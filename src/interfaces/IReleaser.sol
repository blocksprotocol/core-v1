// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IReleaser
/// @notice Sells staged jar inventory against a declining total BUX price.
interface IReleaser {
    struct Lot {
        // Staging timestamp in Unix seconds. Zero before staging.
        uint256 stagedAt;
        // Snapshotted inventory in token base units. Zero before staging.
        uint256 initialAmount;
        // Cumulative token base units sold from the snapshot.
        uint256 sold;
    }

    /// @notice Emitted when inventory is snapshotted as a new lot.
    /// @param jar Authenticated inventory holder.
    /// @param asset Token offered for sale.
    /// @param initialAmount Snapshotted token base units.
    /// @param stagedAt Staging timestamp in Unix seconds.
    event LotStaged(
        address indexed jar, address indexed asset, uint256 initialAmount, uint256 stagedAt
    );
    /// @notice Emitted when a buyer pays BUX for staged inventory.
    /// @param jar Jar delivering inventory and receiving payment.
    /// @param asset Purchased token.
    /// @param caller Immediate caller supplying the BUX allowance.
    /// @param receiver Recipient of purchased inventory.
    /// @param amountTaken Nominal token base units purchased, before token transfer fees.
    /// @param payment Paid BUX base units (6 decimals).
    /// @param remaining Unsold token base units from the snapshot.
    event Taken(
        address indexed jar,
        address indexed asset,
        address caller,
        address receiver,
        uint256 amountTaken,
        uint256 payment,
        uint256 remaining
    );

    /// @notice Thrown when staging through a Releaser that is not current.
    error OnlyCurrentReleaser();
    /// @notice Thrown when staging an asset whose release is paused.
    error ReleasePaused();
    /// @notice Thrown when a jar does not match a trusted factory's deterministic prediction.
    error UnauthenticatedJar();
    /// @notice Thrown when the receiver is zero, the selling jar or this Releaser.
    error InvalidAddress();
    /// @notice Thrown when the price floor is zero or exceeds the ceiling.
    error BadFloor();
    /// @notice Thrown when the decay multiplier is zero or at least one ray.
    error BadDecay();
    /// @notice Thrown when the slide duration is shorter than one pricing step.
    error BadSlide();
    /// @notice Thrown when the calculated total price remains above the floor after the slide.
    error DecayMissesFloor();
    /// @notice Thrown when an active lot is restaged before inventory reaches twice its snapshot.
    error AlreadyStaged();
    /// @notice Thrown when the amount to stage or buy is zero.
    error NothingAvailable();
    /// @notice Thrown when a purchase misses its deadline.
    error Deadline();
    /// @notice Thrown when the purchased amount is below the buyer's minimum.
    error InsufficientAmount();
    /// @notice Thrown when the required payment exceeds the buyer's maximum.
    error ExcessivePayment();

    // Lot operations

    /// @notice Snapshots inventory, restarting an active lot only at twice its snapshot or more.
    /// @dev Anyone may call. The lot is eligible only while this Releaser is current and the asset
    /// is unpaused, until `slide + FLOOR_WINDOW` seconds after staging.
    /// Pauses, replacement and partial fills do not extend that deadline.
    /// @param jar Jar predicted by a trusted factory.
    /// @param asset Inventory token to sell. Release must be unpaused.
    /// @return initialAmount Positive snapshotted token base units.
    function stage(address jar, address asset) external returns (uint256 initialAmount);

    /// @notice Purchases staged inventory subject to time, amount and payment limits.
    /// @dev Anyone may call. The caller approves this Releaser for the BUX payment. Restaging
    /// resets the price to the ceiling. `maxPayment` caps the buyer's payment.
    /// Proportional payment rounds up to a BUX base unit. The jar receives the rounding excess.
    /// @param jar Jar holding the staged lot.
    /// @param asset Inventory token to purchase.
    /// @param maxAmount Maximum nominal token base units to buy. Zero reverts.
    /// @param minAmount Minimum nominal token base units to transfer. Zero removes the lower bound.
    /// @param maxPayment Maximum BUX base units to pay.
    /// @param receiver Inventory recipient. Cannot be zero, the jar or this Releaser.
    /// @param deadline Last valid execution time in Unix seconds, inclusive.
    /// @return amountTaken Nominal token base units transferred, before token transfer fees.
    /// @return payment Paid BUX base units, rounded up.
    function takeWithLimits(
        address jar,
        address asset,
        uint256 maxAmount,
        uint256 minAmount,
        uint256 maxPayment,
        address receiver,
        uint256 deadline
    ) external returns (uint256 amountTaken, uint256 payment);

    // Views

    /// @notice Returns the stored snapshot and cumulative sales for a jar's asset.
    /// @param jar Inventory holder to query.
    /// @param asset Inventory token to query.
    /// @return stagedAt Staging timestamp in Unix seconds. Zero before staging.
    /// @return initialAmount Snapshotted token base units. Zero before staging.
    /// @return sold Cumulative token base units sold from the snapshot.
    function lots(address jar, address asset)
        external
        view
        returns (uint256 stagedAt, uint256 initialAmount, uint256 sold);

    /// @notice Returns the unsold amount of an eligible staged snapshot.
    /// @param jar Inventory holder to query.
    /// @param asset Inventory token to query.
    /// @return Unsold token base units. Zero for an inactive or exhausted lot.
    function available(address jar, address asset) external view returns (uint256);
}
