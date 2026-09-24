// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeeUses} from "../../contracts/libraries/FeeUses.sol";
import {ForkFixture} from "./helpers/ForkFixture.sol";

/// @notice The launch tax against live Hydrex pools: 99% on buys in the launch block, falling linearly to
///         zero over ten blocks, burnt. The creator's buy, sells and fee collection are never taxed.
contract LaunchTaxForkTest is ForkFixture {
    uint256 internal constant WINDOW = 10;

    function _expectedTaxBps(uint256 blocksIn) internal pure returns (uint256) {
        return blocksIn < WINDOW ? 9_900 * (WINDOW - blocksIn) / WINDOW : 0;
    }

    function _launchWithBuy(bool wantToken0, uint256 buyAmount)
        internal
        returns (address token, address pool, uint256 creatorFill)
    {
        _arrangeSide(WETH, wantToken0);
        vm.recordLogs();
        (token, pool,) = _launchFrom(creator, WETH, bytes32(0), buyAmount);
        require((token < WETH) == wantToken0, "wrong side");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("LaunchBought(address,address,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) (, creatorFill) = abi.decode(logs[i].data, (uint256, uint256));
        }
    }

    function test_TheCreatorsBuyIsUntaxedOnBothSides() public onlyForked {
        for (uint256 side = 0; side < 2; side++) {
            (address token,, uint256 fill) = _launchWithBuy(side == 0, 0.05 ether);
            assertGt(fill, 0);
            assertEq(IERC20(token).balanceOf(creator), fill, "creator keeps the whole fill");
            deal(token, creator, 0);
        }
    }

    function test_ASameBlockSnipeKeepsOnePercentOnBothSides() public onlyForked {
        for (uint256 side = 0; side < 2; side++) {
            (address token,,) = _launchWithBuy(side == 0, 0.05 ether);
            uint256 supplyBefore = IERC20(token).totalSupply();

            uint256 poolOut = _swapIn(alice, WETH, token, 1 ether);
            uint256 received = IERC20(token).balanceOf(alice);

            assertEq(received, poolOut - poolOut * 9_900 / 10_000, "sniper keeps 1%");
            assertEq(supplyBefore - IERC20(token).totalSupply(), poolOut - received, "the rest is burnt");
            deal(token, alice, 0);
        }
    }

    function test_TheTaxFallsLinearlyToZeroOverTenBlocks() public onlyForked {
        (address token,,) = _launchWithBuy(true, 0);
        uint256 launchBlock = vm.getBlockNumber();

        for (uint256 k = 0; k <= WINDOW; k++) {
            uint256 snap = vm.snapshotState();
            vm.roll(launchBlock + k);

            uint256 poolOut = _swapIn(alice, WETH, token, 0.1 ether);
            uint256 received = IERC20(token).balanceOf(alice);
            uint256 bps = _expectedTaxBps(k);
            assertEq(received, poolOut - poolOut * bps / 10_000);
            console2.log("block +%s  tax bps %s  kept %s bps", k, bps, received * 10_000 / poolOut);

            vm.revertToState(snap);
        }
    }

    /// Algebra reverts a swap whose input arrives short, so sells must reach the pool whole.
    function test_SellsInTheWindowGoThroughUntaxed() public onlyForked {
        for (uint256 side = 0; side < 2; side++) {
            (address token, address pool, uint256 fill) = _launchWithBuy(side == 0, 0.05 ether);
            vm.roll(vm.getBlockNumber() + 1);

            uint256 poolBefore = IERC20(token).balanceOf(pool);
            uint256 supplyBefore = IERC20(token).totalSupply();
            uint256 wethOut = _sell(creator, token, WETH, fill / 2);

            assertGt(wethOut, 0);
            assertEq(IERC20(token).balanceOf(pool) - poolBefore, fill / 2, "the pool receives the whole sell");
            assertEq(IERC20(token).totalSupply(), supplyBefore, "nothing burnt");
        }
    }

    /// `splitRewards` is permissionless, so a collect inside the window must not burn the locker's fees.
    function test_CollectingFeesInTheWindowBurnsNothing() public onlyForked {
        (address token,, uint256 fill) = _launchWithBuy(true, 0.05 ether);
        _sell(creator, token, WETH, fill); // pays its fee in the launch token

        uint256 supplyBefore = IERC20(token).totalSupply();
        uint256 lockerBefore = IERC20(token).balanceOf(address(locker));
        locker.splitRewards(token);

        assertEq(IERC20(token).totalSupply(), supplyBefore, "collect burnt fees");
        assertGt(IERC20(token).balanceOf(address(locker)), lockerBefore, "and the fees arrived");
    }

    /// Buyback-and-burn buys from the pool, so inside the window its fill arrives taxed. It must still go
    /// through, burning what arrived.
    function test_ABuybackInTheWindowBurnsWhatArrived() public onlyForked {
        _arrangeSide(WETH, true);
        (address token,,) = _launchFrom(creator, WETH, FeeUses.BUYBACK_BURN, 0);
        _swapIn(alice, WETH, token, 1 ether); // pays its fee in WETH
        // A new block opens at the pushed price, so the buyback's price limit leaves it room.
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 2);

        uint256 supplyBefore = IERC20(token).totalSupply();
        locker.handleAllRewards(token);

        uint256 burned = buybackBurn.lifetimeBurned(token);
        assertGt(burned, 0);
        assertGt(supplyBefore - IERC20(token).totalSupply(), burned, "the tax is burnt on top");
        assertEq(IERC20(token).balanceOf(address(buybackBurn)), 0, "nothing stranded");
    }

    /// A bot that buys and dumps at once. The tax is taken in tokens, which the bot then sells at the
    /// post-buy price, so a larger buy loses less than the tax; in the launch block it still loses ~all.
    function test_ALaunchBlockSnipeLosesNearlyEverything() public onlyForked {
        (address token,,) = _launchWithBuy(true, 0);
        uint256 launchBlock = vm.getBlockNumber();
        uint256[3] memory spends = [uint256(0.01 ether), 0.1 ether, 1 ether];

        for (uint256 j = 0; j < spends.length; j++) {
            for (uint256 k = 0; k <= WINDOW; k++) {
                uint256 snap = vm.snapshotState();
                vm.roll(launchBlock + k);

                _swapIn(alice, WETH, token, spends[j]);
                uint256 back = _sell(alice, token, WETH, IERC20(token).balanceOf(alice));
                uint256 lossBps = (spends[j] - back) * 10_000 / spends[j];
                console2.log("spend %e  block +%s  round-trip loss bps %s", spends[j], k, lossBps);

                if (k == 0) assertGe(lossBps, 9_700, "a launch-block snipe must lose at least 97%");
                vm.revertToState(snap);
            }
        }
    }

    function test_AfterTheWindowABuyIsPlain() public onlyForked {
        (address token,,) = _launchWithBuy(true, 0);
        vm.roll(vm.getBlockNumber() + WINDOW);

        uint256 poolOut = _swapIn(alice, WETH, token, 0.1 ether);
        assertEq(IERC20(token).balanceOf(alice), poolOut);

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        IERC20(token).transfer(bob, 1e18);
        console2.log("transfer gas after the window", gasBefore - gasleft());
    }
}
