// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { IForwarderFactory } from "../interfaces/IForwarderFactory.sol";

import { CreatorPayout } from "../CreatorPayout.sol";

/// @title ForwarderFactory
/// @notice Creates deterministic forwarders with fixed routing and payee weights.
/// @dev Matching addresses across chains require matching factory and implementation addresses
/// and deployment inputs, including settings and jar factory addresses.
/// Clone salts bind routing, payees, weights, the protocol fee and implementation.
/// Anyone may create a forwarder. Initialization is atomic and needs no later configuration.
/// @custom:security-contact security@blocks.fm
contract ForwarderFactory is IForwarderFactory {
    /// @inheritdoc IForwarderFactory
    address public immutable implementation;
    /// @inheritdoc IForwarderFactory
    address public immutable settings;
    /// @inheritdoc IForwarderFactory
    address public immutable jarFactory;

    /// @notice Binds settings and the jar factory and creates the implementation at deployment.
    /// @param settings_ Protocol settings used by deployed forwarders.
    /// @param jarFactory_ Jar factory used by deployed forwarders.
    constructor(address settings_, address jarFactory_) {
        settings = settings_;
        jarFactory = jarFactory_;
        implementation = address(new CreatorPayout());
    }

    /// @inheritdoc IForwarderFactory
    function create(Config calldata config, address[] calldata payees, uint16[] calldata weights)
        external
        returns (address forwarder)
    {
        forwarder = predict(config, payees, weights);
        if (forwarder.code.length != 0) return forwarder;
        bytes32 salt = _salt(config, payees, weights);
        forwarder = Clones.cloneDeterministic(implementation, salt);
        CreatorPayout(payable(forwarder)).initializeForwarder(config, payees, weights);
        emit ForwarderCreated(forwarder, salt);
    }

    /// @inheritdoc IForwarderFactory
    function predict(Config calldata config, address[] calldata payees, uint16[] calldata weights)
        public
        view
        returns (address)
    {
        return Clones.predictDeterministicAddress(
            implementation, _salt(config, payees, weights), address(this)
        );
    }

    function _salt(Config calldata config, address[] calldata payees, uint16[] calldata weights)
        private
        view
        returns (bytes32)
    {
        // Partner mode charges 2_000 bps (20%). Other modes charge no protocol fee.
        return keccak256(
            abi.encode(
                config, config.partner ? uint16(2000) : uint16(0), payees, weights, implementation
            )
        );
    }
}
