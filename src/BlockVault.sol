// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from
    "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { IBlockFactory } from "./interfaces/IBlockFactory.sol";
import { IBlockRevenueConfig } from "./interfaces/IBlockRevenueConfig.sol";
import { IBlockToken } from "./interfaces/IBlockToken.sol";
import { IBlockVault } from "./interfaces/IBlockVault.sol";
import { IProtocolSettings } from "./interfaces/IProtocolSettings.sol";

/// @title BlockVault
/// @notice Holds a Block's backing and pays redemptions through an immutable clone.
/// @dev Redemption credits extra-asset claims for separate withdrawal.
/// Only sync and withdrawal call extra tokens, so a failing extra cannot block redemption.
/// @custom:security-contact security@blocks.fm
contract BlockVault is IBlockVault, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // BUX occupies the first of 32 concurrent slots. Disabled slots keep backing and claims.
    /// @inheritdoc IBlockVault
    uint256 public constant MAX_BACKING_ASSETS = 32;
    /// @notice Returns the backing limit for retiring a disabled slot with no claims.
    /// @return One asset base unit.
    uint256 public constant RETIREMENT_DUST = 1;
    /// @notice Returns the Policy notice and application window length in seconds.
    /// @return Seven days in seconds.
    uint256 public constant POLICY_NOTICE = 7 days;

    /// @inheritdoc IBlockVault
    address public token;
    /// @inheritdoc IBlockVault
    address public bux;
    /// @notice Returns the factory that initialized the vault.
    /// @return Initializing caller; zero before initialization.
    address public factory;
    EnumerableSet.AddressSet private _extras;
    // False once disabled: no new receipts, even while the slot still holds backing or claims.
    mapping(address asset => bool) private _isRetained;

    // Reserved claims are excluded from redemption backing.
    // `_available` plus `_reserved` can differ from the token balance.
    mapping(address asset => uint256) private _reserved;
    mapping(address asset => uint256) private _available;
    mapping(address account => mapping(address asset => uint256)) private _claims;
    /// @inheritdoc IBlockRevenueConfig
    address public policy;
    address private _pendingPolicy; // Zero means direct vault delivery while a proposal exists.
    uint64 private _policyEffectiveAt; // Activation time in Unix seconds; zero means no proposal.

    modifier onlyAdmin() {
        if (msg.sender != IBlockFactory(factory).adminOf(token)) revert OnlyAdmin();
        _;
    }

    // Initialization

    /// @notice Locks initialization of the implementation when deployed.
    constructor() {
        token = address(1); // Clone storage starts at zero.
    }

    /// @inheritdoc IBlockVault
    function initialize(address token_, address bux_, address policy_, address[] calldata retained_)
        external
    {
        if (token != address(0)) revert AlreadyInitialized();
        if (token_ == address(0)) revert InvalidAddress();
        if (IBlockToken(token_).factory() != msg.sender) revert OnlyFactory();

        token = token_;
        bux = bux_;
        factory = msg.sender;
        policy = policy_;
        for (uint256 i; i < retained_.length; ++i) {
            if (retained_[i] != bux_) _registerExtra(retained_[i]);
        }
    }

    // Funding

    /// @inheritdoc IBlockVault
    function sync(address asset) external nonReentrant returns (uint256 received) {
        if (asset == token) {
            // The Block's own token is never backing.
            IBlockToken(token).burn(IERC20(token).balanceOf(address(this)));
            return 0;
        }
        if (asset != bux && !_extras.contains(asset)) revert AssetNotAllowed(asset);
        received = _sync(asset);
        // Direct transfers carry no reliable app attribution.
        emit BackingReceived(asset, msg.sender, bytes32(0), bytes32(0), received);
    }

    // Redemption

    /// @inheritdoc IBlockVault
    function redeem(uint256 amount, address to) external nonReentrant returns (uint256 buxOut) {
        if (amount == 0) revert ZeroAmount();
        _checkRecipient(to);
        // Book pending BUX net of the work fee before pricing redemption.
        _sync(bux);

        uint256 tokenSupply = IERC20(token).totalSupply();
        if (amount > tokenSupply) revert InsufficientSupply();

        // Shares use booked backing and pre-burn supply, rounding down. Backing keeps the rest.
        buxOut = Math.mulDiv(_available[bux], amount, tokenSupply);
        _available[bux] -= buxOut;

        uint256 extraCount = _extras.length();
        for (uint256 i; i < extraCount; ++i) {
            address asset = _extras.at(i);
            uint256 assetShare = Math.mulDiv(_available[asset], amount, tokenSupply);
            if (assetShare == 0) continue;
            _available[asset] -= assetShare;
            _claims[to][asset] += assetShare;
            _reserved[asset] += assetShare;
            emit ExtraCredited(to, asset, assetShare);
        }

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IBlockToken(token).burn(amount);
        if (buxOut != 0) IERC20(bux).safeTransfer(to, buxOut);
        emit Redeemed(msg.sender, to, amount, buxOut);
    }

    /// @inheritdoc IBlockVault
    function withdraw(address asset, address to) external nonReentrant returns (uint256 amount) {
        _checkRecipient(to);
        amount = _claims[msg.sender][asset];
        if (amount == 0) revert ZeroAmount();
        _claims[msg.sender][asset] = 0;
        _reserved[asset] -= amount;

        IERC20(asset).safeTransfer(to, amount);
        emit ExtraWithdrawn(msg.sender, to, asset, amount);
    }

    // Basket configuration

    /// @inheritdoc IBlockVault
    function setRetained(address asset, bool enabled) external onlyAdmin nonReentrant {
        if (enabled) {
            _registerExtra(asset);
        } else {
            if (!_extras.contains(asset)) revert AssetNotAllowed(asset);
            _isRetained[asset] = false;
            if (_reserved[asset] == 0 && _available[asset] <= RETIREMENT_DUST) {
                _extras.remove(asset);
                delete _available[asset];
                emit ExtraRetired(asset);
            }
            emit RetainedSet(asset, false);
        }
    }

    // Policy configuration

    /// @inheritdoc IBlockVault
    function proposePolicy(address next) external onlyAdmin {
        if (!IBlockFactory(factory).isBlock(token)) revert BlockNotLive();
        _pendingPolicy = next;
        _policyEffectiveAt = uint64(block.timestamp + POLICY_NOTICE);
        emit PolicyProposed(next, next.codehash, _policyEffectiveAt);
    }

    /// @inheritdoc IBlockVault
    function cancelPolicyProposal() external onlyAdmin {
        address pending = _pendingPolicy;
        delete _pendingPolicy;
        delete _policyEffectiveAt;
        emit PolicyProposalCancelled(pending);
    }

    /// @inheritdoc IBlockVault
    function applyPolicy() external {
        if (_policyEffectiveAt == 0 || block.timestamp < _policyEffectiveAt) {
            revert PolicyNoticePending();
        }
        if (block.timestamp > _policyEffectiveAt + POLICY_NOTICE) revert PolicyProposalExpired();
        _setPolicy(_pendingPolicy);
    }

    /// @inheritdoc IBlockVault
    function disablePolicy() external {
        IBlockFactory blockFactory = IBlockFactory(factory);
        if (msg.sender != blockFactory.adminOf(token) && msg.sender != blockFactory.safe()) {
            revert OnlyAdminOrSafe();
        }
        _setPolicy(address(0));
    }

    // Views

    /// @inheritdoc IBlockVault
    function backing() public view nonReentrantView returns (uint256) {
        return _available[bux];
    }

    /// @inheritdoc IBlockVault
    function backingAssets()
        public
        view
        returns (address[] memory assets, uint256[] memory amounts)
    {
        uint256 backingBux = backing();
        uint256 extraCount = _extras.length();
        assets = new address[](extraCount + 1);
        amounts = new uint256[](extraCount + 1);
        assets[0] = bux;
        amounts[0] = backingBux;
        for (uint256 i; i < extraCount; ++i) {
            address asset = _extras.at(i);
            assets[i + 1] = asset;
            amounts[i + 1] = _available[asset];
        }
    }

    /// @inheritdoc IBlockVault
    function previewRedeem(uint256 amount)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts)
    {
        (assets, amounts) = backingAssets();

        uint256 tokenSupply = IERC20(token).totalSupply();
        if (amount > tokenSupply) revert InsufficientSupply();
        for (uint256 i; i < amounts.length; ++i) {
            amounts[i] = amount == 0 ? 0 : Math.mulDiv(amounts[i], amount, tokenSupply);
        }
    }

    /// @inheritdoc IBlockVault
    function acceptsBacking(address asset) public view returns (bool) {
        if (asset == address(0) || asset == token) return false;
        if (!IBlockFactory(factory).isBlock(token)) return false;
        return asset == bux || _isRetained[asset];
    }

    /// @inheritdoc IBlockRevenueConfig
    function isRetained(address asset) external view returns (bool) {
        return _isRetained[asset];
    }

    /// @inheritdoc IBlockRevenueConfig
    function extras() external view returns (address[] memory) {
        return _extras.values();
    }

    /// @inheritdoc IBlockVault
    function retained() external view returns (address[] memory assets) {
        uint256 count = 1;
        for (uint256 i; i < _extras.length(); ++i) {
            if (_isRetained[_extras.at(i)]) ++count;
        }
        assets = new address[](count);
        assets[0] = bux;
        count = 1;
        for (uint256 i; i < _extras.length(); ++i) {
            address asset = _extras.at(i);
            if (_isRetained[asset]) assets[count++] = asset;
        }
    }

    /// @inheritdoc IBlockVault
    function pendingPolicy() external view returns (address, uint64 effectiveAt) {
        return (_pendingPolicy, _policyEffectiveAt);
    }

    /// @inheritdoc IBlockVault
    function claimable(address account, address asset) external view returns (uint256) {
        return _claims[account][asset];
    }

    /// @inheritdoc IBlockVault
    function available(address asset) public view returns (uint256) {
        return _available[asset];
    }

    /// @inheritdoc IBlockVault
    function reserved(address asset) external view returns (uint256) {
        return _reserved[asset];
    }

    // Internal functions

    function _registerExtra(address asset) private {
        if (asset == token || asset == bux || asset.code.length == 0) {
            revert AssetNotAllowed(asset);
        }
        if (!_extras.contains(asset)) {
            if (_extras.length() + 1 == MAX_BACKING_ASSETS) revert TooManyAssets();
            _extras.add(asset);
            emit ExtraRegistered(asset);
        }
        _isRetained[asset] = true;
        emit RetainedSet(asset, true);
    }

    // Book net surplus before transferring the fee. The fee rounds down in backing's favor.
    // A deficit reduces available backing without reducing reserved claims.
    function _sync(address asset) private returns (uint256 received) {
        uint256 accountedAmount = _available[asset] + _reserved[asset];
        uint256 assetBalance = IERC20(asset).balanceOf(address(this));
        if (assetBalance < accountedAmount) {
            _available[asset] =
                assetBalance > _reserved[asset] ? assetBalance - _reserved[asset] : 0;
            emit BackingCorrected(asset, _available[asset]);
        } else {
            // BUX surplus always books. Extra surplus requires retention and a live Block; disabled
            // extras can still book deficits, so they can still retire.
            if (asset != bux && !acceptsBacking(asset)) revert AssetNotAllowed(asset);
            IProtocolSettings settings = IProtocolSettings(IBlockFactory(factory).settings());
            uint256 surplus = assetBalance - accountedAmount;
            uint256 fee = Math.mulDiv(surplus, settings.workFeeBps(), 10_000);
            received = surplus - fee;
            _available[asset] += received;
            if (fee != 0) IERC20(asset).safeTransfer(settings.feePool(), fee);
        }
    }

    function _checkRecipient(address to) private view {
        if (to == address(0) || to == address(this)) revert InvalidAddress();
    }

    function _setPolicy(address next) private {
        policy = next;
        delete _pendingPolicy;
        delete _policyEffectiveAt;
        emit PolicySet(next, next.codehash);
    }
}
