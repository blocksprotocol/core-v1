// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.37;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from
    "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { MetadataReaderLib } from "solady/utils/MetadataReaderLib.sol";

import { IBlockRegistry } from "../interfaces/IBlockRegistry.sol";
import { IJarFactory } from "../interfaces/IJarFactory.sol";
import { IPermitSignatures } from "../interfaces/IPermitSignatures.sol";
import { IProtocolSettings } from "../interfaces/IProtocolSettings.sol";
import { IStakingVault } from "../interfaces/IStakingVault.sol";

import { ERC20PermitSignatures } from "../token/ERC20PermitSignatures.sol";

/// @title StakingVault
/// @notice Holds a staking Block's underlying and releases revenue through self-held profit shares.
/// @dev ERC-4626 conversions include virtual assets and shares.
/// The vault has no administrative authority, pause, rescue or upgrade operation.
/// @custom:security-contact security@blocks.fm
contract StakingVault is ERC4626, ERC20PermitSignatures, ReentrancyGuardTransient, IStakingVault {
    using SafeERC20 for IERC20;

    // Scale for unlock rates: share base units per second with 12 fractional decimal places.
    uint256 private constant UNLOCK_RATE_PRECISION = 1e12;

    /// @inheritdoc IStakingVault
    address public immutable factory;
    /// @inheritdoc IStakingVault
    address public immutable homeJar;
    IProtocolSettings private immutable _settings;

    /// @inheritdoc IStakingVault
    uint32 public immutable profitMaxUnlockTime;
    /// @inheritdoc IStakingVault
    uint256 public fullProfitUnlockDate;
    /// @inheritdoc IStakingVault
    uint256 public profitUnlockingRate;
    /// @inheritdoc IStakingVault
    uint256 public lastProfitUpdate;

    // Initialization

    /// @notice Binds the underlying, factory, home jar and unlock duration once at deployment.
    /// @dev The staking factory deploys the staking vault before registering it.
    /// @param name_ Receipt and signing domain name. Empty selects the default receipt name.
    /// @param underlying ERC-20 asset deposited into and redeemed from the staking vault.
    /// @param factory_ Registry supplying settings and the deterministic jar factory.
    /// @param unlockTime_ Unlock duration in seconds. Zero selects ten days. Otherwise, 1-30 days.
    constructor(string memory name_, IERC20 underlying, address factory_, uint32 unlockTime_)
        ERC4626(underlying)
        ERC20PermitSignatures(
            bytes(name_).length == 0 ? _receiptName(underlying) : name_,
            _receiptSymbol(underlying)
        )
    {
        // Underlying decimals plus the six-decimal offset must fit `uint8`.
        // Unreadable metadata defaults to 18 underlying decimals and 24 receipt decimals.
        decimals();

        uint32 unlockTime = unlockTime_ == 0 ? uint32(10 days) : unlockTime_;
        if (unlockTime < 1 days || unlockTime > 30 days) revert InvalidUnlockTime();

        factory = factory_;
        _settings = IProtocolSettings(IBlockRegistry(factory_).settings());
        homeJar =
            IJarFactory(IBlockRegistry(factory_).jarFactory()).predict(block.chainid, address(this));
        profitMaxUnlockTime = unlockTime;
    }

    // Revenue

    /// @inheritdoc IStakingVault
    /// @dev The caller pays the work fee without using existing principal.
    function addRevenue(uint256 amount) external nonReentrant returns (uint256 netRevenue) {
        // Work fee rates use bps (10_000 bps = 100%). Round down, leaving the remainder in revenue.
        uint256 fee = Math.mulDiv(amount, _settings.workFeeBps(), 10_000);
        netRevenue = amount - fee;

        // Price shares before receiving revenue. Round down, leaving fractional value to holders.
        uint256 sharesToLock = previewDeposit(netRevenue);
        if (fee != 0) IERC20(asset()).safeTransferFrom(msg.sender, _settings.feePool(), fee);
        _transferIn(msg.sender, netRevenue);

        // Finish external calls before updating self-held shares or their unlock schedule.
        _lockProfit(sharesToLock);
        emit RevenueAdded(msg.sender, amount, fee, netRevenue, sharesToLock);
    }

    /// @inheritdoc IStakingVault
    /// @dev No external call separates burning jar shares from locking their replacements.
    function burn(uint256 amount) external nonReentrant {
        if (msg.sender != homeJar) revert OnlyHomeJar();
        _burn(msg.sender, amount);
        _lockProfit(amount);
    }

    // Views

    /// @inheritdoc IPermitSignatures
    function nonces(address owner)
        public
        view
        override(ERC20PermitSignatures, IPermitSignatures)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    /// @inheritdoc IERC20Metadata
    function decimals() public view override(ERC20, ERC4626, IERC20Metadata) returns (uint8) {
        return super.decimals();
    }

    /// @inheritdoc IERC20
    /// @dev Excludes unlocked self-held shares from the supply used to price deposits and exits.
    /// Returns receipt share base units.
    function totalSupply() public view override(ERC20, IERC20) returns (uint256) {
        return super.totalSupply() - _unlockedShares();
    }

    /// @inheritdoc IERC20
    /// @dev Only the vault's balance excludes unlocked shares awaiting reconciliation.
    /// Returns receipt share base units.
    function balanceOf(address account) public view override(ERC20, IERC20) returns (uint256) {
        uint256 balance = super.balanceOf(account);
        return account == address(this) ? balance - _unlockedShares() : balance;
    }

    /// @inheritdoc IERC4626
    /// @dev Self-held shares are reserved for profit. Positive deposits reject this vault and
    /// `address(0)` as receivers. The limit is in underlying token base units.
    /// Zero rejects positive deposits. `type(uint256).max` means unlimited.
    function maxDeposit(address receiver)
        public
        view
        override(ERC4626, IERC4626)
        returns (uint256)
    {
        return receiver == address(this) || receiver == address(0) ? 0 : super.maxDeposit(receiver);
    }

    /// @inheritdoc IERC4626
    /// @dev Uses the same receiver restrictions as deposits. The limit is in receipt share base
    /// units. Zero rejects positive mints. `type(uint256).max` means unlimited.
    function maxMint(address receiver) public view override(ERC4626, IERC4626) returns (uint256) {
        return receiver == address(this) || receiver == address(0) ? 0 : super.maxMint(receiver);
    }

    // Internal functions

    // Fix receipt metadata at deployment so underlying metadata changes cannot rename it.
    function _receiptName(IERC20 underlying) private view returns (string memory) {
        string memory assetName = MetadataReaderLib.readName(address(underlying));
        return bytes(assetName).length == 0 ? "Blocks Token" : string.concat("Blocks ", assetName);
    }

    function _receiptSymbol(IERC20 underlying) private view returns (string memory) {
        string memory assetSymbol = MetadataReaderLib.readSymbol(address(underlying));
        return bytes(assetSymbol).length == 0 ? "bTOKEN" : string.concat("b", assetSymbol);
    }

    // Six extra share decimals give 1e6 virtual share base units per virtual underlying base unit.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // Net new profit shares against unlocked shares. Excludes losses and fees charged in shares.
    function _lockProfit(uint256 sharesToLock) private {
        uint256 unlockedShares = _unlockedShares();
        if (sharesToLock > unlockedShares) {
            _mint(address(this), sharesToLock - unlockedShares);
        } else if (unlockedShares > sharesToLock) {
            _burn(address(this), unlockedShares - sharesToLock);
        }

        // Weight the remaining and new durations by their locked share base units.
        uint256 totalLockedShares = super.balanceOf(address(this));
        if (totalLockedShares != 0) {
            uint256 previouslyLockedTime;
            if (fullProfitUnlockDate > block.timestamp) {
                previouslyLockedTime =
                    (totalLockedShares - sharesToLock) * (fullProfitUnlockDate - block.timestamp);
            }
            // Round down to whole seconds so holders receive the fractional-second value earlier.
            uint256 lockingPeriod =
                (previouslyLockedTime + sharesToLock * profitMaxUnlockTime) / totalLockedShares;
            // Round the scaled rate down. Residual share base units stay locked until expiry.
            profitUnlockingRate =
                Math.mulDiv(totalLockedShares, UNLOCK_RATE_PRECISION, lockingPeriod);
            fullProfitUnlockDate = block.timestamp + lockingPeriod;
            lastProfitUpdate = block.timestamp;
        } else {
            fullProfitUnlockDate = 0;
        }
    }

    // Round unlocked share base units down. Fractions stay locked until later unlocking.
    // At expiry, all remaining self-held shares unlock without a storage write.
    function _unlockedShares() private view returns (uint256) {
        if (fullProfitUnlockDate > block.timestamp) {
            return Math.mulDiv(
                profitUnlockingRate, block.timestamp - lastProfitUpdate, UNLOCK_RATE_PRECISION
            );
        }
        return fullProfitUnlockDate == 0 ? 0 : super.balanceOf(address(this));
    }

    // The shared hook guards both deposit and mint against reentrancy.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        // Reject zero-share purchases before transfer. Zero-asset operations remain valid.
        if (assets != 0 && shares == 0) revert ZeroDepositShares();
        super._deposit(caller, receiver, assets, shares);
    }

    // The shared hook guards both withdraw and redeem against reentrancy.
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant {
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // Book only what arrives. A transfer that delivers a different amount reverts.
    function _transferIn(address from, uint256 assets) internal override {
        uint256 balanceBefore = IERC20(asset()).balanceOf(address(this));
        super._transferIn(from, assets);
        if (IERC20(asset()).balanceOf(address(this)) - balanceBefore != assets) {
            revert TransferMismatch();
        }
    }

    // Debit only what holders are owed. A transfer that takes a different amount reverts.
    function _transferOut(address to, uint256 assets) internal override {
        uint256 balanceBefore = IERC20(asset()).balanceOf(address(this));
        super._transferOut(to, assets);
        if (balanceBefore - IERC20(asset()).balanceOf(address(this)) != assets) {
            revert TransferMismatch();
        }
    }

    // Reserve self-held shares for profit locks. User transfers cannot add to the reserve.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to == address(this)) revert ERC20InvalidReceiver(to);
        super._update(from, to, value);
    }
}
