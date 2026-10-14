// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { IBlockFactory } from "./IBlockFactory.sol";
import { ICoinAttribution } from "./ICoinAttribution.sol";
import { IJarFactory } from "./IJarFactory.sol";

/// @title ICoinFactory
/// @notice Launches Coins instantly with creator fees claimable in kind from the hook.
interface ICoinFactory is ICoinAttribution {
    /// @dev `isBlock` must be false. Combined cliff and vesting duration cannot exceed 1,825 days.
    /// Prebuy output cannot exceed 20% of fixed supply in token base units.
    /// Prices round down to ticks in currency1/currency0 order. 10_000 bps = 100%.
    struct CoinLaunchParams {
        string name;
        string symbol;
        string metadataURI;
        bool isBlock;
        address parent; // Nonzero parent Block registered through the protocol settings.
        address quote; // Deployed quote token. May be the parent token.
        uint256 prebuyQuote; // Quote base units. Zero skips prebuy and escrow creation.
        uint32 cliffDays; // Whole days before vested-token releases begin.
        // Whole days of linear vesting after the cliff. Zero fully vests all tokens at the cliff.
        uint32 vestDays;
        bytes32 appTag; // Unauthenticated launch attribution. Zero means no tag.
        // Zero selects the caller. Forwarders must pass the intended Coin admin.
        // The Coin admin controls the Coin and migration. Rejects `address(1)` at launch.
        address admin;
        // Zero to 10_000 bps of the post-protocol remainder. Parent-token quotes use an effective
        // zero rate.
        uint16 creatorShareBps;
        uint160 openingPriceX96; // Positive quote base units per token base unit, scaled by 2^96.
        // Same units as `openingPriceX96`. Must be greater before rounding to ticks.
        uint160 bondingPriceX96;
        address source; // Jar deposit attribution. Zero means no source.
    }

    /// @notice Emitted when the factory records a completed Coin launch.
    /// @param token Launched Coin token.
    /// @param quote Market quote token.
    /// @param launch Final launch configuration and destinations.
    event Launched(address indexed token, address indexed quote, IBlockFactory.Launch launch);

    /// @notice Emitted when the launcher or Coin admin publishes Coin metadata.
    /// @param token Coin token.
    /// @param metadataURI Metadata location supplied by the launcher or Coin admin.
    event MetadataSet(address indexed token, string metadataURI);

    /// @notice Emitted when the Coin admin sets the destination for future creator payments.
    /// @param token Coin token.
    /// @param payout Recipient for future accruals and vested-token releases.
    event PayoutSet(address indexed token, address payout);

    /// @notice Emitted when a payout clone is initialized for a Coin.
    /// @param token Coin token.
    /// @param payout Fixed-weight payout clone.
    /// @param recipients Distinct payment recipients.
    /// @param weights Positive recipient weights in bps, totaling 10_000.
    event PayeesSet(
        address indexed token, address indexed payout, address[] recipients, uint16[] weights
    );

    /// @notice Emitted when control of a Coin is transferred.
    /// @param token Coin token.
    /// @param admin New nonzero Coin admin.
    event AdminTransferred(address indexed token, address admin);

    /// @notice Emitted when a Coin's stored creator share is set.
    /// @param token Coin token.
    /// @param creatorShareBps Rate in bps of the post-protocol remainder.
    /// Parent-token quotes use an effective zero rate.
    event CreatorShareSet(address indexed token, uint16 creatorShareBps);

    /// @notice Emitted when the required native launch payment is set.
    /// @param launchFeeWei Payment in wei. Zero disables the native launch fee.
    event LaunchFeeSet(uint256 launchFeeWei);

    /// @notice Emitted when the stored protocol share of the ordinary swap fee is set.
    /// @param protocolShareBps Rate in bps of the ordinary swap fee. Parent-token quotes use an
    /// effective zero rate.
    event ProtocolShareSet(uint16 protocolShareBps);

