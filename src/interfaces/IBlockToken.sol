// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IPermitSignatures } from "./IPermitSignatures.sol";

/// @title IBlockToken
/// @notice Defines the ERC-20 token of a Block or Coin, with permit and holder burns.
/// @dev The factory receives 1e27 token base units (18 decimals) at deployment.
/// The token has no further minting, pause, blacklist, transfer tax or upgrade.
interface IBlockToken is IERC20, IPermitSignatures {
    /// @notice Burns the caller's tokens, reducing outstanding supply.
    /// @dev Anyone may call.
    /// @param amount Token base units (18 decimals) to burn.
    function burn(uint256 amount) external;

    /// @notice Returns the factory recorded at deployment.
    /// @return Recorded factory address.
    function factory() external view returns (address);
}
