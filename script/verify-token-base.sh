#!/usr/bin/env bash
# Verify a HydropumpToken (launchpad-created ERC20) on Base mainnet.
# Usage: source .env && ./script/verify-token-base.sh TOKEN_ADDRESS [LAUNCHPAD_ADDRESS]
# LAUNCHPAD_ADDRESS falls back to $LAUNCHPAD_ADDRESS from .env.

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

TOKEN_ADDRESS="${1:?Usage: $0 TOKEN_ADDRESS [LAUNCHPAD_ADDRESS]}"
LAUNCHPAD="${2:-${LAUNCHPAD_ADDRESS:?Pass LAUNCHPAD_ADDRESS as arg 2 or set it in .env}}"

# The launchpad mints the whole supply to itself, so it is the sole constructor recipient.
DEFAULT_SUPPLY=$(cast call "$LAUNCHPAD" "DEFAULT_SUPPLY()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')
NAME=$(cast call "$TOKEN_ADDRESS" "name()(string)" --rpc-url "$RPC_URL" | unquote)
SYMBOL=$(cast call "$TOKEN_ADDRESS" "symbol()(string)" --rpc-url "$RPC_URL" | unquote)

ARGS=$(cast abi-encode "constructor(string,string,address[],uint256[])" "$NAME" "$SYMBOL" "[$LAUNCHPAD]" "[$DEFAULT_SUPPLY]")

echo "Verifying HydropumpToken '$NAME' ($SYMBOL) at $TOKEN_ADDRESS..."
verify "$TOKEN_ADDRESS" "contracts/HydropumpToken.sol:HydropumpToken" "$ARGS"

echo "Submitted. Check https://basescan.org/address/$TOKEN_ADDRESS#code"
