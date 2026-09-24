// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForkFixture} from "./helpers/ForkFixture.sol";
import {HydropumpLauncher} from "../../contracts/core/HydropumpLauncher.sol";
import {IHydropumpPoolDeployer} from "../../contracts/interfaces/IHydropumpPoolDeployer.sol";
import {HydropumpAddresses} from "../../contracts/libraries/HydropumpAddresses.sol";
import {FeeUses} from "../../contracts/libraries/FeeUses.sol";
import {ILaunchAlgebraFactory} from "../helpers/LaunchPluginSetup.sol";

interface ILaunchPlugin {
    function launchBlock() external view returns (uint256);
    function launchFeeStarted() external view returns (bool);
}

interface IPluginPool {
    function plugin() external view returns (address);
    function initialize(uint160 price) external;
}

interface ILaunchFactorySettings {
    struct Config {
        uint16 a1;
        uint16 a2;
        uint32 b1;
        uint32 b2;
        uint16 g1;
        uint16 g2;
        uint16 base;
    }

    function defaultFeeConfiguration() external view returns (Config memory);
    function setDefaultFeeConfiguration(Config calldata config) external;
    function dynamicFeeStatus() external view returns (bool);
    function slidingFeeStatus() external view returns (bool);
    function setDynamicFeeStatus(bool status) external;
    function setSlidingFeeStatus(bool status) external;
    function securityRegistry() external view returns (address);
    function farmingAddress() external view returns (address);
    function defaultBaseFee() external view returns (uint16);
    function beforeCreatePoolHook(address, address, address, address, address, bytes calldata)
        external
        returns (address);
    function createPluginForExistingPool(address, address) external returns (address);
}

