#!/usr/bin/env bash
# Run the fork suites and fail unless they really forked.
#
# Without a working BASE_RPC_URL every fork test skips instead of failing, so `forge test` exits 0
# having tested nothing. This wrapper fails when:
#   - BASE_RPC_URL does not answer as Base (chain id 8453), or
#   - forge exits non-zero (a test failed), or
#   - any test was skipped.
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
forge test --match-path 'test/fork/*' "$@" 2>&1 | tee "$output_file"
forge_status=${PIPESTATUS[0]}
set -e

if [ "$forge_status" -ne 0 ]; then
  echo "Fork tests failed (forge exit $forge_status)." >&2
  exit "$forge_status"
fi

summary="$(grep -E '^Ran [0-9]+ test suites' "$output_file" | tail -1)"
if [ -z "$summary" ]; then
  echo "Could not find forge's summary line; refusing to report a pass." >&2
  exit 1
fi
if ! grep -Eq ' 0 skipped' <<<"$summary"; then
  echo "Fork tests were skipped, so they did not all run: $summary" >&2
  exit 1
fi
echo "Fork tests ran against Base with nothing skipped: $summary"
