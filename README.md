# Hydropump

Permissionless token launch contracts for [Hydrex](https://hydrex.fi) on Base.

`launch()` deploys a fixed-supply ERC20, opens its pool against a whitelisted quote token, seeds it with
five single-sided liquidity bands, and locks every position forever. Collected trading fees split 75% to the
creator and 25% to the protocol, which buys HYDX and bribes it into the Hydropump gauge.

## Contracts

| Contract              | Upgradeable |                                                                                |
| --------------------- | ----------- | ------------------------------------------------------------------------------ |
| `HydropumpLauncher`   | UUPS        | Deploys the token, creates the pool, mints the bands, hands them to the locker |
| `HydropumpToken`      | no          | Plain immutable ERC20 — burnable, permit, no owner, no mint path, not a proxy  |
| `HydropumpLocker`     | UUPS        | Holds every launch's positions permanently, splits and pays out fees           |
| `HydropumpBuyback`    | no          | Quote → HYDX, then bribes the Hydropump gauge                                  |
| `HydropumpGaugeToken` | no          | Placeholder ERC20 for the pair the Hydropump gauge hangs off                   |

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
- **Launch fee** at least `launchFee()` (0.00001 ETH) sent as `msg.value`, purely to make spamming launches
  cost something. Overpayment is kept, not refunded. The ETH sits in the launcher until the admin sweeps it
  with `claimLaunchFees`.

Launch pools are deliberately **not gauged**. A gauged Hydrex CL pool runs at `communityFee 1000/1000`,
sending 100% of swap fees to the community vault and leaving the locked positions earning nothing.
veHYDX voters are paid from the single Hydropump gauge instead.

## Fees

**The pool fee is dynamic.** Hydrex's plugin sets it per pool and moves it with volatility — the same launch
pool has been observed charging anything from 0.005% to 1.5% within a day. There is no fixed rate to quote,
and nothing here assumes one: every split below is a share of whatever was actually collected.

Read it from `pool.plugin().getCurrentFee()` (hundredths of a bip). Do **not** read `globalState().lastFee`
or the `fee` that QuoterV2 returns — both report a stale `500` on every Hydrex pool regardless of the real
rate.

Where a swap fee goes, in order:

1. Algebra skims `communityFee / 1000` of it into the pool's community vault, before the positions see
   anything. Read it per pool from `globalState()`; launch pools inherit the factory's default at creation.
2. What is left accrues to the locked positions, uncollected, until someone calls `collect`.
3. `collect(token, positionMask)` pulls it into the locker and credits both shares — the creator's to
   `creatorOwed[token][asset]`, the protocol's to `protocolOwed[asset]`. It transfers nothing out. Bit `i`
   of the mask selects band `i`; `fullMask(token)` is all of them. The keeper `eth_call`s it with the full
   mask to read per-band amounts, then sends a transaction covering only the bands worth the gas.
4. `claim(token)` pays the creator. It collects first, so a creator never has to know whether their fees are
   already credited or still sitting in the positions.
5. `sweepProtocol(assets[])` moves the protocol share to the buyback, on the operator's schedule.

Steps 4 and 5 are deliberately independent. Nothing is pushed to a third party during someone else's call,
so a creator can claim at any time and the buyback job can run daily at its own convenience, and neither can
block the other — a protocol fee recipient that cannot receive an asset never stops a creator being paid.
`claimCredited(token)` skips the collect and pays only what is already credited, should `collect` itself ever
revert.

The split is stored, not hardcoded — `setFeeSplit` takes the two shares and only their ratio matters, so
7500/2500 and 75/25 are the same thing. Changes apply to fees collected from then on; balances already
credited are untouched.

For a frontend: `claimable(token)` is a plain view returning what is credited right now for both assets, and
`claimableMany(tokens[])` does a creator's whole portfolio in one call. `totalOwed(token)` adds fees still
sitting uncollected in the positions — it is not a view, because uncollected fees are only knowable by asking
the position manager, so `eth_call` it; sent as a transaction it is just a full collect. `lifetimeFees(token)`
is the gross a launch has ever collected, kept because claiming zeroes `creatorOwed` and nothing else in
state survives to say what a launch has earned.

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
forge fmt
```

## Deploy

Copy `.env.example` to `.env`, then:

```bash
npm run deploy:base
```

Two identities, nothing else to configure:

|                   | Role                                                                                                                                                                                                                                                              |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DEPLOYER_KEY`    | Also the operator. Owns the launcher, so it registers quote tokens and refreshes start ticks, and it runs the buyback job.                                                                                                                                        |
| `HYDROPUMP_ADMIN` | The Safe. Upgrade authority on the launcher, the only role that can repoint the locker, set and sweep the launch fee, or reassign itself, and owner of the locker and buyback — the fee split, the protocol fee recipient, and the gauge bribe all sit behind it. |

The split is deliberate: the hot key can do the daily work but cannot upgrade the launcher, repoint the
locker, change the fee split, or move where protocol fees go. Repointing the locker would redirect every
future launch's liquidity, so it sits with the Safe.

The locker is deployed under the deployer so it can be wired to the launcher, then handed to the admin.
That transfer is `Ownable2Step`, so accept it from the Safe afterwards.

## Quote tokens

```bash
npm run quotes:build              # derive start ticks from api.hydrex.fi/assets -> script/quotes/quote-tokens.json
npm run quotes:register:base      # configureQuoteTokens for everything in that file  (owner)
npm run quotes:refresh:base       # setStartTicks only, for quotes already registered (owner)
```

The generator registers three groups — st0x equities (`wt*`), Coinbase equities (`*c`), and majors
(WETH, cbBTC, USDC, USDT, cbETH, wstETH, EURC) — skipping anything unpriced, out of tick range, whose
address is already registered, or whose address sits so low that mining a launch token beneath it is
impractical.

Most equity quotes are **B20s** — Base's tokenized stocks, native precompiles at `0xb200…` addresses with
no bytecode. They are ERC20 at the interface but the issuer can block an account or pause the token, and a
blocked transfer _reverts_ rather than returning false. `approve` is not policy gated, so a successful
approval proves nothing about the transfer that follows. Corporate actions move a redemption multiplier,
never raw balances, so pool accounting is untouched. A launch itself never moves the quote token — only a dev buy does — and
the credit-then-pull fee design above means a blocked recipient on either side stalls only its own payout.
`test/fork/LaunchB20.fork.t.sol` covers all of it against a mock etched at the real AAPLc address, since a
precompile cannot execute on a fork.

## Gauge seed

The Hydropump gauge hangs off a placeholder classic pair, so that bribing it pays veHYDX voters without any
launch pool needing a gauge of its own.

```bash
npm run deploy:gauge-seed:base
```

Deploys `Hydropump One` and `Hydropump Two` — 18 decimals, fixed supply of 1 each, no mint path — pairs them
as a volatile classic LP on the Hydrex pair factory, and seeds it with the entire supply of both. The
deployer ends up with every LP token bar the burned minimum, so it can stake the lot once a gauge exists.

### Addresses

|                        |                                                                                             |
| ---------------------- | ------------------------------------------------------------------------------------------- |
| Hydropump One / Two    | `0x1129259595aE819F74F4D348D77904eB1bb8DadC` / `0xe7346c1326464d4110718ac09d3698623f8C91b0` |
| vAMM-HPONE/HPTWO       | `0x2778CF77C7BE4Fc9c0dbBb2006c0c0e2807157F8`                                                |
| Gauge                  | `0x7aDD6e6d16A42264F62d84412D182425cad443c4`                                                |
| Bribe (buyback target) | `0xAb444e493d0e6E03d1ce9353956e0E4ad2ff1642`                                                |

The buyback deposits into the **external** bribe — the one voters collect — not the internal LP-fee bribe.
`test/fork/Buyback.fork.t.sol` runs `bribe()` against the live contract to prove the path works.

```bash
npm run stake:gauge:base
```

The full LP float is staked in the gauge, so its emissions accrue to the deployer.

## Deployed on Base

|                           |                                              |
| ------------------------- | -------------------------------------------- |
| HydropumpLauncher (proxy) | `0xa99DCbB3f0F0F9bF07a8aF85149EAaC3E066D09E` |
| HydropumpLocker (proxy)   | `0x32a5a2FB41F8703662CDA5d938DA02E3a642eD30` |
| HydropumpBuyback          | `0xdcf3a4569f23a501748Bd75260f1ceebf3fa84eE` |
| Launcher implementation   | `0x2732F0C8280887c3935816ebcEC89E9214290860` |
| Locker implementation     | `0x1de08f7382C06b061757E4b881cB340F64B13952` |

Deployed at blocks 51187223 (launcher) and 51187221 (locker) — the start blocks the subgraph indexes from.

Verified on chain after deploy: `launcher.locker()`, `locker.launcher()` and `locker.protocolFeeRecipient()`
all point at each other correctly, `buyback.gaugeBribe()` is the voter bribe, and the fee split reads
7500 / 2500.
