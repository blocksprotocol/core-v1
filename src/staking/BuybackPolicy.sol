// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from
    "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { IAuction } from "../interfaces/IAuction.sol";
import { IAuctionFactory } from "../interfaces/IAuctionFactory.sol";
import { IBUX } from "../interfaces/IBUX.sol";
import { IBlockRegistry } from "../interfaces/IBlockRegistry.sol";
import { IBuybackConfig } from "../interfaces/IBuybackConfig.sol";
import { IBuybackPolicy } from "../interfaces/IBuybackPolicy.sol";
import { IProtocolSettings } from "../interfaces/IProtocolSettings.sol";
import { IStakingVault } from "../interfaces/IStakingVault.sol";

/// @title BuybackPolicy
/// @notice Converts BUX revenue to underlying for one staking vault.
/// @dev The Policy is its Auction's receiver and `governance`. Callers cannot select recipients
/// or pricing. The Safe is trusted to select a compatible auction factory.
/// Funds leave only for the auction, BUX redemption or the vault's `addRevenue`.
/// BUX and BUX's reserve asset need no auction.
/// @custom:security-contact security@blocks.fm
contract BuybackPolicy is IBuybackPolicy, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // Opening value of each lot: 1e18 whole underlying tokens, scaled by 1e18.
    uint256 private constant STARTING_PRICE = 1e36;
    // Seconds per price step. Auction's default 50 bps decay is about 5.84% per minute.
    // Nearest-rounded ray (1e27) decay reaches zero after 62_710 seconds, ending any remaining lot.
    uint256 private constant STEP_DURATION = 5;
    // Minimum outside share supply.
    uint256 private constant MINIMUM_SHARES = 1e6;

    /// @notice Returns the staking vault receiving revenue.
    /// @return Staking vault fixed at deployment.
    IStakingVault public immutable wrapper;
    /// @notice Returns the BUX revenue token.
    /// @return BUX resolved from the registry's settings at deployment.
    IERC20 public immutable bux;
    /// @notice Returns the staking vault's underlying ERC-20 asset.
    /// @return Underlying resolved from the staking vault at deployment.
    IERC20 public immutable underlying;
    /// @notice Returns the shared auction factory and row sweeper configuration.
    /// @return Configuration fixed at deployment.
    IBuybackConfig public immutable config;

    /// @inheritdoc IBuybackPolicy
    IAuction public auction;
    /// @inheritdoc IBuybackPolicy
    address public auctionFactory;

    // Initialization

    /// @notice Binds the staking vault and buyback configuration once at deployment.
    /// @dev The staking factory deploys one Policy per staking vault with compatible dependencies.
    /// BUX and BUX's reserve asset need no auction. Other underlying assets must expose
    /// `decimals()` and have at most 18 decimals.
    /// @param wrapper_ Staking vault receiving revenue in its underlying asset.
    /// @param config_ Shared auction factory and row sweeper configuration.
    constructor(IStakingVault wrapper_, IBuybackConfig config_) {
        wrapper = wrapper_;
        bux = IERC20(IProtocolSettings(IBlockRegistry(wrapper_.factory()).settings()).bux());
        underlying = IERC20(wrapper_.asset());
        config = config_;
        if (
            address(underlying) != address(bux)
                && address(underlying) != address(IBUX(address(bux)).underlying())
        ) _buildAuction(config_.auctionFactory());
    }

    // Auction operations

    /// @inheritdoc IBuybackPolicy
    function kickAuction() external nonReentrant returns (uint256) {
        if (address(auction) == address(0)) revert InvalidConversionMode();
        config.sweeper().claimAll(address(wrapper));
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

    // Revenue reporting

    /// @inheritdoc IBuybackPolicy
    function reportUnderlying(uint256 buxToRedeem) external nonReentrant {
        config.sweeper().claimAll(address(wrapper));
        if (buxToRedeem != 0) {
            if (address(underlying) != address(IBUX(address(bux)).underlying())) {
                revert InvalidConversionMode();
            }
            IBUX(address(bux)).redeem(buxToRedeem, address(this));
        }
        _reportUnderlying(buxToRedeem);
    }

    // Internal functions

    function _buildAuction(address nextFactory) private {
        if (address(auction) != address(0)) auction.sweep(address(bux));
        IAuction nextAuction = IAuction(
            IAuctionFactory(nextFactory).createNewAuction(
                address(underlying), address(this), address(this), STARTING_PRICE
            )
        );
        nextAuction.enable(address(bux));
        nextAuction.setStepDuration(STEP_DURATION);
        nextAuction.setGovernanceOnlyKick(true);
        // Minimum price: one underlying token base unit per whole BUX.
        // Lots below one BUX cannot be bought at this price.
        nextAuction.setMinimumPrice(10 ** (18 - IERC20Metadata(address(underlying)).decimals()));
        auction = nextAuction;
        auctionFactory = nextFactory;
    }

    function _reportUnderlying(uint256 buxIn) private {
        uint256 amount = underlying.balanceOf(address(this));
        uint256 outside = wrapper.totalSupply() - wrapper.balanceOf(address(wrapper));
        if (amount == 0 || outside < MINIMUM_SHARES) return;
        underlying.forceApprove(address(wrapper), amount);
        wrapper.addRevenue(amount);
        emit RevenueBought(buxIn, amount);
    }
}