/// @dev Real launcher, Position Manager, router and pools. Repeated with launch token on either side.
contract LaunchFeeFlowForkTest is ForkFixture {
    ILaunchAlgebraFactory constant FACTORY = ILaunchAlgebraFactory(HydropumpAddresses.ALGEBRA_FACTORY);
    bytes32 constant SWAP = keccak256("Swap(address,address,int256,int256,uint160,uint128,int24,uint24,uint24)");
    address internal originalDefault;

    function _waitForNormalFees() internal pure override returns (bool) {
        return false;
    }

    function _wantToken0() internal pure virtual returns (bool) {
        return true;
    }

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        originalDefault = FACTORY.defaultPluginFactory();
        ILaunchFactorySettings source = ILaunchFactorySettings(originalDefault);
        ILaunchFactorySettings target = ILaunchFactorySettings(launcher.poolDeployer());
        assertEq(abi.encode(source.defaultFeeConfiguration()), abi.encode(target.defaultFeeConfiguration()));
        assertEq(source.dynamicFeeStatus(), target.dynamicFeeStatus());
        assertEq(source.slidingFeeStatus(), target.slidingFeeStatus());
        assertEq(source.securityRegistry(), target.securityRegistry());
        assertEq(source.farmingAddress(), target.farmingAddress());
        assertEq(source.defaultBaseFee(), target.defaultBaseFee());
        // Deterministic normal fee only on this fork's dedicated factory, never the shared one.
        vm.startPrank(FACTORY.owner());
        target.setDefaultFeeConfiguration(ILaunchFactorySettings.Config(0, 0, 0, 0, 1, 1, 10000));
        if (!target.dynamicFeeStatus()) target.setDynamicFeeStatus(true);
        if (target.slidingFeeStatus()) target.setSlidingFeeStatus(false);
        vm.stopPrank();
    }

    function _launchFlow(uint256 buy) internal returns (address token, address pool, uint256[] memory ids) {
        _arrangeSide(WETH, _wantToken0());
        return _launchFrom(creator, WETH, FeeUses.CREATOR_BALANCE, buy);
    }

    function _assertFee(Vm.Log[] memory logs, address pool, uint24 expected) internal pure {
        uint256 count;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != pool || logs[i].topics.length == 0 || logs[i].topics[0] != SWAP) continue;
            (,,,,, uint24 fee, uint24 extra) =
                abi.decode(logs[i].data, (int256, int256, uint160, uint128, int24, uint24, uint24));
            assertEq(fee, expected, "actual real-pool swap fee");
            assertEq(extra, 0);
            count++;
        }
        assertEq(count, 1, "exactly one pool swap");
    }

    function test_FullLaunchCreatesPluginAndLocksCustomPositions() public onlyForked {
        (address token, address pool, uint256[] memory ids) = _launchFlow(0);
        address deployer = launcher.poolDeployer();
        assertEq(FACTORY.customPoolByPair(deployer, token, WETH), pool);
        assertEq(FACTORY.poolByPair(token, WETH), address(0));
        address plugin = IPluginPool(pool).plugin();
        assertEq(IHydropumpPoolDeployer(deployer).pluginByPool(pool), plugin);
        assertLe(plugin.code.length, 24576);
        assertEq(ILaunchPlugin(plugin).launchBlock(), block.number);
        assertTrue(ILaunchPlugin(plugin).launchFeeStarted());
        for (uint256 i; i < ids.length; i++) {
            (,,,, address namespace,,,,,,,) = NPM.positions(ids[i]);
            assertEq(namespace, deployer);
        }
        _assertCurveShape(token, WETH, pool, ids);
        assertEq(locker.poolOf(token), pool);
        assertEq(FACTORY.defaultPluginFactory(), originalDefault);
    }

    function test_BuyAndSellEveryBlockThroughExpiry() public onlyForked {
        (address token, address pool,) = _launchFlow(0);
        // Use the recorded value: Solidity may reuse block.number expressions
        // across vm.roll(), which is a test-only mutation of normally constant state.
        uint256 start = ILaunchPlugin(IPluginPool(pool).plugin()).launchBlock();
        for (uint256 i; i <= 11; i++) {
            vm.roll(start + i);
            uint24 fee = i >= 10 ? 10000 : uint24(990000 - 98000 * i);
            vm.recordLogs();
            uint256 bought = _swapIn(alice, WETH, token, 0.001 ether);
            _assertFee(vm.getRecordedLogs(), pool, fee);
            assertGt(bought, 0);
            vm.recordLogs();
            uint256 back = _sell(alice, token, WETH, bought / 2);
            _assertFee(vm.getRecordedLogs(), pool, fee);
            assertGt(back, 0);
        }
    }

    function test_CreatorBuyPays99PercentAndFeesReachLocker() public onlyForked {
        vm.recordLogs();
        (address token, address pool,) = _launchFlow(0.01 ether);
        _assertFee(vm.getRecordedLogs(), pool, 990000);
        assertGt(IERC20(token).balanceOf(creator), 0);
        assertEq(IERC20(WETH).balanceOf(creator), 0);
        locker.splitRewards(token);
        (, uint128 quoteFees) = locker.lifetimeFees(token);
        // Pinned Base factory: 15/1000 of swap fees go to community, rest to LPs.
        assertApproxEqAbs(quoteFees, 0.0099 ether * 985 / 1000, 10);
        assertEq(IERC20(WETH).balanceOf(address(locker)), quoteFees);
    }

    function test_ExistingStandardPoolCannotBlockCustomLaunch() public onlyForked {
        _arrangeSide(WETH, _wantToken0());
        address next = vm.computeCreateAddress(address(launcher), vm.getNonce(address(launcher)));
        address standard = FACTORY.createPool(next, WETH, "");
        IPluginPool(standard).initialize(uint160(1 << 96));
        address oldPlugin = IPluginPool(standard).plugin();
        (address token, address pool,) = _launchFrom(creator, WETH, bytes32(0), 0);
        assertEq(token, next);
        assertTrue(pool != standard);
        assertEq(FACTORY.poolByPair(token, WETH), standard);
        assertEq(IPluginPool(standard).plugin(), oldPlugin);
        assertEq(FACTORY.defaultPluginFactory(), originalDefault);
    }

    function test_MissingRoleRevertsLaunchAtomically() public onlyForked {
        address deployer = launcher.poolDeployer();
        bytes32 role = FACTORY.CUSTOM_POOL_DEPLOYER();
        vm.prank(FACTORY.owner());
        FACTORY.revokeRole(role, deployer);
        address next = vm.computeCreateAddress(address(launcher), vm.getNonce(address(launcher)));
        vm.prank(creator);
        vm.expectRevert(bytes("Can`t create custom pools"));
        launcher.launch{value: LAUNCH_FEE}(HydropumpLauncher.LaunchParams("Fail", "FAIL", WETH, creator, 0, bytes32(0)));
        assertEq(next.code.length, 0);
        assertEq(FACTORY.customPoolByPair(deployer, next, WETH), address(0));
        assertEq(address(launcher).balance, 0);
    }

    function test_RejectsOutsidersForgedCallbacksAndRetrofits() public onlyForked {
        address deployer = launcher.poolDeployer();
        vm.expectRevert(bytes4(keccak256("OnlyLauncher()")));
        IHydropumpPoolDeployer(deployer).createPool(address(1), WETH);
        vm.expectRevert(bytes4(keccak256("InvalidCallback()")));
        ILaunchFactorySettings(deployer)
            .beforeCreatePoolHook(address(1), address(launcher), deployer, address(2), WETH, "");
        vm.prank(address(FACTORY));
        vm.expectRevert(bytes4(keccak256("InvalidCallback()")));
        ILaunchFactorySettings(deployer)
            .beforeCreatePoolHook(address(1), address(launcher), deployer, address(2), WETH, "");
        vm.expectRevert(bytes4(keccak256("ExistingPoolNotSupported()")));
        ILaunchFactorySettings(deployer).createPluginForExistingPool(address(2), WETH);
    }
}

contract LaunchFeeFlowMirroredForkTest is LaunchFeeFlowForkTest {
    function _wantToken0() internal pure override returns (bool) {
        return false;
    }
}
