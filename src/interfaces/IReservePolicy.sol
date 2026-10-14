// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAuction } from "./IAuction.sol";
import { IBlockVault } from "./IBlockVault.sol";
import { IBuybackConfig } from "./IBuybackConfig.sol";

/// @title IReservePolicy
/// @notice Buys one Block's reserve through an auction and forwards assets to its vault.
/// @dev Auction payments round down in reserve token base units. The buyer keeps the remainder,
/// less than one base unit relative to the scaled quote. Dust with zero payment cannot be taken.
/// The lot becomes inactive below the minimum price.
/// Adding BUX to an active lot can make a full take payable, capped at the initial lot size.
/// Taking that capped amount ends the lot. Any excess waits for the next kick.
/// Changing the Block's Policy does not change this Policy's bound vault.
/// New kicks require reserve acceptance. Active lots can sell after acceptance is removed.
/// Forwarding then requires the Block admin to restore retention, unless the reserve still occupies
/// an extra slot and the transfer leaves the vault in deficit.
interface IReservePolicy {
    /// @notice Emitted when the Policy forwards a non-BUX asset to the vault and syncs it.
    /// @param asset ERC-20 asset forwarded to the vault.
    /// @param amount Gross token base units transferred before the vault's work fee or burn.
    event Forwarded(address indexed asset, uint256 amount);

    /// @notice Thrown when the caller initializing the Policy is not the bound factory.
    error OnlyFactory();
    /// @notice Thrown when a kick targets a reserve the vault does not accept as backing.
    error ReserveNotAccepted();
    /// @notice Thrown when `forward` is called with BUX.
    error BuxOnlyBuysReserve();

    // Initialization

    /// @notice Binds a clone's vault and reserve and builds its auction.
    /// @dev Only the factory may call. It must initialize clones once without reading the vault.
    /// The reserve must expose `decimals()` and have at most 18 decimals. Enabling BUX rejects BUX
    /// as the reserve.
    /// @param vault_ Vault receiving forwarded assets. May still be uninitialized.
    /// @param reserve_ ERC-20 payment token with at most 18 decimals, distinct from BUX.
    function initialize(IBlockVault vault_, IERC20 reserve_) external;

    // Auction operations

    /// @notice Claims revenue rows and offers the Policy's whole BUX balance in its auction.
    /// @dev Anyone may call. Reverts `ReserveNotAccepted` unless the vault accepts the reserve.
    /// If the factory changes, first moves unsold BUX to a new auction.
    /// Returns zero while an active lot still holds BUX. Settles an active lot emptied outside
    /// `Auction.take` before kicking. Auction reverts "nothing to kick" for a zero balance.
    /// Proceeds stay here until `forward` sends them to the vault.
    /// @return Lot size in BUX base units (6 decimals), including BUX held by the auction, or zero
    /// while an active lot still holds BUX.
    function kickAuction() external returns (uint256);

    // Asset forwarding

    /// @notice Claims revenue rows and forwards the whole non-BUX asset balance to the vault.
    /// @dev Anyone may call. Reverts `BuxOnlyBuysReserve` for BUX, which leaves via the auction.
    /// Returns if the balance is zero. Otherwise, `vault.sync` burns its own Block token or checks
    /// backing admission and charges the work fee on any surplus. A revert rolls back the transfer
    /// and row claims.
    /// @param asset ERC-20 asset to forward, distinct from BUX.
    function forward(IERC20 asset) external;

    // Views

    /// @notice Returns the factory authorized to initialize this Policy.
    /// @return Factory address fixed at implementation deployment.
    function factory() external view returns (address);

    /// @notice Returns the shared auction factory and row sweeper configuration.
    /// @return Configuration fixed at implementation deployment.
    function config() external view returns (IBuybackConfig);

    /// @notice Returns the fixed token sold by this Policy's auction.
    /// @return BUX token address.
    function bux() external view returns (IERC20);

    /// @notice Returns the vault receiving forwarded assets.
    /// @return Bound vault, or `address(0)` before initialization.
    function vault() external view returns (IBlockVault);

    /// @notice Returns the reserve token bought by this Policy's auction.
    /// @return Reserve token, or `address(0)` before initialization.
    function reserve() external view returns (IERC20);

    /// @notice Returns the auction receiving BUX and paying reserve proceeds to this Policy.
    /// @return Current auction, or `address(0)` before initialization.
    function auction() external view returns (IAuction);

    /// @notice Returns the factory that deployed the current auction.
    /// @return Current auction's factory, or `address(0)` before initialization.
    function auctionFactory() external view returns (address);
}
