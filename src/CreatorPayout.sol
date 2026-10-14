// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from
    "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IWETH9 } from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import { IBlockRegistry } from "./interfaces/IBlockRegistry.sol";
import { IBlockToken } from "./interfaces/IBlockToken.sol";
import { ICreatorPayout } from "./interfaces/ICreatorPayout.sol";
import { IForwarderFactory } from "./interfaces/IForwarderFactory.sol";
import { IJar } from "./interfaces/IJar.sol";
import { IJarFactory } from "./interfaces/IJarFactory.sol";
import { IProtocolSettings } from "./interfaces/IProtocolSettings.sol";

/// @title CreatorPayout
/// @notice Allocates fixed-weight withdrawal claims and forwards receipts through immutable clones.
/// @dev Cumulative rounding makes gross entitlements independent of processing frequency.
/// Forwarder fees round on each increment, so net claims can depend on frequency.
/// Claims must debit custody exactly.
/// Recipients are fixed. The clone has no upgrade, rescue or arbitrary execution.
/// @custom:security-contact security@blocks.fm
contract CreatorPayout is ICreatorPayout, Initializable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @inheritdoc ICreatorPayout
    // Maximum number of fixed payees per payout or forwarder.
    uint256 public constant MAX_PAYEES = 16;
    uint256 private constant BPS = 10_000; // Rate denominator: 10_000 bps = 100%.

    /// @inheritdoc ICreatorPayout
    address public factory;
    /// @inheritdoc ICreatorPayout
    bool public isForwarder;
    /// @notice Returns the routing configuration fixed by forwarder initialization.
    /// @dev All fields are zero before forwarder initialization.
    /// @return homeChainId Chain ID identifying the Block's home chain.
    /// @return token Block token address on its home chain.
    /// @return jarBps Gross receipt share for the jar route in bps, with 10_000 bps = 100%.
    /// @return creatorBps Creator share of the jar route's post-protocol remainder in bps.
    /// @return source Claimed attribution label; zero denotes unattributed receipts.
    /// @return partner Whether forwarded legs incur the 20% protocol fee.
    IForwarderFactory.Config public forwardConfig;
    mapping(address => uint256) private _jarForwarded;
    address[] private _recipients;
    uint16[] private _weights;
    /// @inheritdoc ICreatorPayout
    mapping(address asset => uint256) public totalReceived;
    /// @inheritdoc ICreatorPayout
    mapping(address asset => uint256) public totalAllocated;
    /// @inheritdoc ICreatorPayout
    mapping(address asset => uint256) public totalPaid;
    mapping(address asset => mapping(address account => uint256)) private _allocated;
    /// @inheritdoc ICreatorPayout
    mapping(address asset => mapping(address account => uint256)) public claimable;

    // Initialization

    /// @notice Locks initialization of the implementation when deployed.
    constructor() {
        _disableInitializers();
    }

    /// @notice Accepts native currency only in forwarder mode.
    /// @dev `forward(address(0))` wraps the accumulated balance.
    receive() external payable {
        if (!isForwarder) revert InvalidAsset();
    }

    /// @inheritdoc ICreatorPayout
    function initialize(address factory_, address[] calldata recipients, uint16[] calldata weights)
        external
        initializer
    {
        _initialize(factory_, recipients, weights, false);
    }

    /// @inheritdoc ICreatorPayout
    function initializeForwarder(
        IForwarderFactory.Config calldata config,
        address[] calldata recipients,
        uint16[] calldata weights
    ) external initializer {
        if (
            config.homeChainId == 0 || config.token == address(0) || config.jarBps > BPS
                || config.creatorBps > BPS
                || (config.creatorBps != 0 && block.chainid != config.homeChainId)
        ) revert InvalidConfiguration();
        _initialize(msg.sender, recipients, weights, config.jarBps == BPS);
        isForwarder = true;
        forwardConfig = config;
    }

    // Distribution

    /// @inheritdoc ICreatorPayout
    function distribute(address asset) external nonReentrant returns (uint256 allocated) {
        if (isForwarder) revert InvalidConfiguration();
        if (factory == address(0)) revert NotInitialized();
        if (asset.code.length == 0) revert InvalidAsset();

        uint256 balance = IERC20(asset).balanceOf(address(this));
        uint256 received = balance + totalPaid[asset];
        if (balance < reserved(asset) || received < totalReceived[asset]) {
            revert AssetDeficit(asset);
        }
        totalReceived[asset] = received;

        for (uint256 i; i < _recipients.length; ++i) {
            address account = _recipients[i];
            // Cumulative entitlements round down. Later receipts can allocate the dust.
            uint256 entitlement = Math.mulDiv(received, _weights[i], BPS);
            uint256 amount = entitlement - _allocated[asset][account];
            if (amount == 0) continue;
            _allocated[asset][account] = entitlement;
            allocated += amount;
            claimable[asset][account] += amount;
            emit Allocated(asset, account, amount);
        }
        totalAllocated[asset] += allocated;
        emit Distributed(asset, received, allocated, received - totalAllocated[asset]);
    }

    /// @inheritdoc ICreatorPayout
    function forward(address asset) external nonReentrant returns (uint256 forwarded) {
        if (!isForwarder) revert InvalidConfiguration();
        IForwarderFactory forwarderFactory = IForwarderFactory(factory);
        IProtocolSettings settings = IProtocolSettings(forwarderFactory.settings());
        IForwarderFactory.Config memory config = forwardConfig;
        if (config.creatorBps != 0 && block.chainid != config.homeChainId) {
            revert InvalidConfiguration();
        }
        address jar =
            IJarFactory(forwarderFactory.jarFactory()).create(config.homeChainId, config.token);
        if (asset == address(0)) {
            asset = settings.weth();
            uint256 native = address(this).balance;
            if (native != 0) IWETH9(asset).deposit{ value: native }();
        }

        uint256 balance = IERC20(asset).balanceOf(address(this));
        uint256 received = balance + totalPaid[asset];
        if (balance < reserved(asset) || received < totalReceived[asset]) {
            revert AssetDeficit(asset);
        }
        uint256 gross = received - totalReceived[asset];
        totalReceived[asset] = received;
        emit BlockRevenue(config.homeChainId, config.token, asset, gross, config.source);
        if (block.chainid == config.homeChainId && asset == config.token) {
            totalAllocated[asset] += balance;
            totalPaid[asset] += balance;
            _burnRevenue(asset, balance, settings);
            return balance;
        }

        // The jar entitlement rounds down. The payee pool receives the remainder.
        uint256 jarTotal = Math.mulDiv(received, config.jarBps, BPS);
        uint256 jarAmount = jarTotal - _jarForwarded[asset];
        _jarForwarded[asset] = jarTotal;
        if (jarAmount != 0) {
            address creator;
            if (config.creatorBps != 0) {
                address blockFactory = settings.blockFactoryFor(config.token);
                if (blockFactory == address(0)) revert InvalidConfiguration();
                creator = IBlockRegistry(blockFactory).payoutOf(config.token);
            }
            forwarded =
                _forwardSplit(asset, jarAmount, config.creatorBps, creator, jar, config, settings);
        }

        for (uint256 i; i < _recipients.length; ++i) {
            address account = _recipients[i];
            // Payee entitlements round down. Unallocated dust stays in custody.
            uint256 entitlement = Math.mulDiv(received - jarTotal, _weights[i], BPS);
            uint256 amount = entitlement - _allocated[asset][account];
            _allocated[asset][account] = entitlement;
            if (amount == 0) continue;
            // The payee receives 100% of the post-protocol remainder.
            forwarded += _forwardSplit(asset, amount, 10_000, account, jar, config, settings);
        }

        uint256 afterBalance = IERC20(asset).balanceOf(address(this));
        if (afterBalance > balance || balance - afterBalance != forwarded) {
            revert TransferMismatch();
        }
    }

    // Claims

    /// @inheritdoc ICreatorPayout
    function claim(address asset, address account) external nonReentrant returns (uint256 amount) {
        amount = claimable[asset][account];
        if (amount == 0) revert NothingToClaim();
        IERC20 currency = IERC20(asset);
        uint256 beforeBalance = currency.balanceOf(address(this));
        if (beforeBalance < reserved(asset)) revert AssetDeficit(asset);
        claimable[asset][account] = 0;
        totalPaid[asset] += amount;

        currency.safeTransfer(account, amount);

        uint256 afterBalance = currency.balanceOf(address(this));
        if (afterBalance > beforeBalance || beforeBalance - afterBalance != amount) {
            revert TransferMismatch();
        }
        emit Claimed(asset, account, amount);
    }

    // Views

    /// @inheritdoc ICreatorPayout
    function payees()
        external
        view
        returns (address[] memory recipients, uint16[] memory weights)
    {
        return (_recipients, _weights);
    }

    /// @inheritdoc ICreatorPayout
    function reserved(address asset) public view returns (uint256) {
        return totalAllocated[asset] - totalPaid[asset];
    }

    /// @inheritdoc ICreatorPayout
    function roundingDust(address asset) external view returns (uint256) {
        return totalReceived[asset] - totalAllocated[asset];
    }

    // Internal functions

    function _initialize(
        address factory_,
        address[] calldata recipients,
        uint16[] calldata weights,
        bool allowEmpty
    ) private {
        uint256 payeeCount = recipients.length;
        if (
            factory_ != msg.sender || factory_.code.length == 0 || (payeeCount == 0 && !allowEmpty)
                || payeeCount > MAX_PAYEES || payeeCount != weights.length
        ) {
            revert InvalidConfiguration();
        }

        uint256 totalWeight;
        for (uint256 i; i < payeeCount; ++i) {
            address recipient = recipients[i];
            // Low addresses are routing sentinels, not payees.
            if (recipient <= address(1) || recipient == address(this) || weights[i] == 0) {
                revert InvalidRecipient();
            }
            for (uint256 j; j < i; ++j) {
                if (recipient == recipients[j]) revert InvalidRecipient();
            }
            totalWeight += weights[i];
        }
        if (payeeCount != 0 && totalWeight != BPS) revert InvalidConfiguration();

        factory = factory_;
        _recipients = recipients;
        _weights = weights;
        emit PayeesInitialized(factory_, recipients, weights);
    }

    // Only the home jar can burn staking receipt shares. Raised tokens burn here.
    function _burnRevenue(address asset, uint256 amount, IProtocolSettings settings) private {
        address origin = settings.blockFactoryFor(asset);
        if (origin == address(0) || !IBlockRegistry(origin).isStakingBlock(asset)) {
            IBlockToken(asset).burn(amount);
            return;
        }
        address jar = IJarFactory(IBlockRegistry(origin).jarFactory()).create(block.chainid, asset);
        IERC20(asset).forceApprove(jar, amount);
        IJar(jar).deposit(asset, amount, forwardConfig.source);
    }

    function _forwardSplit(
        address asset,
        uint256 amount,
        uint16 creatorBps,
        address account,
        address jar,
        IForwarderFactory.Config memory config,
        IProtocolSettings settings
    ) private returns (uint256 forwarded) {
        if (account == address(this)) creatorBps = 0;

        // Partner routes charge 20% per leg. Both shares round down. The jar keeps the remainder.
        uint256 toFeePool = Math.mulDiv(amount, config.partner ? 2_000 : 0, BPS);
        uint256 toCreator = Math.mulDiv(amount - toFeePool, creatorBps, BPS);
        uint256 toJar = amount - toFeePool - toCreator;

        totalAllocated[asset] += amount;
        forwarded = toFeePool + toJar;
        totalPaid[asset] += forwarded;

        if (toCreator != 0) {
            claimable[asset][account] += toCreator;
            emit Allocated(asset, account, toCreator);
        }
        if (toFeePool != 0) {
            IERC20(asset).safeTransfer(settings.feePool(), toFeePool);
        }
        if (toJar != 0) {
            IERC20(asset).forceApprove(jar, toJar);
            IJar(jar).deposit(asset, toJar, config.source);
        }
    }
}
