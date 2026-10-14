// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuardTransient } from
    "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { IBlockBatchSale } from "./interfaces/IBlockBatchSale.sol";
import { IBlockFactory } from "./interfaces/IBlockFactory.sol";
import { IBlockHook } from "./interfaces/IBlockHook.sol";
import { IBlockRegistry } from "./interfaces/IBlockRegistry.sol";
import { ICreatorPayout } from "./interfaces/ICreatorPayout.sol";
import { IJarFactory } from "./interfaces/IJarFactory.sol";
import { IPolicyFactory } from "./interfaces/IPolicyFactory.sol";
import { IProtocolSettings } from "./interfaces/IProtocolSettings.sol";

import { BlockVault } from "./BlockVault.sol";
import { HookMigrationRegistry } from "./HookMigrationRegistry.sol";
import { LaunchSettlement } from "./libraries/LaunchSettlement.sol";

/// @title BlockFactory
/// @notice Launches Raised Blocks and keeps their registry.
/// @dev Factory code is fixed. Settings supplies authority. Market components share the pause gate.
/// Launch forwards the fee in the same call. The pinned sale holds sale funds.
/// Launch can call the launcher's Policy factory once before vault initialization and registration.
/// `launchBlock` prevents reentrancy. Only the token's factory can initialize the vault, once.
/// Initializing the vault during the callback reverts the launch. The returned Policy is unchecked
/// and sets only this Block's initial revenue destination.
/// @custom:security-contact security@blocks.fm
contract BlockFactory is IBlockFactory, Pausable, ReentrancyGuardTransient {
    using Clones for address;
    using PoolIdLibrary for PoolKey;

    struct InitParams {
        IPoolManager poolManager;
        address bux;
        address hook;
        address settings;
        address vaultImplementation;
        address escrowImplementation;
        address payoutImplementation;
        address saleImplementation;
        address jarFactory;
        uint256 launchFee; // Native-currency fee in wei; zero allows free launches.
    }

    /// @inheritdoc IBlockFactory
    uint256 public constant SUPPLY = 1_000_000_000e18; // Initial token base units (18 decimals).

    /// @inheritdoc IBlockFactory
    IPoolManager public immutable poolManager;
    /// @inheritdoc IBlockFactory
    address public immutable bux;
    /// @inheritdoc IBlockFactory
    address public immutable hook;
    /// @inheritdoc IBlockRegistry
    address public immutable settings;
    /// @notice Returns the fixed implementation for vault clones.
    /// @return Clone target address.
    address public immutable vaultImplementation;
    /// @notice Returns the fixed implementation for vesting escrow clones.
    /// @return Clone target address.
    address public immutable escrowImplementation;
    /// @inheritdoc IBlockFactory
    address public immutable payoutImplementation;
    /// @inheritdoc IBlockRegistry
    address public immutable jarFactory;
    /// @inheritdoc IBlockFactory
    address public immutable migrationRegistry;

    /// @inheritdoc IBlockFactory
    address public saleImplementation; // Applies only to newly created sale clones.
    /// @inheritdoc IBlockFactory
    uint256 public launchFee; // Native-currency base units (wei).

    mapping(address token => Launch) private _launches;
    mapping(address token => PoolKey) private _keys;
    /// @inheritdoc IBlockFactory
    mapping(address token => bool) public marketLive;
    /// @inheritdoc IBlockFactory
    mapping(address token => address) public canonicalHookOf;
    /// @inheritdoc IBlockFactory
    mapping(address token => address) public saleOf;
    uint256 private _launchCount;

    modifier onlySafe() {
        if (msg.sender != IProtocolSettings(settings).safe()) revert OnlySafe();
        _;
    }

    modifier onlyAdmin(address token) {
        if (_launches[token].token == address(0)) revert NotRegistered(token);
        if (msg.sender != _launches[token].admin) revert NotAdmin();
        _;
    }

    // Initialization

    /// @notice Binds the factory endpoints at deployment, before deploying the predicted hook.
    /// @dev The hook validates the wiring at deployment. Launches reject a hook without code.
    /// The Safe initially owns the migration registry.
    /// @param p Fixed endpoints, initial sale implementation and launch fee in wei.
    constructor(InitParams memory p) {
        if (
            p.hook == address(0) || p.vaultImplementation.code.length == 0
                || p.escrowImplementation.code.length == 0 || p.payoutImplementation.code.length == 0
                || p.saleImplementation.code.length == 0
                || IJarFactory(p.jarFactory).settings() != p.settings
        ) {
            revert InvalidConfiguration();
        }

        settings = p.settings;
        poolManager = p.poolManager;
        bux = p.bux;
        hook = p.hook;
        vaultImplementation = p.vaultImplementation;
        escrowImplementation = p.escrowImplementation;
        payoutImplementation = p.payoutImplementation;
        saleImplementation = p.saleImplementation;
        jarFactory = p.jarFactory;
        migrationRegistry = address(new HookMigrationRegistry(IProtocolSettings(p.settings).safe()));
        launchFee = p.launchFee;
    }

    // Launch

    /// @inheritdoc IBlockFactory
    function launchBlock(
        LaunchParams calldata p,
        IBlockBatchSale.Terms calldata terms_,
        address[] calldata recipients,
        uint16[] calldata weights
    ) external payable whenNotPaused nonReentrant returns (address token, address sale) {
        if (!p.isBlock || p.quote != bux) revert BlockMustBeQuotedInBux();
        IBlockBatchSale.Terms memory terms = terms_;
        address admin = p.admin == address(0) ? msg.sender : p.admin;
        if (terms.creator != address(0) && terms.creator != admin) revert InvalidConfiguration();

        terms.creator = admin;
        token = _prepare(p, recipients, weights);
        sale = LaunchSettlement.startSale(token, bux, saleImplementation, terms);
        saleOf[token] = sale;

        emit LaunchPrepared(
            token,
            sale,
            true,
            keccak256(
                abi.encode(
                    terms,
                    IBlockBatchSale(sale).feeBps(),
                    msg.sender,
                    BlockVault(_launches[token].vault).policy(),
                    BlockVault(_launches[token].vault).policy().codehash,
                    p.retained
                )
            )
        );
        emit SaleCreated(token, sale);
        Address.sendValue(payable(feePool()), msg.value);
    }

    /// @inheritdoc IBlockFactory
    function finalizeBlockSale(
        address token,
        uint256 marketTokens,
        uint256 proceeds,
        uint160 clearingPriceX96,
        uint256 creatorFill
    ) external nonReentrant {
        if (saleOf[token] != msg.sender) revert InvalidLaunchModule();
        if (marketLive[token]) revert MarketAlreadyLive();

        (PoolKey memory key, address escrow) = LaunchSettlement.settleSale(
            _launches[token],
            escrowImplementation,
            marketTokens,
            proceeds,
            clearingPriceX96,
            creatorFill
        );

        _launches[token].escrow = escrow;
        _recordFunded(token, key);
    }

    // Registry

    /// @inheritdoc IBlockFactory
    function setMetadata(address token, string calldata metadataURI) external onlyAdmin(token) {
        emit MetadataSet(token, metadataURI);
    }

    /// @inheritdoc IBlockFactory
    function setPayout(address token, address payout) external onlyAdmin(token) nonReentrant {
        payout = _checkPayout(payout);
        _launches[token].payout = payout;
        emit PayoutSet(token, payout);
    }

    /// @inheritdoc IBlockFactory
    function setPayees(address token, address[] calldata recipients, uint16[] calldata weights)
        external
        onlyAdmin(token)
        nonReentrant
    {
        address payout = _createPayout(token, recipients, weights);
        _launches[token].payout = payout;
        emit PayoutSet(token, payout);
    }

    /// @inheritdoc IBlockFactory
    function transferAdmin(address token, address newAdmin)
        external
        onlyAdmin(token)
        nonReentrant
    {
        if (newAdmin == address(0)) revert ZeroAddress();
        _launches[token].admin = newAdmin;
        emit AdminTransferred(token, newAdmin);
    }

    // Settings

    /// @inheritdoc IBlockFactory
    function setLaunchFee(uint256 launchFeeWei) external onlySafe {
        launchFee = launchFeeWei;
        emit LaunchFeeSet(launchFeeWei);
    }

    /// @inheritdoc IBlockFactory
    function setSaleImplementation(address implementation) external onlySafe {
        if (implementation.code.length == 0) revert InvalidConfiguration();
        saleImplementation = implementation;
        emit SaleImplementationSet(implementation);
    }

    /// @inheritdoc IBlockFactory
    function pause() external onlySafe {
        _pause();
    }

    /// @inheritdoc IBlockFactory
    function unpause() external onlySafe {
        _unpause();
    }

    // Migration

    /// @inheritdoc IBlockFactory
    function migrateLiquidity(address token, address destination)
        external
        onlyAdmin(token)
        nonReentrant
    {
        HookMigrationRegistry gate = HookMigrationRegistry(migrationRegistry);
        if (!marketLive[token]) revert InvalidConfiguration();
        address source = canonicalHookOf[token];
        if (!gate.isRegisteredUpgradePath(source, destination)) revert UpgradeNotRegistered();

        // The registry owner trusts the destination. The Block admin chooses when to migrate.
        // The hook transfers tracked liquidity and dust, leaving claims and vault backing in place.
        bytes memory snapshot = IBlockHook(source).exportLiquidity(token, destination);
        PoolKey memory key = _keys[token];
        (key.fee, key.tickSpacing) = IBlockHook(destination).importLiquidity(token, snapshot);
        key.hooks = IHooks(destination);
        Launch storage launchRecord = _launches[token];
        _keys[token] = key;
        launchRecord.poolId = PoolId.unwrap(key.toId());
        canonicalHookOf[token] = destination;
        emit CanonicalHookChanged(token, source, destination, launchRecord.poolId);
    }

    // Views

    /// @inheritdoc IBlockFactory
    function safe() public view returns (address) {
        return IProtocolSettings(settings).safe();
    }

    /// @inheritdoc IBlockFactory
    function feePool() public view returns (address) {
        return IProtocolSettings(settings).feePool();
    }

    /// @inheritdoc IBlockFactory
    function paused() public view override(IBlockFactory, Pausable) returns (bool) {
        return super.paused();
    }

    /// @inheritdoc IBlockFactory
    function requireMarketsActive() external view whenNotPaused { }

    /// @inheritdoc IBlockFactory
    function launches(address token) external view returns (Launch memory) {
        return _launches[token];
    }

    /// @inheritdoc IBlockFactory
    function poolKeyOf(address token) external view returns (PoolKey memory) {
        return _keys[token];
    }

    /// @inheritdoc IBlockRegistry
    function isRegistered(address token) external view returns (bool) {
        return _launches[token].token != address(0);
    }

    /// @inheritdoc IBlockRegistry
    function isBlock(address token) external view returns (bool) {
        return _launches[token].isBlock && marketLive[token];
    }

    /// @inheritdoc IBlockRegistry
    function isStakingBlock(address) external pure returns (bool) {
        return false;
    }

    /// @inheritdoc IBlockRegistry
    function vaultOf(address token) external view returns (address) {
        return _launches[token].vault;
    }

    /// @inheritdoc IBlockFactory
    function parentOf(address token) external view returns (address) {
        return _launches[token].parent;
    }

    /// @inheritdoc IBlockRegistry
    function payoutOf(address token) external view returns (address) {
        return _launches[token].payout;
    }

    /// @inheritdoc IBlockRegistry
    function adminOf(address token) external view returns (address) {
        return _launches[token].admin;
    }

    // Internal functions

    function _prepare(
        LaunchParams calldata params,
        address[] calldata recipients,
        uint16[] calldata weights
    ) private returns (address token) {
        // Jars resolve Blocks only through listed factories, which are never removed.
        if (!IProtocolSettings(settings).isBlockFactory(address(this))) {
            revert InvalidConfiguration();
        }
        if (hook.code.length == 0) revert HookNotDeployed();
        if (msg.value != launchFee) revert WrongLaunchFee();

        token = LaunchSettlement.createToken(params.name, params.symbol, ++_launchCount);
        address vault = vaultImplementation.clone();
        address policy;
        if (params.policyFactory != address(0)) {
            policy = IPolicyFactory(params.policyFactory).create(vault, params.policyFactoryData);
        }
        BlockVault(vault).initialize(token, bux, policy, params.retained);
        IJarFactory(jarFactory).create(block.chainid, token);
        address admin = params.admin == address(0) ? msg.sender : params.admin;
        _launches[token] = Launch({
            token: token,
            isBlock: true,
            parent: address(0),
            quote: params.quote,
            vault: vault,
            escrow: address(0),
            poolId: bytes32(0),
            admin: admin,
            payout: recipients.length == 0 && weights.length == 0
                ? _checkPayout(admin)
                : _createPayout(token, recipients, weights),
            appTag: params.appTag,
            launchedAt: 0
        });
        emit MetadataSet(token, params.metadataURI);
    }

    function _checkPayout(address payout) private pure returns (address) {
        // Low addresses are routing sentinels, not payees.
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

    function _recordFunded(address token, PoolKey memory key) private {
        Launch storage launchRecord = _launches[token];
        _keys[token] = key;
        launchRecord.poolId = PoolId.unwrap(key.toId());
        launchRecord.launchedAt = uint64(block.timestamp);
        canonicalHookOf[token] = hook;
        marketLive[token] = true;
        emit Launched(token, launchRecord.quote, launchRecord);
    }
}
