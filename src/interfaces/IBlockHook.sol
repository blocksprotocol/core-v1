// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IBlockHook
/// @notice Defines Block and Coin market accounting, fee claims and liquidity migration.
/// @dev Swaps, donations and Coin launches respect the factory's market pause. Block pools accept
/// outside liquidity at the pool's tick spacing. Coin pools reject outside additions.
interface IBlockHook is IHooks {
    /// @notice Immutable after launch.
    struct PoolConfig {
        address token;
        address quote;
        bool tokenIs0; // True when the token is currency0 and the quote is currency1.
        bool isBlock; // True for a Block with its own vault. False for a Coin.
        address vault; // Block vault or Coin parent's vault or staking configuration.
        address parentToken; // Parent Block token when it is the quote. Zero for other quotes.
        uint64 launchedAt; // Launch time in Unix seconds. Starts the Coin window.
        // Coin opening edge: lower for token0, upper for token1. Block sale tick for Blocks.
        int24 openingTick;
        // Coin discovery/depth boundary, reversed for token1. Block sale tick for Blocks.
        int24 bondingTick;
    }

    struct PoolState {
        uint256 custody; // Coin inventory, known LP fees and hook-held dust, in token base units.
        bool bonded; // True after funded seeding or when discovery reaches its terminal edge.
        uint64 capSecond; // Unix timestamp in seconds for the purchase counter.
        uint256 soldThisSecond; // Capped, non-prebuy purchases in `capSecond`, in token base units.
    }

    /// @notice Records a source position and its withdrawn principal and LP fees.
    /// Amounts exclude accrued fee claims and vault backing.
    struct MigrationPosition {
        int24 lower; // Inclusive lower position bound in ticks.
        int24 upper; // Exclusive upper position bound in ticks.
        bytes32 salt;
        uint128 liquidity; // Recorded position liquidity units.
        uint256 amount0; // Position proceeds in currency0 base units.
        uint256 amount1; // Position proceeds in currency1 base units.
    }

    struct MigrationSnapshot {
        PoolKey sourceKey;
        PoolConfig config;
        PoolState state;
        uint32 windowSeconds; // Launch-window duration in seconds. Zero disables the window.
        // Initial launch tax in bps of quote after the ordinary fee. Zero disables tax.
        uint16 taxBps;
        // Purchase cap in bps of fixed supply per second. Applies only during the window.
        // Zero allows only prebuys during the window.
        uint16 capBps;
        uint160 sqrtPriceX96; // Square-root currency1/currency0 price, scaled by 2^96.
        MigrationPosition[] positions;
        uint256 amount0; // Position proceeds plus tracked dust, in currency0 base units.
        uint256 amount1; // Position proceeds plus tracked dust, in currency1 base units.
    }

    struct Charge {
        bool isBuy; // True when quote is exchanged for the market token.
        bool exactInput; // True when the swap specifies input instead of output.
        // Pool quote delta in quote base units: net input on buys, gross output on sells.
        uint256 quoteAmount;
        // Gross token base units. Coin custody excludes sell-side PoolManager protocol fees.
        uint256 tokenAmount;
        // Ordinary swap fee on gross quote, in quote base units, before allocation.
        uint256 fee;
        // Coin launch tax in quote base units, allocated to the parent Block's jar.
        uint256 tax;
    }

    /// @notice Emitted when a pool configuration is registered or imported.
    /// @param token Block or Coin token.
    /// @param poolId Registered PoolManager pool identifier.
    /// @param config Fixed market configuration.
    event PoolRegistered(address indexed token, bytes32 indexed poolId, PoolConfig config);

    /// @notice Emitted when funded launch positions are seeded.
    /// @param token Market token.
    /// @param tokens Supplied token base units, including unused dust.
    /// @param quote Supplied quote base units, including unused dust.
    event FundedSeeded(address indexed token, uint256 tokens, uint256 quote);

    /// @notice Emitted when position proceeds and tracked dust are transferred for migration.
    /// @param token Market token.
    /// @param destination Hook receiving the migration funds.
    /// @param amount0 Transferred currency0 base units.
    /// @param amount1 Transferred currency1 base units.
    event LiquidityExported(
        address indexed token, address indexed destination, uint256 amount0, uint256 amount1
    );

    /// @notice Emitted when a funded migration snapshot is staged.
    /// @param token Market token.
    /// @param poolId Destination PoolManager pool identifier.
    /// @param amount0 Snapshot funding in currency0 base units.
    /// @param amount1 Snapshot funding in currency1 base units.
    event LiquidityImported(
        address indexed token, bytes32 indexed poolId, uint256 amount0, uint256 amount1
    );

