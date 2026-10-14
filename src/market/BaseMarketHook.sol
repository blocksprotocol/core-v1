// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { ReentrancyGuardTransient } from
    "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { IBlockFactory } from "../interfaces/IBlockFactory.sol";
import { IBlockHook } from "../interfaces/IBlockHook.sol";

import { FloorMath } from "../libraries/FloorMath.sol";
import { SwapChargeMath } from "../libraries/SwapChargeMath.sol";
import { MarketLiquidity } from "./MarketLiquidity.sol";

/// @title BaseMarketHook
/// @notice Accounts for swaps, fee claims and launch liquidity for fixed market hooks.
/// @dev Owns launch positions. Only Block pools accept outside liquidity. Concrete hooks deploy
/// at addresses encoding their permissions. They read fee settings and the market pause through
/// the fixed factory. Hook data carries unauthenticated app attribution.
abstract contract BaseMarketHook is IBlockHook, IUnlockCallback, ReentrancyGuardTransient {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @dev Stores 13 flat memory words in transient storage between callbacks.
    /// `_activeToken` prevents nested swaps while the context is active.
    struct SwapContext {
        address token;
        address sender;
        bytes32 appId; // Zero when attribution is absent or the payload length is invalid.
        bool isBuy;
        bool exactIn;
        bool prebuy; // Exempts a factory-funded buy from launch tax and the purchase cap.
        uint256 fee; // Ordinary swap fee in quote base units.
        uint256 tax; // Launch tax in quote base units.
        uint256 taxBps; // Launch tax in bps of quote after the ordinary fee.
        uint256 expectedQuote; // Required pool quote base units. Zero selects token fill checks.
        // Required pool token base units. Checked only when `expectedQuote` is zero.
        uint256 expectedToken;
        // Accrued PoolManager protocol fees in token base units before a Coin sell.
        uint256 protocolTokensBefore;
        uint256 feeBps; // Ordinary swap fee in bps of gross quote, fixed for this swap.
    }

    /// @notice Returns the fixed Coin supply.
    /// @return Supply in 18-decimal token base units.
    uint256 public constant SUPPLY = 1_000_000_000e18;
    // Derived hooks reserve unlock codes 1, 2 and 5. Code 3 is unused.
    // Unlock operation code for quote-fee claims.
    uint8 internal constant OP_CLAIM = 4;
    // Unlock operation code for funded launch seeding.
    uint8 private constant OP_FUNDED = 6;
    // Unlock operation code for liquidity withdrawal.
    uint8 private constant OP_EXPORT = 7;
    // Unlock operation code for liquidity restoration.
    uint8 private constant OP_IMPORT = 8;

    // Hash-derived base slot for transient swap context.
    bytes32 private constant CTX_SLOT = keccak256("blocks.swap.context");
    // Number of 32-byte words in the flat swap context.
    uint256 private constant CTX_WORDS = 13;

    /// @inheritdoc IBlockHook
    IPoolManager public immutable poolManager;
    /// @inheritdoc IBlockHook
    address public immutable factory;
    /// @inheritdoc IBlockHook
    address public immutable bux;

    /// @notice Returns the token registered for an active pool ID.
    /// @dev The key is the PoolManager pool ID derived from the full pool key.
    /// @return token Token address. Zero for unknown or exported pools.
    mapping(bytes32 poolId => address token) public tokenOfPool;
    mapping(address token => PoolKey) internal _keys;
    mapping(address token => PoolConfig) internal _config;
    mapping(address token => PoolState) internal _state;
    mapping(address token => MarketLiquidity.WindowPolicy) internal _windowPolicy;
    mapping(address token => MarketLiquidity.Inventory) internal _inventory;

    /// @inheritdoc IBlockHook
    mapping(address token => mapping(address account => uint256)) public earned;

    address internal transient _activeToken; // Zero means no swap context is active.
    bool private transient _unlocking;

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }

    modifier onlySafe() {
        if (msg.sender != safe()) revert OnlySafe();
        _;
    }

    // Initialization

    /// @notice Binds the hook once at deployment to its manager, fixed factory and BUX.
    /// @dev The address must encode the hook permissions. It must match the factory's `hook()`
    /// unless that address has code. BUX and PoolManager must match the factory's endpoints.
    /// The factory and its migration registry control which hook receives markets.
    /// @param poolManager_ PoolManager bound to the factory.
    /// @param factory_ Fixed factory authorized for registration, funding and migration.
    /// @param bux_ BUX token with 6 decimals.
    constructor(IPoolManager poolManager_, address factory_, address bux_) {
        IBlockFactory blockFactory = IBlockFactory(factory_);
        if (
            (blockFactory.hook() != address(this) && blockFactory.hook().code.length == 0)
                || blockFactory.bux() != bux_
                || address(blockFactory.poolManager()) != address(poolManager_)
        ) revert InvalidConfiguration();

        poolManager = poolManager_;
        factory = factory_;
        bux = bux_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    // Launch

    /// @inheritdoc IBlockHook
    function registerFunded(address token, PoolKey calldata key, PoolConfig calldata config)
        external
        onlyFactory
    {
        _register(token, key, config, MarketLiquidity.WindowPolicy(0, 0, 0));
    }

    /// @inheritdoc IBlockHook
    function seedFunded(address token, uint256 tokenAmount, uint256 quoteAmount)
        external
        onlyFactory
        nonReentrant
    {
        _unlockData(abi.encode(OP_FUNDED, token, tokenAmount, quoteAmount));
    }

    // Migration

    /// @inheritdoc IBlockHook
    function exportLiquidity(address token, address destination)
        external
        onlyFactory
        nonReentrant
        returns (bytes memory snapshot)
    {
        PoolKey memory key = _keys[token];
        if (tokenOfPool[PoolId.unwrap(key.toId())] != token || token == address(0)) {
            revert UnknownPool();
        }
        bytes memory result = _unlock(OP_EXPORT, token, 0, destination);
        snapshot = MarketLiquidity.exportSnapshot(
            _keys, _config, _state, _windowPolicy, poolManager, token, result
        );
        delete tokenOfPool[PoolId.unwrap(key.toId())];
        if (!_isBlockPool()) _state[token].custody = 0;
    }

    /// @inheritdoc IBlockHook
    function importLiquidity(address token, bytes calldata snapshot)
        external
        onlyFactory
        nonReentrant
        returns (uint24 fee, int24 tickSpacing)
    {
        MigrationSnapshot memory decoded = abi.decode(snapshot, (MigrationSnapshot));
        _validatePoolKind(decoded.config);
        if (
            decoded.config.isBlock
                && (decoded.windowSeconds != 0 || decoded.taxBps != 0 || decoded.capBps != 0)
        ) {
            revert InvalidConfiguration();
        }
        MarketLiquidity.stageImport(
            _keys, _config, _state, _windowPolicy, tokenOfPool, poolManager, token, snapshot
        );
        _unlockData(abi.encode(OP_IMPORT, token, snapshot));
        return (_keys[token].fee, _keys[token].tickSpacing);
    }

    // Claims

    /// @inheritdoc IBlockHook
    function claimPoolFees(address token, address account)
        external
        nonReentrant
        returns (uint256 amount)
    {
        return _claimPoolFees(token, account);
    }

    // PoolManager callbacks

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!_unlocking) revert InvalidCallback();
        uint8 operation = abi.decode(data, (uint8));
        if (operation == OP_FUNDED) {
            (, address fundedToken, uint256 tokenAmount, uint256 quoteAmount) =
                abi.decode(data, (uint8, address, uint256, uint256));
            PoolConfig storage config = _config[fundedToken];
            MarketLiquidity.seedLaunch(
                _inventory[fundedToken],
                poolManager,
                _keys[fundedToken],
                config.tokenIs0,
                tokenAmount,
                quoteAmount
            );
            if (!config.isBlock) _state[fundedToken].custody = tokenAmount;
            _state[fundedToken].bonded = true;
            emit FundedSeeded(fundedToken, tokenAmount, quoteAmount);
            return "";
        }
        if (operation == OP_IMPORT) {
            (, address importedToken, bytes memory snapshot) =
                abi.decode(data, (uint8, address, bytes));
            MarketLiquidity.restore(
                _inventory[importedToken], poolManager, _keys[importedToken], snapshot
            );
            return "";
        }
        (uint8 decodedOperation, address token, uint256 amount, address to) =
            abi.decode(data, (uint8, address, uint256, address));
        if (decodedOperation == OP_CLAIM) {
            _collect(token, amount, to);
        } else if (decodedOperation == OP_EXPORT) {
            (MigrationPosition[] memory positions, uint256 amount0, uint256 amount1) =
            MarketLiquidity.withdraw(
                _inventory[token], poolManager, _keys[token], _config[token].tokenIs0, to
            );
            emit LiquidityExported(token, to, amount0, amount1);
            return abi.encode(positions, amount0, amount1);
        } else {
            return _unlockExtra(decodedOperation, token, amount, to);
        }
        return "";
    }

    /// @inheritdoc IHooks
    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != factory) revert OnlyFactory();
        if (tokenOfPool[PoolId.unwrap(key.toId())] == address(0)) revert UnknownPool();
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.afterInitialize.selector;
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        if (!_isBlockPool()) revert LiquidityNotAllowed();
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @inheritdoc IHooks
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        SwapContext memory context = _prepareSwap(sender, key, params, hookData, false);
        _storeCtx(context);
        if (context.isBuy == context.exactIn) {
            uint256 quoteCharge = context.fee + context.tax;
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(_i128(quoteCharge), 0), 0);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @inheritdoc IHooks
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        SwapContext memory context = _loadCtx();
        if (
            _activeToken == address(0) || context.token != _activeToken
                || tokenOfPool[PoolId.unwrap(key.toId())] != context.token
        ) {
            revert InvalidCallback();
        }
        int128 quoteDelta = _finish(context, key, delta);
        _activeToken = address(0);
        return (IHooks.afterSwap.selector, quoteDelta);
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata key, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        IBlockFactory(factory).requireMarketsActive();
        if (tokenOfPool[PoolId.unwrap(key.toId())] == address(0)) revert UnknownPool();
        return IHooks.beforeDonate.selector;
    }

    /// @inheritdoc IHooks
    function afterDonate(
        address,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata
    ) external onlyPoolManager returns (bytes4) {
        address token = tokenOfPool[PoolId.unwrap(key.toId())];
        if (token == address(0)) revert UnknownPool();
        // Coin pools exclude outside LPs, so donated tokens count toward hook custody.
        if (!_isBlockPool()) {
            _state[token].custody += _config[token].tokenIs0 ? amount0 : amount1;
        }
        return IHooks.afterDonate.selector;
    }

    // Views

    /// @inheritdoc IBlockHook
    function safe() public view returns (address) {
        return IBlockFactory(factory).safe();
    }

    /// @inheritdoc IBlockHook
    /// @dev PoolManager skips callbacks for hook-initiated operations. Other callers reach enabled
    /// guards. `IBlockHook` extends `IHooks`, so disabled callbacks must still be implemented.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: true,
            afterDonate: true,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @inheritdoc IBlockHook
    function inventoryDust(address token)
        external
        view
        returns (uint256 tokenDust, uint256 quoteDust)
    {
        return (_inventory[token].dust, _inventory[token].quoteDust);
    }

    /// @inheritdoc IBlockHook
    function poolConfig(address token) external view returns (PoolConfig memory) {
        return _config[token];
    }

    /// @inheritdoc IBlockHook
    function poolState(address token) external view returns (PoolState memory) {
        return _state[token];
    }

    /// @inheritdoc IBlockHook
    function poolKeyOf(address token) external view returns (PoolKey memory) {
        return _keys[token];
    }

    /// @inheritdoc IBlockHook
    function spotSqrtPriceX96(address token) public view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(_keys[token].toId());
    }

    /// @inheritdoc IBlockHook
    function spot(address token) public view returns (uint256) {
        return FloorMath.spot(spotSqrtPriceX96(token), _config[token].tokenIs0);
    }

    /// @inheritdoc IBlockHook
    function feePool() public view returns (address) {
        return IBlockFactory(factory).feePool();
    }

    // Internal functions

    function _register(
        address token,
        PoolKey memory key,
        PoolConfig memory config,
        MarketLiquidity.WindowPolicy memory policy
    ) internal {
        _validatePoolKind(config);
        if (
            token == address(0) || config.token != token || config.quote == address(0)
                || address(key.hooks) != address(this)
                || Currency.unwrap(config.tokenIs0 ? key.currency0 : key.currency1) != token
                || Currency.unwrap(config.tokenIs0 ? key.currency1 : key.currency0) != config.quote
        ) {
            revert InvalidConfiguration();
        }

        bytes32 poolId = PoolId.unwrap(key.toId());
        if (tokenOfPool[poolId] != address(0) || _config[token].token != address(0)) {
            revert PoolAlreadyRegistered();
        }

        tokenOfPool[poolId] = token;
        _keys[token] = key;
        _config[token] = config;
        _windowPolicy[token] = policy;
        emit PoolRegistered(token, poolId, config);
    }

    function _validatePoolKind(PoolConfig memory config) private view {
        if (config.isBlock != _isBlockPool()) revert InvalidConfiguration();
        if (
            config.isBlock
                && (
                    config.quote != bux || config.vault == address(0)
                        || config.parentToken != address(0)
                )
        ) {
            revert InvalidConfiguration();
        }
    }

    function _isBlockPool() internal pure virtual returns (bool);

    function _unlockData(bytes memory data) internal returns (bytes memory result) {
        if (_unlocking || _activeToken != address(0)) revert NestedSwap();
        _unlocking = true;
        result = poolManager.unlock(data);
        _unlocking = false;
    }

    function _unlock(uint8 operation, address token, uint256 quoteAmount, address recipient)
        internal
        returns (bytes memory result)
    {
        return _unlockData(abi.encode(operation, token, quoteAmount, recipient));
    }

    function _claimPoolFees(address token, address account) private returns (uint256 amount) {
        if (account == address(0)) revert InvalidConfiguration();
        PoolConfig storage config = _config[token];
        if (config.token == address(0)) revert UnknownPool();
        amount = earned[token][account];
        if (amount == 0) return 0; // Avoid an arbitrary-token call for an empty claim.
        earned[token][account] = 0;
        _unlock(OP_CLAIM, token, amount, account);
        emit Claimed(account, config.quote, amount, account);
        emit FeeSwept(token, config.quote, account, amount);
    }

    function _collect(address token, uint256 quoteAmount, address recipient) internal {
        address asset = _config[token].quote;
        poolManager.burn(address(this), uint256(uint160(asset)), quoteAmount);
        poolManager.take(Currency.wrap(asset), recipient, quoteAmount);
    }

    function _unlockExtra(uint8, address, uint256, address)
        internal
        virtual
        returns (bytes memory)
    {
        revert InvalidCallback();
    }

    function _prepareSwap(
        address sender,
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        bytes memory hookData,
        bool prebuy_
    ) internal returns (SwapContext memory context) {
        IBlockFactory(factory).requireMarketsActive();
        if (_activeToken != address(0) || (_unlocking && !prebuy_)) {
            revert NestedSwap();
        }
        context.token = tokenOfPool[PoolId.unwrap(key.toId())];
        if (context.token == address(0)) revert UnknownPool();
        if (params.amountSpecified == 0 || params.amountSpecified == type(int256).min) {
            revert InvalidSwap();
        }

        _activeToken = context.token;
        context.sender = sender;
        context.isBuy = params.zeroForOne != _config[context.token].tokenIs0;
        context.exactIn = params.amountSpecified < 0;
        context.prebuy = prebuy_;
        PoolConfig storage config = _config[context.token];
        context.appId = SwapChargeMath.parseAppId(hookData);
        // Fix the fee rate for this swap so `afterSwap` uses the same rate.
        context.feeBps = _swapFeeBps();
        context.taxBps = context.isBuy && !prebuy_ ? _taxBps(context.token) : 0;
        if (!config.isBlock && !context.isBuy) {
            context.protocolTokensBefore =
                poolManager.protocolFeesAccrued(_tokenCurrency(key, config));
        }

        uint256 specified = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);

        if (context.isBuy && context.exactIn) {
            (context.fee, context.tax, context.expectedQuote) =
                SwapChargeMath.charges(specified, context.feeBps, context.taxBps);
            if (context.expectedQuote == 0) revert InvalidSwap();
        } else if (!context.isBuy && !context.exactIn) {
            context.expectedQuote = SwapChargeMath.grossForNet(specified, context.feeBps, 0);
            (context.fee,,) = SwapChargeMath.charges(context.expectedQuote, context.feeBps, 0);
        } else {
            context.expectedToken = specified;
        }
    }

    function _swapFeeBps() internal view virtual returns (uint256);

    function _taxBps(address) internal view virtual returns (uint256) {
        return 0;
    }

    function _tokenCurrency(PoolKey memory key, PoolConfig storage config)
        internal
        view
        returns (Currency)
    {
        return config.tokenIs0 ? key.currency0 : key.currency1;
    }

    function _storeCtx(SwapContext memory context) private {
        bytes32 slot = CTX_SLOT;
        assembly ("memory-safe") {
            for { let i := 0 } lt(i, CTX_WORDS) { i := add(i, 1) } {
                tstore(add(slot, i), mload(add(context, mul(i, 32))))
            }
        }
    }

    function _i128(uint256 amount) internal pure returns (int128) {
        return SafeCast.toInt128(SafeCast.toInt256(amount));
    }

    function _loadCtx() private view returns (SwapContext memory context) {
        bytes32 slot = CTX_SLOT;
        assembly ("memory-safe") {
            context := mload(0x40)
            mstore(0x40, add(context, mul(CTX_WORDS, 32)))
            for { let i := 0 } lt(i, CTX_WORDS) { i := add(i, 1) } {
                mstore(add(context, mul(i, 32)), tload(add(slot, i)))
            }
        }
    }

    function _finish(SwapContext memory context, PoolKey memory key, BalanceDelta delta)
        internal
        returns (int128)
    {
        PoolConfig storage config = _config[context.token];
        PoolState storage state = _state[context.token];
        (uint256 quoteAmount, uint256 tokenAmount) = _amounts(delta, config.tokenIs0);
        if (quoteAmount == 0 || tokenAmount == 0) revert ZeroOutput();

        // The unspecified return delta cannot adjust charges on specified quote.
        // All modes require full fills within router limits.
        if (
            context.expectedQuote != 0
                ? quoteAmount != context.expectedQuote
                : tokenAmount != context.expectedToken
        ) {
            revert PartialFill();
        }

        if (context.isBuy && !context.exactIn) {
            uint256 grossQuoteAmount =
                SwapChargeMath.grossForNet(quoteAmount, context.feeBps, context.taxBps);
            (context.fee, context.tax,) =
                SwapChargeMath.charges(grossQuoteAmount, context.feeBps, context.taxBps);
        } else if (!context.isBuy && context.exactIn) {
            (context.fee,,) = SwapChargeMath.charges(quoteAmount, context.feeBps, 0);
        }

        if (!config.isBlock) {
            if (context.isBuy) {
                state.custody -= tokenAmount;
                if (!context.prebuy) _enforceCap(config, state, tokenAmount);
            } else {
                uint256 protocolTokens = poolManager.protocolFeesAccrued(
                    _tokenCurrency(key, config)
                ) - context.protocolTokensBefore;
                state.custody += tokenAmount - protocolTokens;
            }
        }

        _distributeSwapFee(context, config, config.quote);
        if (!state.bonded && _discoveryExhausted(key, config)) {
            state.bonded = true;
            emit Bonded(context.token, PoolId.unwrap(key.toId()));
        }

        _emitCharged(context, config.quote, quoteAmount, tokenAmount);
        emit SwapAttributed(context.token, context.appId, context.sender);
        // Only swaps with unspecified quote pay charges here. Gross quote equals net plus charges.
        return context.isBuy != context.exactIn ? _i128(context.fee + context.tax) : int128(0);
    }

    function _amounts(BalanceDelta delta, bool tokenIs0)
        internal
        pure
        returns (uint256 quoteAmount, uint256 tokenAmount)
    {
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();
        (int128 tokenDelta, int128 quoteDelta) = tokenIs0 ? (amount0, amount1) : (amount1, amount0);
        tokenAmount = tokenDelta < 0 ? uint256(-int256(tokenDelta)) : uint256(int256(tokenDelta));
        quoteAmount = quoteDelta < 0 ? uint256(-int256(quoteDelta)) : uint256(int256(quoteDelta));
    }

    function _enforceCap(PoolConfig storage, PoolState storage, uint256) internal virtual { }

    function _distributeSwapFee(
        SwapContext memory context,
        PoolConfig storage config,
        address asset
    ) internal virtual;

    function _creditAccount(address token, address asset, address account, uint256 quoteAmount)
        internal
    {
        if (quoteAmount == 0) return;
        if (account == address(0)) revert InvalidConfiguration();
        earned[token][account] += quoteAmount;
        emit FeeAccrued(token, asset, account, quoteAmount);
    }

    function _discoveryExhausted(PoolKey memory key, PoolConfig storage config)
        internal
        view
        returns (bool)
    {
        (, int24 tick,,) = poolManager.getSlot0(key.toId());
        return config.tokenIs0 ? tick >= config.bondingTick : tick < config.bondingTick;
    }

    function _emitCharged(
        SwapContext memory context,
        address asset,
        uint256 quoteAmount,
        uint256 tokenAmount
    ) internal {
        emit SwapCharged(
            context.token,
            asset,
            Charge({
                isBuy: context.isBuy,
                exactInput: context.exactIn,
                quoteAmount: quoteAmount,
                tokenAmount: tokenAmount,
                fee: context.fee,
                tax: context.tax
            })
        );
    }

    function _quoteCurrency(PoolKey memory key, PoolConfig storage config)
        internal
        view
        returns (Currency)
    {
        return config.tokenIs0 ? key.currency1 : key.currency0;
    }
}
