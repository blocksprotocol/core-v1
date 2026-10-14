// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { IJarFactory } from "../interfaces/IJarFactory.sol";
import { IProtocolSettings } from "../interfaces/IProtocolSettings.sol";

import { Jar } from "./Jar.sol";

/// @title JarFactory
/// @notice Creates deterministic jars for a Block's home chain and token.
/// @dev Matching addresses across chains require matching factory and implementation addresses
/// and deployment inputs, including the settings address. Creation and initialization are atomic.
/// Anyone may create a jar. No later configuration is needed.
/// @custom:security-contact security@blocks.fm
contract JarFactory is IJarFactory {
    /// @notice Returns the jar implementation cloned by this factory.
    /// @return Fixed implementation with initialization locked.
    address public immutable implementation;
    /// @inheritdoc IJarFactory
    address public immutable settings;

    /// @notice Binds settings and deploys the jar implementation at factory deployment.
    /// @param settings_ Protocol settings address with deployed code.
    constructor(address settings_) {
        if (settings_.code.length == 0) revert InvalidSettings();
        settings = settings_;
        implementation = address(new Jar(address(this), IProtocolSettings(settings_)));
    }

    /// @inheritdoc IJarFactory
    function create(uint256 homeChainId, address token) external returns (address jar) {
        jar = predict(homeChainId, token);
        if (jar.code.length != 0) return jar;
        jar = Clones.cloneDeterministic(implementation, keccak256(abi.encode(homeChainId, token)));
        Jar(payable(jar)).initialize(homeChainId, token);
        emit JarCreated(homeChainId, token, jar);
    }

    /// @inheritdoc IJarFactory
    function predict(uint256 homeChainId, address token) public view returns (address) {
        return Clones.predictDeterministicAddress(
            implementation, keccak256(abi.encode(homeChainId, token)), address(this)
        );
    }
}
