// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IBlockRevenue
/// @notice Defines receipt attribution for jars and forwarders.
interface IBlockRevenue {
    /// @notice Emitted when gross receipts are recognized before fees and routing.
    /// @dev A forwarder and jar can report the same funds at successive stages.
    /// Internal jar reclassification emits no new revenue.
    /// @param homeChainId Chain ID of the Block's home chain.
    /// @param token Block token on its home chain.
    /// @param asset Received asset; zero denotes native currency.
    /// @param gross Gross receipts in asset base units, or wei for native currency.
    /// @param source Claimed attribution label; zero denotes unattributed receipts.
    event BlockRevenue(
        uint256 indexed homeChainId,
        address indexed token,
        address indexed asset,
        uint256 gross,
        address source
    );
}
