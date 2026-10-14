// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IAuction
/// @notice Sells enabled tokens in falling-price lots for one want token and pays its receiver.
/// @dev A lot is active while its price is nonzero. The price becomes zero below the minimum
/// price or more than one day after the kick.
interface IAuction {
    /// @notice Enables a token for sale.
    /// @dev Governance only. Reverts for the zero address, the want token, a token already enabled
    /// or a token with more than 18 decimals.
    /// @param from Token to sell.
    function enable(address from) external;

    /// @notice Sets the time between price decay steps.
    /// @dev Governance only. Requires no active lots and a duration greater than zero and below
    /// one day.
    /// @param stepDuration Seconds per step.
    function setStepDuration(uint256 stepDuration) external;

    /// @notice Sets whether only governance may kick lots.
    /// @dev Governance only.
    /// @param governanceOnlyKick True to restrict kicks to governance.
    function setGovernanceOnlyKick(bool governanceOnlyKick) external;

    /// @notice Sets the price below which a lot ends.
    /// @dev Governance only. Reverts while any lot is active.
    /// @param minimumPrice Want per whole token sold, in wad (1e18). Zero sets no minimum.
    function setMinimumPrice(uint256 minimumPrice) external;

    /// @notice Starts a lot that sells the auction's balance of `from`.
    /// @dev Reverts while a lot of `from` is active, for a token not enabled, for a zero balance,
    /// or for a caller other than governance when kicks are restricted.
    /// @param from Token to sell.
    /// @return `from` base units put up for sale.
    function kick(address from) external returns (uint256);

    /// @notice Settles an empty lot.
    /// @dev Anyone may call. Requires a kicked lot and a zero balance of `from`.
    /// @param from Token sold.
    function settle(address from) external;

    /// @notice Sends the auction's whole balance of `token` to governance.
    /// @dev Governance only.
    /// @param token Token to sweep.
    function sweep(address token) external;

    /// @notice Returns the amount of `from` still for sale in the current lot.
    /// @param from Token being sold.
    /// @return Auction balance in token base units, capped at the initial lot size.
    /// Zero if no lot is active.
    function available(address from) external view returns (uint256);

    /// @notice Returns whether the lot of `from` is active.
    /// @dev Taking a whole lot ends it. A lot emptied any other way stays active until it is
    /// settled or its price reaches zero.
    /// @param from Token being sold.
    /// @return True while a kicked lot still has a nonzero price.
    function isActive(address from) external view returns (bool);
}
