// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { IBlockBatchSale } from "./IBlockBatchSale.sol";
import { IBlockRegistry } from "./IBlockRegistry.sol";

/// @title IBlockFactory
/// @notice Launches Raised Blocks with fixed sales and records markets, Block admins and payouts.
/// @dev The token address identifies a Block on its home chain. Factory code is immutable.
interface IBlockFactory is IBlockRegistry {
    /// @dev A zero Policy factory selects direct vault delivery.
    /// A nonzero factory receives the vault address and creation data before vault initialization.
    struct LaunchParams {
        string name;
        string symbol;
        string metadataURI;
        bool isBlock; // Must be true for a Raised launch.
        address parent; // Ignored by Raised launches, which register a zero parent.
        address quote; // Must equal the factory's BUX asset.
        bytes32 appTag; // App attribution tag recorded with the launch.
        // Zero selects the caller; adapters must pass the intended Block admin explicitly.
        address admin;
        address policyFactory; // Zero selects direct vault delivery.
        bytes policyFactoryData;
        address[] retained; // Extra backing assets admitted at launch; BUX entries are skipped.
    }

    /// @dev Settlement sets market fields for a Raised Block. Launch sets them for a Coin.
    /// The registered admin can change control and payout. Migration can change the pool ID.
    struct Launch {
        address token;
        bool isBlock;
        address parent; // Parent Block token; zero for a Raised Block.
        address quote;
        // Own vault for a Raised Block; parent's vault or staking configuration for a Coin.
        address vault; // Zero for an absent record.
        address escrow; // Vesting escrow; zero when none has been created.
        bytes32 poolId;
        address admin; // Authority over metadata, payout, migration and control transfer.
        address payout; // Destination for creator fees, vested releases and creator revenue shares.
        bytes32 appTag; // App attribution tag recorded with the launch.
        // Market opening time in Unix seconds; zero before a Raised Block settles.
        uint64 launchedAt;
    }

    /// @notice Emitted when a Raised launch records its sale and terms hash.
    /// @param token Token funded into the sale.
    /// @param module Pinned sale clone.
    /// @param isBlock Always true for this factory.
    /// @param termsHash Hash of resolved sale terms, fee, launcher, Policy, Policy code hash and
    /// retained assets.
    event LaunchPrepared(
        address indexed token, address indexed module, bool isBlock, bytes32 termsHash
    );

    /// @notice Emitted when a sale clone is pinned to a token.
    /// @param token Launched token.
    /// @param sale Funded sale clone.
    event SaleCreated(address indexed token, address indexed sale);

    /// @notice Emitted when settlement records a funded market.
    /// @param token Launched token.
    /// @param quote Market quote asset.
    /// @param launch Completed registry record.
    event Launched(address indexed token, address indexed quote, Launch launch);

    /// @notice Emitted when launch metadata is published or updated.
    /// @param token Registered token.
    /// @param metadataURI Published metadata URI.
    event MetadataSet(address indexed token, string metadataURI);

    /// @notice Emitted when the Block admin changes the payout destination.
    /// @param token Registered token.
    /// @param payout Destination for future creator payments.
    event PayoutSet(address indexed token, address payout);

    /// @notice Emitted when an immutable weighted payout is created.
    /// @param token Registered token.
    /// @param payout New payout clone.
    /// @param recipients Fixed payment recipients.
    /// @param weights Recipient weights in bps, totaling 10_000.
    event PayeesSet(
        address indexed token, address indexed payout, address[] recipients, uint16[] weights
    );

    /// @notice Emitted when the Block admin transfers control.
    /// @param token Registered token.
    /// @param admin New Block admin.
    event AdminTransferred(address indexed token, address admin);

    /// @notice Emitted when the Safe changes the launch fee.
    /// @param launchFeeWei Required native-currency payment in wei; zero allows free launches.
    event LaunchFeeSet(uint256 launchFeeWei);

    /// @notice Emitted when the Safe selects the implementation for new sales.
    /// @param implementation Implementation cloned for later launches.
    event SaleImplementationSet(address indexed implementation);

    /// @notice Emitted when the Block admin migrates market custody.
    /// @param token Registered token.
    /// @param source Hook exporting tracked liquidity and inventory.
    /// @param destination Hook accepting market custody.
    /// @param poolId Destination pool identifier.
    event CanonicalHookChanged(
        address indexed token, address indexed source, address indexed destination, bytes32 poolId
    );

