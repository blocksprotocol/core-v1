// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { LowLevelCall } from "@openzeppelin/contracts/utils/LowLevelCall.sol";

import { IProtocolSettings } from "../interfaces/IProtocolSettings.sol";
import { IReleaser } from "../interfaces/IReleaser.sol";

/// @title JarSweeper
/// @notice Batches prepaid purchases of jar inventory for keepers.
/// @dev The caller prepays each leg's maximum and receives unused BUX by transfer.
/// @custom:security-contact security@blocks.fm
contract JarSweeper {
    using SafeERC20 for IERC20;

    struct Leg {
        address jar;
        address asset;
        // Maximum nominal token base units to buy. Zero reverts the leg.
        uint256 maxAmount;
        // Minimum nominal token base units to buy. Zero removes the lower bound.
        uint256 minAmount;
        // Maximum prepayment in BUX base units (6 decimals). The buyer receives unused BUX.
        uint256 maxPayment;
    }

    /// @notice Returns the settings used to discover BUX and the current Releaser.
    /// @return Protocol settings fixed at deployment.
    IProtocolSettings public immutable settings;

    /// @notice Thrown when anyone other than this sweeper calls `buyOne`.
    error OnlySelf();
    /// @notice Thrown when successful legs exceed the batch payment cap.
    /// @dev The Releaser uses the same selector when a leg exceeds its payment limit.
    error ExcessivePayment();

    // Initialization

    /// @notice Binds the protocol settings once at deployment.
    /// @param settings_ Settings supplying BUX and the current Releaser.
    constructor(IProtocolSettings settings_) {
        settings = settings_;
    }

    // Lot purchases

    /// @notice Buys independent legs, reverting the batch if its total payment cap is exceeded.
    /// @dev Anyone may call. The buyer approves this sweeper for the sum of `maxPayment` values.
    /// Refunds do not restore allowance. The outer transaction also needs gas for call overhead
    /// and batch accounting.
    /// @param legs Ordered lot purchases delivering inventory to the caller.
    /// @param deadline Last valid execution time for all legs in Unix seconds, inclusive.
    /// @param maxTotalPayment Maximum total spent in BUX base units.
    /// @param legGas Gas cap per self-call, typically 500_000 gas units. Keepers may raise it.
    /// Actual forwarded gas may be lower.
    /// @param skipFailures Whether failed legs are skipped instead of reverting the batch.
    /// @return payments BUX base units spent, in input order. Zero for skipped legs.
    /// @return successes Success flags in input order. False for skipped legs.
    function buyMany(
        Leg[] calldata legs,
        uint256 deadline,
        uint256 maxTotalPayment,
        uint256 legGas,
        bool skipFailures
    ) external returns (uint256[] memory payments, bool[] memory successes) {
        payments = new uint256[](legs.length);
        successes = new bool[](legs.length);
        uint256 totalPayment;
        for (uint256 i; i < legs.length; ++i) {
            try this.buyOne{ gas: legGas }(msg.sender, legs[i], deadline) returns (uint256 payment)
            {
                totalPayment += payment;
                if (totalPayment > maxTotalPayment) revert ExcessivePayment();
                payments[i] = payment;
                successes[i] = true;
            } catch (bytes memory reason) {
                if (!skipFailures) LowLevelCall.bubbleRevert(reason);
            }
        }
    }

    /// @notice Prepays for one purchase and refunds unused BUX atomically.
    /// @dev Only this sweeper may call. The buyer must approve the full `leg.maxPayment`.
    /// @param buyer Account funding payment and receiving inventory and refunds.
    /// @param leg Jar, asset and purchase limits for this leg.
    /// @param deadline Last valid execution time in Unix seconds, inclusive.
    /// @return payment BUX base units spent.
    function buyOne(address buyer, Leg calldata leg, uint256 deadline)
        external
        returns (uint256 payment)
    {
        if (msg.sender != address(this)) revert OnlySelf();
        IReleaser releaser = IReleaser(settings.releaser());
        IERC20 bux = IERC20(settings.bux());
        bux.safeTransferFrom(buyer, address(this), leg.maxPayment);
        bux.forceApprove(address(releaser), leg.maxPayment);
        (, payment) = releaser.takeWithLimits(
            leg.jar, leg.asset, leg.maxAmount, leg.minAmount, leg.maxPayment, buyer, deadline
        );
        if (payment < leg.maxPayment) bux.safeTransfer(buyer, leg.maxPayment - payment);
    }
}
