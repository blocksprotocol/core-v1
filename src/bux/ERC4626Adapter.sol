// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IBuxAdapter } from "../interfaces/IBuxAdapter.sol";

/// @title ERC4626Adapter
/// @notice Invests BUX reserves in an ERC-4626 vault and returns withdrawals to BUX.
/// @dev The vault must return exact withdrawal amounts.
/// Zero `maxDeposit` blocks investment. Zero `maxWithdraw` still allows idle withdrawals.
/// @custom:security-contact security@blocks.fm
contract ERC4626Adapter is IBuxAdapter {
    using SafeERC20 for IERC20;

    /// @inheritdoc IBuxAdapter
    address public immutable bux;
    /// @inheritdoc IBuxAdapter
    address public immutable asset;
    /// @notice Returns the ERC-4626 vault holding the invested reserves.
    /// @return Vault fixed at deployment.
    IERC4626 public immutable vault;

    /// @notice Emitted when prefunded underlying is invested in the vault.
    /// @param assets Invested underlying-token base units.
    event Deposited(uint256 assets);
    /// @notice Emitted when underlying is returned to BUX.
    /// @param assets Transferred underlying-token base units.
    event Withdrawn(uint256 assets);
    /// @notice Emitted when shares and idle underlying are transferred without redemption.
    /// @param to Recipient of shares and idle underlying.
    /// @param shares Transferred vault shares in share base units.
    /// @param assets Transferred idle underlying-token base units.
    event Rescued(address indexed to, uint256 shares, uint256 assets);

    /// @notice Thrown when anyone other than BUX calls a reserve operation.
    error OnlyBux();
    /// @notice Thrown when amounts are zero, exceed capacity or deposits mint no shares.
    error Unavailable();

    modifier onlyBux() {
        if (msg.sender != bux) revert OnlyBux();
        _;
    }

    // Initialization

    /// @notice Binds BUX, the vault and its underlying asset once at deployment.
    /// @param bux_ BUX contract authorized to deposit, withdraw and rescue.
    /// @param vault_ ERC-4626 vault with deployed code, reporting the reserve underlying.
    constructor(address bux_, IERC4626 vault_) {
        require(bux_.code.length != 0, "BUX required");
        require(address(vault_).code.length != 0, "vault required");
        bux = bux_;
        vault = vault_;
        asset = vault_.asset();
    }

    // Reserve operations

    /// @inheritdoc IBuxAdapter
    function deposit(uint256 assets) external onlyBux {
        if (assets == 0 || assets > vault.maxDeposit(address(this))) revert Unavailable();
        IERC20(asset).forceApprove(address(vault), assets);
        if (vault.deposit(assets, address(this)) == 0) revert Unavailable();
        IERC20(asset).forceApprove(address(vault), 0);
        emit Deposited(assets);
    }

    /// @inheritdoc IBuxAdapter
    function withdraw(uint256 assets) external onlyBux {
        if (assets == 0 || assets > maxWithdraw()) revert Unavailable();
        uint256 idle = IERC20(asset).balanceOf(address(this));
        if (assets > idle) vault.withdraw(assets - idle, address(this), address(this));
        IERC20(asset).safeTransfer(bux, assets);
        emit Withdrawn(assets);
    }

    /// @inheritdoc IBuxAdapter
    function rescue(address to) external onlyBux {
        uint256 shares = vault.balanceOf(address(this));
        uint256 assets = IERC20(asset).balanceOf(address(this));
        if (shares != 0) IERC20(address(vault)).safeTransfer(to, shares);
        if (assets != 0) IERC20(asset).safeTransfer(to, assets);
        emit Rescued(to, shares, assets);
    }

    // Views

    /// @inheritdoc IBuxAdapter
    /// @dev ERC-4626 share conversion rounds down to underlying-token base units.
    /// The vault retains the fractional value, which this quote excludes.
    function balance() external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this))
            + vault.convertToAssets(vault.balanceOf(address(this)));
    }

    /// @inheritdoc IBuxAdapter
    function maxWithdraw() public view returns (uint256) {
        return IERC20(asset).balanceOf(address(this)) + vault.maxWithdraw(address(this));
    }
}
