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
}
