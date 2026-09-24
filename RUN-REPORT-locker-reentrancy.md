# Locker reentrancy guard — run report

## What happened, for someone who wasn't here

Hydropump's locker is the contract that holds every launch's liquidity positions and keeps the ledger of
what each launch's creator and the protocol are owed. One of its calls, `spendCreatorShare`, sends a
launch's creator share to that launch's fee use, calls the fee use, and then books back to that same launch
whatever the locker's balance rose by while the call was running. That is how a fee use returns what it
could not spend. The locker had no reentrancy guard, so anything that could make *another* launch's fees
arrive during that call got them booked twice: once to the launch that earned them, and again to the launch
being spent. The locker would then owe more than it held, and the shortfall would come out of other
launches' fees and the protocol's share. The security review of 23 September 2026 found this and rated it
High [HP-02].

The fix is a reentrancy guard on the locker. All nine entry points that move tokens or change the ledger —
both `splitRewards` overloads, `spendCreatorShare`, `handleCreatorRewards`, `handleProtocolRewards`,
`handleAllRewards`, `deliverProtocolShare`, `convertProtocolShare` and `sweepProtocol` — now take
OpenZeppelin's `ReentrancyGuardTransient`, so no two of them can run at once and nothing can call back into
the locker while one is in progress. The bodies of the ones that call each other moved into internal
functions, so a combined call like `handleAllRewards` takes the guard once rather than hitting its own
guard partway through. The guard keeps its flag in transient storage, so it occupies no storage slot: the
locker's storage layout is byte-for-byte what it was, and the existing v1.0.0 snapshot still matches.

Both routes the review described are now closed, and there is a test for each that fails on the old code
and passes on the new. Nothing else changed behaviour: the full unit suite went from 227 tests to 233, all
passing, and the fork suite is green against Base apart from the three failures that were already failing
on `main` before this change.

This needs a new locker implementation deployed and the proxy upgraded. No storage migration, no other
contract changes.

## What was done, per queue item

### 1. Reproduce both routes as failing tests

`test/LockerReentrancy.t.sol` is new. It is built on the repo's `HydropumpFixture` and mocks. It carried
five tests when this item was done, and six after the review added one.

The hooked-quote route is ported from the review's proof of concept
(`poc/test/reentry/HookedQuoteReentry.t.sol`): a quote token that calls its receiver on every transfer, and
a creator's recipient contract that uses that callback to re-enter `splitRewards` for someone else's launch
while its own share is being paid. The proof of concept asserted that the double booking happens; this
version asserts that the re-entry is refused, that the victim launch's `creatorOwed` is unchanged, and that
for every asset the locker's booked total — every launch's `creatorOwed` plus `protocolOwed` — is no more
than the balance it actually holds.

The hostile-fee-use route is written fresh against a `ReentrantFeeUse` modelled on the one in
`poc/test/invariant/HarnessControls.t.sol`. The invariant harness around it was not ported. Only the
fee-use registry's owner can point a launch at such a fee use, so this route needs a privileged mistake;
the hooked-quote route needs none.

On the unfixed contract, three of those five failed:

| Test | Failure on unfixed code |
| --- | --- |
| `test_hookedQuote_creatorCannotDoubleBookAnotherLaunchsFees` | `the re-entrant splitRewards must be refused` |
| `test_hookedQuote_attackerIsPaidOnlyItsOwnShare` | `nothing was re-booked to the attacker: 4000000000000000 != 0` |
| `test_hostileFeeUse_cannotSplitAnotherLaunchMidSpend` | `next call did not revert as expected` |

The middle line is the money: the victim launch's whole 4e15 of collected quote had been credited to the
attacker's own `creatorOwed`.

The other two were ported to pass both before and after, as the work order asked:
`test_hookedQuote_sweepDuringSpendOnlyAffectsTheAttackersOwnSpend` and
`test_launchNeverHandsTheCreatorControl_evenWithAHookedQuote`. Both passed on the unfixed code and still
pass.

### 2. Add the guard

