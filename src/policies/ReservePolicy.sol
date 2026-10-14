// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from
    "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { IAuction } from "../interfaces/IAuction.sol";
import { IAuctionFactory } from "../interfaces/IAuctionFactory.sol";
import { IBlockVault } from "../interfaces/IBlockVault.sol";
import { IBuybackConfig } from "../interfaces/IBuybackConfig.sol";
import { IReservePolicy } from "../interfaces/IReservePolicy.sol";

/// @title ReservePolicy
/// @notice Buys one Block's reserve through an auction and forwards assets to its vault.
/// @dev The factory must initialize each clone once without reading its uninitialized vault.
/// The Policy is its Auction's receiver and `governance`. Callers cannot select recipients
/// or pricing. The Safe is trusted to select a compatible auction factory.
/// Only BUX enters the auction. Other assets leave only for the bound vault, which syncs them.
/// @custom:security-contact security@blocks.fm
contract ReservePolicy is IReservePolicy, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // Opening value of each lot: 1e18 whole reserve tokens, scaled by 1e18.
    uint256 private constant STARTING_PRICE = 1e36;
    // Seconds per price step. Auction's default 50 bps decay is about 5.84% per minute.
    // Nearest-rounded ray (1e27) decay reaches zero after 62_710 seconds, ending any remaining lot.
    uint256 private constant STEP_DURATION = 5;

    /// @inheritdoc IReservePolicy
    address public immutable factory;
    /// @inheritdoc IReservePolicy
    IBuybackConfig public immutable config;
    /// @inheritdoc IReservePolicy
    IERC20 public immutable bux;

    /// @inheritdoc IReservePolicy
    IBlockVault public vault;
    /// @inheritdoc IReservePolicy
    IERC20 public reserve;
    /// @inheritdoc IReservePolicy
    IAuction public auction;
    /// @inheritdoc IReservePolicy
    address public auctionFactory;

    // Initialization

    /// @notice Binds the deploying factory, configuration and BUX once for the implementation.
    /// @dev The Policy factory deploys this implementation. Clones share its immutables.
    /// @param config_ Shared auction factory and row sweeper configuration.
    /// @param bux_ ERC-20 revenue token sold for the reserve.
    constructor(IBuybackConfig config_, IERC20 bux_) {
        factory = msg.sender;
        config = config_;
        bux = bux_;
    }

    /// @inheritdoc IReservePolicy
    /// @dev The factory enforces one initialization per clone. This contract has no local guard.
    function initialize(IBlockVault vault_, IERC20 reserve_) external {
        if (msg.sender != factory) revert OnlyFactory();
        vault = vault_;
        reserve = reserve_;
        _buildAuction(config.auctionFactory());
    }

    // Auction operations

    /// @inheritdoc IReservePolicy
    function kickAuction() external nonReentrant returns (uint256) {
        config.sweeper().claimAll(vault.token());
        if (!vault.acceptsBacking(address(reserve))) revert ReserveNotAccepted();
        address nextFactory = config.auctionFactory();
        if (nextFactory != auctionFactory) _buildAuction(nextFactory);

        if (auction.isActive(address(bux))) {
            if (auction.available(address(bux)) > 0) return 0;
            auction.settle(address(bux));
        }
        uint256 balance = bux.balanceOf(address(this));
        if (balance > 0) bux.safeTransfer(address(auction), balance);
        return auction.kick(address(bux));
    }

    // Asset forwarding

    /// @inheritdoc IReservePolicy
    function forward(IERC20 asset) external nonReentrant {
        if (address(asset) == address(bux)) revert BuxOnlyBuysReserve();
        config.sweeper().claimAll(vault.token());
        uint256 amount = asset.balanceOf(address(this));
        if (amount == 0) return;
        asset.safeTransfer(address(vault), amount);
        vault.sync(address(asset));
        emit Forwarded(address(asset), amount);
    }

    // Internal functions

    function _buildAuction(address nextFactory) private {
        if (address(auction) != address(0)) auction.sweep(address(bux));
        IAuction nextAuction = IAuction(
            IAuctionFactory(nextFactory).createNewAuction(
                address(reserve), address(this), address(this), STARTING_PRICE
            )
        );
        nextAuction.enable(address(bux));
        nextAuction.setStepDuration(STEP_DURATION);
        nextAuction.setGovernanceOnlyKick(true);
        // Minimum price: one reserve token base unit per whole BUX.
        // Lots below one BUX cannot be bought at this price.
        nextAuction.setMinimumPrice(10 ** (18 - IERC20Metadata(address(reserve)).decimals()));
        auction = nextAuction;
        auctionFactory = nextFactory;
    }
}
