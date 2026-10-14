// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IPermitSignatures } from "./IPermitSignatures.sol";

/// @title IBUXSignatures
/// @notice Authorizes BUX allowances and single-use payments with typed signatures.
/// @dev Permit and payment nonces are independent. Contract signatures are checked at execution.
/// Validation first tries low-s, 65-byte ECDSA recovery. If it fails to match the signer,
/// a signer with code must return the ERC-1271 magic value through a static call.
/// An EIP-7702 delegate cannot veto the account's key signature. Switching delegates does not
/// cancel it. ERC-1271 approval is sufficient without a key signature.
/// Receiving contracts must use receive authorizations and bind their order terms separately.
interface IBUXSignatures is IPermitSignatures {
    /// @notice Emitted when a payment authorization is consumed.
    /// @param authorizer Account that authorized the payment.
    /// @param nonce Consumed authorization nonce.
    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);

    /// @notice Emitted when a signed cancellation consumes an authorization nonce.
    /// @param authorizer Account that authorized the cancellation.
    /// @param nonce Canceled authorization nonce.
    event AuthorizationCanceled(address indexed authorizer, bytes32 indexed nonce);

    /// @notice Thrown when neither ECDSA recovery nor ERC-1271 validates a payment or cancellation
    /// signature.
    error InvalidSignature();
    /// @notice Thrown when the timestamp is at or before the authorization's lower bound.
    error AuthorizationNotYetValid();
    /// @notice Thrown when the timestamp is at or after the authorization's upper bound.
    error AuthorizationExpired();
    /// @notice Thrown when an authorization nonce has been used or canceled.
    /// @param authorizer Account whose nonce is unavailable.
    /// @param nonce Used or canceled authorization nonce.
    error AuthorizationAlreadyUsed(address authorizer, bytes32 nonce);
    /// @notice Thrown when the caller of a receive authorization is not its payee.
    error OnlyPayee();

    // Payment authorizations

    /// @notice Transfers an exact payment authorized by the payer.
    /// @dev Anyone may call. Use a receive authorization for an atomic contract purchase.
    /// Time bounds are exclusive. Transfer and receive authorizations share payment nonces.
    /// @param from Payer. Cannot be zero.
    /// @param to Payee. Cannot be zero.
    /// @param value Payment in BUX base units (6 decimals). Zero is allowed.
    /// @param validAfter Exclusive lower bound in Unix seconds. Zero allows later timestamps.
    /// @param validBefore Exclusive upper bound in Unix seconds.
    /// `type(uint256).max` sets the latest possible expiry.
    /// @param nonce Unique payment nonce for this payer. Zero is valid.
    /// @param v Recovery identifier, packed after `r` and `s` for validation.
    /// @param r First 32 signature bytes.
    /// @param s Second 32 signature bytes.
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
    ) external;

    /// @notice Transfers an exact payment authorized by the payer.
    /// @dev Anyone may call. Use a receive authorization for an atomic contract purchase.
    /// Time bounds are exclusive. Transfer and receive authorizations share payment nonces.
    /// @param from Payer. Cannot be zero.
    /// @param to Payee. Cannot be zero.
    /// @param value Payment in BUX base units (6 decimals). Zero is allowed.
    /// @param validAfter Exclusive lower bound in Unix seconds. Zero allows later timestamps.
    /// @param validBefore Exclusive upper bound in Unix seconds.
    /// `type(uint256).max` sets the latest possible expiry.
    /// @param nonce Unique payment nonce for this payer. Zero is valid.
    /// @param signature ECDSA bytes packed as `r`, `s`, `v`, or an arbitrary ERC-1271 signature.
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external;

    /// @notice Receives an exact payment authorized by the payer.
    /// @dev Only the payee may call, so the payment settles inside the payee's own call.
    /// Time bounds are exclusive. Transfer and receive authorizations share payment nonces.
    /// @param from Payer. Cannot be zero.
    /// @param to Payee. Cannot be zero.
    /// @param value Payment in BUX base units (6 decimals). Zero is allowed.
    /// @param validAfter Exclusive lower bound in Unix seconds. Zero allows later timestamps.
    /// @param validBefore Exclusive upper bound in Unix seconds.
    /// `type(uint256).max` sets the latest possible expiry.
    /// @param nonce Unique payment nonce for this payer. Zero is valid.
    /// @param v Recovery identifier, packed after `r` and `s` for validation.
    /// @param r First 32 signature bytes.
    /// @param s Second 32 signature bytes.
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
    ) external;

    /// @notice Receives an exact payment authorized by the payer.
    /// @dev Only the payee may call, so the payment settles inside the payee's own call.
    /// Time bounds are exclusive. Transfer and receive authorizations share payment nonces.
    /// @param from Payer. Cannot be zero.
    /// @param to Payee. Cannot be zero.
    /// @param value Payment in BUX base units (6 decimals). Zero is allowed.
    /// @param validAfter Exclusive lower bound in Unix seconds. Zero allows later timestamps.
    /// @param validBefore Exclusive upper bound in Unix seconds.
    /// `type(uint256).max` sets the latest possible expiry.
    /// @param nonce Unique payment nonce for this payer. Zero is valid.
    /// @param signature ECDSA bytes packed as `r`, `s`, `v`, or an arbitrary ERC-1271 signature.
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external;

    /// @notice Cancels an unused payment nonce with the authorizer's signature.
    /// @dev Anyone may call. Cancellation and payment compete to consume the same nonce.
    /// @param authorizer Nonce owner. Cannot be zero.
    /// @param nonce Payment nonce to cancel. Zero is valid.
    /// @param v Recovery identifier, packed after `r` and `s` for validation.
    /// @param r First 32 signature bytes.
    /// @param s Second 32 signature bytes.
    function cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s)
        external;

    /// @notice Cancels an unused payment nonce with the authorizer's signature.
    /// @dev Anyone may call. Cancellation and payment compete to consume the same nonce.
    /// @param authorizer Nonce owner. Cannot be zero.
    /// @param nonce Payment nonce to cancel. Zero is valid.
    /// @param signature ECDSA bytes packed as `r`, `s`, `v`, or an arbitrary ERC-1271 signature.
    function cancelAuthorization(address authorizer, bytes32 nonce, bytes memory signature)
        external;

    // Views

    /// @notice Returns whether a payment nonce has been used or canceled.
    /// @param authorizer Nonce owner.
    /// @param nonce Payment nonce. Zero is valid.
    /// @return True if used or canceled, false if still unused.
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);

    /// @notice Returns the `TransferWithAuthorization` EIP-712 type hash.
    /// @return Keccak-256 hash of the standard `TransferWithAuthorization` type string.
    function TRANSFER_WITH_AUTHORIZATION_TYPEHASH() external view returns (bytes32);

    /// @notice Returns the `ReceiveWithAuthorization` EIP-712 type hash.
    /// @return Keccak-256 hash of the standard `ReceiveWithAuthorization` type string.
    function RECEIVE_WITH_AUTHORIZATION_TYPEHASH() external view returns (bytes32);

    /// @notice Returns the `CancelAuthorization` EIP-712 type hash.
    /// @return Keccak-256 hash of the standard `CancelAuthorization` type string.
    function CANCEL_AUTHORIZATION_TYPEHASH() external view returns (bytes32);
}