    /// @notice Emitted when a Coin's canonical market migrates.
    /// @param token Coin token.
    /// @param source Hook exporting the tracked liquidity.
    /// @param destination Hook importing the tracked liquidity.
    /// @param poolId Destination PoolManager pool identifier.
    event CanonicalHookChanged(
        address indexed token, address indexed source, address indexed destination, bytes32 poolId
    );

    /// @notice Thrown when the native payment differs from the required launch fee.
    error WrongLaunchFee();

    /// @notice Thrown when the requested quote token has no deployed code.
    error UnsupportedQuote();

    /// @notice Thrown when prebuy output exceeds 20% of the fixed token supply.
    error PrebuyTooLarge();

    /// @notice Thrown when combined cliff and vesting duration exceeds 1,825 days.
    error VestingOutOfRange();

    /// @notice Thrown when the caller is not the registered Coin admin.
    error NotAdmin();

    /// @notice Thrown when the token has no completed launch record.
    /// @param token Token without a completed launch record.
    error NotRegistered(address token);

    /// @notice Thrown when a required address is zero or a payout uses the reserved protocol row.
    error ZeroAddress();

    /// @notice Thrown when the caller is not the Safe.
    error OnlySafe();

    /// @notice Thrown when factory endpoints, parent registration, prices or migration are invalid.
    error InvalidConfiguration();

    /// @notice Thrown when the hook receives less or more quote than the requested prebuy funding.
    error TransferMismatch();

    /// @notice Thrown when the protocol share exceeds the current settings cap.
    error InvalidFeePolicy();

    /// @notice Thrown when the creator share exceeds 10_000 bps.
    error CreatorShareTooHigh();

    /// @notice Thrown when the initial launch hook has no deployed code.
    error HookNotDeployed();

    /// @notice Thrown when a Coin launch requests Block status.
    error BlockSaleRequired();

    /// @notice Thrown when the migration registry has not authorized the path between hooks.
    error UpgradeNotRegistered();

    // Launch

    /// @notice Launches a Coin, seeds its market and optionally funds a vesting prebuy.
    /// @dev Anyone may call. `isBlock` must be false and the native payment must equal `launchFee`.
    /// Empty payee arrays select the Coin admin as payout. Otherwise supply one to 16 distinct
    /// recipients above `address(1)`, excluding the payout clone. Array lengths must match.
    /// Weights must be positive and total 10_000 bps.
    /// For a prebuy, the caller must approve the factory to spend `prebuyQuote` base units of
    /// `quote`. The hook must receive the full amount.
    /// @param p Coin configuration, prices and optional prebuy funding.
    /// @param recipients Payment recipients. Empty payee arrays select the Coin admin.
    /// @param weights Recipient weights in bps. Empty only with empty recipients.
    /// @return token Newly deployed Coin token.
    function launch(
        CoinLaunchParams calldata p,
        address[] calldata recipients,
        uint16[] calldata weights
    ) external payable returns (address token);

    // Registry

    /// @notice Publishes metadata for a registered Coin.
    /// @dev Only the Coin admin may call. Emits the URI without changing the stored launch record.
    /// @param token Registered Coin token.
    /// @param metadataURI Metadata location to publish.
    function setMetadata(address token, string calldata metadataURI) external;

    /// @notice Sets the destination for future creator accruals and vested-token releases.
    /// @dev Only the Coin admin may call. Existing accruals stay with their credited recipient.
    /// @param token Registered Coin token.
    /// @param payout Recipient. Rejects zero and the reserved `address(1)` protocol row.
    function setPayout(address token, address payout) external;

    /// @notice Creates an immutable payout clone for future creator payments.
    /// @dev Only the Coin admin may call. Array lengths must match and contain one to 16 entries.
    /// Recipients must be distinct, above `address(1)` and exclude the payout clone.
    /// Weights must be positive and total 10_000 bps. Existing accruals stay with their recipient.
    /// @param token Registered Coin token.
    /// @param recipients Distinct payment recipients. Cannot be empty.
    /// @param weights Positive recipient weights in bps.
    function setPayees(address token, address[] calldata recipients, uint16[] calldata weights)
        external;

