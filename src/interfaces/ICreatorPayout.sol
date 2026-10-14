// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IBlockRevenue } from "./IBlockRevenue.sol";
import { IForwarderFactory } from "./IForwarderFactory.sol";

/// @title ICreatorPayout
/// @notice Allocates receipts to immutable payees and supports fixed forwarder routing.
/// @dev Funding, allocation and withdrawal are separate. Payout changes preserve existing claims.
/// Factories must initialize clones in the deployment transaction.
/// Initialization does not authenticate the clone's deployer.
interface ICreatorPayout is IBlockRevenue {
    /// @notice Emitted when a factory initializes fixed payees.
    /// @param factory Calling factory recorded by the clone.
    /// @param recipients Fixed payment recipients; empty for a jar-only forwarder.
    /// @param weights Recipient weights in bps, totaling 10_000 when nonempty.
    event PayeesInitialized(address indexed factory, address[] recipients, uint16[] weights);
    /// @notice Emitted when processing credits a recipient's withdrawal claim.
    /// @param asset Allocated asset.
    /// @param account Claim recipient.
    /// @param amount Newly credited asset base units.
    event Allocated(address indexed asset, address indexed account, uint256 amount);

    /// @notice Emitted when payout-mode receipts are processed.
    /// @param asset Processed asset.
    /// @param received Cumulative processed receipts in asset base units.
    /// @param allocated Newly allocated asset base units in this call.
    /// @param dust Processed but unallocated asset base units.
    event Distributed(address indexed asset, uint256 received, uint256 allocated, uint256 dust);
    /// @notice Emitted when an existing claim is transferred to its fixed recipient.
    /// @param asset Paid asset.
    /// @param account Claim owner and recipient.
    /// @param amount Paid asset base units.
    event Claimed(address indexed asset, address indexed account, uint256 amount);

    /// @notice Thrown when factory wiring, mode, routing or payee weights are invalid.
    error InvalidConfiguration();
    /// @notice Thrown when a payee is reserved, the clone itself, duplicated or assigned zero
    /// weight.
    error InvalidRecipient();
    /// @notice Thrown when payout distribution is attempted before factory initialization.
    error NotInitialized();
    /// @notice Thrown when payout distribution uses an asset without code or native currency is
    /// sent to payout mode.
    error InvalidAsset();
    /// @notice Thrown when custody cannot cover claims or cumulative receipts decrease.
    /// @param asset Asset with insufficient custody.
    error AssetDeficit(address asset);
    /// @notice Thrown when the selected recipient has no claim for the asset.
    error NothingToClaim();
    /// @notice Thrown when a custody balance change differs from the accounted payment.
    error TransferMismatch();

    // Initialization

    /// @notice Initializes a payout clone once, binding the calling factory and fixed payees.
    /// @dev Only the supplied factory may call, and it must have code.
    /// Requires one to 16 unique recipients other than the clone, with positive weights
    /// totaling 10_000 bps.
    /// @param factory Calling factory recorded by the clone.
    /// @param recipients Fixed payment recipients; zero and one are reserved.
    /// @param weights Recipient weights in bps, with 10_000 bps = 100%.
    function initialize(address factory, address[] calldata recipients, uint16[] calldata weights)
        external;

    /// @notice Initializes fixed forwarder routing once, binding the calling factory and payees.
    /// @dev Any contract with code may call. Requires a nonzero home chain and token.
    /// Creator routing requires the home chain. Requires one to 16 unique recipients other than
    /// the clone, with positive weights totaling 10_000 bps. Payees may be empty only if `jarBps`
    /// is 10_000.
    /// @param config Fixed routing metadata, with jar and creator rates from zero to 10_000 bps.
    /// @param recipients Fixed payment recipients; zero and one are reserved.
    /// @param weights Recipient weights in bps, with 10_000 bps = 100%.
    function initializeForwarder(
        IForwarderFactory.Config calldata config,
        address[] calldata recipients,
        uint16[] calldata weights
    ) external;

    // Distribution

