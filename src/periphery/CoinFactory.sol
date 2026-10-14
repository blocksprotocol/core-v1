// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuardTransient } from
    "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { IBlockFactory } from "../interfaces/IBlockFactory.sol";
import { IBlockHook } from "../interfaces/IBlockHook.sol";
import { IBlockRegistry } from "../interfaces/IBlockRegistry.sol";
import { ICoinFactory } from "../interfaces/ICoinFactory.sol";
import { ICoinHook } from "../interfaces/ICoinHook.sol";
import { ICreatorPayout } from "../interfaces/ICreatorPayout.sol";
import { IJarFactory } from "../interfaces/IJarFactory.sol";
import { IProtocolSettings } from "../interfaces/IProtocolSettings.sol";

import { HookMigrationRegistry } from "../HookMigrationRegistry.sol";
import { VestingEscrow } from "../VestingEscrow.sol";
import { FloorMath } from "../libraries/FloorMath.sol";
import { LaunchSettlement } from "../libraries/LaunchSettlement.sol";

/// @title CoinFactory
/// @notice Launches Coins instantly and resolves their parent Blocks through registered factories.
/// @dev Coins have no vault of their own. All launch funds leave the factory in the same call.
/// @custom:security-contact security@blocks.fm
contract CoinFactory is ICoinFactory, Pausable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using Clones for address;
    using PoolIdLibrary for PoolKey;

    struct InitParams {
        IBlockFactory blockFactory;
        IJarFactory jarFactory;
        address hook; // Predicted Coin hook. May have no code yet.
        address escrowImplementation;
        address payoutImplementation;
        uint256 launchFee; // Native launch payment in wei. Zero disables the fee.
    }

    struct LaunchCtx {
        address token;
        address admin;
        address parent;
        address vault; // Parent vault or staking configuration.
        address parentToken; // Parent token when it is the quote. Zero for other quotes.
        address escrow; // Zero when the launch has no prebuy.
        address payout;
        uint256 prebuyTokens; // Purchased 18-decimal token base units. Zero without prebuy.
        PoolKey key;
    }

    /// @inheritdoc ICoinFactory
    // Fixed supply in 18-decimal token base units.
    uint256 public constant SUPPLY = 1_000_000_000e18;
    /// @inheritdoc ICoinFactory
    uint256 public constant MAX_PREBUY_BPS = 2_000; // Maximum prebuy output in bps of fixed supply.
    /// @inheritdoc ICoinFactory
    // Maximum combined cliff and vesting duration in whole days.
    uint256 public constant MAX_VEST_DAYS = 1_825;
    /// @notice Returns the Coin pool spacing.
    /// @return Fixed spacing of one tick.
    int24 public constant TICK_SPACING = 1;
    /// @notice Returns the PoolManager LP fee for new Coin pools.
    /// @dev The hook accounts for Coin swap charges.
    /// @return Zero LP fee, in hundredths of a bp (1_000_000 = 100%).
    uint24 public constant LP_FEE = 0;

    /// @inheritdoc ICoinFactory
    IBlockFactory public immutable blockFactory;
    /// @inheritdoc ICoinFactory
    IPoolManager public immutable poolManager;
    /// @inheritdoc ICoinFactory
    address public immutable bux;
    /// @inheritdoc ICoinFactory
    address public immutable hook;
    /// @notice Returns the fixed implementation used for vesting-escrow clones.
    /// @return Address cloned for each funded prebuy.
    address public immutable escrowImplementation;
    /// @notice Returns the fixed implementation used for payout clones.
    /// @return Address cloned for configured payees.
    address public immutable payoutImplementation;
    /// @inheritdoc ICoinFactory
    address public immutable migrationRegistry;
    /// @inheritdoc ICoinFactory
    IJarFactory public immutable jarFactory;

    /// @inheritdoc ICoinFactory
    uint256 public launchFee;

    /// @inheritdoc ICoinFactory
    mapping(address token => address) public jarOf;
    /// @inheritdoc ICoinFactory
    mapping(address token => address) public sourceOf;
    mapping(address token => IBlockFactory.Launch) private _launches;
    mapping(address token => PoolKey) private _keys;
    /// @inheritdoc ICoinFactory
    mapping(address token => bool) public marketLive;
    /// @inheritdoc ICoinFactory
    mapping(address token => address) public canonicalHookOf;
    /// @inheritdoc ICoinFactory
    uint16 public protocolShareBps;
    /// @inheritdoc ICoinFactory
    mapping(address token => uint16) public creatorShareBps;
    uint256 private _launchCount;

    modifier onlySafe() {
        if (msg.sender != blockFactory.safe()) revert OnlySafe();
        _;
    }

    modifier onlyAdmin(address token) {
        if (_launches[token].token == address(0)) revert NotRegistered(token);
        if (msg.sender != _launches[token].admin) revert NotAdmin();
        _;
    }

    // Initialization

    /// @notice Binds the factory's deployment endpoints and initial launch fee once.
    /// @dev The deployer creates the factory before its predicted Coin hook, which checks that
    /// their endpoints match. The Safe initially owns the migration registry.
    /// @param p Core factory, jar factory, predicted hook, clone implementations and launch fee in
    /// wei.
    constructor(InitParams memory p) {
        if (
            p.jarFactory.settings() != p.blockFactory.settings()
                || p.escrowImplementation.code.length == 0 || p.payoutImplementation.code.length == 0
        ) revert InvalidConfiguration();

        jarFactory = p.jarFactory;
        blockFactory = p.blockFactory;
        poolManager = p.blockFactory.poolManager();
        bux = p.blockFactory.bux();
        hook = p.hook;
        escrowImplementation = p.escrowImplementation;
        payoutImplementation = p.payoutImplementation;
        migrationRegistry = address(new HookMigrationRegistry(safe()));
        launchFee = p.launchFee;
        // The initial protocol allocation is 2,000 bps (20%) of the ordinary Coin swap fee.
        protocolShareBps = 2000;
        emit ProtocolShareSet(2000);
    }

    // Launch

    /// @inheritdoc ICoinFactory
    function launch(
        CoinLaunchParams calldata p,
        address[] calldata recipients,
        uint16[] calldata weights
    ) external payable whenNotPaused nonReentrant returns (address token) {
        return _launchInstant(p, recipients, weights);
    }

    // Registry

    /// @inheritdoc ICoinFactory
    function setMetadata(address token, string calldata metadataURI) external onlyAdmin(token) {
        emit MetadataSet(token, metadataURI);
    }

    /// @inheritdoc ICoinFactory
    function setPayout(address token, address payout) external onlyAdmin(token) nonReentrant {
        // `address(1)` identifies the protocol fee row, not a payout recipient.
        if (payout == address(0) || payout == address(1)) revert ZeroAddress();
        _launches[token].payout = payout;
        emit PayoutSet(token, payout);
    }

    /// @inheritdoc ICoinFactory
    function setPayees(address token, address[] calldata recipients, uint16[] calldata weights)
        external
        onlyAdmin(token)
        nonReentrant
    {
        address payout = _createPayout(token, recipients, weights);
        _launches[token].payout = payout;
        emit PayoutSet(token, payout);
    }

    /// @inheritdoc ICoinFactory
    function transferAdmin(address token, address newAdmin)
        external
        onlyAdmin(token)
        nonReentrant
    {
        if (newAdmin == address(0)) revert ZeroAddress();
        _launches[token].admin = newAdmin;
        emit AdminTransferred(token, newAdmin);
    }

    /// @inheritdoc ICoinFactory
    function setCreatorShareBps(address token, uint16 creatorShareBps_)
        external
        onlyAdmin(token)
        nonReentrant
    {
        _validateCreatorShare(creatorShareBps_);
        creatorShareBps[token] = creatorShareBps_;
        emit CreatorShareSet(token, creatorShareBps_);
    }

    // Settings

    /// @inheritdoc ICoinFactory
    function setLaunchFee(uint256 launchFeeWei) external onlySafe {
        launchFee = launchFeeWei;
        emit LaunchFeeSet(launchFeeWei);
    }

    /// @inheritdoc ICoinFactory
    function setProtocolShareBps(uint16 protocolShareBps_) external onlySafe {
        if (protocolShareBps_ > IProtocolSettings(blockFactory.settings()).MAX_PROTOCOL_SHARE_BPS())
        {
            revert InvalidFeePolicy();
        }
        protocolShareBps = protocolShareBps_;
        emit ProtocolShareSet(protocolShareBps_);
    }

    /// @inheritdoc ICoinFactory
    function pause() external onlySafe {
        _pause();
    }

    /// @inheritdoc ICoinFactory
    function unpause() external onlySafe {
        _unpause();
    }

    // Migration

    /// @inheritdoc ICoinFactory
    function migrateLiquidity(address token, address destination)
        external
        onlyAdmin(token)
        nonReentrant
    {
        HookMigrationRegistry gate = HookMigrationRegistry(migrationRegistry);
        if (!marketLive[token]) revert InvalidConfiguration();
        address source = canonicalHookOf[token];
        if (!gate.isRegisteredUpgradePath(source, destination)) revert UpgradeNotRegistered();

        bytes memory snapshot = IBlockHook(source).exportLiquidity(token, destination);
        PoolKey memory key = _keys[token];
        (key.fee, key.tickSpacing) = IBlockHook(destination).importLiquidity(token, snapshot);
        key.hooks = IHooks(destination);
        IBlockFactory.Launch storage launchRecord = _launches[token];
        _keys[token] = key;
        launchRecord.poolId = PoolId.unwrap(key.toId());
        canonicalHookOf[token] = destination;
        emit CanonicalHookChanged(token, source, destination, launchRecord.poolId);
    }

    // Views

    /// @inheritdoc ICoinFactory
    function safe() public view returns (address) {
        return blockFactory.safe();
    }

    /// @inheritdoc ICoinFactory
    function feePool() public view returns (address) {
        return blockFactory.feePool();
    }

    /// @inheritdoc ICoinFactory
    function paused() public view override(ICoinFactory, Pausable) returns (bool) {
        return super.paused() || blockFactory.paused();
    }

    /// @inheritdoc ICoinFactory
    function requireMarketsActive() external view whenNotPaused { }

    /// @inheritdoc ICoinFactory
    function launches(address token) external view returns (IBlockFactory.Launch memory) {
        return _launches[token];
    }

    /// @inheritdoc ICoinFactory
    function swapFeeTerms(address token)
        external
        view
        returns (address payout, uint16 protocolBps, uint16 creatorBps)
    {
        IBlockFactory.Launch storage launchRecord = _launches[token];
        // Fees in parent tokens go entirely to the Block's jar for burning.
        // Protocol and creator recipients receive no parent tokens to sell.
        if (launchRecord.quote == launchRecord.parent) return (launchRecord.payout, 0, 0);

        return (launchRecord.payout, protocolShareBps, creatorShareBps[token]);
    }

    /// @inheritdoc ICoinFactory
    function poolKeyOf(address token) external view returns (PoolKey memory) {
        return _keys[token];
    }

    /// @inheritdoc ICoinFactory
    function isRegistered(address token) external view returns (bool) {
        return _launches[token].token != address(0);
    }

    /// @inheritdoc ICoinFactory
    function parentOf(address token) external view returns (address) {
        return _launches[token].parent;
    }

    /// @inheritdoc ICoinFactory
    function payoutOf(address token) external view returns (address) {
        return _launches[token].payout;
    }

    /// @inheritdoc ICoinFactory
    function adminOf(address token) external view returns (address) {
        return _launches[token].admin;
    }

    /// @inheritdoc ICoinFactory
    function vaultOf(address token) external view returns (address) {
        if (_launches[token].token != address(0)) return _launches[token].vault;
        address factory = IProtocolSettings(blockFactory.settings()).blockFactoryFor(token);
        return factory == address(0) ? address(0) : IBlockRegistry(factory).vaultOf(token);
    }

    // Internal functions

    function _launchInstant(
        CoinLaunchParams calldata params,
        address[] memory recipients,
        uint16[] memory weights
    ) private returns (address token) {
        if (params.isBlock) revert BlockSaleRequired();
        if (hook.code.length == 0) revert HookNotDeployed();
        if (msg.value != launchFee) revert WrongLaunchFee();
        if (uint256(params.cliffDays) + params.vestDays > MAX_VEST_DAYS) {
            revert VestingOutOfRange();
        }
        _validateCreatorShare(params.creatorShareBps);

        LaunchCtx memory context;
        context.admin = params.admin == address(0) ? msg.sender : params.admin;
        (context.parent, context.vault, context.parentToken) = _resolveQuote(params);

        context.token = LaunchSettlement.createToken(params.name, params.symbol, ++_launchCount);
        token = context.token;
        // Any launcher may choose payees for the named Coin admin.
        context.payout = _checkPayout(context.admin);
        if (recipients.length != 0 || weights.length != 0) {
            context.payout = _createPayout(token, recipients, weights);
        }

        // Set creator authority and terms before prebuy. Leave `token` unset until the final
        // record so `onlyAdmin` rejects callback edits during launch.
        _launches[token].isBlock = false;
        _launches[token].admin = context.admin;
        _launches[token].payout = context.payout;
        _launches[token].parent = params.parent;
        _launches[token].quote = params.quote;
        _setRouting(token, params);
        creatorShareBps[token] = params.creatorShareBps;
        emit CreatorShareSet(token, params.creatorShareBps);

        // Register before initialization so the hook admits the caller's opening price.
        _createPool(params, context);

        IERC20(context.token).safeTransfer(hook, SUPPLY);
        ICoinHook(hook).seed(context.token, SUPPLY);

        if (params.prebuyQuote != 0) _prebuy(params, context);

        // Funding alone grants no Coin admin, payout or escrow rights. Vested tokens go to payout.
        _record(params, context);

        Address.sendValue(payable(feePool()), msg.value);
    }

    function _validateCreatorShare(uint16 creatorShareBps_) private pure {
        if (creatorShareBps_ > 10_000) revert CreatorShareTooHigh();
    }

    function _resolveQuote(CoinLaunchParams calldata params)
        internal
        view
        returns (address parent, address vault, address parentToken)
    {
        if (params.parent == address(0)) revert ZeroAddress();
        if (params.quote.code.length == 0) revert UnsupportedQuote();
        // Both sale-launched and staking Blocks may be parents through a registered factory.
        address factory = IProtocolSettings(blockFactory.settings()).blockFactoryFor(params.parent);
        if (factory == address(0)) revert InvalidConfiguration();
        return (
            params.parent,
            IBlockRegistry(factory).vaultOf(params.parent),
            params.quote == params.parent ? params.parent : address(0)
        );
    }

    function _checkPayout(address payout) private pure returns (address) {
        // `address(1)` identifies the protocol fee row, not a payout recipient.
        if (payout == address(1)) revert ZeroAddress();
        return payout;
    }

    function _createPayout(address token, address[] memory recipients, uint16[] memory weights)
        private
        returns (address payout)
    {
        payout = payoutImplementation.clone();
        ICreatorPayout(payout).initialize(address(this), recipients, weights);
        emit PayeesSet(token, payout, recipients, weights);
    }

    function _setRouting(address token, CoinLaunchParams calldata params) private {
        jarOf[token] = jarFactory.create(block.chainid, params.parent);
        sourceOf[token] = params.source;
    }

    function _createPool(CoinLaunchParams calldata params, LaunchCtx memory context) internal {
        bool tokenIs0;
        (context.key, tokenIs0) = _poolKey(context.token, params.quote);
        (uint160 sqrtOpeningPriceX96, int24 openingTick, int24 bondingTick) =
            _openingTicks(params.openingPriceX96, params.bondingPriceX96, tokenIs0);
        ICoinHook(hook).register(
            context.token,
            context.key,
            IBlockHook.PoolConfig({
                token: context.token,
                quote: params.quote,
                tokenIs0: tokenIs0,
                isBlock: false,
                vault: context.vault,
                parentToken: context.parentToken,
                launchedAt: uint64(block.timestamp),
                openingTick: openingTick,
                bondingTick: bondingTick
            })
        );
        poolManager.initialize(context.key, sqrtOpeningPriceX96);
    }

    function _poolKey(address token, address quote)
        internal
        view
        returns (PoolKey memory key, bool tokenIs0)
    {
        tokenIs0 = token < quote;
        (address currency0, address currency1) = tokenIs0 ? (token, quote) : (quote, token);
        key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });
    }

    function _openingTicks(uint160 openingPriceX96, uint160 bondingPriceX96, bool tokenIs0)
        internal
        pure
        returns (uint160 sqrtOpeningPriceX96, int24 openingTick, int24 bondingTick)
    {
        if (openingPriceX96 == 0 || bondingPriceX96 <= openingPriceX96) {
            revert InvalidConfiguration();
        }
        // Ratio, square root and tick conversions round down in currency1/currency0 order.
        // No funds move. The pool starts at the opening tick's exact square-root price.
        // Both inputs can map to the same tick.
        sqrtOpeningPriceX96 = FloorMath.sqrtPriceForRatio(openingPriceX96, 1 << 96, tokenIs0);
        openingTick = TickMath.getTickAtSqrtPrice(sqrtOpeningPriceX96);
        sqrtOpeningPriceX96 = TickMath.getSqrtPriceAtTick(openingTick);
        bondingTick = TickMath.getTickAtSqrtPrice(
            FloorMath.sqrtPriceForRatio(bondingPriceX96, 1 << 96, tokenIs0)
        );
    }

    function _prebuy(CoinLaunchParams calldata params, LaunchCtx memory context) internal {
        context.escrow = escrowImplementation.clone();
        uint256 quoteBalanceBefore = IERC20(params.quote).balanceOf(hook);
        IERC20(params.quote).safeTransferFrom(msg.sender, hook, params.prebuyQuote);
        if (IERC20(params.quote).balanceOf(hook) - quoteBalanceBefore != params.prebuyQuote) {
            revert TransferMismatch();
        }
        context.prebuyTokens =
            ICoinHook(hook).prebuy(context.token, params.prebuyQuote, context.escrow);
        // The cap applies to token output. 10_000 bps = 100%.
        // This fixed-supply division is exact.
        if (context.prebuyTokens > SUPPLY * MAX_PREBUY_BPS / 10_000) revert PrebuyTooLarge();
        uint64 cliffEnd = uint64(block.timestamp + uint256(params.cliffDays) * 1 days);
        uint64 vestEnd = cliffEnd + uint64(uint256(params.vestDays) * 1 days);
        VestingEscrow(context.escrow).initialize(
            context.token, address(this), context.prebuyTokens, cliffEnd, vestEnd
        );
    }

    function _record(CoinLaunchParams calldata params, LaunchCtx memory context) internal {
        IBlockFactory.Launch memory launchRecord = IBlockFactory.Launch({
            token: context.token,
            isBlock: false,
            parent: context.parent,
            quote: params.quote,
            vault: context.vault,
            escrow: context.escrow,
            poolId: PoolId.unwrap(context.key.toId()),
            admin: context.admin,
            payout: context.payout,
            appTag: params.appTag,
            launchedAt: uint64(block.timestamp)
        });
        _launches[context.token] = launchRecord;
        _keys[context.token] = context.key;
        marketLive[context.token] = true;
        canonicalHookOf[context.token] = hook;
        emit Launched(context.token, params.quote, launchRecord);
        emit CoinAttributed(
            context.token, context.parent, params.source, block.chainid, params.metadataURI
        );
        emit MetadataSet(context.token, params.metadataURI);
    }
}