    /// @notice Emitted when an account's accrued quote fees are paid.
    /// @param account Account whose fee row is debited.
    /// @param asset Quote currency.
    /// @param amount Paid quote base units.
    /// @param to Recipient, equal to the credited account.
    event Claimed(address indexed account, address indexed asset, uint256 amount, address to);

    /// @notice Emitted when an account's accrued quote fees are claimed.
    /// @param token Market token.
    /// @param asset Quote currency.
    /// @param beneficiary Credited account receiving the payment.
    /// @param amount Claimed quote base units, before any transfer tax.
    event FeeSwept(
        address indexed token, address indexed asset, address indexed beneficiary, uint256 amount
    );

    /// @notice Emitted when quote fees accrue to an account.
    /// @param token Market token.
    /// @param asset Quote currency.
    /// @param account Recipient fixed at accrual.
    /// @param amount Credited quote base units.
    event FeeAccrued(
        address indexed token, address indexed asset, address indexed account, uint256 amount
    );

    /// @notice Emitted when a swap's charges and inventory accounting are complete.
    /// @param token Market token.
    /// @param asset Quote currency.
    /// @param charge Pool amounts and hook charges in each field's documented units.
    event SwapCharged(address indexed token, address indexed asset, Charge charge);

    /// @notice Emitted when the ordinary swap fee and launch tax are allocated.
    /// @param token Market token.
    /// @param asset Quote currency.
    /// @param toCreator Creator allocation in quote base units.
    /// @param toVault Block allocation, including Coin launch tax, in quote base units.
    /// @param toFeePool Protocol allocation in quote base units.
    event SwapFeeSplit(
        address indexed token,
        address indexed asset,
        uint256 toCreator,
        uint256 toVault,
        uint256 toFeePool
    );

    /// @notice Emitted when a swap first reaches the discovery range's terminal edge.
    /// @param token Market token.
    /// @param poolId PoolManager pool identifier.
    event Bonded(address indexed token, bytes32 indexed poolId);

    /// @notice Emitted when a swap records optional app attribution.
    /// @param token Market token.
    /// @param appId Unauthenticated app ID. Zero if absent or the payload length is invalid.
    /// @param router Caller of `PoolManager.swap`; the hook itself for factory prebuys.
    event SwapAttributed(address indexed token, bytes32 indexed appId, address indexed router);

    /// @notice Thrown when the caller is not the bound PoolManager.
    error OnlyPoolManager();

    /// @notice Thrown when a restricted caller or pool initializer is not the factory.
    error OnlyFactory();

    /// @notice Thrown when the token or pool is not registered for the requested operation.
    error UnknownPool();

    /// @notice Thrown when the token or pool is already registered.
    error PoolAlreadyRegistered();

    /// @notice Thrown when an outside caller adds liquidity to a Coin pool.
    error LiquidityNotAllowed();

    /// @notice Thrown when configuration, a seed amount or a fee recipient is invalid.
    error InvalidConfiguration();

    /// @notice Thrown when a swap or unlock conflicts with an active operation.
    error NestedSwap();

    /// @notice Thrown when the pool delta differs from the full fill required after hook charges.
    error PartialFill();

    /// @notice Thrown when the specified amount is invalid or charges leave no pool input.
    error InvalidSwap();

    /// @notice Thrown when a swap has a zero token or quote delta.
    error ZeroOutput();

    /// @notice Thrown when an unlock operation or swap callback context is invalid.
    error InvalidCallback();

    /// @notice Thrown when the caller is not the Safe.
    error OnlySafe();

    // Launch

    /// @notice Registers a Block market funded by its batch sale without a launch window.
    /// @dev Only the factory may call. The pool must not yet be initialized.
    /// @param token Block token.
    /// @param key Pool key whose hook must be this contract.
    /// @param config Fixed Block market configuration.
    function registerFunded(address token, PoolKey calldata key, PoolConfig calldata config)
        external;

    /// @notice Funds launch bids and an ask from amounts transferred by the factory.
    /// @dev Only the factory may call, even while paused. The pool must be initialized.
    /// Bids must cover supply outside supplied token inventory. Unused funds remain tracked dust.
    /// @param token Registered market token.
    /// @param tokenAmount Prefunded token base units.
    /// @param quoteAmount Prefunded quote base units.
    function seedFunded(address token, uint256 tokenAmount, uint256 quoteAmount) external;

    // Migration

