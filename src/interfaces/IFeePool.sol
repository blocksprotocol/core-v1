// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IFeePool
/// @notice Splits current balances between two configured recipients.
interface IFeePool {
    /// @notice Emitted when the current asset balance is distributed.
    /// @param asset Distributed asset; zero denotes native currency.
    /// @param toTreasury Treasury payment in asset base units, or wei for native currency.
    /// @param toProtocolValue Protocol-value payment in asset base units, or wei for native
    /// currency.
    /// @param caller Account requesting distribution.
    event Distributed(
        address indexed asset, uint256 toTreasury, uint256 toProtocolValue, address indexed caller
    );
    /// @notice Emitted when the Safe replaces recipients and the split.
    /// @param treasury Treasury recipient.
    /// @param protocolValue Protocol-value recipient.
    /// @param treasuryBps Treasury share of gross balances in bps, with 10_000 bps = 100%.
    event SplitSet(address treasury, address protocolValue, uint16 treasuryBps);

    /// @notice Thrown when either configured recipient is zero.
    error ZeroRecipient();
    /// @notice Thrown when the treasury share exceeds 10_000 bps.
    error InvalidConfiguration();
    /// @notice Thrown when the caller is not the current Safe.
    /// @param account Unauthorized caller.
    error OwnableUnauthorizedAccount(address account);

    /// @notice Distributes the current balance to the configured recipients.
    /// @dev Anyone may call. The treasury share rounds down. Protocol value receives the remainder.
    /// A failed transfer reverts all payments. Receiving funds does not trigger distribution.
    /// @param asset Asset to distribute; zero selects native currency.
    /// @return amount Balance before payments, in asset base units or native wei.
    function distribute(address asset) external returns (uint256 amount);

    /// @notice Replaces recipients and the treasury share.
    /// @dev Only the Safe may call. Recipients must be nonzero and may coincide.
    /// The split applies to all undistributed balances. Changing it requires no prior distribution.
    /// @param treasury Nonzero treasury recipient.
    /// @param protocolValue Nonzero protocol-value recipient.
    /// @param treasuryBps_ Treasury share of gross balances in bps, from zero to 10_000.
    function setSplit(address treasury, address protocolValue, uint16 treasuryBps_) external;

    /// @notice Returns the current treasury recipient.
    /// @return Treasury payment destination.
    function treasuryRecipient() external view returns (address);

    /// @notice Returns the current protocol-value recipient.
    /// @return Protocol-value payment destination.
    function protocolValueRecipient() external view returns (address);

    /// @notice Returns the treasury share of the gross distributed balance.
    /// @return Treasury share in bps, with 10_000 bps = 100%.
    function treasuryBps() external view returns (uint16);
}
