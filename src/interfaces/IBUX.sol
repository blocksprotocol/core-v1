// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IBuxAdapter } from "./IBuxAdapter.sol";

/// @title IBUX
/// @notice Provides a six-decimal reserve token with deposits and redemptions at par.
/// @dev No bridge role can mint or burn BUX.
interface IBUX is IERC20 {
    /// @notice Emitted when a deposit mints BUX for received underlying.
    /// @param from Account funding the deposit.
    /// @param to Recipient of minted BUX.
    /// @param underlyingIn Requested input in underlying-token base units.
    /// @param buxOut Actual BUX minted in BUX base units (6 decimals).
    event Deposited(address indexed from, address indexed to, uint256 underlyingIn, uint256 buxOut);
    /// @notice Emitted when BUX is burned for underlying.
    /// @param from Account whose BUX is burned.
    /// @param to Recipient of underlying.
    /// @param buxIn Burned amount in BUX base units.
    /// @param underlyingOut Nominal transfer in underlying-token base units.
    event Redeemed(address indexed from, address indexed to, uint256 buxIn, uint256 underlyingOut);
    /// @notice Emitted when the reserve underlying is bound.
    /// @param underlying Six-decimal reserve token.
    event Initialised(address underlying);
    /// @notice Emitted when the harvest recipient changes.
    /// @param yieldReceiver Recipient of future surplus BUX.
    event YieldReceiverSet(address indexed yieldReceiver);
    /// @notice Emitted when the debt manager changes.
    /// @param manager Manager. Zero disables `updateDebt`.
    event ManagerSet(address indexed manager);
    /// @notice Emitted when an adapter is approved.
    /// @param adapter Newly approved reserve adapter.
    event AdapterAdded(address indexed adapter);
    /// @notice Emitted when an adapter is delisted without withdrawing its assets.
    /// @param adapter Delisted reserve adapter.
    /// @param debtWrittenOff Removed debt in underlying-token base units.
    event AdapterRemoved(address indexed adapter, uint256 debtWrittenOff);
    /// @notice Emitted when an adapter's maximum debt changes.
    /// @param adapter Approved reserve adapter.
    /// @param maxDebt Debt limit in underlying-token base units. Zero stops new allocation.
    event MaxDebtSet(address indexed adapter, uint256 maxDebt);
    /// @notice Emitted when the minimum idle reserve changes.
    /// @param minimumTotalIdle Underlying-token base units to keep idle. Zero means no minimum.
    event MinimumTotalIdleSet(uint256 minimumTotalIdle);
    /// @notice Emitted when the BUX owner withdraws idle reserves.
    /// @param amount Transferred underlying-token base units.
    event EmergencyRescue(uint256 amount);
    /// @notice Emitted when an adapter's position is rescued after delisting.
    /// @param adapter Adapter whose position is transferred.
    /// @param to Recipient of the position and idle underlying.
    event AdapterRescued(address indexed adapter, address indexed to);
    /// @notice Emitted when the manager updates an adapter's debt.
    /// @param adapter Approved reserve adapter.
    /// @param currentDebt Previous debt in underlying-token base units.
    /// @param newDebt Updated debt in underlying-token base units.
    event DebtUpdated(address indexed adapter, uint256 currentDebt, uint256 newDebt);
    /// @notice Emitted when an adapter returns underlying to BUX.
    /// @param adapter Adapter returning reserves or gains.
    /// @param amount Received underlying-token base units.
    event Withdrawn(address indexed adapter, uint256 amount);
    /// @notice Emitted when realized surplus mints BUX.
    /// @param surplus Minted BUX base units.
    /// @param to Configured yield recipient.
    event Harvested(uint256 surplus, address to);

