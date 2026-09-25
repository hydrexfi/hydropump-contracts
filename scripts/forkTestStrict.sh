#!/usr/bin/env bash
# Run the fork suites and fail unless they really forked.
#
#   forkTestStrict.sh [--slow] [forge args...]
#
# Default: every suite under test/fork/ except test/fork/slow/. With --slow: only test/fork/slow/,
# the suites too long to run on every PR (see .github/workflows/fork-slow.yml).
#
# Without a working BASE_RPC_URL every fork test skips instead of failing, so `forge test` exits 0
# having tested nothing. This wrapper fails when:
#   - BASE_RPC_URL does not answer as Base (chain id 8453), or
#   - forge exits non-zero (a test failed), or
#   - any test was skipped.
#
# Exit codes: 0 pass, 1 a test failed or nothing ran, 3 every failure was the RPC (a timeout, a rate
# limit or a dropped connection) rather than the code. The RPC URL is redacted from the output.
#
# Extra arguments are passed to forge, e.g. `npm run test:fork:strict -- --no-match-test 'test_Foo'`.
# Foundry reads .env itself; this script sources it too so the chain-id check sees the same URL.
set -euo pipefail

cd "$(dirname "$0")/.."
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

paths=(--match-path 'test/fork/*' --no-match-path 'test/fork/slow/*')
if [ "${1:-}" = "--slow" ]; then
  paths=(--match-path 'test/fork/slow/*')
  shift
fi

if [ -z "${BASE_RPC_URL:-}" ]; then
  echo "BASE_RPC_URL is not set (put a private Base RPC URL in .env)." >&2
  exit 1
fi

chain_id="$(cast chain-id --rpc-url "$BASE_RPC_URL")"
if [ "$chain_id" != "8453" ]; then
  echo "BASE_RPC_URL answered chain id '$chain_id', expected 8453 (Base)." >&2
  exit 1
fi

output_file="$(mktemp)"
trap 'rm -f "$output_file"' EXIT

set +e
forge test "${paths[@]}" "$@" 2>&1 | perl -pe 's/\Q$ENV{BASE_RPC_URL}\E/<BASE_RPC_URL>/g' | tee "$output_file"
forge_status=${PIPESTATUS[0]}
set -e

if [ "$forge_status" -ne 0 ]; then
  # Forge lists each failing test as "[FAIL: <reason>] <name>" in its run and again in its summary.
  failures="$(grep -E '^\[FAIL' "$output_file" | sort -u || true)"
  rpc_pattern='timed out|429|too many requests|rate.?limit|compute units|database error|error sending request|connection (reset|refused|closed)'
  total="$(grep -c . <<<"$failures" || true)"
  rpc="$(grep -Eic "$rpc_pattern" <<<"$failures" || true)"

  if [ "$total" -gt 0 ] && [ "$rpc" -eq "$total" ]; then
    message="Fork tests failed because the RPC throttled or timed out ($rpc failing), not because of the code. Re-run, or raise FOUNDRY_ETH_RPC_TIMEOUT."
    [ "${GITHUB_ACTIONS:-}" = "true" ] && echo "::error title=RPC throttled::$message"
    echo "$message" >&2
    exit 3
  fi

  echo "Fork tests failed (forge exit $forge_status)." >&2
  if [ "$rpc" -gt 0 ]; then
    echo "$rpc of the $total failures were RPC errors; the rest are real test failures." >&2
  fi
  exit "$forge_status"
fi

# Forge says "test suite" for one suite and "test suites" for several.
summary="$(grep -E '^Ran [0-9]+ test suites?' "$output_file" | tail -1)"
if [ -z "$summary" ]; then
  echo "Could not find forge's summary line; refusing to report a pass." >&2
  exit 1
fi
if ! grep -Eq ' 0 skipped' <<<"$summary"; then
  echo "Fork tests were skipped, so they did not all run: $summary" >&2
  exit 1
fi
echo "Fork tests ran against Base with nothing skipped: $summary"
