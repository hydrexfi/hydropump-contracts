// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CreatorBalanceFeeUse} from "../contracts/feeuses/CreatorBalanceFeeUse.sol";
import {AutoLpFeeUse} from "../contracts/feeuses/AutoLpFeeUse.sol";
import {BuybackBurnFeeUse} from "../contracts/feeuses/BuybackBurnFeeUse.sol";
import {FeeUses} from "../contracts/libraries/FeeUses.sol";
import {FeeUseRegistry} from "../contracts/FeeUseRegistry.sol";
import {HydropumpLocker} from "../contracts/HydropumpLocker.sol";
import {HydropumpFixture} from "./helpers/HydropumpFixture.sol";
import {MockAlgebraPool} from "./mocks/MockAlgebra.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TickMath} from "../contracts/libraries/TickMath.sol";

/// @notice What a launch's creator share can be spent on: a payout, more liquidity, or a burn.
/// @dev The through-line of every case below is that routing is the whole thing. A fee use spends what it
///      is handed inside the same call and keeps nothing, so `escrow.route` — or `locker.handleAllRewards`,
///      which wraps it — is the only step, and a balance sitting in one of these contracts afterwards is
///      a bug rather than a state to claim from.
///
///      Run twice: `FeeUsesMirroredTest` at the bottom repeats every case with the launch token sorting
///      above its quote. Two of the three strategies swap or deposit into the pool, and both care which
///      side of the pair they are on.
contract FeeUsesTest is HydropumpFixture {
    /// @dev Overridden by the mirrored suite. The high quote puts a launch token on the token0 side.
    function _quote() internal view virtual returns (address) {
        return HIGH_QUOTE;
    }

    /// @dev A launch on the requested fee use, with fees accrued and split but not yet spent.
    function _launchWithFees(bytes32 feeUse, uint256 launchAmount, uint256 quoteAmount)
        internal
        returns (address token, address pool)
    {
        (token, pool,) = _launch(_quote(), feeUse, 0);
        _accrueFees(token, launchAmount, quoteAmount);
        _seedPoolQuote(token, 10e18);
        locker.splitRewards(token);
    }

    /// @dev Nothing may be left behind in a fee use. Asserted after every case that spends.
    function _assertNothingHeld(address feeUse, address token) internal view {
        assertEq(IERC20(token).balanceOf(feeUse), 0, "fee use held launch tokens");
        assertEq(IERC20(_quote()).balanceOf(feeUse), 0, "fee use held quote");
    }

    // =============================
    //  CREATOR BALANCE
    // =============================

    function test_CreatorBalancePaysBothSidesOnArrival() public {
        (address token,) = _launchWithFees(FeeUses.CREATOR_BALANCE, 40_000, 8_000);

        locker.spendCreatorShare(token);

        assertEq(IERC20(token).balanceOf(creator), 30_000, "75% of the launch-token fees");
        assertEq(IERC20(_quote()).balanceOf(creator), 6_000, "and of the quote");
        assertEq(creatorBalance.lifetimePaid(token, token), 30_000);
        _assertNothingHeld(address(creatorBalance), token);
    }

    /// Permissionless, and the caller is not the recipient. Anyone can press the button; only the creator
    /// is paid by it.
    function test_AnyoneCanRouteAndTheCreatorIsStillThePayee() public {
        (address token,) = _launchWithFees(FeeUses.CREATOR_BALANCE, 40_000, 0);
        assertEq(locker.creatorOwed(token, token), 30_000, "sitting in the escrow");

        vm.prank(stranger);
        locker.spendCreatorShare(token);

        assertEq(locker.creatorOwed(token, token), 0);
        assertEq(IERC20(token).balanceOf(creator), 30_000, "reached the creator, not the caller");
        assertEq(IERC20(token).balanceOf(stranger), 0);
    }

    function test_PayoutFollowsARedirectedRecipient() public {
        (address token,) = _launchWithFees(FeeUses.CREATOR_BALANCE, 40_000, 0);

        vm.prank(creator);
        locker.setCreatorRecipient(token, stranger);
        locker.spendCreatorShare(token);

        assertEq(IERC20(token).balanceOf(stranger), 30_000, "the locker is the single source of truth");
        assertEq(IERC20(token).balanceOf(creator), 0);
    }

    function test_RoutingTwiceIsANoop() public {
        (address token,) = _launchWithFees(FeeUses.CREATOR_BALANCE, 40_000, 0);
        locker.spendCreatorShare(token);
        locker.spendCreatorShare(token);
        assertEq(IERC20(token).balanceOf(creator), 30_000);
    }

    function test_OnlyTheEscrowCanDeliverToACreatorBalance() public {
        (address token,) = _launchWithFees(FeeUses.CREATOR_BALANCE, 1_000, 0);

        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        (assets[0], amounts[0]) = (token, 1);

        vm.prank(stranger);
        vm.expectRevert(CreatorBalanceFeeUse.NotLocker.selector);
        creatorBalance.onFees(token, assets, amounts);
    }

    /// Two launches routed back to back must not see each other's money, even though both pass through the
    /// same contract. Nothing is stored between them, which is what makes that true by construction.
    function test_TwoLaunchesRoutedThroughTheSameContractStaySeparate() public {
        (address tokenA,) = _launchWithFees(FeeUses.CREATOR_BALANCE, 0, 8_000);
        (address tokenB,) = _launchWithFees(FeeUses.CREATOR_BALANCE, 0, 4_000);

        address otherCreator = makeAddr("otherCreator");
        vm.prank(creator);
        locker.setCreatorRecipient(tokenB, otherCreator);

        locker.spendCreatorShare(tokenA);
        locker.spendCreatorShare(tokenB);

        assertEq(IERC20(_quote()).balanceOf(creator), 6_000, "launch A's share only");
        assertEq(IERC20(_quote()).balanceOf(otherCreator), 3_000, "launch B's share only");
        assertEq(IERC20(_quote()).balanceOf(address(creatorBalance)), 0, "and nothing was kept back");
    }

    // =============================
    //  AUTO LP
    // =============================

    /// Fees go back into the launch's own curve. The position they land in belongs to the locker and has no
    /// withdraw path, so this is one-way: nobody can take the liquidity back out, this contract included.
    function test_AutoLpAddsToTheLockedCurveAndCannotTakeItBack() public {
        (address token, address pool) = _launchWithFees(FeeUses.AUTO_LP, 40_000e18, 1e18);

        (uint256 positionId, bool found) = autoLp.targetBand(token);
        assertTrue(found);
        uint128 before = npm.liquidityOf(positionId);
        assertEq(npm.ownerOf(positionId), address(locker));

        vm.prank(stranger);
        locker.spendCreatorShare(token);

        uint128 added = autoLp.lifetimeLiquidityAdded(token);
        assertGt(added, 0, "liquidity was added");
        assertEq(npm.liquidityOf(positionId), before + added);
        assertEq(npm.ownerOf(positionId), address(locker), "and the position never moved");
        assertEq(IERC20(token).balanceOf(stranger), 0, "the caller takes nothing");
        assertTrue(pool != address(0));
    }

    /// A band takes one ratio, so something is nearly always left over. It goes back to the locker rather
    /// than out to the creator — this contract is a route, and it keeps nothing.
    function test_AutoLpReturnsWhatDidNotPairOff() public {
        (address token,) = _launchWithFees(FeeUses.AUTO_LP, 40_000e18, 1e18);

        locker.spendCreatorShare(token);

        _assertNothingHeld(address(autoLp), token);
        assertEq(IERC20(token).balanceOf(creator), 0, "auto-LP pays the creator nothing");
        assertEq(IERC20(_quote()).balanceOf(creator), 0);
    }

    /// One-sided fees used to revert the whole call: a band holding the price sizes liquidity by the
    /// smaller side, so a zero on one side means zero liquidity and `zeroLiquidityDesired`. Whatever
    /// cannot be deposited now goes back to the locker instead.
    function test_AutoLpSurvivesOneSidedFees() public {
        (address token,) = _launchWithFees(FeeUses.AUTO_LP, 40_000e18, 0);

        uint256 lockerBefore = IERC20(token).balanceOf(address(locker));

        locker.spendCreatorShare(token); // must not revert

        // Deposited or returned, nothing is lost and nothing is kept: the locker is down only by what
        // the band actually took.
        uint256 spentIntoTheBand = lockerBefore - IERC20(token).balanceOf(address(locker));
        assertLe(spentIntoTheBand, 30_000e18, "it can never spend more than the creator share");
        assertEq(IERC20(token).balanceOf(creator), 0, "and the creator is not paid by auto-LP");
        _assertNothingHeld(address(autoLp), token);
    }

    /// And the one-click path survives it, which is the point: a launch on auto-LP must still be able to
    /// pay the protocol its share.
    function test_HandleAllRewardsSurvivesAnUndepositableAutoLp() public {
        (address token,,) = _launch(_quote(), FeeUses.AUTO_LP, 0);
        _accrueFees(token, 40_000e18, 0);
        _seedPoolQuote(token, 10e18);

        locker.handleAllRewards(token);

        // Whatever the band could not take is re-booked rather than lost, and nothing sticks in the
        // fee use. The protocol is paid either way.
        _assertNothingHeld(address(autoLp), token);
        assertGt(locker.protocolOwed(_quote()) + IERC20(_quote()).balanceOf(buyback), 0, "protocol paid");
    }

    function test_RoutingNothingToAutoLpDoesNotCallIt() public {
        (address token,,) = _launch(_quote(), FeeUses.AUTO_LP, 0);

        // No fees, so `route` returns before it ever reaches the fee use. It must not revert.
        locker.spendCreatorShare(token);
        _assertNothingHeld(address(autoLp), token);
    }

    function test_OnlyTheEscrowCanDeliverToAutoLp() public {
        (address token,,) = _launch(_quote(), FeeUses.AUTO_LP, 0);

        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        (assets[0], amounts[0]) = (token, 1);

        vm.prank(stranger);
        vm.expectRevert(AutoLpFeeUse.NotLocker.selector);
        autoLp.onFees(token, assets, amounts);
    }

    // =============================
    //  BUYBACK AND BURN
    // =============================

    /// The quote side buys the launch token in its own pool and the lot is destroyed. Supply only falls.
    function test_BuybackBurnBuysWithTheQuoteAndBurnsEverything() public {
        (address token,) = _launchWithFees(FeeUses.BUYBACK_BURN, 40_000e18, 1e18);

        uint256 supplyBefore = IERC20(token).totalSupply();

        vm.prank(stranger);
        locker.spendCreatorShare(token);

        uint256 burned = buybackBurn.lifetimeBurned(token);
        assertGt(burned, 30_000e18, "the launch-token fees plus whatever the quote bought");
        assertEq(IERC20(token).totalSupply(), supplyBefore - burned, "supply actually fell");
        assertEq(IERC20(token).balanceOf(stranger), 0, "and the caller takes nothing");
        _assertNothingHeld(address(buybackBurn), token);
    }

    function test_BuybackBurnWorksWithOnlyLaunchTokenFees() public {
        (address token,) = _launchWithFees(FeeUses.BUYBACK_BURN, 40_000e18, 0);

        uint256 supplyBefore = IERC20(token).totalSupply();
        locker.spendCreatorShare(token);

        assertEq(buybackBurn.lifetimeBurned(token), 30_000e18, "no quote to spend, so it is just the burn");
        assertEq(IERC20(token).totalSupply(), supplyBefore - 30_000e18);
    }

    /// No price bound, deliberately: the caller takes none of the output — every token bought is burned —
    /// so a bad fill costs the burn size and nothing else, and the call can never be stuck behind one.
    function test_BuybackBurnFillsWhateverThePoolGives() public {
        (address token, address pool) = _launchWithFees(FeeUses.BUYBACK_BURN, 0, 1e18);

        // Spot shoved a long way against the buy. It still goes through.
        int24 shoved = _currentTick(pool) + (token < _quote() ? int24(40_000) : int24(-40_000));
        MockAlgebraPool(pool).setPrice(TickMath.getSqrtRatioAtTick(shoved));

        uint256 supplyBefore = IERC20(token).totalSupply();
        locker.spendCreatorShare(token);
        assertGt(buybackBurn.lifetimeBurned(token), 0);
        assertLt(IERC20(token).totalSupply(), supplyBefore);
    }

    function test_OnlyTheEscrowCanDeliverToBuybackBurn() public {
        (address token,,) = _launch(_quote(), FeeUses.BUYBACK_BURN, 0);

        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        (assets[0], amounts[0]) = (token, 1);

        vm.prank(stranger);
        vm.expectRevert(BuybackBurnFeeUse.NotLocker.selector);
        buybackBurn.onFees(token, assets, amounts);
    }

    // =============================
    //  ONE CLICK
    // =============================

    /// Each path collects for itself, so none of them depends on someone else having split first.
    function test_EachEntryPointCollectsOnItsOwn() public {
        (address paid,,) = _launch(_quote(), FeeUses.CREATOR_BALANCE, 0);
        _accrueFees(paid, 40_000, 8_000);
        _seedPoolQuote(paid, 10e18);

        // Creator only: pays out, and leaves the protocol's share booked for later.
        vm.prank(stranger);
        locker.handleCreatorRewards(paid);
        assertEq(IERC20(paid).balanceOf(creator), 30_000, "the creator was paid without a prior split");
        assertEq(locker.protocolOwed(paid), 10_000, "and the protocol's side is untouched, not lost");
        assertEq(IERC20(_quote()).balanceOf(buyback), 0, "nothing delivered yet");

        // Protocol only: converts and delivers, and pays the creator nothing.
        (address swept,,) = _launch(_quote(), FeeUses.CREATOR_BALANCE, 0);
        _accrueFees(swept, 40_000, 8_000);
        _seedPoolQuote(swept, 10e18);

        vm.prank(stranger);
        locker.handleProtocolRewards(swept);
        assertEq(locker.protocolOwed(swept), 0, "converted");
        assertGt(IERC20(_quote()).balanceOf(buyback), 0, "and delivered to the buyback");
        assertEq(locker.creatorOwed(swept, swept), 30_000, "the creator's side is booked, not spent");
    }

    /// A broken fee use takes the creator path down but must not take the protocol path with it.
    function test_ProtocolPathIsIndependentOfTheCreatorPath() public {
        (address token,,) = _launch(_quote(), FeeUses.CREATOR_BALANCE, 0);
        _accrueFees(token, 40_000, 8_000);
        _seedPoolQuote(token, 10e18);

        // Deployed first: `prank` binds to the very next call, and `new` would consume it.
        address bareRegistry = address(new FeeUseRegistry());
        vm.prank(owner);
        locker.setFeeUseRegistry(bareRegistry);

        vm.expectRevert(HydropumpLocker.UnknownFeeUse.selector);
        locker.handleCreatorRewards(token);

        // The protocol still gets paid, and the creator's share stays booked.
        locker.handleProtocolRewards(token);
        assertGt(IERC20(_quote()).balanceOf(buyback), 0);
        assertEq(locker.creatorOwed(token, token), 30_000, "still waiting, still payable");
    }

    /// What the button actually calls. One transaction takes a launch from uncollected fees to spent, on
    /// all three strategies and on the protocol's side too, with no follow-up step of any kind.
    function test_HandleAllRewardsDoesTheWholeThingInOneCall() public {
        (address paid, address pooled, address burned) = _threeLaunchesWithUncollectedFees();

        uint256 burnedSupplyBefore = IERC20(burned).totalSupply();
        (uint256 pooledPosition,) = autoLp.targetBand(pooled);
        uint128 pooledLiquidityBefore = npm.liquidityOf(pooledPosition);

        vm.startPrank(stranger);
        locker.handleAllRewards(paid);
        locker.handleAllRewards(pooled);
        locker.handleAllRewards(burned);
        vm.stopPrank();

        assertEq(IERC20(paid).balanceOf(creator), 30_000e18, "one paid its creator");
        assertGt(npm.liquidityOf(pooledPosition), pooledLiquidityBefore, "one grew its own curve");
        assertLt(IERC20(burned).totalSupply(), burnedSupplyBefore, "one destroyed supply");

        // Nothing left in a fee use and no launch-token share still needing a pool to convert against.
        // `creatorOwed` may be non-zero afterwards: auto-LP re-books whatever a band could not take.
        for (uint256 i = 0; i < 3; i++) {
            address token = [paid, pooled, burned][i];
            assertEq(locker.protocolOwed(token), 0, "protocol share left unconverted");
            _assertNothingHeld(registry.implementationFor(token), token);
        }
        assertEq(locker.creatorOwed(paid, _quote()), 0, "a payout leaves nothing booked");
        assertEq(locker.creatorOwed(burned, _quote()), 0, "and neither does a burn");

        // The protocol's side was converted AND delivered by the same presses, so nothing is left for a
        // keeper to come back for.
        assertEq(locker.protocolOwed(_quote()), 0, "swept by the button, not by an operator");
        assertGt(IERC20(_quote()).balanceOf(buyback), 0, "and it reached the buyback");
    }

    /// The three strategies are genuinely different, and none of them touches another's money.
    function test_ThreeLaunchesOnThreeStrategiesEachDoTheirOwnThing() public {
        (address paid, address pooled, address burned) = _threeLaunchesWithUncollectedFees();

        locker.handleAllRewards(paid);
        locker.handleAllRewards(pooled);
        locker.handleAllRewards(burned);

        assertEq(IERC20(paid).balanceOf(creator), 30_000e18);
        assertEq(IERC20(burned).balanceOf(creator), 0, "a burn pays its creator nothing");
        assertEq(IERC20(pooled).balanceOf(creator) + IERC20(burned).balanceOf(creator), 0, "no crossed wires");
    }

    /// A launch whose price has run past every band still goes through. The deposit takes what it can and
    /// the rest comes back, so no strategy can leave the button stuck on a pool that moved.
    function test_HandleAllRewardsSurvivesAPriceOutsideEveryBand() public {
        (address token, address pool) = _launchWithFees(FeeUses.AUTO_LP, 40_000e18, 1e18);
        _setSpot(pool, _currentTick(pool) + (token < _quote() ? int24(-200_000) : int24(200_000)));

        locker.handleAllRewards(token);

        // Deposited or re-booked, never stranded: the fee use keeps nothing either way.
        _assertNothingHeld(address(autoLp), token);
    }

    function _threeLaunchesWithUncollectedFees() internal returns (address paid, address pooled, address burned) {
        bytes32[3] memory uses = [FeeUses.CREATOR_BALANCE, FeeUses.AUTO_LP, FeeUses.BUYBACK_BURN];
        address[3] memory tokens;

        for (uint256 i = 0; i < 3; i++) {
            (tokens[i],,) = _launch(_quote(), uses[i], 0);
            _accrueFees(tokens[i], 40_000e18, 1e18);
            _seedPoolQuote(tokens[i], 10e18);
        }
        (paid, pooled, burned) = (tokens[0], tokens[1], tokens[2]);
    }
}

/// @notice Every case above again, with the launch token sorting ABOVE its quote.
contract FeeUsesMirroredTest is FeeUsesTest {
    function _quote() internal pure override returns (address) {
        return LOW_QUOTE;
    }
}
