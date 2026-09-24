// SPDX-License-Identifier: MIT
pragma solidity =0.8.20;

import {Test} from 'forge-std/Test.sol';
import {HydrexBasePlugin} from '../../contracts/plugins/HydrexBasePlugin.sol';
import {HydrexBasePluginFactory} from '../../contracts/plugins/HydrexBasePluginFactory.sol';
import {AlgebraFeeConfiguration} from '../../contracts/plugins/base/AlgebraFeeConfiguration.sol';
import {IAlgebraPlugin} from '@cryptoalgebra/integral-core/contracts/interfaces/plugin/IAlgebraPlugin.sol';
import {ISecurityPlugin} from '../../contracts/plugins/interfaces/plugins/ISecurityPlugin.sol';
import {ISecurityRegistry} from '../../contracts/plugins/interfaces/plugins/ISecurityRegistry.sol';

contract PluginPoolMock {
  address public plugin;
  uint8 public config;
  uint16 public fee = 10000;
  int24 public tick;
  uint160 public price = uint160(1 << 96);
  function setPlugin(address value) external { plugin = value; }
  function setPluginConfig(uint8 value) external { config = value; }
  function setTick(int24 value) external { tick = value; }
  function setFee(uint16 value) external { fee = value; }
  function globalState() external view returns (uint160, int24, uint16, uint8, uint16, bool) {
    return (price, tick, fee, config, 0, true);
  }
}

contract PluginAuthorityMock {
  address public immutable owner;
  address public farmingAddress;
  constructor() { owner = msg.sender; }
  function hasRoleOrOwner(bytes32, address user) external view returns (bool) { return user == owner; }
  function setFarmingAddress(address user) external { farmingAddress = user; }
}

contract SecurityRegistryMock {
  ISecurityRegistry.Status public status;
  function setStatus(ISecurityRegistry.Status value) external { status = value; }
  function getPoolStatus(address) external view returns (ISecurityRegistry.Status) { return status; }
}

contract VirtualPoolMock {
  int24 public lastTick;
  bool public lastDirection;
  function crossTo(int24 tick, bool direction) external returns (bool) { lastTick = tick; lastDirection = direction; return true; }
}

