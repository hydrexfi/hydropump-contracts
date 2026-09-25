# Per-launch keeper buybacks

This affects the creator's launch-token buyback-and-burn only. The protocol HYDX buyback,
protocol fee conversion, creator-balance strategy and Auto-LP remain unchanged.

## Setup and execution

1. Register `KeeperBuybackBurnFeeUse(locker, votingEscrow)` as the `BUYBACK_BURN` implementation.
   The deployment script does this for new deployments using Base's production veHYDX proxy.
2. Launch with `FeeUses.BUYBACK_BURN` (or have governance repoint an existing launch).
3. The original launch creator calls `configureBuyback(token, bountyBps)` on that implementation.
   Choose 250 for 2.5%; 0–9,900 is accepted. Setup is write-once per token, with no implicit rate.
   At the 99% maximum, a fully executed allocation pays 99% to the keeper and uses only 1% for the
   buyback. Creators should choose this rate carefully; it cannot be changed after setup.
   The creator recipient is not automatically authorized to configure someone else's launch.
4. A keeper calls `locker.executeKeeperBuyback(token, veTokenId)`. It collects fees and executes
   the buyback atomically. The caller must own that NFT and its current `balanceOfNFT` must be positive.
   Approvals and delegated votes do not qualify. There is no holding-age or minimum-power threshold.
   Smart-contract NFT owners may execute; the bounty goes to that contract, not `tx.origin`.

The old `spendCreatorShare`, `handleCreatorRewards` and `handleAllRewards` calls cannot execute
this strategy: its ordinary `onFees` callback reverts. Frontends and automation must use the new
entry point. Fee collection (`splitRewards`) and protocol-only processing remain available.
An empty creator allocation is a no-op and never earns a reward.

## Bounty accounting

The reward is paid in the paired token from the creator's quote allocation, not from protocol fees,
existing launch-token fees or donations. For a 1,000-unit budget at 250 bps, reserve 25 and offer 975
to the swap. If all 975 fills, the keeper receives 25. All bought launch tokens are still burned.

For a partial fill, pay `floor(actualQuoteSpent * bps / (10000 - bps))`, capped by the reserved amount.
Return the unused swap budget and unused bounty reserve to the locker, which rebooks them to the
same launch. Calculations round down. No output, a skipped swap, an unusable oracle or a token-only
burn pays no bounty. This preserves the existing price guard and launch-tax handling; it does not
fix or expand their protections. The existing oracle getter revert edge case can still revert execution.

Invariant: quote spent + keeper bounty + returned quote = current quote allocation.
Splitting calls adds no flat payout or minimum bounty; each reward is tied to actual executed input.
There is no dollar-denominated cap. NFT ownership is eligibility, not a guarantee against MEV;
keepers can compete for calls and eligible callers still face the existing sandwich risk.

## Existing deployments

Upgrade the locker implementation (no storage layout change), deploy the keeper strategy, then
use `FeeUseRegistry.replaceFeeUse` to replace the `BUYBACK_BURN` implementation. Each creator must
configure its token on the new implementation before execution. An unconfigured strategy fails closed
and leaves fees booked. Configuration and `lifetimeBurned` are local to the new non-upgradeable
implementation; old counters remain on the old address. Plan this migration with the frontend.

The legacy `BuybackBurnFeeUse` remains as the reusable swap/burn base and for legacy deployments;
it is not the strategy registered by the updated deployment script. Until governance replaces an
existing registry entry, that deployment retains its old permissionless behavior.
