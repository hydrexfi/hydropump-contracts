// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForkFixture} from "./helpers/ForkFixture.sol";
import {FeeUses} from "../../contracts/libraries/FeeUses.sol";
import {TickMath} from "../../contracts/libraries/TickMath.sol";

/// @notice Audit reproductions against real Base dependencies. No broadcasts.
contract AuditFindingsForkTest is ForkFixture {
    function test_Audit_PreinitializedPoolIsSkipped() public onlyForked {
        address predicted = vm.computeCreateAddress(address(launcher), vm.getNonce(address(launcher)));
        bool isToken0 = predicted < WETH;
        int24 tick = isToken0 ? WETH_START_TICK + int24(7000) : -WETH_START_TICK - int24(7000);
        vm.prank(bob);
        NPM.createAndInitializePoolIfNecessary(
            isToken0 ? predicted : WETH, isToken0 ? WETH : predicted, address(0), TickMath.getSqrtRatioAtTick(tick), ""
        );
        (address token, address pool,) = _launchFrom(creator, WETH, FeeUses.CREATOR_BALANCE, 0);
        assertTrue(token != predicted);
        assertEq(_currentTick(pool), token < WETH ? WETH_START_TICK : -WETH_START_TICK);
        assertEq(IERC20(predicted).totalSupply(), 0);
    }

    function attemptLaunch() external {
        _launchFrom(creator, WETH, FeeUses.CREATOR_BALANCE, 0);
    }

    function test_Audit_BuybackSandwichIsRejected() public onlyForked {
        (address token,,,) = _launchOnSide(WETH, true, FeeUses.BUYBACK_BURN);
        // Accumulate the creator's quote fees through ordinary swaps, not storage edits.
        for (uint256 i; i < 30; i++) {
            uint256 roundTripTokens = _swapIn(alice, WETH, token, 5 ether);
            _sell(alice, token, WETH, roundTripTokens);
        }
        _swapIn(alice, WETH, token, 2 ether);
        _ageTwapWindow(token, WETH);
        locker.splitRewards(token);
        uint256 snapshot = vm.snapshotState();
        locker.spendCreatorShare(token);
        uint256 baselineBurn = buybackBurn.lifetimeBurned(token);
        vm.revertToState(snapshot);

        uint256 capital = 10 ether;
        uint256 acquired = _swapIn(bob, WETH, token, capital);
        uint256 credit = locker.creatorOwed(token, WETH);
        vm.prank(bob);
        vm.expectRevert();
        locker.spendCreatorShare(token);
        uint256 recovered = _sell(bob, token, WETH, acquired);
        console2.log("attacker capital", capital);
        console2.log("attacker recovered", recovered);
        console2.log("baseline burn", baselineBurn);
        console2.log("attacked burn", buybackBurn.lifetimeBurned(token));
        assertLt(recovered, capital, "no profitable sandwich");
        assertEq(locker.creatorOwed(token, WETH), credit, "failed swap preserves funds");
        assertEq(buybackBurn.lifetimeBurned(token), 0);
        assertGt(baselineBurn, 0, "unmanipulated fee execution is available");
    }
}
