#!/usr/bin/env bash
# Verify both halves of a launch — the HydropumpToken and its HydropumpLocker — on Base mainnet.
# Usage: source .env && ./script/verify-launch-base.sh TOKEN_ADDRESS LOCKER_ADDRESS [LAUNCHPAD_ADDRESS]

set -euo pipefail

TOKEN_ADDRESS="${1:?Usage: $0 TOKEN_ADDRESS LOCKER_ADDRESS [LAUNCHPAD_ADDRESS]}"
LOCKER_ADDRESS="${2:?Usage: $0 TOKEN_ADDRESS LOCKER_ADDRESS [LAUNCHPAD_ADDRESS]}"
DIR="$(dirname "${BASH_SOURCE[0]}")"

"$DIR/verify-token-base.sh" "$TOKEN_ADDRESS" "${3:-}"
"$DIR/verify-locker-base.sh" "$LOCKER_ADDRESS"

echo "Done."
