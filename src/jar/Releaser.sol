// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from
    "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

import { IJar } from "../interfaces/IJar.sol";
import { IJarFactory } from "../interfaces/IJarFactory.sol";
import { IProtocolSettings } from "../interfaces/IProtocolSettings.sol";
import { IReleaser } from "../interfaces/IReleaser.sol";

/// @title Releaser
/// @notice Sells staged jar inventory at a declining BUX price with fixed pricing parameters.
/// @dev Pricing reads no token decimals, oracle or past price. Each lot snapshots sellable
/// inventory, excluding Policy rows and home-bound BUX. Total sales cannot exceed the snapshot.
/// Added inventory stays out of the discounted lot. Restaging resets the price to the ceiling.
/// Replacement Releasers must be fresh deployments to prevent reusing a snapshot after another
/// Releaser sells inventory.
/// @custom:security-contact security@blocks.fm
contract Releaser is IReleaser, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Returns the ray scale used for decay multiplication.
    /// @return Fixed-point scale of 1e27 per whole unit.
    uint256 public constant RAY = 1e27;
    /// @notice Returns the eligibility window after the slide duration.
    /// @return Window in seconds, equal to one hour.
    uint256 public constant FLOOR_WINDOW = 1 hours;

    /// @notice Returns the settings that select the current Releaser and paused assets.
    /// @return Protocol settings fixed at deployment.
    IProtocolSettings public immutable settings;
    /// @notice Returns the opening total-lot price.
    /// @return Ceiling in BUX base units (6 decimals).
    uint256 public immutable ceiling;
    /// @notice Returns the minimum total-lot price.
    /// @return Positive floor in BUX base units, at most the ceiling.
    uint256 public immutable floor;
    /// @notice Returns the per-step price multiplier.
    /// @return Decay scaled by one ray (1e27), strictly between zero and one ray.
    uint256 public immutable decayRay;
    /// @notice Returns the duration of a pricing step.
    /// @return Positive duration in seconds.
    uint256 public immutable step;
    /// @notice Returns the time allowed for the calculated price to reach the floor.
    /// @return Duration in seconds, at least one step.
    uint256 public immutable slide;

    /// @inheritdoc IReleaser
    mapping(address jar => mapping(address asset => Lot)) public lots;

    // Initialization

    /// @notice Binds settings and validates immutable pricing parameters once at deployment.
    /// @dev The rounded total price must reach the floor by the end of the slide.
    /// @param settings_ Protocol settings supplying the Releaser, BUX and trusted jar factories.
    /// @param ceiling_ Opening total-lot price in BUX base units.
    /// @param floor_ Positive total-lot floor in BUX base units, at most `ceiling_`.
    /// @param decayRay_ Per-step multiplier in ray (1e27), strictly between zero and one ray.
    /// @param step_ Positive pricing interval in seconds. Zero reverts on division.
    /// @param slide_ Duration in seconds, at least `step_`, by which the price must reach `floor_`.
    constructor(
        IProtocolSettings settings_,
        uint256 ceiling_,
        uint256 floor_,
        uint256 decayRay_,
        uint256 step_,
        uint256 slide_
    ) {
        if (floor_ == 0 || floor_ > ceiling_) revert BadFloor();
        if (decayRay_ == 0 || decayRay_ >= RAY) revert BadDecay();
        if (slide_ < step_) revert BadSlide();
        // Whole-step time rounds down. Exponentiation rounds intermediate products to nearest.
        // Total-price multiplication rounds down, discarding the fraction for this bound check.
        if (
            Math.mulDiv(ceiling_, FixedPointMathLib.rpow(decayRay_, slide_ / step_, RAY), RAY)
                > floor_
        ) {
            revert DecayMissesFloor();
        }

        settings = settings_;
        ceiling = ceiling_;
        floor = floor_;
        decayRay = decayRay_;
        step = step_;
        slide = slide_;
    }

    // Lot operations

    /// @inheritdoc IReleaser
    function stage(address jar, address asset) external nonReentrant returns (uint256 balance) {
        if (settings.releaser() != address(this)) revert OnlyCurrentReleaser();
        if (settings.assetReleasePaused(asset)) revert ReleasePaused();
        _authenticate(jar);

        balance = IJar(jar).inventory(asset);
        if (balance == 0) revert NothingAvailable();

        Lot memory lot = lots[jar][asset];
        // Halving rounds down but preserves comparison with twice the snapshot without overflow.
        // Any odd token base unit stays in inventory.
        if (_isActive(asset, lot) && balance / 2 < lot.initialAmount) revert AlreadyStaged();
        lots[jar][asset] = Lot(block.timestamp, balance, 0);
        emit LotStaged(jar, asset, balance, block.timestamp);
    }

    /// @inheritdoc IReleaser
    function takeWithLimits(
        address jar,
        address asset,
        uint256 maxAmount,
        uint256 minAmount,
        uint256 maxPayment,
        address receiver,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountTaken, uint256 payment) {
        if (block.timestamp > deadline) revert Deadline();
        (amountTaken, payment) = _take(jar, asset, maxAmount, receiver);
        if (amountTaken < minAmount) revert InsufficientAmount();
        if (payment > maxPayment) revert ExcessivePayment();
    }

    // Views

    /// @inheritdoc IReleaser
    function available(address jar, address asset) public view returns (uint256) {
        Lot memory lot = lots[jar][asset];
        if (!_isActive(asset, lot)) return 0;
        return _available(lot);
    }

    // Internal functions

    // A jar outside the trusted factories could collect payment without delivering inventory.
    function _authenticate(address jar) private view {
        address factory = IJar(jar).factory();
        if (!settings.trustedJarFactory(factory)) revert UnauthenticatedJar();
        if (IJarFactory(factory).predict(IJar(jar).homeChainId(), IJar(jar).token()) != jar) {
            revert UnauthenticatedJar();
        }
    }

    function _isActive(address asset, Lot memory lot) private view returns (bool) {
        return settings.releaser() == address(this)
            && block.timestamp < lot.stagedAt + slide + FLOOR_WINDOW
            && !settings.assetReleasePaused(asset);
    }

    // Payment passes through this Releaser so a replacement cannot spend the buyer's allowance.
    // The jar verifies its own receipt before delivering inventory.
    function _take(address jar, address asset, uint256 maxAmount, address receiver)
        private
        returns (uint256 amountTaken, uint256 payment)
    {
        if (receiver == address(0) || receiver == jar || receiver == address(this)) {
            revert InvalidAddress();
        }

        amountTaken = Math.min(maxAmount, available(jar, asset));
        if (amountTaken == 0) revert NothingAvailable();
        Lot memory lot = lots[jar][asset];
        payment = _quote(lot, amountTaken);
        lots[jar][asset].sold += amountTaken;

        IERC20 bux = IERC20(settings.bux());
        bux.safeTransferFrom(msg.sender, address(this), payment);
        bux.forceApprove(jar, payment);
        IJar(jar).release(asset, amountTaken, payment, receiver);
        emit Taken(
            jar, asset, msg.sender, receiver, amountTaken, payment, _available(lots[jar][asset])
        );
    }

    // While this Releaser is current, only its sales reduce inventory. Each sale first adds the
    // same token base units to `sold`, so the unsold snapshot cannot exceed inventory.
    function _available(Lot memory lot) private pure returns (uint256) {
        return lot.initialAmount - lot.sold;
    }

    // Proportional payment rounds up to a BUX base unit. The jar receives the rounding excess.
    function _quote(Lot memory lot, uint256 amount) private view returns (uint256) {
        return Math.mulDiv(_totalPrice(lot), amount, lot.initialAmount, Math.Rounding.Ceil);
    }

    // Elapsed time rounds down to whole steps, holding the price until the next step.
    // Exponentiation rounds intermediate products to nearest. Total-price multiplication rounds
    // down before applying the floor, leaving fractional BUX with the buyer.
    function _totalPrice(Lot memory lot) private view returns (uint256) {
        uint256 elapsed = block.timestamp - lot.stagedAt;
        return Math.max(
            floor, Math.mulDiv(ceiling, FixedPointMathLib.rpow(decayRay, elapsed / step, RAY), RAY)
        );
    }
}
