// SPDX-License-Identifier: MIT
pragma solidity =0.8.20;

import './HydrexBasePlugin.t.sol';

contract LaunchFeeTest is HydrexBasePluginTest {
  function test_CannotRestartWindow() public {
    vm.prank(address(pool));
    vm.expectRevert(HydrexBasePlugin.PluginAlreadyInitialized.selector);
    plugin.afterInitialize(address(this), uint160(1 << 96), 0);
    vm.expectRevert(bytes('Already initialized'));
    plugin.initialize();
    assertEq(plugin.launchBlock(), START);
    assertTrue(plugin.launchFeeStarted());
  }

  function test_StartIsPoolInitializationNotPluginDeployment() public {
    PluginPoolMock otherPool = new PluginPoolMock();
    HydrexBasePlugin other = new HydrexBasePlugin(address(otherPool), address(authority), address(authority), _config(3000), 4000);
    otherPool.setPlugin(address(other));
    vm.roll(START + 100);
    _initialize(other, otherPool);
    assertEq(other.launchBlock(), START + 100);
    vm.prank(address(otherPool));
    (, uint24 fee,) = other.beforeSwap(address(this), address(this), true, 1, 0, false, '');
    assertEq(fee, 990000);
    assertEq(_swap(true), 0, 'other pool must not restart original window');
  }

  function test_ExistingPoolOracleInitializationDoesNotApplyLaunchFee() public {
    HydrexBasePlugin other = new HydrexBasePlugin(address(pool), address(authority), address(authority), _config(3000), 4000);
    pool.setPlugin(address(other));
    other.initialize();
    assertFalse(other.launchFeeStarted());
    vm.prank(address(pool));
    (, uint24 fee,) = other.beforeSwap(address(this), address(this), true, 1, 0, false, '');
    assertEq(fee, 0);
  }

  function test_NoCreatorRouterOrExactOutputExemptions() public {
    vm.roll(START);
    for (uint256 i; i < 4; i++) {
      vm.prank(address(pool));
      (, uint24 fee, uint24 extra) = plugin.beforeSwap(address(uint160(i + 1)), address(this), i % 2 == 0, -1 ether, 0, i > 1, 'arbitrary data');
      assertEq(fee, 990000);
      assertEq(extra, 0);
    }
  }

  function test_SecurityRemainsActiveDuringLaunch() public {
    vm.roll(START);
    test_SecurityChecksRejectSwaps();
  }

  function test_FarmingRemainsActiveDuringLaunch() public {
    vm.roll(START);
    test_AfterSwapStillUpdatesFarming();
  }

  function test_SlidingFactorsKeepUpdatingDuringLaunch() public {
    vm.roll(START);
    plugin.changeSlidingFeeStatus(true);
    pool.setTick(100);
    vm.warp(1002);
    assertEq(_swap(true), 990000);
    (uint128 factor0, uint128 factor1) = plugin.s_feeFactors();
    assertLt(factor0, uint128(1 << 96));
    assertGt(factor1, uint128(1 << 96));
    vm.roll(START + 10);
    assertLt(_swap(true), 4000);
    assertGt(_swap(false), 4000);
  }

  function test_NormalFeeChangesAreRespectedWithoutRestart() public {
    vm.roll(START + 5);
    pool.setFee(20000);
    assertEq(_swap(true), 505000);
    plugin.changeDynamicFeeStatus(true);
    plugin.changeFeeConfiguration(_config(6000));
    assertEq(_swap(true), 498000);
    assertEq(plugin.launchBlock(), START);
    vm.roll(START + 10);
    assertEq(_swap(true), 6000);
  }

  // Invariant: for a fixed normal fee the launch fee is monotonic, bounded,
  // and becomes the original override exactly ten blocks after initialization.
  function testFuzz_FeeBoundsAndMonotonicity(uint16 normalFee, bool dynamic, bool direction) public {
    pool.setFee(normalFee);
    if (dynamic) {
      plugin.changeDynamicFeeStatus(true);
      plugin.changeFeeConfiguration(_config(normalFee));
    }
    uint256 previous = 990000;
    for (uint256 elapsed; elapsed < 10; elapsed++) {
      vm.roll(START + elapsed);
      uint24 fee = _swap(direction);
      assertEq(fee, 990000 - ((990000 - uint256(normalFee)) * elapsed) / 10);
      assertLe(fee, previous);
      assertGe(fee, normalFee);
      assertLt(fee, 1000000);
      previous = fee;
    }
    vm.roll(START + 10);
    assertEq(_swap(direction), dynamic ? normalFee : 0);
  }

  function test_LaunchStartsAt99PercentForBothDirections() public {
    vm.roll(START);
    assertEq(_swap(true), 990000);
    assertEq(_swap(false), 990000);
  }

  function test_LinearDecayEveryBlockThenRestoresPoolFallback() public {
    for (uint256 elapsed; elapsed < 10; elapsed++) {
      vm.roll(START + elapsed);
      assertEq(_swap(true), 990000 - elapsed * 98000);
    }
    vm.roll(START + 10);
    assertEq(_swap(true), 0, 'zero means use the stored pool fee');
    vm.roll(START + 100);
    assertEq(_swap(false), 0);
  }

  function test_DecayReturnsToDynamicAndSlidingFee() public {
    plugin.changeDynamicFeeStatus(true);
    plugin.changeSlidingFeeStatus(true);
    vm.roll(START + 5);
    assertEq(_swap(true), 496500);
    vm.roll(START + 10);
    assertEq(_swap(true), 3000);
  }

  function test_TimeDoesNotAdvanceBlockBasedDecay() public {
    vm.roll(START);
    vm.warp(2000);
    assertEq(_swap(true), 990000);
    assertEq(plugin.lastTimepointTimestamp(), 2000, 'oracle must still update');
  }
}
