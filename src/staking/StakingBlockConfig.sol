// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IBlockRevenueConfig } from "../interfaces/IBlockRevenueConfig.sol";

/// @title StakingBlockConfig
/// @notice Exposes fixed revenue routing for a staking Block.
/// @dev Exposes no custody operations.
/// @custom:security-contact security@blocks.fm
contract StakingBlockConfig is IBlockRevenueConfig {
    /// @notice Returns the staking vault.
    /// @return Staking vault fixed at deployment.
    address public immutable token;
    /// @notice Returns the staking vault's underlying ERC-20 asset.
    /// @return Underlying fixed at deployment.
    address public immutable underlying;
    /// @inheritdoc IBlockRevenueConfig
    /// @dev Staking launches require a nonzero Policy.
    address public immutable policy;
    address private immutable _bux;

    /// @notice Binds the staking vault, underlying, BUX and Policy once at deployment.
    /// @dev The staking factory deploys one configuration per staking vault.
    /// @param token_ Staking vault whose revenue uses this configuration.
    /// @param underlying_ ERC-20 asset accepted by the staking vault.
    /// @param bux_ BUX token excluded from retained extras.
    /// @param policy_ Revenue Policy. Staking routing does not support `address(0)`.
    constructor(address token_, address underlying_, address bux_, address policy_) {
        token = token_;
        underlying = underlying_;
        policy = policy_;
        _bux = bux_;
    }

    /// @inheritdoc IBlockRevenueConfig
    function isRetained(address asset) external view returns (bool) {
        return underlying != _bux && asset == underlying;
    }

    /// @inheritdoc IBlockRevenueConfig
    function extras() external view returns (address[] memory assets) {
        assets = new address[](underlying == _bux ? 0 : 1);
        if (assets.length != 0) assets[0] = underlying;
    }
}
