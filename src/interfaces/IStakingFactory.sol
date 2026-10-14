// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IBlockFactory } from "./IBlockFactory.sol";
import { IBlockRegistry } from "./IBlockRegistry.sol";
import { IBuybackConfig } from "./IBuybackConfig.sol";

/// @title IStakingFactory
/// @notice Launches staking Blocks and tracks revenue configurations, Block admins and payouts.
interface IStakingFactory is IBlockRegistry {
    /// @notice Configures a staking vault using the factory's fixed buyback configuration.
    struct LaunchParams {
        // Empty selects the default receipt name.
        string name;
        address underlying;
        // `address(0)` selects the caller as the Block admin.
        address admin;
        // Maximum unlock duration in seconds. Zero selects ten days. Otherwise, 1-30 days.
        uint32 profitUnlockTime;
        string metadataURI;
    }

    /// @notice Emitted when a staking Block and its revenue destinations are registered.
    /// @param token Staking vault address.
    /// @param underlying Staking vault's underlying ERC-20 asset.
    /// @param config Fixed revenue routing configuration.
    /// @param admin Block admin authorized to update metadata and payout routing.
    /// @param payout Destination for future creator payouts.
    event StakingBlockCreated(
        address indexed token,
        address indexed underlying,
        address config,
        address admin,
        address payout
    );
    /// @notice Emitted when the Block's metadata URI is published.
    /// @param token Registered staking vault address.
    /// @param metadataURI Metadata location. May be empty.
    event MetadataSet(address indexed token, string metadataURI);
    /// @notice Emitted when the Block admin sets the destination for future creator payouts.
    /// @param token Registered staking vault address.
    /// @param payout New creator payout destination.
    event PayoutSet(address indexed token, address payout);
    /// @notice Emitted when a weighted payout is created for a staking Block.
    /// @param token Staking vault address.
    /// @param payout Newly created weighted payout address.
    /// @param recipients Unique payees corresponding to the weights.
    /// @param weights Positive payout shares in bps, totaling 10_000 bps (100%).
    event PayeesSet(
        address indexed token, address indexed payout, address[] recipients, uint16[] weights
    );
    /// @notice Emitted when administration of a staking Block is transferred.
    /// @param token Registered staking vault address.
    /// @param admin New Block admin address.
    event AdminTransferred(address indexed token, address admin);
    /// @notice Emitted when the Safe sets the fee for future launches.
    /// @param launchFeeWei Launch fee in wei. Zero makes launches free.
    event LaunchFeeSet(uint256 launchFeeWei);

    /// @notice Thrown when Block factory and buyback settings differ, the factory is not listed,
    /// or the underlying has no code.
    /// @dev Payout creation uses the same selector for invalid payee counts or weight totals.
    error InvalidConfiguration();
    /// @notice Thrown when the native payment differs from the required launch fee.
    error WrongLaunchFee();
    /// @notice Thrown when an administrative operation targets an unregistered staking vault.
    /// @param token Unregistered token address.
    error NotRegistered(address token);
    /// @notice Thrown when the caller is not the Block admin.
    error NotAdmin();
    /// @notice Thrown when the caller is not the current Safe.
    error OnlySafe();
    /// @notice Thrown when a payout is address zero or one, or the new Block admin is zero.
    error ZeroAddress();

    // Launch

    /// @notice Launches a live ERC-4626 staking Block with a fixed buyback Policy.
    /// @dev Anyone may call. Requires a listed factory, active markets and the exact `launchFee`
    /// in wei. The vault redeems only underlying. BUX and BUX's reserve asset need no auction.
    /// Other underlying assets must expose `decimals()`, have at most 18 decimals and allow auction
    /// creation. Weighted payees cannot include the new payout itself.
    /// @param params Underlying, Block admin, unlock duration and metadata for the staking vault.
    /// @param recipients One to 16 unique payees above address one. Leave both arrays empty to pay
    /// the Block admin.
    /// @param weights Matching positive shares in bps, totaling 10_000 bps (100%) when nonempty.
    /// @return token Newly registered staking vault address.
    function launch(
        LaunchParams calldata params,
        address[] calldata recipients,
        uint16[] calldata weights
    ) external payable returns (address token);

    // Block administration

    /// @notice Publishes metadata for a registered Block.
    /// @dev Only the Block admin may call.
    /// @param token Registered staking vault address.
    /// @param metadataURI Metadata location. May be empty.
    function setMetadata(address token, string calldata metadataURI) external;

    /// @notice Sets the destination for future creator payouts.
    /// @dev Only the Block admin may call. Use the Block's jar to pay its community.
    /// @param token Registered staking vault address.
    /// @param payout New payout destination. Addresses zero and one are reserved.
    function setPayout(address token, address payout) external;

    /// @notice Creates an immutable weighted payout for future creator payouts.
    /// @dev Only the Block admin may call. Existing payouts retain their fees and recipients.
    /// @param token Registered staking vault address.
    /// @param recipients One to 16 unique payees above address one, excluding the new payout.
    /// @param weights Matching positive payout shares in bps, totaling 10_000 bps (100%).
    function setPayees(address token, address[] calldata recipients, uint16[] calldata weights)
        external;

    /// @notice Transfers Block administration.
    /// @dev Only the Block admin may call. The payout destination remains unchanged.
    /// @param token Registered staking vault address.
    /// @param newAdmin Nonzero Block admin address.
    function transferAdmin(address token, address newAdmin) external;

    // Protocol configuration

    /// @notice Sets the fee for future launches.
    /// @dev Only the Safe may call.
    /// @param launchFeeWei Launch fee in wei. Zero makes launches free.
    function setLaunchFee(uint256 launchFeeWei) external;

    // Views

    /// @notice Returns the Block factory supplying shared dependencies and the market pause gate.
    /// @return Block factory fixed at deployment.
    function blockFactory() external view returns (IBlockFactory);

    /// @notice Returns the implementation cloned for weighted payouts.
    /// @return Payout implementation fixed at deployment.
    function payoutImplementation() external view returns (address);

    /// @notice Returns the shared auction configuration used by new staking launches.
    /// @return Buyback configuration fixed at deployment.
    function buybackConfig() external view returns (IBuybackConfig);

    /// @notice Returns the launch fee.
    /// @return Fee in wei. Zero makes launches free.
    function launchFee() external view returns (uint256);
}
