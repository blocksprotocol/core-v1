// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IProtocolSettings } from "./IProtocolSettings.sol";

import { PolicySweeper } from "../periphery/PolicySweeper.sol";

/// @title IBuybackConfig
/// @notice Defines the shared auction factory and row sweeper for staking and Reserve Policies.
interface IBuybackConfig {
    /// @notice Emitted when the Safe sets the auction factory.
    /// @param auctionFactory Factory for new auctions.
    event AuctionFactorySet(address indexed auctionFactory);

    /// @notice Thrown when the caller is not the current Safe.
    error OnlySafe();
    /// @notice Thrown when the proposed auction factory has no code.
    error InvalidAddress();

    /// @notice Sets the factory used on each Policy's next kick.
    /// @dev Only the Safe may call. New Policies use the current factory when they need an auction.
    /// Reverts `InvalidAddress` if the address has no code. Each compatible replacement must be a
    /// fresh deployment, even when switching back. The Auction factory cannot redeploy an auction
    /// for the same Policy with the same creation arguments.
    /// @param auctionFactory_ Compatible auction factory with deployed code.
    function setAuctionFactory(address auctionFactory_) external;

    /// @notice Returns the settings supplying the current Safe.
    /// @return Protocol settings fixed at deployment.
    function settings() external view returns (IProtocolSettings);

    /// @notice Returns the sweeper used to claim Policy revenue rows.
    /// @return Row sweeper fixed at deployment.
    function sweeper() external view returns (PolicySweeper);

    /// @notice Returns the factory for new auctions and migrations on each Policy's next kick.
    /// @return Current auction factory address.
    function auctionFactory() external view returns (address);
}
