// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AutoLpFeeUse} from "../contracts/feeuses/AutoLpFeeUse.sol";
import {FeeUseRegistry} from "../contracts/helpers/FeeUseRegistry.sol";
import {HydropumpLocker} from "../contracts/core/HydropumpLocker.sol";
import {IFeeUse} from "../contracts/interfaces/IFeeUse.sol";
import {FeeUses} from "../contracts/libraries/FeeUses.sol";
import {HydropumpFixture} from "./helpers/HydropumpFixture.sol";

/// @notice A fee use that refuses everything, for proving what a broken one can and cannot break.
contract RevertingFeeUse is IFeeUse {
    function onFees(address, address[] calldata, uint256[] calldata) external pure {
        revert("strategy is broken");
    }
}

/// @notice The registry: who may point it, and what happens when the thing it points at stops working.
contract FeeUseRegistryTest is HydropumpFixture {
    bytes32 internal constant BROKEN = keccak256("hydropump.feeuse.broken");

    // =============================
    //  WHICH FEE USE
    // =============================

    function test_DefaultAppliesUntilALaunchChoosesOtherwise() public {
        (address riding,,) = _launch(HIGH_QUOTE, bytes32(0), 0);
        (address chose,,) = _launch(HIGH_QUOTE, FeeUses.BUYBACK_BURN, 0);

        assertEq(registry.feeUseOf(riding), FeeUses.CREATOR_BALANCE);
        assertEq(registry.feeUseOf(chose), FeeUses.BUYBACK_BURN);
        assertFalse(registry.hasExplicitFeeUse(riding));
        assertTrue(registry.hasExplicitFeeUse(chose));
    }

    /// The default is read through rather than written at launch, so moving it moves everyone on it.
    function test_MovingTheDefaultMovesOnlyTheLaunchesRidingIt() public {
        (address riding,,) = _launch(HIGH_QUOTE, bytes32(0), 0);
        (address chose,,) = _launch(HIGH_QUOTE, FeeUses.AUTO_LP, 0);

        vm.prank(owner);
        registry.setDefaultFeeUse(FeeUses.BUYBACK_BURN);

        assertEq(registry.feeUseOf(riding), FeeUses.BUYBACK_BURN, "followed the default");
        assertEq(registry.feeUseOf(chose), FeeUses.AUTO_LP, "an explicit choice is not overridden");
    }

    function test_AdminCanRepointALaunchThatAlreadyChose() public {
        (address token,,) = _launch(HIGH_QUOTE, FeeUses.AUTO_LP, 0);

        vm.prank(owner);
        registry.setFeeUse(token, FeeUses.CREATOR_BALANCE);

        assertEq(registry.feeUseOf(token), FeeUses.CREATOR_BALANCE);
        assertEq(registry.implementationFor(token), address(creatorBalance));
    }

    function test_OnlyTheLauncherCanRecordACreatorsChoice() public {
        (address token,,) = _launch(HIGH_QUOTE);

        vm.prank(stranger);
        vm.expectRevert(FeeUseRegistry.NotLauncher.selector);
        registry.setLaunchFeeUse(token, FeeUses.AUTO_LP);
    }

    function test_ACreatorsChoiceIsWriteOnce() public {
        (address token,,) = _launch(HIGH_QUOTE, FeeUses.AUTO_LP, 0);

        vm.prank(address(launcher));
        vm.expectRevert(FeeUseRegistry.AlreadySet.selector);
        registry.setLaunchFeeUse(token, FeeUses.BUYBACK_BURN);
    }

    // =============================
    //  THE REGISTRY
    // =============================

    /// Ids are write-once. Repointing one under launches that already chose it would move their money
    /// without their knowing, so a new strategy has to be a new id.
    function test_AnIdCannotBeRepointedAtADifferentImplementation() public {
        vm.prank(owner);
        vm.expectRevert(FeeUseRegistry.FeeUseAlreadyRegistered.selector);
        registry.registerFeeUse(FeeUses.AUTO_LP, address(buybackBurn));
    }

    /// The escape hatch for a broken implementation: one write moves every launch on that id.
    function test_ReplacingAnImplementationMovesEveryLaunchOnThatId() public {
        (address token,,) = _launch(HIGH_QUOTE, FeeUses.AUTO_LP, 0);
        AutoLpFeeUse replacement = new AutoLpFeeUse(address(locker));

        vm.prank(stranger);
        vm.expectRevert();
        registry.replaceFeeUse(FeeUses.AUTO_LP, address(replacement));

        vm.prank(owner);
        registry.replaceFeeUse(FeeUses.AUTO_LP, address(replacement));

        assertEq(registry.implementationFor(token), address(replacement), "the launch followed it");
        assertEq(registry.feeUseOf(token), FeeUses.AUTO_LP, "without changing what it chose");
    }

    function test_ReplacingRejectsBlanksAndUnknownIds() public {
        vm.startPrank(owner);
        vm.expectRevert(FeeUseRegistry.UnknownFeeUse.selector);
        registry.replaceFeeUse(BROKEN, address(1));
        vm.expectRevert(FeeUseRegistry.ZeroAddress.selector);
        registry.replaceFeeUse(FeeUses.AUTO_LP, address(0));
        vm.stopPrank();
    }

    function test_RegisteringIsOwnerOnlyAndRejectsBlanks() public {
        vm.prank(stranger);
        vm.expectRevert();
        registry.registerFeeUse(BROKEN, address(1));

        vm.startPrank(owner);
        vm.expectRevert(FeeUseRegistry.UnknownFeeUse.selector);
        registry.registerFeeUse(bytes32(0), address(1));
        vm.expectRevert(FeeUseRegistry.ZeroAddress.selector);
        registry.registerFeeUse(BROKEN, address(0));
        vm.stopPrank();
    }

    function test_AnUnregisteredIdCannotBecomeTheDefaultOrBeAssigned() public {
        (address token,,) = _launch(HIGH_QUOTE);

        vm.startPrank(owner);
        vm.expectRevert(FeeUseRegistry.UnknownFeeUse.selector);
        registry.setDefaultFeeUse(BROKEN);
        vm.expectRevert(FeeUseRegistry.UnknownFeeUse.selector);
        registry.setFeeUse(token, BROKEN);
        vm.stopPrank();
    }

    /// The registry never holds tokens, so there is nothing in it to strand or rescue.
    function test_TheRegistryNeverHoldsAnything() public {
        (address token,,) = _launch(HIGH_QUOTE, FeeUses.CREATOR_BALANCE, 0);
        _accrueFees(token, 40_000, 8_000);
        locker.handleAllRewards(token);

        assertEq(IERC20(token).balanceOf(address(registry)), 0);
        assertEq(IERC20(HIGH_QUOTE).balanceOf(address(registry)), 0);
    }

    // =============================
    //  A BROKEN FEE USE
    // =============================

    /// Why spending is separate from the split: a fee use that reverts must not stop fees being collected,
    /// or one creator's broken strategy would hold the protocol's share hostage too.
    function test_ABrokenFeeUseCannotStopTheSplitAndStrandsNothing() public {
        vm.startPrank(owner);
        registry.registerFeeUse(BROKEN, address(new RevertingFeeUse()));
        vm.stopPrank();

        (address token,,) = _launch(HIGH_QUOTE);
        vm.prank(owner);
        registry.setFeeUse(token, BROKEN);

        _accrueFees(token, 40_000, 8_000);

        // The split goes through: it only books numbers.
        locker.splitRewards(token);
        assertEq(locker.creatorOwed(token, token), 30_000);
        assertEq(locker.protocolOwed(token), 10_000, "and the protocol was paid regardless");

        // Spending is what fails, and it fails without moving anything.
        vm.expectRevert("strategy is broken");
        locker.spendCreatorShare(token);
        assertEq(locker.creatorOwed(token, token), 30_000, "still booked, still reachable");

        // The one-click path routes too, so it goes down with it — just as harmlessly.
        vm.expectRevert("strategy is broken");
        locker.handleAllRewards(token);
        assertEq(locker.creatorOwed(token, token), 30_000);

        // And the admin can point it somewhere that works.
        vm.prank(owner);
        registry.setFeeUse(token, FeeUses.CREATOR_BALANCE);
        locker.spendCreatorShare(token);
        assertEq(IERC20(token).balanceOf(creator), 30_000, "reachable the whole time");
    }

    function test_SpendingWithNoRegisteredFeeUseReverts() public {
        (address token,,) = _launch(HIGH_QUOTE);
        _accrueFees(token, 40_000, 0);
        locker.splitRewards(token);

        // A registry with no default has nowhere to send anything.
        FeeUseRegistry bare = new FeeUseRegistry();
        vm.prank(owner);
        locker.setFeeUseRegistry(address(bare));

        vm.expectRevert(HydropumpLocker.UnknownFeeUse.selector);
        locker.spendCreatorShare(token);
    }

    // =============================
    //  ADMIN
    // =============================

    function test_PointersAreOwnerOnly() public {
        vm.prank(stranger);
        vm.expectRevert();
        registry.setLauncher(stranger);

        vm.prank(owner);
        registry.setLauncher(stranger);
        assertEq(registry.launcher(), stranger);
    }

    function test_UpgradeIsOwnerOnly() public {
        address newImpl = address(new FeeUseRegistry());

        vm.prank(stranger);
        vm.expectRevert();
        registry.upgradeToAndCall(newImpl, "");

        vm.prank(owner);
        registry.upgradeToAndCall(newImpl, "");
    }
}
