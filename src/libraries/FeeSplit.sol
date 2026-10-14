// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FeeSplit
/// @notice Splits ordinary Coin swap fees, taking the protocol share before the creator share.
/// @dev Swap accounting supplies validated factory rates, never rates from swap data.
/// This library does not validate rates.
library FeeSplit {
    struct SwapSplit {
        uint256 creator; // Creator allocation in fee-asset base units.
        uint256 vault; // Parent Block allocation in fee-asset base units, including the remainder.
        uint256 feePool; // Protocol allocation in fee-asset base units.
    }

    uint256 internal constant BPS = 10_000; // Rate denominator: 10_000 bps = 100%.
    // Fixed ordinary Coin swap fee in bps: 100 bps = 1%.
    uint256 internal constant SWAP_FEE_BPS = 100;

    // Accounting row for a Block's own-market or parent share, not a payee.
    address internal constant BLOCK_ROW = address(0);
    // Accounting row for the protocol share, not a payee.
    address internal constant PROTOCOL_ROW = address(1);

    /// @notice Splits a fee into protocol, creator and parent Block allocations.
    /// @dev Protocol and creator shares round down. The parent Block receives the remainder.
    /// @param fee Gross fee in fee-asset base units.
    /// @param protocolBps Protocol share of the gross fee in bps.
    /// @param creatorBps Creator share of the post-protocol remainder in bps.
    /// @return s Allocations in fee-asset base units.
    function splitSwapFee(uint256 fee, uint256 protocolBps, uint256 creatorBps)
        public
        pure
        returns (SwapSplit memory s)
    {
        s.feePool = Math.mulDiv(fee, protocolBps, BPS);
        uint256 remaining = fee - s.feePool;
        s.creator = Math.mulDiv(remaining, creatorBps, BPS);
        s.vault = remaining - s.creator;
    }
}
