// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IBlockVault } from "../interfaces/IBlockVault.sol";

import { PolicySweeper } from "../periphery/PolicySweeper.sol";

/// @title StandardPolicy
/// @notice Claims one Block's revenue rows and forwards held assets to its vault.
/// @dev A zero Policy delivers directly to the vault. This optional Policy binds one vault and
/// sweeper. Launch supplies an uninitialized vault, so `vault.token()` is read during forwarding.
/// @custom:security-contact security@blocks.fm
contract StandardPolicy {
    using SafeERC20 for IERC20;

    /// @notice Returns the vault receiving forwarded assets.
    /// @return Vault fixed at deployment.
    IBlockVault public immutable vault;
    /// @notice Returns the sweeper claiming the Block's revenue rows.
    /// @return Row sweeper fixed at deployment.
    PolicySweeper public immutable sweeper;

    /// @notice Emitted when the Policy forwards an asset to the vault and syncs it.
    /// @param asset ERC-20 asset forwarded to the vault.
    /// @param amount Gross token base units transferred before the vault's work fee or burn.
    event Forwarded(address indexed asset, uint256 amount);

    /// @notice Binds the destination vault and row sweeper once at deployment.
    /// @dev The deployer may supply an uninitialized vault.
    /// @param vault_ Vault receiving all forwarded assets.
    /// @param sweeper_ Sweeper claiming the bound Block's revenue rows.
    constructor(IBlockVault vault_, PolicySweeper sweeper_) {
        vault = vault_;
        sweeper = sweeper_;
    }

    /// @notice Claims the Block's revenue rows and forwards the whole asset balance to its vault.
    /// @dev Anyone may call. Returns if the balance is zero.
    /// An unaccepted extra reverts unless it still occupies an extra slot and the transfer leaves
    /// the vault in deficit. A revert rolls back the transfer and row claims.
    /// The Block admin can restore retention to allow forwarding again.
    /// The vault burns its own Block token. For other assets, `sync` reconciles backing and
    /// reserved claims and charges the work fee only on a surplus.
    /// @param asset BUX, the Block token to burn, or an asset in the vault's extra slots.
    function forward(IERC20 asset) external {
        sweeper.claimAll(vault.token());
        uint256 amount = asset.balanceOf(address(this));
        if (amount == 0) return;
        asset.safeTransfer(address(vault), amount);
        vault.sync(address(asset));
        emit Forwarded(address(asset), amount);
    }
}
