# Unattended run contract — read this cold, then start

This file governs **how** an unattended (delegated) Claude Code session behaves in this repo. **What**
it works on is its work order: the GitHub issue that `delegate` hands it, which holds the queue, the
branch and the "Done when" list. `CLAUDE.md` holds the repo's commands and standing rules; everything
there applies too.

**These are settled decisions, not defaults to re-litigate.** If a rule here blocks you, that is the
rule working. Log it and move on; do not reason your way past it.

---

## 1. Settled decisions

| | decision |
|---|---|
| **Model spend** | Zero beyond this session's own reasoning. No paid APIs, no subagents on a paid provider. |
| **Git authority** | Commit freely. Push the feature branch whenever you like, including work in progress. Open the PR. **Never merge. Never push `main`.** Never touch another branch, including other people's open PRs. |
| **Chain authority** | **Read-only.** Fork tests and `cast call` are fine. Never broadcast a transaction, never run a deploy or quote-registration script, never use a private key. |
| **On hitting a fork** | **Park it in writing and continue.** Write the question and both readings to `RUN-LOG.md`, then move to the next queue item. A parked question is never resolved by guessing. Only §5's hard stops end the run. |
| **Scope** | The work order's queue, in order. Do not add work. If the queue empties, stop and write the report. |

---

## 2. Rules for this repo

1. **Run the gates before every commit, including "docs only":**
   ```
   forge build --sizes
   npm run test:unit
   npm run fmt:check
   npm run check:storage-snapshots
   ```
   And `npm run test:fork` before any commit that changes `contracts/`.

2. **A fork test that did not fork proves nothing.** Fork suites skip, or pass silently, without an RPC.
   Before relying on a fork result, check `cast chain-id --rpc-url "$BASE_RPC_URL"` prints `8453`, and
   log that you checked.

3. **Fail, fix, pass — and log all three.** The new test must fail on the unfixed code. Log the failing
   output's key line before you change the contract. A test that would pass against a no-op is not a test.

4. **Never weaken a test to make it pass.** If an existing test asserted the old, unsafe behaviour, rewrite
   it to assert the safe behaviour, and name it in the report under "tests changed".

5. **Storage layout changes follow `CLAUDE.md`** (append, shrink `__gap`, new versioned snapshot). Never
   edit an existing snapshot to make the storage check pass.

6. **Every negative claim names where it looked.** Before writing "there is no other caller" or "nothing
   else uses this", list the searches you ran.

7. **`~/engagements/` is read-only.** Proof-of-concept tests from the security review live there; copy
   and adapt them into `test/`, never edit them in place.

---

## 3. Logging — write as you go, not at the end

Log with `runlog <KIND> <text>` from the worktree root, one line per step, as it happens. Never edit
`RUN-LOG.md` directly. Kinds:

```
START  <item> — <what, in one line>
DONE   <item> — <result, including the number that matters>
PARK   <item> — <the question, and both readings>
NOTE   <anything surprising, including your own errors>
```

Commit the log with the work it describes. Rich follows it with `tail -F RUN-LOG.md`.

---

## 4. The report

The work order names the file (`RUN-REPORT-<slug>.md`). Commit it last; nothing may be committed after it.

- **What was done**, per queue item: the defect, the fix, and the test that failed before and passes after.
- **Verified vs. assumed**, explicitly separated.
- **Tests changed**: any existing test whose assertion was rewritten, and why.
- **Upgrade impact**: which contracts need a new implementation, and whether storage changed.
- **What was parked**, with the question and why it was not resolved.
- **Where you were wrong during the run.** Not optional; "nothing" only if true.

Write for a reviewer who has not seen the work order: the claim first in plain words, then the evidence.

---

## 5. Hard stops — end the run and write the report

- A queue item would need model spend, a write outside this worktree, a merge, or a chain transaction.
- A test fails that you did not cause and cannot explain.
- A committed, load-bearing document is wrong (`README.md`, `CLAUDE.md`, this file, NatSpec a fix relies
  on): correct it, commit, keep going, and say so loudly in the report.
- Two consecutive queue items park without progress.