    /// @notice Transfers Coin control while retaining the payout destination.
    /// @dev Only the Coin admin may call.
    /// @param token Registered Coin token.
    /// @param newAdmin Nonzero recipient of Coin control and migration authority.
    function transferAdmin(address token, address newAdmin) external;

    /// @notice Sets a Coin's creator share for future swaps.
    /// @dev Only the Coin admin may call. The share rounds down from the post-protocol remainder.
    /// The Block keeps the rounding remainder. Parent-token quotes use an effective zero rate.
    /// @param token Registered Coin token.
    /// @param creatorShareBps Rate from zero to 10_000 bps of the post-protocol remainder.
    function setCreatorShareBps(address token, uint16 creatorShareBps) external;

    // Settings

    /// @notice Sets the native payment required for future Coin launches.
    /// @dev Only the Safe may call.
    /// @param launchFeeWei Required payment in wei. Zero disables the native launch fee.
    function setLaunchFee(uint256 launchFeeWei) external;

    /// @notice Sets the protocol share for future Coin swaps.
    /// @dev Only the Safe may call. The current settings cap applies.
    /// The share rounds down. The remainder funds creator and Block allocations.
    /// @param protocolShareBps Rate in bps of the ordinary swap fee. Zero disables the protocol
    /// allocation.
    function setProtocolShareBps(uint16 protocolShareBps) external;

    /// @notice Pauses Coin launches, swaps and donations through this factory.
    /// @dev Only the Safe may call. Claims, sweeps and migration remain available.
    function pause() external;

    /// @notice Lifts the local pause on Coin markets.
    /// @dev Only the Safe may call. The core Block factory may still pause markets.
    function unpause() external;

    // Migration

    /// @notice Migrates a Coin's canonical market along an authorized path.
    /// @dev Only the Coin admin may call. Pausing does not block migration. The migration registry
    /// owner approves trusted destinations using the same PoolManager. Registry ownership is
    /// transferable. Claims stay in the source hook. Vault backing does not move.
    /// @param token Registered Coin with a completed launch.
    /// @param destination Hook authorized for migration from the current canonical hook.
    function migrateLiquidity(address token, address destination) external;

    // Views

    /// @notice Returns the current Safe through the core Block factory.
    /// @return Current Safe.
    function safe() external view returns (address);

    /// @notice Returns the FeePool through the fixed core Block factory.
    /// @return Current protocol fee recipient.
    function feePool() external view returns (address);

    /// @notice Returns whether this factory or the core Block factory is paused.
    /// @return True when either factory pauses Coin markets.
    function paused() external view returns (bool);

    /// @notice Reverts when either this factory or the core Block factory is paused.
    function requireMarketsActive() external view;

    /// @notice Returns a Coin's stored launch record.
    /// @param token Coin token.
    /// @return Launch record. All fields are zero for an unknown token.
    function launches(address token) external view returns (IBlockFactory.Launch memory);

    /// @notice Returns the current payout and effective swap fee rates.
    /// @dev Both rates are zero for parent-token quotes. Creator fees accrue in kind.
    /// @param token Coin token.
    /// @return payout Current creator recipient. Zero for an unknown token.
    /// @return protocolBps Protocol rate in bps of the ordinary swap fee.
    /// @return creatorBps Creator rate in bps of the post-protocol remainder.
    function swapFeeTerms(address token)
        external
        view
        returns (address payout, uint16 protocolBps, uint16 creatorBps);

    /// @notice Returns the current canonical pool key, updated after migration.
    /// @param token Coin token.
    /// @return Pool currencies, fee, spacing and hook. All fields are zero for an unknown token.
    function poolKeyOf(address token) external view returns (PoolKey memory);

    /// @notice Returns whether a Coin has a completed launch record.
    /// @param token Coin token.
    /// @return True after launch completes.
    function isRegistered(address token) external view returns (bool);

