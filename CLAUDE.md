# Hydropump contracts — guidance for Claude sessions

Hydropump is a permissionless token launchpad on Hydrex (Base). The launcher deploys a token, opens its
Algebra pool against a whitelisted quote token and mints single-sided liquidity bands; the locker holds
those position NFTs forever and splits their trading fees between the creator (spent through a fee use:
creator balance, buyback-and-burn or auto-LP) and the protocol. `README.md` describes the design.

Findings labelled `HP-01` … `HP-23` refer to the internal security review of 23 September 2026
(commit `24eb16c`). A work order or PR that fixes one names it in brackets after a plain description.

## Commands (run from the repo root)

| What | Command |
| --- | --- |
| Install | `npm ci` (OpenZeppelin comes from `node_modules`; forge-std is a git submodule) |
| Build and size check | `forge build --sizes` |
| Unit tests | `npm run test:unit` |
| Fork tests | `npm run test:fork:strict` — needs `BASE_RPC_URL`; fails if the RPC is not Base or any test skips (see below) |
| Format check | `npm run fmt:check` (fix with `forge fmt`) |
| Storage layouts | `npm run check:storage-snapshots` |

CI (`.github/workflows/ci.yml`) runs build, unit, format and storage checks on every PR. It does **not** run
the fork tests yet (the public RPC rate-limits them; a private one needs an admin-set secret), so run
`npm run test:fork:strict` locally before pushing any change under `contracts/`.

**Fork tests do not fail without an RPC.** When `BASE_RPC_URL` is unset, every fork suite marks its
tests skipped (`vm.skip`), so a run can finish green having tested nothing. Each suite has its own guard;
five of the nine share `test/fork/helpers/ForkFixture.sol`. Foundry loads `.env` automatically. The public
endpoint in `.env.example` is rate-limited too hard for the full fork suite; put a private RPC URL in
`.env` (never in `.env.example`, which is tracked). `npm run test:fork:strict` refuses to pass
unless the RPC answers as Base (chain id 8453) and nothing was skipped; use it rather than `test:fork`
whenever the result matters.

## Upgradeable contracts and storage

`HydropumpLauncher`, `HydropumpLocker`, `PairDirectory` and `FeeUseRegistry` sit behind UUPS proxies.
For any change that adds, removes or reorders their storage:

1. Append new variables after the existing ones and shrink `__gap` by exactly the slots consumed.
2. Add a new snapshot at a bumped version:
   `forge inspect <path>:<Contract> storage --json > artifacts-storage/storage_layout_<Contract>_v<x.y.z>.json`
3. Note the gap change in the commit subject, e.g. `(__gap 46->45)`, and explain it in the PR.

Never edit an existing snapshot file. Constants, immutables and transient storage take no slots.

## Never, in any session

- Broadcast a transaction. Do not run `npm run deploy:*`, `quotes:register:base`, `quotes:refresh:base`,
  `stake:gauge:base`, or any `forge script … --broadcast`.
- Put a private key in `.env` of a worktree that an unattended session uses. `DEPLOYER_KEY` stays empty.
- Change a test's assertion to make it pass. A test that asserted the old, unsafe behaviour is rewritten
  to assert the safe behaviour, and the PR says so.

## How a fix is made

- **Fail, fix, pass.** Write the test that reproduces the defect first, see it fail on the unfixed code,
  then fix. Record both results in the PR.
- State the function's precondition, postcondition or invariant in NatSpec where the fix changes it,
  to the standard below. Change only the lines the fix needs: never rewrite or expand a comment it
  does not require. In `contracts/`, comment lines added should not outgrow code lines added; longer
  explanation belongs in the PR body.
- One finding per commit, with its own test.
- Commits follow Conventional Commits: `type(scope): subject`, imperative, lowercase, ≤ 72 characters.
  Security-relevant commits say so. A `fix` body names the defect class and how many sites have it.

## Comments and NatSpec

Say each fact once, in the place that owns it. Audit and finding IDs, design history, alternatives
considered and test provenance ("adapted from the review's test_CG6") go in the commit message and
the PR body, never in the code.

- **External and public functions:** a one-sentence `@notice` saying what it does for a caller.
- **`@dev`, only when needed:** preconditions, what it reverts on, who gets paid, trust assumptions.
  Short bullets, one line each, usually 0–4 lines in total.
- **`@param` and `@return`:** only where the name and type do not already say it — units, bps,
  "0 means skip".
- **Contract-level `@dev`:** state the key invariants once and number them (I1, I2…). Elsewhere write
  "relies on I1" rather than restating one.
- **Internal and private functions:** no NatSpec by default. One line only if it carries an invariant.
- **Inline comments:** why, not what, in one line. Use them for non-obvious ordering or arithmetic;
  OpenZeppelin requires one on every `unchecked` block.
- **Tests:** the test name is the specification. Comment only where the setup is non-obvious.

Worked example. `deliverProtocolShareFromSelf` carried nine lines of NatSpec; one line drops the
precondition that makes the function necessary. The standard gives three:

```solidity
/// @notice Deliver the protocol share from inside `handleAllRewards`' try block.
/// @dev Requirements: the caller is this contract, and the reentrancy guard is held.
///      `try` needs an external call, and `deliverProtocolShare` would hit the held guard.
```

## Definition of done

- `forge build --sizes`, `npm run test:unit`, `npm run fmt:check` and `npm run check:storage-snapshots`
  pass; `npm run test:fork:strict` passes when a contract under `contracts/` changed.
- New or changed behaviour has a test that would fail without the change.
- The `code-reviewer` agent has reviewed the diff and nothing above LOW is left unaddressed.
- The PR body says what changed, why, the risk (including any upgrade or redeploy step) and the tests.
