// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import { IBlockFactory } from "../interfaces/IBlockFactory.sol";
import { IBlockRevenueConfig } from "../interfaces/IBlockRevenueConfig.sol";
import { IPolicyRows } from "../interfaces/IPolicyRows.sol";
import { IProtocolSettings } from "../interfaces/IProtocolSettings.sol";

import { FeeSplit } from "../libraries/FeeSplit.sol";
import { BaseMarketHook } from "./BaseMarketHook.sol";

/// @title BlockHook
/// @notice Routes ordinary Block/BUX swap fees and holds liquidity funded by Block batch sales.
/// @dev Every swap credits the Block's share to its claimable row. With a zero Policy, the next
/// swap pays the row to the vault. With a nonzero Policy, the row waits for `claimPolicy`.
/// @custom:security-contact security@blocks.fm
contract BlockHook is BaseMarketHook, IPolicyRows {
    // Initialization

    /// @notice Binds the hook once at deployment to its factory, manager and BUX.
    /// @param manager PoolManager bound to the factory.
    /// @param factory_ Fixed factory authorized for registration, funding and migration.
    /// @param bux_ BUX token with 6 decimals.
    constructor(IPoolManager manager, address factory_, address bux_)
        BaseMarketHook(manager, factory_, bux_)
    { }

    // Claims

    /// @inheritdoc IPolicyRows
    function claimPolicy(address token)
        external
        nonReentrant
        returns (address[] memory assets, uint256[] memory amounts)
    {
        PoolConfig storage config = _config[token];
        if (config.token == address(0)) revert UnknownPool();

        address destination = IBlockRevenueConfig(config.vault).policy();
        bool toVault = destination == address(0);
        assets = new address[](1);
        amounts = new uint256[](1);
        assets[0] = config.quote;
        uint256 buxAmount = earned[token][FeeSplit.BLOCK_ROW];
        amounts[0] = buxAmount;

        earned[token][FeeSplit.BLOCK_ROW] = 0;

        if (buxAmount != 0) {
            _unlock(OP_CLAIM, token, buxAmount, toVault ? config.vault : destination);
        }
        emit PolicyClaimed(token, destination, config.quote, buxAmount);
    }

    // Internal functions

    function _isBlockPool() internal pure override returns (bool) {
        return true;
    }

    function _swapFeeBps() internal view override returns (uint256) {
        return IProtocolSettings(IBlockFactory(factory).settings()).blockSwapFeeBps();
    }

    // PoolManager credits the hook's fee after `afterSwap` returns, offsetting the mint.
    // A zero Policy delivers the row left by earlier swaps to the vault from BUX the PoolManager
    // holds. A buy's own BUX arrives only when the router settles, so this swap's share waits.
    function _distributeSwapFee(
        SwapContext memory context,
        PoolConfig storage config,
        address asset
    ) internal override {
        IBlockFactory blockFactory = IBlockFactory(factory);
        (uint16 protocolBps, uint16 creatorBps,) =
            IProtocolSettings(blockFactory.settings()).swapSplit();
        address creator = blockFactory.payoutOf(context.token);
        // Both rates apply independently to the ordinary swap fee and round down.
        // The Block receives the remainder. 10_000 bps = 100%.
        uint256 protocolBux = Math.mulDiv(context.fee, protocolBps, 10_000);
        uint256 creatorBux = Math.mulDiv(context.fee, creatorBps, 10_000);
        uint256 blockBux = context.fee - protocolBux - creatorBux;

        // Crediting shares makes no recipient calls. Each credit stays with its recipient.
        _creditAccount(context.token, asset, creator, creatorBux);
        _creditAccount(context.token, asset, blockFactory.feePool(), protocolBux);
        // The zero account identifies the Block's row, not a payout address.
        uint256 earlier = earned[context.token][FeeSplit.BLOCK_ROW];
        if (earlier != 0 && IBlockRevenueConfig(config.vault).policy() == address(0)) {
            earned[context.token][FeeSplit.BLOCK_ROW] = 0;
            _collect(context.token, earlier, config.vault);
            emit PolicyClaimed(context.token, address(0), asset, earlier);
        }
        earned[context.token][FeeSplit.BLOCK_ROW] += blockBux;
        emit PolicyAccrued(context.token, asset, blockBux);
        if (context.fee != 0) {
            poolManager.mint(address(this), uint256(uint160(asset)), context.fee);
        }
        emit SwapFeeSplit(context.token, asset, creatorBux, blockBux, protocolBux);
    }
}
