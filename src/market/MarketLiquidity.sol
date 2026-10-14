// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { CurrencySettler } from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { SqrtPriceMath } from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { TransientStateLibrary } from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import { IBlockHook } from "../interfaces/IBlockHook.sol";

/// @title MarketLiquidity
/// @notice Seeds and migrates market positions in the calling hook's custody.
/// @dev Linked functions use the calling hook's storage. Funding, withdrawal and settlement run
/// during its PoolManager unlock. Snapshot staging and export run outside it.
library MarketLiquidity {
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    struct Position {
        int24 lower; // Inclusive lower position bound in ticks.
        int24 upper; // Exclusive upper position bound in ticks.
        bytes32 salt;
        uint128 liquidity; // Funded position liquidity units.
    }

    struct Inventory {
        Position[] positions;
        uint256 dust; // Tracked token base units outside positions.
        uint256 quoteDust; // Tracked quote base units outside positions.
    }

    struct WindowPolicy {
        uint32 seconds_; // Window duration in seconds. Zero disables the window.
        uint16 tax; // Initial launch tax in bps of quote after the ordinary fee. Zero disables tax.
        // Purchase cap in bps of fixed supply per second. Applies only during the window.
        // Zero allows only prebuys during the window.
        uint16 cap;
    }

    // Bid widths use multiples of the 60-tick Block pool spacing.
    int24 private constant NEAR_BID_TICKS = 1_080; // Width in ticks, about 10% below the bid edge.
    // Width in ticks, about 35% below the bid edge.
    int24 private constant MIDDLE_BID_TICKS = 4_320;
    int24 private constant DEEP_BID_TICKS = 13_860; // Width in ticks, about 75% below the bid edge.
    uint16 private constant NEAR_BID_BPS = 5_000; // Quote allocation in bps: 50% of net proceeds.
    uint16 private constant MIDDLE_BID_BPS = 3_000; // Quote allocation in bps: 30% of net proceeds.
    // Nominal quote allocation in bps: 20%, plus allocation rounding.
    uint16 private constant DEEP_BID_BPS = 2_000;

    /// @notice Thrown when restoration finds tracked positions.
    error AlreadySeeded();

    /// @notice Thrown when position funding, capacity, migration proceeds or restoration bounds are
    /// invalid.
    error InvalidLiquidity();

    /// @notice Thrown when settlement selects native currency.
    error NativeCurrencyNotSupported();

    // Liquidity operations

    /// @notice Seeds zero to three nested quote-only bids below the current quote-per-token price
    /// and a token-only ask above it.
    /// @dev Bids must cover supply outside the supplied inventory, including withheld and vested
    /// tokens. The first two quote allocations round down. The final bid receives the remainder.
    /// Token capacity rounds down for the coverage check. Unused tokens and quote remain tracked
    /// dust. The caller must provide funds and an initialized pool during its PoolManager unlock.
    /// @param self Calling hook's tracked inventory for the pool.
    /// @param manager PoolManager holding the pool.
    /// @param key Initialized pool receiving the launch positions.
    /// @param tokenIs0 Whether the market token is currency0.
    /// @param tokens Supplied token base units.
    /// @param quote Supplied quote base units.
    function seedLaunch(
        Inventory storage self,
        IPoolManager manager,
        PoolKey memory key,
        bool tokenIs0,
        uint256 tokens,
        uint256 quote
    ) public {
        uint256 tokenSupply =
            IERC20(Currency.unwrap(tokenIs0 ? key.currency0 : key.currency1)).totalSupply();
        (uint160 sqrtPriceX96, int24 saleTick,,) = manager.getSlot0(key.toId());
        int24 bidEdgeTick = saleTick;
        // Keep bids quote-only by rounding down to the tick grid for token0.
        // For token1, round up past any fractional tick, then up to the grid.
        if (!tokenIs0 && sqrtPriceX96 > TickMath.getSqrtPriceAtTick(saleTick)) ++bidEdgeTick;
        bidEdgeTick = tokenIs0
            ? _tickFloor(bidEdgeTick, key.tickSpacing)
            : _tickCeil(bidEdgeTick, key.tickSpacing);
        int24[3] memory bidWidths = [NEAR_BID_TICKS, MIDDLE_BID_TICKS, DEEP_BID_TICKS];
        uint16[3] memory bidShares = [NEAR_BID_BPS, MIDDLE_BID_BPS, DEEP_BID_BPS];
        uint256 remainingQuote = quote;
        uint256 tokenCapacity;
        for (uint256 i; i < bidWidths.length; ++i) {
            // Quote weights use bps: 10_000 bps = 100%.
            uint256 bidQuote =
                i == bidWidths.length - 1 ? remainingQuote : quote * bidShares[i] / 10_000;
            remainingQuote -= bidQuote;
            // `_fundPosition` rejects zero liquidity.
            if (bidQuote == 0) continue;
            int24 bidLower = tokenIs0 ? bidEdgeTick - bidWidths[i] : bidEdgeTick;
            int24 bidUpper = tokenIs0 ? bidEdgeTick : bidEdgeTick + bidWidths[i];
            uint128 bidLiquidity = _seedLaunchPosition(
                self,
                manager,
                key,
                sqrtPriceX96,
                bidLower,
                bidUpper,
                bidQuote,
                !tokenIs0,
                keccak256(abi.encode("launch-bid", i))
            );
            uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(bidLower);
            uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(bidUpper);
            tokenCapacity += tokenIs0
                ? SqrtPriceMath.getAmount0Delta(sqrtLowerX96, sqrtUpperX96, bidLiquidity, false)
                : SqrtPriceMath.getAmount1Delta(sqrtLowerX96, sqrtUpperX96, bidLiquidity, false);
        }
        _seedLaunchPosition(
            self,
            manager,
            key,
            sqrtPriceX96,
            tokenIs0 ? bidEdgeTick + key.tickSpacing : TickMath.minUsableTick(key.tickSpacing),
            tokenIs0 ? TickMath.maxUsableTick(key.tickSpacing) : bidEdgeTick - key.tickSpacing,
            tokens,
            tokenIs0,
            keccak256("launch-ask")
        );

        if (tokenCapacity < tokenSupply - tokens) revert InvalidLiquidity();
        (uint256 amount0, uint256 amount1) = tokenIs0 ? (tokens, quote) : (quote, tokens);
        deposit(manager, key.currency0, amount0);
        deposit(manager, key.currency1, amount1);
        _settleFunding(self, manager, key, tokenIs0, amount0, amount1);
    }

    /// @notice Withdraws tracked positions and sends proceeds and tracked dust to the destination.
    /// @dev Runs during the hook's PoolManager unlock. Position removal rounds principal down.
    /// PoolManager keeps the rounding remainder. Fee claims and untracked direct transfers stay
    /// in the source hook. Snapshots contain one to four positions.
    /// @param self Calling hook's tracked inventory for the pool.
    /// @param manager PoolManager holding the positions.
    /// @param key Pool whose positions are withdrawn.
    /// @param tokenIs0 Whether the market token is currency0.
    /// @param destination Recipient of position proceeds and tracked dust.
    /// @return positions Source ranges, liquidity units and proceeds in currency base units.
    /// @return amount0 Total transferred currency0 base units, including dust.
    /// @return amount1 Total transferred currency1 base units, including dust.
    function withdraw(
        Inventory storage self,
        IPoolManager manager,
        PoolKey memory key,
        bool tokenIs0,
        address destination
    )
        public
        returns (IBlockHook.MigrationPosition[] memory positions, uint256 amount0, uint256 amount1)
    {
        uint256 count = self.positions.length;
        if (count == 0 || count > 4) revert InvalidLiquidity();
        positions = new IBlockHook.MigrationPosition[](count);
        for (uint256 i; i < count; ++i) {
            Position memory position = self.positions[i];
            (BalanceDelta delta,) = manager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: position.lower,
                    tickUpper: position.upper,
                    liquidityDelta: -int256(uint256(position.liquidity)),
                    salt: position.salt
                }),
                ""
            );
            if (delta.amount0() < 0 || delta.amount1() < 0) revert InvalidLiquidity();
            uint256 received0 = uint256(int256(delta.amount0()));
            uint256 received1 = uint256(int256(delta.amount1()));
            positions[i] = IBlockHook.MigrationPosition(
                position.lower,
                position.upper,
                position.salt,
                position.liquidity,
                received0,
                received1
            );
            amount0 += received0;
            amount1 += received1;
        }
        uint256 dust0 = tokenIs0 ? self.dust : self.quoteDust;
        uint256 dust1 = tokenIs0 ? self.quoteDust : self.dust;
        delete self.positions;
        self.dust = 0;
        self.quoteDust = 0;
        CurrencySettler.settle(key.currency0, manager, address(this), dust0, true);
        CurrencySettler.settle(key.currency1, manager, address(this), dust1, true);
        amount0 += dust0;
        amount1 += dust1;
        CurrencySettler.take(key.currency0, manager, destination, amount0, true);
        CurrencySettler.take(key.currency1, manager, destination, amount1, true);
    }

    /// @notice Records a migration snapshot and initializes its pool at the source price.
    /// @dev The factory supplies a trusted snapshot from the same PoolManager after transferring
    /// its funds. Runs before the hook's restoration unlock.
    /// @param keys Calling hook's pool keys.
    /// @param configs Calling hook's market configurations.
    /// @param states Calling hook's custody, bonding and launch-window state.
    /// @param policies Calling hook's snapshotted launch-window settings.
    /// @param tokensOfPools Calling hook's active pool-to-token registrations.
    /// @param manager PoolManager shared by the source and destination.
    /// @param token Market token identified by the snapshot.
    /// @param encodedSnapshot ABI-encoded funded `IBlockHook.MigrationSnapshot`.
    function stageImport(
        mapping(address => PoolKey) storage keys,
        mapping(address => IBlockHook.PoolConfig) storage configs,
        mapping(address => IBlockHook.PoolState) storage states,
        mapping(address => WindowPolicy) storage policies,
        mapping(bytes32 => address) storage tokensOfPools,
        IPoolManager manager,
        address token,
        bytes memory encodedSnapshot
    ) public {
        IBlockHook.MigrationSnapshot memory snapshot =
            abi.decode(encodedSnapshot, (IBlockHook.MigrationSnapshot));
        PoolKey memory key = snapshot.sourceKey;
        key.hooks = IHooks(address(this));
        bytes32 poolId = PoolId.unwrap(key.toId());
        if (
            token == address(0) || configs[token].token != address(0)
                || tokensOfPools[poolId] != address(0) || snapshot.config.token != token
                || Currency.unwrap(snapshot.config.tokenIs0 ? key.currency0 : key.currency1) != token
                || Currency.unwrap(snapshot.config.tokenIs0 ? key.currency1 : key.currency0)
                    != snapshot.config.quote
        ) {
            revert IBlockHook.InvalidConfiguration();
        }
        keys[token] = key;
        configs[token] = snapshot.config;
        tokensOfPools[poolId] = token;
        policies[token] = WindowPolicy(snapshot.windowSeconds, snapshot.taxBps, snapshot.capBps);
        states[token] = snapshot.state;
        // PoolManager keeps the withdrawal rounding remainder.
        // Coin custody counts only transferred inventory.
        if (!snapshot.config.isBlock) {
            states[token].custody = snapshot.config.tokenIs0 ? snapshot.amount0 : snapshot.amount1;
        }
        manager.initialize(key, snapshot.sqrtPriceX96);
        emit IBlockHook.PoolRegistered(token, poolId, snapshot.config);
        emit IBlockHook.LiquidityImported(token, poolId, snapshot.amount0, snapshot.amount1);
    }

    /// @notice Restores source ranges from the funds recorded in a migration snapshot.
    /// @dev Runs during the hook's PoolManager unlock after initialization at the snapshot price.
    /// Each position must retain 99.99% to 100% of its recorded liquidity. Unused funds remain
    /// this pool's dust. Fee claims and other pools never fund restoration.
    /// Snapshots contain one to four positions.
    /// @param self Calling hook's empty tracked inventory for the pool.
    /// @param manager PoolManager holding the destination pool.
    /// @param key Initialized destination pool.
    /// @param encodedSnapshot ABI-encoded `IBlockHook.MigrationSnapshot` funded at the hook.
    function restore(
        Inventory storage self,
        IPoolManager manager,
        PoolKey memory key,
        bytes memory encodedSnapshot
    ) public {
        IBlockHook.MigrationSnapshot memory snapshot =
            abi.decode(encodedSnapshot, (IBlockHook.MigrationSnapshot));
        if (self.positions.length != 0) revert AlreadySeeded();
        uint256 count = snapshot.positions.length;
        if (count == 0 || count > 4) revert InvalidLiquidity();
        uint256 allocated0;
        uint256 allocated1;
        for (uint256 i; i < count; ++i) {
            IBlockHook.MigrationPosition memory position = snapshot.positions[i];
            allocated0 += position.amount0;
            allocated1 += position.amount1;
            _fundPosition(self, manager, key, snapshot.sqrtPriceX96, position);
        }
        if (allocated0 > snapshot.amount0 || allocated1 > snapshot.amount1) {
            revert InvalidLiquidity();
        }
        _settleFunding(
            self, manager, key, snapshot.config.tokenIs0, snapshot.amount0, snapshot.amount1
        );
    }

    /// @notice Deposits the calling hook's ERC-20 funding into PoolManager as ERC-6909 claims.
    /// @dev Runs during the hook's PoolManager unlock. Position funding burns claims and the
    /// remaining claims are the tracked dust, so the hook holds no ERC-20 funding at rest.
    /// @param manager PoolManager receiving the funding.
    /// @param currency ERC-20 currency to deposit.
    /// @param amount Funding base units held by the hook.
    function deposit(IPoolManager manager, Currency currency, uint256 amount) public {
        CurrencySettler.settle(currency, manager, address(this), amount, false);
        CurrencySettler.take(currency, manager, address(this), amount, true);
    }

    /// @notice Settles the calling hook's ERC-20 debt to PoolManager.
    /// @dev Runs during the hook's PoolManager unlock. Transfers tokens without using fee claims.
    /// @param manager PoolManager holding the transient currency delta.
    /// @param currency ERC-20 currency. Rejects native currency at `address(0)`.
    function settle(IPoolManager manager, Currency currency) public {
        if (currency.isAddressZero()) revert NativeCurrencyNotSupported();
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) {
            CurrencySettler.settle(currency, manager, address(this), uint256(-delta), false);
        }
    }

    // Views

    /// @notice Encodes a pool's configuration, state and withdrawn migration proceeds.
    /// @dev Linked encoding keeps the hook below the runtime code-size limit.
    /// Reads the hook's mappings after the withdrawal unlock finishes.
    /// @param keys Calling hook's pool keys.
    /// @param configs Calling hook's market configurations.
    /// @param states Calling hook's custody, bonding and launch-window state.
    /// @param policies Calling hook's snapshotted launch-window settings.
    /// @param manager PoolManager supplying the source pool price.
    /// @param token Market token to encode.
    /// @param proceeds ABI-encoded withdrawn positions and currency totals in base units.
    /// @return ABI-encoded `IBlockHook.MigrationSnapshot`.
    function exportSnapshot(
        mapping(address => PoolKey) storage keys,
        mapping(address => IBlockHook.PoolConfig) storage configs,
        mapping(address => IBlockHook.PoolState) storage states,
        mapping(address => WindowPolicy) storage policies,
        IPoolManager manager,
        address token,
        bytes memory proceeds
    ) public view returns (bytes memory) {
        IBlockHook.MigrationSnapshot memory snapshot;
        snapshot.sourceKey = keys[token];
        snapshot.config = configs[token];
        snapshot.state = states[token];
        WindowPolicy memory policy = policies[token];
        snapshot.windowSeconds = policy.seconds_;
        snapshot.taxBps = policy.tax;
        snapshot.capBps = policy.cap;
        (snapshot.sqrtPriceX96,,,) = manager.getSlot0(snapshot.sourceKey.toId());
        (snapshot.positions, snapshot.amount0, snapshot.amount1) =
            abi.decode(proceeds, (IBlockHook.MigrationPosition[], uint256, uint256));
        return abi.encode(snapshot);
    }

    // Internal functions

    function _tickFloor(int24 tick, int24 tickSpacing) private pure returns (int24) {
        unchecked {
            int24 remainder = tick % tickSpacing;
            return remainder >= 0 ? tick - remainder : tick - remainder - tickSpacing;
        }
    }

    function _tickCeil(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 floored = _tickFloor(tick, tickSpacing);
        return floored == tick ? tick : floored + tickSpacing;
    }

    function _seedLaunchPosition(
        Inventory storage inventory,
        IPoolManager poolManager,
        PoolKey memory key,
        uint160 sqrtPriceX96,
        int24 lowerTick,
        int24 upperTick,
        uint256 assetAmount,
        bool isCurrency0,
        bytes32 salt
    ) private returns (uint128) {
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(lowerTick);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(upperTick);
        // Affordable liquidity rounds down. Unused funds remain the hook's tracked dust.
        uint128 liquidity = isCurrency0
            ? LiquidityAmounts.getLiquidityForAmount0(sqrtLowerX96, sqrtUpperX96, assetAmount)
            : LiquidityAmounts.getLiquidityForAmount1(sqrtLowerX96, sqrtUpperX96, assetAmount);
        return _fundPosition(
            inventory,
            poolManager,
            key,
            sqrtPriceX96,
            IBlockHook.MigrationPosition(
                lowerTick,
                upperTick,
                salt,
                liquidity,
                isCurrency0 ? assetAmount : 0,
                isCurrency0 ? 0 : assetAmount
            )
        );
    }

    function _fundPosition(
        Inventory storage inventory,
        IPoolManager poolManager,
        PoolKey memory key,
        uint160 sqrtPriceX96,
        IBlockHook.MigrationPosition memory position
    ) private returns (uint128 liquidity) {
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(position.lower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(position.upper);
        if (sqrtLowerX96 >= sqrtUpperX96 || position.liquidity == 0) revert InvalidLiquidity();
        if (sqrtPriceX96 <= sqrtLowerX96) {
            liquidity = _cappedLiquidity(
                sqrtLowerX96, sqrtUpperX96, position.amount0, true, position.liquidity
            );
        } else if (sqrtPriceX96 >= sqrtUpperX96) {
            liquidity = _cappedLiquidity(
                sqrtLowerX96, sqrtUpperX96, position.amount1, false, position.liquidity
            );
        } else {
            uint128 liquidity0 = _cappedLiquidity(
                sqrtPriceX96, sqrtUpperX96, position.amount0, true, position.liquidity
            );
            uint128 liquidity1 = _cappedLiquidity(
                sqrtLowerX96, sqrtPriceX96, position.amount1, false, position.liquidity
            );
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        }
        if (uint256(liquidity) * 10_000 < uint256(position.liquidity) * 9_999) {
            revert InvalidLiquidity();
        }
        poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: position.lower,
                tickUpper: position.upper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: position.salt
            }),
            ""
        );
        inventory.positions.push(Position(position.lower, position.upper, position.salt, liquidity));
    }

    // Donations can fund liquidity above `uint128`. Return the cap if funded to avoid overflow.
    // Otherwise affordable liquidity is below the cap and fits `uint128`.
    // Required funds round up in PoolManager's favor. Affordable liquidity rounds down,
    // leaving unused funds as the hook's tracked dust.
    function _cappedLiquidity(
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96,
        uint256 assetAmount,
        bool isCurrency0,
        uint128 liquidityCap
    ) private pure returns (uint128) {
        uint256 requiredAmount = isCurrency0
            ? SqrtPriceMath.getAmount0Delta(sqrtLowerX96, sqrtUpperX96, liquidityCap, true)
            : SqrtPriceMath.getAmount1Delta(sqrtLowerX96, sqrtUpperX96, liquidityCap, true);
        if (assetAmount >= requiredAmount) return liquidityCap;
        return isCurrency0
            ? LiquidityAmounts.getLiquidityForAmount0(sqrtLowerX96, sqrtUpperX96, assetAmount)
            : LiquidityAmounts.getLiquidityForAmount1(sqrtLowerX96, sqrtUpperX96, assetAmount);
    }

    function _settleFunding(
        Inventory storage inventory,
        IPoolManager poolManager,
        PoolKey memory key,
        bool tokenIs0,
        uint256 amount0,
        uint256 amount1
    ) private {
        int256 delta0 = poolManager.currencyDelta(address(this), key.currency0);
        int256 delta1 = poolManager.currencyDelta(address(this), key.currency1);
        if (delta0 > 0 || delta1 > 0 || uint256(-delta0) > amount0 || uint256(-delta1) > amount1) {
            revert InvalidLiquidity();
        }
        uint256 dust0 = amount0 - uint256(-delta0);
        uint256 dust1 = amount1 - uint256(-delta1);
        inventory.dust = tokenIs0 ? dust0 : dust1;
        inventory.quoteDust = tokenIs0 ? dust1 : dust0;
        CurrencySettler.settle(key.currency0, poolManager, address(this), uint256(-delta0), true);
        CurrencySettler.settle(key.currency1, poolManager, address(this), uint256(-delta1), true);
    }
}
