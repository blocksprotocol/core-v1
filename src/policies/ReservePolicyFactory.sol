// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.37;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IBlockVault } from "../interfaces/IBlockVault.sol";
import { IBuybackConfig } from "../interfaces/IBuybackConfig.sol";
import { IPolicyFactory } from "../interfaces/IPolicyFactory.sol";

import { ReservePolicy } from "./ReservePolicy.sol";

/// @title ReservePolicyFactory
/// @notice Creates a Policy that buys reserves for one vault.
/// @dev Each call deploys and initializes a new clone. The factory cannot reinitialize clones
/// or move their assets. It must not custody funds.
/// @custom:security-contact security@blocks.fm
contract ReservePolicyFactory is IPolicyFactory {
    /// @notice Returns the Policy implementation used for new clones.
    /// @return Implementation deployed by the constructor.
    address public immutable implementation;

    /// @notice Deploys the Policy implementation once with fixed dependencies.
    /// @dev The deployer supplies compatible configuration and BUX contracts.
    /// @param config Shared auction factory and row sweeper configuration.
    /// @param bux ERC-20 revenue token sold by each Policy.
    constructor(IBuybackConfig config, IERC20 bux) {
        implementation = address(new ReservePolicy(config, bux));
    }

    /// @inheritdoc IPolicyFactory
    /// @dev `data` must be `abi.encode(reserve)`.
    function create(address vault, bytes calldata data) external returns (address policy) {
        IERC20 reserve = abi.decode(data, (IERC20));
        policy = Clones.clone(implementation);
        ReservePolicy(policy).initialize(IBlockVault(vault), reserve);
        emit PolicyCreated(vault, policy);
    }
}