    /// @notice Thrown when reserve configuration, an adapter or a recipient is invalid, or the
    /// target debt equals current debt.
    error InvalidConfiguration();
    /// @notice Thrown when the caller is not the debt manager.
    error OnlyManager();
    /// @notice Thrown when a deposit requests or receives zero underlying, or a redemption
    /// requests zero BUX.
    error ZeroAmount();
    /// @notice Thrown when the underlying is not initialized.
    error NotInitialised();
    /// @notice Thrown when reserves cannot fund redemption or an adapter returns an inexact amount.
    error InsufficientReserves();

    // Initialization

    /// @notice Binds the six-decimal underlying once after deployment.
    /// @dev Only the BUX owner may call.
    /// @param underlying_ Reserve token with deployed code, distinct from BUX.
    function initialise(IERC20 underlying_) external;

    // Reserve operations

    /// @notice Mints BUX against the actual underlying balance increase.
    /// @dev Anyone may call. Balance-delta accounting does not make arbitrary token behavior safe.
    /// @param underlyingIn Positive underlying-token base units to request.
    /// @param to BUX recipient. Cannot be zero or BUX itself.
    /// @return buxOut Minted BUX base units, equal to received underlying base units.
    function deposit(uint256 underlyingIn, address to) external returns (uint256 buxOut);

    /// @notice Burns BUX and pays underlying at par, using idle reserves before adapters.
    /// @dev Anyone may call. A shortfall is withdrawn from adapters in order, with enough extra to
    /// restore `minimumTotalIdle` as far as their liquidity allows; adapters the shortfall does not
    /// need are not called. Insufficient liquidity reverts the burn and all withdrawals.
    /// @param buxIn Positive BUX base units to burn.
    /// @param to Underlying recipient. Cannot be zero or BUX itself.
    /// @return underlyingOut Nominal underlying-token base units sent, before token transfer fees.
    function redeem(uint256 buxIn, address to) external returns (uint256 underlyingOut);

    /// @notice Withdraws adapter gains and mints realized surplus to the yield receiver.
    /// @dev Anyone may call. Direct underlying donations can create surplus.
    /// Minting requires a configured receiver.
    /// @return surplus Minted BUX base units, or zero if no idle surplus is available.
    function harvest() external returns (uint256 surplus);

    /// @notice Adjusts an approved adapter's recorded debt through deposits or withdrawals.
    /// @dev Only the manager may call. Equal target and current debt revert.
    /// A withdrawal grows to restore `minimumTotalIdle`, which can leave debt below `targetDebt`.
    /// Current debt and adapter liquidity cap the withdrawal.
    /// Withdrawals must return exact amounts. Limited liquidity can leave idle below the minimum.
    /// An unavailable withdrawal returns current debt without moving funds or emitting an event.
    /// Deposits use only idle above `minimumTotalIdle` and cannot increase debt beyond `maxDebt`.
    /// If `maxDebt` is below current debt or idle is at or below the minimum, an increase returns
    /// current debt without moving funds or emitting an event. All other completions emit
    /// `DebtUpdated`, including an increase capped at current debt that moves no funds.
    /// @param adapter Approved reserve adapter.
    /// @param targetDebt Target in underlying-token base units. Zero requests a full withdrawal.
    /// `type(uint256).max` requests the largest increase the debt limit and idle reserve permit.
    /// @return Updated debt in underlying-token base units.
    function updateDebt(IBuxAdapter adapter, uint256 targetDebt) external returns (uint256);

    // Reserve configuration

    /// @notice Sets the recipient of future harvested BUX.
    /// @dev Only the BUX owner may call.
    /// @param yieldReceiver_ Recipient. Cannot be zero or BUX itself.
    function setYieldReceiver(address yieldReceiver_) external;

    /// @notice Sets the manager authorized to update adapter debt.
    /// @dev Only the BUX owner may call.
    /// @param manager_ Manager. Zero disables `updateDebt`.
    function setManager(address manager_) external;

