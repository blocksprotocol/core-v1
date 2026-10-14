// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IAuction } from "./IAuction.sol";

/// @title IBuybackPolicy
/// @notice Converts BUX revenue to underlying or reports it directly to one staking vault.
/// @dev Auction payments round down in underlying token base units. The buyer keeps the remainder,
/// less than one base unit relative to the scaled quote. Dust with zero payment cannot be taken.
/// The lot becomes inactive below the minimum price.
/// Adding BUX to an active lot can make a full take payable, capped at the initial lot size.
/// Taking that capped amount ends the lot. Any excess waits for the next kick.
interface IBuybackPolicy {
    /// @notice Emitted when held underlying is reported to the staking vault.
    /// @param buxIn BUX base units (6 decimals) redeemed. Zero means no redemption.
    /// @param underlyingReported Gross underlying token base units reported before the work fee.
    event RevenueBought(uint256 buxIn, uint256 underlyingReported);

    /// @notice Thrown when auction execution or BUX redemption is unavailable for the underlying.
    error InvalidConversionMode();

    /// @notice Claims revenue rows and offers the Policy's whole BUX balance in its auction.
    /// @dev Anyone may call. Reverts `InvalidConversionMode` for BUX or BUX's reserve asset.
    /// If the factory changes, first moves unsold BUX to a new auction.
    /// Returns zero while an active lot still holds BUX. Settles an active lot emptied outside
    /// `Auction.take` before kicking. Auction reverts "nothing to kick" for a zero balance.
    /// Proceeds stay here until `reportUnderlying` sends them to the staking vault.
    /// @return Lot size in BUX base units (6 decimals), including BUX held by the auction, or zero
    /// while an active lot still holds BUX.
    function kickAuction() external returns (uint256);

    /// @notice Claims revenue rows and reports all underlying to the fixed staking vault.
    /// @dev Anyone may call. Nonzero `buxToRedeem` requires underlying to be BUX's reserve asset.
    /// Redemption can revert if reserves are unavailable. BUX needs no conversion.
    /// @param buxToRedeem BUX base units (6 decimals) to redeem. Zero skips redemption.
    function reportUnderlying(uint256 buxToRedeem) external;

    /// @notice Returns the auction used to buy underlying.
    /// @return Current auction, or `address(0)` for the BUX and BUX-reserve modes.
    function auction() external view returns (IAuction);

    /// @notice Returns the factory that deployed the current auction.
    /// @return Auction factory, or `address(0)` for the BUX and BUX-reserve modes.
    function auctionFactory() external view returns (address);
}
