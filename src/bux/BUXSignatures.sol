// SPDX-License-Identifier: Apache-2.0 AND MIT
pragma solidity 0.8.37;

import { IBUXSignatures } from "../interfaces/IBUXSignatures.sol";
import { IPermitSignatures } from "../interfaces/IPermitSignatures.sol";

import { ERC20PermitSignatures } from "../token/ERC20PermitSignatures.sol";

/// @title BUXSignatures
/// @notice Validates typed signatures for BUX allowances and single-use payments.
/// @dev Signatures bind the current chain and token address.
/// Payment nonces never authorize allowances.
abstract contract BUXSignatures is ERC20PermitSignatures, IBUXSignatures {
    /// @inheritdoc IBUXSignatures
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    /// @inheritdoc IBUXSignatures
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    /// @inheritdoc IBUXSignatures
    bytes32 public constant CANCEL_AUTHORIZATION_TYPEHASH =
        keccak256("CancelAuthorization(address authorizer,bytes32 nonce)");

    // Used or canceled payment nonces. Permit nonces are separate.
    mapping(address => mapping(bytes32 => bool)) private _authorizationStates;

    // Initialization

    /// @notice Binds the BUX signing domain at deployment.
    constructor() ERC20PermitSignatures("BUX", "BUX") { }

    // Payment authorizations

    /// @inheritdoc IBUXSignatures
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        transferWithAuthorization(
            from, to, value, validAfter, validBefore, nonce, abi.encodePacked(r, s, v)
        );
    }

    /// @inheritdoc IBUXSignatures
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) public {
        _transferWithAuthorization(
            TRANSFER_WITH_AUTHORIZATION_TYPEHASH,
            from,
            to,
            value,
            validAfter,
            validBefore,
            nonce,
            signature
        );
    }

    /// @inheritdoc IBUXSignatures
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        receiveWithAuthorization(
            from, to, value, validAfter, validBefore, nonce, abi.encodePacked(r, s, v)
        );
    }

    /// @inheritdoc IBUXSignatures
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) public {
        if (to != msg.sender) revert OnlyPayee();
        _transferWithAuthorization(
            RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
            from,
            to,
            value,
            validAfter,
            validBefore,
            nonce,
            signature
        );
    }

    /// @inheritdoc IBUXSignatures
    function cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s)
        external
    {
        cancelAuthorization(authorizer, nonce, abi.encodePacked(r, s, v));
    }

    /// @inheritdoc IBUXSignatures
    function cancelAuthorization(address authorizer, bytes32 nonce, bytes memory signature)
        public
    {
        _requireUnusedAuthorization(authorizer, nonce);
        _requireValidSignature(
            authorizer,
            keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce)),
            signature
        );

        _authorizationStates[authorizer][nonce] = true;
        emit AuthorizationCanceled(authorizer, nonce);
    }

    // Views

    /// @inheritdoc IPermitSignatures
    function nonces(address owner)
        public
        view
        override(IPermitSignatures, ERC20PermitSignatures)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    /// @inheritdoc IBUXSignatures
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool) {
        return _authorizationStates[authorizer][nonce];
    }

    // Internal functions

    function _transferWithAuthorization(
        bytes32 typehash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) private {
        if (block.timestamp <= validAfter) revert AuthorizationNotYetValid();
        if (block.timestamp >= validBefore) revert AuthorizationExpired();
        _requireUnusedAuthorization(from, nonce);
        _requireValidSignature(
            from,
            keccak256(abi.encode(typehash, from, to, value, validAfter, validBefore, nonce)),
            signature
        );

        _authorizationStates[from][nonce] = true;
        emit AuthorizationUsed(from, nonce);
        _transfer(from, to, value);
    }

    function _requireUnusedAuthorization(address authorizer, bytes32 nonce) private view {
        if (_authorizationStates[authorizer][nonce]) {
            revert AuthorizationAlreadyUsed(authorizer, nonce);
        }
    }

    function _requireValidSignature(address signer, bytes32 structHash, bytes memory signature)
        private
        view
    {
        (bool valid,) = _isValidSignature(signer, _hashTypedDataV4(structHash), signature);
        if (!valid) revert InvalidSignature();
    }
}
