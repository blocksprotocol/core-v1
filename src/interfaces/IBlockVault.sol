// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IBlockRevenueConfig } from "./IBlockRevenueConfig.sol";

/// @title IBlockVault
/// @notice Holds per-Block backing, pays BUX redemptions and credits extras for withdrawal.
/// @dev The Block admin admits assets but cannot withdraw backing.
/// Basket quantities provide no oracle valuation or enforced market floor. Exits work while paused.
interface IBlockVault is IBlockRevenueConfig {
    /// @notice Emitted when a sync books backing net of the work fee, including zero.
    /// @param asset Backing asset.
    /// @param caller Account calling `sync`.
    /// @param appId Always zero; direct transfers carry no app attribution.
    /// @param ref Always zero; reserved receipt reference.
    /// @param amount Net backing received in asset base units.
    event BackingReceived(
        address indexed asset,
        address indexed caller,
        bytes32 indexed appId,
        bytes32 ref,
        uint256 amount
    );

    /// @notice Emitted when sync finds a balance below booked backing plus reserved claims.
    /// @param asset Asset with a deficit.
    /// @param available Remaining booked backing in asset base units, excluding reserved claims.
    event BackingCorrected(address indexed asset, uint256 available);

    /// @notice Emitted when tokens are burned for BUX and extra-asset claims.
    /// @param redeemer Account supplying the burned tokens.
    /// @param to Recipient of BUX and credited claims.
    /// @param tokensBurned Burned token base units (18 decimals).
    /// @param buxOut Immediate payment in BUX base units (6 decimals).
    event Redeemed(
        address indexed redeemer, address indexed to, uint256 tokensBurned, uint256 buxOut
    );

    /// @notice Emitted when redemption credits an extra-asset withdrawal claim.
    /// @param to Account that owns the claim.
    /// @param asset Extra backing asset.
    /// @param amount Credited asset base units.
    event ExtraCredited(address indexed to, address indexed asset, uint256 amount);

    /// @notice Emitted when an account withdraws its extra-asset claim.
    /// @param account Account whose claim is consumed.
    /// @param to Transfer recipient.
    /// @param asset Extra backing asset.
    /// @param amount Transferred asset base units.
    event ExtraWithdrawn(
        address indexed account, address indexed to, address indexed asset, uint256 amount
    );

    /// @notice Emitted when an extra asset occupies a backing slot.
    /// @param asset Newly registered extra asset.
    event ExtraRegistered(address indexed asset);

    /// @notice Emitted when a disabled slot retires with no claims and at most one asset base unit
    /// of backing.
    /// @param asset Retired extra asset.
    event ExtraRetired(address indexed asset);

    /// @notice Emitted when initialization admits an extra or the Block admin sets its admission.
    /// @param asset Configured extra asset.
    /// @param enabled Whether new receipts are admitted.
    event RetainedSet(address indexed asset, bool enabled);

    /// @notice Emitted when the Block admin starts a Policy notice period.
    /// @param policy Proposed destination; zero selects direct vault delivery.
    /// @param codeHash Destination code hash when proposed.
    /// @param effectiveAt Activation time in Unix seconds.
    event PolicyProposed(address indexed policy, bytes32 codeHash, uint64 effectiveAt);

    /// @notice Emitted when the Block admin calls `cancelPolicyProposal`, with or without a
    /// pending proposal.
    /// @param policy Canceled destination; zero means direct vault delivery or no proposal.
    event PolicyProposalCancelled(address indexed policy);

    /// @notice Emitted when a Policy is applied or disabled.
    /// @param policy Active destination; zero selects direct vault delivery.
    /// @param codeHash Destination code hash when applied or disabled.
    event PolicySet(address indexed policy, bytes32 codeHash);

