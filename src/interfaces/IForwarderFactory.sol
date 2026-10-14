// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IForwarderFactory
/// @notice Creates deterministic forwarders with fixed routing and payee weights.
interface IForwarderFactory {
    struct Config {
        // Home EVM chain ID. Zero is invalid.
        uint256 homeChainId;
        // Block's home token address. Zero is invalid.
        address token;
        // Gross receipt share split among the fee, creator and jar, in bps. 10_000 bps = 100%.
        uint16 jarBps;
        // Creator share of the jar allocation after the fee, in bps. Zero sends it to the jar.
        uint16 creatorBps;
        // Unverified revenue attribution label. Zero means unattributed.
        address source;
        // Enables the 2_000 bps (20%) fee on jar and payee legs. False means no fee.
        bool partner;
    }

    /// @notice Emitted when a forwarder is created and initialized.
    /// @param forwarder Deployed payout clone.
    /// @param salt Deployment salt binding routing, payees, weights, fee and implementation.
    event ForwarderCreated(address indexed forwarder, bytes32 indexed salt);

    /// @notice Creates and initializes the configured forwarder, or returns the existing forwarder.
    /// @dev Anyone may call. Nonzero `creatorBps` requires the home chain.
    /// Nonempty payee arrays must match the weights array's length and contain one to 16 unique
    /// addresses above `address(1)`, excluding the forwarder.
    /// @param config Fixed routing configuration. Rates must not exceed 10_000 bps (100%).
    /// @param payees Recipients. May be empty only when `jarBps` is 10_000 bps.
    /// @param weights Positive payee weights in bps, summing to 10_000 for nonempty payees.
    /// @return Initialized deterministic forwarder.
    function create(Config calldata config, address[] calldata payees, uint16[] calldata weights)
        external
        returns (address);

    /// @notice Returns the fixed payout implementation cloned for forwarders.
    /// @return Implementation deployed by this factory.
    function implementation() external view returns (address);

    /// @notice Returns the protocol settings fixed at factory deployment.
    /// @return Settings used by deployed forwarders.
    function settings() external view returns (address);

    /// @notice Returns the jar factory used by deployed forwarders.
    /// @return Jar factory fixed at deployment.
    function jarFactory() external view returns (address);

    /// @notice Predicts the address bound to a routing configuration and payee weights.
    /// @dev Prediction does not check whether initialization can succeed.
    /// @param config Routing configuration included in the deployment salt.
    /// @param payees Ordered recipients included in the deployment salt.
    /// @param weights Ordered payee weights in bps included in the deployment salt.
    /// @return Predicted forwarder address, whether deployed or not.
    function predict(Config calldata config, address[] calldata payees, uint16[] calldata weights)
        external
        view
        returns (address);
}
