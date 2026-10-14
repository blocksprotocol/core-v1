# blocks

Smart contracts for blocks, the protocol for creator economies.

[Docs](https://docs.blocks.fm) · [Website](https://blocks.fm) · [X](https://x.com/blocksfm)

A Block is a token with a vault behind it. Its revenue, from trading fees, subscriptions, apps or anything else, flows into the Block's Jar and then into its vault. Holders can redeem tokens for their share of the vault at any time, with no fee and no pause.

## How it works

```
  trading fees, subscriptions, games, apps
                     |
                     v
                    Jar           one address per Block, on every chain
                     |
                     v
              Policy (optional)   decides what happens to new revenue
                     |
                     v
                   Vault          holds the backing, pays redemptions
```

- **Block**: a token, its Uniswap v4 market and its vault. A Block launches its own token through a batch sale. A Staking Block wraps a token that already exists.
- **BUX**: the protocol's dollar. 1 BUX is minted for 1 USDG and redeemed for 1 USDG, with no fee.
- **Jar**: collects a Block's revenue in any token. It sends BUX to the vault and sells other tokens for BUX in a falling-price auction.
- **Vault**: holds the Block's backing. It pays the protocol a 1% work fee on new backing. Backing divided by token supply is the floor. Backing leaves the vault only when holders redeem.
- **Policy**: an optional contract that decides what a Block does with new revenue. If no Policy is set, all new revenue goes to the vault. A change takes 7 days' notice.
- **Coin**: a token launched under a Block. Part of every Coin trade's fee goes to the parent Block.
- **Safe**: the multisig that runs the protocol. See [Governance](#governance).

[Blocks 101](https://docs.blocks.fm/blocks-101) follows the money end to end.

## Uniswap v4 hooks

The protocol uses three hooks. Each one is immutable and deployed at an address that encodes its permissions, as Uniswap v4 requires. A market moves to a newer hook by migration, never by upgrade.

| Hook | Pools | Permissions |
| --- | --- | --- |
| [`BlockHook`](src/market/BlockHook.sol) | Block markets, quoted in BUX | `beforeInitialize`, `beforeAddLiquidity`, `beforeSwap`, `afterSwap`, `beforeDonate`, `afterDonate`, `beforeSwapReturnDelta`, `afterSwapReturnDelta` |
| [`CoinHook`](src/periphery/CoinHook.sol) | Coin markets, quoted in any ERC-20 | Same as `BlockHook` |
| [`BuxWrapperHook`](src/bux/BuxWrapperHook.sol) | One USDG/BUX pool | `beforeInitialize`, `beforeAddLiquidity`, `beforeSwap`, `beforeSwapReturnDelta` |

`BlockHook` and `CoinHook` share [`BaseMarketHook`](src/market/BaseMarketHook.sol):

- Only the protocol's factory can create a pool on the hook.
- Every swap pays a fee on the quote side, 1% today. The pool's LP fee is zero.
- The hook takes the fee in `beforeSwap` when the quote amount is specified, and in `afterSwap` when it is not.
- The hook mints its fees to itself as ERC-6909 claims and burns them when it pays out.
- A swap must fill in full. A partial fill reverts.
- Block markets accept outside liquidity. Coin markets do not. The hooks never block removing liquidity.
- Swaps and donations revert while markets are paused.
- `hookData` can carry a 32-byte app ID for attribution. It is not authenticated and does not change the price.
- A Block's or Coin's admin can move its market to a newer hook, but only along a path the Safe has approved in the factory's [`HookMigrationRegistry`](src/HookMigrationRegistry.sol).

Where each fee goes, at today's settings:

- **Block markets**: 20% to the protocol, 10% to the creator and 70% to the Block. The Block's share is paid to its vault on the next swap, or held until its Policy claims it.
- **Coin markets**: 20% to the protocol. The Coin's creator chooses a share of the rest, and what remains goes to the parent Block's Jar. Anyone can call `sweepVault` to pay out the protocol and Block shares. If a Coin is quoted in its parent's token, the whole fee goes to the parent's Jar.
- **Coin launches**: for the first 30 seconds, buys pay a tax that falls in a straight line from 90% to zero, and all buys together are capped at 0.5% of supply per second. The tax goes to the parent Block's Jar. The creator's launch purchase, which the hook executes itself, is exempt.

`BuxWrapperHook` swaps USDG and BUX 1:1 with no fee. It mints or redeems BUX inside `beforeSwap`, so the pool holds no liquidity and adding liquidity reverts. The pool must have a zero fee, tick spacing 1 and a 1:1 starting price. The hook takes the input token from the PoolManager during the swap, so a router that settles after swapping needs the PoolManager to hold enough of that token already.

## Contracts

```
src/
├── BlockFactory.sol              Launches Blocks and keeps their registry
├── BlockBatchSale.sol            Sale clone: BUX commitments, one clearing price, refunds
├── BlockToken.sol                ERC-20 with permit and burn, 1 billion minted once
├── BlockVault.sol                Vault clone: holds backing, pays redemptions
├── VestingEscrow.sol             Releases a creator's locked tokens over time
├── CreatorPayout.sol             Fixed-weight payout splits, also used by Forwarders
├── FeePool.sol                   Collects protocol fees for two Safe-set recipients
├── ProtocolSettings.sol          Per-chain settings held by the Safe
├── HookMigrationRegistry.sol     Safe-approved paths to move a market to a newer hook
├── bux/
│   ├── BUX.sol                   The protocol dollar, 1:1 with USDG
│   ├── BUXSignatures.sol         Permit and EIP-3009 transfers for BUX
│   ├── BuxWrapperHook.sol        Uniswap v4 hook: USDG and BUX at par
│   └── ERC4626Adapter.sol        Optional yield adapter for the BUX reserve
├── jar/
│   ├── Jar.sol                   Collects a Block's revenue on each chain
│   ├── JarFactory.sol            Creates Jars at the same address on every chain
│   └── Releaser.sol              Sells Jar inventory for BUX at a falling price
├── market/
│   ├── BaseMarketHook.sol        Swap, fee and liquidity logic shared by both market hooks
│   ├── BlockHook.sol             Uniswap v4 hook for Block markets
│   └── MarketLiquidity.sol       Seeds and migrates hook-owned liquidity
├── periphery/
│   ├── CoinFactory.sol           Launches Coins under a parent Block
│   ├── CoinHook.sol              Uniswap v4 hook for Coin markets
│   ├── ForwarderFactory.sol      Creates Forwarders that split revenue between a Jar and payees
│   ├── BlockLens.sol             Reads a Block's kind, Jar and redemption address
│   ├── BuybackConfig.sol         Shared auction factory for Policies
│   ├── JarSweeper.sol            Buys many Jar lots in one call
│   └── PolicySweeper.sol         Claims everything waiting for a Block's Policy in one call
├── policies/
│   ├── StandardPolicy.sol        Example Policy that forwards revenue to the vault
│   ├── ReservePolicy.sol         Reference Policy that buys a reserve asset for the vault
│   └── ReservePolicyFactory.sol  Creates Reserve Policies
├── staking/
│   ├── StakingFactory.sol        Launches Staking Blocks
│   ├── StakingVault.sol          The bToken: an ERC-4626 wrapper that shares revenue
│   ├── StakingBlockConfig.sol    Fixed revenue routing for a Staking Block
│   └── BuybackPolicy.sol         Turns a Staking Block's BUX into the wrapped token
├── libraries/
│   ├── CoinLiquidity.sol         Seeds Coin liquidity and sweeps Coin fees
│   ├── FeeSplit.sol              Splits Coin swap fees
│   ├── FloorMath.sol             Converts between token prices and pool prices
│   ├── LaunchSettlement.sol      Settles a sale and opens the Block's market
│   └── SwapChargeMath.sol        Swap fee and launch tax maths
├── token/
│   └── ERC20PermitSignatures.sol Permit checks for wallets and smart accounts
└── interfaces/                   Interfaces
```

## Governance

A Safe multisig runs the protocol, at the same address on every chain. What it can and cannot do is enforced in code:

- It can lower the work fee, the Block swap fee and the sale fee, but never raise them.
- It can change the Block swap split, with the protocol's share capped at 20%. It can set the protocol's share of Coin fees up to 25%.
- It can pause new launches and trading, but never redemption.
- It cannot move money out of a vault. It cannot choose a Block's Policy, only switch one off.
- It owns BUX and can move the USDG reserve behind it. This is the main trust assumption.

[Governance and safety](https://docs.blocks.fm/trust/governance-and-safety) lists every power.

## Build

The contracts use Solidity 0.8.37 and [Foundry](https://getfoundry.sh). Install the dependencies:

```sh
git init
forge install \
  Uniswap/v4-core@v4.0.0 \
  Uniswap/v4-periphery@dce236d4e2057422d0791d9a973a58765eb46f65 \
  OpenZeppelin/openzeppelin-contracts@v5.6.1 \
  OpenZeppelin/uniswap-hooks@v1.1.0-rc.1 \
  smartcontractkit/chainlink-ccip@contracts-ccip-v2.0.0 \
  smartcontractkit/chainlink-evm@contracts-v1.5.0 \
  Vectorized/solady@v0.1.26
```

Add a `foundry.toml`:

```toml
[profile.default]
solc = "0.8.37"
evm_version = "cancun"
optimizer = true
optimizer_runs = 200
via_ir = true
auto_detect_remappings = false
remappings = [
  "@uniswap/v4-core/=lib/v4-core/",
  "@uniswap/v4-periphery/=lib/v4-periphery/",
  "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/",
  "@openzeppelin/uniswap-hooks/=lib/uniswap-hooks/",
  "@chainlink/contracts-ccip/=lib/chainlink-ccip/chains/evm/contracts/",
  "@chainlink/contracts/=lib/chainlink-evm/contracts/",
  "solady/=lib/solady/src/",
  "lib/uniswap-hooks/:v4-core/=lib/v4-core/",
  "lib/uniswap-hooks/:openzeppelin/=lib/openzeppelin-contracts/contracts/",
]
```

Then build:

```sh
forge build
```

## Deployments

Robinhood Chain (chain ID 4663) is the first home chain. Addresses will be listed on the [contracts page](https://docs.blocks.fm/reference/contracts) of the docs as each contract goes live.

## Security

Please report vulnerabilities to [security@blocks.fm](mailto:security@blocks.fm). Do not open a public issue.

Audit reports will be published in the [docs](https://docs.blocks.fm) as they are completed.

## Licence

Most files are licensed under MIT. Six files are licensed under AGPL-3.0-only, and two under Apache-2.0 AND MIT. Each file states its licence in its SPDX header.
