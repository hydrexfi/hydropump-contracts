#!/usr/bin/env bash
# Verify a HydropumpLocker (per-launch LP locker) on Base mainnet.
# Usage: source .env && ./script/verify-locker-base.sh LOCKER_ADDRESS
# The constructor arg is read back off-chain from the locker itself.

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

LOCKER_ADDRESS="${1:?Usage: $0 LOCKER_ADDRESS}"

OWNER=$(cast call "$LOCKER_ADDRESS" "owner()(address)" --rpc-url "$RPC_URL")
ARGS=$(cast abi-encode "constructor(address)" "$OWNER")

echo "Verifying HydropumpLocker at $LOCKER_ADDRESS (owner: $OWNER)..."
verify "$LOCKER_ADDRESS" "contracts/HydropumpLocker.sol:HydropumpLocker" "$ARGS"

echo "Submitted. Check https://basescan.org/address/$LOCKER_ADDRESS#code"
