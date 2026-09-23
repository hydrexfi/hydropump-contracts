// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HydropumpFixture} from "./helpers/HydropumpFixture.sol";
import {FeeUses} from "../contracts/libraries/FeeUses.sol";
import {TickMath} from "../contracts/libraries/TickMath.sol";
import {INonfungiblePositionManager} from "../contracts/interfaces/INonfungiblePositionManager.sol";
import {AutoLpFeeUse} from "../contracts/feeuses/AutoLpFeeUse.sol";

contract AutoLpRemaindersTest is HydropumpFixture {
    function _quote() internal pure virtual returns (address) {
        return HIGH_QUOTE;
    }

    function _launchInsideBand() internal returns (address token, address pool, uint256 id) {
        uint256[] memory ids;
        (token, pool, ids) = _launch(_quote(), FeeUses.AUTO_LP, 0);
        _setSpot(pool, _currentTick(pool) + (token < _quote() ? int24(100) : int24(-100)));
        id = ids[0];
    }

    function test_TokenLeftoversWaitForNewQuoteFees() public {
        (address token,, uint256 id) = _launchInsideBand();
        _accrueFees(token, 40_000e18, 0);
        uint256 supplyBefore = IERC20(token).totalSupply();
        uint128 before = npm.liquidityOf(id);
        uint256 nextId = npm.nextId();
        vm.prank(stranger);
        locker.handleCreatorRewards(token);
        assertEq(locker.creatorOwed(token, token), 30_000e18);
        assertEq(npm.liquidityOf(id), before);
        _accrueFees(token, 0, 1 ether);
        vm.prank(stranger);
        locker.handleCreatorRewards(token);
        assertGt(npm.liquidityOf(id), before);
        assertEq(locker.creatorOwed(token, token), 0);
        assertEq(locker.creatorOwed(token, _quote()), 0);
        assertEq(IERC20(token).totalSupply(), supplyBefore);
        assertEq(npm.nextId(), nextId, "no supplemental position");
        _assertEmptyAndNoPayout(token);
    }

    function test_QuoteLeftoversWaitForNewTokenFees() public {
        (address token,, uint256 id) = _launchInsideBand();
        _accrueFees(token, 0, 1 ether);
        uint128 before = npm.liquidityOf(id);
        locker.handleCreatorRewards(token);
        assertEq(locker.creatorOwed(token, _quote()), 0.75 ether);
        assertEq(npm.liquidityOf(id), before);
        _accrueFees(token, 40_000e18, 0);
        locker.handleCreatorRewards(token);
        assertGt(npm.liquidityOf(id), before);
        assertEq(locker.creatorOwed(token, _quote()), 0);
        _assertEmptyAndNoPayout(token);
    }

    function test_PriceChangeAllowsRetryWithoutNewFees() public {
        (address token, address pool, uint256 id) = _launchInsideBand();
        (int24 lower, int24 upper) = npm.range(id);
        _accrueFees(token, 40_000e18, 0);
        locker.handleCreatorRewards(token);
        assertEq(locker.creatorOwed(token, token), 30_000e18);
        uint128 before = npm.liquidityOf(id);
        // At the opening edge this existing position takes only launch tokens.
        _setSpot(pool, token < _quote() ? lower : upper);
        vm.prank(stranger);
        locker.spendCreatorShare(token);
        assertGt(npm.liquidityOf(id), before);
        assertEq(locker.creatorOwed(token, token), 0);
        assertEq(npm.ownerOf(id), address(locker));
        (int24 lowerAfter, int24 upperAfter) = npm.range(id);
        assertEq(lowerAfter, lower);
        assertEq(upperAfter, upper);
    }

    function test_PartialFillRetainsBothRemaindersAndRetries() public {
        (address token,, uint256 id) = _launchInsideBand();
        _accrueFees(token, 40_000e18, 1 ether);
        npm.setUsageCaps(token < _quote() ? 20_000e18 : 0.5 ether, token < _quote() ? 0.5 ether : 20_000e18);
        uint256 supplyBefore = IERC20(token).totalSupply();
        locker.handleCreatorRewards(token);
        assertEq(locker.creatorOwed(token, token), 10_000e18);
        assertEq(locker.creatorOwed(token, _quote()), 0.25 ether);
        uint128 beforeRetry = npm.liquidityOf(id);
        npm.setUsageCaps(0, 0);
        locker.spendCreatorShare(token);
        assertGt(npm.liquidityOf(id), beforeRetry);
        assertEq(locker.creatorOwed(token, token), 0);
        assertEq(locker.creatorOwed(token, _quote()), 0);
        assertEq(locker.protocolOwed(token), 10_000e18);
        assertEq(locker.protocolOwed(_quote()), 0.25 ether);
        assertEq(IERC20(token).totalSupply(), supplyBefore);
        _assertEmptyAndNoPayout(token);
    }

    function test_ZeroLiquidityDustIsRetainedWithoutCallingNpm() public {
        (address token, address pool,) = _launchInsideBand();
        _setSpot(pool, token < _quote() ? TickMath.MAX_TICK - 1 : TickMath.MIN_TICK + 1);
        _accrueFees(token, 0, 4);
        // At this price three wei cannot buy one liquidity unit. A real NPM rejects that deposit.
        vm.mockCallRevert(
            NPM, abi.encodeWithSelector(INonfungiblePositionManager.increaseLiquidity.selector), bytes("zero liquidity")
        );
        locker.handleCreatorRewards(token);
        assertEq(locker.creatorOwed(token, _quote()), 3);
        assertEq(locker.protocolOwed(_quote()), 1);
        _assertEmptyAndNoPayout(token);
    }

    function test_SharedQuoteRemaindersStayWithTheirLaunch() public {
        (address a,,) = _launchInsideBand();
        (address b,,) = _launchInsideBand();
        _accrueFees(a, 0, 1 ether);
        _accrueFees(b, 0, 2 ether);
        locker.handleCreatorRewards(a);
        locker.handleCreatorRewards(b);
        _accrueFees(a, 40_000e18, 0);
        locker.handleCreatorRewards(a);
        assertEq(locker.creatorOwed(a, _quote()), 0);
        assertEq(locker.creatorOwed(b, _quote()), 1.5 ether);
        assertEq(IERC20(_quote()).balanceOf(address(locker)), 1.5 ether + locker.protocolOwed(_quote()));
    }

    function test_FailedDepositRestoresCreditsAndApprovals() public {
        (address token,,) = _launchInsideBand();
        _accrueFees(token, 40_000e18, 1 ether);
        locker.splitRewards(token);
        vm.mockCallRevert(
            NPM, abi.encodeWithSelector(INonfungiblePositionManager.increaseLiquidity.selector), bytes("deposit failed")
        );
        vm.expectRevert(bytes("deposit failed"));
        locker.spendCreatorShare(token);
        assertEq(locker.creatorOwed(token, token), 30_000e18);
        assertEq(locker.creatorOwed(token, _quote()), 0.75 ether);
        _assertEmptyAndNoPayout(token);
    }

    function test_InvalidAssetsAreRejectedEvenFromLocker() public {
        (address token,,) = _launchInsideBand();
        address[] memory assets = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        (assets[0], assets[1]) = (_quote(), token);
        vm.prank(address(locker));
        vm.expectRevert(AutoLpFeeUse.InvalidAssets.selector);
        autoLp.onFees(token, assets, amounts);
    }

    function testFuzz_RepeatedUnpairableRetriesDoNotLoseOrDuplicateCredit(uint128 fees, bool quoteOnly) public {
        fees = uint128(bound(fees, 1, 1e24));
        (address token,, uint256 id) = _launchInsideBand();
        _accrueFees(token, quoteOnly ? 0 : fees, quoteOnly ? fees : 0);
        uint128 before = npm.liquidityOf(id);
        uint256 supplyBefore = IERC20(token).totalSupply();
        locker.handleCreatorRewards(token);
        for (uint256 i; i < 3; i++) {
            vm.prank(stranger);
            locker.spendCreatorShare(token);
            assertEq(locker.creatorOwed(token, quoteOnly ? _quote() : token), uint256(fees) - fees / 4);
        }
        assertEq(npm.liquidityOf(id), before);
        assertEq(IERC20(token).totalSupply(), supplyBefore);
        _assertEmptyAndNoPayout(token);
    }

    function _assertEmptyAndNoPayout(address token) internal view {
        assertEq(IERC20(token).balanceOf(address(autoLp)), 0);
        assertEq(IERC20(_quote()).balanceOf(address(autoLp)), 0);
        assertEq(IERC20(token).balanceOf(stranger), 0);
        assertEq(IERC20(_quote()).balanceOf(stranger), 0);
        assertEq(IERC20(token).allowance(address(autoLp), NPM), 0);
        assertEq(IERC20(_quote()).allowance(address(autoLp), NPM), 0);
    }
}

contract AutoLpRemaindersMirroredTest is AutoLpRemaindersTest {
    function _quote() internal pure override returns (address) {
        return LOW_QUOTE;
    }
}
