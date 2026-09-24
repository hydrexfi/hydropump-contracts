# Report — distributor allocation fix (issue #9)

> **Superseded in part (24 September 2026, after review).** The `setAllocation` change this report
> describes, making the amount a lifetime total, was replaced. `setAllocation` keeps its original
> meaning, what a recipient can still claim, and now reverts if a call raises what the distributor
> owes above what it holds (`AllocationExceedsBalance`). That closes the review's case, a correction
> after a claim, and a second route to the same shortfall that the lifetime-total design left open:
> an unfunded raise. A call that lowers what is owed is always allowed, so the owner can tidy the
> ledger while the contract is short. The work order had set the lifetime-total design; the session followed it
> correctly. The `setOperator` zero-address fix below is unchanged. The PR body describes the
> current fix.

## What happened, for someone who wasn't here

Hydropump's reward distributor (`HydropumpRewardDistributor.sol`) holds tokens that an operator
has allocated to recipients — for example, weekly reward payouts — until each recipient claims
them. The owner has a function, `setAllocation`, to correct a mistaken allocation. Before this
fix, that function had a bug: if a recipient had already claimed their allocation and the owner
then tried to lower it, the function would instead hand them a fresh top-up equal to the new
number. So an owner trying to reduce someone from 100 to 10 would, after that person had already
claimed their 100, accidentally let them claim another 10 on top. The security review of
23 September 2026 labelled this the reduction-after-claim bug in `setAllocation` (HP-07), rated
Low severity, because it only happens when the owner makes exactly the kind of correction an
honest owner would make.

The fix changes what the numbers passed to `setAllocation` mean. Before, they meant "how much is
still claimable." Now they mean "this recipient's total allocation over the contract's whole
life" — the same idea the contract already used internally to track what someone has claimed
(`lifetimeClaimed`). With that meaning, the function can tell the difference between "lower
someone's future allocation" (fine) and "take back money already paid out" (not fine, so it now
refuses): if the new total is below what the recipient has already claimed, the call reverts
instead of quietly re-crediting them.

A second, unrelated fix went in the same run: `setOperator`, which lets the owner change who is
allowed to write allocations, had no check against the zero address. Setting the operator to the
zero address would have locked out the only address (besides the owner) that can call `allocate`,
so new rewards could no longer be posted. This is the missing zero-address check in `setOperator`
(HP-20), also Low. It now reverts if asked to set the operator to the zero address.

Both fixes are in `contracts/core/HydropumpRewardDistributor.sol`, which is not behind a proxy —
it will simply be redeployed as part of the production deployment planned for Friday 25 September
2026, so this fix needs to make that deployment.

**The one thing that matters for anyone integrating with this contract:** `setAllocation` now
expects lifetime totals, not remaining amounts. See "The changed meaning of `setAllocation`"
below.

## What was done, per queue item

**1. Reproduce the over-promise as a failing test.** Added two tests to
`test/HydropumpRewardDistributor.t.sol`, adapted from the security review's
`test_T4H1_7_claimBeforeAReductionKeepsTheOldAmount`:

- `test_ReductionBelowLifetimeClaimedReverts`: allocate 100, claim it, then `setAllocation` to
  10. Run against the unfixed contract, this failed with `next call did not revert as expected`
  — the old code let the call through and re-credited 10.
- `test_ReductionAboveLifetimeClaimedSetsRemainder`: a recipient allocated 100 in total who has
  claimed 40 is raised to a lifetime total of 150. Run against the unfixed contract, this failed
  with `150000000000000000000 != 110000000000000000000` — the old code set `claimable` to the raw
  input (150) instead of the input minus what was already claimed (110).

Both failures were the expected ones, not compile errors or unrelated breakage.

**2. Fix `setAllocation`.** Added a new custom error, `AllocationBelowLifetimeClaimed()`, and
rewrote the function: it now reverts with that error if `amounts[i] < lifetimeClaimed[recipient][token]`,
and otherwise sets `claimable` to `amounts[i] - lifetimeClaimed[recipient][token]`. `totalOwed`
still moves by the change in `claimable`, exactly as before — that arithmetic did not need to
change. NatSpec on the function now states the precondition (`amounts[i] >= lifetimeClaimed`) and
postcondition (`claimable + lifetimeClaimed == amounts[i]`). Both new tests, the 17 pre-existing
tests in the same file, and the full 229-test unit suite passed afterward.

**3. Zero-address check in `setOperator`.** Added `test_SetOperatorRejectsZeroAddress`
(confirmed red on the unfixed function: `next call did not revert as expected`), then added
`if (newOperator == address(0)) revert ZeroAddress();` before the existing state write. All 19
tests in the file and the 230-test unit suite (one more than before, from this test) pass.

## Verified versus assumed

**Verified**, by running the commands myself:
- `forge build --sizes` compiles clean; only pre-existing, unrelated lint warnings in
  `test/helpers/HydropumpFixture.sol` (unsafe-typecast) and `test/mocks/MockAlgebra.sol`
  (erc20-unchecked-transfer), neither touched by this change.
- `npm run test:unit` — 230 tests pass, 0 fail, 0 skipped.
- `forge test --match-contract HydropumpRewardDistributorTest` — 19 tests pass.
- `npm run fmt:check` — clean.
- `npm run check:storage-snapshots` — all 4 tracked proxy contracts' layouts still match (the
  distributor isn't one of them; it holds no proxy storage to snapshot).
