// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from
    "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IBlockBatchSale } from "./interfaces/IBlockBatchSale.sol";
import { IBlockFactory } from "./interfaces/IBlockFactory.sol";
import { IBlockToken } from "./interfaces/IBlockToken.sol";
import { IProtocolSettings } from "./interfaces/IProtocolSettings.sol";

/// @title BlockBatchSale
/// @notice Holds irrevocable BUX commitments and settles a Block sale at one clearing price.
/// @dev Settlement clamps the clearing denominator to the floor and cap.
/// The sale pays its fee before funding the factory. Accounting requires exact transfers.
/// @custom:security-contact security@blocks.fm
contract BlockBatchSale is IBlockBatchSale, Initializable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // Initial supply in token base units (18 decimals).
    uint256 private constant SUPPLY_TOKENS = 1_000_000_000e18;
    // Minimum commitment of 0.1 BUX, in BUX base units (6 decimals).
    uint256 private constant MIN_COMMIT_BUX = 100_000;
    // Cap bound in BUX base units: 1e12 whole BUX, limiting ticks.
    uint256 private constant MAX_CAP_BUX_BASE_UNITS = 1e18;
    // Maximum dimensionless cap-to-floor ratio, limiting the price range.
    uint256 private constant MAX_CAP_MULTIPLE = 1_000;
    // Seconds after the end time before expiry is allowed.
    uint256 private constant EXPIRY_DELAY = 7 days;

    IERC20 private _token;
    IERC20 private _bux;
    address private _factory;
    address private _launcher;
    /// @inheritdoc IBlockBatchSale
    uint16 public feeBps;
    State private _state;
    /// @inheritdoc IBlockBatchSale
    uint256 public commitmentsTotal;
    uint256 private _creatorTokens;
    uint256 private _creatorBux;
    Terms private _terms;
    Totals private _results;
    /// @inheritdoc IBlockBatchSale
    mapping(address => uint256) public commitments;
    /// @inheritdoc IBlockBatchSale
    mapping(address => bool) public delivered;

    // Initialization

    /// @notice Locks initialization of the implementation when deployed.
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IBlockBatchSale
    function initialize(
        address token_,
        address quote_,
        address factory_,
        Terms calldata terms_,
        address launcher_
    ) external initializer {
        if (factory_ != msg.sender) revert InvalidSaleWiring();
        IBlockFactory blockFactory = IBlockFactory(factory_);
        if (
            terms_.creator == address(0) || terms_.creator == address(this)
                || terms_.creator == factory_ || launcher_ == address(0)
        ) revert InvalidRecipient();
        uint16 successFeeBps = IProtocolSettings(blockFactory.settings()).saleSuccessFeeBps();
        _validateTerms(terms_, successFeeBps);

        _token = IERC20(token_);
        _bux = IERC20(quote_);
        _factory = factory_;
        _launcher = launcher_;
        feeBps = successFeeBps;
        _terms = terms_;
        _state = State.Selling;
        emit SaleInitialized(token_, quote_, launcher_, terms_, successFeeBps);
    }

    // Commitments

    /// @inheritdoc IBlockBatchSale
    function commit(uint256 bux, address to) external nonReentrant {
        if (_state != State.Selling) revert WrongState();
        if (block.timestamp < _terms.startTime || block.timestamp >= _terms.endTime) {
            revert CommitmentsClosed();
        }
        if (bux < MIN_COMMIT_BUX) revert InvalidCommitment();
        if (to == address(0) || to == address(this)) revert InvalidRecipient();

        _commit(bux, to);
    }

    /// @inheritdoc IBlockBatchSale
    function commitForCreator(uint256 bux) external nonReentrant {
        if (msg.sender != _factory) revert OnlyFactory();
        if (_state != State.Selling) revert WrongState();
        if (block.timestamp >= _terms.startTime) revert CommitmentsClosed();
        if (_creatorBux != 0 || bux != _terms.creatorCommit) revert InvalidCommitment();

        _creatorBux = bux;
        _commit(bux, _terms.creator);
    }

    // Settlement

    /// @inheritdoc IBlockBatchSale
    function close() external nonReentrant {
        _close();
    }

    /// @inheritdoc IBlockBatchSale
    function expire() external nonReentrant {
        if (_state != State.Selling) revert WrongState();
        if (block.timestamp < uint256(_terms.endTime) + EXPIRY_DELAY) revert DeadlineNotReached();

        _state = State.Cancelled;
        _results.refund = commitmentsTotal;
        IBlockToken(address(_token)).burn(SUPPLY_TOKENS);
        emit SaleCancelled();
    }

    /// @inheritdoc IBlockBatchSale
    function deliver(address to) external nonReentrant {
        if (_state == State.Selling) _close();
        if (_state != State.Live && _state != State.Cancelled) revert WrongState();
        if (delivered[to] || commitments[to] == 0) return;

        (uint256 tokenAmount, uint256 refundBux) = previewFor(to);
        delivered[to] = true;
        uint256 launcherRefundBux;
        if (to == _terms.creator && to != _launcher && _state == State.Cancelled) {
            launcherRefundBux = _creatorBux;
        }

        if (tokenAmount != 0) _token.safeTransfer(to, tokenAmount);
        if (refundBux != 0) _bux.safeTransfer(to, refundBux);
        if (launcherRefundBux != 0) {
            _bux.safeTransfer(_launcher, launcherRefundBux);
            emit Delivered(to, _launcher, 0, launcherRefundBux);
        }
        emit Delivered(to, to, tokenAmount, refundBux);
    }

    // Views

    /// @inheritdoc IBlockBatchSale
    function previewFor(address who) public view returns (uint256 tokens, uint256 refundBux) {
        if (delivered[who]) return (0, 0);
        uint256 publicBux = commitments[who];
        uint256 creatorBux = _creatorBux;
        // Priority commitment is not public BUX.
        if (who == _terms.creator) publicBux -= creatorBux;
        Totals memory totals = previewTotals();
        if (totals.accepted == 0) {
            if (who == _terms.creator && who == _launcher) publicBux += creatorBux;
            return (0, publicBux);
        }
        if (publicBux == 0) return (0, 0);

        uint256 publicTotalBux = commitmentsTotal - creatorBux;
        uint256 publicAcceptedBux = totals.accepted - creatorBux;
        // Each division rounds down, leaving BUX and token dust in the sale.
        uint256 acceptedBux = Math.mulDiv(publicBux, publicAcceptedBux, publicTotalBux);
        tokens = Math.mulDiv(acceptedBux, _terms.saleSupply, totals.denominator);
        refundBux = Math.mulDiv(publicBux, publicTotalBux - publicAcceptedBux, publicTotalBux);
    }

    /// @inheritdoc IBlockBatchSale
    function previewTotals() public view returns (Totals memory totals) {
        if (_state == State.Live || _state == State.Cancelled) return _results;
        uint256 committedBux = commitmentsTotal;

        totals.denominator = Math.min(Math.max(committedBux, _terms.floorRaise), _terms.capRaise);
        totals.accepted = Math.min(committedBux, _terms.capRaise);
        totals.tokens = Math.mulDiv(totals.accepted, _terms.saleSupply, totals.denominator);
        totals.refund = committedBux - totals.accepted;
        totals.priceX96 =
            SafeCast.toUint160(Math.mulDiv(totals.denominator, 1 << 96, _terms.saleSupply));
        totals.fee = Math.mulDiv(totals.accepted, feeBps, 10_000);
        totals.proceeds = totals.accepted - totals.fee;
    }

    /// @inheritdoc IBlockBatchSale
    function state() external view returns (State) {
        return _state;
    }

    /// @inheritdoc IBlockBatchSale
    function terms() external view returns (Terms memory) {
        return _terms;
    }

    // Internal functions

    function _validateTerms(Terms calldata config, uint16 successFeeBps) private view {
        if (
            config.floorRaise < 1_000e6 || config.capRaise > MAX_CAP_BUX_BASE_UNITS
                || config.floorRaise > config.capRaise
                || config.capRaise > MAX_CAP_MULTIPLE * config.floorRaise
                || (
                    config.saleSupply != 400_000_000e18 && config.saleSupply != 500_000_000e18
                        && config.saleSupply != 600_000_000e18
                )
        ) revert InvalidSaleTerms();
        // At the 100 bps fee ceiling, bids cover about 29% more tokens than allocated before
        // tick and liquidity rounding. Seeding checks actual coverage.
        // The 20% floor-price bound excludes the creator's public buys.
        // The priority ceiling rounds down to a BUX base unit, discarding fractional capacity.
        if (
            successFeeBps > 100 || config.creatorCommit >= config.capRaise
                || config.creatorCommit
                    > Math.mulDiv(config.floorRaise, SUPPLY_TOKENS / 5, config.saleSupply)
        ) revert InvalidSaleTerms();
        if (
            config.startTime < block.timestamp + 10 minutes
                || config.startTime > block.timestamp + 30 days || config.endTime <= config.startTime
                || config.endTime - config.startTime < 30 minutes
                || config.endTime - config.startTime > 7 days
        ) revert InvalidSaleTimeline();
        uint256 vestingDuration = uint256(config.cliffDuration) + config.vestDuration;
        if (vestingDuration > 1_825 days || (config.creatorCommit != 0 && vestingDuration == 0)) {
            revert InvalidSaleVesting();
        }
    }

    function _commit(uint256 buxAmount, address recipient) private {
        commitments[recipient] += buxAmount;
        commitmentsTotal += buxAmount;

        _bux.safeTransferFrom(msg.sender, address(this), buxAmount);
        emit Committed(recipient, msg.sender, buxAmount);
    }

    function _close() private {
        if (_state != State.Selling) revert WrongState();
        if (block.timestamp < _terms.endTime) revert DeadlineNotReached();

        Totals memory totals = previewTotals();
        _results = totals;
        // Priority rounds down separately. The sale keeps the allocation remainder.
        _creatorTokens = Math.mulDiv(_creatorBux, _terms.saleSupply, totals.denominator);
        _state = State.Live;

        _payFee(totals.fee);
        uint256 marketTokens = SUPPLY_TOKENS - totals.tokens;
        uint256 tokensForFactory = marketTokens + _creatorTokens;

        _token.forceApprove(_factory, tokensForFactory);
        _bux.forceApprove(_factory, totals.proceeds);
        IBlockFactory(_factory).finalizeBlockSale(
            address(_token), marketTokens, totals.proceeds, totals.priceX96, _creatorTokens
        );
        _token.forceApprove(_factory, 0);
        _bux.forceApprove(_factory, 0);
        emit SaleClosed(totals, _creatorTokens);
    }

    function _payFee(uint256 feeBux) private {
        // Settings fixes the FeePool address, so reading it at payment cannot redirect the fee.
        if (feeBux != 0) _bux.safeTransfer(IBlockFactory(_factory).feePool(), feeBux);
    }
}
