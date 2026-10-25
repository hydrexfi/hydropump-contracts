// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

import {HydropumpLauncher} from "../../../contracts/core/HydropumpLauncher.sol";
import {LaunchCurveFixture} from "../helpers/LaunchCurveFixture.sol";

/// @notice The launch curve against every generated quote. Slow: run by hand with `npm run test:fork:slow`.
contract LaunchCurveAllQuotesForkTest is LaunchCurveFixture {
    /// The whole point of the per-quote start tick: every launch opens at the same USD valuation, whatever
    /// the quote token's decimals or price, and whichever side of the pair the launch token landed on.
    function test_StartFdvIsFiveThousandAcrossQuoteDecimals() public onlyForked {
        string[5] memory symbols = ["WETH", "USDC", "cbBTC", "EURC", "wtAAPL"];

        for (uint256 i = 0; i < symbols.length; i++) {
            Quote memory q = _quote(symbols[i]);
            _registerQuote(q.token, q.startTick);

            for (uint256 side = 0; side < 2; side++) {
                bool wantToken0 = side == 0;
                (address token, address pool, uint256[] memory ids,) = _launchOnSide(q.token, wantToken0, bytes32(0));

                assertEq(_currentTick(pool), wantToken0 ? q.startTick : -q.startTick, "opening tick");
                _assertCurveShape(token, q.token, pool, ids);

                uint256 fdv = _fdvUsdE8(pool, q, token) / 1e8;
                assertApproxEqRel(fdv, TARGET_FDV_USD, 0.02e18, q.symbol);
            }
            console2.log(string.concat("  ", q.symbol, " opens at target on both sides"));
        }
    }

    /// Every quote the generator emits must launch and open at the target valuation. Nothing is skipped for
    /// being unmineable any more — that category no longer exists.
    function test_EveryGeneratedQuoteLaunchesAtTarget() public onlyForked {
        string[] memory symbols = vm.parseJsonStringArray(quotesJson, ".symbols");
        uint256 asToken0;
        uint256 asToken1;
        uint256 skippedB20;
        uint256 failed;

        for (uint256 i = 0; i < symbols.length; i++) {
            Quote memory q = _quote(symbols[i]);
            if (_isB20(q.token)) {
                skippedB20++;
                continue;
            }
            _registerQuote(q.token, q.startTick);

            vm.warp(vm.getBlockTimestamp() + 1);
            vm.prank(creator);
            try launcher.launch{value: LAUNCH_FEE}(
                HydropumpLauncher.LaunchParams({
                    name: "Alpha",
                    symbol: "ALPHA",
                    quoteToken: q.token,
                    creatorRecipient: creator,
                    buyAmount: 0,
                    feeUse: bytes32(0)
                })
            ) returns (
                address token, address pool, uint256[] memory
            ) {
                if (token < q.token) asToken0++;
                else asToken1++;
                assertApproxEqRel(_fdvUsdE8(pool, q, token) / 1e8, TARGET_FDV_USD, 0.02e18, q.symbol);
            } catch {
                failed++;
                console2.log(string.concat("  FAILED: ", q.symbol));
            }
        }

        console2.log("launched as token0", asToken0);
        console2.log("launched as token1", asToken1);
        console2.log("skipped (B20)     ", skippedB20);
        console2.log("failed            ", failed);
        assertEq(failed, 0, "every non-B20 quote must launch at target");
        assertGt(asToken0 + asToken1, 30, "sanity: most quotes should have been exercised");
        assertGt(asToken1, 0, "and the mirrored side must have been exercised at all");
    }
}
