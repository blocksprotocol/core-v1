// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title SwapChargeMath
/// @notice Calculates ordinary swap fees and launch tax on gross quote for all four swap modes.
library SwapChargeMath {
    // Basis-point denominator: 10_000 bps = 100%.
    uint256 internal constant BPS = 10_000;

    /// @notice Thrown when launch tax exceeds 9,000 bps.
    error InvalidRate();

    /// @notice Deducts the ordinary swap fee, then launch tax, rounding both up.
    /// @dev Fee and tax recipients keep rounding excess. Hooks supply the Block rate, which can
    /// only decrease, or the fixed 100 bps Coin rate. Only the 9,000 bps tax bound is checked.
    /// @param gross Gross quote base units before hook charges.
    /// @param feeBps Ordinary swap fee in bps of gross quote. Zero disables the fee.
    /// @param taxBps Launch tax in bps of quote after the ordinary fee. Zero disables tax.
    /// @return fee Ordinary swap fee in quote base units.
    /// @return tax Launch tax in quote base units.
    /// @return net Remaining quote base units.
    function charges(uint256 gross, uint256 feeBps, uint256 taxBps)
        public
        pure
        returns (uint256 fee, uint256 tax, uint256 net)
    {
        if (taxBps > 9_000) revert InvalidRate();
        fee = Math.mulDiv(gross, feeBps, BPS, Math.Rounding.Ceil);
        uint256 remainder = gross - fee;
        tax = Math.mulDiv(remainder, taxBps, BPS, Math.Rounding.Ceil);
        net = remainder - tax;
    }

    /// @notice Returns the smallest gross quote amount whose charges leave exactly `net`.
    /// @dev Requires a fee below 10_000 bps and tax at most 9,000 bps.
    /// Undoes tax, then the ordinary fee, rounding up at each step. No funds move.
    /// `Math.mulDiv` reverts if either result exceeds `uint256`.
    /// @param net Required quote base units after hook charges.
    /// @param feeBps Ordinary swap fee in bps of gross quote. Zero disables the fee.
    /// @param taxBps Launch tax in bps of quote after the ordinary fee. Zero disables tax.
    /// @return gross Gross quote base units before hook charges.
    function grossForNet(uint256 net, uint256 feeBps, uint256 taxBps)
        public
        pure
        returns (uint256 gross)
    {
        if (taxBps > 9_000) revert InvalidRate();

        uint256 afterFee = Math.mulDiv(net, BPS, BPS - taxBps, Math.Rounding.Ceil);
        gross = Math.mulDiv(afterFee, BPS, BPS - feeBps, Math.Rounding.Ceil);
    }

    /// @notice Decodes optional app attribution from exactly 32 bytes.
    /// @dev Other lengths return zero. Attribution neither authenticates creators nor grants fees.
    /// @param data Optional `abi.encode(bytes32 appId)` payload.
    /// @return appId Unauthenticated app ID. Zero for other payload lengths or an encoded zero.
    function parseAppId(bytes memory data) internal pure returns (bytes32 appId) {
        if (data.length == 32) appId = abi.decode(data, (bytes32));
    }
}
