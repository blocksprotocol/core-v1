// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IRouterClient } from "@chainlink/contracts-ccip/interfaces/IRouterClient.sol";
import { Client } from "@chainlink/contracts-ccip/libraries/Client.sol";
import { ExtraArgsCodec } from "@chainlink/contracts-ccip/libraries/ExtraArgsCodec.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from
    "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IWETH9 } from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import { IBUX } from "../interfaces/IBUX.sol";
import { IBlockRegistry } from "../interfaces/IBlockRegistry.sol";
import { IBlockRevenueConfig } from "../interfaces/IBlockRevenueConfig.sol";
import { IBlockToken } from "../interfaces/IBlockToken.sol";
import { IBlockVault } from "../interfaces/IBlockVault.sol";
import { IJar } from "../interfaces/IJar.sol";
import { IProtocolSettings } from "../interfaces/IProtocolSettings.sol";

/// @title Jar
/// @notice Holds Block receipts as inventory or delivers them to the vault or Policy.
/// @dev Retained-asset delivery uses a self-call so a failed transfer or vault sync leaves a
/// retryable Policy row.
/// @custom:security-contact security@blocks.fm
contract Jar is IJar, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @inheritdoc IJar
    address public immutable factory;
    /// @notice Returns the protocol settings fixed when the implementation is deployed.
    /// @return Settings supplying routing, reserve and bridge configuration.
    IProtocolSettings public immutable settings;

    /// @inheritdoc IJar
    uint256 public homeChainId;
    /// @inheritdoc IJar
    address public token;
    bool private _initialized;
    /// @inheritdoc IJar
    mapping(address => uint256) public inventory;
    /// @inheritdoc IJar
    mapping(address => uint256) public homeBound;
    /// @inheritdoc IJar
    mapping(address asset => uint256) public policyClaimable;

    // Initialization

    /// @notice Binds the factory and settings once and locks implementation initialization.
    /// @dev The jar factory deploys the implementation and initializes each clone's identity once.
    /// @param factory_ Factory authorized to initialize clones.
    /// @param settings_ Protocol settings shared by this implementation's clones.
    constructor(address factory_, IProtocolSettings settings_) {
        factory = factory_;
        settings = settings_;
        _initialized = true;
    }

    /// @notice Accepts unattributed native surplus for anyone to sync.
    receive() external payable { }

    /// @inheritdoc IJar
    function initialize(uint256 homeChainId_, address token_) external {
        if (msg.sender != factory) revert OnlyFactory();
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        homeChainId = homeChainId_;
        token = token_;
    }

    // Receipts and sales

    /// @inheritdoc IJar
    function deposit(address asset, uint256 amount, address source) external payable nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (asset == address(0)) {
            if (msg.value != amount) revert InvalidValue();
        } else {
            if (msg.value != 0) revert InvalidValue();
            uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
            amount = IERC20(asset).balanceOf(address(this)) - beforeBalance;
            if (amount == 0) revert ZeroAmount();
        }

        emit BlockRevenue(homeChainId, token, asset, amount, source);
        _receive(asset, amount);
    }

    /// @inheritdoc IJar
    function sync(address asset) external nonReentrant {
        uint256 balance =
            asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this));
        uint256 reserved = accounted(asset);
        if (balance < reserved) revert BalanceShortfall();
        if (balance == reserved) revert ZeroAmount();

        uint256 received = balance - reserved;
        emit BlockRevenue(homeChainId, token, asset, received, address(0));
        _receive(asset, received);
    }

    /// @inheritdoc IJar
    function pushToVault(address asset, uint256 amount, address vault) external {
        if (msg.sender != address(this)) revert OnlySelf();
        IERC20(asset).safeTransfer(vault, amount);
        IBlockVault(vault).sync(asset);
    }

    /// @inheritdoc IJar
    /// @dev The Releaser sets the price. The jar requires exact, positive BUX payment before
    /// transferring inventory.
    function release(address asset, uint256 units, uint256 buxIn, address to)
        external
        nonReentrant
    {
        if (msg.sender != settings.releaser()) revert OnlyReleaser();
        if (buxIn == 0) revert ZeroAmount();
        if (units > inventory[asset]) revert InsufficientInventory();
        inventory[asset] -= units;
        IERC20 bux = IERC20(settings.bux());
        uint256 beforeBalance = bux.balanceOf(address(this));
        bux.safeTransferFrom(msg.sender, address(this), buxIn);
        if (bux.balanceOf(address(this)) - beforeBalance != buxIn) revert InsufficientBux();

        IERC20(asset).safeTransfer(to, units);
        _deliverBux(buxIn);
    }

    // Policy claims

    /// @inheritdoc IJar
    /// @dev Separate asset claims keep a failing token or recipient from blocking other rows.
    function claimPolicyAsset(address asset) external nonReentrant returns (uint256 amount) {
        amount = policyClaimable[asset];
        if (amount == 0) return 0;

        address blockFactory = settings.blockFactoryFor(token);
        if (blockFactory == address(0) || !IBlockRegistry(blockFactory).isBlock(token)) {
            revert BlockNotLive();
        }
        address vault = IBlockRegistry(blockFactory).vaultOf(token);
        address policy = IBlockRevenueConfig(vault).policy();
        bool toVault = policy == address(0);
        policyClaimable[asset] = 0;
        if (asset != settings.bux() && !_retained(asset, blockFactory)) {
            _receive(asset, amount);
            emit PolicyMovedToInventory(token, asset, amount);
            return amount;
        }
        IERC20(asset).safeTransfer(toVault ? vault : policy, amount);
        if (toVault && asset != settings.bux()) IBlockVault(vault).sync(asset);
        emit PolicyClaimed(token, policy, asset, amount);
    }

    // Bridge delivery

    /// @inheritdoc IJar
    function bridgeHome(uint256 amount) external payable nonReentrant returns (bytes32 messageId) {
        if (amount == 0) revert ZeroAmount();
        address bux = settings.bux();
        homeBound[bux] -= amount;
        IRouterClient router = IRouterClient(settings.bridgeRouter());
        IERC20(bux).forceApprove(address(router), amount);

        Client.EVMTokenAmount[] memory amounts = new Client.EVMTokenAmount[](1);
        amounts[0] = Client.EVMTokenAmount(bux, amount);
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(address(this)),
            data: "",
            tokenAmounts: amounts,
            feeToken: address(0),
            extraArgs: ExtraArgsCodec._getBasicEncodedExtraArgsV3(0, bytes4(0))
        });
        messageId =
            router.ccipSend{ value: msg.value }(settings.chainSelector(homeChainId), message);
        emit BridgedHome(amount, messageId);
    }

    // Views

    /// @inheritdoc IJar
    function accounted(address asset) public view returns (uint256) {
        return inventory[asset] + policyClaimable[asset] + homeBound[asset];
    }

    // Internal functions

    function _receive(address asset, uint256 amount) private {
        bool atHome = block.chainid == homeChainId;
        if (atHome && asset == token) {
            IBlockToken(asset).burn(amount);
            return;
        }
        if (asset == address(0)) {
            asset = settings.weth();
            IWETH9(asset).deposit{ value: amount }();
        }

        address bux = settings.bux();
        if (asset == address(IBUX(bux).underlying())) {
            IERC20(asset).forceApprove(bux, amount);
            amount = IBUX(bux).deposit(amount, address(this));
            asset = bux;
        }

        if (asset == bux) {
            _deliverBux(amount);
            return;
        }
        address blockFactory = atHome ? settings.blockFactoryFor(token) : address(0);
        if (!_retained(asset, blockFactory)) {
            inventory[asset] += amount;
            return;
        }
        address vault = _liveDirectVaultOrZero(blockFactory);
        if (vault == address(0)) {
            _accruePolicy(asset, amount);
            return;
        }
        // A failed vault delivery, including its work fee transfer, leaves a retryable Policy row.
        try this.pushToVault(asset, amount, vault) { }
        catch {
            _accruePolicy(asset, amount);
        }
    }

    // At home, the vault books direct BUX transfers on its next sync or redemption.
    // Other BUX receipts wait for a Policy claim or bridging.
    function _deliverBux(uint256 amount) private {
        address bux = settings.bux();
        if (block.chainid != homeChainId) {
            homeBound[bux] += amount;
            return;
        }
        address vault = _liveDirectVaultOrZero(settings.blockFactoryFor(token));
        if (vault == address(0)) _accruePolicy(bux, amount);
        else IERC20(bux).safeTransfer(vault, amount);
    }

    function _retained(address asset, address blockFactory) private view returns (bool) {
        if (blockFactory == address(0)) return false;
        address vault = IBlockRegistry(blockFactory).vaultOf(token);
        return IBlockRevenueConfig(vault).isRetained(asset);
    }

    // Returns zero for a nonzero Policy or a Block that is not live, including a canceled sale.
    function _liveDirectVaultOrZero(address blockFactory) private view returns (address) {
        if (blockFactory == address(0) || !IBlockRegistry(blockFactory).isBlock(token)) {
            return address(0);
        }
        address vault = IBlockRegistry(blockFactory).vaultOf(token);
        return IBlockRevenueConfig(vault).policy() == address(0) ? vault : address(0);
    }

    function _accruePolicy(address asset, uint256 amount) private {
        policyClaimable[asset] += amount;
        emit PolicyAccrued(token, asset, amount);
    }
}
