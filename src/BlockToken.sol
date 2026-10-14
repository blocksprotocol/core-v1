// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { IBlockToken } from "./interfaces/IBlockToken.sol";
import { IPermitSignatures } from "./interfaces/IPermitSignatures.sol";

import { ERC20PermitSignatures } from "./token/ERC20PermitSignatures.sol";

/// @title BlockToken
/// @notice Provides an ERC-20 token with permit, a fixed initial supply and holder burns.
/// @dev Deployment sets metadata and the permit domain. The token has no initializer or upgrade.
/// @custom:security-contact security@blocks.fm
contract BlockToken is ERC20, ERC20PermitSignatures, IBlockToken {
    /// @notice Returns the initial issuance in token base units (18 decimals).
    /// @return One billion tokens in base units.
    uint256 public constant SUPPLY = 1_000_000_000e18;

    /// @inheritdoc IBlockToken
    address public immutable factory;

    /// @notice Mints the initial supply to the factory at deployment.
    /// @param name_ Token name and permit signing domain name.
    /// @param symbol_ Token ticker.
    /// @param factory_ Recorded factory and initial supply recipient.
    constructor(string memory name_, string memory symbol_, address factory_)
        ERC20PermitSignatures(name_, symbol_)
    {
        factory = factory_;
        _mint(factory_, SUPPLY); // No further minting.
    }

    /// @inheritdoc IBlockToken
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @inheritdoc IPermitSignatures
    function nonces(address owner)
        public
        view
        override(ERC20PermitSignatures, IPermitSignatures)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}
