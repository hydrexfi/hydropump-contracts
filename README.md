# Hydropump

Permissionless token launch contracts for [Hydrex](https://hydrex.fi) on Base.

`launch()` deploys a fixed-supply ERC20, opens its pool against a whitelisted quote token, seeds it with
five single-sided liquidity bands, and locks every position forever. Trading fees split 75% to whatever the
launch chose to spend them on and 25% to the protocol, which converts its share to the quote token and
bribes the Hydropump gauge with it.

## Contracts

```
contracts/
  core/       Launcher, Locker, Token, Buyback, RewardDistributor
  helpers/    PairDirectory, FeeUseRegistry, GaugeToken
  feeuses/    the three things a creator's share can become
  interfaces/ libraries/
```

| Contract               | Upgradeable |                                                                                     |
| ---------------------- | ----------- | ----------------------------------------------------------------------------------- |
| `PairDirectory`        | UUPS        | What is launchable, and what one launch token is worth in each quote. Repriced daily |
| `HydropumpLauncher`    | UUPS        | Deploys the token, creates the pool, mints the bands, hands them to the locker       |
| `HydropumpToken`       | no          | Plain immutable ERC20 — burnable, permit, no owner, no mint path, not a proxy        |
| `HydropumpLocker`      | UUPS        | Holds every launch's positions permanently and splits the fees they earn             |
| `FeeUseRegistry`       | UUPS        | Which strategy each launch's creator share is spent on. Holds no tokens              |
| `CreatorBalanceFeeUse` | no          | Creator share is paid straight to the creator's recipient                            |
| `AutoLpFeeUse`         | no          | Creator share goes back into the launch's own locked curve, permanently              |
| `BuybackBurnFeeUse`    | no          | Creator share buys the token in its own pool and burns it                            |
| `HydropumpBuyback`     | no          | Quote → HYDX via KyberSwap, then bribes the Hydropump gauge                          |
| `HydropumpGaugeToken`  | no          | Placeholder ERC20 for the pair the Hydropump gauge hangs off                         |
| `HydropumpRewardDistributor` | no    | Operator credits rewards, recipients withdraw. Owner can rewrite and withdraw        |

```
        PairDirectory ──whitelists pairs, daily quote rates──▶ HydropumpLauncher
                                                                     │
                                                  single-sided liquidity, locked
                                                                     ▼
                         ┌──────────────── 25% ──────────  HydropumpLocker  ──── 75% ───────────┐
                         │                             spendRewards(token), public              │
                         ▼                                              books both shares, then  │
                 HydropumpBuyback                                        pushes the creator's ───┤
        (launch-token share sold to quote first,                                                 │
          so only quote ever lands here)                      FeeUseRegistry ── names where ─────┘
                                                        TOKEN → FEE_USE, admin-settable, default
                                            ┌───────────────────┬───────────────────┐
                                            ▼                   ▼                   ▼
                                    CreatorBalance          AutoLP            BuybackBurn
```

## How a launch works

- **Supply** 10,000,000,000, all of it deployed as liquidity. Nothing is held back.
- **Bands** five, at tick offsets `0 / 34k / 63k / 93k / 177k / 887.2k` from the start tick, holding
  `20 / 14.5 / 15.5 / 19 / 31%` of supply. Net buying to reach a valuation is about 5% of it (3.5–6.5%)
  from $100k to $100m: $1m takes about $50k and sells a third of supply. Offsets, not absolute ticks, so
  the curve is quote-agnostic, and unsigned distances rather than directions — see **Pair ordering**.
  Bands are aligned to the pool's actual tick spacing at launch time, and band 0 is always the one
  adjacent to the opening price.
- **Start tick** per quote token, in the **directory**, refreshed as the quote's USD price moves. No oracle.
  `node script/quotes/build-quote-tokens.mjs` derives ticks for every eligible asset from the live Hydrex list.
  One number per quote covers both orientations: it is the token0-side reading, and the launcher negates it
  for the other side.
- **Pair ordering** the launch token can be *either* side of the pool. Algebra sorts a pair by address, and
  a launch does not control its own. When the launch token is token0 the pool opens at the stored start tick
  and the bands run **up** from it; when it is token1 the pool opens at the **negated** tick — the same
  price, inverted — and the same bands run **down**. Either way the liquidity is pure launch token, because
  token0 liquidity lives above the price and token1 liquidity below it. `launchIsToken0(token, quote)` and
  `poolStartTick(token, quote)` give the orientation and the opening tick.
- **No salts** a launch token is deployed with plain `CREATE`, so its address is not knowable beforehand —
  read it from the `Launched` event in the receipt. The curve mirrors, so a token works on either side of
  its pair and no address needs mining.
- **Fee use** a creator picks at launch what their share is spent on — paid out, auto-LP back into their
  own locked curve, or a buyback-and-burn. The choice is an id in the registry; blank rides the default.
  An admin can repoint a launch later, so read it back from the registry rather than the `Launched` event.
- **Locked** positions go straight to the locker, which exposes no transfer, withdraw, burn, or
  decrease-liquidity path.
- **Dev buy** set `buyAmount` to spend that much quote token buying the launch token in the same
  transaction, sent to the caller. `0` skips it. Approve the launcher for the quote token first.
- **Launch fee** at least `launchFee()` (0.0005 ETH) sent as `msg.value`, purely to make spamming launches
  cost something. Overpayment is kept, not refunded. The ETH sits in the launcher until the admin sweeps it
  with `claimLaunchFees`.

### Where the fees go

Three entry points on the locker, all permissionless and none of them pointable. Each collects first, so
none depends on anyone else having run:

| | |
| --- | --- |
| `handleCreatorRewards(token)` | Spends the creator's 75% on whatever the launch chose |
| `handleProtocolRewards(token)` | Converts the protocol's 25% to the pair asset and delivers it to the buyback |
| `handleAllRewards(token)` | Both, in one transaction. What the frontend button calls |

Underneath are the primitives, for one step at a time: `splitRewards` (collect and book),
`spendCreatorShare`, `convertProtocolShare`, `sweepProtocol`.

**`splitRewards` can never fail on its own.** It touches no pool, no swap and no third-party contract — it
only moves numbers. Everything that can fail is downstream of it, so a broken fee use or an unfillable pool
leaves the share booked and reachable rather than stranding it, and one creator's choice can never block
another's fees or the protocol's. It does refuse re-entry: every locker entry point is `nonReentrant`.

**Send `handleAllRewards` with a generous gas limit.** Its protocol half is wrapped in a `try` so a pool
that cannot fill a sell does not stop a creator being paid — but that means the call succeeds whether or
not the body runs, and gas estimation will settle on a limit that starves it.

**The protocol's launch-token share is sold into the pool** by `convertProtocolShare`, so only the quote
token ever reaches the buyback. No price bound: the caller does not choose the price and takes none of the
output, so a bound could only make the call stuck. `spendRewards` runs it best-effort — if it fails the
share stays in `protocolOwed` for a later call.

**The protocol side is pulled, not pushed.** `sweepProtocol` is a separate call because the buyback holds
real tokens and a quote that can blocklist an address — a B20 equity, say — would otherwise make a
transfer to it revert.

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

Both pair orderings are exercised throughout, because which one a launch gets is not something it chooses:

- `test/LaunchCurve.t.sol` seeds the curve both ways against a stand-in Algebra — the orientation is forced
  by etching a quote near the top or the bottom of the address space — across five tick spacings, every
  start tick the generator emits, and fuzzed over the whole configurable tick range.
- `test/HydropumpLocker.t.sol` and `test/FeeUses.t.sol` each run their whole suite twice, the second time
  with the launch token sorting above its quote, so nothing may quietly assume the pool's `amount0` is the
  launch token.
- `test/fork/FeeFlow.fork.t.sol` runs the full path against live Hydrex — real swaps, a real split, a real
  conversion, and each of the three fee uses — in both orientations.
- `test/fork/LaunchCurve.fork.t.sol` launches against **every** quote the generator emits and checks each
  opens at the target valuation, whichever side it lands on.

## Live addresses (Base)

| | |
| --- | --- |
| `PairDirectory` | `0xc06e27984c25B4C14D8e36091E633690206Da715` |
| `HydropumpLauncher` | `0x0102B7c2C293CaA425994f0D8F930eccB216965d` |
| `HydropumpLocker` | `0x1b5D6B9836E07aDCB5CBabA218E5EeE3fE2f21F5` |
| `FeeUseRegistry` | `0xcd12D1E35f1957DB330492BbD8CAa1887500eD12` |
| `CreatorBalanceFeeUse` | `0xfd2ef93dF03f536B1afD798a1ABAA8a5361e6A4e` |
| `AutoLpFeeUse` | `0xe81d8f8415C8e1393bb0F5f059aF87C2bf523063` |
| `BuybackBurnFeeUse` | `0x890c74027E6DC27A019d39329313ecc50064fd30` |
| `HydropumpBuyback` | `0x104326575BCce86129933842D59BE172AD57b5e6` |
| `HydropumpRewardDistributor` | `0x346bD6Ca0eBa1de331219B52C0903C03Ee86e0b9` |

Deployed at block `51748534`. Indexed by `hydrex-dummy/0.6.0`.

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

After the first quote registration, directory ownership goes to the backend key that runs the reprice cron
(`0x1681b1d40AB2fb81F8a1dd28b56baFfbB869a214`, also `HYDROPUMP_OPERATOR`), which accepts it with
`acceptOwnership()`.

## Quote tokens

```bash
npm run quotes:build              # derive start ticks from api.hydrex.fi/assets -> script/quotes/quote-tokens.json
npm run quotes:register:base      # configureQuoteTokens on the directory, for everything in that file (owner)
npm run quotes:refresh:base       # setStartTicks only, for quotes already registered                  (owner)
```

The generator registers three groups — st0x equities (`wt*`), Coinbase equities (`*c`), and majors
(WETH, cbBTC, USDC, USDT, cbETH, wstETH, EURC) — skipping anything unpriced, out of tick range, or already
registered. A quote's address no longer constrains anything: HYDX sits at `0x00000e7e…`, low enough that no
launch token can ever sort below it, and it is an ordinary quote because the curve mirrors onto the other
side instead.

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
