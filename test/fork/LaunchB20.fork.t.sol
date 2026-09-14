// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {HydropumpLauncher} from "../../contracts/HydropumpLauncher.sol";
import {HydropumpLocker} from "../../contracts/HydropumpLocker.sol";
import {IAlgebraPool} from "../../contracts/interfaces/IAlgebraPool.sol";
import {ISwapRouter} from "../../contracts/interfaces/ISwapRouter.sol";
import {HydropumpAddresses} from "../../contracts/libraries/HydropumpAddresses.sol";
import {MockB20} from "../mocks/MockB20.sol";

/// @notice Hydropump against a B20 tokenized stock as the quote token.
/// @dev B20s are native precompiles and cannot run on a fork, so a faithful mock is etched at the real
///      AAPLc address — keeping the real address ordering, decimals and start tick, while making the
///      policy, pause and multiplier behaviours reachable.
contract LaunchB20ForkTest is Test {
    ISwapRouter internal constant ROUTER = ISwapRouter(HydropumpAddresses.SWAP_ROUTER);
    address internal constant AAPLC = 0xb200000000000000000000C2e324d24d7eEcd1fb;
    uint8 internal constant AAPLC_DECIMALS = 8;
    int24 internal constant AAPLC_START_TICK = -433451;

    HydropumpLauncher internal launcher;
    HydropumpLocker internal locker;
    MockB20 internal quote;

    address internal owner = makeAddr("owner");
    address internal creator = makeAddr("creator");
    address internal buyback = makeAddr("buyback");
    address internal alice = makeAddr("alice");

    uint256 internal saltCursor;
    uint96 internal constant LAUNCH_FEE = 0.0005 ether;
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        vm.deal(creator, 100 ether);

        // A real B20 has no bytecode; put the mock where the precompile sits.
        assertLe(AAPLC.code.length, 1, "expected a bytecode-free B20 precompile");
        vm.etch(AAPLC, address(new MockB20()).code);
        quote = MockB20(AAPLC);
        quote.init(AAPLC_DECIMALS);

        locker = HydropumpLocker(
            address(
                new ERC1967Proxy(
                    address(new HydropumpLocker()),
                    abi.encodeCall(
                        HydropumpLocker.initialize, (owner, address(0), buyback, uint64(7_500), uint64(2_500))
                    )
                )
            )
        );
        launcher = HydropumpLauncher(
            address(
                new ERC1967Proxy(
                    address(new HydropumpLauncher()),
                    abi.encodeCall(HydropumpLauncher.initialize, (owner, owner, address(locker), LAUNCH_FEE))
                )
            )
        );

        address[] memory tokens = new address[](1);
        bool[] memory enabled = new bool[](1);
        int24[] memory ticks = new int24[](1);
        (tokens[0], enabled[0], ticks[0]) = (AAPLC, true, AAPLC_START_TICK);

        vm.startPrank(owner);
        locker.setLauncher(address(launcher));
        launcher.configureQuoteTokens(tokens, enabled, ticks);
        vm.stopPrank();
    }

    function _mineSalt() internal returns (bytes32 salt) {
        for (uint256 i = saltCursor; i < saltCursor + 50_000; i++) {
            salt = bytes32(i);
            if (launcher.isSaltValid(creator, salt, AAPLC)) {
                saltCursor = i + 1;
                return salt;
            }
        }
        revert("no salt found");
    }

    function _launch(uint256 buyAmount) internal returns (address token, address pool) {
        bytes32 salt = _mineSalt();
        vm.prank(creator);
        (token, pool,) = launcher.launch{value: LAUNCH_FEE}(
            HydropumpLauncher.LaunchParams({
                name: "Alpha",
                symbol: "ALPHA",
                quoteToken: AAPLC,
                userSalt: salt,
                creatorRecipient: creator,
                buyAmount: buyAmount
            })
        );
    }

    // ------------------------------------------------------------- launch

    function test_LaunchAgainstB20NeverTouchesTheQuoteToken() public {
        if (!forked) {
            vm.skip(true);
        }

        // Block every party. A plain launch is single-sided, so no quote ever moves and policy is irrelevant.
        quote.setBlocked(creator, true);
        quote.setBlocked(address(launcher), true);
        quote.setPaused(true);

        (address token, address pool) = _launch(0);

        assertEq(IAlgebraPool(pool).token0(), token);
        assertEq(IAlgebraPool(pool).token1(), AAPLC, "B20 must be token1");
        assertEq(quote.balanceOf(pool), 0);
        assertApproxEqRel(IERC20(token).balanceOf(pool), launcher.SUPPLY(), 1e12);
    }

    function test_DevBuyWorksWhenPolicyAllows() public {
        if (!forked) {
            vm.skip(true);
        }

        uint256 buyAmount = 100e8; // 100 AAPLc
        quote.mint(creator, buyAmount);
        vm.prank(creator);
        quote.approve(address(launcher), buyAmount);

        (address token,) = _launch(buyAmount);

        assertGt(IERC20(token).balanceOf(creator), 0, "buyer must receive tokens");
        assertEq(quote.balanceOf(creator), 0, "full buy amount spent");
        assertEq(quote.balanceOf(address(launcher)), 0, "no quote stranded in the launcher");
    }

    /// The spec's sharpest edge: approve is not policy gated, so a successful approval proves nothing.
    function test_DevBuyRevertsWhenBuyerIsBlockedDespiteApprovalSucceeding() public {
        if (!forked) {
            vm.skip(true);
        }

        uint256 buyAmount = 100e8;
        quote.mint(creator, buyAmount);

        vm.prank(creator);
        assertTrue(quote.approve(address(launcher), buyAmount), "approve succeeds even when blocked");
        quote.setBlocked(creator, true);

        bytes32 salt = _mineSalt();
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(MockB20.TransferBlocked.selector, creator));
        launcher.launch{value: LAUNCH_FEE}(
            HydropumpLauncher.LaunchParams({
                name: "Alpha",
                symbol: "ALPHA",
                quoteToken: AAPLC,
                userSalt: salt,
                creatorRecipient: creator,
                buyAmount: buyAmount
            })
        );
    }

    function test_DevBuyRevertsWhenTheB20IsPaused() public {
        if (!forked) {
            vm.skip(true);
        }

        uint256 buyAmount = 100e8;
        quote.mint(creator, buyAmount);
        vm.prank(creator);
        quote.approve(address(launcher), buyAmount);
        quote.setPaused(true);

        bytes32 salt = _mineSalt();
        vm.prank(creator);
        vm.expectRevert(MockB20.TransferPaused.selector);
        launcher.launch{value: LAUNCH_FEE}(
            HydropumpLauncher.LaunchParams({
                name: "Alpha",
                symbol: "ALPHA",
                quoteToken: AAPLC,
                userSalt: salt,
                creatorRecipient: creator,
                buyAmount: buyAmount
            })
        );
    }

    // ------------------------------------------------------------- fees

    function _tradeAgainst(address token) internal {
        uint256 amountIn = 500e8;
        quote.mint(alice, amountIn);
        vm.startPrank(alice);
        quote.approve(address(ROUTER), amountIn);
        ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: AAPLC,
                tokenOut: token,
                deployer: address(0),
                recipient: alice,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                limitSqrtPrice: 0
            })
        );
        vm.stopPrank();
    }

    function test_FeesCollectAndSplitWithAB20Quote() public {
        if (!forked) {
            vm.skip(true);
        }

        (address token,) = _launch(0);
        _tradeAgainst(token);

        locker.collect(token, locker.fullMask(token));

        HydropumpLocker.ClaimableFees memory owed = locker.claimable(token);
        assertGt(owed.quoteAmount, 0, "creator owed B20 fees");
        assertGt(locker.protocolOwed(AAPLC), 0, "protocol share credited");
        assertEq(quote.balanceOf(buyback), 0, "collect moves nothing out of the locker");
        assertApproxEqAbs(owed.quoteAmount, locker.protocolOwed(AAPLC) * 3, 8);

        address[] memory assets = new address[](1);
        assets[0] = AAPLC;
        uint256 protocolShare = locker.protocolOwed(AAPLC);
        locker.sweepProtocol(assets);
        assertEq(quote.balanceOf(buyback), protocolShare, "sweep delivers it");

        locker.claim(token);
        assertEq(quote.balanceOf(creator), owed.quoteAmount);
    }

    /// A blocked protocol fee recipient is now inert: `collect` credits rather than pays, so nothing the
    /// protocol side does can stop a creator being paid. Only the sweep fails, and only until repointed.
    function test_BlockedProtocolRecipientStallsOnlyTheSweep() public {
        if (!forked) {
            vm.skip(true);
        }

        (address token,) = _launch(0);
        _tradeAgainst(token);

        quote.setBlocked(buyback, true);

        // Collection is unaffected, and the creator is paid in full.
        locker.claim(token);
        assertGt(quote.balanceOf(creator), 0, "creator paid despite a blocked protocol recipient");

        uint256 protocolShare = locker.protocolOwed(AAPLC);
        assertGt(protocolShare, 0, "protocol share waiting in the ledger");

        address[] memory assets = new address[](1);
        assets[0] = AAPLC;
        vm.expectRevert(abi.encodeWithSelector(MockB20.TransferBlocked.selector, buyback));
        locker.sweepProtocol(assets);

        address rescue = makeAddr("rescue");
        vm.prank(owner);
        locker.setProtocolFeeRecipient(rescue);

        locker.sweepProtocol(assets);
        assertEq(quote.balanceOf(rescue), protocolShare, "the balance was never at risk, only stuck");
        assertEq(locker.protocolOwed(AAPLC), 0);
    }

    /// A blocked creator cannot be paid, but collection still works and the balance stays credited.
    function test_BlockedCreatorStallsClaimOnlyAndIsRecoverable() public {
        if (!forked) {
            vm.skip(true);
        }

        (address token,) = _launch(0);
        _tradeAgainst(token);

        quote.setBlocked(creator, true);

        // Collection is unaffected: the creator's share is credited, not pushed.
        locker.collect(token, locker.fullMask(token));
        uint256 owed = locker.claimable(token).quoteAmount;
        assertGt(owed, 0);

        vm.expectRevert(abi.encodeWithSelector(MockB20.TransferBlocked.selector, creator));
        locker.claim(token);

        // The creator moves their payout to an address the policy permits.
        address allowed = makeAddr("allowed");
        vm.prank(creator);
        locker.setCreatorRecipient(token, allowed);
        locker.claim(token);

        assertEq(quote.balanceOf(allowed), owed);
        assertEq(locker.claimable(token).quoteAmount, 0);
    }

    // ------------------------------------------------------------- multiplier

    /// Corporate actions move the redemption ratio, not raw balances, so pool accounting is untouched.
    function test_MultiplierChangeLeavesPoolAccountingIntact() public {
        if (!forked) {
            vm.skip(true);
        }

        (address token, address pool) = _launch(0);
        _tradeAgainst(token);

        uint256 poolQuoteBefore = quote.balanceOf(pool);
        uint128 liquidityBefore = IAlgebraPool(pool).liquidity();
        (uint160 priceBefore,,,,,) = IAlgebraPool(pool).globalState();

        quote.setMultiplier(2e18); // 2:1 split

        assertEq(quote.balanceOf(pool), poolQuoteBefore, "raw balances must not rebase");
        assertEq(IAlgebraPool(pool).liquidity(), liquidityBefore);
        (uint160 priceAfter,,,,,) = IAlgebraPool(pool).globalState();
        assertEq(priceAfter, priceBefore);

        // Only redemption value moved, which is a price change for the market to arbitrage.
        assertEq(quote.scaledBalanceOf(pool), poolQuoteBefore * 2);

        // Collection still works afterwards.
        locker.collect(token, locker.fullMask(token));
        assertGt(locker.claimable(token).quoteAmount, 0);
    }
}