    /// @notice Thrown when the native-currency payment differs from the launch fee.
    error WrongLaunchFee();
    /// @notice Thrown when a Raised launch is not marked as a Block or uses a quote other than BUX.
    error BlockMustBeQuotedInBux();
    /// @notice Thrown when the caller is not the registered Block admin.
    error NotAdmin();
    /// @notice Thrown when an operation requires a registered token.
    /// @param token Token absent from the registry.
    error NotRegistered(address token);
    /// @notice Thrown when the Block admin is zero or a payout uses a reserved low address.
    error ZeroAddress();
    /// @notice Thrown when the caller is not the Safe.
    error OnlySafe();
    /// @notice Thrown when launch wiring, creator identity or migration state is invalid.
    error InvalidConfiguration();
    /// @notice Thrown when the initial launch hook has no code.
    error HookNotDeployed();
    /// @notice Thrown when the settlement caller is not the token's pinned sale.
    error InvalidLaunchModule();
    /// @notice Thrown when the market is already funded.
    error MarketAlreadyLive();
    /// @notice Thrown when the migration registry has not authorized the directed hook path.
    error UpgradeNotRegistered();

    // Launch

    /// @notice Launches a Raised Block with fixed sale terms and an optional weighted payout.
    /// @dev Anyone may call while launches are unpaused. The caller pays the exact launch fee
    /// in wei and funds priority in BUX base units (6 decimals).
    /// A zero creator resolves to the Block admin. A nonzero creator must equal the Block admin.
    /// Empty payout arrays select the Block admin. Otherwise, they must define one to 16 unique
    /// recipients with positive weights totaling 10_000 bps. Addresses zero and one are reserved.
    /// @param p Metadata, destinations and Policy creation configuration.
    /// @param terms Fixed sale amounts and schedule, with zero creator resolved before hashing.
    /// @param recipients Fixed payees. Empty with `weights` selects the Block admin.
    /// @param weights Recipient weights in bps, with 10_000 bps = 100%.
    /// @return token Newly deployed token.
    /// @return sale Funded sale clone.
    function launchBlock(
        LaunchParams calldata p,
        IBlockBatchSale.Terms calldata terms,
        address[] calldata recipients,
        uint16[] calldata weights
    ) external payable returns (address token, address sale);

    /// @notice Funds the market and creator escrow.
    /// @dev Only the token's pinned sale may call.
    /// The sale pays its fee first. Settlement remains available while paused.
    /// @param token Token whose sale is settling.
    /// @param marketTokens Hook inventory in token base units (18 decimals).
    /// @param proceeds Net market funding in BUX base units.
    /// @param clearingPriceX96 BUX base units per token base unit, scaled by 2^96.
    /// @param creatorFill Vested allocation in token base units (18 decimals); zero skips escrow
    /// creation.
    function finalizeBlockSale(
        address token,
        uint256 marketTokens,
        uint256 proceeds,
        uint160 clearingPriceX96,
        uint256 creatorFill
    ) external;

    // Registry

    /// @notice Publishes new metadata for a registered token.
    /// @dev Only the Block admin may call.
    /// @param token Registered token.
    /// @param metadataURI New metadata URI.
    function setMetadata(address token, string calldata metadataURI) external;

    /// @notice Sets the destination for future creator payments.
    /// @dev Only the Block admin may call. A Block's jar can receive payments for its community.
    /// @param token Registered token.
    /// @param payout Payment destination; addresses zero and one are reserved.
    function setPayout(address token, address payout) external;

    /// @notice Installs an immutable weighted payout.
    /// @dev Only the Block admin may call. Funds in the old payout stay with its payees.
    /// Requires one to 16 unique recipients with positive weights totaling 10_000 bps.
    /// Addresses zero and one are reserved.
    /// @param token Registered token.
    /// @param recipients New fixed payout recipients.
    /// @param weights Recipient weights in bps, with 10_000 bps = 100%.
    function setPayees(address token, address[] calldata recipients, uint16[] calldata weights)
        external;

    /// @notice Transfers control without changing the payout.
    /// @dev Only the Block admin may call.
    /// @param token Registered token.
    /// @param newAdmin Nonzero successor Block admin.
    function transferAdmin(address token, address newAdmin) external;

