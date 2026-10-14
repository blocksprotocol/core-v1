// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title FloorMath
/// @notice Converts token quote prices and pool square-root prices using fixed-point arithmetic.
/// @dev `spot` returns quote base units per 1e18 token base units, independent of redemption value.
/// BUX uses 6 decimals. The pool encodes currency1 per currency0.
/// `tokenIs0` selects quote per token. Otherwise, the ratio is inverted.
library FloorMath {
    uint256 internal constant WAD = 1e18; // Token base units per whole 18-decimal token.

    /// @notice Thrown when a ratio input or its Q128 encoding is zero, or the encoded square-root
    /// price is out of bounds.
    error InvalidPrice();

    /// @notice Returns the encoded pool spot quote per whole token.
    /// @dev The square rounds down to Q128. The final division also rounds down.
    /// Inverting the rounded denominator can overstate the exact reciprocal.
    /// Quantization changes only the reported price and transfers no remainder.
    /// @param sqrtPriceX96 Square root of currency1 per currency0, scaled by 2^96.
    /// @param tokenIs0 Whether the token is currency0 and the quote is currency1.
    /// @return Quote base units per 1e18 token base units.
    function spot(uint160 sqrtPriceX96, bool tokenIs0) public pure returns (uint256) {
        uint256 priceX128 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
        if (tokenIs0) return Math.mulDiv(priceX128, WAD, 1 << 128);
        return Math.mulDiv(WAD, 1 << 128, priceX128);
    }

    /// @notice Encodes a raw quote-to-token base-unit ratio as a pool square-root price.
    /// @dev Callers must preserve the raw ratio. Rounding to quote base units per whole token
    /// first loses precision. The ratio rounds down to Q128, then the square root rounds down.
    /// The low 32 output bits are zero. Quantization can change the tick at a boundary but
    /// transfers no remainder. Zero inputs, a zero Q128 ratio and square-root prices at or
    /// outside the bounds revert with `InvalidPrice`. Q128 division reverts on `uint256` overflow.
    /// @param quoteAmount Nonzero quote base units defining the ratio.
    /// @param tokenAmount Nonzero token base units defining the ratio.
    /// @param tokenIs0 Whether the token is currency0 and the quote is currency1.
    /// @return sqrtPriceX96 Square root of currency1 per currency0, scaled by 2^96.
    function sqrtPriceForRatio(uint256 quoteAmount, uint256 tokenAmount, bool tokenIs0)
        public
        pure
        returns (uint160 sqrtPriceX96)
    {
        if (quoteAmount == 0 || tokenAmount == 0) revert InvalidPrice();
        uint256 ratioX128 = tokenIs0
            ? Math.mulDiv(quoteAmount, 1 << 128, tokenAmount)
            : Math.mulDiv(tokenAmount, 1 << 128, quoteAmount);
        if (ratioX128 == 0) revert InvalidPrice();
        sqrtPriceX96 = SafeCast.toUint160(Math.sqrt(ratioX128) << 32);
        if (sqrtPriceX96 <= TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert InvalidPrice();
        }
    }
}
