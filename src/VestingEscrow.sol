// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from
    "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IBlockFactory } from "./interfaces/IBlockFactory.sol";
import { IBlockToken } from "./interfaces/IBlockToken.sol";
import { IVestingEscrow } from "./interfaces/IVestingEscrow.sol";

/// @title VestingEscrow
/// @notice Releases vested launch tokens to the current payout through an immutable clone.
/// @custom:security-contact security@blocks.fm
contract VestingEscrow is IVestingEscrow, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @inheritdoc IVestingEscrow
    address public token;
    /// @inheritdoc IVestingEscrow
    address public factory;
    /// @inheritdoc IVestingEscrow
    uint256 public total;
    /// @inheritdoc IVestingEscrow
    uint256 public released;
    /// @inheritdoc IVestingEscrow
    uint64 public cliffEnd;
    /// @inheritdoc IVestingEscrow
    uint64 public vestEnd;

    // Initialization

    /// @notice Locks initialization of the implementation when deployed.
    constructor() {
        token = address(1); // Clone storage starts at zero.
    }

    /// @inheritdoc IVestingEscrow
    function initialize(
        address token_,
        address factory_,
        uint256 total_,
        uint64 cliffEnd_,
        uint64 vestEnd_
    ) external {
        if (token != address(0)) revert AlreadyInitialized();
        if (
            factory_ != msg.sender || IBlockToken(token_).factory() != factory_ || total_ == 0
                || IERC20(token_).balanceOf(address(this)) < total_ || cliffEnd_ < block.timestamp
                || vestEnd_ < cliffEnd_ || uint256(vestEnd_) - block.timestamp > 1825 days
        ) revert InvalidInitialization();

        token = token_;
        factory = factory_;
        total = total_;
        cliffEnd = cliffEnd_;
        vestEnd = vestEnd_;
    }

    // Release

    /// @inheritdoc IVestingEscrow
    function release() external nonReentrant returns (uint256 amount) {
        amount = releasable();
        if (amount == 0) revert NothingToRelease();
        IBlockFactory blockFactory = IBlockFactory(factory);
        address to = blockFactory.payoutOf(token);
        if (to == address(0) || to == address(this)) revert InvalidRecipient();

        released += amount;

        IERC20(token).safeTransfer(to, amount);
        emit Released(to, amount, released);
    }

    // Views

    /// @inheritdoc IVestingEscrow
    function vested() public view returns (uint256) {
        if (block.timestamp < cliffEnd) return 0;
        if (block.timestamp >= vestEnd) return total;
        return Math.mulDiv(total, block.timestamp - cliffEnd, vestEnd - cliffEnd);
    }

    /// @inheritdoc IVestingEscrow
    function releasable() public view returns (uint256) {
        return vested() - released;
    }
}