    /// @notice Withdraws tracked positions and sends proceeds and tracked dust to the destination.
    /// @dev Only the factory may call. It selects a trusted destination using the same PoolManager.
    /// Accrued claims and untracked direct transfers stay in the source hook.
    /// @param token Registered market token.
    /// @param destination Trusted hook receiving the migration funds.
    /// @return snapshot ABI-encoded `MigrationSnapshot` with configuration, positions and
    /// transferred funds.
    function exportLiquidity(address token, address destination)
        external
        returns (bytes memory snapshot);

    /// @notice Restores a funded migration snapshot into the destination pool.
    /// @dev Only the factory may call. The snapshot's funds must already be transferred.
    /// The pool initializes at the snapshot price. Each range must retain at least 99.99% of its
    /// liquidity. Block snapshots must have zero launch-window fields.
    /// @param token Market token identified by the snapshot.
    /// @param snapshot ABI-encoded `MigrationSnapshot` from a trusted source using the same
    /// PoolManager.
    /// @return fee Destination LP fee in hundredths of a bp (1_000_000 = 100%).
    /// @return tickSpacing Destination spacing in ticks. The factory retains the currencies.
    function importLiquidity(address token, bytes calldata snapshot)
        external
        returns (uint24 fee, int24 tickSpacing);

    // Claims

    /// @notice Pays accrued quote fees to the credited account.
    /// @dev Anyone may call. Payout changes preserve existing recipients' accruals.
    /// @param token Registered market token.
    /// @param account Credited recipient. Rejects zero, which is reserved for Policy claims.
    /// @return amount Paid quote base units. Zero when the account has no accrual.
    function claimPoolFees(address token, address account) external returns (uint256 amount);

    // Views

    /// @notice Returns the current Safe through the fixed factory.
    /// @return Current Safe.
    function safe() external view returns (address);

    /// @notice Returns the callback permissions encoded in the hook address.
    /// @return Enabled callbacks and return-delta permissions.
    function getHookPermissions() external pure returns (Hooks.Permissions memory);

    /// @notice Returns tracked funds held outside the pool's positions.
    /// @dev Excludes untracked direct transfers.
    /// @param token Market token.
    /// @return tokenDust Tracked token base units.
    /// @return quoteDust Tracked quote base units.
    function inventoryDust(address token)
        external
        view
        returns (uint256 tokenDust, uint256 quoteDust);

    /// @notice Returns the registered pool configuration.
    /// @param token Market token.
    /// @return Fixed configuration. All fields are zero for an unknown token.
    function poolConfig(address token) external view returns (PoolConfig memory);

    /// @notice Returns custody, bonding status and launch-window counters.
    /// @param token Market token.
    /// @return Tracked state. All fields are zero for an unknown token.
    function poolState(address token) external view returns (PoolState memory);

    /// @notice Returns the stored pool key, retained after liquidity export.
    /// @param token Market token.
    /// @return Stored currencies, fee, spacing and hook. All fields are zero for an unknown token.
    function poolKeyOf(address token) external view returns (PoolKey memory);

    /// @notice Returns the current PoolManager square-root price.
    /// @param token Market token.
    /// @return Square-root currency1/currency0 price, scaled by 2^96. Zero before initialization.
    function spotSqrtPriceX96(address token) external view returns (uint160);

    /// @notice Returns the current quote price per 10^18 token base units.
    /// @dev Rounds the currency1/currency0 ratio down at Q128 (2^128) precision, then rounds the
    /// final conversion down. Rounding before inversion can overstate the reciprocal price.
    /// No funds move.
    /// @param token Market token.
    /// @return Quote base units per 10^18 token base units.
    function spot(address token) external view returns (uint256);

    /// @notice Returns the current FeePool through the fixed factory.
    /// @return Protocol fee recipient.
    function feePool() external view returns (address);

    /// @notice Returns the PoolManager bound at deployment.
    /// @return Fixed PoolManager.
    function poolManager() external view returns (IPoolManager);

    /// @notice Returns the fixed factory authorized for registration, funding and migration.
    /// @return Factory bound at deployment.
    function factory() external view returns (address);

    /// @notice Returns the BUX token bound at deployment.
    /// @return BUX token with 6 decimals.
    function bux() external view returns (address);

    /// @notice Returns accrued quote fees for a token and account.
    /// @dev For Blocks, the zero-account row holds Block allocations until `claimPolicy` or, with
    /// a zero Policy, a later swap delivers them. Coin protocol and Block allocations use
    /// `pendingFees`.
    /// @param token Market token whose quote currency denominates the row.
    /// @param account Credited recipient. Zero selects the reserved Block Policy row.
    /// @return Accrued quote base units backed by hook-owned PoolManager claims.
    function earned(address token, address account) external view returns (uint256);
}
