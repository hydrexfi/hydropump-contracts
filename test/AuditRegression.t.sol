// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HydropumpFixture} from "./helpers/HydropumpFixture.sol";
import {FeeUses} from "../contracts/libraries/FeeUses.sol";
import {TickMath} from "../contracts/libraries/TickMath.sol";
import {MockAlgebraPool} from "./mocks/MockAlgebra.sol";
import {HydropumpLauncher} from "../contracts/core/HydropumpLauncher.sol";
import {PairDirectory} from "../contracts/helpers/PairDirectory.sol";

contract AuditRegressionTest is HydropumpFixture {
    function test_ExpiredQuoteCannotLaunch() public {
        vm.warp(block.timestamp + 1 days + 1);
        assertFalse(directory.isEnabled(HIGH_QUOTE), "stale quote must not be offered");
        vm.expectRevert();
        this.launchForTest(HIGH_QUOTE);
    }

    function test_RefreshingExpiredQuoteRestoresLaunch() public {
        vm.warp(block.timestamp + 2 days);
        _registerQuote(HIGH_QUOTE, WETH_START_TICK);
        (address token,,) = _launch(HIGH_QUOTE);
        assertTrue(locker.poolOf(token) != address(0));
    }

    function launchForTest(address quote) external {
        _launch(quote);
    }

    function test_PoisonedPoolDoesNotBlockLaunch() public {
        address predicted = vm.computeCreateAddress(address(launcher), vm.getNonce(address(launcher)));
        npm.createAndInitializePoolIfNecessary(
            predicted, HIGH_QUOTE, address(0), TickMath.getSqrtRatioAtTick(WETH_START_TICK + 7000), ""
        );
        (address token, address pool,) = _launch(HIGH_QUOTE);
        assertTrue(token != predicted, "must skip the poisoned address");
        assertEq(_currentTick(pool), WETH_START_TICK);
        assertEq(IERC20(predicted).totalSupply(), 0, "discarded supply is burned");
    }

    function test_PoisonedMirroredPoolDoesNotBlockLaunch() public {
        address predicted = vm.computeCreateAddress(address(launcher), vm.getNonce(address(launcher)));
        npm.createAndInitializePoolIfNecessary(
            LOW_QUOTE, predicted, address(0), TickMath.getSqrtRatioAtTick(-WETH_START_TICK - 7000), ""
        );
        (address token, address pool,) = _launch(LOW_QUOTE);
        assertTrue(token != predicted);
        assertEq(_currentTick(pool), -WETH_START_TICK);
    }

    function test_ManipulatedBuybackRevertsAndPreservesCredit() public {
        (address token, address pool,) = _launch(HIGH_QUOTE, FeeUses.BUYBACK_BURN, 0);
        _accrueFees(token, 0, 1 ether);
        locker.splitRewards(token);
        _oracle(pool, WETH_START_TICK);
        _setSpot(pool, WETH_START_TICK + 40000);
        uint256 credit = locker.creatorOwed(token, HIGH_QUOTE);
        vm.expectRevert();
        locker.spendCreatorShare(token);
        assertEq(locker.creatorOwed(token, HIGH_QUOTE), credit);
    }

    function test_ManipulatedProtocolSellRevertsAndPreservesCredit() public {
        (address token, address pool,) = _launch(HIGH_QUOTE);
        _accrueFees(token, 40_000e18, 0);
        _seedPoolQuote(token, 10 ether);
        locker.splitRewards(token);
        _oracle(pool, WETH_START_TICK);
        _setSpot(pool, WETH_START_TICK - 40000);
        uint256 credit = locker.protocolOwed(token);
        vm.expectRevert();
        locker.convertProtocolShare(token);
        assertEq(locker.protocolOwed(token), credit);
    }

    function _oracle(address pool, int24 tick) internal {
        address oracle = makeAddr("oracle");
        vm.mockCall(pool, abi.encodeWithSignature("plugin()"), abi.encode(oracle));
        int56[] memory cumulatives = new int56[](2);
        cumulatives[1] = int56(tick) * 1800;
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("getTimepoints(uint32[])", _seconds()),
            abi.encode(cumulatives, new uint88[](2))
        );
    }

    function _seconds() internal pure returns (uint32[] memory secondsAgos) {
        secondsAgos = new uint32[](2);
        secondsAgos[0] = 1800;
    }
}
