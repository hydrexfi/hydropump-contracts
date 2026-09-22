# Hydropump

Permissionless token launch contracts for Hydrex on Base.

A launch deploys a fixed-supply, burnable ERC20, creates its quote-token pool, seeds five single-sided
liquidity positions, and sends their NFTs to the locker. The default split of collected LP fees is
75% to the creator-selected fee use and 25% to the protocol buyback.

## Contracts and trust

| Contract | Responsibility | Upgrade/control |
| --- | --- | --- |
| PairDirectory | Quote allowlist and opening-price ticks | Owner refreshes; admin upgrades |
| HydropumpLauncher | Token deployment, bands, optional initial buy | Admin upgrades and sets pointers |
| HydropumpLocker | NFT custody and per-asset fee accounting | Owner upgrades and sets split/destinations |
| FeeUseRegistry | Maps launches to fee uses | Owner replaces implementations and choices |
| CreatorBalanceFeeUse | Pays the current creator recipient | Immutable implementation |
| AutoLpFeeUse | Adds fees to the active or nearest locked band | Immutable implementation |
| BuybackBurnFeeUse | Buys and burns launch tokens with a historical output floor | Immutable implementation |
| HydropumpBuyback | Operator routes quote assets to HYDX and bribes the gauge | Owner/operator controls |
| HydropumpRewardDistributor | Funded allocations and recipient claims | Owner can rewrite or withdraw allocations |
| HydropumpToken | Initial 10 billion supply, burnable, permit | No owner, proxy, or further minting |
| HydropumpGaugeToken | Fixed-supply gauge seed token | No further minting |

The current locker has no ordinary NFT transfer or liquidity withdrawal path. **Custody is nevertheless
upgradeable**: its owner can install different code. Do not describe it as an immutable permanent lock.
Registry choices and the fee split are also administratively changeable.

## Launch curve

| Band | Tick offsets from aligned base | Initial supply share |
| --- | --- | ---: |
| 0 | 0–14,000 | 5.47% |
| 1 | 14,000–36,000 | 13.36% |
| 2 | 36,000–62,000 | 18.22% |
| 3 | 62,000–150,000 | 22.47% |
| 4 | 150,000–887,200, clamped to usable ticks | 40.48% |

Offsets are mirrored when the launch token sorts above the quote token. Boundaries align to the pool's
tick spacing; all initial deposits are launch-token-only. Unused mint-rounding dust is burned.
The opening USD FDV targets roughly $5,000 using the directory's quote valuation. USD results change
with the quote's market price; the pool itself trades token ratios.

CREATE addresses are predictable from the launcher nonce. Every candidate pool's actual opening sqrt
price is checked against the intended price. A launch burns the supply of a mismatched candidate and
tries the next address, up to four candidates. If all four are poisoned, the transaction reverts.
Anyone can call `skipPoisonedLaunch(quoteToken)` to persistently advance past one poisoned address,
then retry. This deploys a zero-supply discarded token, takes no fee, and reverts for a clean candidate.
Use the `Launched` event for the final address; do not assume it is the first predicted candidate.

`launch(LaunchParams)` accepts name, symbol, quoteToken, creatorRecipient, buyAmount, and feeUse.
A zero recipient defaults to the caller; zero buyAmount skips the initial buy; zero feeUse follows the
registry default. Approve the launcher for quote spent on an initial buy. Send at least `launchFee()`;
overpayments are retained. Existing deployment defaults use 0.00001 ETH.

## Fee collection and execution

| Entry point | Behavior |
| --- | --- |
| `splitRewards(token)` / `splitRewards(token, mask)` | Collects selected positions and books both asset shares |
| `spendCreatorShare(token)` | Sends booked creator fees to the selected fee use |
| `convertProtocolShare(token)` | Converts booked protocol launch tokens to quote |
| `sweepProtocol(assets)` | Sends booked quote assets to the configured buyback |
| `deliverProtocolShare(token)` | Converts and sweeps the protocol share |
| `handleCreatorRewards(token)` | Collects and spends creator fees |
| `handleProtocolRewards(token)` | Collects and delivers protocol fees |
| `handleAllRewards(token)` | Collects, spends creator fees, then attempts protocol delivery |

All these entry points are permissionless with fixed destinations. Collection calls the external position
manager and can fail on token restrictions; it does not execute a strategy or swap. Failed spending
reverts atomically, preserving credits. Auto-LP returns unused assets and the locker rebooks them.

`handleAllRewards` catches failure of protocol delivery, but creator-strategy failure reverts the whole
call. A successful receipt does not prove protocol delivery succeeded: inspect events and balances.
Gas estimation can underfund its optional protocol leg. Standalone collection and creator-balance
payouts remain available when a swap is unsafe.

### Swap protection

