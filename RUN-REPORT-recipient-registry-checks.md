# Recipient and registry checks — run report

Issue: [#10](https://github.com/hydrexfi/hydropump-contracts/issues/10) — rejecting the locker or the
registry as a creator recipient (HP-11), and rejecting mismatched registries at launch (HP-08).
Branch: `fix/recipient-and-registry-checks`

## What happened, for someone who wasn't here

Hydropump is a token launchpad: when someone launches a token, its trading fees get split between the
creator and the protocol. The creator's share goes to an address they choose — the "creator recipient" —
and is spent however they picked at launch (paid to a balance, used to buy back and burn the token, or
added back into the pool). Two small gaps in that setup, both found by last week's security review, could
each cause a creator's fees to go missing without anyone getting an error.

**The first gap: a creator's fees could get locked up forever.** The contract that holds every launch's
liquidity permanently and pays out fees is called the locker (`HydropumpLocker.sol` in the code). If a
creator recipient was ever set to the locker itself — by mistake, or by someone else's mistake acting on
their behalf — the creator's payout would be sent to the locker, which would then immediately credit it
right back to the same launch's own ledger instead of paying anyone. And because only the current
recipient is allowed to change the recipient, and the recipient was now the locker, nobody could ever fix
it: the money was stuck for good. The same trap existed if the recipient was set to the fee-routing
registry instead of the locker. The review rated this a Low-severity finding (HP-11). The fix rejects both
of those addresses as a recipient, both when a token is first launched and any time the recipient is
changed later.

**The second gap: a creator's chosen fee routing could get silently ignored.** Two different contracts
each keep their own note of which fee-routing registry to use: the launcher (which records what a creator
picked when they launched) and the locker (which actually spends the money later). Normally these point
at the same registry. But nothing stopped them from being pointed at two different ones — for instance, if
someone updated one during a deployment and forgot the other. If that happened, a creator's choice (say,
"add my fees back into the pool automatically") would be written down in the launcher's registry, but the
locker would never look there — it would just fall back to whatever the default choice is in its own,
different registry. Nothing would be lost, but the creator's actual choice would be quietly overridden.
The review also rated this a Low-severity finding (HP-08). The fix makes launching a new token fail loudly
if the two registries disagree, so the mismatch gets caught immediately instead of silently misrouting
fees later.

Both fixes are small, targeted, and change no stored data — they only add new checks. The production
deployment planned for Friday 25 September 2026 can include them as-is.

## What was done, per queue item

**1. Recipient check (HP-11).** Added `test/RecipientAndRegistryChecks.t.sol` with five tests adapted
from the review's proof-of-concept (`test_CG6_recipientSetToTheLockerTrapsTheShareForGood`): launching
with the locker as the creator recipient, launching with the registry as the creator recipient, changing
an existing recipient to the locker, changing one to the registry, and a sanity check that an ordinary
recipient still works both ways. Run against the unmodified contract, four of the five failed with `[FAIL:
next call did not revert as expected]` — the old code let all four dangerous cases through. The fix adds
one new error, `HydropumpLocker.InvalidCreatorRecipient`, and one internal check,
`_requirePayableRecipient`, called from both `registerLaunch` (the launch-time path) and
`setCreatorRecipient` (the later-change path), so both entry points are covered by a single check rather
than two copies of it. After the fix, all five tests pass. Committed as `c97e2b4`.

