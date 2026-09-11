# Hydropump

Permissionless token launchpad contracts for [Hydrex](https://hydrex.fi) on Base.

Anyone can call `launch()` to deploy a fixed-supply ERC20, create its WETH pool on Hydrex, seed it with
single-sided liquidity, and lock the LP position forever. Trading fees are split 50/50 between the launch's fee
claimer and a savings balance earmarked for gauge bribes.

## Contracts

| Contract | Description |
| --- | --- |
| `HydropumpLaunchpad` | Entry point. Deploys the token, creates + initializes the pool, mints the position, and hands the LP NFT to a fresh locker. Keeps a queryable registry of every launch. |
| `HydropumpToken` | Fixed-supply ERC20 (burnable + permit) minted once in its constructor. |
| `HydropumpLocker` | One per launch. Permanently holds that launch's LP NFT, splits collected fees, places bribes from savings, and forwards incentive claims. |
| `libraries/HydropumpAddresses` | Base mainnet addresses (position manager, WETH, oHYDX) used across the protocol. |

### Launch mechanics

- **Supply**: 1,000,000,000 tokens, minted entirely to the launchpad and deposited as liquidity.
- **Pair**: WETH on Base.
- **Starting price**: ~0.000000010869565 WETH per token (≈ $25K FDV at 1B supply), tick ±183383.
- **Position**: single-sided, one tick spacing away from the initial tick, 105,972 ticks wide (60 tick spacing).
- **LP NFT**: transferred into a per-launch `HydropumpLocker` and never withdrawable — there is no burn or
  decrease-liquidity path on the locker.

### Fee flow

`collectFees()` (callable by the fee claimer or the locker owner) pulls fees off the position and splits them:

- 50% straight to the `feeClaimer` (rotatable by the fee claimer or owner)
- 50% into `savings`, spendable only via `placeBribe()` into the configured gauge bribe, or via the owner's
  `withdraw()`

`claimAndForward()` lets the fee claimer call arbitrary distributor contracts and forward the resulting balance
increase to themselves — restricted to tokens the owner has whitelisted (oHYDX is whitelisted by default).

## Development

```bash
npm install          # OpenZeppelin contracts
forge install        # forge-std
forge build
forge test
```

The fork test exercises a real launch against live Hydrex contracts and is skipped unless an RPC is set:

```bash
BASE_RPC_URL=https://mainnet.base.org forge test --match-path 'test/fork/*' -vv
```

## Deployment

Copy `.env.example` to `.env` and fill it in, then:

```bash
npm run deploy:launchpad:base    # deploys HydropumpLaunchpad, writes deployments/<network>-<address>.json
npm run launch:token:base        # calls launch() using TOKEN_NAME / TOKEN_SYMBOL / TOKEN_IMAGE / FEE_CLAIMER
```

`LAUNCHPAD_VAULT_OWNER` becomes the owner of every locker the launchpad deploys — set it to a multisig or
governance address. It can be rotated later with `setVaultOwner()` (affects new launches only; existing lockers
are rotated with their own `setOwner()`).

Tokens and lockers are created by the launchpad, so Basescan does not verify them automatically:

```bash
npm run verify:launch:base -- <TOKEN_ADDRESS> <LOCKER_ADDRESS>   # both at once
npm run verify:token:base  -- <TOKEN_ADDRESS>
npm run verify:locker:base -- <LOCKER_ADDRESS>
```

Constructor arguments are read back on-chain, so only the addresses are needed.
