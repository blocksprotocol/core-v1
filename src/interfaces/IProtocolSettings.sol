// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IProtocolSettings
/// @notice Defines per-chain settings controlled by the Safe.
/// @dev Only the Safe can change settings. Vaults apply the work fee when booking backing.
interface IProtocolSettings {
    /// @notice Emitted when the Safe selects the current inventory Releaser.
    /// @param releaser Selected Releaser contract.
    event ReleaserSet(address indexed releaser);

    /// @notice Emitted when the Safe sets the current or a lower work fee.
    /// @param feeBps Work fee in bps, with 10_000 bps = 100%.
    event WorkFeeSet(uint16 feeBps);

    /// @notice Emitted when the Safe sets the current or a lower ordinary Block swap fee.
    /// @param feeBps Ordinary swap fee in bps, with 10_000 bps = 100%.
    event BlockSwapFeeSet(uint16 feeBps);

    /// @notice Emitted when the Safe sets the current or a lower success fee for new sales.
    /// @param feeBps Success fee in bps, with 10_000 bps = 100%.
    event SaleSuccessFeeSet(uint16 feeBps);

    /// @notice Emitted when the Safe changes gross ordinary Block swap-fee shares.
    /// @param protocolBps Protocol share of the gross fee in bps.
    /// @param creatorBps Creator share of the gross fee in bps.
    /// @param blockBps Block share of the gross fee in bps; all shares total 10_000.
    event SwapSplitSet(uint16 protocolBps, uint16 creatorBps, uint16 blockBps);

    /// @notice Emitted when the Safe configures the fixed endpoints once.
    /// @param bux Fixed BUX asset.
    /// @param weth Fixed wrapped-native asset.
    /// @param feePool Fixed fee collection destination.
    event FixedEndpointsConfigured(address bux, address weth, address feePool);

    /// @notice Emitted when the Safe lists a Block factory.
    /// @param factory Listed factory.
    event BlockFactoryAdded(address indexed factory);

    /// @notice Emitted when the Safe selects the local CCIP sending router.
    /// @param router Router endpoint.
    event BridgeRouterSet(address indexed router);

    /// @notice Emitted when the Safe changes whether a factory's jars are admitted by the Releaser.
    /// @param factory Configured jar factory.
    /// @param trusted Whether its jars are admitted.
    event JarFactoryTrustSet(address indexed factory, bool trusted);

    /// @notice Emitted when the Safe changes a destination selector.
    /// @param chainId Destination chain ID.
    /// @param selector CCIP destination selector; zero leaves the destination unconfigured.
    event BridgeChainSet(uint256 indexed chainId, uint64 selector);

    /// @notice Emitted when the Safe pauses or resumes inventory processing for an asset.
    /// @param asset Inventory asset.
    /// @param paused Whether staging and selling are paused.
    event AssetReleasePauseSet(address indexed asset, bool paused);

    /// @notice Thrown when anyone attempts to renounce ownership.
    error FixedSafe();
    /// @notice Thrown when required code is absent, factory wiring is invalid or a required
    /// address is zero.
    error InvalidAddress();
    /// @notice Thrown when fixed endpoints are configured more than once.
    error EndpointIsFixed();
    /// @notice Thrown when a fee increases or Block swap shares exceed their cap or fail to total
    /// 10_000 bps.
    error InvalidRate();

    // Releaser configuration

    /// @notice Selects the current inventory Releaser immediately.
    /// @dev Only the Safe may call. It must choose a fresh deployment to avoid reviving aged lots.
    /// Checks for code only, not freshness.
    /// @param nextReleaser Releaser contract with code.
    function setReleaser(address nextReleaser) external;

    // Fee configuration

    /// @notice Sets the current or a lower work fee for newly booked backing.
    /// @dev Only the Safe may call.
    /// @param feeBps Work fee in bps; zero disables it.
    function setWorkFeeBps(uint16 feeBps) external;

    /// @notice Sets the current or a lower ordinary Block swap fee for newly prepared swaps.
    /// @dev Only the Safe may call. An increase reverts with `InvalidRate`.
    /// @param feeBps Ordinary swap fee in bps; zero disables it.
    function setBlockSwapFeeBps(uint16 feeBps) external;

    /// @notice Sets the current or a lower success fee for new sales.
    /// @dev Only the Safe may call. Existing sales retain their initialization snapshot.
    /// @param rate Success fee in bps; zero disables it.
    function setSaleSuccessFeeBps(uint16 rate) external;

    /// @notice Sets shares of the gross ordinary Block swap fee for later swaps.
    /// @dev Only the Safe may call. Shares total 10_000 bps.
    /// The protocol share cannot exceed 2,000 bps.
    /// @param protocolBps Protocol share of the gross fee in bps.
    /// @param creatorBps Creator share of the gross fee in bps.
    /// @param blockBps Block share of the gross fee in bps.
    function setSwapSplit(uint16 protocolBps, uint16 creatorBps, uint16 blockBps) external;

    // Endpoints

    /// @notice Configures BUX, wrapped native currency and FeePool once.
    /// @dev Only the Safe may call. Each endpoint must have code and cannot be changed afterward.
    /// @param bux_ BUX asset endpoint.
    /// @param weth_ Wrapped-native asset endpoint.
    /// @param feePool_ Fee collection endpoint.
    function configureFixedEndpoints(address bux_, address weth_, address feePool_) external;

