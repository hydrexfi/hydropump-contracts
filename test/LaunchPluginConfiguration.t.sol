// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {HydropumpFixture} from "./helpers/HydropumpFixture.sol";
import {HydropumpLauncher} from "../contracts/core/HydropumpLauncher.sol";
import {HydropumpAddresses} from "../contracts/libraries/HydropumpAddresses.sol";
import {FeeUses} from "../contracts/libraries/FeeUses.sol";

contract DeployerIdentityMock {
    address public immutable launcher;
    address public immutable algebraFactory;

    constructor(address launcher_, address factory_) {
        launcher = launcher_;
        algebraFactory = factory_;
    }
}

contract LaunchPluginConfigurationTest is HydropumpFixture {
    function _fresh() internal returns (HydropumpLauncher) {
        return HydropumpLauncher(
            address(
                new ERC1967Proxy(
                    address(new HydropumpLauncher()),
                    abi.encodeCall(
                        HydropumpLauncher.initialize, (owner, admin, address(locker), address(directory), LAUNCH_FEE)
                    )
                )
            )
        );
    }

    function test_BindingRequiresAdminAndCannotBeChanged() public {
        HydropumpLauncher fresh = _fresh();
        address deployer = address(new DeployerIdentityMock(address(fresh), HydropumpAddresses.ALGEBRA_FACTORY));
        vm.prank(owner);
        vm.expectRevert(HydropumpLauncher.NotAdmin.selector);
        fresh.setPoolDeployer(deployer);
        vm.prank(admin);
        fresh.setPoolDeployer(deployer);
        assertEq(fresh.poolDeployer(), deployer);
        vm.prank(admin);
        vm.expectRevert(HydropumpLauncher.PoolDeployerAlreadyConfigured.selector);
        fresh.setPoolDeployer(deployer);
    }

    function test_BindingRejectsWrongFactoryOrLauncher() public {
        HydropumpLauncher fresh = _fresh();
        address wrongLauncher = address(new DeployerIdentityMock(stranger, HydropumpAddresses.ALGEBRA_FACTORY));
        address wrongFactory = address(new DeployerIdentityMock(address(fresh), stranger));
        vm.startPrank(admin);
        vm.expectRevert(HydropumpLauncher.InvalidPoolDeployer.selector);
        fresh.setPoolDeployer(address(0));
        vm.expectRevert(HydropumpLauncher.InvalidPoolDeployer.selector);
        fresh.setPoolDeployer(wrongLauncher);
        vm.expectRevert(HydropumpLauncher.InvalidPoolDeployer.selector);
        fresh.setPoolDeployer(wrongFactory);
        vm.stopPrank();
    }

    function test_UnconfiguredLauncherFailsClosed() public {
        HydropumpLauncher fresh = _fresh();
        vm.prank(creator);
        vm.expectRevert(HydropumpLauncher.PoolDeployerNotConfigured.selector);
        fresh.launch{value: LAUNCH_FEE}(HydropumpLauncher.LaunchParams("No", "NO", HIGH_QUOTE, creator, 0, bytes32(0)));
        assertEq(address(fresh).balance, 0);
    }

    function test_BuybackUsesPositionNamespaceIncludingLegacyZero() public {
        (address token,, uint256[] memory ids) = _launch(HIGH_QUOTE, FeeUses.BUYBACK_BURN, 0);
        _accrueFees(token, 0, 1e15);
        locker.handleAllRewards(token);
        assertEq(router.lastDeployer(), launcher.poolDeployer());
        // Existing launches retain zero in their NPM position even after launcher upgrades.
        npm.setPositionDeployer(ids[0], address(0));
        _accrueFees(token, 0, 1e15);
        locker.handleAllRewards(token);
        assertEq(router.lastDeployer(), address(0));
    }

    function test_ProtocolConversionUsesPositionNamespaceIncludingLegacyZero() public {
        (address token,, uint256[] memory ids) = _launch(HIGH_QUOTE);
        _seedPoolQuote(token, 10e18);
        _accrueFees(token, 1e22, 0);
        locker.splitRewards(token);
        assertGt(locker.convertProtocolShare(token), 0);
        assertEq(router.lastDeployer(), launcher.poolDeployer());
        npm.setPositionDeployer(ids[0], address(0));
        _accrueFees(token, 1e22, 0);
        locker.splitRewards(token);
        assertGt(locker.convertProtocolShare(token), 0);
        assertEq(router.lastDeployer(), address(0));
    }
}
