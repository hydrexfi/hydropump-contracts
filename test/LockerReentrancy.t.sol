// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {HydropumpFixture} from "./helpers/HydropumpFixture.sol";
import {HydropumpLocker} from "../contracts/core/HydropumpLocker.sol";
import {HydropumpLauncher} from "../contracts/core/HydropumpLauncher.sol";
import {IFeeUse} from "../contracts/interfaces/IFeeUse.sol";
import {FeeUses} from "../contracts/libraries/FeeUses.sol";

/// @notice The callback shape an ERC-777 / ERC-1363-style token gives its receiver.
interface ITokenReceiverHook {
    function onTokenReceived(address from, uint256 amount) external;
}

/// @notice A quote token that calls the RECEIVER after every transfer.
/// @dev No quote on the live whitelist behaves this way today, so this models a token the directory owner
///      could list in future rather than one already listed.
contract HookedQuote is ERC20 {
    constructor() ERC20("Hooked", "HOOK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (to.code.length > 0 && from != address(0)) {
            try ITokenReceiverHook(to).onTokenReceived(from, value) {} catch {}
        }
    }
}

/// @notice A creator's recipient contract. On receiving the quote it re-enters the locker, and records
///         whether that re-entry was refused.
/// @dev The recording is what lets a test assert the guard fired: the quote token swallows a reverting
///      hook, so without it the refusal would be invisible from outside.
contract CreatorHook is ITokenReceiverHook {
    HydropumpLocker public immutable locker;

    /// @notice 1 = split another launch mid-spend; 2 = sweep the quote's protocol share mid-spend.
    uint8 public action;
    address public target;
    bool internal busy;

    bool public reentryAttempted;
    bool public reentryReverted;
    bytes public reentryRevertData;

    constructor(HydropumpLocker _locker) {
        locker = _locker;
    }

    function arm(uint8 _action, address _target) external {
        (action, target) = (_action, _target);
    }

    function onTokenReceived(address, uint256) external {
        if (busy || action == 0) return;
        busy = true;
        reentryAttempted = true;

        if (action == 1) {
            try locker.splitRewards(target) {}
            catch (bytes memory reason) {
                (reentryReverted, reentryRevertData) = (true, reason);
            }
        } else if (action == 2) {
            address[] memory assets = new address[](1);
            assets[0] = target;
            try locker.sweepProtocol(assets) {}
            catch (bytes memory reason) {
                (reentryReverted, reentryRevertData) = (true, reason);
            }
        }

        busy = false;
    }
}

/// @notice A contract creator that counts every hook it receives, to see whether launch() ever hands it
///         control.
contract CountingCreator is ITokenReceiverHook {
    uint256 public hooks;

    function onTokenReceived(address, uint256) external {
        hooks++;
    }

    function doLaunch(HydropumpLauncher launcher, address quote, uint256 buy) external payable returns (address t) {
        IERC20(quote).approve(address(launcher), buy);
        (t,,) = launcher.launch{value: msg.value}(
            HydropumpLauncher.LaunchParams({
                name: "Nested",
                symbol: "NST",
                quoteToken: quote,
                creatorRecipient: address(this),
                buyAmount: buy,
                feeUse: bytes32(0)
            })
        );
    }
}

/// @notice A fee use that re-enters the locker to split another launch while it is being paid.
/// @dev Only the fee-use registry's owner can point a launch at one of these, so this route needs a
///      privileged mistake; the hooked quote above needs none.
contract ReentrantFeeUse is IFeeUse {
    HydropumpLocker public immutable locker;
    address public victim;

    constructor(HydropumpLocker _locker) {
        locker = _locker;
    }

    function setVictim(address v) external {
        victim = v;
    }

    function onFees(address, address[] calldata, uint256[] calldata) external {
        locker.splitRewards(victim);
    }
}