contract HydrexBasePluginTest is Test {
  HydrexBasePlugin internal plugin;
  PluginPoolMock internal pool;
  PluginAuthorityMock internal authority;
  uint256 internal constant START = 100;

  function setUp() public virtual {
    vm.roll(START);
    vm.warp(1000);
    pool = new PluginPoolMock();
    authority = new PluginAuthorityMock();
    plugin = new HydrexBasePlugin(address(pool), address(authority), address(authority), _config(3000), 4000);
    pool.setPlugin(address(plugin));
    _initialize(plugin, pool);
    // Existing behavior is asserted after the proposed launch window.
    vm.roll(START + 10);
  }

  function _config(uint16 baseFee) internal pure returns (AlgebraFeeConfiguration memory) {
    return AlgebraFeeConfiguration(0, 0, 0, 0, 1, 1, baseFee);
  }

  function _initialize(HydrexBasePlugin p, PluginPoolMock target) internal {
    vm.startPrank(address(target));
    assertEq(p.beforeInitialize(address(this), uint160(1 << 96)), IAlgebraPlugin.beforeInitialize.selector);
    assertEq(p.afterInitialize(address(this), uint160(1 << 96), 0), IAlgebraPlugin.afterInitialize.selector);
    vm.stopPrank();
  }

  function _swap(bool direction) internal returns (uint24 fee) {
    vm.prank(address(pool));
    (bytes4 selector, uint24 overrideFee, uint24 pluginFee) = plugin.beforeSwap(address(this), address(this), direction, 1 ether, 0, false, '');
    assertEq(selector, IAlgebraPlugin.beforeSwap.selector);
    assertEq(pluginFee, 0);
    return overrideFee;
  }

  function test_InitializationConfiguresOracleAndCallbacks() public view {
    assertTrue(plugin.isInitialized());
    assertEq(plugin.lastTimepointTimestamp(), 1000);
    assertEq(pool.config(), plugin.defaultPluginConfig());
  }

  function test_OnlyPoolCanCallSwapAndInitialize() public {
    vm.expectRevert(bytes('Only pool can call this'));
    plugin.beforeSwap(address(this), address(this), true, 1, 0, false, '');
    vm.expectRevert(bytes('Only pool can call this'));
    plugin.afterInitialize(address(this), uint160(1 << 96), 0);
    vm.expectRevert(bytes('Only pool can call this'));
    plugin.afterSwap(address(this), address(this), true, 1, 0, 0, 0, '');
  }

  function test_NoOverridesWhenFeeModesDisabled() public { assertEq(_swap(true), 0); }

  function test_DynamicFeeUsesConfiguredBase() public {
    plugin.changeDynamicFeeStatus(true);
    assertEq(_swap(true), 3000);
    assertEq(_swap(false), 3000);
  }

  function test_SlidingFeeUsesItsOwnBaseWhenDynamicDisabled() public {
    plugin.changeSlidingFeeStatus(true);
    assertEq(_swap(true), 4000);
    assertEq(_swap(false), 4000);
  }

  function test_SlidingFeeUsesDynamicBaseWhenBothEnabled() public {
    plugin.changeDynamicFeeStatus(true);
    plugin.changeSlidingFeeStatus(true);
    assertEq(_swap(true), 3000);
  }

  function test_SwapUpdatesOracleOnlyOncePerTimestamp() public {
    vm.warp(1002);
    pool.setTick(50);
    _swap(true);
    assertEq(plugin.timepointIndex(), 1);
    assertEq(plugin.lastTimepointTimestamp(), 1002);
    _swap(false);
    assertEq(plugin.timepointIndex(), 1);
  }

  function test_SecurityChecksRejectSwaps() public {
    SecurityRegistryMock registry = new SecurityRegistryMock();
    plugin.setSecurityRegistry(address(registry));
    registry.setStatus(ISecurityRegistry.Status.DISABLED);
    vm.prank(address(pool));
    vm.expectRevert(ISecurityPlugin.PoolDisabled.selector);
    plugin.beforeSwap(address(this), address(this), true, 1, 0, false, '');
    registry.setStatus(ISecurityRegistry.Status.BURN_ONLY);
    vm.prank(address(pool));
    vm.expectRevert(ISecurityPlugin.BurnOnly.selector);
    plugin.beforeSwap(address(this), address(this), false, 1, 0, false, '');
  }

  function test_FeeAndSecuritySettingsRequireAuthorization() public {
    vm.startPrank(address(0xBAD));
    vm.expectRevert(); plugin.changeDynamicFeeStatus(true);
    vm.expectRevert(); plugin.changeSlidingFeeStatus(true);
    vm.expectRevert(); plugin.changeFeeConfiguration(_config(5000));
    vm.expectRevert(); plugin.setSecurityRegistry(address(1));
    vm.stopPrank();
    assertEq(plugin.getSecurityRegistry(), address(0));
  }

  function test_AfterSwapStillUpdatesFarming() public {
    VirtualPoolMock incentive = new VirtualPoolMock();
    authority.setFarmingAddress(address(this));
    plugin.setIncentive(address(incentive));
    pool.setTick(42);
    vm.prank(address(pool));
    plugin.afterSwap(address(this), address(this), true, 1, 0, 0, 0, '');
    assertEq(incentive.lastTick(), 42);
    assertTrue(incentive.lastDirection());
  }

  function test_FactoryDeploysConfiguredPluginAndRejectsDuplicates() public {
    HydrexBasePluginFactory factory = new HydrexBasePluginFactory(address(authority));
    factory.setDynamicFeeStatus(true);
    factory.setSlidingFeeStatus(true);
    factory.setDefaultBaseFee(5000);
    vm.expectRevert();
    factory.beforeCreatePoolHook(address(pool), address(this), address(0), address(1), address(2), '');
    vm.prank(address(authority));
    address deployed = factory.beforeCreatePoolHook(address(pool), address(this), address(0), address(1), address(2), '');
    assertEq(factory.pluginByPool(address(pool)), deployed);
    assertEq(HydrexBasePlugin(deployed).pool(), address(pool));
    assertTrue(HydrexBasePlugin(deployed).dynamicFeeEnabled());
    assertTrue(HydrexBasePlugin(deployed).slidingFeeEnabled());
    vm.prank(address(authority));
    vm.expectRevert(bytes('Already created'));
    factory.beforeCreatePoolHook(address(pool), address(this), address(0), address(1), address(2), '');
  }
}
