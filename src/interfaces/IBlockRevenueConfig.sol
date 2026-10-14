// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IBlockRevenueConfig
/// @notice Exposes revenue routing for Raised vaults and staking configurations.
/// @dev Staking configurations expose fixed routing metadata.
interface IBlockRevenueConfig {
    /// @notice Returns the current Policy destination.
    /// @return Destination address; zero selects direct vault delivery.
    function policy() external view returns (address);

    /// @notice Returns whether an extra asset is admitted for new home-chain receipts.
    /// @param asset Asset to check. BUX is not an extra.
    /// @return Whether the extra is admitted.
    function isRetained(address asset) external view returns (bool);

    /// @notice Returns occupied extra slots, including disabled Raised slots awaiting retirement.
    /// @return Extra-asset addresses, including those with no current claim.
    function extras() external view returns (address[] memory);
}
