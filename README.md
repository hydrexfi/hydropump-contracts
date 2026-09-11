# Hydropump

Permissionless token launch contracts for [Hydrex](https://hydrex.fi) on Base.

`launch()` deploys a fixed-supply ERC20, opens its pool against a whitelisted quote token, seeds it with
five single-sided liquidity bands, and locks every position forever. Trading fees split 0.8% to the
creator and 0.3% to the protocol, which buys HYDX and bribes it into the Hydropump gauge.

## Contracts

| Contract             | Upgradeable |                                                                                |
| -------------------- | ----------- | ------------------------------------------------------------------------------ |
| `HydropumpLauncher`  | UUPS        | Deploys the token, creates the pool, mints the bands, hands them to the locker |
| `HydropumpToken`     | no          | Plain immutable ERC20 — burnable, permit, no owner, no mint path, not a proxy  |
| `HydropumpLocker`    | UUPS        | Holds every launch's positions permanently, splits and pays out fees           |
| `HydropumpBuyback`   | no          | Quote → HYDX, then bribes the Hydropump gauge                                  |
| `HydropumpEmissions` | no          | Splits gauge emissions across an operator-set recipient list                   |

## How a launch works

- **Supply** 10,000,000,000, all of it deployed as liquidity. Nothing is held back.
- **Bands** five, at tick offsets `0 / 14k / 36k / 62k / 92k / 887.2k` from the start tick, holding
  `9 / 22 / 30 / 37 / 2%` of supply. Offsets, not absolute ticks, so the curve is quote-agnostic.
  Bands are aligned to the pool's actual tick spacing at launch time.
- **Start tick** per quote token, in launcher storage, refreshed as the quote's USD price moves. No oracle.
  `node script/quotes/build-quote-tokens.mjs` derives ticks for every eligible asset from the live Hydrex list.
- **token0** the launch token is always token0. The frontend mines `userSalt` until the CREATE2 address
  sorts below the quote token — a few attempts against WETH. Use `predictToken` and `isSaltValid`.
  A salt is bound to the sender, so a mempool watcher cannot burn it.
- **Locked** positions go straight to the locker, which exposes no transfer, withdraw, burn, or
  decrease-liquidity path.
- **Dev buy** set `buyAmount` to spend that much quote token buying the launch token in the same
  transaction, sent to the caller. `0` skips it. Approve the launcher for the quote token first.

Launch pools are deliberately **not gauged**. A gauged Hydrex CL pool runs at `communityFee 1000/1000`,
sending 100% of swap fees to the community vault and leaving the locked positions earning nothing.
veHYDX voters are paid from the single Hydropump gauge instead.

## Fees

`collect(token, positionMask)` is permissionless — the keeper runs it, a creator can expedite it. Bit `i`
of the mask selects band `i`; `fullMask(token)` is all of them. The keeper `eth_call`s it with the full
mask to read per-band amounts, then sends a transaction covering only the bands worth the gas.

The creator's 0.8% accrues as a claimable balance (paid by `claim`); the protocol's 0.3% leaves for the
buyback immediately.

For a frontend: `claimable(token)` is a plain view returning what is credited and claimable right now for
both assets, and `claimableMany(tokens[])` does a creator's whole portfolio in one call. `totalOwed(token)`
adds fees still sitting uncollected in the positions — it is not a view, because uncollected fees are only
knowable by asking the position manager, so `eth_call` it; sent as a transaction it is just a full collect. The split is stored, not hardcoded — `setFeeSplit` takes the two shares
and only their ratio matters, so 8000/3000 and 800/300 are the same thing. Changes apply to fees collected
from then on; balances already credited are untouched.

The buyback converts what it receives into HYDX along routes built off-chain and passed as calldata to the
Hydrex multi router, then `bribe()` deposits the HYDX into the Hydropump gauge. Routes are not restricted to
one hop — a cycle converts many different assets at once and most of them want a multi-hop path. The job is
operator-gated; output is verified as a HYDX balance delta, so a route that sends its output anywhere else
fails its own `minHydxOut` bound. `bribe()` stays permissionless so HYDX cannot be stranded.

## Develop

```bash
npm install && forge install
forge build
forge test
BASE_RPC_URL=https://mainnet.base.org forge test --match-path 'test/fork/*' -vv   # full launch on a fork
npm run fmt
```

## Deploy

Copy `.env.example` to `.env`, then:

```bash
npm run deploy:base
```

Two identities, nothing else to configure:

|                   | Role                                                                                                                                                                 |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DEPLOYER_KEY`    | Also the operator. Owns the launcher, so it registers quote tokens and refreshes start ticks, and it runs the buyback job.                                           |
| `HYDROPUMP_ADMIN` | The Safe. Upgrade authority on the launcher, and owner of the locker and buyback — the fee split, the protocol fee recipient, and the gauge bribe all sit behind it. |

The split is deliberate: the hot key can do the daily work but cannot upgrade the launcher, change the fee
split, or move where protocol fees go. Only the admin can reassign the admin role.

The locker is deployed under the deployer so it can be wired to the launcher, then handed to the admin.
That transfer is `Ownable2Step`, so accept it from the Safe afterwards.

## Quote tokens

```bash
npm run quotes:build              # derive start ticks from api.hydrex.fi/assets -> script/quote-tokens.json
npm run quotes:register:base      # configureQuoteTokens for everything in that file  (owner)
npm run quotes:refresh:base       # setStartTicks only, for quotes already registered (owner)
```

The generator registers three groups — st0x equities (`wt*`), Coinbase equities (`*c`), and majors
(WETH, cbBTC, USDC, USDT, cbETH, wstETH, EURC) — skipping anything unpriced, out of tick range, or whose
address sits so low that mining a launch token beneath it is impractical.

## Gauge seed

The Hydropump gauge hangs off a placeholder classic pair, so that bribing it pays veHYDX voters without any
launch pool needing a gauge of its own.

```bash
npm run deploy:gauge-seed:base
```

Deploys `Hydropump One` and `Hydropump Two` — 18 decimals, fixed supply of 1 each, no mint path — pairs them
as a volatile classic LP on the Hydrex pair factory, and seeds it with the entire supply of both. The
deployer ends up with every LP token bar the burned minimum, so it can stake the lot once a gauge exists.

Deployed on Base:

|                        |                                                                                             |
| ---------------------- | ------------------------------------------------------------------------------------------- |
| Hydropump One / Two    | `0x1129259595aE819F74F4D348D77904eB1bb8DadC` / `0xe7346c1326464d4110718ac09d3698623f8C91b0` |
| vAMM-HPONE/HPTWO       | `0x2778CF77C7BE4Fc9c0dbBb2006c0c0e2807157F8`                                                |
| Gauge                  | `0x7aDD6e6d16A42264F62d84412D182425cad443c4`                                                |
| Bribe (buyback target) | `0xAb444e493d0e6E03d1ce9353956e0E4ad2ff1642`                                                |

The buyback deposits into the **external** bribe — the one voters collect — not the internal LP-fee bribe.
`test/fork/Buyback.fork.t.sol` runs `bribe()` against the live contract to prove the path works.

Still to do: stake the LP into the gauge from the deployer.
