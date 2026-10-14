// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.37;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { ReentrancyGuardTransient } from
    "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { IBlockFactory } from "../interfaces/IBlockFactory.sol";
import { IBlockRegistry } from "../interfaces/IBlockRegistry.sol";
import { IBuybackConfig } from "../interfaces/IBuybackConfig.sol";
import { ICreatorPayout } from "../interfaces/ICreatorPayout.sol";
import { IJarFactory } from "../interfaces/IJarFactory.sol";
import { IProtocolSettings } from "../interfaces/IProtocolSettings.sol";
import { IStakingFactory } from "../interfaces/IStakingFactory.sol";
import { IStakingVault } from "../interfaces/IStakingVault.sol";

import { BuybackPolicy } from "./BuybackPolicy.sol";
import { StakingBlockConfig } from "./StakingBlockConfig.sol";
import { StakingVault } from "./StakingVault.sol";

/// @title StakingFactory
/// @notice Launches staking Blocks and tracks revenue configurations, Block admins and payouts.
/// @dev Each staking vault holds its principal. Vault deployment salts include the chain ID
/// and an incrementing launch count. The factory exposes no market operations.
/// @custom:security-contact security@blocks.fm
contract StakingFactory is IStakingFactory, ReentrancyGuardTransient {
    using Clones for address;

    struct StakingBlock {
        // Revenue routing only. The staking vault holds assets.
        address config;
        address admin;
        // Destination for future creator payouts.
        address payout;
    }

    /// @inheritdoc IStakingFactory
    IBlockFactory public immutable blockFactory;
    /// @inheritdoc IBlockRegistry
    address public immutable settings;
    /// @inheritdoc IBlockRegistry
    address public immutable jarFactory;
    /// @inheritdoc IStakingFactory
    address public immutable payoutImplementation;
    /// @inheritdoc IStakingFactory
    IBuybackConfig public immutable buybackConfig;

    /// @inheritdoc IStakingFactory
    uint256 public launchFee;
    mapping(address token => StakingBlock) private _blocks;
    uint256 private _launchCount;

    modifier onlySafe() {
        if (msg.sender != IProtocolSettings(settings).safe()) revert OnlySafe();
        _;
    }

    modifier onlyAdmin(address token) {
        if (_blocks[token].config == address(0)) revert NotRegistered(token);
        if (msg.sender != _blocks[token].admin) revert NotAdmin();
        _;
    }

    // Initialization

    /// @notice Binds shared dependencies and the initial launch fee once at deployment.
    /// @dev The deployer must supply Block and buyback configurations with matching settings.
    /// @param blockFactory_ Block factory supplying dependencies and the shared market pause gate.
    /// @param buybackConfig_ Shared auction factory and row sweeper configuration.
    /// @param launchFee_ Launch fee in wei. Zero makes launches free.
    constructor(IBlockFactory blockFactory_, IBuybackConfig buybackConfig_, uint256 launchFee_) {
        blockFactory = blockFactory_;
        settings = blockFactory_.settings();
        jarFactory = blockFactory_.jarFactory();
        payoutImplementation = blockFactory_.payoutImplementation();
        buybackConfig = buybackConfig_;
        if (address(buybackConfig_.settings()) != settings) revert InvalidConfiguration();
        launchFee = launchFee_;
    }

    // Launch

    /// @inheritdoc IStakingFactory
    function launch(
        LaunchParams calldata params,
        address[] calldata recipients,
        uint16[] calldata weights
    ) external payable nonReentrant returns (address token) {
        // Shares the pause gate with Block and Coin launches and market operations.
        blockFactory.requireMarketsActive();
        if (
            !IProtocolSettings(settings).isBlockFactory(address(this))
                || params.underlying.code.length == 0
        ) revert InvalidConfiguration();
        if (msg.value != launchFee) revert WrongLaunchFee();

        address admin = params.admin == address(0) ? msg.sender : params.admin;
        token = address(
            new StakingVault{ salt: keccak256(abi.encode(block.chainid, ++_launchCount)) }(
                params.name, IERC20(params.underlying), address(this), params.profitUnlockTime
            )
        );
        address policy = address(new BuybackPolicy(IStakingVault(token), buybackConfig));
        address config = address(
            new StakingBlockConfig(
                token, params.underlying, IProtocolSettings(settings).bux(), policy
            )
        );
        address payout = recipients.length == 0 && weights.length == 0
            ? _checkPayout(admin)
            : _createPayout(token, recipients, weights);

        _blocks[token] = StakingBlock(config, admin, payout);
        IJarFactory(jarFactory).create(block.chainid, token);
        emit MetadataSet(token, params.metadataURI);
        emit StakingBlockCreated(token, params.underlying, config, admin, payout);
        Address.sendValue(payable(IProtocolSettings(settings).feePool()), msg.value);
    }

    // Block administration

    /// @inheritdoc IStakingFactory
    function setMetadata(address token, string calldata metadataURI) external onlyAdmin(token) {
        emit MetadataSet(token, metadataURI);
    }

    /// @inheritdoc IStakingFactory
    function setPayout(address token, address payout) external onlyAdmin(token) nonReentrant {
        payout = _checkPayout(payout);
        _blocks[token].payout = payout;
        emit PayoutSet(token, payout);
    }

    /// @inheritdoc IStakingFactory
    function setPayees(address token, address[] calldata recipients, uint16[] calldata weights)
        external
        onlyAdmin(token)
        nonReentrant
    {
        address payout = _createPayout(token, recipients, weights);
        _blocks[token].payout = payout;
        emit PayoutSet(token, payout);
    }

    /// @inheritdoc IStakingFactory
    function transferAdmin(address token, address newAdmin)
        external
        onlyAdmin(token)
        nonReentrant
    {
        if (newAdmin == address(0)) revert ZeroAddress();
        _blocks[token].admin = newAdmin;
        emit AdminTransferred(token, newAdmin);
    }

    // Protocol configuration

    /// @inheritdoc IStakingFactory
    function setLaunchFee(uint256 launchFeeWei) external onlySafe {
        launchFee = launchFeeWei;
        emit LaunchFeeSet(launchFeeWei);
    }

    // Views

    /// @inheritdoc IBlockRegistry
    function isRegistered(address token) external view returns (bool) {
        return _blocks[token].config != address(0);
    }

    /// @inheritdoc IBlockRegistry
    function isBlock(address token) external view returns (bool) {
        return _blocks[token].config != address(0);
    }

    /// @inheritdoc IBlockRegistry
    function isStakingBlock(address token) external view returns (bool) {
        return _blocks[token].config != address(0);
    }

    /// @inheritdoc IBlockRegistry
    function vaultOf(address token) external view returns (address) {
        return _blocks[token].config;
    }

    /// @inheritdoc IBlockRegistry
    function payoutOf(address token) external view returns (address) {
        return _blocks[token].payout;
    }

    /// @inheritdoc IBlockRegistry
    function adminOf(address token) external view returns (address) {
        return _blocks[token].admin;
    }

    // Internal functions

    function _checkPayout(address payout) private pure returns (address) {
        // Reserved low addresses are routing sentinels, never registered payees.
        if (payout <= address(1)) revert ZeroAddress();
        return payout;
    }

    function _createPayout(address token, address[] memory recipients, uint16[] memory weights)
        private
        returns (address payout)
    {
        payout = payoutImplementation.clone();
        ICreatorPayout(payout).initialize(address(this), recipients, weights);
        emit PayeesSet(token, payout, recipients, weights);
    }
}
