// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {HydropumpLauncher} from "../../contracts/HydropumpLauncher.sol";
import {HydropumpLocker} from "../../contracts/HydropumpLocker.sol";
import {IAlgebraPool} from "../../contracts/interfaces/IAlgebraPool.sol";
import {INonfungiblePositionManager} from "../../contracts/interfaces/INonfungiblePositionManager.sol";
import {ISwapRouter} from "../../contracts/interfaces/ISwapRouter.sol";
import {HydropumpAddresses} from "../../contracts/libraries/HydropumpAddresses.sol";

/// @notice Exercises the launch curve against live Hydrex on Base, across quote tokens of different
///         decimals, with real third-party swaps and the full fee path.
/// @dev Requires BASE_RPC_URL; skipped when unset. Start ticks come from script/quotes/quote-tokens.json,
///      so this tests the generator and the launcher together rather than a hand-picked tick.
contract LaunchCurveForkTest is Test {
    INonfungiblePositionManager internal constant NPM =
        INonfungiblePositionManager(HydropumpAddresses.NONFUNGIBLE_POSITION_MANAGER);
    ISwapRouter internal constant ROUTER = ISwapRouter(HydropumpAddresses.SWAP_ROUTER);

    uint256 internal constant TARGET_FDV_USD = 5_000;

    HydropumpLauncher internal launcher;
    HydropumpLocker internal locker;

    address internal owner = makeAddr("owner");
    address internal creator = makeAddr("creator");
    address internal buyback = makeAddr("buyback");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    string internal quotesJson;
    uint256 internal saltCursor;
    bool internal forked;

    struct Quote {
        string symbol;
        address token;
        uint8 decimals;
        int24 startTick;
        uint256 priceUsdE8;
    }

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        quotesJson = vm.readFile("script/quotes/quote-tokens.json");

        locker = HydropumpLocker(
            address(
                new ERC1967Proxy(
                    address(new HydropumpLocker()),
                    abi.encodeCall(
                        HydropumpLocker.initialize, (owner, address(0), buyback, uint64(8_000), uint64(3_000))
                    )
                )
            )
        );
        launcher = HydropumpLauncher(
            address(
                new ERC1967Proxy(
                    address(new HydropumpLauncher()),
                    abi.encodeCall(HydropumpLauncher.initialize, (owner, owner, address(locker)))
                )
            )
        );
        vm.prank(owner);
        locker.setLauncher(address(launcher));
    }

    // ---------------------------------------------------------------- helpers

    function _quote(string memory symbol) internal view returns (Quote memory q) {
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

    /// @dev B20 tokenized stocks are native Base precompiles rather than deployed contracts, so they hold
    ///      no bytecode — Base's node services their calls natively. revm only sees the 0xef marker byte and
    ///      halts with OpcodeNotFound, so they cannot be exercised on a fork. They work on mainnet; the live
    ///      AAPLc/WETH Algebra pool is proof.
    function _isB20(address token) internal view returns (bool) {
        return token.code.length <= 1;
    }

    function _register(Quote memory q) internal {
        address[] memory tokens = new address[](1);
        bool[] memory enabled = new bool[](1);
        int24[] memory ticks = new int24[](1);
        (tokens[0], enabled[0], ticks[0]) = (q.token, true, q.startTick);
        vm.prank(owner);
        launcher.configureQuoteTokens(tokens, enabled, ticks);
    }

    /// @dev Advances a cursor so repeated launches in one test never reuse a salt. CREATE2 is
    ///      deterministic, so the same (creator, userSalt) pair resolves to an address that already exists.
    function _mineSalt(address deployer, address quoteToken) internal returns (bytes32 salt) {
        for (uint256 i = saltCursor; i < saltCursor + 50_000; i++) {
            salt = bytes32(i);
            if (launcher.isSaltValid(deployer, salt, quoteToken)) {
                saltCursor = i + 1;
                return salt;
            }
        }
        revert("no salt found");
    }

    function _launch(Quote memory q, uint256 buyAmount)
        internal
        returns (address token, address pool, uint256[] memory positionIds)
    {
        _register(q);
        bytes32 salt = _mineSalt(creator, q.token);

        if (buyAmount > 0) {
            deal(q.token, creator, buyAmount);
            vm.prank(creator);
            IERC20(q.token).approve(address(launcher), buyAmount);
        }

        vm.prank(creator);
        (token, pool, positionIds) = launcher.launch(
            HydropumpLauncher.LaunchParams({
                name: "Alpha",
                symbol: "ALPHA",
                metadataURI: "",
                quoteToken: q.token,
                userSalt: salt,
                creatorRecipient: creator,
                buyAmount: buyAmount
            })
        );
    }

    /// @dev Fully diluted valuation in USD, scaled by 1e8, implied by the pool's current price.
    /// @dev Fully diluted valuation in USD, scaled by 1e8, implied by the pool's current price.
    ///      Carries 1e18 of extra precision: a 6-decimal quote prices one whole launch token at about half
    ///      a raw unit, so anything less floors straight to zero.
    function _fdvUsdE8(address pool, Quote memory q) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,) = IAlgebraPool(pool).globalState();

        // Raw quote units per one whole (1e18) launch token, scaled by 1e18.
        uint256 quoteRawPerTokenE18 = Math.mulDiv(uint256(sqrtPriceX96) * uint256(sqrtPriceX96), 1e36, 1 << 192);

        // * USD price (1e8), * 10e9 supply, / 10**decimals, / the 1e18 scale
        return Math.mulDiv(quoteRawPerTokenE18, q.priceUsdE8 * 1e10, 10 ** q.decimals * 1e18);
    }

    function _swapIn(address who, address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256 out) {
        deal(tokenIn, who, amountIn);
        vm.startPrank(who);
        IERC20(tokenIn).approve(address(ROUTER), amountIn);
        out = ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                deployer: address(0),
                recipient: who,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                limitSqrtPrice: 0
            })
        );
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- tests

    /// The whole point of the per-quote start tick: every launch opens at the same USD valuation,
    /// whatever the quote token's decimals or price.
    function test_StartFdvIsFiveThousandAcrossQuoteDecimals() public {
        if (!forked) {
            vm.skip(true);
        }

        string[5] memory symbols = ["WETH", "USDC", "cbBTC", "EURC", "wtAAPL"];
        for (uint256 i = 0; i < symbols.length; i++) {
            Quote memory q = _quote(symbols[i]);
            (, address pool,) = _launch(q, 0);

            uint256 fdv = _fdvUsdE8(pool, q) / 1e8;
            console2.log(string.concat("  ", q.symbol, " FDV $"), fdv);
            assertApproxEqRel(fdv, TARGET_FDV_USD, 0.02e18, q.symbol);
        }
    }

    function test_EveryBandIsPureLaunchTokenAcrossQuotes() public {
        if (!forked) {
            vm.skip(true);
        }

        string[3] memory symbols = ["WETH", "USDC", "cbBTC"];
        for (uint256 i = 0; i < symbols.length; i++) {
            Quote memory q = _quote(symbols[i]);
            (address token, address pool, uint256[] memory positionIds) = _launch(q, 0);

            assertEq(IERC20(q.token).balanceOf(pool), 0, "pool must hold no quote at launch");
            assertEq(IERC20(q.token).balanceOf(address(locker)), 0);
            assertEq(IERC20(token).balanceOf(address(launcher)), 0);

            int24 previousUpper;
            for (uint256 b = 0; b < positionIds.length; b++) {
                (,,,,, int24 lower, int24 upper, uint128 liquidity,,,,) = NPM.positions(positionIds[b]);
                assertGt(liquidity, 0);
                if (b > 0) assertEq(lower, previousUpper, "bands must be contiguous");
                previousUpper = upper;
            }
            // Whole supply in the pool, bar liquidity-math dust.
            assertApproxEqRel(IERC20(token).balanceOf(pool), launcher.SUPPLY(), 1e12);
        }
    }

    function test_ThirdPartyBuyMovesPriceAndAccruesFeesToTheLockedPositions() public {
        if (!forked) {
            vm.skip(true);
        }

        Quote memory q = _quote("WETH");
        (address token, address pool,) = _launch(q, 0);

        uint256 fdvBefore = _fdvUsdE8(pool, q) / 1e8;
        uint256 received = _swapIn(alice, q.token, token, 1 ether);

        assertGt(received, 0, "buyer must receive tokens");
        assertEq(IERC20(token).balanceOf(alice), received);

        uint256 fdvAfter = _fdvUsdE8(pool, q) / 1e8;
        assertGt(fdvAfter, fdvBefore, "a buy must raise the valuation");

        // Fees are only visible once collected; eth_call semantics via a real call here.
        (uint256[] memory fees0, uint256[] memory fees1) = locker.collect(token, locker.fullMask(token));
        uint256 totalQuoteFees;
        for (uint256 i = 0; i < fees1.length; i++) {
            totalQuoteFees += fees1[i];
        }
        assertGt(totalQuoteFees, 0, "the swap must leave fees on the locked positions");
        assertEq(fees0[0], 0, "a buy pays its fee in the quote token");

        console2.log("FDV before / after ", fdvBefore, fdvAfter);
        console2.log("quote fees collected", totalQuoteFees);
    }

    function test_FeesSplitAndReachTheCreatorAndBuyback() public {
        if (!forked) {
            vm.skip(true);
        }

        Quote memory q = _quote("WETH");
        (address token,,) = _launch(q, 0);

        _swapIn(alice, q.token, token, 2 ether);
        // Sell part of it back so both sides of the pair accrue fees.
        uint256 held = IERC20(token).balanceOf(alice);
        vm.startPrank(alice);
        IERC20(token).approve(address(ROUTER), held / 2);
        ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: q.token,
                deployer: address(0),
                recipient: alice,
                deadline: block.timestamp,
                amountIn: held / 2,
                amountOutMinimum: 0,
                limitSqrtPrice: 0
            })
        );
        vm.stopPrank();

        locker.collect(token, locker.fullMask(token));

        HydropumpLocker.ClaimableFees memory owed = locker.claimable(token);
        assertGt(owed.quoteAmount, 0, "creator owed quote fees");
        assertGt(owed.launchTokenAmount, 0, "creator owed launch-token fees from the sell");

        uint256 buybackQuote = IERC20(q.token).balanceOf(buyback);
        uint256 buybackToken = IERC20(token).balanceOf(buyback);
        assertGt(buybackQuote, 0, "protocol share must reach the buyback");

        // 0.8 / 0.3 split, within a wei of rounding.
        assertApproxEqAbs(owed.quoteAmount * 3, buybackQuote * 8, 8);
        assertApproxEqAbs(owed.launchTokenAmount * 3, buybackToken * 8, 8);

        locker.claim(token);
        assertEq(IERC20(q.token).balanceOf(creator), owed.quoteAmount);
        assertEq(locker.claimable(token).quoteAmount, 0);

        console2.log("creator quote / token", owed.quoteAmount, owed.launchTokenAmount);
        console2.log("buyback quote / token", buybackQuote, buybackToken);
    }

    /// The tail band exists so the pool is still buyable after the fourth band is cleared.
    function test_BuyingThroughEveryBandStillFills() public {
        if (!forked) {
            vm.skip(true);
        }

        Quote memory q = _quote("WETH");
        (address token, address pool,) = _launch(q, 0);

        // Enough to walk well past the top of band four.
        uint256 received = _swapIn(alice, q.token, token, 6_000 ether);
        assertGt(received, 0);

        uint256 fdv = _fdvUsdE8(pool, q) / 1e8;
        assertGt(fdv, 40_000_000, "should be deep into the curve");

        // Still finite, still buyable in the tail.
        uint256 more = _swapIn(bob, q.token, token, 10 ether);
        assertGt(more, 0, "tail band must keep the pool buyable");

        console2.log("FDV after deep buy $", fdv);
        console2.log("tail buy received   ", more);
    }

    /// Every quote the generator emits must launch and open at the target valuation. B20 precompiles are
    /// counted and skipped rather than failed - see `_isB20`.
    function test_EveryGeneratedQuoteLaunchesAtTarget() public {
        if (!forked) {
            vm.skip(true);
        }

        string[] memory symbols = vm.parseJsonStringArray(quotesJson, ".symbols");
        uint256 launched;
        uint256 skippedB20;
        uint256 failed;

        for (uint256 i = 0; i < symbols.length; i++) {
            Quote memory q = _quote(symbols[i]);
            if (_isB20(q.token)) {
                skippedB20++;
                continue;
            }

            _register(q);
            bytes32 salt = _mineSalt(creator, q.token);

            vm.prank(creator);
            try launcher.launch(
                HydropumpLauncher.LaunchParams({
                    name: "Alpha",
                    symbol: "ALPHA",
                    metadataURI: "",
                    quoteToken: q.token,
                    userSalt: salt,
                    creatorRecipient: creator,
                    buyAmount: 0
                })
            ) returns (
                address, address pool, uint256[] memory
            ) {
                launched++;
                assertApproxEqRel(_fdvUsdE8(pool, q) / 1e8, TARGET_FDV_USD, 0.02e18, q.symbol);
            } catch {
                failed++;
                console2.log(string.concat("  FAILED: ", q.symbol));
            }
        }

        console2.log("launched      ", launched);
        console2.log("skipped (B20) ", skippedB20);
        console2.log("failed        ", failed);
        assertEq(failed, 0, "every non-B20 quote must launch at target");
        assertGt(launched, 30, "sanity: most quotes should have been exercised");
    }

    /// B20 quotes cannot be executed on a fork, so validate our half of the arithmetic against a stand-in
    /// with the same decimals. This checks the start tick, not B20 interop.
    function test_B20StartTicksAreCorrectAgainstAStandIn() public {
        if (!forked) {
            vm.skip(true);
        }

        string[3] memory symbols = ["AAPLc", "NVDAc", "TSLAc"];
        for (uint256 i = 0; i < symbols.length; i++) {
            Quote memory q = _quote(symbols[i]);
            assertTrue(_isB20(q.token), "expected a B20 precompile");

            StandIn standIn = new StandIn(q.decimals);
            vm.etch(q.token, address(standIn).code);
            vm.store(q.token, bytes32(uint256(0)), bytes32(uint256(q.decimals)));

            (, address pool,) = _launch(q, 0);
            uint256 fdv = _fdvUsdE8(pool, q) / 1e8;
            console2.log(string.concat("  ", q.symbol, " FDV $"), fdv);
            assertApproxEqRel(fdv, TARGET_FDV_USD, 0.02e18, q.symbol);
        }
    }

    function test_RoundTripSellReturnsQuote() public {
        if (!forked) {
            vm.skip(true);
        }

        Quote memory q = _quote("WETH");
        (address token,,) = _launch(q, 0);

        uint256 bought = _swapIn(alice, q.token, token, 1 ether);
        uint256 quoteBefore = IERC20(q.token).balanceOf(alice);

        vm.startPrank(alice);
        IERC20(token).approve(address(ROUTER), bought);
        uint256 back = ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: q.token,
                deployer: address(0),
                recipient: alice,
                deadline: block.timestamp,
                amountIn: bought,
                amountOutMinimum: 0,
                limitSqrtPrice: 0
            })
        );
        vm.stopPrank();

        assertGt(back, 0);
        assertEq(IERC20(q.token).balanceOf(alice), quoteBefore + back);
        // Two 1.1% fees plus curve movement, so expect a couple of percent of round-trip loss.
        assertLt(back, 1 ether);
        assertGt(back, 0.9 ether, "round trip should not lose more than a few percent");

        console2.log("round trip out of 1e18 wei:", back);
    }
}

/// @dev Minimal ERC20 used in place of a B20 precompile, which cannot be executed on a fork.
contract StandIn {
    uint8 public decimals;
    string public name = "StandIn";
    string public symbol = "STAND";
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint8 _decimals) {
        decimals = _decimals;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Local copy of the two mulDiv paths this test needs.
library Math {
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) return prod0 / denominator;
            require(denominator > prod1, "mulDiv overflow");

            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = denominator & (0 - denominator);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            result = prod0 * inverse;
        }
    }
}
