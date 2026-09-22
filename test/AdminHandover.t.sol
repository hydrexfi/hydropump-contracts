// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HydropumpFixture} from "./helpers/HydropumpFixture.sol";
import {CheckAdminHandover} from "../script/deploy/CheckAdminHandover.s.sol";

contract AdminHandoverTest is HydropumpFixture {
    function test_PendingTransferIsNotACompletedDeployment() public {
        CheckAdminHandover checker = new CheckAdminHandover();
        vm.startPrank(owner);
        locker.transferOwnership(admin);
        registry.transferOwnership(admin);
        vm.stopPrank();
        vm.expectRevert("locker handover incomplete");
        checker.verify(address(locker), address(registry), admin);
        vm.prank(stranger);
        vm.expectRevert();
        locker.acceptOwnership();
        vm.prank(admin);
        locker.acceptOwnership();
        vm.expectRevert("registry handover incomplete");
        checker.verify(address(locker), address(registry), admin);
        vm.prank(admin);
        registry.acceptOwnership();
        checker.verify(address(locker), address(registry), admin);
        assertEq(locker.owner(), admin);
        assertEq(registry.owner(), admin);
    }
}