    /// @notice Returns a Coin's registered parent Block token.
    /// @param token Coin token.
    /// @return Parent Block token. Zero for an unknown Coin.
    function parentOf(address token) external view returns (address);

    /// @notice Returns the destination for future creator accruals and vested-token releases.
    /// @param token Coin token.
    /// @return Current payout. Zero for an unknown Coin.
    function payoutOf(address token) external view returns (address);

    /// @notice Returns the Coin admin authorized to update control and migrate liquidity.
    /// @param token Coin token.
    /// @return Current Coin admin. Zero for an unknown Coin.
    function adminOf(address token) external view returns (address);

    /// @notice Returns the revenue configuration for a Coin's parent or a registered Block.
    /// @param token Coin token or Block token registered through the protocol settings.
    /// @return Vault or staking configuration. Zero if neither a Coin nor a registered factory
    /// resolves the token.
    function vaultOf(address token) external view returns (address);

    /// @notice Returns the fixed Coin supply.
    /// @return Supply in 18-decimal token base units.
    function SUPPLY() external view returns (uint256);

    /// @notice Returns the maximum prebuy output as a fraction of fixed supply.
    /// @return Maximum output in bps of fixed supply.
    function MAX_PREBUY_BPS() external view returns (uint256);

    /// @notice Returns the maximum combined cliff and vesting duration.
    /// @return Duration in whole days.
    function MAX_VEST_DAYS() external view returns (uint256);

    /// @notice Returns the fixed core Block factory supplying endpoints, authority and the pause.
    /// @return Core Block factory.
    function blockFactory() external view returns (IBlockFactory);

    /// @notice Returns the PoolManager bound at deployment.
    /// @return Fixed PoolManager.
    function poolManager() external view returns (IPoolManager);

    /// @notice Returns the BUX token bound at deployment.
    /// @return BUX token with 6 decimals.
    function bux() external view returns (address);

    /// @notice Returns the initial hook used for new Coin launches.
    /// @dev Migrated Coins use `canonicalHookOf`.
    /// @return Fixed launch hook.
    function hook() external view returns (address);

    /// @notice Returns the fixed registry authorizing hook migration paths.
    /// @return Registry whose owner approves migration destinations and may transfer ownership.
    function migrationRegistry() external view returns (address);

    /// @notice Returns the fixed factory used to create parent jars.
    /// @return Parent jar factory.
    function jarFactory() external view returns (IJarFactory);

    /// @notice Returns the required native launch payment.
    /// @return Payment in wei. Zero disables the native launch fee.
    function launchFee() external view returns (uint256);

    /// @notice Returns the parent Block's jar selected for a Coin.
    /// @param token Coin token.
    /// @return Parent jar. Zero for an unknown Coin.
    function jarOf(address token) external view returns (address);

    /// @notice Returns the source attribution attached to a Coin's jar deposits.
    /// @param token Coin token.
    /// @return Source address. Zero for an unknown Coin or no attribution.
    function sourceOf(address token) external view returns (address);

    /// @notice Returns whether a Coin has completed launch.
    /// @dev Migration preserves this flag.
    /// @param token Coin token.
    /// @return True after launch completes.
    function marketLive(address token) external view returns (bool);

    /// @notice Returns a Coin's current canonical hook, updated after migration.
    /// @param token Coin token.
    /// @return Current hook. Zero before launch completion.
    function canonicalHookOf(address token) external view returns (address);

    /// @notice Returns the stored protocol share of the ordinary Coin swap fee.
    /// @dev Parent-token quotes use an effective zero rate.
    /// @return Stored rate in bps.
    function protocolShareBps() external view returns (uint16);

    /// @notice Returns a Coin's stored creator share.
    /// @dev `swapFeeTerms` returns the effective rate, which is zero for parent-token quotes.
    /// @param token Coin token.
    /// @return Stored bps of the post-protocol remainder. Zero for an unknown Coin.
    function creatorShareBps(address token) external view returns (uint16);
}
