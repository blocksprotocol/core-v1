// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IBuxAdapter
/// @notice Invests BUX reserves in one venue and returns them to BUX.
interface IBuxAdapter {
    /// @notice Invests underlying already transferred here by BUX.
    /// @dev Only BUX may call.
    /// @param assets Positive underlying-token base units to invest.
    function deposit(uint256 assets) external;

    /// @notice Returns underlying to BUX, using idle assets first.
    /// @dev Only BUX may call.
    /// @param assets Positive underlying-token base units to return.
    function withdraw(uint256 assets) external;

    /// @notice Transfers the position and idle underlying without redemption.
    /// @dev Only BUX may call.
    /// @param to Recipient of the position and idle underlying.
    function rescue(address to) external;

    /// @notice Returns the BUX contract authorized to move adapter assets.
    /// @return BUX contract bound at deployment.
    function bux() external view returns (address);

    /// @notice Returns the underlying token used for adapter accounting.
    /// @return Underlying token invested and withdrawn.
    function asset() external view returns (address);

    /// @notice Returns idle underlying plus the value of the invested position.
    /// @return Total value in underlying-token base units.
    function balance() external view returns (uint256);

    /// @notice Returns the amount immediately available for withdrawal to BUX.
    /// @return Withdrawable underlying-token base units, including idle. Zero means unavailable.
    function maxWithdraw() external view returns (uint256);
}
