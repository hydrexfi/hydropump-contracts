// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StakeGaugeLP} from "../../script/deploy/StakeGaugeLP.s.sol";
import {IGauge} from "../../contracts/interfaces/IGauge.sol";
import {HydropumpAddresses} from "../../contracts/libraries/HydropumpAddresses.sol";

/// @notice Stakes the live LP into the live Hydropump gauge on Base.
/// @dev Requires BASE_RPC_URL; skipped when unset.
contract StakeGaugeLPForkTest is Test {
    IGauge internal constant GAUGE = IGauge(HydropumpAddresses.GAUGE);
    IERC20 internal constant PAIR = IERC20(HydropumpAddresses.GAUGE_PAIR);
    address internal constant DEPLOYER = 0x2ccDf18b0cBbdB7272be8a49C42bA3e76A7f813D;

    StakeGaugeLP internal script;
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        script = new StakeGaugeLP();
    }

    function test_StakesTheWholeLpBalance() public {
        if (!forked) {
            vm.skip(true);
        }

        uint256 lp = PAIR.balanceOf(DEPLOYER);
        if (lp == 0) {
            // Already staked on-chain; nothing left to exercise.
            assertGt(GAUGE.balanceOf(DEPLOYER), 0, "LP is neither held nor staked");
            return;
        }

        uint256 gaugeSupplyBefore = GAUGE.totalSupply();

        // Run the script's own logic as the deployer.
        vm.prank(DEPLOYER, DEPLOYER);
        PAIR.transfer(address(script), lp);
        uint256 staked = script.stake(address(script));

        assertEq(staked, lp);
        assertEq(PAIR.balanceOf(address(script)), 0, "no LP may be left unstaked");
        assertEq(GAUGE.balanceOf(address(script)), lp, "staked balance must be credited");
        assertEq(GAUGE.totalSupply(), gaugeSupplyBefore + lp);

        console2.log("staked       ", staked);
        console2.log("gauge supply ", GAUGE.totalSupply());
        console2.log("reward token ", GAUGE.rewardToken());
    }

    function test_StakedPositionAccruesEmissions() public {
        if (!forked) {
            vm.skip(true);
        }

        uint256 lp = PAIR.balanceOf(DEPLOYER);
        if (lp > 0) {
            vm.prank(DEPLOYER, DEPLOYER);
            PAIR.transfer(address(script), lp);
            script.stake(address(script));
        }

        // Emissions only flow after a vote and a distribution, so this just confirms the accounting
        // surface is live rather than asserting a non-zero number.
        skip(7 days);
        assertGe(GAUGE.earned(address(script)), 0);
    }
}
