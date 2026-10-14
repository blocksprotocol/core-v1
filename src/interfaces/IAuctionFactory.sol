// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IAuctionFactory
/// @notice Deploys auctions that sell tokens for one want token and pay a receiver.
interface IAuctionFactory {
    /// @notice Deploys and initializes an auction.
    /// @dev Reverts for a zero `want` or `receiver`, a `want` with more than 18 decimals, or a
    /// `startingPrice` of 1e9 or less. The address derives from the caller, `want`, `receiver` and
    /// `governance`. Reusing those values reverts, even with a different `startingPrice`.
    /// @param want Token that buyers pay.
    /// @param receiver Initial recipient of want payments.
    /// @param governance Initial authority to configure the auction and receive swept balances.
    /// @param startingPrice Opening value of each lot in whole want tokens, scaled by 1e18.
    /// The per-token opening price divides this by the lot size in whole tokens, rounding to
    /// nearest with ties up.
    /// @return Address of the new auction.
    function createNewAuction(
        address want,
        address receiver,
        address governance,
        uint256 startingPrice
    ) external returns (address);
}