    /// @notice Lists a Block factory after fixed endpoints are configured.
    /// @dev Only the Safe may call. The factory must have code and reference these settings.
    /// Listed factories cannot be removed.
    /// @param factory Factory to list.
    function addBlockFactory(address factory) external;

    // Bridge configuration

    /// @notice Sets the local CCIP router used by jars to send home-bound BUX.
    /// @dev Only the Safe may call.
    /// @param router Router contract with code.
    function setBridgeRouter(address router) external;

    /// @notice Sets whether a factory's jars are admitted by the local Releaser.
    /// @dev Only the Safe may call.
    /// @param factory Nonzero jar factory address.
    /// @param trusted Whether its jars are admitted.
    function setTrustedJarFactory(address factory, bool trusted) external;

    /// @notice Sets a destination chain's CCIP selector.
    /// @dev Only the Safe may call.
    /// @param chainId Destination chain ID.
    /// @param selector Destination selector. Zero leaves the destination unconfigured.
    function setBridgeChain(uint256 chainId, uint64 selector) external;

    // Pauses

    /// @notice Pauses or resumes staging and selling an inventory asset.
    /// @dev Only the Safe may call.
    /// @param asset Nonzero inventory asset.
    /// @param paused Whether staging and selling are paused.
    function setAssetReleasePaused(address asset, bool paused) external;

    // Ownership

    /// @notice Rejects ownership renunciation unconditionally.
    /// @dev Anyone may call. Always reverts with `FixedSafe`.
    function renounceOwnership() external pure;

    // Views

    /// @notice Returns the current Safe.
    /// @return Current Safe address.
    function safe() external view returns (address);

    /// @notice Returns shares of the gross ordinary Block swap fee.
    /// @return protocolBps Protocol share in bps, initially 2,000.
    /// @return creatorBps Creator share in bps, initially 1,000.
    /// @return blockBps Block share in bps, initially 7,000; all shares total 10_000.
    function swapSplit()
        external
        view
        returns (uint16 protocolBps, uint16 creatorBps, uint16 blockBps);

    /// @notice Returns the listed factory that registered a token.
    /// @dev Returns zero for tokens without code, reverting `factory()` calls, unlisted factories
    /// or unregistered tokens. Malformed return data can revert.
    /// A listed factory's reverting or malformed `isRegistered` response also propagates.
    /// @param token Token whose factory is resolved.
    /// @return Registered factory; zero if no listed factory confirms registration.
    function blockFactoryFor(address token) external view returns (address);

    /// @notice Returns the Coin protocol-share ceiling.
    /// @dev The Coin ceiling is 2,500 bps. The Block swap protocol-share cap is 2,000 bps.
    /// @return Coin protocol-share ceiling in bps.
    function MAX_PROTOCOL_SHARE_BPS() external view returns (uint16);

    /// @notice Returns the success fee snapshotted by new sales.
    /// @return Fee in bps, initially 100; zero disables it.
    function saleSuccessFeeBps() external view returns (uint16);

    /// @notice Returns the work fee on newly booked backing.
    /// @return Fee in bps, initially 100. Can only stay unchanged or decrease. Zero disables it.
    function workFeeBps() external view returns (uint16);

    /// @notice Returns the fixed BUX endpoint.
    /// @return BUX asset; zero before endpoint configuration.
    function bux() external view returns (address);

    /// @notice Returns the fixed wrapped-native endpoint.
    /// @return Wrapped-native asset; zero before endpoint configuration.
    function weth() external view returns (address);

    /// @notice Returns membership in the append-only Block factory list.
    /// @param factory Factory to check.
    /// @return Whether the factory is listed.
    function isBlockFactory(address factory) external view returns (bool);

    /// @notice Returns the fixed FeePool endpoint.
    /// @return Fee collection destination; zero before endpoint configuration.
    function feePool() external view returns (address);

    /// @notice Returns the current local CCIP sending router.
    /// @return Router endpoint; zero before configuration.
    function bridgeRouter() external view returns (address);

    /// @notice Returns whether a factory's jars are admitted by the Releaser.
    /// @param factory Jar factory to check.
    /// @return Whether the factory is trusted.
    function trustedJarFactory(address factory) external view returns (bool);

    /// @notice Returns the configured destination selector.
    /// @param chainId Destination chain ID.
    /// @return CCIP selector; zero means no destination is configured.
    function chainSelector(uint256 chainId) external view returns (uint64);

    /// @notice Returns whether staging and selling an inventory asset are paused.
    /// @param asset Inventory asset to check.
    /// @return Whether release processing is paused.
    function assetReleasePaused(address asset) external view returns (bool);

    /// @notice Returns the current inventory Releaser.
    /// @return Releaser address; zero until first configured.
    function releaser() external view returns (address);

    /// @notice Returns the ordinary Block swap fee.
    /// @dev Ordinary Coin swap fees remain fixed at 100 bps.
    /// @return Fee in bps, initially 100. Can only stay unchanged or decrease. Zero disables it.
    function blockSwapFeeBps() external view returns (uint16);
}
