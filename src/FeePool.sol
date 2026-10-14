// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { ReentrancyGuardTransient } from
    "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IFeePool } from "./interfaces/IFeePool.sol";
import { IProtocolSettings } from "./interfaces/IProtocolSettings.sol";

/// @title FeePool
/// @notice Collects fees for permissionless distribution between two configured recipients.
/// @dev Funds stay here until distribution, which uses the current split.
/// @custom:security-contact security@blocks.fm
contract FeePool is IFeePool, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint16 private constant BPS = 10_000; // Rate denominator: 10_000 bps = 100%.

    IProtocolSettings private immutable _settings;

    /// @inheritdoc IFeePool
    address public treasuryRecipient;
    /// @inheritdoc IFeePool
    address public protocolValueRecipient;
    /// @inheritdoc IFeePool
    uint16 public treasuryBps = BPS / 2; // Initial treasury share of 50%, configurable by the Safe.

    /// @notice Binds settings and sets both recipients to the Safe at deployment.
    /// @dev Later Safe changes do not update recipients.
    /// @param settings_ Existing settings contract.
    constructor(address settings_) {
        _settings = IProtocolSettings(settings_);
        address safe = _settings.safe();
        treasuryRecipient = safe;
        protocolValueRecipient = safe;
    }

    /// @notice Accepts native currency for later distribution.
    receive() external payable { }

    /// @inheritdoc IFeePool
    function distribute(address asset) external nonReentrant returns (uint256 amount) {
        amount =
            asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this));
        uint256 toTreasury = Math.mulDiv(amount, treasuryBps, BPS);
        uint256 toProtocolValue = amount - toTreasury;
        _pay(asset, treasuryRecipient, toTreasury);
        _pay(asset, protocolValueRecipient, toProtocolValue);
        emit Distributed(asset, toTreasury, toProtocolValue, msg.sender);
    }

    /// @inheritdoc IFeePool
    function setSplit(address treasury, address protocolValue, uint16 treasuryBps_) external {
        if (msg.sender != _settings.safe()) revert OwnableUnauthorizedAccount(msg.sender);
        if (treasury == address(0) || protocolValue == address(0)) revert ZeroRecipient();
        if (treasuryBps_ > BPS) revert InvalidConfiguration();
        treasuryRecipient = treasury;
        protocolValueRecipient = protocolValue;
        treasuryBps = treasuryBps_;
        emit SplitSet(treasury, protocolValue, treasuryBps_);
    }

    function _pay(address asset, address recipient, uint256 amount) private {
        if (amount == 0) return;
        if (asset == address(0)) Address.sendValue(payable(recipient), amount);
        else IERC20(asset).safeTransfer(recipient, amount);
    }
}
