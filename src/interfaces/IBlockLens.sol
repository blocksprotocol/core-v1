// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IBlockLens
/// @notice Reports Block status and destinations on the Block's home chain only.
interface IBlockLens {
    enum Kind {
        // No listed factory recognizes the token.
        None,
        // Registered Raise whose market is not live and whose sale is not canceled.
        Launching,
        // Registered Raise with an open market.
        Live,
        // Unclosed sale expired explicitly, with its entire initial token supply burned.
        Cancelled,
        // Registered staking Block.
        Staking
    }

    /// @notice Returns a Block's registration and lifecycle status on its home chain.
    /// @dev `Launching` includes sales before opening, taking commitments or awaiting close.
    /// Read the sale's `terms()` for its start and end times in Unix seconds.
    /// `Cancelled` requires explicit expiry at least seven days after the sale ends.
    /// A failed settings lookup returns `None`. Later factory and sale reads can revert.
    /// A token's `factory()` call can exhaust the available gas.
    /// @param token Block's home token address.
    /// @return Registration and lifecycle kind, or `None` if no factory is found.
    function kindOf(address token) external view returns (Kind);

    /// @notice Predicts the home-chain jar, or returns zero if no factory is found.
    /// @dev Uses `block.chainid` without deploying. Launching and canceled Blocks have predictable
    /// jars. A canceled Block's jar can sell inventory, but BUX proceeds and retained receipts
    /// remain in undeliverable Policy rows. Check `kindOf` before paying.
    /// @param token Block's home token address.
    /// @return Predicted jar address, or zero if no factory is found.
    function jarOf(address token) external view returns (address);

    /// @notice Returns the token itself for `Staking`, its vault for `Live`, or zero otherwise.
    /// @dev Staking Blocks use ERC-4626 `redeem(shares, receiver, owner)`.
    /// Live Blocks use the vault's `redeem(amount, to)`. Callers branch on `kindOf` first.
    /// @param token Block's home token address.
    /// @return Redemption destination, or zero when redemption is unavailable.
    function redemptionOf(address token) external view returns (address);
}
