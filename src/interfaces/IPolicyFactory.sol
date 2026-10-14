// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IPolicyFactory
/// @notice Creates a Policy bound to one vault during launch or for an existing Block.
/// @dev During launch, the vault is an uninitialized clone and the Block is not registered.
/// Store the vault without reading it or the registry. Read `vault.token()` when the Policy runs.
interface IPolicyFactory {
    /// @notice Emitted when a Policy is created and bound to a vault.
    /// @param vault Vault receiving the Policy's forwarded assets.
    /// @param policy Newly created Policy address.
    event PolicyCreated(address indexed vault, address indexed policy);

    /// @notice Creates and initializes a Policy for a vault.
    /// @dev Anyone may call.
    /// @param vault Vault to bind. May be uninitialized during launch.
    /// @param data Factory-specific data. Block launches pass `policyFactoryData` unchanged.
    /// @return policy Newly created Policy address.
    function create(address vault, bytes calldata data) external returns (address policy);
}