/// @title LockerReentrancyTest — the hooked-quote route into the locker (HP-02)
/// @notice `spendCreatorShare` books back whatever the locker's balance rose by while the fee use ran. If
///         another launch's fees can be made to arrive inside that window, they are booked twice: once to
///         the launch that earned them and again to the launch being spent. These tests assert that no
///         locker entry point can run inside another, so the window cannot be opened.
/// @dev Ported from the security review's proof of concept
///      (`poc/test/reentry/HookedQuoteReentry.t.sol`), with the assertions turned from "the double
///      booking happens" to "it is refused".
contract LockerReentrancyTest is HydropumpFixture {
    HookedQuote internal hq;
    address internal victimLaunch;
    address internal attackerLaunch;
    CreatorHook internal hook;

    function setUp() public override {
        super.setUp();
        vm.etch(HIGH_QUOTE, address(new HookedQuote()).code);
        hq = HookedQuote(HIGH_QUOTE);

        (victimLaunch,,) = _launch(HIGH_QUOTE, FeeUses.CREATOR_BALANCE, 0);
        (attackerLaunch,,) = _launch(HIGH_QUOTE, FeeUses.CREATOR_BALANCE, 0);

        // The attacker is simply the creator of attackerLaunch; it points its recipient at its own contract.
        hook = new CreatorHook(locker);
        vm.prank(creator);
        locker.setCreatorRecipient(attackerLaunch, address(hook));
    }

    /// @dev The fixture's `_accrueFees` mints the quote through MockERC20; do it with HookedQuote instead.
    function _accrue(address t, uint256 launchAmt, uint256 quoteAmt) internal {
        vm.prank(locker.poolOf(t));
        IERC20(t).transfer(NPM, launchAmt);
        hq.mint(NPM, quoteAmt);
        npm.setOwed(locker.getPositions(t)[0], uint128(launchAmt), uint128(quoteAmt)); // launch token is token0
    }

    /// @dev Everything the locker's ledger says it owes for one asset: both launches' creator shares plus
    ///      the pooled protocol share.
    function _booked(address asset) internal view returns (uint256) {
        return locker.creatorOwed(victimLaunch, asset) + locker.creatorOwed(attackerLaunch, asset)
            + locker.protocolOwed(asset);
    }

    function _assertNotOverBooked(address asset, string memory what) internal view {
        assertLe(_booked(asset), IERC20(asset).balanceOf(address(locker)), what);
    }

    function _assertSolvent(string memory what) internal view {
        _assertNotOverBooked(HIGH_QUOTE, what);
        _assertNotOverBooked(victimLaunch, what);
        _assertNotOverBooked(attackerLaunch, what);
    }

    /// @dev The unprivileged route: the attacker's recipient re-enters `splitRewards(victim)` during its own
    ///      payout, so the victim's fees land mid-spend and would be re-booked to the attacker as well.
    function test_hookedQuote_creatorCannotDoubleBookAnotherLaunchsFees() public {
        _accrue(attackerLaunch, 1e20, 1e15);
        locker.splitRewards(attackerLaunch);
        _accrue(victimLaunch, 1e20, 4e15); // victim has fees waiting in its positions

        hook.arm(1, victimLaunch);
        uint256 victimOwedBefore = locker.creatorOwed(victimLaunch, HIGH_QUOTE);

        locker.spendCreatorShare(attackerLaunch); // anyone can trigger it; the attacker's hook does the rest

        assertTrue(hook.reentryAttempted(), "precondition: the hook did get control and did re-enter");
        assertTrue(hook.reentryReverted(), "the re-entrant splitRewards must be refused");
        assertEq(
            bytes4(hook.reentryRevertData()),
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector,
            "and refused by the reentrancy guard, not by something else"
        );
        assertEq(
            locker.creatorOwed(victimLaunch, HIGH_QUOTE),
            victimOwedBefore,
            "the victim's booked creator share is untouched"
        );
        _assertSolvent("the locker never books more than it holds");
    }

    /// @dev The same route seen from the money: with the re-entry refused, a second spend can only pay the
    ///      attacker its own share, and the victim's creator is still payable afterwards.
    function test_hookedQuote_attackerIsPaidOnlyItsOwnShare() public {
        _accrue(attackerLaunch, 1e20, 1e15);
        locker.splitRewards(attackerLaunch);
        _accrue(victimLaunch, 1e20, 4e15);

        hook.arm(1, victimLaunch);
        uint256 attackerPaidBefore = IERC20(HIGH_QUOTE).balanceOf(address(hook));
        locker.spendCreatorShare(attackerLaunch);

        assertEq(locker.creatorOwed(attackerLaunch, HIGH_QUOTE), 0, "nothing was re-booked to the attacker");

        // Disarmed and spent again. With nothing re-booked there is nothing left owed, so this second
        // call returns early and pays nothing — which is the point. On the unfixed contract it paid out
        // the victim's fees.
        hook.arm(0, address(0));
        locker.spendCreatorShare(attackerLaunch);
        assertEq(
            IERC20(HIGH_QUOTE).balanceOf(address(hook)) - attackerPaidBefore,
            7.5e14,
            "the attacker is paid its own 75% of its own 1e15 of fees, and no more"
        );

        // The victim's creator can still be paid in full.
        locker.splitRewards(victimLaunch);
        uint256 victimOwed = locker.creatorOwed(victimLaunch, HIGH_QUOTE);
        assertEq(victimOwed, 3e15, "the victim's launch owes its creator the whole 75% of its 4e15");
        uint256 creatorBefore = IERC20(HIGH_QUOTE).balanceOf(creator);
        locker.spendCreatorShare(victimLaunch);
        assertEq(IERC20(HIGH_QUOTE).balanceOf(creator) - creatorBefore, victimOwed, "and pays it");
        _assertSolvent("the locker never books more than it holds");
    }

    /// @dev A hook that pulls the locker's quote balance down mid-spend can only ever hurt the spend it is
    ///      attached to. Before the guard the sweep went through and the attacker's own re-book underflowed,
    ///      so its spend reverted; with the guard the sweep is refused and its spend completes. Either way
    ///      the victim is paid and the ledger stays covered, which is the claim this test makes.
    function test_hookedQuote_sweepDuringSpendOnlyAffectsTheAttackersOwnSpend() public {
        _accrue(attackerLaunch, 1e20, 1e15);
        _accrue(victimLaunch, 1e20, 4e15);
        locker.splitRewards(attackerLaunch);
        locker.splitRewards(victimLaunch); // protocolOwed[quote] now holds both launches' protocol share

        hook.arm(2, HIGH_QUOTE);
        (bool attackerSpendSucceeded,) =
            address(locker).call(abi.encodeCall(HydropumpLocker.spendCreatorShare, (attackerLaunch)));
        emit log_named_string("the attacker's own spend", attackerSpendSucceeded ? "succeeded" : "reverted");

        uint256 victimOwed = locker.creatorOwed(victimLaunch, HIGH_QUOTE);
        assertGt(victimOwed, 0, "precondition: the victim has a creator share booked");
        uint256 before = IERC20(HIGH_QUOTE).balanceOf(creator);
        locker.spendCreatorShare(victimLaunch);
        assertEq(
            IERC20(HIGH_QUOTE).balanceOf(creator) - before, victimOwed, "the victim's creator is still paid in full"
        );
        _assertSolvent("the locker never books more than it holds");
    }

    /// @dev `deliverProtocolShareFromSelf` is the one entry point that moves tokens without a guard of its
    ///      own, so its access check is the only thing keeping an unguarded convert-and-sweep off the
    ///      public surface. Both halves of that check are exercised here: a caller that is not the locker,
    ///      and the locker itself with no guard held. The path that is meant to work — `handleAllRewards`
    ///      reaching it from inside its own guard — is covered by `test/FeeUses.t.sol`, which asserts
    ///      `protocolOwed` reaches zero and the quote reaches the buyback after that call.
    function test_deliverProtocolShareFromSelf_refusesEveryCallerAndEveryUnguardedFrame() public {
        vm.expectRevert(HydropumpLocker.NotGuardedSelfCall.selector);
        locker.deliverProtocolShareFromSelf(attackerLaunch);

        vm.prank(stranger);
        vm.expectRevert(HydropumpLocker.NotGuardedSelfCall.selector);
        locker.deliverProtocolShareFromSelf(attackerLaunch);

        // The locker's own address, but from a frame where no entry point is holding the guard.
        vm.prank(address(locker));
        vm.expectRevert(HydropumpLocker.NotGuardedSelfCall.selector);
        locker.deliverProtocolShareFromSelf(attackerLaunch);
    }

    /// @dev Even with a hooked quote and a dev buy, `launch()` never gives the creator's contract the quote:
    ///      it moves from the creator to the launcher, then through the router into the pool. The creator
    ///      receives the LAUNCH token, which has no hook, and the locker receives position NFTs, not quote.
    ///      So the creator's contract never gets control during `launch()`, and there is nothing to
    ///      re-enter with.
    function test_launchNeverHandsTheCreatorControl_evenWithAHookedQuote() public {
        CountingCreator c = new CountingCreator();
        uint256 buy = 1e15;
        hq.mint(address(c), buy);
        vm.deal(address(c), 1 ether);
        address t = c.doLaunch{value: LAUNCH_FEE}(launcher, HIGH_QUOTE, buy);
        assertTrue(t != address(0), "the launch with a dev buy succeeded");
        assertEq(c.hooks(), 0, "the creator's contract received no callback during launch()");
    }
}