Protocol conversions and creator buyback-and-burn use the pool plugin's 30-minute tick TWAP.
Output must be at least 98% of the reference quote, including pool fees and price impact. The minimum
is calculated on-chain and cannot be relaxed by the caller. Missing/short oracle history, malformed
observations, dust with zero protected output, or an inadequate fill revert without consuming credits.
A launch-token-only burn does not require a swap or oracle history.

This bounds adverse execution; it does not eliminate all MEV or sustained oracle manipulation.
Large accumulated fees, a fast-moving price, or a pool fee near the limit may delay execution.
There is no privileged bypass. The 30-minute/2% policy requires review before deployment.
The initial creator buy is a separate atomic launch operation, not this fee-swap path.

### Accounting and external fees

Read `creatorOwed(token, asset)`, `protocolOwed(asset)`, `lifetimeFees(token)`, `getLaunch(token)`,
`getPositions(token)`, and `fullMask(token)`. The split's scalar return values sum raw units of
different assets and must not be displayed as USD volume.

The pool's dynamic trading fee and community-fee deduction are separate from the 75/25 locker split.
Only fees reaching positions can be split. Setting communityFee to 1000/1000 redirects all new swap
fees away from LP positions. Gauge creation and an administrative community-fee update are separate
actions: operations must exclude launch pools from incompatible settings.

CreatorBalance reads the current recipient each time. That recipient can call `setCreatorRecipient`;
the original creator has no separate override. The registry owner can replace a strategy or repoint
a launch. The buyback operator provides router calldata and a minimum HYDX output; the operator is
trusted to choose those safely. `bribe()` sends held HYDX to the configured gauge bribe.

## Quote freshness

The directory rejects launches when its price timestamp is older than one day, zero, or in the future.
`isEnabled` includes freshness. Raw config and unchecked tick views remain readable when a quote expires.
Refresh frequently enough to avoid gaps rather than scheduling exactly at the expiry boundary.

`build-quote-tokens.mjs` requires a usable API `updatedAt` for every included quote and rejects stale,
future, or missing timestamps. The generated `priceObservedAt` is the oldest included observation.
Registration checks this timestamp before broadcasting and calls
`configureQuoteTokensWithTimestamp` or `setStartTicksWithTimestamp`, preserving it on-chain.
Old generated files without this field must be regenerated.

The API timestamp is only as trustworthy as the source's freshness semantics; a recently refreshed
record does not independently prove a fresh underlying market observation. The owner remains a trusted
price publisher. Legacy owner methods treat explicitly submitted ticks as observed at the transaction
time; the supported file-registration flow uses the timestamped methods.

B20 quote tokens have issuer-controlled transfer policies, pauses, and seizure capabilities.
Standard forks use B20 mocks and cannot establish native precompile behavior. Wrapped equities must
be priced per wrapped token. Listing decisions and callback/accounting hardening require separate review.

## Development and checks

```sh
npm ci
forge build
forge test --no-match-path 'test/fork/*'
node --test test/QuoteSource.test.mjs
BASE_RPC_URL=https://base.gateway.tenderly.co forge test --match-path 'test/fork/*'
```

Forks exercise live Base dependencies but deploy a fresh local Hydropump stack. No test broadcasts.
Some suites use historical blocks, and the all-quotes suite internally omits native B20 assets.
The audit regressions cover poisoned pools, expiry, adverse fee swaps, and retained credits.

## Deployment and remediation

See [audit remediation and deployment steps](docs/AUDIT_REMEDIATION.md) for the finding mapping,
red/green evidence, upgrade sequence, and admin handover. A merged PR does not apply upgrades or
accept ownership on-chain.

```sh
npm run quotes:build
npm run quotes:register:base
npm run quotes:refresh:base
```

These registration commands publish transactions using the configured owner. Review the generated data
before running them. Existing deploy scripts require the Safe to accept locker and registry ownership.

## Recorded Base deployment addresses

These are the existing deployment addresses, not evidence that this PR has been deployed.

| Contract | Address |
| --- | --- |
| PairDirectory | `0x86F4Ff7b66De9fB8580DB4892c40514479828B6A` |
| HydropumpLauncher | `0xB4209c5D03bA37f63e495d951EFc017f6332f5aE` |
| HydropumpLocker | `0xe1137758d2168617cfa7C8103cbF935f5b1DB1E5` |
| FeeUseRegistry | `0x665B8666693dC6154E3BAACBA739df66b29D300D` |
| HydropumpBuyback | `0xe3cD62d4dC36D0e751D1C4AC6a6Fc22d632e611a` |
| HydropumpRewardDistributor | `0x24533D77817e65901003b79D0529eDA88098371d` |

The Hydropump gauge uses a separate classic seed pair:
`0x2778CF77C7BE4Fc9c0dbBb2006c0c0e2807157F8`.
Gauge: `0x7aDD6e6d16A42264F62d84412D182425cad443c4`.
External bribe: `0xAb444e493d0e6E03d1ce9353956e0E4ad2ff1642`.
The operator stakes the seed LP and funds reward allocations; weekly rankings are not enforced by the distributor.