`HydropumpLocker` now inherits `ReentrancyGuardTransient` and applies `nonReentrant` to the nine entry
points listed above. Three bodies moved into internal functions — `_splitRewards`, `_spendCreatorShare` and
`_deliverProtocolShare` — so the combined entry points call those rather than calling a guarded sibling.

`spendCreatorShare` gained NatSpec naming the invariant it relies on: no locker entry point can run while
another is in progress, which is what makes the balance rise across `onFees` that fee use's return and
nothing else. The comment above the re-book was extended to say the same thing at the point where it
matters.

After the change every test in the new file passes, and the whole unit suite is 233 passed, 0 failed,
0 skipped.

Gas, measured the same way before and after (`forge test --match-path test/FeeUses.t.sol --gas-report`, an
identical set of calls in both runs; the "after" column is the final tree, including the review fixes):

| Function | Avg before | Avg after | Delta |
| --- | --- | --- | --- |
| `handleAllRewards` | 585,216 | 586,060 | +844 (+0.14%) |
| `handleCreatorRewards` | 341,115 | 341,494 | +379 |
| `handleProtocolRewards` | 364,504 | 363,404 | −1,100 |
| `splitRewards` | 186,128 | 186,575 | +447 |
| `spendCreatorShare` | 181,015 | 181,471 | +456 |

`handleAllRewards`'s median moved 568,730 → 569,558. `handleProtocolRewards` got *cheaper* because it no
longer makes an external call to itself to deliver the protocol share; it calls the internal function, and
that saves more than the guard costs.

The locker's runtime size went from 10,760 to 10,999 bytes, still 13,577 bytes under the limit.

## The one design call worth a reviewer's attention

`handleAllRewards` makes the protocol half best-effort by wrapping it in `try { } catch { }`, and `try`
needs a real external call to get a frame it can roll back. If it called the now-guarded
`deliverProtocolShare`, that call would hit the guard `handleAllRewards` is already holding, revert, and be
swallowed by the `catch` — so the protocol share would never be delivered.

The answer was a second entry point, `deliverProtocolShareFromSelf`, with the same body through
`_deliverProtocolShare`. It carries no `nonReentrant` of its own, because it exists to be called from
inside one. Instead it checks its own precondition: it reverts `NotGuardedSelfCall()` unless `msg.sender`
is the locker itself **and** the reentrancy guard is currently held. Both halves matter. The first keeps
every outside caller out. The second means "this only ever runs inside a guarded frame" is a property of
the function rather than of the rest of the file — a later upgrade that adds a second self-call, a
fallback, or an `onFees` to the locker cannot quietly widen it. There is a test that fails if either half
is deleted; I checked that by deleting each and watching it go red.

The guard is still taken exactly once per transaction and is not loosened anywhere. It is a new function in
the locker's ABI, which is the part worth a second pair of eyes.

## What the review changed

The `code-reviewer` agent reviewed the first commit and returned CHANGES REQUESTED: one MEDIUM, three LOWs
and four nits. Everything above LOW is fixed, and I took all three LOWs as well, in commit two.

- **MEDIUM — the new access check had no test.** `deliverProtocolShareFromSelf` is the one entry point that
  moves tokens without a guard of its own, so its access check is the only thing keeping an unguarded
  convert-and-sweep off the public surface, and nothing exercised it: deleting the line left the whole
  suite green. There is now a test that calls it as the test contract, as a stranger, and as the locker's
  own address with no guard held, and expects all three refused.
- **LOW — the check rested on a property of the file, not of the function.** Hence the
  `!_reentrancyGuardEntered()` half described above, and the rename from `NotSelf()` to
  `NotGuardedSelfCall()`, which says what is actually being checked.
- **LOW — the stated invariant had a counterexample 400 lines below it.** The contract's NatSpec and the
  README both said every entry point that moves tokens or changes the ledger is `nonReentrant`.
  `deliverProtocolShareFromSelf` is one that is not. Both now name the exception.
