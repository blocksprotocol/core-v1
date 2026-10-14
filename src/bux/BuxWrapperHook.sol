// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { BaseHook } from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import { CurrencySettler } from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { BeforeSwapDelta, toBeforeSwapDelta } from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { IBUX } from "../interfaces/IBUX.sol";

/// @title BuxWrapperHook
/// @notice Wraps and unwraps BUX at par without fees or liquidity positions.
/// @dev Swaps require BUX's reported conversion amount to equal the specified token base units.
/// Redemption reports the nominal transfer, not the received amount. Transfers must preserve par
/// so each swap funds its own output. Swaps mint no ERC-6909 claims.
/// Routers that swap before settling need input currency in PoolManager from pool balances
/// or ERC-6909 claim deposits.
/// @custom:security-contact security@blocks.fm
contract BuxWrapperHook is BaseHook {
    using CurrencySettler for Currency;
    using SafeERC20 for IERC20;

    /// @notice Returns the BUX reserve used for swap conversion.
    /// @return BUX contract fixed at deployment.
    IBUX public immutable bux;
    /// @notice Returns the underlying token paired with BUX.
    /// @return Initialized reserve underlying, fixed at hook deployment.
    IERC20 public immutable underlying;

    /// @notice Thrown when liquidity is added to the wrapping pool.
    error NoLiquidity();
    /// @notice Thrown when the reported conversion amount differs from the specified swap amount.
    error NotAtPar();

    // Initialization

    /// @notice Binds PoolManager and an initialized BUX reserve once at deployment.
    /// @param manager PoolManager authorized to invoke hook callbacks.
    /// @param bux_ BUX reserve with a nonzero underlying token.
    constructor(IPoolManager manager, IBUX bux_) BaseHook(manager) {
        bux = bux_;
        underlying = bux_.underlying();
        if (address(underlying) == address(0)) revert InvalidPool();
        // An unlimited allowance lets BUX pull each swap's underlying input.
        underlying.forceApprove(address(bux_), type(uint256).max);
    }

    // Views

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeAddLiquidity = true;
        p.beforeSwap = true;
        p.beforeSwapReturnDelta = true;
    }

    // Internal functions

    function _beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        view
        override
        returns (bytes4)
    {
        address first = address(bux) < address(underlying) ? address(bux) : address(underlying);
        address second = address(bux) < address(underlying) ? address(underlying) : address(bux);
        // A 1:1 price in token base units has square-root price `1 << 96` in Q64.96.
        if (
            Currency.unwrap(key.currency0) != first || Currency.unwrap(key.currency1) != second
                || key.fee != 0 || key.tickSpacing != 1 || sqrtPriceX96 != 1 << 96
        ) revert InvalidPool();
        return this.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal pure override returns (bytes4) {
        revert NoLiquidity();
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 amount = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);
        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        Currency output = params.zeroForOne ? key.currency1 : key.currency0;
        poolManager.take(input, address(this), amount);
        uint256 received = Currency.unwrap(input) == address(underlying)
            ? bux.deposit(amount, address(this))
            : bux.redeem(amount, address(this));
        if (received != amount) revert NotAtPar();
        output.settle(poolManager, address(this), amount, false);
        // `PoolManager.take` bounds the amount to a positive `int128`, preventing truncation.
        return (
            this.beforeSwap.selector,
            toBeforeSwapDelta(int128(-params.amountSpecified), int128(params.amountSpecified)),
            0
        );
    }
}
