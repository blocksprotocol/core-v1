// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { IBlockBatchSale } from "../interfaces/IBlockBatchSale.sol";
import { IBlockFactory } from "../interfaces/IBlockFactory.sol";
import { IBlockHook } from "../interfaces/IBlockHook.sol";

import { BlockToken } from "../BlockToken.sol";
import { VestingEscrow } from "../VestingEscrow.sol";
import { FloorMath } from "./FloorMath.sol";

/// @title LaunchSettlement
/// @notice Creates launch tokens, funds sales and opens settled Block markets.
/// @dev Fixed linked code uses the factory's custody. The factory authenticates the calling sale.
/// Settlement requires BUX and BlockToken to have no transfer fees or callbacks.
library LaunchSettlement {
    using SafeERC20 for IERC20;
    using Clones for address;

    // Ticks between usable boundaries, limiting tick density and swap gas.
    int24 private constant BLOCK_TICK_SPACING = 60;

    // Launch

    /// @notice Deploys a token whose initial supply is minted to the calling factory.
    /// @dev Chain ID and launch number in the salt separate chains sharing a factory address
    /// and repeated launches with the same name.
    /// @param name Token name and permit domain name.
    /// @param symbol Token ticker.
    /// @param launchNumber Sequence number used in the deployment salt.
    /// @return Newly deployed token address.
    function createToken(string calldata name, string calldata symbol, uint256 launchNumber)
        public
        returns (address)
    {
        bytes32 salt = keccak256(abi.encode(block.chainid, launchNumber));
        return address(new BlockToken{ salt: salt }(name, symbol, address(this)));
    }

    /// @notice Funds and initializes a sale clone, then pulls the launcher's priority commitment.
    /// @dev The calling factory supplies all outstanding tokens before initialization.
    /// @param token Token whose supply funds the sale.
    /// @param quote BUX asset used for commitments.
    /// @param implementation Sale implementation to clone.
    /// @param terms Fixed amounts and schedule. Zero `creatorCommit` skips priority funding.
    /// @return sale Funded sale clone.
    function startSale(
        address token,
        address quote,
        address implementation,
        IBlockBatchSale.Terms memory terms
    ) public returns (address sale) {
        sale = implementation.clone();
        IERC20(token).safeTransfer(sale, IERC20(token).totalSupply());
        IBlockBatchSale(sale).initialize(token, quote, address(this), terms, msg.sender);
        uint256 creatorBux = terms.creatorCommit;
        if (creatorBux == 0) return sale;

        IERC20(quote).safeTransferFrom(msg.sender, address(this), creatorBux);
        IERC20(quote).forceApprove(sale, creatorBux);
        IBlockBatchSale(sale).commitForCreator(creatorBux);
        IERC20(quote).forceApprove(sale, 0);
    }

    // Settlement

    /// @notice Funds creator vesting and opens the market after the sale pays its fee.
    /// @dev The cliff starts at settlement. Linear vesting starts at the cliff's end.
    /// @param launch Registry record for the settling token.
    /// @param escrowImplementation Vesting implementation for nonzero priority allocations.
    /// @param marketTokens Hook inventory in token base units (18 decimals).
    /// @param proceeds Net market funding in BUX base units (6 decimals).
    /// @param priceX96 BUX base units per token base unit, scaled by 2^96.
    /// @param creatorFill Vested token base units (18 decimals). Zero skips escrow creation.
    /// @return key Initialized market key.
    /// @return escrow Funded vesting clone; zero when no priority allocation exists.
    function settleSale(
        IBlockFactory.Launch memory launch,
        address escrowImplementation,
        uint256 marketTokens,
        uint256 proceeds,
        uint160 priceX96,
        uint256 creatorFill
    ) public returns (PoolKey memory key, address escrow) {
        IBlockBatchSale sale = IBlockBatchSale(msg.sender);
        if (creatorFill != 0) {
            IBlockBatchSale.Terms memory terms = sale.terms();
            escrow = escrowImplementation.clone();
            IERC20(launch.token).safeTransferFrom(msg.sender, escrow, creatorFill);
            uint64 cliffEnd = uint64(block.timestamp) + terms.cliffDuration;
            VestingEscrow(escrow).initialize(
                launch.token, address(this), creatorFill, cliffEnd, cliffEnd + terms.vestDuration
            );
        }

        key = _openFunded(launch, marketTokens, proceeds, priceX96);
    }

    // Internal functions

    function _openFunded(
        IBlockFactory.Launch memory launchRecord,
        uint256 marketTokens,
        uint256 proceedsBux,
        uint160 priceX96
    ) private returns (PoolKey memory key) {
        IBlockFactory factory = IBlockFactory(address(this));
        address hook = factory.hook();
        bool tokenIs0 = launchRecord.token < launchRecord.quote;
        key = PoolKey({
            currency0: Currency.wrap(tokenIs0 ? launchRecord.token : launchRecord.quote),
            currency1: Currency.wrap(tokenIs0 ? launchRecord.quote : launchRecord.token),
            fee: 0,
            tickSpacing: BLOCK_TICK_SPACING,
            hooks: IHooks(hook)
        });
        // The ratio and square root round down. The pool price can differ from the clearing price.
        uint160 sqrtPriceX96 = FloorMath.sqrtPriceForRatio(priceX96, 1 << 96, tokenIs0);
        int24 saleTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        IBlockHook(hook).registerFunded(
            launchRecord.token,
            key,
            IBlockHook.PoolConfig({
                token: launchRecord.token,
                quote: launchRecord.quote,
                tokenIs0: tokenIs0,
                isBlock: launchRecord.isBlock,
                vault: launchRecord.vault,
                parentToken: address(0),
                launchedAt: uint64(block.timestamp),
                openingTick: saleTick,
                bondingTick: saleTick
            })
        );
        factory.poolManager().initialize(key, sqrtPriceX96);
        IERC20(launchRecord.token).safeTransferFrom(msg.sender, hook, marketTokens);
        IERC20(launchRecord.quote).safeTransferFrom(msg.sender, hook, proceedsBux);
        IBlockHook(hook).seedFunded(launchRecord.token, marketTokens, proceedsBux);
    }
}