**2. Registry check (HP-08).** Added three more tests to the same file, adapted from
`test_CG10_divergentRegistriesIgnoreTheCreatorsChoice`: pointing the launcher and the locker at different
registries and confirming a launch now fails; confirming a launch still succeeds and the creator's choice
is respected when the two registries match (today's normal case); and confirming a launch still succeeds
when neither registry has ever been set at all (both `address(0)`), which is today's behaviour for a
brand-new, not-yet-configured pair of contracts. Run against the unmodified contract, only the
mismatched-registries test failed, as expected — the other two already passed, confirming what today's
code does before touching anything. The fix adds a getter, `feeUseRegistry()`, to the `IHydropumpLocker`
interface (the locker already exposed this publicly; the interface just hadn't caught up), and a new
error, `HydropumpLauncher.FeeUseRegistryMismatch`, checked at the very start of `launch()`. After the fix,
all eight tests in the file pass. Committed as `0ce41b5`.

One existing test, `test_LaunchingStillWorksWithNoEscrowSet` in `test/HydropumpLauncher.t.sol`, broke
under the new check and needed rewriting rather than just patching around. It had been testing that a
launcher with no registry set could still launch, even while the locker already had one configured — but
that is exactly the registry-divergence trap this fix closes (HP-08): the launcher would go on to launch
without ever writing the creator's choice anywhere, silently falling back to the locker's own default. Per
this repo's rule against weakening a test to make it pass, the test was renamed
`test_ZeroingOnlyTheLaunchersEscrowNowRevertsAsADivergence` and now asserts the safe behaviour: that
launch reverts. This was included in the same commit as the registry-mismatch fix (HP-08).

**3. Gates and fork suite.** All local gates pass on the final state: `forge build --sizes`, `npm run
test:unit` (235/235), `npm run fmt:check`, and `npm run check:storage-snapshots`. The full fork suite
(`npm run test:fork:strict`, excluding the three known-failing tests below) passed 57/57 against live
Base, nothing skipped. No fixture wiring broke — see "Deploy and fixture wiring order" below.

## Verified vs. assumed

**Verified, by running it:**
- Each new test fails on the unmodified contract with the specific assertion named above, and passes
  after its matching fix (the "fail, fix, pass" sequence, logged in `RUN-LOG.md` as it happened).
- The full unit suite (235/235) and the fork suite (57/57, excluding the three known failures) both pass
  on the final, committed state.
- `forge build --sizes`, `npm run fmt:check`, and `npm run check:storage-snapshots` all pass; the storage
  check was re-confirmed after `forge clean` since a stale build cache briefly made it fail spuriously —
  that failure was an artifact of a partial rebuild, not a real storage change.
- The three fork tests the work order names as pre-existing, unrelated failures fail with the same
  messages on the unmodified branch as the baseline `npm run test:fork:strict` run at the start of this
  session (before either fix), and are excluded by name from the suite the "Done when" list checks.
- An independent `code-reviewer` agent reviewed the finished diff, ran the same gates itself, and also
  independently reproduced the red-phase failure by dropping the new test file into a throwaway worktree
  against unmodified `main` and confirming it doesn't compile against the unfixed `HydropumpLocker` (the
  new error doesn't exist yet there). Verdict: **approve with nits**, nothing above Low.

**Assumed, not independently re-verified beyond reading the code:**
- That the deploy script's and both fixtures' wiring order never launches between setting the launcher's
  registry and the locker's — see the next section for what was actually read to support this.
- That the reviewer's one Low finding (see below) is correctly scoped as already out of scope per the
  work order, rather than something to fix now.

## Tests changed

- `test/HydropumpLauncher.t.sol`: `test_LaunchingStillWorksWithNoEscrowSet` →
  `test_ZeroingOnlyTheLaunchersEscrowNowRevertsAsADivergence`. It asserted the old, now-unsafe behaviour
  (a launcher with an unset registry launching anyway, while the locker's registry stayed set from
  `setUp`) and now asserts the new revert. No other existing test's assertions were changed.

## Upgrade impact

Both `HydropumpLauncher` and `HydropumpLocker` need new implementation contracts deployed and upgraded to,
since both had logic changes (`launch()` gained a check; `registerLaunch()` and `setCreatorRecipient()`
gained a check). `FeeUseRegistry` and `PairDirectory` are unchanged.

**Storage: unchanged.** Neither fix adds, removes, or reorders any state variable; both `__gap` arrays are
untouched. `npm run check:storage-snapshots` passes against the existing v1.0.0 snapshots for all four
proxied contracts, confirmed after a clean rebuild.

**Deploy and fixture wiring order.** The main risk the work order flagged was that the new registry check
could break a deploy or fixture sequence that sets the launcher's registry and the locker's registry in
two separate steps, if anything tried to launch in between. I read `script/deploy/DeployHydropump.s.sol`
end to end: it calls `locker.setFeeUseRegistry(...)` and then `launcher.setFeeUseRegistry(...)`
back-to-back (lines 116–117), and the script never calls `launch()` itself — launching only happens later,
once both are already set. `test/helpers/HydropumpFixture.sol` and `test/fork/helpers/ForkFixture.sol`
both do the same: both `setFeeUseRegistry` calls happen in `setUp()`, before any test's `_launch(...)`
call runs. Nothing in the deploy script or either fixture needed changing, and the full fork suite passing
end to end is consistent with that reading. This is a reading of the script and the two fixtures, not a
transaction sent against a deploy — the work order asked to read-only report on this, not to broadcast.

## What was parked

Nothing. No fork came up that needed parking; both queue items and the gates ran straight through.

## What it cost

Wall clock: **0 h 36 min**, from the `runlog COST` line. Model spend: **$0.00** — no paid API calls or
subagents on a paid provider were used; the `code-reviewer` agent ran on this same session's model.

## What I'd do next, ranked

1. **Nothing is required before Friday's deployment.** Both fixes are complete, tested, and reviewed.
2. Consider the reviewer's one Low finding as a follow-up, not a blocker: `_requirePayableRecipient` in
   `HydropumpLocker.sol` blocks the locker and the registry as a recipient, but not the three fee-use
   implementation contracts (`CreatorBalanceFeeUse`, `AutoLpFeeUse`, `BuybackBurnFeeUse`) themselves. The
   same trap-forever mechanism applies if a recipient is set to one of those addresses directly. This is
   explicitly the work order's own out-of-scope item ("Fee-use contracts as recipients are not in scope:
   the registry has no reverse lookup, and adding one is a design change"), so it wasn't touched here — but
   it's worth a deliberate decision later rather than staying an unwritten gap.
3. The reviewer also flagged, as a documentation nit rather than a defect, that three `@dev` NatSpec
   comments describe the exact mechanics of the fund-trap the new guards now make unreachable, without a
   test directly exercising that mechanism (the guards themselves are fully tested; the comments explain
   *why* the guard exists). Worth a look if anyone wants the comments to say "verified by reading the code
   path" rather than reading as an asserted, tested fact.

## Where I was wrong during the run

The registry-check "both unset" test (`test_HP08_bothRegistriesUnsetStillLaunches`) needed a completely
fresh locker/launcher pair deployed inside the test, rather than reusing the shared fixture's `locker` and
`launcher`: once `HydropumpLocker.setFeeUseRegistry` has been called once (as the fixture's `setUp()`
always does), it can never be set back to `address(0)` — the setter rejects the zero address — so the
"never configured" state can only exist on a pair that has never had the setter called at all. I saw this
before writing the test rather than after a failed run, but it's worth naming because the first instinct
was to try to zero out the shared fixture's locker registry, which is not something the contract allows.

The `npm run check:storage-snapshots` check failed once, right after the registry-mismatch fix (HP-08),
with `forge inspect failed: storage layout missing from artifact`. That looked like a real storage problem
for a moment. It
was a stale build-artifact cache from an interrupted intermediate build, not a real layout change — a
`forge clean` and rebuild made it pass cleanly, and neither contract's storage actually changed (confirmed
by inspecting the diff: no new state variables, `__gap` untouched in both files).

## Details

**Commits on this branch:**
- `c97e2b4` — `fix(locker): reject the locker and the registry as a creator recipient (HP-11)`
- `0ce41b5` — `fix(launcher): require the locker's fee-use registry to match the launcher's (HP-08)`

**New errors:**
- `HydropumpLocker.InvalidCreatorRecipient()` — reverts in `registerLaunch` and `setCreatorRecipient` when
  the recipient is the locker itself or its `feeUseRegistry`.
- `HydropumpLauncher.FeeUseRegistryMismatch()` — reverts in `launch()` when the launcher's own
  `feeUseRegistry` differs from `IHydropumpLocker(locker).feeUseRegistry()`.

**Interface change:** `IHydropumpLocker` gained `feeUseRegistry() external view returns (address)`,
matching the public state variable `HydropumpLocker` already exposed.

**Test file:** `test/RecipientAndRegistryChecks.t.sol` (new), 8 tests — 5 for the recipient check
(HP-11), 3 for the registry check (HP-08) — plus one rewritten test in `test/HydropumpLauncher.t.sol`.

**Known fork failures, unrelated to this change and excluded by name from the "Done when" fork run, both
before and after the fix, with the same messages both times:**
- `test_LaunchPoolsAreNotGaugedOnEitherSide` — `launch pools must keep fees with the LP: 15 != 0`
- `test_TheDevBuyFillsInTheSameTransactionOnBothSides` — `quote landed in the pool: 49999925000000000 !=
  50000000000000000`
- `test_StakesTheWholeLpBalance` — `LP is neither held nor staked: 0 <= 0`

**Gate results on the final state:**
- `forge build --sizes` — clean; `HydropumpLauncher` 15,034 B runtime / 9,542 B margin,
  `HydropumpLocker` 10,841 B runtime / 13,735 B margin, both comfortably under the 24,576 B limit.
- `npm run test:unit` — 235/235 pass.
- `npm run fmt:check` — clean.
- `npm run check:storage-snapshots` — all four snapshots (`FeeUseRegistry`, `HydropumpLauncher`,
  `HydropumpLocker`, `PairDirectory`) pass unchanged.
- `npm run test:fork:strict -- --no-match-test '...'` — 57/57 pass against Base (chain id 8453), nothing
  skipped.

**Note on `origin/main` during this run:** while this branch was in progress, `origin/main` moved ahead by
three commits (PR #12, `d52dc89`), one of which appears to address the
`test_LaunchPoolsAreNotGaugedOnEitherSide` / community-fee failure named above. This branch was not
rebased onto that — the work order scoped this run to its own branch and named those three failures as
"not yours to fix" — so they're still reported here as failing on this branch, matching what the work
order described. Whoever merges this PR may want to rebase first to pick up that fix.
