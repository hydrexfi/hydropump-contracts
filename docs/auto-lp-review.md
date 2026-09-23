# Auto-LP review and agreed change

## Finding: permissionless Auto-LP can be sandwiched

Reviewed main commit: `525c355abaafbceef84159ff931b42602b298257`.

The existing Auto-LP route adds creator fees to an active or nearby original launch position at the pool's current spot price. Anyone can trigger the route through `HydropumpLocker.spendCreatorShare(token)`.

An attacker can buy the launch token to move spot, trigger Auto-LP at that manipulated price, and sell the acquired tokens back. The caller does not receive the fees directly; the profit comes from trading against the liquidity deposited between the two swaps.

### Reproduction before the fix

A Base fork test using the real Algebra pool reproduced a profitable sandwich in both token orderings. Fees were generated through real swaps rather than assigning synthetic fee balances.

The setup used 30 buy/sell round trips of 5 WETH, then collected the resulting fees. One observed run produced approximately 0.01125 WETH of creator quote-token credit:

| Scenario | WETH spent | WETH returned | Net WETH before gas |
| --- | ---: | ---: | ---: |
| Buy then sell, without Auto-LP between swaps | 5 | 4.999470245444338193 | -0.000529754555661807 |
| Buy, trigger Auto-LP, then sell | 5 | 5.010471088722469501 | +0.010471088722469501 |

The regression asserts that the attacker cannot make a positive round-trip profit. That assertion failed against the original implementation in both token orderings—the expected **fail** stage of fail–fix–pass testing. Exact outputs depend on fork state.

The local reproduction is `test/fork/MainAutoLpReview.t.sol`, run with:

```sh
BASE_RPC_URL=https://mainnet.base.org forge test --match-path test/fork/MainAutoLpReview.t.sol -vv
```

The test and implementation are still local work in progress and are not included in this documentation-only commit.

## Agreed behavior

The purpose of Auto-LP is to reduce circulating supply and provide paired-token liquidity for users selling the launch token.

- Only the original launch creator may execute Auto-LP for now.
- Burn the launch-token portion of creator fees.
- Deposit only the paired-token portion into a dedicated position in the **same launch pool**.
- Place that position one valid tick-spacing range below the launch token's spot price, so sells can reach it and exchange launch tokens for the paired token.
- Leave the original locked launch positions untouched.
- When refreshing the dedicated position, burn launch tokens it acquired from sellers and redeposit its remaining paired tokens together with new paired-token fees.
- Do not introduce a TWAP or rename the feature “BidWall.”

“Below spot” refers to the launch token's price in the paired token. Algebra's raw tick direction reverses when the launch token changes from token0 to token1. The implementation must handle both orderings and align the range to the pool's tick spacing; it cannot simply subtract one raw tick in every pool.

This supplies an exit while the position has paired-token inventory. It does not guarantee a price floor or unlimited exit liquidity. As sellers consume the position, it becomes launch tokens, which are burned on a subsequent creator execution.

## Additional execution protection under implementation

The draft also accepts an expected pool tick, a maximum tick deviation, and a deadline from the creator. These let the creator reject execution if spot has moved beyond their chosen tolerance before the transaction lands, without introducing a TWAP.

Creator-only execution prevents an attacker from independently triggering Auto-LP. It does **not** make a publicly submitted creator transaction immune to a sandwich, particularly if the creator chooses a loose price tolerance.

## Verification still required

The pre-fix reproduction is complete. Implementation and post-fix verification are not yet complete. Before treating this as a finished fix:

- Confirm outsider execution reverts and the sandwich regression passes in both token orderings.
- Confirm creator execution works and deposits paired tokens only, on the correct side of spot.
- Confirm sellers can consume the new position and acquired launch tokens are burned when it is refreshed.
- Verify the original locked positions remain unchanged.
- Test tick movement, deadlines, negative-tick rounding, one-sided fees, residual balances, and separation between launches sharing the same paired token.
- Run the relevant unit and fork suites and document any integration changes to the creator execution flow.
