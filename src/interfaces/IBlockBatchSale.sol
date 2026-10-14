// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IBlockBatchSale
/// @notice Defines a fixed-window BUX sale with one clearing price and permissionless delivery.
interface IBlockBatchSale {
    enum State {
        Uninitialized,
        Selling,
        Live,
        Cancelled
    }

    /// @dev Amounts use BUX base units (6 decimals) or token base units (18 decimals).
    /// Timestamps use Unix seconds. Durations use seconds.
    struct Terms {
        uint256 floorRaise; // Minimum clearing-price denominator, in BUX base units.
        uint256 capRaise; // Maximum accepted BUX and clearing denominator, in BUX base units.
        uint64 startTime; // First commitment timestamp, in Unix seconds.
        uint64 endTime; // Exclusive commitment deadline, in Unix seconds.
        uint256 saleSupply; // Tokens offered, in token base units.
        uint256 creatorCommit; // Priority commitment in BUX base units. Zero means none.
        uint64 cliffDuration; // Seconds from settlement to the start of linear vesting.
        // Linear vesting duration in seconds after the cliff. Zero vests all at the cliff.
        uint64 vestDuration;
        address creator; // Priority recipient. The factory resolves zero to the Block admin.
    }

    /// @dev Budgets before per-account rounding. Amounts use BUX base units except `tokens`
    /// (18-decimal token base units) and `priceX96`. Expiry sets `refund` to all commitments
    /// and zeros the other fields.
    struct Totals {
        // Commitments clamped to `floorRaise` and `capRaise`. Zero after expiry.
        uint256 denominator;
        uint256 accepted; // Commitments accepted up to the cap, including priority.
        uint256 tokens; // Tokens bought by accepted BUX, including the priority allocation.
        uint256 refund; // BUX above the cap, or all commitments after expiry.
        uint160 priceX96; // BUX-base/token-base times 2^96.
        uint256 fee; // Success fee deducted from accepted BUX.
        uint256 proceeds; // Market funding in BUX after the success fee.
    }

    /// @notice Emitted when the factory initializes a sale clone.
    /// @param token Token offered by the sale.
    /// @param quote BUX asset used for commitments.
    /// @param launcher Funder that receives priority refunds on expiry.
    /// @param terms Fixed sale amounts and schedule.
    /// @param feeBps Snapshotted success fee in bps, with 10_000 bps = 100%.
    event SaleInitialized(
        address indexed token,
        address indexed quote,
        address indexed launcher,
        Terms terms,
        uint16 feeBps
    );
    /// @notice Emitted when BUX is committed for a recipient.
    /// @param to Account credited with the commitment.
    /// @param payer Account funding the commitment.
    /// @param bux Added commitment in BUX base units.
    event Committed(address indexed to, address indexed payer, uint256 bux);
    /// @notice Emitted when settlement funds the market and any creator vesting.
    /// @dev The sale pays `totals.fee` to FeePool before market funding. Distribution is separate.
    /// @param totals Frozen aggregate settlement budgets.
    /// @param creatorFill Priority allocation in token base units (18 decimals).
    event SaleClosed(Totals totals, uint256 creatorFill);
    /// @notice Emitted when an expired sale burns its supply and enables full refunds.
    event SaleCancelled();
    /// @notice Emitted when an account's tokens or refund are delivered.
    /// @param committer Account whose commitment is settled.
    /// @param to Recipient of this payment.
    /// @param tokens Delivered token base units (18 decimals); zero for refund-only payments.
    /// @param bux Refunded BUX base units; zero when no refund is due.
    event Delivered(address indexed committer, address indexed to, uint256 tokens, uint256 bux);

    /// @notice Thrown when the initializer's factory differs from the caller.
    error InvalidSaleWiring();
    /// @notice Thrown when amounts, allocation or fee fall outside the sale limits.
    error InvalidSaleTerms();
    /// @notice Thrown when the sale start or duration falls outside the permitted window.
    error InvalidSaleTimeline();
    /// @notice Thrown when cliff plus vesting exceeds 1,825 days or is zero with nonzero priority.
    error InvalidSaleVesting();
    /// @notice Thrown when the creator, launcher or commitment recipient is disallowed.
    error InvalidRecipient();
    /// @notice Thrown when a commitment is below the minimum or priority funding is repeated or
    /// mismatched.
    error InvalidCommitment();
    /// @notice Thrown when the caller funding priority is not the factory.
    error OnlyFactory();
    /// @notice Thrown when the sale lifecycle does not permit the operation.
    error WrongState();
    /// @notice Thrown when funding occurs outside the applicable commitment window.
    error CommitmentsClosed();
    /// @notice Thrown when a call precedes the closing or expiry deadline.
    error DeadlineNotReached();

    // Initialization

