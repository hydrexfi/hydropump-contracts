#!/usr/bin/env bash
# Shared config for the Hydropump verification scripts on Base mainnet.
# Etherscan V2 API (V1 deprecated). Base = chainid 8453.

set -euo pipefail

CHAIN_ID=8453
RPC_URL="${BASE_RPC_URL:-https://mainnet.base.org}"
VERIFIER_URL="https://api.etherscan.io/v2/api?chainid=${CHAIN_ID}"

if [ -z "${BASESCAN_API_KEY:-}" ]; then
  echo "BASESCAN_API_KEY not set. Source .env or export it." >&2
  exit 1
fi

# Strip the surrounding quotes cast puts around decoded strings
unquote() { sed -e 's/^"//' -e 's/"$//'; }

verify() { # verify ADDRESS CONTRACT_PATH CONSTRUCTOR_ARGS
  forge verify-contract \
    "$1" \
    "$2" \
    --chain-id "$CHAIN_ID" \
    --verifier etherscan \
    --verifier-url "$VERIFIER_URL" \
    --etherscan-api-key "$BASESCAN_API_KEY" \
    --constructor-args "$3"
}
