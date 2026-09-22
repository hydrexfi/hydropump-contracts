# Main audit remediation

Base revision: `24eb16cbe4b50e8fd643473c6359da7c9bf16c94`.
No contracts were deployed and no ownership transactions were broadcast for this PR.

## Finding mapping

| Finding | Change | Deployment requirement |
| --- | --- | --- |
| H-01: manipulable public fee swaps | 30-minute plugin TWAP; at least 98% of its quote; revert atomically on unsafe/unknown output | Upgrade Locker and replace BUYBACK_BURN implementation |
| M-01: predicted-pool launch denial of service | Validate actual sqrt price; burn and skip poisoned candidates; four automatic attempts plus permissionless persistent skip recovery | Upgrade Launcher |
| M-02: indefinitely old launch prices | One-day directory expiry; validate source timestamps; preserve observation timestamp through registration | Upgrade PairDirectory, regenerate quote file, and refresh |
| O-01: incomplete ownership handover | Exact acceptance calls and read-only post-deployment gate below | Intended admin must execute acceptOwnership for both contracts |
| L-01: outdated bands/APIs/security claims | README reflects current ABI, band allocations, custody controls and failure behavior | Update consuming documentation/integrations |

O-01 is not resolved on-chain by merging this PR. H-01/M-01/M-02 likewise remain present in deployed
implementations until the reviewed upgrade/replacement steps are executed.

## Fail, fix, pass evidence

Before changing production contracts, `forge test --match-contract AuditRegressionTest -vv` produced:

```text
[FAIL: stale quote must not be offered] test_ExpiredQuoteCannotLaunch
[FAIL: next call did not revert as expected] test_ManipulatedBuybackRevertsAndPreservesCredit
[FAIL: next call did not revert as expected] test_ManipulatedProtocolSellRevertsAndPreservesCredit
[FAIL: ZeroLiquidity()] test_PoisonedMirroredPoolDoesNotBlockLaunch
[FAIL: ZeroLiquidity()] test_PoisonedPoolDoesNotBlockLaunch
[PASS] test_RefreshingExpiredQuoteRestoresLaunch
```

After the fixes the same six tests passed. Additional regressions cover exact expiry, stale file replay,
future timestamps, retry exhaustion/recovery, a clean candidate that cannot be discarded, and missing
oracle history/implementation. Existing tests that asserted the old unsafe behavior were updated to
assert preserved credits or successful launch recovery.

Before changing the quote generator, `node --test test/QuoteSource.test.mjs` failed all four tests:
stale, missing, and future source timestamps were accepted, and the observation time was not preserved.
After the fix all four pass. Tests stub the API and use disposable directories; they do not rewrite the
repository quote list or depend on a live market feed.

The real Base-fork regressions exercise successful recovery from preinitialization and rejection of a
buy/execute/sell sandwich. The manipulated operation leaves credit intact, while the unmanipulated
baseline remains executable. Protocol-sell manipulation is tested in both token orientations.

The handover test observes the read-only gate fail with pending ownership, fail after only one
acceptance, and pass only after the intended admin accepts both; a stranger cannot accept.
This is an operations check, not an automatic ownership transfer.

Final verification on September 22: **221 Solidity unit tests, 58 fork tests, and 4 Node tests passed**.
No test failed or was skipped at the test-case level. The all-quotes test internally skips native B20
assets; the B20 suite uses mocks. Compiler and lint warnings in legacy scripts/mocks remain.
Runtime sizes are below the EIP-170 limit: Launcher 17,120 bytes, Locker 13,140 bytes,
PairDirectory 5,353 bytes, BuybackBurnFeeUse 4,481 bytes (Solidity 0.8.26, optimizer/via-IR).

Commands:

```sh
forge test --no-match-path 'test/fork/*' --summary
node --test test/QuoteSource.test.mjs
BASE_RPC_URL=https://base.gateway.tenderly.co forge test --match-path 'test/fork/*' --summary
forge build --sizes
```

## Execution policy and remaining assumptions