    /// @notice Initializes a sale clone once.
    /// @dev Only the factory may call, after funding the full initial supply.
    /// Snapshots a success fee of at most 100 bps. The floor is at least 1,000 BUX.
    /// The cap is at most 1e12 BUX and 1,000 times the floor.
    /// The sale offers 40%, 50% or 60% of initial supply. Priority stays below the cap and buys
    /// at most 20% of initial supply at the floor, excluding the creator's public buys.
    /// The start is ten minutes to thirty days ahead. The sale lasts thirty minutes to seven days.
    /// Cliff plus vesting is at most 1,825 days and must be nonzero for nonzero priority.
    /// @param token_ Token offered by the sale.
    /// @param quote_ BUX asset used for commitments.
    /// @param factory_ Calling factory that settles the market.
    /// @param terms_ Fixed amounts, schedule and creator.
    /// @param launcher_ Nonzero priority funder that receives priority refunds on expiry.
    function initialize(
        address token_,
        address quote_,
        address factory_,
        Terms calldata terms_,
        address launcher_
    ) external;

    // Commitments

    /// @notice Commits at least 0.1 BUX irrevocably for a recipient during the public window.
    /// @dev Anyone may call from `startTime` until `endTime`, exclusive.
    /// The minimum limits dust commitments that cost keepers delivery gas.
    /// @param bux Commitment pulled from the caller, in BUX base units.
    /// @param to Credited account. Cannot be zero or the sale.
    function commit(uint256 bux, address to) external;

    /// @notice Funds configured creator priority before the public window opens.
    /// @dev Only the factory may call. Nonzero priority is accepted once in full. Its tokens vest.
    /// Zero funding leaves priority unfunded and allows repeat calls.
    /// @param bux Exact configured priority in BUX base units; zero means no priority.
    function commitForCreator(uint256 bux) external;

    // Settlement

    /// @notice Closes the sale from its end time onward, paying the fee and opening the market.
    /// @dev Anyone may call. Closing has no deadline. With no commitments, the pool opens at the
    /// quantized floor price. All tokens fund an ask above that price, with unused tokens left as
    /// hook inventory dust. Below the floor, unsold tokens join market inventory.
    function close() external;

    /// @notice Expires an unclosed sale seven days after its end time, enabling full refunds.
    /// @dev Anyone may call. Expiry provides a backstop when closing cannot succeed.
    /// Closing has no deadline, so the first successful `close`, `deliver` or `expire` decides the
    /// outcome.
    function expire() external;

    /// @notice Delivers one account's tokens and refunds, closing an open sale first.
    /// @dev Anyone may call. An open sale reverts with `DeadlineNotReached` before `endTime`.
    /// Empty or delivered accounts receive nothing after the state check.
    /// Keepers can enumerate `Committed` events and batch calls through Multicall3.
    /// Priority refunds go to the launcher. The creator's public buys stay public.
    /// A failed transfer reverts the whole call, including any close it performs.
    /// @param to Account to settle. Priority refunds may go to the launcher separately.
    function deliver(address to) external;

    // Views

    /// @notice Returns pending public tokens and refunds for an account, excluding vested tokens.
    /// @dev Returns zero after delivery. Estimates become final after close or expiry.
    /// Includes priority refunds only when creator and launcher are the same account.
    /// Otherwise, `deliver` pays the launcher separately. Accepted BUX and refunds round down
    /// independently, leaving at most one BUX base unit per public account in the sale.
    /// Tokens also round down at settlement. For sale supply S and denominator D, the shortfall
    /// from the ideal allocation is less than S/D + 1 token base units per account
    /// (up to about 0.6 whole token). Splitting commitments across wallets can increase dust.
    /// Under extreme dilution, 1 BUX can buy zero tokens and receive a 0.999999 BUX refund.
    /// Dust stays in the sale permanently. Stranded tokens remain in outstanding supply.
    /// @param who Account whose pending delivery is calculated.
    /// @return tokens Public allocation in token base units (18 decimals).
    /// @return refundBux Refund delivered to this account in BUX base units.
    function previewFor(address who) external view returns (uint256 tokens, uint256 refundBux);

    /// @notice Returns settlement budgets, excluding donations and fixed after close or expiry.
    /// @dev Token allocations, the encoded price and the fee round down.
    /// Market funding receives accepted BUX minus the fee, including the fee rounding remainder.
    /// Token rounding adds market inventory. Pool-price quantization follows price encoding.
    /// @return Aggregate settlement budgets before per-account rounding.
    function previewTotals() external view returns (Totals memory);

    /// @notice Returns the sale lifecycle state, including expiry.
    /// @return Current lifecycle state.
    function state() external view returns (State);

    /// @notice Returns the immutable sale terms.
    /// @return Fixed amounts, schedule and creator.
    function terms() external view returns (Terms memory);

    /// @notice Returns the success fee snapshotted at initialization.
    /// @return Fee in bps, with 10_000 bps = 100%.
    function feeBps() external view returns (uint16);

    /// @notice Returns total commitments including creator priority and excluding donations.
    /// @return Committed BUX base units.
    function commitmentsTotal() external view returns (uint256);

    /// @notice Returns an account's commitments including any creator priority.
    /// @param who Account credited with the commitments.
    /// @return Committed BUX base units.
    function commitments(address who) external view returns (uint256);

    /// @notice Returns whether delivery completed, including any priority refund to the launcher.
    /// @param who Account whose delivery is checked.
    /// @return Whether delivery completed.
    function delivered(address who) external view returns (bool);
}