- **LOW, declined — `test_hookedQuote_sweepDuringSpendOnlyAffectsTheAttackersOwnSpend` cannot tell the fix
  from its absence.** True, and deliberate: the work order asks for that test to pass both before and
  after, so it cannot assert anything that only holds after. The discriminating assertion the reviewer
  wants — that the re-entrant call is refused, by the guard's own error — is made by
  `test_hookedQuote_creatorCannotDoubleBookAnotherLaunchsFees`, which fails on the unfixed contract. I left
  the instruction as written rather than override it; if Garrett would rather have the assertion than the
  before-and-after property, it is a two-line change.
- Four nits taken: two comments that overstated what they described, one that read as though a no-op call
  paid something, and a note on two assertions that restate what a `vm.expectRevert` already guarantees.

The reviewer also corrected me on a claim I had made in the first commit message and in an earlier draft of
this report. I wrote that if the self-call had gone to the guarded `deliverProtocolShare`, the swallowed
revert would have been silent and no existing test would have caught it. That is wrong.
`test/FeeUses.t.sol` asserts `protocolOwed` reaches zero and the quote reaches the buyback after
`handleAllRewards` (lines 345 and 353), so the unit suite — and therefore CI, without the fork tests —
would have gone red. The design decision stands; my reason for thinking it urgent was overstated, and the
shape I chose turns out to be covered by existing regression tests rather than resting on argument alone.

## Verified versus assumed

**Verified — I ran it:**

- Both re-entry routes fail on the unfixed contract and pass on the fixed one, with the failing lines
  recorded above and in `RUN-LOG.md`.
- `forge build --sizes`, `npm run test:unit` (232 passed), `npm run fmt:check` and
  `npm run check:storage-snapshots` (all four contracts PASS against their committed v1.0.0 snapshots) all
  pass on the change.
- The fork suite runs against Base, nothing skipped, with the three known-failing tests excluded by name.
- The new access-check test fails if either half of the check is removed. I deleted each half in turn, ran
  the test, and saw it fail both times before restoring the line.
- The storage layout is unchanged: no snapshot was added, and none was edited.
- No fee use calls a non-view function on the locker. Searched `grep -rn 'locker\.' contracts/feeuses/` and
  `grep -rn 'locker\.\|IHydropumpLocker(' contracts`: the three fee uses call only `poolOf`,
  `getPositions`, `quoteTokenOf` and `creatorRecipient`, all views; the launcher calls `registerLaunch`,
  which is not one of the guarded entry points and is not reached from inside one.
- Nothing outside the locker calls `deliverProtocolShare`. Searched
  `grep -rn 'deliverProtocolShare' contracts script scripts test`.
- The two deploy scripts that use the locker (`script/deploy/SeedLaunches.s.sol` and
  `script/deploy/TradeHydxPool.s.sol`) call the entry points one after another, never nested, so the guard
  cannot bite them.

**Assumed — not checked in this run:**

- That Base has EIP-1153 transient storage live. The repo already builds for the `cancun` EVM version, and
  the review's own fix note says Base supports it, but I did not verify it on chain.
- That no quote token currently on the whitelist has a transfer hook. That is the review's finding, from a
  bytecode scan at block 51,634,448; I did not re-run it. The fix does not depend on it — it removes the
  class either way — but the "nobody can exploit this today" claim does.
- That the three fork tests already failing on `main` are not this repo's problem. I confirmed they fail
  identically before and after; whether the Algebra factory's community-fee change is intended is a team
  question, as the work order says.

## Tests changed

No existing test's assertion was rewritten. The only test file touched is the new
`test/LockerReentrancy.t.sol`, which grew one more test after the review
(`test_deliverProtocolShareFromSelf_refusesEveryCallerAndEveryUnguardedFrame`).

Two tests in it are ports of proof-of-concept tests whose assertions were deliberately inverted, which the
work order asked for: the proof of concept asserted the double booking happens, and these assert it is
refused. That is a new file asserting the safe behaviour, not an existing test weakened.

