// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {HydropumpFixture} from "./helpers/HydropumpFixture.sol";
import {HydropumpLocker} from "../contracts/core/HydropumpLocker.sol";
import {IFeeUse} from "../contracts/interfaces/IFeeUse.sol";
import {FeeUses} from "../contracts/libraries/FeeUses.sol";

/// A quote token that calls its receiver after every transfer.
contract HookedQuote is ERC20 {
    constructor() ERC20("Hooked", "HOOK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (to.code.length > 0 && from != address(0)) {
            try CreatorHook(to).onTokenReceived() {} catch {}
        }
    }
}

/// A creator recipient that re-enters `splitRewards` when paid, and records the revert.
contract CreatorHook {
    HydropumpLocker public immutable locker;
    address public target;
    bytes4 public revertSelector;

    constructor(HydropumpLocker _locker) {
        locker = _locker;
    }

    function arm(address _target) external {
        target = _target;
    }

    function onTokenReceived() external {
        if (target == address(0)) return;
        address t = target;
        target = address(0);
        try locker.splitRewards(t) {}
        catch (bytes memory reason) {
            revertSelector = bytes4(reason);
        }
    }
}

/// A fee use that re-enters `splitRewards` for another launch.
contract ReentrantFeeUse is IFeeUse {
    HydropumpLocker public immutable locker;
    address public immutable victim;

    constructor(HydropumpLocker _locker, address _victim) {
        (locker, victim) = (_locker, _victim);
    }

    function onFees(address, address[] calldata, uint256[] calldata) external {
        locker.splitRewards(victim);
    }
}

/// Another launch's fees arriving mid-spend would be re-booked to the launch being spent.
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

        hook = new CreatorHook(locker);
        vm.prank(creator);
        locker.setCreatorRecipient(attackerLaunch, address(hook));
    }

    function _accrue(address t, uint256 launchAmt, uint256 quoteAmt) internal {
        _moveOutOfPool(t, locker.poolOf(t), launchAmt);
        hq.mint(NPM, quoteAmt);
        npm.setOwed(locker.getPositions(t)[0], uint128(launchAmt), uint128(quoteAmt));
    }

    function _assertSolvent() internal view {
        address[3] memory assets = [HIGH_QUOTE, victimLaunch, attackerLaunch];
        for (uint256 i; i < assets.length; i++) {
            uint256 booked = locker.creatorOwed(victimLaunch, assets[i]) + locker.creatorOwed(attackerLaunch, assets[i])
                + locker.protocolOwed(assets[i]);
            assertLe(booked, IERC20(assets[i]).balanceOf(address(locker)));
        }
    }

    function test_AHookedQuoteCannotReenterDuringASpend() public {
        _accrue(attackerLaunch, 1e20, 1e15);
        locker.splitRewards(attackerLaunch);
        _accrue(victimLaunch, 1e20, 4e15);

        hook.arm(victimLaunch);
        locker.spendCreatorShare(attackerLaunch);

        assertEq(hook.revertSelector(), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertEq(locker.creatorOwed(attackerLaunch, HIGH_QUOTE), 0, "nothing re-booked to the attacker");
        _assertSolvent();
    }

    function test_AFeeUseCannotReenterDuringASpend() public {
        ReentrantFeeUse hostile = new ReentrantFeeUse(locker, victimLaunch);
        bytes32 id = keccak256("hostile");
        vm.startPrank(owner);
        registry.registerFeeUse(id, address(hostile));
        registry.setFeeUse(attackerLaunch, id);
        vm.stopPrank();

        _accrue(attackerLaunch, 1e20, 1e15);
        locker.splitRewards(attackerLaunch);
        _accrue(victimLaunch, 1e20, 4e15);

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        locker.spendCreatorShare(attackerLaunch);
    }

    function test_DeliverFromSelfOnlyRunsInsideAGuardedSelfCall() public {
        vm.prank(stranger);
        vm.expectRevert(HydropumpLocker.NotGuardedSelfCall.selector);
        locker.deliverProtocolShareFromSelf(attackerLaunch);

        vm.prank(address(locker));
        vm.expectRevert(HydropumpLocker.NotGuardedSelfCall.selector);
        locker.deliverProtocolShareFromSelf(attackerLaunch);
    }
}
