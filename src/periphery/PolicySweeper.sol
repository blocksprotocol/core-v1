// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { CallWithExactGas } from "@chainlink/contracts/src/v0.8/shared/call/CallWithExactGas.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IBlockFactory } from "../interfaces/IBlockFactory.sol";
import { IBlockRegistry } from "../interfaces/IBlockRegistry.sol";
import { IBlockRevenueConfig } from "../interfaces/IBlockRevenueConfig.sol";
import { IJar } from "../interfaces/IJar.sol";
import { IJarFactory } from "../interfaces/IJarFactory.sol";
import { IPolicyRows } from "../interfaces/IPolicyRows.sol";
import { IProtocolSettings } from "../interfaces/IProtocolSettings.sol";

/// @title PolicySweeper
/// @notice Claims Policy rows for a live Block on its home chain without taking custody.
/// @dev Discovers the hook, jar and configured extra assets. It neither chooses recipients
/// nor spends caller funds.
/// @custom:security-contact security@blocks.fm
contract PolicySweeper {
    /// @notice Returns the gas budget for each extra-asset claim.
    /// @dev Leaves headroom above an estimated 300_000 gas units for transfer, vault sync and fee.
    /// @return Gas units forwarded to each extra-asset claim.
    uint256 public constant CLAIM_GAS_LIMIT = 500_000;
    /// @notice Returns the gas reserved to check that the full call budget is available.
    /// @return Gas units reserved before checking the forwarded budget.
    uint16 public constant GAS_FOR_CALL_EXACT_CHECK = 5_000;

    /// @notice Returns the settings used to discover Block factories and BUX.
    /// @return Protocol settings fixed at deployment.
    IProtocolSettings public immutable settings;

    /// @notice Thrown when the token has no registered factory or is not a live Block.
    error BlockNotLive();

    /// @notice Binds protocol settings once at deployment.
    /// @param settings_ Settings supplying registered factories and BUX.
    constructor(IProtocolSettings settings_) {
        settings = settings_;
    }

    /// @notice Syncs BUX, then claims the canonical hook row, jar BUX and configured extras.
    /// @dev Anyone may call. BUX claims revert together, including the hook's PoolManager unlock.
    /// Each extra-asset claim has its own gas budget. A failed claim leaves the row retryable.
    /// Insufficient outer gas reverts the operation.
    /// @param token Live Block token on its home chain.
    function claimAll(address token) external {
        IBlockRegistry blocks = IBlockRegistry(settings.blockFactoryFor(token));
        if (address(blocks) == address(0) || !blocks.isBlock(token)) revert BlockNotLive();
        IJar jar = IJar(IJarFactory(blocks.jarFactory()).predict(block.chainid, token));
        address bux = settings.bux();

        if (IERC20(bux).balanceOf(address(jar)) > jar.accounted(bux)) jar.sync(bux);
        if (!blocks.isStakingBlock(token)) {
            address hook = IBlockFactory(address(blocks)).canonicalHookOf(token);
            if (hook != address(0)) IPolicyRows(hook).claimPolicy(token);
        }
        jar.claimPolicyAsset(bux);

        address[] memory extras = IBlockRevenueConfig(blocks.vaultOf(token)).extras();
        for (uint256 i; i < extras.length; ++i) {
            // Discarding return data prevents a claim from exhausting the caller's memory budget.
            CallWithExactGas._callWithExactGas(
                abi.encodeCall(IJar.claimPolicyAsset, (extras[i])),
                address(jar),
                CLAIM_GAS_LIMIT,
                GAS_FOR_CALL_EXACT_CHECK
            );
        }
    }
}
