// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { CurrencySettler } from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { TransientStateLibrary } from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import { ICoinFactory } from "../interfaces/ICoinFactory.sol";
import { ICoinHook } from "../interfaces/ICoinHook.sol";
import { IJar } from "../interfaces/IJar.sol";
import { IProtocolSettings } from "../interfaces/IProtocolSettings.sol";

import { MarketLiquidity } from "../market/MarketLiquidity.sol";
import { FeeSplit } from "./FeeSplit.sol";

/// @title CoinLiquidity
/// @notice Seeds Coin liquidity and sends deferred fees to the protocol and parent jars.
/// @dev Linked calls use the hook's storage and funds during its PoolManager unlock.
library CoinLiquidity {
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;

    /// @notice Thrown when the Coin inventory already has tracked positions.
    error AlreadySeeded();

    /// @notice Thrown when the hook has a prior currency delta, a range rounds to zero liquidity
    /// or funding leaves a credit.
    error InvalidLiquidity();

    // Liquidity operations

    /// @notice Seeds discovery and depth ranges from supplied token inventory.
    /// @dev Discovery spans opening to bonding. Depth extends from bonding to the far usable tick.
    /// Both ranges start with tokens only. Discovery gets 80%, rounded down in token base units.
    /// Depth receives the remainder. The caller must initialize the pool at its opening tick and
    /// provide funds during its PoolManager unlock. Affordable liquidity rounds down.
    /// Required token funding rounds up in PoolManager's favor. Unused funds remain tracked dust.
    /// @param self Calling hook's empty tracked Coin inventory.
    /// @param manager PoolManager holding the pool.
    /// @param key Initialized Coin pool.
    /// @param tokenIs0 Whether the Coin token is currency0.
    /// @param opening Discovery's opening tick.
    /// @param bonding Tick separating discovery and depth.
    /// @param tokens Supplied token base units.
    function seed(
        MarketLiquidity.Inventory storage self,
        IPoolManager manager,
        PoolKey memory key,
        bool tokenIs0,
        int24 opening,
        int24 bonding,
        uint256 tokens
    ) public {
        _requireNoPriorDelta(manager, key);
        if (self.positions.length != 0) revert AlreadySeeded();
        uint256 discovery = tokens * 80 / 100;
        int24 far = tokenIs0
            ? TickMath.maxUsableTick(key.tickSpacing)
            : TickMath.minUsableTick(key.tickSpacing);
        if (tokenIs0) {
            _mint(self, manager, key, opening, bonding, discovery, true, keccak256("discovery"));
            _mint(self, manager, key, bonding, far, tokens - discovery, true, keccak256("depth"));
        } else {
            _mint(self, manager, key, bonding, opening, discovery, false, keccak256("discovery"));
            _mint(self, manager, key, far, bonding, tokens - discovery, false, keccak256("depth"));
        }
        Currency tokenCurrency = tokenIs0 ? key.currency0 : key.currency1;
        MarketLiquidity.deposit(manager, tokenCurrency, tokens);
        int256 delta = manager.currencyDelta(address(this), tokenCurrency);
        if (delta > 0) revert InvalidLiquidity();
        self.dust = tokens - uint256(-delta);
        CurrencySettler.settle(tokenCurrency, manager, address(this), uint256(-delta), true);
    }

    // Claims

    /// @notice Redeems quote claims to pay the protocol and deposit the Block share into its jar.
    /// @dev Runs during the hook's PoolManager unlock. Delivery is in kind. Only the Block share
    /// enters the jar. Creator accruals remain separate.
    /// @param pending Hook's pending quote base units, keyed by reserved protocol and Block rows.
    /// @param manager PoolManager holding the hook's quote claims.
    /// @param factory Coin factory supplying the parent jar, source and protocol settings.
    /// @param token Coin token whose fee balances are redeemed.
    /// @param asset Coin's quote token.
    /// @return amount Total redeemed quote base units. Zero when neither allocation has accrued.
    function sweep(
        mapping(address => uint256) storage pending,
        IPoolManager manager,
        ICoinFactory factory,
        address token,
        address asset
    ) public returns (uint256 amount) {
        uint256 protocol = pending[FeeSplit.PROTOCOL_ROW];
        uint256 blockAmount = pending[FeeSplit.BLOCK_ROW];
        amount = protocol + blockAmount;
        if (amount == 0) return 0;
        pending[FeeSplit.PROTOCOL_ROW] = 0;
        pending[FeeSplit.BLOCK_ROW] = 0;
        manager.burn(address(this), Currency.wrap(asset).toId(), amount);
        manager.take(Currency.wrap(asset), address(this), amount);
        address jar = factory.jarOf(token);
        address source = factory.sourceOf(token);
        IProtocolSettings settings = IProtocolSettings(factory.blockFactory().settings());
        if (protocol != 0) {
            address feePool = settings.feePool();
            IERC20(asset).safeTransfer(feePool, protocol);
            emit ICoinHook.ProtocolFeeSwept(token, asset, feePool, protocol);
        }
        if (blockAmount != 0) {
            IERC20(asset).forceApprove(jar, blockAmount);
            IJar(jar).deposit(asset, blockAmount, source);
            emit ICoinHook.BlockFeeSwept(token, asset, jar, blockAmount);
        }
    }

    // Internal functions

    // Anyone can credit the hook through `PoolManager.settleFor` during an unlock.
    // Require zero currency deltas so that credit cannot fund seeding or inflate inventory.
    function _requireNoPriorDelta(IPoolManager manager, PoolKey memory key) private view {
        if (
            manager.currencyDelta(address(this), key.currency0) != 0
                || manager.currencyDelta(address(this), key.currency1) != 0
        ) revert InvalidLiquidity();
    }

    function _mint(
        MarketLiquidity.Inventory storage self,
        IPoolManager manager,
        PoolKey memory key,
        int24 lower,
        int24 upper,
        uint256 amount,
        bool tokenIs0,
        bytes32 salt
    ) private {
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(upper);
        uint128 liquidity = tokenIs0
            ? LiquidityAmounts.getLiquidityForAmount0(sqrtLowerX96, sqrtUpperX96, amount)
            : LiquidityAmounts.getLiquidityForAmount1(sqrtLowerX96, sqrtUpperX96, amount);
        if (liquidity == 0) revert InvalidLiquidity();
        manager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: salt
            }),
            ""
        );
        self.positions.push(MarketLiquidity.Position(lower, upper, salt, liquidity));
    }
}
