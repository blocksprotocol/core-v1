// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IVestingEscrow
/// @notice Vests launch tokens after an optional cliff and releases to the current payout.
/// @dev Escrowed tokens remain in outstanding supply. Redemption requires release.
interface IVestingEscrow {
    /// @notice Emitted when vested tokens are paid to the current payout destination.
    /// @param to Payout destination resolved at release.
    /// @param amount Released token base units (18 decimals).
    /// @param totalReleased Cumulative released token base units (18 decimals).
    event Released(address indexed to, uint256 amount, uint256 totalReleased);

    /// @notice Thrown when initialization is attempted on an initialized or locked escrow.
    error AlreadyInitialized();
    /// @notice Thrown when factory wiring, funding, allocation or the vesting schedule is invalid.
    error InvalidInitialization();
    /// @notice Thrown when no vested tokens are available to release.
    error NothingToRelease();
    /// @notice Thrown when the current payout is zero or the escrow itself.
    error InvalidRecipient();

    // Initialization

    /// @notice Initializes a funded clone once.
    /// @dev Only the token's factory may call, and it must match the supplied factory.
    /// The cliff cannot precede initialization. Vesting ends at or after the cliff,
    /// within 1,825 days of initialization.
    /// @param token_ Token held for vesting.
    /// @param factory_ Calling factory whose registry resolves the payout.
    /// @param total_ Nonzero funded allocation in token base units (18 decimals).
    /// @param cliffEnd_ Start of linear vesting in Unix seconds.
    /// @param vestEnd_ Full-vesting time in Unix seconds. Equal to the cliff to vest all at once.
    function initialize(
        address token_,
        address factory_,
        uint256 total_,
        uint64 cliffEnd_,
        uint64 vestEnd_
    ) external;

    // Release

    /// @notice Pays unreleased vested tokens to the current registry payout.
    /// @dev Anyone may call. A zero or escrow recipient reverts without consuming entitlement.
    /// The token's admin can correct the payout. Payout changes redirect all unreleased tokens,
    /// including vested amounts. Transferring admin alone does not change the payout.
    /// A weighted payout holds the tokens until `distribute` allocates them.
    /// @return amount Released token base units (18 decimals).
    function release() external returns (uint256 amount);

    // Views

    /// @notice Returns cumulative vested tokens without subtracting releases.
    /// @dev Vesting is zero before the cliff, linear afterward and complete at the end.
    /// Linear vesting rounds down. The escrow keeps the remainder until later vesting.
    /// A zero-length linear period vests the full allocation at the cliff.
    /// @return Cumulative vested token base units (18 decimals).
    function vested() external view returns (uint256);

    /// @notice Returns vested tokens minus cumulative releases.
    /// @return Unreleased vested token base units (18 decimals).
    function releasable() external view returns (uint256);

    /// @notice Returns the token held for vesting.
    /// @return Vested token address.
    function token() external view returns (address);

    /// @notice Returns the factory whose registry resolves the current payout.
    /// @return Factory address.
    function factory() external view returns (address);

    /// @notice Returns the allocation fixed at initialization.
    /// @dev Later receipts do not increase entitlement.
    /// @return Allocation in token base units (18 decimals).
    function total() external view returns (uint256);

    /// @notice Returns cumulative released tokens.
    /// @return Released token base units (18 decimals).
    function released() external view returns (uint256);

    /// @notice Returns the start of linear vesting.
    /// @return Cliff end in Unix seconds.
    function cliffEnd() external view returns (uint64);

    /// @notice Returns the time when the full allocation is vested.
    /// @return Vesting end in Unix seconds. Equal to the cliff for full vesting there.
    function vestEnd() external view returns (uint64);
}