/// @title HostileFeeUseReentrancyTest — the privileged route into the same window (HP-02)
/// @notice A fee use that re-enters `splitRewards` for another launch while it is being paid. Only the
///         registry owner can point a launch at such a fee use, so this route needs an owner mistake; the
///         damage it would do is the same double booking.
/// @dev The re-entrant fee use is modelled on `ReentrantFeeUse` in the review's
///      `poc/test/invariant/HarnessControls.t.sol`. The invariant harness around it is not ported.
contract HostileFeeUseReentrancyTest is HydropumpFixture {
    bytes32 internal constant HOSTILE = keccak256("hydropump.feeuse.hostile-reentrant");

    address internal spentLaunch;
    address internal victimLaunch;
    ReentrantFeeUse internal hostile;

    function setUp() public override {
        super.setUp();

        // Both launches share LOW_QUOTE, so fees booked to one are held in the same asset as the other's.
        (spentLaunch,,) = _launch(LOW_QUOTE, FeeUses.CREATOR_BALANCE, 0);
        (victimLaunch,,) = _launch(LOW_QUOTE, FeeUses.AUTO_LP, 0);

        hostile = new ReentrantFeeUse(locker);
        hostile.setVictim(victimLaunch);
        vm.startPrank(owner);
        registry.registerFeeUse(HOSTILE, address(hostile));
        registry.setFeeUse(spentLaunch, HOSTILE);
        vm.stopPrank();
    }

    function _booked(address asset) internal view returns (uint256) {
        return
            locker.creatorOwed(spentLaunch, asset) + locker.creatorOwed(victimLaunch, asset)
                + locker.protocolOwed(asset);
    }

    function _assertSolvent(string memory what) internal view {
        assertLe(_booked(LOW_QUOTE), IERC20(LOW_QUOTE).balanceOf(address(locker)), what);
        assertLe(_booked(spentLaunch), IERC20(spentLaunch).balanceOf(address(locker)), what);
        assertLe(_booked(victimLaunch), IERC20(victimLaunch).balanceOf(address(locker)), what);
    }

    /// @dev The spend must fail outright rather than book the victim's fees twice. Failing leaves the spent
    ///      launch's share booked in the locker, which is what `spendCreatorShare` already promises for a
    ///      fee use that reverts.
    function test_hostileFeeUse_cannotSplitAnotherLaunchMidSpend() public {
        _accrueFees(spentLaunch, 0, 1e21);
        locker.splitRewards(spentLaunch);
        _accrueFees(victimLaunch, 0, 5e21); // the victim's fees are sitting uncollected in its band

        uint256 spentOwedBefore = locker.creatorOwed(spentLaunch, LOW_QUOTE);
        uint256 victimOwedBefore = locker.creatorOwed(victimLaunch, LOW_QUOTE);
        assertGt(spentOwedBefore, 0, "precondition: the spend reaches onFees");

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        locker.spendCreatorShare(spentLaunch);

        // The revert above already rolls both of these back; they are here to state the promise the
        // revert is keeping, which is that a refused spend strands nobody's money.
        assertEq(locker.creatorOwed(victimLaunch, LOW_QUOTE), victimOwedBefore, "the victim's share is untouched");
        assertEq(locker.creatorOwed(spentLaunch, LOW_QUOTE), spentOwedBefore, "and the spent share stays booked");
        _assertSolvent("the locker never books more than it holds");
    }
}
