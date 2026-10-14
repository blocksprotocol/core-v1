// SPDX-License-Identifier: Apache-2.0 AND MIT
pragma solidity 0.8.37;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Nonces } from "@openzeppelin/contracts/utils/Nonces.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import { IPermitSignatures } from "../interfaces/IPermitSignatures.sol";

/// @title ERC20PermitSignatures
/// @notice Validates typed signatures for token allowances from EOAs and ERC-1271 wallets.
/// @dev ECDSA remains valid for delegated EOAs. ERC-1271 validation is read-only.
/// Signatures bind the current chain and token address.
abstract contract ERC20PermitSignatures is ERC20, IPermitSignatures, EIP712, Nonces {
    /// @inheritdoc IPermitSignatures
    bytes32 public constant PERMIT_TYPEHASH = keccak256(
        "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
    );

    // Initialization

    /// @notice Binds the signing domain at token deployment.
    /// @param name_ Token and signing domain name. The version is "1".
    /// @param symbol_ Token ticker.
    constructor(string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        EIP712(name_, "1")
    { }

    // Permit

    /// @inheritdoc IPermitSignatures
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        permit(owner, spender, value, deadline, abi.encodePacked(r, s, v));
    }

    /// @inheritdoc IPermitSignatures
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        bytes memory signature
    ) public {
        if (block.timestamp > deadline) revert ERC2612ExpiredSignature(deadline);

        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, owner, spender, value, _useNonce(owner), deadline)
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        (bool valid, address recovered) = _isValidSignature(owner, digest, signature);
        if (!valid) {
            // Preserve ECDSA recovery errors for owners without code.
            if (owner.code.length == 0) ECDSA.recover(digest, signature);
            revert ERC2612InvalidSigner(recovered, owner);
        }

        _approve(owner, spender, value);
    }

    // Views

    /// @inheritdoc IPermitSignatures
    function nonces(address owner)
        public
        view
        virtual
        override(IPermitSignatures, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    /// @inheritdoc IPermitSignatures
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // Internal functions

    function _isValidSignature(address signer, bytes32 digest, bytes memory signature)
        internal
        view
        returns (bool valid, address recovered)
    {
        ECDSA.RecoverError recoverError;
        (recovered, recoverError,) = ECDSA.tryRecover(digest, signature);
        // Delegated EOAs can sign with their own key even if the delegate lacks ERC-1271.
        if (recoverError == ECDSA.RecoverError.NoError && recovered == signer) {
            return (true, recovered);
        }
        valid = signer.code.length != 0
            && SignatureChecker.isValidERC1271SignatureNow(signer, digest, signature);
    }
}