- The 30-minute/2% oracle policy is a reviewable default, not a guarantee against every MEV strategy.
  Sustained oracle manipulation remains a risk in thin pools. Large batches and fast markets may wait.
- Short-history pools fail closed; collection and ordinary creator payouts remain separate from swaps.
  Tiny swaps whose protected output rounds to zero also wait for more fees.
- The output floor includes swap fees and price impact. There is no caller-controlled floor or
  privileged bypass.
- Address skipping is bounded for gas. When four candidates are poisoned, call
  `skipPoisonedLaunch(quoteToken)` until a regular launch has a clean candidate within its retry budget.
  Skipped candidates are zero-supply tokens; they are not registered launches.
- Price publication remains owner-trusted. Legacy direct methods declare a fresh reading at submission.
  Supported file registration uses timestamped methods and does not renew stale data.
- API `updatedAt` cannot establish underlying market freshness if the provider merely refreshes its
  records. Validate that source contract operationally; stock-market closure policy needs its own review.
- No storage fields were added or reordered in Launcher, Locker, or PairDirectory. Constants and
  internal helpers do not consume storage slots. Check the actual deployed predecessor before upgrade.
- This PR does not redesign auto-LP, B20 callback accounting, gauge eligibility/community-fee operations,
  upper curve economics, or issuer seizure policies from the separate follow-up assessment.

## Upgrade sequence

1. Review this PR and reproduce tests against the exact production dependency versions.
2. Deploy new Launcher, Locker and PairDirectory implementations. Check predecessor storage layouts.
3. The Launcher and PairDirectory admin execute `upgradeToAndCall(newImplementation, 0x)`.
   The Locker owner executes its own `upgradeToAndCall`.
4. Deploy `BuybackBurnFeeUse(existingLocker)`; the registry owner calls
   `replaceFeeUse(keccak256("hydropump.feeuse.buyback-burn"), newFeeUse)`. Confirm the ID against
   `contracts/libraries/FeeUses.sol` before preparing calldata. Other strategies need no replacement.
5. Regenerate quote data, review it, and publish through the updated registration script. Old checked-in
   files lack the observation timestamp and must not be relabeled as fresh by hand.
6. Read implementation slots and registry pointers back. Perform a bounded smoke test and inspect fees.
7. Complete the ownership handover below. Run the post-handover gate.

Existing direct deployment scripts may be limited to a deployer who still owns a contract. Once the
Safe owns it, submit the corresponding calls through the Safe rather than using a deployer key.

## O-01: admin acceptance calls

Previously observed intended admin:
`0x74266f2b206D1359B83fc74949EF07176FB3AE03`.
Read `pendingOwner()` again and verify that this remains the intended admin before execution.
Do not transfer ownership again if the intended address is already pending.

Submit these two calls FROM the intended admin account/Safe:

| Target | Function | ETH value | Calldata |
| --- | --- | ---: | --- |
| Locker `0xe1137758d2168617cfa7C8103cbF935f5b1DB1E5` | `acceptOwnership()` | 0 | `0x79ba5097` |
| Registry `0x665B8666693dC6154E3BAACBA739df66b29D300D` | `acceptOwnership()` | 0 | `0x79ba5097` |

The Safe may batch the calls using its normal tooling. A deployer or unrelated caller cannot accept
on its behalf. If the pending owner differs, resolve that explicitly with the current owner.

Read-only verification (set these public addresses in the environment; no private key is needed):

```sh
LOCKER_ADDRESS=0xe1137758d2168617cfa7C8103cbF935f5b1DB1E5 \
FEE_USE_REGISTRY_ADDRESS=0x665B8666693dC6154E3BAACBA739df66b29D300D \
HYDROPUMP_ADMIN=0x74266f2b206D1359B83fc74949EF07176FB3AE03 \
forge script script/deploy/CheckAdminHandover.s.sol:CheckAdminHandover \
  --rpc-url https://base.gateway.tenderly.co
```

The check must succeed with both owners equal to the intended admin and both pending owners zero.
If it fails, deployment is not ready; a pending transfer is not a completed handover.
