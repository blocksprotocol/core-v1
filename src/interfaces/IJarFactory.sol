// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IJarFactory
/// @notice Creates deterministic jars for a Block's home chain and token.
interface IJarFactory {
    /// @notice Emitted when a jar is created and initialized.
    /// @param homeChainId Home EVM chain ID.
    /// @param token Block's home token address.
    /// @param jar Deployed jar address.
    event JarCreated(uint256 indexed homeChainId, address indexed token, address jar);

    /// @notice Thrown when the settings address has no deployed code.
    error InvalidSettings();

    /// @notice Creates and initializes a jar, or returns the existing jar.
    /// @dev Anyone may call.
    /// @param homeChainId Home EVM chain ID.
    /// @param token Block's home token address.
    /// @return jar Initialized deterministic jar.
    function create(uint256 homeChainId, address token) external returns (address jar);

    /// @notice Returns the protocol settings fixed at factory deployment.
    /// @return Settings used by this factory's jars.
    function settings() external view returns (address);

    /// @notice Predicts the jar address for a home chain and token without deploying it.
    /// @param homeChainId Home EVM chain ID.
    /// @param token Block's home token address.
    /// @return Deterministic jar address, whether deployed or not.
    function predict(uint256 homeChainId, address token) external view returns (address);
}