One ported test needed its assertion re-aimed rather than inverted.
`test_hookedQuote_sweepDuringSpendOnlyAffectsTheAttackersOwnSpend` says that a hook pulling the locker's
balance down mid-spend can only ever hurt the spend it is attached to. In the proof of concept that showed
up as the attacker's own spend reverting on an arithmetic underflow, and the test asserted the revert. With
the guard in place the sweep is refused instead and the attacker's own spend completes, so asserting the
revert would have failed after the fix. The test now asserts the claim the name makes — the victim is still
paid in full and the ledger stays covered — and logs which way the attacker's own spend went. It passes
before and after. This is the one place where I had to choose between the letter of "port it unchanged" and
its meaning, and I chose the meaning.

## Upgrade impact

- `HydropumpLocker` needs a new implementation deployed and the UUPS proxy pointed at it.
- Storage is unchanged. No new snapshot, no `__gap` change, no migration.
- The ABI gains one function, `deliverProtocolShareFromSelf(address)`, and one error,
  `NotGuardedSelfCall()`. Nothing off-chain needs to call the new function; it exists for the locker's own
  use.
- No other contract changes. The fee uses, the launcher, the registry and the directory are untouched.

## Parked

Nothing was parked. No question came up that needed Rich.

## Known failures on main, before and after

The work order named three fork tests already failing on unmodified `main` at today's chain state. All
three still fail with exactly the same messages after the change, and no other fork test fails.

| Test | Message, before and after |
| --- | --- |
| `test_LaunchPoolsAreNotGaugedOnEitherSide` | `launch pools must keep fees with the LP: 15 != 0` |
| `test_TheDevBuyFillsInTheSameTransactionOnBothSides` | `quote landed in the pool: 49999925000000000 != 50000000000000000` |
| `test_StakesTheWholeLpBalance` | `LP is neither held nor staked: 0 <= 0` |

## Cost

1 hour 54 minutes wall clock, $0.00. No model spend beyond this session: no paid API, no subagent on a
paid provider. Most of the wall clock is the fork suite, which takes about 13 minutes a run and was run
three times — once for the baseline on unmodified `main`, once on the fix, once on the reviewed tree.
`test/fork/LaunchCurve.fork.t.sol` alone accounts for about 12 of those 13 minutes.

## What I'd do next, ranked

1. **Stop inferring the remainder from the balance at all.** The review's second suggestion: have
   `IFeeUse.onFees` return what it hands back, and re-book exactly that, checked against the balance. The
   guard closes the route in; returning the amount removes the inference the route attacked. It was out of
   scope here because it changes all three fee uses' interface.
2. **Treat quote listing as security-relevant.** The hooked-quote route needs a whitelisted quote with a
   transfer hook. Today none has one, but that is a property of the current list, not of the code. A
   written check before the directory owner lists a token would make it a property of the process.
3. **Get the fork suite into CI.** It is the only gate that would have caught a regression in the paths
   this change touches, and it runs nowhere but a developer's laptop. It needs a `BASE_RPC_URL` repository
   secret, which needs an admin. Until then every contract change depends on whoever pushed it having
   remembered to run it.
4. **Re-run the quote hook scan before Friday's deployment.** The scan is from block 51,634,448. If any
   quote has been listed since, the "not exploitable today" claim is stale.
