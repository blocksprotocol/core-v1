// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title HookMigrationRegistry
/// @notice Records migration paths authorized by the migration registry owner.
/// @dev Registration trusts the destination without checking its code or custody compatibility.
/// Ownership transfers in two steps and does not track later Safe changes.
/// @custom:security-contact security@blocks.fm
contract HookMigrationRegistry is Ownable2Step {
    /// @notice Returns whether a directed hook path is authorized.
    /// @dev Keys are the source hook, then the destination hook.
    /// @return Whether the directed path is registered.
    mapping(address => mapping(address => bool)) public isAllowedHookUpgrade;

    /// @notice Emitted when the migration registry owner registers a directed migration path,
    /// including repeated registrations.
    /// @param fromImpl Source hook implementation.
    /// @param toImpl Destination hook implementation.
    event UpgradeRegistered(address fromImpl, address toImpl);
    /// @notice Emitted when the migration registry owner removes a directed migration path,
    /// including repeated removals.
    /// @param fromImpl Source hook implementation.
    /// @param toImpl Destination hook implementation.
    event UpgradeRemoved(address fromImpl, address toImpl);

    /// @notice Binds the migration registry owner once at deployment.
    /// @dev The creating factory supplies its Safe at deployment.
    /// @param owner Initial migration registry owner.
    constructor(address owner) Ownable(owner) { }

    /// @notice Registers directed paths from each source to a destination.
    /// @dev Only the migration registry owner may call. Reverse paths need separate authorization.
    /// @param baseImpls Source hook implementations.
    /// @param upgradeImpl Destination hook implementation.
    function registerUpgradePath(address[] memory baseImpls, address upgradeImpl)
        external
        onlyOwner
    {
        for (uint256 i = 0; i < baseImpls.length; i++) {
            isAllowedHookUpgrade[baseImpls[i]][upgradeImpl] = true;
            emit UpgradeRegistered(baseImpls[i], upgradeImpl);
        }
    }

    /// @notice Removes a directed migration path.
    /// @dev Only the migration registry owner may call. The reverse path is unaffected.
    /// @param baseImpl Source hook implementation.
    /// @param upgradeImpl Destination hook implementation.
    function removeUpgradePath(address baseImpl, address upgradeImpl) external onlyOwner {
        isAllowedHookUpgrade[baseImpl][upgradeImpl] = false;
        emit UpgradeRemoved(baseImpl, upgradeImpl);
    }

    /// @notice Returns whether a directed migration path is authorized.
    /// @param baseImpl Source hook implementation.
    /// @param upgradeImpl Destination hook implementation.
    /// @return Whether migration is authorized.
    function isRegisteredUpgradePath(address baseImpl, address upgradeImpl)
        external
        view
        returns (bool)
    {
        return isAllowedHookUpgrade[baseImpl][upgradeImpl];
    }
}
