// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IBlockRegistry
/// @notice Exposes Block identity and revenue routing for listed factories.
interface IBlockRegistry {
    /// @notice Returns the settings shared by this factory and its jars.
    /// @return Settings contract address.
    function settings() external view returns (address);

    /// @notice Returns the factory that creates each Block's home jar.
    /// @return Jar factory address.
    function jarFactory() external view returns (address);

    /// @notice Returns whether this factory registered a token, including an unfunded Raised Block.
    /// @param token Token to look up.
    /// @return Whether the token is registered.
    function isRegistered(address token) external view returns (bool);

    /// @notice Returns whether the token is a funded Raised Block or a registered staking Block.
    /// @param token Token to look up.
    /// @return Whether the token is an active Block.
    function isBlock(address token) external view returns (bool);

    /// @notice Returns whether this factory registered a staking Block.
    /// @param token Token to look up.
    /// @return Whether the token is a staking Block.
    function isStakingBlock(address token) external view returns (bool);

    /// @notice Returns the Block's revenue-routing configuration.
    /// @dev Raised Blocks use a vault. Staking Blocks use a configuration contract without custody.
    /// Route revenue through the Block's jar.
    /// @param token Token to look up.
    /// @return Routing configuration; zero for unregistered tokens.
    function vaultOf(address token) external view returns (address);

    /// @notice Returns the destination for future creator payments.
    /// @param token Token to look up.
    /// @return Payout destination; zero for unregistered tokens.
    function payoutOf(address token) external view returns (address);

    /// @notice Returns the current Block admin.
    /// @param token Token to look up.
    /// @return Block admin; zero for unregistered tokens.
    function adminOf(address token) external view returns (address);
}
