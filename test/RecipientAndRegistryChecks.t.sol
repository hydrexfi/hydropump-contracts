// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {HydropumpLauncher} from "../contracts/core/HydropumpLauncher.sol";
import {HydropumpLocker} from "../contracts/core/HydropumpLocker.sol";
import {FeeUseRegistry} from "../contracts/helpers/FeeUseRegistry.sol";
import {FeeUses} from "../contracts/libraries/FeeUses.sol";
import {HydropumpFixture} from "./helpers/HydropumpFixture.sol";

/// @notice Two input checks a creator or an admin can trip into by mistake, each of which silently loses
///         or misroutes a creator's fees. Adapted from the security review's `test_CG6` and `test_CG10`
///         proof-of-concept tests.
contract RecipientAndRegistryChecksTest is HydropumpFixture {
    // ==========================================================================================
    //  Recipient cannot be the locker or the registry (HP-11)
    // ==========================================================================================

    /// @dev A creator recipient set to the locker itself pays the locker, whose balance-delta re-book in
    ///      `spendCreatorShare` credits the payout straight back — and only the recipient can change the
    ///      recipient, which the locker never will. The share can never leave.
    function test_HP11_recipientCannotBeSetToTheLockerAtLaunch() public {
        vm.prank(creator);
        vm.expectRevert(HydropumpLocker.InvalidCreatorRecipient.selector);
        launcher.launch{value: LAUNCH_FEE}(
            HydropumpLauncher.LaunchParams({
                name: "Alpha",
                symbol: "ALPHA",
                quoteToken: HIGH_QUOTE,
                creatorRecipient: address(locker),
                buyAmount: 0,
                feeUse: FeeUses.CREATOR_BALANCE
            })
        );
    }

    /// @dev Same trap, reached later: an ordinary recipient repoints itself to the locker.
    function test_HP11_recipientCannotBeSetToTheLockerViaSetCreatorRecipient() public {
        (address token,,) = _launch(HIGH_QUOTE, FeeUses.CREATOR_BALANCE, 0);

        vm.prank(creator);
        vm.expectRevert(HydropumpLocker.InvalidCreatorRecipient.selector);
        locker.setCreatorRecipient(token, address(locker));
    }

    /// @dev The fee-use registry as recipient traps the share the same way: `spendCreatorShare` transfers
    ///      it out to the registry's address before calling `onFees`, and nothing sends it onward.
    function test_HP11_recipientCannotBeSetToTheRegistryAtLaunch() public {
        vm.prank(creator);
        vm.expectRevert(HydropumpLocker.InvalidCreatorRecipient.selector);
        launcher.launch{value: LAUNCH_FEE}(
            HydropumpLauncher.LaunchParams({
                name: "Alpha",
                symbol: "ALPHA",
                quoteToken: HIGH_QUOTE,
                creatorRecipient: address(registry),
                buyAmount: 0,
                feeUse: FeeUses.CREATOR_BALANCE
            })
        );
    }

    function test_HP11_recipientCannotBeSetToTheRegistryViaSetCreatorRecipient() public {
        (address token,,) = _launch(HIGH_QUOTE, FeeUses.CREATOR_BALANCE, 0);

        vm.prank(creator);
        vm.expectRevert(HydropumpLocker.InvalidCreatorRecipient.selector);
        locker.setCreatorRecipient(token, address(registry));
    }

    /// @dev The check must reject exactly the locker and the registry, not recipients in general.
    function test_HP11_ordinaryRecipientStillWorks() public {
        vm.prank(creator);
        (address token,,) = launcher.launch{value: LAUNCH_FEE}(
            HydropumpLauncher.LaunchParams({
                name: "Alpha",
                symbol: "ALPHA",
                quoteToken: HIGH_QUOTE,
                creatorRecipient: stranger,
                buyAmount: 0,
                feeUse: FeeUses.CREATOR_BALANCE
            })
        );
        assertEq(locker.creatorRecipient(token), stranger, "an ordinary recipient is accepted at launch");

        vm.prank(stranger);
        locker.setCreatorRecipient(token, creator);
        assertEq(locker.creatorRecipient(token), creator, "and can repoint to another ordinary recipient");
    }

    // ==========================================================================================
    //  Launcher and locker registries must agree (HP-08)
    // ==========================================================================================

    /// @dev The launcher records a creator's fee-use choice in its own `feeUseRegistry`; the locker spends
    ///      through its own. If an admin repoints only one — a half-finished redeploy — a creator who chose
    ///      AUTO_LP would be silently spent as the locker registry's default instead.
    function test_HP08_divergentRegistriesRevertLaunch() public {
        FeeUseRegistry other = FeeUseRegistry(
            address(
                new ERC1967Proxy(
                    address(new FeeUseRegistry()), abi.encodeCall(FeeUseRegistry.initialize, (owner, address(launcher)))
                )
            )
        );
        vm.startPrank(owner);
        other.registerFeeUse(FeeUses.CREATOR_BALANCE, address(creatorBalance));
        other.registerFeeUse(FeeUses.AUTO_LP, address(autoLp));
        other.setDefaultFeeUse(FeeUses.CREATOR_BALANCE);
        vm.stopPrank();

        // The launcher now records choices in `other`; the locker still spends through `registry`.
        vm.prank(admin);
        launcher.setFeeUseRegistry(address(other));

        vm.prank(creator);
        vm.expectRevert(HydropumpLauncher.FeeUseRegistryMismatch.selector);
        launcher.launch{value: LAUNCH_FEE}(
            HydropumpLauncher.LaunchParams({
                name: "Alpha",
                symbol: "ALPHA",
                quoteToken: HIGH_QUOTE,
                creatorRecipient: creator,
                buyAmount: 0,
                feeUse: FeeUses.AUTO_LP
            })
        );
    }

    /// @dev The fixture wires both to the same registry, so a launch still succeeds and the creator's
    ///      choice lands where the locker will actually spend it.
    function test_HP08_matchingRegistriesLaunchSucceedsAndCreatorChoiceIsRespected() public {
        assertEq(launcher.feeUseRegistry(), address(registry));
        assertEq(locker.feeUseRegistry(), address(registry));

        (address token,,) = _launch(HIGH_QUOTE, FeeUses.AUTO_LP, 0);
        assertEq(registry.feeUseOf(token), FeeUses.AUTO_LP, "the creator's choice is recorded");
        assertEq(locker.feeUseRegistry(), address(registry), "and it is the registry the locker spends through");
    }

    /// @dev A launcher/locker pair that never had a registry wired at all — the state before either
    ///      `setFeeUseRegistry` call runs — must still be able to launch, exactly as it does on unfixed
    ///      main: `HydropumpLauncher.launch` already skips `setLaunchFeeUse` whenever its own registry is
    ///      unset, and the new check only compares the two pointers against each other, not against zero.
    function test_HP08_bothRegistriesUnsetStillLaunches() public {
        HydropumpLocker freshLocker = HydropumpLocker(
            address(
                new ERC1967Proxy(
                    address(new HydropumpLocker()),
                    abi.encodeCall(HydropumpLocker.initialize, (owner, address(0), buyback, CREATOR_FEE, PROTOCOL_FEE))
                )
            )
        );
        HydropumpLauncher freshLauncher = HydropumpLauncher(
            address(
                new ERC1967Proxy(
                    address(new HydropumpLauncher()),
                    abi.encodeCall(
                        HydropumpLauncher.initialize,
                        (owner, admin, address(freshLocker), address(directory), LAUNCH_FEE)
                    )
                )
            )
        );
        vm.prank(owner);
        freshLocker.setLauncher(address(freshLauncher));

        assertEq(freshLauncher.feeUseRegistry(), address(0), "launcher registry starts unset");
        assertEq(freshLocker.feeUseRegistry(), address(0), "locker registry starts unset");

        vm.prank(creator);
        (address token,,) = freshLauncher.launch{value: LAUNCH_FEE}(
            HydropumpLauncher.LaunchParams({
                name: "Alpha",
                symbol: "ALPHA",
                quoteToken: HIGH_QUOTE,
                creatorRecipient: creator,
                buyAmount: 0,
                feeUse: bytes32(0)
            })
        );
        assertTrue(token != address(0), "launch succeeds with both registries unset");
    }
}
