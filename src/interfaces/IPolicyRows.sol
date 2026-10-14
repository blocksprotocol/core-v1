// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IPolicyRows
/// @notice Exposes each Block's accrued assets for delivery to its current Policy or vault.
/// @dev A zero Policy delivers BUX to the vault by transfer and other assets by transfer then sync.
/// Every Block market swap credits the Block's share to its row. With a zero Policy, a later
/// swap delivers the BUX row left by earlier swaps to the vault.
interface IPolicyRows {
    /// @notice Emitted when assets accrue to a Block's Policy row.
    /// @param token Block's home token address.
    /// @param asset Token held in the row.
    /// @param amount Accrued token base units. Zero when the swap fee or the Block's share is zero.
    event PolicyAccrued(address indexed token, address indexed asset, uint256 amount);
    /// @notice Emitted when a Block's row is delivered to its current destination by a claim or,
    /// with a zero Policy, by a later Block market swap.
    /// @param token Block's home token address.
    /// @param policy Receiving Policy, or zero for direct vault delivery.
    /// @param asset ERC-20 token held in the row.
    /// @param amount Claimed token base units. Zero for an empty row.
    event PolicyClaimed(
        address indexed token, address indexed policy, address indexed asset, uint256 amount
    );

    /// @notice Claims accrued assets for the current Policy, or the vault for zero Policy.
    /// @dev Anyone may claim a row that remains. A Block's last swap leaves its own share waiting.
    /// @param token Block's home token address.
    /// @return assets Tokens reported by the claim, in the same order as `amounts`.
    /// @return amounts Claimed token base units for each asset.
    function claimPolicy(address token)
        external
        returns (address[] memory assets, uint256[] memory amounts);
}
