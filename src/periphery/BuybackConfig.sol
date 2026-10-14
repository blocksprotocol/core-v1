// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IBuybackConfig } from "../interfaces/IBuybackConfig.sol";
import { IProtocolSettings } from "../interfaces/IProtocolSettings.sol";

import { PolicySweeper } from "./PolicySweeper.sol";

/// @title BuybackConfig
/// @notice Holds the shared auction factory and row sweeper for Policies.
/// @dev Settings and the sweeper are fixed at deployment. The Safe may replace the auction factory.
/// The setter checks only that the new address has code. The Safe must ensure compatibility.
/// The contract must never custody a Block's funds.
/// @custom:security-contact security@blocks.fm
contract BuybackConfig is IBuybackConfig {
    /// @inheritdoc IBuybackConfig
    IProtocolSettings public immutable settings;
    /// @inheritdoc IBuybackConfig
    PolicySweeper public immutable sweeper;
    /// @inheritdoc IBuybackConfig
    address public auctionFactory;

    modifier onlySafe() {
        if (msg.sender != settings.safe()) revert OnlySafe();
        _;
    }

    /// @notice Binds settings, the initial auction factory and the sweeper once at deployment.
    /// @dev The deployer must supply compatible dependencies. The constructor does not check code.
    /// @param settings_ Protocol settings supplying the current Safe.
    /// @param auctionFactory_ Initial factory for Policy auctions.
    /// @param sweeper_ Fixed sweeper claiming Policy revenue rows.
    constructor(IProtocolSettings settings_, address auctionFactory_, PolicySweeper sweeper_) {
        settings = settings_;
        auctionFactory = auctionFactory_;
        sweeper = sweeper_;
    }

    /// @inheritdoc IBuybackConfig
    function setAuctionFactory(address auctionFactory_) external onlySafe {
        if (auctionFactory_.code.length == 0) revert InvalidAddress();
        auctionFactory = auctionFactory_;
        emit AuctionFactorySet(auctionFactory_);
    }
}
