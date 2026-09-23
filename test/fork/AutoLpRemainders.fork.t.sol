// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/console2.sol";
import {ForkFixture} from "./helpers/ForkFixture.sol";
import {FeeUses} from "../../contracts/libraries/FeeUses.sol";
import {IAlgebraPool} from "../../contracts/interfaces/IAlgebraPool.sol";

contract AutoLpRemaindersForkTest is ForkFixture {
    function _wantToken0() internal pure virtual returns (bool) {
        return true;
    }

    function _quoteOnlyLaunch() internal returns (address token, address pool, uint256 acquired) {
        (token, pool,,) = _launchOnSide(WETH, _wantToken0(), FeeUses.AUTO_LP);
        acquired = _swapIn(alice, WETH, token, 1 ether);
        locker.splitRewards(token);
        assertEq(locker.creatorOwed(token, token), 0, "buy volume only: fees are quote");
        assertGt(locker.creatorOwed(token, WETH), 0);
    }

    function test_QuoteRemainderAddsSamePoolDepthWithoutMovingOriginalBands() public onlyForked {
        (address token, address pool,) = _quoteOnlyLaunch();
        uint256[] memory originals = locker.getPositions(token);
        bytes32[] memory beforePositions = new bytes32[](originals.length);
        for (uint256 i; i < originals.length; i++) {
            beforePositions[i] = _positionHash(originals[i]);
        }
        uint256 quoteBefore = locker.creatorOwed(token, WETH);
        uint256 poolQuoteBefore = IERC20(WETH).balanceOf(pool);
        vm.prank(bob);
        locker.spendCreatorShare(token);
        assertTrue(autoLp.hasQuotePosition(token));
        uint256 id = autoLp.quotePosition(token);
        assertEq(NPM.ownerOf(id), address(autoLp));
        (,, address token0, address token1,, int24 lower, int24 upper, uint128 liquidity,,,,) = NPM.positions(id);
        assertEq(token0, _wantToken0() ? token : WETH);
        assertEq(token1, _wantToken0() ? WETH : token);
        assertEq(upper - lower, IAlgebraPool(pool).tickSpacing());
        if (_wantToken0()) assertLe(upper, _currentTick(pool));
        else assertGt(lower, _currentTick(pool));
        assertGt(liquidity, 0);
        assertEq(IERC20(WETH).balanceOf(pool) - poolQuoteBefore + autoLp.quoteCarry(token), quoteBefore);
        for (uint256 i; i < originals.length; i++) {
            assertEq(_positionHash(originals[i]), beforePositions[i]);
            assertEq(NPM.ownerOf(originals[i]), address(locker));
        }
        assertEq(IERC20(WETH).balanceOf(bob), 0);
        assertEq(IERC20(token).balanceOf(bob), 0);
        assertEq(IERC20(WETH).allowance(address(autoLp), address(NPM)), 0);
    }

    function test_SellersConsumeQuoteAndRefreshBurnsAcquiredTokens() public onlyForked {
        (address token,, uint256 acquired) = _quoteOnlyLaunch();
        locker.spendCreatorShare(token);
        uint256 oldId = autoLp.quotePosition(token);
        uint256 supplyBefore = IERC20(token).totalSupply();
        // These tokens came from a real buy, not a synthetic balance. Selling traverses the new range.
        uint256 output = _sell(alice, token, WETH, acquired);
        assertGt(output, 0);
        vm.prank(bob);
        autoLp.refreshQuotePosition(token); // no new locked-position fee collection required
        uint256 burned = autoLp.lifetimeBurned(token);
        assertGt(burned, 0, "the supplemental position acquired launch tokens from sellers");
        assertEq(IERC20(token).totalSupply(), supplyBefore - burned);
        assertEq(IERC20(token).balanceOf(address(autoLp)), 0);
        assertEq(IERC20(WETH).balanceOf(address(autoLp)), autoLp.quoteCarry(token));
        vm.expectRevert();
        NPM.ownerOf(oldId);
        assertEq(IERC20(WETH).balanceOf(bob), 0);
        assertEq(IERC20(token).balanceOf(bob), 0);
    }

    function test_RefreshRepeatedlyPreservesQuoteAccounting() public onlyForked {
        (address token, address pool,) = _quoteOnlyLaunch();
        uint256 quoteBefore = locker.creatorOwed(token, WETH);
        uint256 poolBefore = IERC20(WETH).balanceOf(pool);
        locker.spendCreatorShare(token);
        for (uint256 i; i < 5; i++) {
            vm.prank(bob);
            autoLp.refreshQuotePosition(token);
            assertEq(IERC20(WETH).balanceOf(pool) - poolBefore + autoLp.quoteCarry(token), quoteBefore);
            assertEq(IERC20(WETH).balanceOf(address(autoLp)), autoLp.quoteCarry(token));
        }
    }

    function test_RealCompoundingAccountsForBothFeeTokens() public onlyForked {
        (address token, address pool, uint256 acquired) = _quoteOnlyLaunch();
        _sell(alice, token, WETH, acquired / 2);
        locker.splitRewards(token);
        uint256 tokenFees = locker.creatorOwed(token, token);
        uint256 quoteFees = locker.creatorOwed(token, WETH);
        assertGt(tokenFees, 0);
        assertGt(quoteFees, 0);
        uint256 poolTokenBefore = IERC20(token).balanceOf(pool);
        uint256 poolQuoteBefore = IERC20(WETH).balanceOf(pool);
        uint256 supplyBefore = IERC20(token).totalSupply();
        (uint256 originalId,) = autoLp.targetBand(token);
        (,,,,, int24 lowerBefore, int24 upperBefore, uint128 liquidityBefore,,,,) = NPM.positions(originalId);
        vm.prank(bob);
        locker.spendCreatorShare(token);
        (,,,,, int24 lowerAfter, int24 upperAfter, uint128 liquidityAfter,,,,) = NPM.positions(originalId);
        assertGt(liquidityAfter, liquidityBefore, "the original band is compounded first");
        assertEq(lowerBefore, lowerAfter);
        assertEq(upperBefore, upperAfter);
        assertEq(IERC20(token).balanceOf(pool) - poolTokenBefore + autoLp.lifetimeBurned(token), tokenFees);
        assertEq(IERC20(WETH).balanceOf(pool) - poolQuoteBefore + autoLp.quoteCarry(token), quoteFees);
        assertEq(IERC20(token).totalSupply(), supplyBefore - autoLp.lifetimeBurned(token));
        assertEq(IERC20(token).balanceOf(address(autoLp)), 0);
        assertEq(IERC20(WETH).balanceOf(address(autoLp)), autoLp.quoteCarry(token));
        assertEq(locker.creatorOwed(token, token), 0);
        assertEq(locker.creatorOwed(token, WETH), 0);
    }

    /// @dev A characterization test, NOT an MEV-protection assertion. Permissionless spot execution
    ///      intentionally remains sandwichable; a correct implementation must not be advertised otherwise.
    function test_PermissionlessSpotExecutionStillHasSandwichRisk() public onlyForked {
        (address token,,,) = _launchOnSide(WETH, _wantToken0(), FeeUses.AUTO_LP);
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

    function _positionHash(uint256 id) internal view returns (bytes32) {
        (,, address token0, address token1,, int24 lower, int24 upper, uint128 liquidity,,,,) = NPM.positions(id);
        return keccak256(abi.encode(token0, token1, lower, upper, liquidity));
    }
}

contract AutoLpRemaindersMirroredForkTest is AutoLpRemaindersForkTest {
    function _wantToken0() internal pure override returns (bool) {
        return false;
    }
}
