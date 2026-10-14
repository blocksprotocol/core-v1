// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IBlockRegistry } from "./interfaces/IBlockRegistry.sol";
import { IBlockToken } from "./interfaces/IBlockToken.sol";
import { IProtocolSettings } from "./interfaces/IProtocolSettings.sol";

/// @title ProtocolSettings
/// @notice Holds per-chain settings controlled by the Safe, without custody of funds.
/// @dev The Safe controls mutable settings and transfers ownership in one step.
/// BUX, wrapped native currency and FeePool addresses are fixed after setup.
/// @custom:security-contact security@blocks.fm
contract ProtocolSettings is IProtocolSettings, Ownable {
    // Coin protocol-share ceiling in bps.
    /// @inheritdoc IProtocolSettings
    uint16 public constant override MAX_PROTOCOL_SHARE_BPS = 2_500;

    /// @inheritdoc IProtocolSettings
    uint16 public saleSuccessFeeBps = 100;
    /// @inheritdoc IProtocolSettings
    uint16 public override workFeeBps = 100;
    /// @inheritdoc IProtocolSettings
    address public bux;
    /// @inheritdoc IProtocolSettings
    address public weth;
    /// @inheritdoc IProtocolSettings
    mapping(address => bool) public override isBlockFactory;
    /// @inheritdoc IProtocolSettings
    address public feePool;
    /// @inheritdoc IProtocolSettings
    address public override bridgeRouter;
    /// @inheritdoc IProtocolSettings
    mapping(address => bool) public override trustedJarFactory;
    /// @inheritdoc IProtocolSettings
    mapping(uint256 => uint64) public chainSelector;
    /// @inheritdoc IProtocolSettings
    mapping(address => bool) public override assetReleasePaused;
    uint16 private _swapProtocolBps = 2_000; // Initial 20% of the gross ordinary Block swap fee.
    uint16 private _swapCreatorBps = 1_000; // Initial 10%; the Block receives the remaining 70%.
    /// @inheritdoc IProtocolSettings
    address public override releaser;
    /// @inheritdoc IProtocolSettings
    uint16 public override blockSwapFeeBps = 100;

    // Initialization

    /// @notice Binds the Safe once at deployment.
    /// @param safe_ Nonzero initial Safe.
    constructor(address safe_) Ownable(safe_) { }

    // Releaser configuration

    /// @inheritdoc IProtocolSettings
    function setReleaser(address nextReleaser) external override onlyOwner {
        if (nextReleaser.code.length == 0) revert InvalidAddress();
        releaser = nextReleaser;
        emit ReleaserSet(nextReleaser);
    }

    // Fee configuration

    /// @inheritdoc IProtocolSettings
    function setWorkFeeBps(uint16 feeBps) external override onlyOwner {
        if (feeBps > workFeeBps) revert InvalidRate();
        workFeeBps = feeBps;
        emit WorkFeeSet(feeBps);
    }

    /// @inheritdoc IProtocolSettings
    function setBlockSwapFeeBps(uint16 feeBps) external override onlyOwner {
        if (feeBps > blockSwapFeeBps) revert InvalidRate();
        blockSwapFeeBps = feeBps;
        emit BlockSwapFeeSet(feeBps);
    }

    /// @inheritdoc IProtocolSettings
    function setSaleSuccessFeeBps(uint16 rate) external onlyOwner {
        if (rate > saleSuccessFeeBps) revert InvalidRate();
        saleSuccessFeeBps = rate;
        emit SaleSuccessFeeSet(rate);
    }

    /// @inheritdoc IProtocolSettings
    function setSwapSplit(uint16 protocolBps, uint16 creatorBps, uint16 blockBps)
        external
        override
        onlyOwner
    {
        if (protocolBps > 2_000 || uint256(protocolBps) + creatorBps + blockBps != 10_000) {
            revert InvalidRate();
        }
        _swapProtocolBps = protocolBps;
        _swapCreatorBps = creatorBps;
        emit SwapSplitSet(protocolBps, creatorBps, blockBps);
    }

    // Endpoints

    /// @inheritdoc IProtocolSettings
    function configureFixedEndpoints(address bux_, address weth_, address feePool_)
        external
        onlyOwner
    {
        // Fixed endpoints preserve BUX identity and prevent a replacement wrapper from keeping
        // native receipts. Routing fees back to a vault would leave them there, unbooked.
        if (bux != address(0)) revert EndpointIsFixed();
        if (bux_.code.length == 0 || weth_.code.length == 0 || feePool_.code.length == 0) {
            revert InvalidAddress();
        }
        bux = bux_;
        weth = weth_;
        feePool = feePool_;
        emit FixedEndpointsConfigured(bux_, weth_, feePool_);
    }

    /// @inheritdoc IProtocolSettings
    function addBlockFactory(address factory) external override onlyOwner {
        // FeePool must exist before any Block can pay a work fee.
        if (
            feePool == address(0) || factory.code.length == 0
                || IBlockRegistry(factory).settings() != address(this)
        ) {
            revert InvalidAddress();
        }
        isBlockFactory[factory] = true;
        emit BlockFactoryAdded(factory);
    }

    // Bridge configuration

    /// @inheritdoc IProtocolSettings
    function setBridgeRouter(address router) external override onlyOwner {
        if (router.code.length == 0) revert InvalidAddress();
        bridgeRouter = router;
        emit BridgeRouterSet(router);
    }

    /// @inheritdoc IProtocolSettings
    function setTrustedJarFactory(address factory, bool trusted) external override onlyOwner {
        if (factory == address(0)) revert InvalidAddress();
        trustedJarFactory[factory] = trusted;
        emit JarFactoryTrustSet(factory, trusted);
    }

    /// @inheritdoc IProtocolSettings
    function setBridgeChain(uint256 chainId, uint64 selector) external override onlyOwner {
        chainSelector[chainId] = selector;
        emit BridgeChainSet(chainId, selector);
    }

    // Pauses

    /// @inheritdoc IProtocolSettings
    function setAssetReleasePaused(address asset, bool paused) external override onlyOwner {
        if (asset == address(0)) revert InvalidAddress();
        assetReleasePaused[asset] = paused;
        emit AssetReleasePauseSet(asset, paused);
    }

    // Ownership

    /// @inheritdoc IProtocolSettings
    function renounceOwnership() public pure override(Ownable, IProtocolSettings) {
        revert FixedSafe();
    }

    // Views

    /// @inheritdoc IProtocolSettings
    function safe() external view override returns (address) {
        return owner();
    }

    /// @inheritdoc IProtocolSettings
    function swapSplit() external view override returns (uint16, uint16, uint16) {
        return (_swapProtocolBps, _swapCreatorBps, 10_000 - _swapProtocolBps - _swapCreatorBps);
    }

    /// @inheritdoc IProtocolSettings
    function blockFactoryFor(address token) external view override returns (address) {
        // An address without code returns empty data, which fails decoding outside the catch.
        if (token.code.length == 0) return address(0);
        // Any contract can name a listed factory. The factory must confirm registration.
        try IBlockToken(token).factory() returns (address tokenFactory) {
            if (isBlockFactory[tokenFactory] && IBlockRegistry(tokenFactory).isRegistered(token)) {
                return tokenFactory;
            }
        } catch { }
        return address(0);
    }
}