    // Settings

    /// @notice Sets the fee for future launches.
    /// @dev Only the Safe may call.
    /// @param launchFeeWei Native-currency fee in wei; zero allows free launches.
    function setLaunchFee(uint256 launchFeeWei) external;

    /// @notice Sets the implementation for future sale clones.
    /// @dev Only the Safe may call. Existing clones and funded terms remain fixed.
    /// @param implementation Contract with code to clone for new sales.
    function setSaleImplementation(address implementation) external;

    /// @notice Pauses launches and market operations using the shared gate.
    /// @dev Only the Safe may call. Sale commitments, close, expiry, settlement, migration,
    /// vault redemption and claims remain open.
    function pause() external;

    /// @notice Resumes activity through the shared gate.
    /// @dev Only the Safe may call.
    function unpause() external;

    // Migration

    /// @notice Migrates a market along a registry-authorized path.
    /// @dev Only the Block admin may call. The migration registry owner authorizes destinations.
    /// The Safe initially owns that registry. Later Safe changes do not change registry ownership.
    /// Migration works while paused. Accrued claims and vault backing stay in place.
    /// @param token Token with a funded market.
    /// @param destination Hook authorized to receive the current hook's liquidity.
    function migrateLiquidity(address token, address destination) external;

    // Views

    /// @notice Returns the current Safe.
    /// @return Safe address from settings.
    function safe() external view returns (address);

    /// @notice Returns the FeePool endpoint fixed in settings.
    /// @return Fee collection destination; zero before endpoint configuration.
    function feePool() external view returns (address);

    /// @notice Returns whether the shared market gate is paused.
    /// @return Whether gated activity is paused.
    function paused() external view returns (bool);

    /// @notice Checks that the shared launch and market gate is active.
    /// @dev Reverts with `EnforcedPause` while paused.
    function requireMarketsActive() external view;

    /// @notice Returns the recorded launch data.
    /// @param token Token to look up.
    /// @return Registry record; all fields are zero or false when absent.
    function launches(address token) external view returns (Launch memory);

    /// @notice Returns the recorded market key.
    /// @param token Token to look up.
    /// @return Current market key; zero fields before settlement or when absent.
    function poolKeyOf(address token) external view returns (PoolKey memory);

    /// @notice Returns the registered parent token.
    /// @param token Token to look up.
    /// @return Parent token; zero for Raised Blocks and unregistered tokens.
    function parentOf(address token) external view returns (address);

    /// @notice Returns the initial issuance of one billion tokens.
    /// @return Initial supply of 1e27 token base units (18 decimals).
    function SUPPLY() external view returns (uint256);

    /// @notice Returns the fixed PoolManager used by launches.
    /// @return PoolManager endpoint.
    function poolManager() external view returns (IPoolManager);

    /// @notice Returns the fixed BUX quote asset.
    /// @return BUX token address.
    function bux() external view returns (address);

    /// @notice Returns the initial launch hook.
    /// @dev Individual market migrations do not change this value.
    /// @return Hook used for new markets.
    function hook() external view returns (address);

    /// @notice Returns the fixed implementation for weighted payout clones.
    /// @return Payout implementation address.
    function payoutImplementation() external view returns (address);

    /// @notice Returns the implementation used for future sale clones.
    /// @return Current sale implementation.
    function saleImplementation() external view returns (address);

    /// @notice Returns the registry authorizing directed hook migrations.
    /// @return Migration registry address.
    function migrationRegistry() external view returns (address);

    /// @notice Returns the current launch fee.
    /// @return Required native-currency payment in wei; zero allows free launches.
    function launchFee() external view returns (uint256);

    /// @notice Returns whether settlement has funded the market.
    /// @param token Token to look up.
    /// @return Whether its market is live.
    function marketLive(address token) external view returns (bool);

    /// @notice Returns the hook currently responsible for a funded market.
    /// @param token Token to look up.
    /// @return Current hook, including migrations; zero before settlement or when absent.
    function canonicalHookOf(address token) external view returns (address);

    /// @notice Returns the sale pinned to a token.
    /// @param token Token to look up.
    /// @return Sale clone; zero for unregistered tokens.
    function saleOf(address token) external view returns (address);
}