    /// @notice Approves an adapter for this reserve and underlying asset.
    /// @dev Only the BUX owner may call.
    /// @param adapter Unapproved adapter bound to this BUX and underlying.
    /// Harvest treats existing value as surplus, not debt.
    function addAdapter(IBuxAdapter adapter) external;

    /// @notice Records an approved adapter's fixed maximum debt.
    /// @dev Only the BUX owner may call. Changing the limit does not call the adapter or withdraw.
    /// @param adapter Approved reserve adapter.
    /// @param maxDebt Debt limit in underlying-token base units. Zero stops new allocation.
    function setMaxDebt(IBuxAdapter adapter, uint256 maxDebt) external;

    /// @notice Delists an approved adapter and writes off debt without calling it.
    /// @dev Only the BUX owner may call. Assets stay in the adapter. To withdraw first, the manager
    /// calls `updateDebt` with zero target debt, subject to available liquidity.
    /// @param adapter Approved adapter to remove.
    function removeAdapter(IBuxAdapter adapter) external;

    /// @notice Sets the fixed minimum idle reserve.
    /// @dev Only the BUX owner may call. `updateDebt` never lends idle below it, and a redemption
    /// that withdraws from adapters refills idle toward it as far as their liquidity allows.
    /// @param minimumTotalIdle_ Underlying-token base units to keep idle. Zero means no minimum.
    function setMinimumTotalIdle(uint256 minimumTotalIdle_) external;

    /// @notice Transfers idle underlying reserves to the BUX owner.
    /// @dev Only the BUX owner may call. BUX supply remains unchanged.
    /// @param amount Underlying-token base units to transfer.
    function emergencyRescue(uint256 amount) external;

    /// @notice Delists an adapter, writes off its debt and rescues its position.
    /// @dev Only the BUX owner may call, even after removal. A failed rescue reverts all changes.
    /// @param adapter Adapter whose position is rescued.
    /// @param to Recipient passed to the adapter's rescue operation.
    function rescueAdapter(IBuxAdapter adapter, address to) external;

    // Views

    /// @notice Returns the six-decimal reserve underlying bound by the BUX owner.
    /// @return Reserve token, or zero before initialization.
    function underlying() external view returns (IERC20);

    /// @notice Returns the BUX owner's configured harvest recipient.
    /// @return Recipient, or zero until configured.
    function yieldReceiver() external view returns (address);

    /// @notice Returns the fixed minimum idle reserve.
    /// @return Underlying-token base units. Defaults to zero, meaning no minimum.
    function minimumTotalIdle() external view returns (uint256);

    /// @notice Returns recorded adapter debt before quoted losses.
    /// @return Debt in underlying-token base units.
    function totalDebt() external view returns (uint256);

    /// @notice Returns an approved adapter by index.
    /// @dev Removal may change array ordering.
    /// @param index Zero-based position in the approved-adapter array.
    /// @return Adapter at that position.
    function adapters(uint256 index) external view returns (IBuxAdapter);

    /// @notice Returns an adapter's maximum debt, current debt and approval status.
    /// @param adapter Reserve adapter to query.
    /// @return maxDebt Debt limit in underlying-token base units. Zero stops new allocation.
    /// @return currentDebt Recorded debt in underlying-token base units.
    /// @return approved Whether the adapter is approved for reserve operations.
    function adapterState(IBuxAdapter adapter)
        external
        view
        returns (uint256 maxDebt, uint256 currentDebt, bool approved);

    /// @notice Returns the manager authorized to update adapter debt.
    /// @return Manager. Defaults to zero, which disables `updateDebt`.
    function manager() external view returns (address);

    /// @notice Returns idle reserves plus each adapter's value capped at its recorded debt.
    /// @return Backing in underlying-token base units, including losses but excluding quoted gains.
    function totalUnderlying() external view returns (uint256);

    /// @notice Returns the number of approved adapters.
    /// @return Length of the approved-adapter array.
    function adapterCount() external view returns (uint256);
}