    /// @notice Allocates prefunded ERC-20 receipts to fixed-weight claims in payout mode.
    /// @dev Anyone may call. Each entitlement rounds down, leaving fewer than `MAX_PAYEES`
    /// asset base units unallocated in custody. Later receipts can allocate that dust.
    /// Repeated calls without additional receipts do not change allocation. Forwarders use
    /// `forward`.
    /// @param asset ERC-20 asset with code.
    /// @return allocated Newly allocated asset base units.
    function distribute(address asset) external returns (uint256 allocated);

    /// @notice Processes forwarder receipts into protocol payments, jar deposits and withdrawal
    /// claims.
    /// @dev Anyone may call in forwarder mode. Partner routes charge 20% per processed leg.
    /// Each split rounds the protocol share down, then the creator share of the remainder down.
    /// The jar receives the remainder. A payee receives 100% of the post-protocol remainder.
    /// The creator leg credits the Block's current registry payout, or the jar if it is this clone.
    /// Gross cumulative jar and payee entitlements round down. Jar rounding goes to the payee pool.
    /// Payee rounding stays unallocated in custody. Fees round on each increment, so net claims
    /// can depend on forwarding frequency. On the home chain, the Block's own tokens are burned
    /// in full or deposited to a staking Block's jar.
    /// @param asset Received ERC-20 asset; zero wraps accumulated native currency first.
    /// @return forwarded Asset base units leaving custody immediately through protocol transfers,
    /// jar deposits or own-token consumption; excludes newly credited withdrawal claims.
    function forward(address asset) external returns (uint256 forwarded);

    // Claims

    /// @notice Delivers an existing claim to its fixed recipient by plain transfer.
    /// @dev Anyone may call, regardless of market pauses or the current payout.
    /// The transfer must debit custody by exactly the claim.
    /// A jar can receive community payments. Vaults and staking configurations get plain transfers.
    /// @param asset Asset owed to the recipient.
    /// @param account Fixed recipient whose claim is paid.
    /// @return amount Paid asset base units.
    function claim(address asset, address account) external returns (uint256 amount);

    // Views

    /// @notice Returns the fixed recipients and their weights.
    /// @return recipients Payment recipients; empty for a jar-only forwarder.
    /// @return weights Corresponding weights in bps, totaling 10_000 when nonempty.
    function payees()
        external
        view
        returns (address[] memory recipients, uint16[] memory weights);

    /// @notice Returns allocated amounts still held for withdrawal claims.
    /// @param asset Asset to query.
    /// @return Reserved asset base units.
    function reserved(address asset) external view returns (uint256);

    /// @notice Returns recognized receipts left unallocated after processing.
    /// @dev Includes receipts processed by `distribute` or `forward` only.
    /// @param asset Asset to query.
    /// @return Unallocated asset base units still in custody.
    function roundingDust(address asset) external view returns (uint256);

    /// @notice Returns the maximum number of fixed payees.
    /// @return Payee limit of 16.
    function MAX_PAYEES() external view returns (uint256);

    /// @notice Returns the factory recorded at initialization.
    /// @return Recorded factory; zero before initialization.
    function factory() external view returns (address);

    /// @notice Returns whether the clone uses forwarder routing.
    /// @return Whether forwarder mode is initialized.
    function isForwarder() external view returns (bool);

    /// @notice Returns cumulative receipts recognized by processing.
    /// @dev Unprocessed balances are excluded.
    /// @param asset Asset to query.
    /// @return Processed receipts in asset base units.
    function totalReceived(address asset) external view returns (uint256);

    /// @notice Returns cumulative receipts assigned to claims or immediate payments.
    /// @param asset Asset to query.
    /// @return Allocated asset base units, including paid or consumed amounts.
    function totalAllocated(address asset) external view returns (uint256);

    /// @notice Returns cumulative amounts transferred, deposited to jars or consumed as own tokens.
    /// @param asset Asset to query.
    /// @return Paid or consumed asset base units.
    function totalPaid(address asset) external view returns (uint256);

    /// @notice Returns a recipient's outstanding withdrawal claim.
    /// @param asset Asset to query.
    /// @param account Claim recipient.
    /// @return Withdrawable asset base units.
    function claimable(address asset, address account) external view returns (uint256);
}
