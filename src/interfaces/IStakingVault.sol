// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { IPermitSignatures } from "./IPermitSignatures.sol";

/// @title IStakingVault
/// @notice Holds a staking Block's underlying and unlocks revenue over time.
/// @dev The vault is immutable and supports only standard, non-rebasing, untaxed underlying tokens.
/// ERC-4626 previews exclude pending Policy revenue. Direct donations unlock immediately.
/// Permit grants a receipt-share allowance that authorizes withdrawals and redemptions under
/// the same guards as other allowances.
interface IStakingVault is IERC4626, IPermitSignatures {
    /// @notice Emitted when revenue is added and the profit-share lock is reconciled.
    /// @param payer Caller supplying the underlying.
    /// @param gross Gross revenue in underlying token base units.
    /// @param fee Work fee in underlying token base units, rounded down. Net keeps the remainder.
    /// @param net Revenue retained by the vault in underlying token base units.
    /// @param sharesLocked New profit shares in receipt share base units before reconciliation.
    /// Excludes burns and existing locked shares. Zero creates no new share lock.
    event RevenueAdded(
        address indexed payer, uint256 gross, uint256 fee, uint256 net, uint256 sharesLocked
    );

    /// @notice Thrown when a nonzero unlock duration is outside one to thirty days.
    error InvalidUnlockTime();
    /// @notice Thrown when the caller burning receipt shares is not the home jar.
    error OnlyHomeJar();
    /// @notice Thrown when the vault's underlying balance changes by a different amount than the
    /// transfer requested.
    error TransferMismatch();
    /// @notice Thrown when a positive underlying deposit rounds down to zero receipt shares.
    error ZeroDepositShares();

    // Revenue

    /// @notice Pulls underlying from the caller, pays the work fee and locks the remaining profit.
    /// @dev Anyone may call. The caller approves the gross amount and receives no receipt shares.
    /// Deposits share in revenue as it unlocks, including deposits made after this call.
    /// The work fee rounds down, leaving the remainder in the vault. Profit shares use the price
    /// before revenue arrives and round down, leaving fractional-share value with holders.
    /// If profit shares round to zero, net revenue reaches holders immediately without a new lock.
    /// @param amount Gross revenue in underlying token base units. Zero only reconciles the lock.
    /// @return netRevenue Underlying retained after the work fee, in token base units.
    function addRevenue(uint256 amount) external returns (uint256 netRevenue);

    /// @notice Locks the home jar's receipt shares for gradual consumption.
    /// @dev Only the home jar may call. Burns its shares and locks replacements without moving
    /// underlying. Effective supply stays unchanged at intake. New and existing locked shares
    /// unlock together. Holders exit through ERC-4626.
    /// @param amount Receipt share base units to consume. Zero only reconciles the lock.
    function burn(uint256 amount) external;

    // Views

    /// @notice Returns the factory bound at deployment.
    /// @return Factory registering this staking vault.
    function factory() external view returns (address);

    /// @notice Returns the deterministic home jar authorized to burn receipt shares.
    /// @return Home jar address on this chain.
    function homeJar() external view returns (address);

    /// @notice Returns the immutable maximum unlock duration for newly reported profit.
    /// @return Duration in seconds, from one to thirty days inclusive.
    function profitMaxUnlockTime() external view returns (uint32);

    /// @notice Returns the recorded end of the unlocking schedule.
    /// @dev A past timestamp can remain after all shares unlock.
    /// @return End in Unix seconds. Zero means no recorded schedule or a cleared schedule.
    function fullProfitUnlockDate() external view returns (uint256);

    /// @notice Returns the rate recorded for the last unlocking schedule.
    /// @dev Persists after expiry or clearing the end date.
    /// @return Self-held share base units per second, scaled by 1e12. Zero before any schedule.
    function profitUnlockingRate() external view returns (uint256);

    /// @notice Returns the start timestamp recorded for the last unlocking schedule.
    /// @dev Persists after expiry or clearing the end date.
    /// @return Start in Unix seconds. Zero before any schedule.
    function lastProfitUpdate() external view returns (uint256);
}
