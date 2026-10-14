// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title ICoinAttribution
/// @notice Records a Coin's claimed parent Block and revenue source.
/// @dev External launchpads may emit this event.
interface ICoinAttribution {
    /// @notice Emitted when a Coin is attributed to a parent Block and revenue source.
    /// @dev The emitter's claimed association is unverified.
    /// @param token Coin token.
    /// @param parent Claimed parent Block token on its home chain.
    /// @param source Unverified attribution label. Zero means unattributed.
    /// @param homeChainId Claimed parent Block's home EVM chain ID.
    /// @param metadataURI Metadata location from the emitter. May be empty.
    event CoinAttributed(
        address indexed token,
        address indexed parent,
        address indexed source,
        uint256 homeChainId,
        string metadataURI
    );
}
