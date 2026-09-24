// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/console2.sol";
import {ForkFixture} from "./helpers/ForkFixture.sol";
import {FeeUses} from "../../contracts/libraries/FeeUses.sol";

contract AutoLpRemaindersForkTest is ForkFixture {
    struct BeforeDeposit {
        uint256 tokenFees;
        uint256 quoteFees;
        uint256 poolToken;
        uint256 poolQuote;
        uint256 id;
        int24 lower;
        int24 upper;
        uint128 liquidity;
    }

    function _wantToken0() internal pure virtual returns (bool) {
        return true;
    }

    function test_QuoteFeesWaitThenCompoundWithLaterSellFees() public onlyForked {
        (address token, address pool, uint256[] memory ids,) = _launchOnSide(WETH, _wantToken0(), FeeUses.AUTO_LP);
        _passLaunchWindow();
        uint256 acquired = _swapIn(alice, WETH, token, 1 ether);
        locker.splitRewards(token);
        uint256 retained = locker.creatorOwed(token, WETH);
        uint256 supplyBefore = IERC20(token).totalSupply();
        assertGt(retained, 0);
        assertEq(locker.creatorOwed(token, token), 0);
        vm.prank(bob);
        locker.spendCreatorShare(token);
        assertEq(locker.creatorOwed(token, WETH), retained, "unpairable quote remains credited");
        assertEq(autoLp.lifetimeLiquidityAdded(token), 0);
        // Real sell fees provide the other asset, while the previous quote credit remains available.
        _sell(alice, token, WETH, acquired / 2);
        locker.splitRewards(token);
        _compoundAndCheckAccounting(token, pool);
        assertEq(IERC20(token).totalSupply(), supplyBefore, "no burn");
        assertEq(locker.positionCount(token), ids.length);
        for (uint256 i; i < ids.length; i++) {
            assertEq(NPM.ownerOf(ids[i]), address(locker));
        }
        assertEq(IERC20(token).balanceOf(address(autoLp)), 0);
        assertEq(IERC20(WETH).balanceOf(address(autoLp)), 0);
        assertEq(IERC20(token).balanceOf(bob), 0);
        assertEq(IERC20(WETH).balanceOf(bob), 0);
    }

    function _compoundAndCheckAccounting(address token, address pool) internal {
        BeforeDeposit memory before;
        before.tokenFees = locker.creatorOwed(token, token);
        before.quoteFees = locker.creatorOwed(token, WETH);
        before.poolToken = IERC20(token).balanceOf(pool);
        before.poolQuote = IERC20(WETH).balanceOf(pool);
        (before.id,) = autoLp.targetBand(token);
        (,,,,, before.lower, before.upper, before.liquidity,,,,) = NPM.positions(before.id);
        vm.prank(bob);
        locker.spendCreatorShare(token);
        (,,,,, int24 lower, int24 upper, uint128 liquidity,,,,) = NPM.positions(before.id);
        assertGt(liquidity, before.liquidity);
        assertEq(lower, before.lower);
        assertEq(upper, before.upper);
        assertEq(IERC20(token).balanceOf(pool) - before.poolToken + locker.creatorOwed(token, token), before.tokenFees);
        assertEq(IERC20(WETH).balanceOf(pool) - before.poolQuote + locker.creatorOwed(token, WETH), before.quoteFees);
    }

    function test_RepeatedUnpairableRetriesPreserveRealFees() public onlyForked {
        (address token,,,) = _launchOnSide(WETH, _wantToken0(), FeeUses.AUTO_LP);
        _swapIn(alice, WETH, token, 1 ether);
        locker.splitRewards(token);
        uint256 retained = locker.creatorOwed(token, WETH);
        uint256 lockerBalance = IERC20(WETH).balanceOf(address(locker));
        for (uint256 i; i < 5; i++) {
            vm.prank(bob);
            locker.spendCreatorShare(token);
            assertEq(locker.creatorOwed(token, WETH), retained);
            assertEq(IERC20(WETH).balanceOf(address(locker)), lockerBalance);
            assertEq(IERC20(WETH).balanceOf(address(autoLp)), 0);
        }
    }

    /// @dev A characterization test, not an MEV-protection assertion: spot execution remains permissionless.
    function test_PermissionlessSpotExecutionStillHasSandwichRisk() public onlyForked {
        (address token,,,) = _launchOnSide(WETH, _wantToken0(), FeeUses.AUTO_LP);
        _passLaunchWindow();
        for (uint256 i; i < 30; i++) {
            uint256 volumeBought = _swapIn(alice, WETH, token, 5 ether);
            _sell(alice, token, WETH, volumeBought);
        }
        locker.splitRewards(token);
        uint256 snapshot = vm.snapshotState();
        uint256 controlBought = _swapIn(bob, WETH, token, 5 ether);
        uint256 controlOut = _sell(bob, token, WETH, controlBought);
        assertLt(controlOut, 5 ether);
        vm.revertToState(snapshot);
        uint256 bought = _swapIn(bob, WETH, token, 5 ether);
        vm.prank(bob);
        locker.spendCreatorShare(token);
        uint256 output = _sell(bob, token, WETH, bought);
        console2.log("control WETH returned", controlOut);
        console2.log("sandwich WETH returned", output);
        assertGt(output, 5 ether, "known residual risk: attacker profit before gas");
    }
}

contract AutoLpRemaindersMirroredForkTest is AutoLpRemaindersForkTest {
    function _wantToken0() internal pure override returns (bool) {
        return false;
    }
}