    /// @notice Thrown when redemption is zero or a withdrawal has no claim.
    error ZeroAmount();
    /// @notice Thrown when initialization is attempted on an initialized or locked vault.
    error AlreadyInitialized();
    /// @notice Thrown when the initializer is not the token's factory.
    error OnlyFactory();
    /// @notice Thrown when the token is zero or a recipient is zero or the vault itself.
    error InvalidAddress();
    /// @notice Thrown when an extra asset cannot be admitted, disabled or synchronized.
    /// @param asset Rejected asset.
    error AssetNotAllowed(address asset);
    /// @notice Thrown when admitting an extra would exceed 31 occupied extra slots.
    error TooManyAssets();
    /// @notice Thrown when a redemption amount exceeds outstanding token supply.
    error InsufficientSupply();
    /// @notice Thrown when the caller is not the Block admin.
    error OnlyAdmin();
    /// @notice Thrown when the caller is neither the Block admin nor the Safe.
    error OnlyAdminOrSafe();
    /// @notice Thrown when a Policy is proposed while the Block's market is not live.
    error BlockNotLive();
    /// @notice Thrown when no Policy proposal exists or its notice period has not ended.
    error PolicyNoticePending();
    /// @notice Thrown when a Policy is applied more than seven days after activation.
    error PolicyProposalExpired();

    // Initialization

    /// @notice Initializes a vault once during launch.
    /// @dev Only the factory may call. Any Policy factory creates the initial destination first.
    /// @param token_ Nonzero token whose holders redeem backing.
    /// @param bux_ BUX asset used for immediate redemption payments.
    /// @param policy_ Initial destination; zero selects direct vault delivery.
    /// @param retained_ Extra assets admitted as backing; BUX entries are skipped.
    function initialize(address token_, address bux_, address policy_, address[] calldata retained_)
        external;

    // Funding

    /// @notice Books a transferred surplus net of the work fee.
    /// @dev Anyone may call. BUX can sync before launch. Registered extras can sync deficits
    /// even if disabled or the Block is not live. At or above booked backing plus reserved claims,
    /// extras require retention and a live Block, even with no surplus.
    /// Deficits reduce backing but preserve reserved claims.
    /// Unknown assets are never called. `BackingReceived` reports net backing received, including
    /// zero. Syncing the Block's own token burns the full vault balance, charges no fee, returns
    /// zero and emits no `BackingReceived`. The work fee rounds down. Backing keeps the remainder.
    /// @param asset Asset to book, or the Block's own token to burn.
    /// @return received Net booked asset base units; zero for own-token burns or deficits.
    function sync(address asset) external returns (uint256 received);

    // Redemption

    /// @notice Burns tokens, pays proportional BUX and credits proportional extra-asset claims.
    /// @dev Anyone may call. Syncs pending BUX net of the work fee before pricing, without calling
    /// extra tokens. The caller must approve the vault for `amount`.
    /// Each share rounds down against pre-burn supply. Backing keeps the remainder.
    /// Redemption works inside a PoolManager unlock. BUX sync emits no `BackingReceived` here.
    /// A nonzero fee emits a BUX `Transfer` to FeePool.
    /// @param amount Token base units (18 decimals) to burn; must be nonzero.
    /// @param to Recipient of BUX and claims; cannot be zero or the vault.
    /// @return buxOut Paid BUX base units.
    function redeem(uint256 amount, address to) external returns (uint256 buxOut);

    /// @notice Transfers the caller's credited extra asset to a recipient.
    /// @dev Anyone may call. Assets are independent. A failed transfer preserves the claim.
    /// @param asset Extra asset with a nonzero claim.
    /// @param to Transfer recipient; cannot be zero or the vault.
    /// @return amount Withdrawn asset base units.
    function withdraw(address asset, address to) external returns (uint256 amount);

    // Basket configuration

    /// @notice Admits an extra asset or disables its future receipts.
    /// @dev Only the Block admin may call. BUX cannot be configured here.
    /// Disabling retires a slot only with no reserved claims and at most one asset base unit of
    /// booked backing. Otherwise, the slot stays occupied.
    /// @param asset Extra asset to configure.
    /// @param enabled Whether new receipts are admitted.
    function setRetained(address asset, bool enabled) external;

    // Policy configuration

    /// @notice Starts a seven-day Policy notice period.
    /// @dev Only the Block admin may call. Each proposal restarts notice, even for direct delivery.
    /// Reverts with `BlockNotLive` while the Block's market is not live, so the whole notice
    /// runs while holders can exit. A proposal outlives an admin transfer.
    /// @param next Proposed destination; zero selects direct vault delivery.
    function proposePolicy(address next) external;

