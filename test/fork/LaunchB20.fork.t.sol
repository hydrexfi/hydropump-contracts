// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HydropumpLauncher} from "../../contracts/core/HydropumpLauncher.sol";
import {HydropumpLocker} from "../../contracts/core/HydropumpLocker.sol";
import {FeeUses} from "../../contracts/libraries/FeeUses.sol";
import {IAlgebraPool} from "../../contracts/interfaces/IAlgebraPool.sol";
import {ISwapRouter} from "../../contracts/interfaces/ISwapRouter.sol";
import {ForkFixture} from "./helpers/ForkFixture.sol";
import {MockB20} from "../mocks/MockB20.sol";

/// @notice Hydropump against a B20 tokenized stock as the quote token.
/// @dev B20s are native precompiles and cannot run on a fork, so a faithful mock is etched at the real
///      AAPLc address — keeping the real address ordering, decimals and start tick, while making the
///      policy, pause and multiplier behaviours reachable.
///
///      A B20 sits at a 0xb2… address, which is mid-range: launch tokens land on both sides of it, so
///      every case here has to hold in both orientations.
contract LaunchB20ForkTest is ForkFixture {
    address internal constant AAPLC = 0xb200000000000000000000C2e324d24d7eEcd1fb;
    uint8 internal constant AAPLC_DECIMALS = 8;
    int24 internal constant AAPLC_START_TICK = -433451;

    MockB20 internal quote;

    function setUp() public override {
        super.setUp();
        if (!forked) return;

        // A real B20 has no bytecode; put the mock where the precompile sits.
        assertLe(AAPLC.code.length, 1, "expected a bytecode-free B20 precompile");
        vm.etch(AAPLC, address(new MockB20()).code);
        quote = MockB20(AAPLC);
        quote.init(AAPLC_DECIMALS);

        _registerQuote(AAPLC, AAPLC_START_TICK);
    }

    function _launchB20(uint256 buyAmount) internal returns (address token, address pool) {
        (token, pool,) = _launchFrom(creator, AAPLC, bytes32(0), 0);
        if (buyAmount > 0) revert("use _launchB20WithBuy");
    }

    function _launchB20WithBuy(uint256 buyAmount) internal returns (address token, address pool) {
        quote.mint(creator, buyAmount);
        vm.prank(creator);
        quote.approve(address(launcher), buyAmount);

        vm.prank(creator);
        (token, pool,) = launcher.launch{value: LAUNCH_FEE}(
            HydropumpLauncher.LaunchParams({
                name: "Alpha",
                symbol: "ALPHA",
                quoteToken: AAPLC,
                creatorRecipient: creator,
                buyAmount: buyAmount,
                feeUse: bytes32(0)
            })
        );
    }

    function _tradeAgainst(address token) internal {
        uint256 amountIn = 500e8;
        quote.mint(alice, amountIn);
        vm.startPrank(alice);
        quote.approve(address(ROUTER), amountIn);
        ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: AAPLC,
                tokenOut: token,
                deployer: launcher.poolDeployer(),
                recipient: alice,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                limitSqrtPrice: 0
            })
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------- launch

    function test_LaunchAgainstB20NeverTouchesTheQuoteToken() public onlyForked {
        // Block every party. A plain launch is single-sided, so no quote ever moves and policy is irrelevant.
        quote.setBlocked(creator, true);
        quote.setBlocked(address(launcher), true);
        quote.setPaused(true);

        (address token, address pool) = _launchB20(0);

        (address expected0, address expected1) = token < AAPLC ? (token, AAPLC) : (AAPLC, token);
        assertEq(IAlgebraPool(pool).token0(), expected0);
        assertEq(IAlgebraPool(pool).token1(), expected1);
        assertEq(quote.balanceOf(pool), 0);
        assertApproxEqRel(IERC20(token).balanceOf(pool), launcher.SUPPLY(), 1e12);
    }

    /// Both orientations are ordinary traffic for a stock quote rather than an edge case.
    function test_BothOrientationsWorkAgainstAB20Quote() public onlyForked {
        for (uint256 side = 0; side < 2; side++) {
            bool wantToken0 = side == 0;
            (address token, address pool, uint256[] memory ids,) = _launchOnSide(AAPLC, wantToken0, bytes32(0));

            assertEq(token < AAPLC, wantToken0, "fixture: wrong side");
            assertEq(_currentTick(pool), wantToken0 ? AAPLC_START_TICK : -AAPLC_START_TICK, "opening tick");
            _assertCurveShape(token, AAPLC, pool, ids);
            assertEq(quote.balanceOf(address(launcher)), 0);
        }
    }

    function test_DevBuyWorksWhenPolicyAllows() public onlyForked {
        (address token,) = _launchB20WithBuy(100e8); // 100 AAPLc

        assertGt(IERC20(token).balanceOf(creator), 0, "buyer must receive tokens");
        assertEq(quote.balanceOf(creator), 0, "full buy amount spent");
        assertEq(quote.balanceOf(address(launcher)), 0, "no quote stranded in the launcher");
    }

    /// The spec's sharpest edge: approve is not policy gated, so a successful approval proves nothing.
    function test_DevBuyRevertsWhenBuyerIsBlockedDespiteApprovalSucceeding() public onlyForked {
        uint256 buyAmount = 100e8;
        quote.mint(creator, buyAmount);

        vm.prank(creator);
        assertTrue(quote.approve(address(launcher), buyAmount), "approve succeeds even when blocked");
        quote.setBlocked(creator, true);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(MockB20.TransferBlocked.selector, creator));
        launcher.launch{value: LAUNCH_FEE}(
            HydropumpLauncher.LaunchParams({
                name: "Alpha",
                symbol: "ALPHA",
                quoteToken: AAPLC,
                creatorRecipient: creator,
                buyAmount: buyAmount,
                feeUse: bytes32(0)
            })
        );
    }

    function test_DevBuyRevertsWhenTheB20IsPaused() public onlyForked {
        uint256 buyAmount = 100e8;
        quote.mint(creator, buyAmount);
        vm.prank(creator);
        quote.approve(address(launcher), buyAmount);
        quote.setPaused(true);

        vm.prank(creator);
        vm.expectRevert(MockB20.TransferPaused.selector);
        launcher.launch{value: LAUNCH_FEE}(
            HydropumpLauncher.LaunchParams({
                name: "Alpha",
                symbol: "ALPHA",
                quoteToken: AAPLC,
                creatorRecipient: creator,
                buyAmount: buyAmount,
                feeUse: bytes32(0)
            })
        );
    }

    // ------------------------------------------------------------- fees

    function test_FeesSplitAndReachTheCreatorWithAB20Quote() public onlyForked {
        (address token,) = _launchB20(0);
        _tradeAgainst(token);

        // Unconverted: the protocol side's swap is not what this suite is about, and a paused B20 would
        // make it impossible anyway — which is exactly why that path is optional.
        locker.splitRewards(token);

        uint256 escrowed = locker.creatorOwed(token, AAPLC);
        assertGt(escrowed, 0, "creator share of the B20 fees");
        assertGt(locker.protocolOwed(AAPLC), 0, "protocol share credited");
        assertEq(quote.balanceOf(buyback), 0, "a split moves nothing out to the buyback");

        uint256 protocolShare = locker.protocolOwed(AAPLC);
        address[] memory assets = new address[](1);
        assets[0] = AAPLC;
        locker.sweepProtocol(assets);
        assertEq(quote.balanceOf(buyback), protocolShare, "the sweep delivers it");

        locker.spendCreatorShare(token);
        assertEq(quote.balanceOf(creator), escrowed);
        assertEq(quote.balanceOf(address(creatorBalance)), 0, "nothing lingers in the fee use");
    }

    /// A blocked protocol recipient is inert: the split credits rather than pays, so nothing the protocol
    /// side does can stop a creator being paid. Only the sweep fails, and only until it is repointed.
    function test_BlockedProtocolRecipientStallsOnlyTheSweep() public onlyForked {
        (address token,) = _launchB20(0);
        _tradeAgainst(token);

        quote.setBlocked(buyback, true);

        locker.splitRewards(token);
        locker.spendCreatorShare(token);
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

    /// A blocked creator cannot be paid, but the split still works and the share stays booked. Spending
    /// being a separate call is what keeps it reachable.
    function test_BlockedCreatorStallsTheSpendOnlyAndIsRecoverable() public onlyForked {
        (address token,) = _launchB20(0);
        _tradeAgainst(token);

        quote.setBlocked(creator, true);

        locker.splitRewards(token);
        uint256 owed = locker.creatorOwed(token, AAPLC);
        assertGt(owed, 0, "the split was unaffected");

        vm.expectRevert(abi.encodeWithSelector(MockB20.TransferBlocked.selector, creator));
        locker.spendCreatorShare(token);
        assertEq(locker.creatorOwed(token, AAPLC), owed, "nothing moved, still reachable");

        // The creator moves their payout to an address the policy permits.
        address allowed = makeAddr("allowed");
        vm.prank(creator);
        locker.setCreatorRecipient(token, allowed);
        locker.spendCreatorShare(token);

        assertEq(quote.balanceOf(allowed), owed);
        assertEq(locker.creatorOwed(token, AAPLC), 0);
    }

    // ------------------------------------------------------------- multiplier

    /// Corporate actions move the redemption ratio, not raw balances, so pool accounting is untouched.
    function test_MultiplierChangeLeavesPoolAccountingIntact() public onlyForked {
        (address token, address pool) = _launchB20(0);
        _tradeAgainst(token);

        uint256 poolQuoteBefore = quote.balanceOf(pool);
        uint128 liquidityBefore = IAlgebraPool(pool).liquidity();
        (uint160 priceBefore,,,,,) = IAlgebraPool(pool).globalState();

        quote.setMultiplier(2e18); // 2:1 split

        assertEq(quote.balanceOf(pool), poolQuoteBefore, "raw balances must not rebase");
        assertEq(IAlgebraPool(pool).liquidity(), liquidityBefore);
        (uint160 priceAfter,,,,,) = IAlgebraPool(pool).globalState();
        assertEq(priceAfter, priceBefore);

        // And the fee path is equally indifferent to it.
        locker.splitRewards(token);
        assertGt(locker.creatorOwed(token, AAPLC), 0);
    }
}
