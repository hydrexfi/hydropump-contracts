// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HydropumpLaunchpad} from "../contracts/HydropumpLaunchpad.sol";
import {HydropumpAddresses} from "../contracts/libraries/HydropumpAddresses.sol";

/// @dev Launching end-to-end needs a live Algebra deployment; see test/fork/HydropumpLaunch.fork.t.sol.
///      These cover the bookkeeping and ownership surface that stands alone.
contract HydropumpLaunchpadTest is Test {
    HydropumpLaunchpad internal launchpad;

    address internal vaultOwner = makeAddr("vaultOwner");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        launchpad = new HydropumpLaunchpad(vaultOwner);
    }

    function test_ConstructorWiring() public view {
        assertEq(launchpad.vaultOwner(), vaultOwner);
        assertEq(launchpad.WETH(), HydropumpAddresses.WETH);
        assertEq(address(launchpad.nonfungiblePositionManager()), HydropumpAddresses.NONFUNGIBLE_POSITION_MANAGER);
        assertEq(launchpad.DEFAULT_SUPPLY(), 1_000_000_000e18);
        assertEq(launchpad.getTotalLaunches(), 0);
    }

    function test_ConstructorRejectsZeroVaultOwner() public {
        vm.expectRevert("Invalid vault owner");
        new HydropumpLaunchpad(address(0));
    }

    function test_LaunchRejectsZeroFeeClaimer() public {
        vm.expectRevert("Invalid fee claimer");
        launchpad.launch("Alpha", "ALPHA", "", address(0));
    }

    function test_SetVaultOwnerIsRestrictedToCurrentOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Not vault owner");
        launchpad.setVaultOwner(stranger);

        vm.prank(vaultOwner);
        vm.expectRevert("Invalid vault owner");
        launchpad.setVaultOwner(address(0));

        vm.prank(vaultOwner);
        launchpad.setVaultOwner(stranger);
        assertEq(launchpad.vaultOwner(), stranger);
    }

    function test_EmptyQueriesAreSafe() public {
        (HydropumpLaunchpad.LaunchDetails[] memory page, uint256 total) = launchpad.getLaunches(0, 10);
        assertEq(page.length, 0);
        assertEq(total, 0);
        assertEq(launchpad.getLatestLaunches(5).length, 0);

        vm.expectRevert("Token not launched");
        launchpad.getLaunchByToken(address(1));

        vm.expectRevert("Index out of bounds");
        launchpad.getLaunchByIndex(0);
    }
}
