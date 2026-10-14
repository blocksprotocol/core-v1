// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC5267 } from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @title IPermitSignatures
/// @notice Authorizes token allowances with typed signatures from EOAs and ERC-1271 wallets.
/// @dev Checks ECDSA first. A low-s, 65-byte signature must recover the signer.
/// Otherwise, a signer with code must return the ERC-1271 magic value through a static call
/// at execution. ERC-1271 approval needs no key signature.
/// An EIP-7702 delegate's ERC-1271 policy cannot veto the account's key signatures.
/// Switching delegates does not cancel outstanding key signatures. Anyone may submit a permit
/// first. Integrations must tolerate consumed permits and authorize their action separately.
/// Calling `approve(spender, 0)` does not consume a permit nonce.
/// A successful permit, including a zero-value permit, consumes its nonce.
interface IPermitSignatures is IERC5267, IERC20Permit {
    /// @notice Thrown when a permit's inclusive deadline has passed.
    /// @param deadline Last valid time in Unix seconds.
    error ERC2612ExpiredSignature(uint256 deadline);
    /// @notice Thrown when ECDSA recovers another signer or an owner with code fails both checks.
    /// @param signer Recovered address. Zero if ECDSA recovery fails for an owner with code.
    /// @param owner Account whose allowance the permit attempts to set.
    error ERC2612InvalidSigner(address signer, address owner);

    // Permit

    /// @notice Sets an allowance using the owner's next sequential permit nonce.
    /// @dev Anyone may call. The allowance does not expire at the permit deadline.
    /// Malformed signatures from owners without code revert with ECDSA recovery errors.
    /// @param owner Token holder; cannot be zero.
    /// @param spender Account allowed to spend; cannot be zero.
    /// @param value Allowance in token base units. Zero revokes. `type(uint256).max` is unlimited.
    /// @param deadline Inclusive bound in Unix seconds; `type(uint256).max` means no expiration.
    /// @param v Recovery identifier; `r`, `s` and `v` are packed in that order before validation.
    /// @param r First 32 signature bytes.
    /// @param s Second 32 signature bytes.
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /// @notice Sets an allowance using the owner's next sequential permit nonce.
    /// @dev Anyone may call. The allowance does not expire at the permit deadline.
    /// Malformed signatures from owners without code revert with ECDSA recovery errors.
    /// @param owner Token holder; cannot be zero.
    /// @param spender Account allowed to spend; cannot be zero.
    /// @param value Allowance in token base units. Zero revokes. `type(uint256).max` is unlimited.
    /// @param deadline Inclusive bound in Unix seconds; `type(uint256).max` means no expiration.
    /// @param signature ECDSA bytes packed as `r`, `s`, `v`, or an ERC-1271 signature.
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        bytes memory signature
    ) external;

    // Views

    /// @notice Returns the next sequential permit nonce.
    /// @param owner Permit signer.
    /// @return Next unused permit nonce, starting at zero.
    function nonces(address owner) external view returns (uint256);

    /// @notice Returns the signing domain for the current chain and this token.
    /// @return EIP-712 domain separator.
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    /// @notice Returns the Permit EIP-712 type hash.
    /// @return Keccak-256 hash of the standard Permit type string.
    function PERMIT_TYPEHASH() external view returns (bytes32);
}
