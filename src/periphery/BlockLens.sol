// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IBlockBatchSale } from "../interfaces/IBlockBatchSale.sol";
import { IBlockFactory } from "../interfaces/IBlockFactory.sol";
import { IBlockLens } from "../interfaces/IBlockLens.sol";
import { IBlockRegistry } from "../interfaces/IBlockRegistry.sol";
import { IJarFactory } from "../interfaces/IJarFactory.sol";
import { IProtocolSettings } from "../interfaces/IProtocolSettings.sol";

/// @title BlockLens
/// @notice Reports Block status and destinations on the Block's home chain only.
/// @dev Reads factory registration and sale state and predicts jars without taking custody.
/// @custom:security-contact security@blocks.fm
contract BlockLens is IBlockLens {
    IProtocolSettings private immutable _settings;

    /// @notice Binds the settings used for factory discovery once at deployment.
    /// @param settings_ Protocol settings supplying registered factories.
    constructor(IProtocolSettings settings_) {
        _settings = settings_;
    }

    /// @inheritdoc IBlockLens
    function kindOf(address token) public view returns (Kind) {
        IBlockRegistry factory = _factoryOf(token);
        if (address(factory) == address(0)) return Kind.None;
        if (factory.isStakingBlock(token)) return Kind.Staking;
        IBlockFactory blocks = IBlockFactory(address(factory));
        if (blocks.marketLive(token)) return Kind.Live;

        // A Raise has an initialized sale. Outside `close`, a market that is not live has a
        // `Selling` or `Cancelled` sale.
        IBlockBatchSale.State state = IBlockBatchSale(blocks.saleOf(token)).state();
        if (state == IBlockBatchSale.State.Cancelled) return Kind.Cancelled;
        return Kind.Launching;
    }

    /// @inheritdoc IBlockLens
    function jarOf(address token) external view returns (address) {
        IBlockRegistry factory = _factoryOf(token);
        if (address(factory) == address(0)) return address(0);
        return IJarFactory(factory.jarFactory()).predict(block.chainid, token);
    }

    /// @inheritdoc IBlockLens
    function redemptionOf(address token) external view returns (address) {
        Kind kind = kindOf(token);
        if (kind == Kind.Staking) return token;
        if (kind == Kind.Live) {
            return _factoryOf(token).vaultOf(token);
        }
        return address(0);
    }

    // A failed settings lookup means unrecognized. Later factory and sale failures still propagate.
    function _factoryOf(address token) private view returns (IBlockRegistry factory) {
        try _settings.blockFactoryFor(token) returns (address found) {
            factory = IBlockRegistry(found);
        } catch { }
    }
}