    /// @notice Clears the pending Policy proposal without starting a new notice.
    /// @dev Only the Block admin may call. Emits `PolicyProposalCancelled` even with nothing
    /// pending. Within the application window, anyone may still apply the proposal until the
    /// cancel executes.
    function cancelPolicyProposal() external;

    /// @notice Applies the pending Policy from activation through seven days afterward, inclusive.
    /// @dev Anyone may call. Reverts with `PolicyNoticePending` before activation or without a
    /// proposal. Reverts with `PolicyProposalExpired` after the window, requiring a new proposal.
    /// The destination's code is not checked against the proposed hash.
    function applyPolicy() external;

    /// @notice Restores direct vault delivery immediately and clears any pending proposal.
    /// @dev Only the Block admin or the Safe may call.
    function disablePolicy() external;

    // Views

    /// @notice Returns the token whose holders redeem backing.
    /// @return Backed token address.
    function token() external view returns (address);

    /// @notice Returns the BUX asset used for immediate redemption payments.
    /// @return BUX token address.
    function bux() external view returns (address);

    /// @notice Returns booked BUX backing.
    /// @dev Pending BUX receipts enter backing through `sync(bux)` or redemption.
    /// Reverts during reentrancy.
    /// @return Booked BUX base units.
    function backing() external view returns (uint256);

    /// @notice Returns booked backing with BUX first, followed by occupied extra slots.
    /// @dev Includes disabled extras and excludes reserved claims and unknown assets.
    /// Does not sync pending receipts or call extra tokens. Reverts during reentrancy.
    /// @return assets Ordered backing assets.
    /// @return amounts Available asset base units in the same order.
    function backingAssets()
        external
        view
        returns (address[] memory assets, uint256[] memory amounts);

    /// @notice Returns proportional redemption amounts from booked backing.
    /// @dev Divides by pre-burn supply, including unsold inventory and escrowed tokens.
    /// Each share rounds down, leaving the remainder in backing. Pending BUX is not synced,
    /// so the BUX payment can differ. Zero returns zero amounts. Amounts above supply revert.
    /// Does not check ownership or allowance. Uses `backingAssets` ordering and reentrancy guard.
    /// Extra-asset amounts become withdrawal claims at redemption.
    /// @param amount Token base units (18 decimals) to preview; zero is allowed.
    /// @return assets Ordered backing assets, BUX first.
    /// @return amounts Proportional asset base units in the same order.
    function previewRedeem(uint256 amount)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts);

    /// @notice Returns whether a live Block admits an asset as backing.
    /// @dev Pauses do not close funding. BUX synchronization bypasses this gate.
    /// The Block's own token returns false but can be synchronized to burn it.
    /// @param asset Asset to check; zero and the Block's own token are rejected.
    /// @return Whether the asset is BUX or an enabled extra for a live Block.
    function acceptsBacking(address asset) external view returns (bool);

    /// @notice Returns assets admitted for new receipts, BUX first, excluding disabled extras.
    /// @return Admitted asset addresses.
    function retained() external view returns (address[] memory);

    /// @notice Returns the proposed destination and its activation time.
    /// @dev A proposal expires seven days after activation but stays recorded until replaced,
    /// canceled or disabled.
    /// @return policy Proposed destination; zero can mean direct delivery or no proposal.
    /// @return effectiveAt Activation time in Unix seconds; zero means no proposal.
    function pendingPolicy() external view returns (address policy, uint64 effectiveAt);

    /// @notice Returns an account's extra-asset withdrawal claim.
    /// @param account Claim recipient.
    /// @param asset Extra backing asset.
    /// @return Withdrawable asset base units.
    function claimable(address account, address asset) external view returns (uint256);

    /// @notice Returns booked backing excluding reserved withdrawal claims.
    /// @dev Unknown assets return zero without external calls.
    /// @param asset Backing asset, including BUX.
    /// @return Available asset base units.
    function available(address asset) external view returns (uint256);

    /// @notice Returns extra-asset amounts reserved for existing withdrawal claims.
    /// @param asset Extra backing asset.
    /// @return Reserved asset base units, excluded from future redemption backing.
    function reserved(address asset) external view returns (uint256);

    /// @notice Returns the maximum number of backing assets a vault can hold, BUX included.
    /// @return Slot limit of 32: the BUX slot plus up to 31 extra assets.
    function MAX_BACKING_ASSETS() external view returns (uint256);
}