- `grep -rn "setAllocation"` across the repo (excluding `node_modules` and `lib/`) finds only the
  function definition and 5 call sites, all in the test file — nothing else in this repo calls it.
- `grep -rn "function setOperator"` finds one other contract with the same missing-check shape,
  `HydropumpBuyback.sol:128` — untouched, out of scope for this work order.
- The `code-reviewer` agent independently re-ran the test suite and format check rather than
  trusting my claims, and reviewed the diff. Verdict: **APPROVE WITH NITS**, nothing above LOW.
  Its one nit (a redundant assertion in `test_ReductionBelowLifetimeClaimedReverts` that's
  trivially true given the two assertions right above it) doesn't meet the work order's
  above-LOW bar for action, so I left it as-is.

**Assumed / not run:** the fork test suite (`npm run test:fork:strict`). The work order's settled
decisions say the distributor has no fork tests and needs none, and a repo-wide search confirms
no fork suite under `test/fork/` references `HydropumpRewardDistributor`. I did not run
`test:fork:strict` for this change; I trusted that settled decision rather than re-verifying it
against the general CLAUDE.md rule that would otherwise require it for any change under
`contracts/`.

## Tests changed

None. All 18 pre-existing tests in `test/HydropumpRewardDistributor.t.sol` pass unmodified.
None of them called `setAllocation` after a `claim()` on the same recipient, so none of them
exercised (or asserted) the old, unsafe behaviour — the bug was real but untested until now.

## The changed meaning of `setAllocation`, and who must know

Before this fix, calling `setAllocation(token, [alice], [10e18])` meant "alice can now claim
10e18." After this fix, it means "alice's lifetime allocation of this token is 10e18 in total" —
if alice already claimed more than that, the call now reverts instead of silently doing something
else.

Nothing else in this repository calls `setAllocation` (verified above). But if any off-chain
system — the backend Garrett runs — calls this function with "how much is left to give this
person" rather than "this person's total ever," it will now under-allocate recipients who have
already claimed something, or the call will revert outright once someone has claimed more than
the new number. **Garrett needs to check whether the backend calls `setAllocation`, and if so,
switch it to pass lifetime totals before this contract is redeployed on 25 September 2026.**

I did not add a flag or second function to preserve the old meaning: the work order says plainly
that doing so to avoid this off-chain-caller risk should be parked, not built, and I found no
in-repo caller that would need it.

## What was parked

Nothing. The queue ran straight through slices 1, 2 and 3 without a fork.

## What it cost

Wall clock: **0 h 41 min** (from the `RUN-LOG.md` `START`/`COST` lines). Model spend: **$0.00** —
no paid APIs or subagents were used beyond this session's own reasoning; the `code-reviewer`
review ran on this session's own allowance, per the work order's spend rule.

## What I'd do next, ranked

1. **Tell Garrett** about the `setAllocation` meaning change (above) before Friday's deployment —
   this is the one risk that actually matters here.
2. **HydropumpBuyback.sol:128** has the same missing-zero-address-check shape in its own
   `setOperator` as the one just fixed here (HP-20). It's a different contract and out of scope
   for this work order, but worth its own small fix if the review didn't already flag it there
   under a different HP number.
3. Nothing else — the code-reviewer's one nit is cosmetic and doesn't change behaviour or
   coverage in a way worth a follow-up.

## Where I was wrong during the run

- My first commit message for the `setAllocation` lifetime-total fix (HP-07) stated "ten sites in
  this repo call setAllocation" without having actually searched for it — a number I made up
  rather than derived, which is
  exactly what `CLAUDE.md`'s commit-hygiene rule (take the count from a search, not from the
  flagged line) exists to prevent. I caught this before pushing, ran `grep -rn "setAllocation"`,
  found 5 call sites (all tests, not "ten" of anything), and amended the not-yet-pushed commit
  with a corrected message before moving on.
- While waiting for the `code-reviewer` agent's background result, I mistakenly made a second,
  empty `Agent` call ("placeholder") trying to yield my turn while waiting for its notification.
  It did nothing (no prompt to act on) and caused no repo changes, but it was an unnecessary
  tool call I should not have made — I should have just stopped and waited for the actual
  notification.

## Details

**Files changed:**
- `contracts/core/HydropumpRewardDistributor.sol` — `setAllocation` (HP-07) and `setOperator`
  (HP-20).
- `test/HydropumpRewardDistributor.t.sol` — 3 new tests, 0 modified.

**Commits on `fix/distributor-allocation-total`** (ahead of `origin/main`):
- `d1cceab` — `fix(distributor): setAllocation sets lifetime total, not remaining claimable`
- `e0555bf` — `fix(distributor): reject the zero address in setOperator`

**New custom error:** `AllocationBelowLifetimeClaimed()` — no arguments, matching the existing
error style in this contract (`ZeroAddress()`, `LengthMismatch()`, `NothingAllocated()`).

**`AllocationSet` event:** its `amount` field still carries the post-subtraction `claimable`
value (consistent with `previous`, which was always a `claimable`-space value), not the raw
lifetime total passed in. The lifetime total remains fully reconstructable off-chain from the
public `lifetimeClaimed` and `claimable` getters, so this preserves the event's existing meaning
rather than changing it.

**Storage:** no new state variables. `HydropumpRewardDistributor` is not behind a proxy and has
no tracked storage snapshot; `npm run check:storage-snapshots` passed unaffected.
