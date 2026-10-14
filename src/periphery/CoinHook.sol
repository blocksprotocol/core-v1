// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { IBlockFactory } from "../interfaces/IBlockFactory.sol";
import { ICoinFactory } from "../interfaces/ICoinFactory.sol";
import { ICoinHook } from "../interfaces/ICoinHook.sol";

import { CoinLiquidity } from "../libraries/CoinLiquidity.sol";
import { FeeSplit } from "../libraries/FeeSplit.sol";
import { BaseMarketHook } from "../market/BaseMarketHook.sol";
import { MarketLiquidity } from "../market/MarketLiquidity.sol";

/// @title CoinHook
/// @notice Enforces Coin launch windows, accounts for swaps and defers fee delivery to parent jars.
/// @custom:security-contact security@blocks.fm
contract CoinHook is BaseMarketHook, ICoinHook {
    // Unlock codes share one namespace with `BaseMarketHook`, which uses 4, 6, 7 and 8.
    // Unlock operation code for Coin discovery and depth seeding.
    uint8 private constant OP_SEED = 1;
    // Unlock operation code for the factory-funded prebuy.
    uint8 private constant OP_PREBUY = 2;
    // Unlock operation code for protocol and Block fee sweeps.
    uint8 private constant OP_VAULT = 5;

    /// @inheritdoc ICoinHook
    uint32 public WINDOW = 30;
    /// @inheritdoc ICoinHook
    uint16 public TAX0_BPS = 9_000;
    /// @inheritdoc ICoinHook
    uint16 public CAP_BPS = 50;
    /// @inheritdoc ICoinHook
    mapping(address token => mapping(address account => uint256)) public pendingFees;

    // Initialization

    /// @notice Binds the hook once at deployment to its factory, manager and BUX.
    /// @param manager PoolManager bound to the factory.
    /// @param factory_ Fixed factory authorized for registration, funding and migration.
    /// @param bux_ BUX token with 6 decimals.
    constructor(IPoolManager manager, address factory_, address bux_)
        BaseMarketHook(manager, factory_, bux_)
    { }

    // Launch

    /// @inheritdoc ICoinHook
    function register(address token, PoolKey calldata key, PoolConfig calldata config)
        external
        onlyFactory
    {
        _register(token, key, config, MarketLiquidity.WindowPolicy(WINDOW, TAX0_BPS, CAP_BPS));
    }

    /// @inheritdoc ICoinHook
    function seed(address token, uint256 tokens) external onlyFactory {
        IBlockFactory(factory).requireMarketsActive();
        _unlock(OP_SEED, token, tokens, address(0));
    }

    /// @inheritdoc ICoinHook
    function prebuy(address token, uint256 quoteIn, address escrow)
        external
        onlyFactory
        returns (uint256 tokensOut)
    {
        IBlockFactory(factory).requireMarketsActive();
        bytes memory result = _unlock(OP_PREBUY, token, quoteIn, escrow);
        tokensOut = abi.decode(result, (uint256));
    }

    // Claims

    /// @inheritdoc ICoinHook
    function sweepVault(address token) external nonReentrant returns (uint256) {
        return _sweep(token);
    }

    // Settings

    /// @inheritdoc ICoinHook
    function setWindowParams(uint32 windowSeconds, uint16 tax0Bps, uint16 capBps)
        external
        onlySafe
    {
        if (
            windowSeconds == 0 || windowSeconds > 3600 || tax0Bps == 0 || tax0Bps > 9000
                || capBps == 0 || capBps > 2000
        ) revert InvalidConfiguration();
        WINDOW = windowSeconds;
        TAX0_BPS = tax0Bps;
        CAP_BPS = capBps;
        emit WindowParamsSet(windowSeconds, tax0Bps, capBps);
    }

    // Views

    /// @inheritdoc ICoinHook
    function circulating(address token) public view returns (uint256) {
        return IERC20(token).totalSupply() - _state[token].custody;
    }

    /// @inheritdoc ICoinHook
    function custodyOf(address token) external view returns (uint256) {
        return _state[token].custody;
    }

    /// @inheritdoc ICoinHook
    function windowPolicy(address token)
        external
        view
        returns (uint32 seconds_, uint16 tax, uint16 cap)
    {
        MarketLiquidity.WindowPolicy memory window = _windowPolicy[token];
        return (window.seconds_, window.tax, window.cap);
    }

    // Internal functions

    function _isBlockPool() internal pure override returns (bool) {
        return false;
    }

    function _unlockExtra(uint8 op, address token, uint256 amount, address to)
        internal
        override
        returns (bytes memory)
    {
        if (op == OP_SEED) {
            _seed(token, amount);
        } else if (op == OP_PREBUY) {
            return abi.encode(_prebuy(token, amount, to));
        } else if (op == OP_VAULT) {
            return abi.encode(
                CoinLiquidity.sweep(
                    pendingFees[token],
                    poolManager,
                    ICoinFactory(factory),
                    token,
                    _config[token].quote
                )
            );
        } else {
            revert InvalidCallback();
        }
        return "";
    }

    function _seed(address token, uint256 tokens) internal {
        PoolConfig storage config = _config[token];
        if (config.token == address(0) || tokens != SUPPLY) revert InvalidConfiguration();
        CoinLiquidity.seed(
            _inventory[token],
            poolManager,
            _keys[token],
            config.tokenIs0,
            config.openingTick,
            config.bondingTick,
            tokens
        );
        _state[token].custody = tokens;
        // Discovery rounds down in token base units. Depth receives the remainder.
        emit Seeded(token, tokens * 80 / 100, tokens - tokens * 80 / 100);
    }

    function _prebuy(address token, uint256 quoteIn, address escrow)
        internal
        returns (uint256 tokensOut)
    {
        PoolKey memory key = _keys[token];
        PoolConfig storage config = _config[token];
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !config.tokenIs0,
            amountSpecified: -SafeCast.toInt256(quoteIn),
            // Use the widest price limits strictly inside the PoolManager bounds.
            sqrtPriceLimitX96: config.tokenIs0
                ? TickMath.MAX_SQRT_PRICE - 1
                : TickMath.MIN_SQRT_PRICE + 1
        });
        // PoolManager skips callbacks for this hook's own swaps, so prepare and finish here.
        SwapContext memory context = _prepareSwap(address(this), key, params, "", true);
        params.amountSpecified = -SafeCast.toInt256(context.expectedQuote);
        BalanceDelta delta = poolManager.swap(key, params, "");
        _finish(context, key, delta);
        (, tokensOut) = _amounts(delta, config.tokenIs0);
        // The factory supplies `quoteIn` before calling.
        MarketLiquidity.settle(poolManager, _quoteCurrency(key, config));
        poolManager.take(_tokenCurrency(key, config), escrow, tokensOut);
        _activeToken = address(0);
        emit Prebought(token, quoteIn, tokensOut, escrow);
    }

    function _sweep(address token) private returns (uint256 amount) {
        if (_config[token].token == address(0)) revert UnknownPool();
        amount = abi.decode(_unlock(OP_VAULT, token, 0, address(0)), (uint256));
    }

    function _swapFeeBps() internal pure override returns (uint256) {
        return FeeSplit.SWAP_FEE_BPS;
    }

    // Launch tax decays linearly over the snapshotted window, rounding down to whole bps
    // in the buyer's favor. It is zero once the window ends.
    function _taxBps(address token) internal view override returns (uint256) {
        MarketLiquidity.WindowPolicy memory window = _windowPolicy[token];
        uint256 elapsed = block.timestamp - _config[token].launchedAt;
        if (elapsed >= window.seconds_) return 0;
        return uint256(window.tax) * (window.seconds_ - elapsed) / window.seconds_;
    }

    // Non-prebuy purchases share the snapshotted cap in bps of fixed supply per second.
    // Counting per Unix second also covers chains with sub-second block times.
    function _enforceCap(PoolConfig storage config, PoolState storage state, uint256 tokensOut)
        internal
        override
    {
        MarketLiquidity.WindowPolicy memory window = _windowPolicy[config.token];
        if (block.timestamp - config.launchedAt >= window.seconds_) return;
        if (state.capSecond != uint64(block.timestamp)) {
            state.capSecond = uint64(block.timestamp);
            state.soldThisSecond = 0;
        }
        state.soldThisSecond += tokensOut;
        // The fixed-supply division is exact in token base units.
        if (state.soldThisSecond > SUPPLY * window.cap / FeeSplit.BPS) revert CapExceeded();
    }

    // Allocations and the creator recipient are fixed at accrual.
    // The protocol share rounds down from the fee, then the creator share from the remainder.
    // The Block keeps the rounding remainder.
    function _distributeSwapFee(SwapContext memory context, PoolConfig storage, address asset)
        internal
        override
    {
        (address creator, uint16 protocolBps, uint16 creatorBps) =
            ICoinFactory(factory).swapFeeTerms(context.token);
        FeeSplit.SwapSplit memory split =
            FeeSplit.splitSwapFee(context.fee, protocolBps, creatorBps);
        if (creator <= FeeSplit.PROTOCOL_ROW) revert InvalidConfiguration();
        _creditAccount(context.token, asset, creator, split.creator);
        pendingFees[context.token][FeeSplit.PROTOCOL_ROW] += split.feePool;
        pendingFees[context.token][FeeSplit.BLOCK_ROW] += split.vault + context.tax;
        if (context.fee + context.tax != 0) {
            poolManager.mint(address(this), uint256(uint160(asset)), context.fee + context.tax);
        }
        emit SwapFeeSplit(
            context.token, asset, split.creator, split.vault + context.tax, split.feePool
        );
    }
}
