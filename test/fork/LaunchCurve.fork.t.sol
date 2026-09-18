// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {HydropumpLauncher} from "../../contracts/HydropumpLauncher.sol";
import {IAlgebraPool} from "../../contracts/interfaces/IAlgebraPool.sol";
import {ForkFixture} from "./helpers/ForkFixture.sol";

/// @notice The launch curve against every quote the generator emits, on both sides of the pair.
/// @dev Start ticks come from script/quotes/quote-tokens.json, so this tests the generator and the
///      launcher together rather than a hand-picked number.
contract LaunchCurveForkTest is ForkFixture {
    struct Quote {
        string symbol;
        address token;
        uint8 decimals;
        int24 startTick;
        uint256 priceUsdE8;
    }

    string internal quotesJson;

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        quotesJson = vm.readFile("script/quotes/quote-tokens.json");
    }

    // ---------------------------------------------------------------- helpers

    function _quote(string memory symbol) internal view returns (Quote memory) {
        string[] memory symbols = vm.parseJsonStringArray(quotesJson, ".symbols");
        address[] memory addresses = vm.parseJsonAddressArray(quotesJson, ".addresses");
        int256[] memory ticks = vm.parseJsonIntArray(quotesJson, ".startTicks");
        uint256[] memory decimals = vm.parseJsonUintArray(quotesJson, ".decimals");
        uint256[] memory prices = vm.parseJsonUintArray(quotesJson, ".priceUsdE8");

        for (uint256 i = 0; i < symbols.length; i++) {
            if (keccak256(bytes(symbols[i])) == keccak256(bytes(symbol))) {
                return Quote(symbol, addresses[i], uint8(decimals[i]), int24(ticks[i]), prices[i]);
            }
        }
        revert("quote not in generated list");
    }

    /// @dev B20 tokenized stocks are native Base precompiles rather than deployed contracts, so they hold no
    ///      bytecode — Base's node services their calls natively. revm only sees the 0xef marker byte and
    ///      halts with OpcodeNotFound, so they cannot be exercised on a fork. They work on mainnet; the live
    ///      AAPLc/WETH Algebra pool is proof, and LaunchB20.fork.t.sol covers them against a faithful mock.
    function _isB20(address token) internal view returns (bool) {
        return token.code.length <= 1;
    }

    /// @dev Fully diluted valuation in USD, scaled by 1e8, implied by the pool's current price. Carries 1e18
    ///      of extra precision: a 6-decimal quote prices one whole launch token at about half a raw unit, so
    ///      anything less floors straight to zero.
    function _fdvUsdE8(address pool, Quote memory q, address token) internal view returns (uint256) {
        uint256 quoteRawPerTokenE18 = _priceE18(pool, token, q.token);
        // * USD price (1e8), * 10e9 supply, / 10**decimals, / the 1e18 scale
        return Math.mulDiv(quoteRawPerTokenE18, q.priceUsdE8 * 1e10, 10 ** q.decimals * 1e18);
    }

    // ---------------------------------------------------------------- tests

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

    /// Documents what a launch pool actually charges today. The split is a ratio applied to whatever is
    /// collected, so it holds at any pool fee — but the absolute amounts scale with it.
    function test_EffectivePoolFeeAndSplitAreIndependent() public onlyForked {
        Quote memory q = _quote("WETH");
        (address token, address pool,,) = _launchOnSide(q.token, true, bytes32(0));

        (,,, uint16 pluginConfig,,) = IAlgebraPool(pool).globalState();
        uint256 amountIn = 1 ether;
        _swapIn(alice, q.token, token, amountIn);

        locker.splitRewards(token);
        (, uint128 grossQuote) = locker.lifetimeFees(token);

        // Hundredths of a bip, denominator 1e6 — the same units as the pool fee.
        uint256 effectiveFee = (uint256(grossQuote) * 1e6) / amountIn;
        console2.log("pool.fee() at launch  ", uint256(IAlgebraPool(pool).fee()));
        console2.log("effective fee taken   ", effectiveFee);

        assertEq(pluginConfig & 128, 128, "DYNAMIC_FEE is on, so the plugin owns the fee");
        assertEq(locker.creatorOwed(token, q.token), uint256(grossQuote) - uint256(grossQuote) / 4);
        assertEq(locker.protocolOwed(q.token), uint256(grossQuote) / 4);
    }

    function test_RoundTripSellReturnsQuote() public onlyForked {
        Quote memory q = _quote("WETH");
        (address token,,,) = _launchOnSide(q.token, true, bytes32(0));

        uint256 bought = _swapIn(alice, q.token, token, 1 ether);
        uint256 quoteBefore = IERC20(q.token).balanceOf(alice);

        uint256 back = _sell(alice, token, q.token, bought);

        assertGt(back, 0);
        assertEq(IERC20(q.token).balanceOf(alice), quoteBefore + back);
        // Two fees plus curve movement, so expect a couple of percent of round-trip loss.
        assertLt(back, 1 ether);
        assertGt(back, 0.9 ether, "a round trip should not lose more than a few percent");
    }
}
