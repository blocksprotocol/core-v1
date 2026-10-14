// SPDX-License-Identifier: AGPL-3.0-only
//                         #################
//                  ###############################
//              #############             #############
//           ##########                         ##########
//         ########                #######          ########
//       #######                   #######             #######
//     #######            #####################          #######
//    ######              ########################         ######
//   ######              #######          #########         ######
//  ######               #######             #######         ######
//  #####               #######             #######           #####
// ######               #######          #########            ######
// ######              ########################               ######
// ######              ##########################             ######
// ######             #######             ########            ######
//  #####             #######              ########           #####
//  ######           #######               ########          ######
//   #########      ########            ##########          ######
//    ##########################################           ######
//     #####################################             #######
//                            #######                  #######
//         ########           ######                ########
//           ##########                         ##########
//              #############             #############
//                  ###############################
//                         #################
pragma solidity 0.8.37;

import { Ownable, Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from
    "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IBUX } from "../interfaces/IBUX.sol";
import { IBuxAdapter } from "../interfaces/IBuxAdapter.sol";

import { BUXSignatures } from "./BUXSignatures.sol";

/// @title BUX
/// @notice Issues a six-decimal reserve token with allocation limits set by the BUX owner.
/// @dev Adapter debt records cost. Backing includes losses and excludes unrealized gains.
/// Harvests mint BUX only against realized surplus.
/// @custom:security-contact security@blocks.fm
contract BUX is IBUX, BUXSignatures, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    struct AdapterState {
        // Debt limit in underlying-token base units. Zero stops new allocation.
        uint256 maxDebt;
        // Recorded investment cost in underlying-token base units.
        uint256 currentDebt;
        bool approved;
    }

    /// @inheritdoc IBUX
    IERC20 public underlying;
    /// @inheritdoc IBUX
    address public yieldReceiver;
    /// @inheritdoc IBUX
    uint256 public minimumTotalIdle;
    /// @inheritdoc IBUX
    uint256 public totalDebt;
    /// @inheritdoc IBUX
    IBuxAdapter[] public adapters;
    /// @inheritdoc IBUX
    mapping(IBuxAdapter => AdapterState) public adapterState;
    /// @inheritdoc IBUX
    address public manager;

    modifier initialised() {
        if (address(underlying) == address(0)) revert NotInitialised();
        _;
    }

    // Initialization

    /// @notice Binds the initial BUX owner at deployment.
    /// @param safe Initial BUX owner, who binds the underlying once after deployment.
    constructor(address safe) Ownable(safe) { }

    /// @inheritdoc IBUX
    function initialise(IERC20 underlying_) external onlyOwner {
        if (
            address(underlying) != address(0) || address(underlying_) == address(this)
                || address(underlying_).code.length == 0
                || IERC20Metadata(address(underlying_)).decimals() != 6
        ) revert InvalidConfiguration();

        underlying = underlying_;
        emit Initialised(address(underlying_));
    }

    // Reserve operations

    /// @inheritdoc IBUX
    function deposit(uint256 underlyingIn, address to)
        external
        initialised
        nonReentrant
        returns (uint256 buxOut)
    {
        if (underlyingIn == 0) revert ZeroAmount();
        if (to == address(0) || to == address(this)) revert InvalidConfiguration();

        uint256 balanceBefore = underlying.balanceOf(address(this));
        underlying.safeTransferFrom(msg.sender, address(this), underlyingIn);
        buxOut = underlying.balanceOf(address(this)) - balanceBefore;
        if (buxOut == 0) revert ZeroAmount();
        _mint(to, buxOut);
        emit Deposited(msg.sender, to, underlyingIn, buxOut);
    }

    /// @inheritdoc IBUX
    function redeem(uint256 buxIn, address to)
        external
        initialised
        nonReentrant
        returns (uint256 underlyingOut)
    {
        if (buxIn == 0) revert ZeroAmount();
        if (to == address(0) || to == address(this)) revert InvalidConfiguration();

        _burn(msg.sender, buxIn);
        underlyingOut = buxIn;
        uint256 idle = underlying.balanceOf(address(this));
        // Each pull also asks for the idle minimum; only adapters the shortfall needs are called.
        for (uint256 i; idle < buxIn && i < adapters.length; ++i) {
            idle += _withdraw(adapters[i], Math.saturatingAdd(buxIn - idle, minimumTotalIdle), true);
        }
        if (idle < buxIn) revert InsufficientReserves();
        // Issuer freezes or failed transfers revert the burn.
        underlying.safeTransfer(to, underlyingOut);
        emit Redeemed(msg.sender, to, buxIn, underlyingOut);
    }

    /// @inheritdoc IBUX
    function harvest() external initialised nonReentrant returns (uint256 surplus) {
        for (uint256 i; i < adapters.length; ++i) {
            IBuxAdapter adapter = adapters[i];
            uint256 value = adapter.balance();
            uint256 currentDebt = adapterState[adapter].currentDebt;
            if (value > currentDebt) _withdraw(adapter, value - currentDebt, false);
        }

        uint256 backing = totalUnderlying();
        if (backing <= totalSupply()) return 0;
        surplus = Math.min(underlying.balanceOf(address(this)), backing - totalSupply());
        if (surplus == 0) return 0;

        _mint(yieldReceiver, surplus);
        emit Harvested(surplus, yieldReceiver);
    }

    /// @inheritdoc IBUX
    function updateDebt(IBuxAdapter adapter, uint256 targetDebt)
        external
        nonReentrant
        returns (uint256)
    {
        if (msg.sender != manager) revert OnlyManager();
        AdapterState storage state = adapterState[adapter];
        if (!state.approved) revert InvalidConfiguration();

        uint256 newDebt = targetDebt;
        uint256 currentDebt = state.currentDebt;
        if (newDebt == currentDebt) revert InvalidConfiguration();

        if (currentDebt > newDebt) {
            uint256 assetsToWithdraw = currentDebt - newDebt;
            uint256 idle = underlying.balanceOf(address(this));

            // Restore the idle minimum without withdrawing more than the adapter's debt.
            if (idle + assetsToWithdraw < minimumTotalIdle) {
                assetsToWithdraw = Math.min(minimumTotalIdle - idle, currentDebt);
            }

            assetsToWithdraw = Math.min(assetsToWithdraw, adapter.maxWithdraw());
            if (assetsToWithdraw == 0) return currentDebt;

            uint256 withdrawn = _withdraw(adapter, assetsToWithdraw, true);
            newDebt = currentDebt - withdrawn;
        } else {
            uint256 maxDebt = state.maxDebt;
            if (newDebt > maxDebt) {
                newDebt = maxDebt;
                // Current debt can exceed a lowered maximum.
                if (newDebt < currentDebt) return currentDebt;
            }

            uint256 assetsToDeposit = newDebt - currentDebt;
            uint256 idle = underlying.balanceOf(address(this));
            if (idle <= minimumTotalIdle) return currentDebt;

            assetsToDeposit = Math.min(assetsToDeposit, idle - minimumTotalIdle);
            if (assetsToDeposit > 0) {
                state.currentDebt += assetsToDeposit;
                totalDebt += assetsToDeposit;

                underlying.safeTransfer(address(adapter), assetsToDeposit);
                adapter.deposit(assetsToDeposit);
            }
            newDebt = currentDebt + assetsToDeposit;
        }

        emit DebtUpdated(address(adapter), currentDebt, newDebt);
        return newDebt;
    }

    // Reserve configuration

    /// @inheritdoc IBUX
    function setYieldReceiver(address yieldReceiver_) external onlyOwner {
        if (yieldReceiver_ == address(0) || yieldReceiver_ == address(this)) {
            revert InvalidConfiguration();
        }
        yieldReceiver = yieldReceiver_;
        emit YieldReceiverSet(yieldReceiver_);
    }

    /// @inheritdoc IBUX
    function setManager(address manager_) external onlyOwner {
        manager = manager_;
        emit ManagerSet(manager_);
    }

    /// @inheritdoc IBUX
    function addAdapter(IBuxAdapter adapter) external onlyOwner initialised {
        if (
            adapterState[adapter].approved || adapter.bux() != address(this)
                || adapter.asset() != address(underlying)
        ) revert InvalidConfiguration();
        adapterState[adapter].approved = true;
        adapters.push(adapter);
        emit AdapterAdded(address(adapter));
    }

    /// @inheritdoc IBUX
    function setMaxDebt(IBuxAdapter adapter, uint256 maxDebt) external onlyOwner {
        if (!adapterState[adapter].approved) revert InvalidConfiguration();
        adapterState[adapter].maxDebt = maxDebt;
        emit MaxDebtSet(address(adapter), maxDebt);
    }

    /// @inheritdoc IBUX
    function removeAdapter(IBuxAdapter adapter) external onlyOwner nonReentrant {
        if (!adapterState[adapter].approved) revert InvalidConfiguration();
        uint256 debtWrittenOff = _removeAdapter(adapter);
        emit AdapterRemoved(address(adapter), debtWrittenOff);
    }

    /// @inheritdoc IBUX
    function setMinimumTotalIdle(uint256 minimumTotalIdle_) external onlyOwner {
        minimumTotalIdle = minimumTotalIdle_;
        emit MinimumTotalIdleSet(minimumTotalIdle_);
    }

    /// @inheritdoc IBUX
    function emergencyRescue(uint256 amount) external onlyOwner {
        underlying.safeTransfer(msg.sender, amount);
        emit EmergencyRescue(amount);
    }

    /// @inheritdoc IBUX
    function rescueAdapter(IBuxAdapter adapter, address to) external onlyOwner nonReentrant {
        _removeAdapter(adapter);
        adapter.rescue(to);
        emit AdapterRescued(address(adapter), to);
    }

    // Views

    /// @inheritdoc IERC20Metadata
    /// @dev Six accounting decimals do not guarantee the underlying asset's market value.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @inheritdoc IBUX
    function totalUnderlying() public view returns (uint256 backing) {
        backing = underlying.balanceOf(address(this));
        for (uint256 i; i < adapters.length; ++i) {
            backing += Math.min(adapters[i].balance(), adapterState[adapters[i]].currentDebt);
        }
    }

    /// @inheritdoc IBUX
    function adapterCount() external view returns (uint256) {
        return adapters.length;
    }

    // Internal functions

    // Capital withdrawals reduce recorded debt. Harvesting gains leaves debt unchanged.
    function _withdraw(IBuxAdapter adapter, uint256 amount, bool capital)
        private
        returns (uint256 received)
    {
        amount = Math.min(amount, adapter.maxWithdraw());
        if (amount == 0) return 0;

        if (capital) {
            uint256 currentDebt = Math.min(amount, adapterState[adapter].currentDebt);
            adapterState[adapter].currentDebt -= currentDebt;
            totalDebt -= currentDebt;
        }

        uint256 balanceBefore = underlying.balanceOf(address(this));
        adapter.withdraw(amount);
        received = underlying.balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert InsufficientReserves();
        emit Withdrawn(address(adapter), received);
    }

    function _removeAdapter(IBuxAdapter adapter) private returns (uint256 debtWrittenOff) {
        debtWrittenOff = adapterState[adapter].currentDebt;
        totalDebt -= debtWrittenOff;
        delete adapterState[adapter];
        for (uint256 i; i < adapters.length; ++i) {
            if (address(adapters[i]) == address(adapter)) {
                adapters[i] = adapters[adapters.length - 1];
                adapters.pop();
                break;
            }
        }
    }
}