5. **Make `check:storage-snapshots` immune to a stale artifact.** Twice in this run, editing only
   `HydropumpLocker.sol` and re-running the check reported the layout as missing from the artifact, which
   reads exactly like a real layout change and is one of the work order's hard stops. `forge clean &&
   forge build` cleared it both times. CI always builds clean so it never sees this, which is why it has
   survived — but it costs a developer a scare and several minutes each time, and the failure text invites
   exactly the wrong response, which is to regenerate a snapshot. Having the script do a clean build, or
   detect the caching case and say so, would be a few lines.

## Where I was wrong during the run

- I expected `handleAllRewards` to need nothing more than the internal-function split the work order
  described. It needed one thing more, because `try`/`catch` cannot wrap an internal call — see the design
  call section above. I did not park it, because there was one reading that satisfied every constraint
  rather than two readings to choose between, but it is the part of this change I would most want a
  reviewer to disagree with me about if they are going to.
- I took the first storage-check failure at face value for a moment. It reported the locker's layout as
  unverifiable, which reads like the hard stop the work order names. It was a stale build artifact —
  forge's own message says so — and `forge clean && forge build` cleared it. No snapshot was touched. It
  then happened a second time, on the second edit to the same file, which makes it reproducible rather
  than a one-off; see "what I'd do next".
- I told the reviewer, and wrote in the first commit message, that routing the self-call through the
  guarded `deliverProtocolShare` would have failed silently with no existing test catching it. That was
  wrong: `test/FeeUses.t.sol` asserts `protocolOwed` reaches zero and the quote reaches the buyback after
  `handleAllRewards`, so the unit suite would have gone red. The decision I made was right; the reason I
  gave for it was overstated.
- My first version of the new access check tested only who was calling, not whether a guard was held. The
  reviewer was right that "only reachable from a guarded entry point" was a property of the rest of the
  file rather than of the function, and that a later upgrade could break it without touching the line.

## Details

### Files changed

| File | Change |
| --- | --- |
| `contracts/core/HydropumpLocker.sol` | Inherits `ReentrancyGuardTransient`; `nonReentrant` on nine entry points; three bodies split into `_splitRewards`, `_spendCreatorShare`, `_deliverProtocolShare`; new `deliverProtocolShareFromSelf` and `NotGuardedSelfCall()`; NatSpec on the invariant. |
| `test/LockerReentrancy.t.sol` | New. Six tests: the two re-entry routes, two supporting facts, and the new access check. |
| `README.md` | One claim corrected — see below. |
| `RUN-LOG.md`, `RUN-REPORT-locker-reentrancy.md` | The run's log and this report. |

### The README correction

`README.md` said "**`splitRewards` can never fail.**" This change makes that narrowly false: a call made
from inside another locker call now reverts. The sentence is load-bearing — it is how a reader reasons
about whether a creator's fees can ever be blocked — so it was corrected in place rather than left to
mislead. It now reads "can never fail on its own" and names the one exception. It sits in the same commit
as the fix, because the fix is what made it false.

### The guard, entry point by entry point

| Entry point | Guard | Body |
| --- | --- | --- |
| `splitRewards(address)` | `nonReentrant` | `_splitRewards` |
| `splitRewards(address,uint256)` | `nonReentrant` | `_splitRewards` |
| `spendCreatorShare(address)` | `nonReentrant` | `_spendCreatorShare` |
| `handleCreatorRewards(address)` | `nonReentrant` | `_splitRewards` + `_spendCreatorShare` |
| `handleProtocolRewards(address)` | `nonReentrant` | `_splitRewards` + `_deliverProtocolShare` |
| `handleAllRewards(address)` | `nonReentrant` | `_splitRewards` + `_spendCreatorShare` + `try this.deliverProtocolShareFromSelf` |
| `deliverProtocolShare(address)` | `nonReentrant` | `_deliverProtocolShare` |
| `deliverProtocolShareFromSelf(address)` | self-only, and only inside a held guard (`NotGuardedSelfCall()`) | `_deliverProtocolShare` |
| `convertProtocolShare(address)` | `nonReentrant` | `_convertProtocolShare` |
| `sweepProtocol(address[])` | `nonReentrant` | `_sweep` per asset |

`registerLaunch`, `setCreatorRecipient`, `onERC721Received` and the owner-only setters are not guarded.
None of them moves tokens or changes `creatorOwed` / `protocolOwed`, and none is reachable from inside a
guarded call.

### Commands run

```
npm ci && git submodule update --init
forge clean && forge build                     # after each locker edit, see the storage-check note
forge build --sizes
npm run test:unit
npm run fmt:check
npm run check:storage-snapshots
forge test --match-path test/LockerReentrancy.t.sol -vv
forge test --match-path test/FeeUses.t.sol --gas-report
npm run test:fork:strict                       # baseline, on unmodified main
npm run test:fork:strict -- --no-match-test 'test_LaunchPoolsAreNotGaugedOnEitherSide|test_TheDevBuyFillsInTheSameTransactionOnBothSides|test_StakesTheWholeLpBalance'
```

No transaction was broadcast, no deploy or quote-registration script was run, and no private key was used.
The fork runs read Base through the private RPC in the worktree's `.env`, which is untracked and was never
printed or logged.
