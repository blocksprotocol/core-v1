// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IBlockRevenue } from "./IBlockRevenue.sol";

/// @title IJar
/// @notice Holds revenue and inventory and delivers assets on one Block's home chain.
interface IJar is IBlockRevenue {
    /// @notice Emitted when the jar submits home-bound BUX to the bridge.
    /// @param amount Bridged BUX base units (6 decimals).
    /// @param messageId Identifier returned by the CCIP router.
    event BridgedHome(uint256 amount, bytes32 indexed messageId);
    /// @notice Emitted when received assets are queued for a Policy claim.
    /// @param token Block's home token address.
    /// @param asset Token held in the row.
    /// @param amount Accrued token base units.
    event PolicyAccrued(address indexed token, address indexed asset, uint256 amount);
    /// @notice Emitted when a Policy row is transferred to its current destination.
    /// @param token Block's home token address.
    /// @param policy Receiving Policy, or zero for direct vault delivery.
    /// @param asset Transferred token.
    /// @param amount Claimed token base units.
    event PolicyClaimed(
        address indexed token, address indexed policy, address indexed asset, uint256 amount
    );
    /// @notice Emitted when a Policy row for an asset no longer retained becomes inventory.
    /// @dev If BUX was initialized before the row accrued, the asset stays in the jar and the
    /// cleared amount becomes inventory. The claim recognizes no new revenue.
    /// If BUX later adopts the asset as its underlying, the claim converts it to BUX but this
    /// event still names the asset in the cleared row.
    /// @param token Block's home token address.
    /// @param asset Token moved out of the Policy row.
    /// @param amount Token base units moved, equal to the cleared row.
    event PolicyMovedToInventory(address indexed token, address indexed asset, uint256 amount);

    /// @notice Thrown when anyone other than the factory calls initialization.
    error OnlyFactory();
    /// @notice Thrown when initialization is repeated or targets the implementation.
    error AlreadyInitialized();
    /// @notice Thrown when a native deposit has the wrong value or a token deposit includes value.
    error InvalidValue();
    /// @notice Thrown when a receipt, payment or bridge request has a zero amount.
    error ZeroAmount();
    /// @notice Thrown when anyone other than the current Releaser calls inventory release.
    error OnlyReleaser();
    /// @notice Thrown when anyone other than this jar calls vault delivery.
    error OnlySelf();
    /// @notice Thrown when a release exceeds recorded inventory.
    error InsufficientInventory();
    /// @notice Thrown when the received BUX payment differs from the required payment.
    error InsufficientBux();
    /// @notice Thrown when an asset's balance is below its accounted amount during sync.
    error BalanceShortfall();
    /// @notice Thrown when a nonempty Policy row is claimed before the Block is live.
    error BlockNotLive();

    // Initialization

    /// @notice Binds a clone to a Block's home chain and token once.
    /// @dev Only the factory may call. The implementation is locked.
    /// @param homeChainId_ Home EVM chain ID.
    /// @param token_ Block's home token address.
    function initialize(uint256 homeChainId_, address token_) external;

    // Receipts and sales

    /// @notice Receives revenue and routes the received amount.
    /// @dev Anyone may call. At home, the Block's own token is burned before BUX is read. Other
    /// receipts require configured BUX and route to inventory, vault delivery, Policy rows or
    /// home-bound BUX. At home, BUX and retained receipts wait in Policy rows until the Block is
    /// live. A canceled Block cannot receive vault or Policy delivery. Inventory remains sellable.
    /// Token deposits require zero `msg.value`.
    /// @param asset Received token, or zero for native currency.
    /// @param amount Positive token base units, or wei equal to `msg.value` for native deposits.
    /// @param source Unverified attribution label. Zero means unattributed.
    function deposit(address asset, uint256 amount, address source) external payable;

    /// @notice Routes unaccounted surplus as a deposit.
    /// @dev Anyone may call. Requires a balance above the accounted amount.
    /// Records the surplus as unattributed revenue.
    /// @param asset Token to reconcile, or zero for native currency, which is wrapped.
    function sync(address asset) external;

    /// @notice Transfers an asset directly to the vault and syncs it atomically.
    /// @dev Only this jar may call. Failed delivery can be caught and left as a Policy row.
    /// @param asset Token accepted by the destination vault.
    /// @param amount Token base units to transfer.
    /// @param vault Destination vault to sync after transfer.
    function pushToVault(address asset, uint256 amount, address vault) external;

    /// @notice Collects exact BUX payment, sends inventory and routes the proceeds.
    /// @dev Only the current Releaser may call. The Block need not be live.
    /// The jar charges no sale fee. The destination can charge a work fee.
    /// @param asset Inventory token sold.
    /// @param units Nominal token base units to transfer, at most recorded inventory.
    /// @param buxIn Positive BUX base units required as payment.
    /// @param to Recipient of purchased inventory.
    function release(address asset, uint256 units, uint256 buxIn, address to) external;

    // Policy claims

    /// @notice Claims one row using the current destination once the Block is live.
    /// @dev Anyone may call. Non-BUX assets no longer retained follow normal receipt routing.
    /// @param asset Token whose row is claimed.
    /// @return Token base units transferred or reprocessed, or zero for an empty row.
    function claimPolicyAsset(address asset) external returns (uint256);

    // Bridge delivery

    /// @notice Sends home-bound BUX to this jar's deterministic address on its home chain.
    /// @dev Anyone may call. The caller pays the native CCIP fee. Quote the router's
    /// `getFee` for this token-only message first. Excess `msg.value` is not refunded.
    /// Delivery does not call this jar. `sync(BUX)` books the received balance separately.
    /// @param amount Positive BUX base units, at most `homeBound(BUX)`.
    /// @return messageId Identifier returned by the CCIP router.
    function bridgeHome(uint256 amount) external payable returns (bytes32 messageId);

    // Views

    /// @notice Returns the factory that fixes this jar's deterministic identity.
    /// @return Factory authorized to initialize clones.
    function factory() external view returns (address);

    /// @notice Returns the Block's home chain.
    /// @return Home EVM chain ID bound during initialization.
    function homeChainId() external view returns (uint256);

    /// @notice Returns the Block's home token address.
    /// @return Token bound during initialization.
    function token() external view returns (address);

    /// @notice Returns sellable inventory, excluding Policy rows and home-bound BUX.
    /// @param asset Inventory token to query.
    /// @return Sellable token base units. Zero means no inventory.
    function inventory(address asset) external view returns (uint256);

    /// @notice Returns BUX received away from home and not yet bridged.
    /// @param asset BUX token address. Other assets have no home-bound balance.
    /// @return BUX base units awaiting bridging. Zero at home.
    function homeBound(address asset) external view returns (uint256);

    /// @notice Returns assets waiting for a Policy claim.
    /// @param asset Token held in the row.
    /// @return Claimable token base units. Zero means an empty row.
    function policyClaimable(address asset) external view returns (uint256);

    /// @notice Returns the total reserved across inventory, Policy rows and home-bound BUX.
    /// @param asset Token to query, or zero for native currency.
    /// @return Reserved token base units or wei. Zero means no recorded reserves.
    function accounted(address asset) external view returns (uint256);
}
