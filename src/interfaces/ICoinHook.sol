// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { IBlockHook } from "./IBlockHook.sol";

/// @title ICoinHook
/// @notice Defines Coin launch funding, launch windows and deferred fees for parent jars.
interface ICoinHook is IBlockHook {
    /// @notice Emitted when token inventory funds discovery and depth positions.
    /// @param token Coin token.
    /// @param discoveryTokens Discovery allocation in 18-decimal token base units.
    /// @param depthTokens Depth allocation in 18-decimal token base units.
    event Seeded(address indexed token, uint256 discoveryTokens, uint256 depthTokens);

    /// @notice Emitted when a factory-funded prebuy sends tokens to escrow.
    /// @param token Coin token.
    /// @param quoteIn Gross prefunded quote base units, including the ordinary swap fee.
    /// @param tokensOut Purchased 18-decimal token base units.
    /// @param escrow Recipient of the purchased tokens.
    event Prebought(address indexed token, uint256 quoteIn, uint256 tokensOut, address escrow);

    /// @notice Emitted when a nonzero protocol fee allocation is transferred to FeePool.
    /// @dev A taxed quote token can deliver less than the allocation sent.
    /// @param token Coin token.
    /// @param asset Quote token.
    /// @param feePool FeePool recipient.
    /// @param amount Allocation sent in quote base units, before any transfer tax.
    event ProtocolFeeSwept(
        address indexed token, address indexed asset, address indexed feePool, uint256 amount
    );

    /// @notice Emitted when a nonzero Block fee allocation is deposited into its jar.
    /// @dev Transfer tax can reduce the receipt. The jar's `BlockRevenue` records its receipt.
    /// @param token Coin token.
    /// @param asset Quote token.
    /// @param jar Parent jar.
    /// @param amount Allocation sent in quote base units, before any transfer tax.
    event BlockFeeSwept(
        address indexed token, address indexed asset, address indexed jar, uint256 amount
    );

    /// @notice Emitted when launch-window defaults are set for future registrations.
    /// @param windowSeconds Window duration in seconds.
    /// @param tax0Bps Initial launch tax in bps of quote after the ordinary fee.
    /// @param capBps Purchase cap in bps of fixed supply per second.
    event WindowParamsSet(uint32 windowSeconds, uint16 tax0Bps, uint16 capBps);

    /// @notice Thrown when non-prebuy purchases exceed the launch-window cap for one second.
    error CapExceeded();

    // Launch

    /// @notice Records a Coin pool before PoolManager initialization.
    /// @dev Only the factory may call. Snapshots launch-window defaults and permits initialization.
    /// @param token Coin token.
    /// @param key Pool key whose hook must be this contract.
    /// @param config Fixed Coin configuration, including the launch time in Unix seconds.
    function register(address token, PoolKey calldata key, PoolConfig calldata config) external;

    /// @notice Seeds discovery with 80% of the fixed supply and depth with the remainder.
    /// @dev Only the factory may call. Markets must be active. The hook must hold the full supply,
    /// and the pool must be initialized at its opening tick. Discovery allocation rounds down.
    /// Depth receives the remainder. Unused funds remain tracked dust.
    /// @param token Registered Coin token.
    /// @param tokens Full fixed supply in 18-decimal token base units.
    function seed(address token, uint256 tokens) external;

    /// @notice Executes a factory-funded exact-input buy without launch tax or the purchase cap.
    /// @dev Only the factory may call. Markets must be active and the hook must hold the quote
    /// funding. The ordinary swap fee applies. Purchased tokens go to escrow.
    /// @param token Registered Coin token.
    /// @param quoteIn Prefunded quote base units, including the ordinary swap fee.
    /// @param escrow Recipient of the purchased tokens.
    /// @return tokensOut Purchased 18-decimal token base units.
    function prebuy(address token, uint256 quoteIn, address escrow)
        external
        returns (uint256 tokensOut);

    // Claims

    /// @notice Redeems a Coin's protocol and Block fee allocations.
    /// @dev Anyone may call. Protocol fees go to FeePool. The Block allocation, including launch
    /// tax, goes to the parent's jar in kind.
    /// @param token Registered Coin token.
    /// @return amount Total redeemed quote base units. Zero when neither allocation has accrued.
    function sweepVault(address token) external returns (uint256 amount);

    // Settings

    /// @notice Sets launch-window defaults for future registrations.
    /// @dev Only the Safe may call. Registered pools retain their snapshot.
    /// Launch tax decays linearly and rounds down to whole bps in the buyer's favor.
    /// Prebuys are exempt. 10_000 bps = 100%.
    /// @param windowSeconds Window duration, from one to 3,600 seconds.
    /// @param tax0Bps Initial launch tax, from one to 9,000 bps of quote after the ordinary fee.
    /// @param capBps Purchase cap, from one to 2,000 bps of fixed supply per second.
    function setWindowParams(uint32 windowSeconds, uint16 tax0Bps, uint16 capBps) external;

    // Views

    /// @notice Returns Coin tokens outside tracked hook custody.
    /// @dev Includes escrowed tokens. The result is informational.
    /// @param token Coin token.
    /// @return Token base units outside custody.
    function circulating(address token) external view returns (uint256);

    /// @notice Returns inventory in hook positions, known LP fees and hook-held dust.
    /// @param token Coin token.
    /// @return Tracked token base units. Zero for an unknown token.
    function custodyOf(address token) external view returns (uint256);

    /// @notice Returns launch-window settings snapshotted for a pool.
    /// @param token Coin token.
    /// @return seconds_ Window duration in seconds. Zero disables the window.
    /// @return tax Initial launch tax in bps of quote after the ordinary fee. Zero disables tax.
    /// @return cap Purchase cap in bps of fixed supply per second. Applies only during the window.
    /// Zero allows only prebuys during the window.
    function windowPolicy(address token)
        external
        view
        returns (uint32 seconds_, uint16 tax, uint16 cap);

    /// @notice Returns the default launch-window duration for future registrations.
    /// @return Mutable duration in seconds.
    function WINDOW() external view returns (uint32);

    /// @notice Returns the default initial launch tax rate for future registrations.
    /// @return Mutable rate in bps of quote after the ordinary fee.
    function TAX0_BPS() external view returns (uint16);

    /// @notice Returns the default purchase cap for future registrations.
    /// @return Mutable cap in bps of fixed supply per second.
    function CAP_BPS() external view returns (uint16);

    /// @notice Returns pending protocol or Block allocations for a Coin.
    /// @param token Coin token.
    /// @param account `address(0)` for the Block and launch tax, `address(1)` for the protocol.
    /// @return Pending quote base units. Other rows remain zero.
    function pendingFees(address token, address account) external view returns (uint256);
}
