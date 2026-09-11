// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HydropumpBuyback} from "../../contracts/HydropumpBuyback.sol";
import {HydropumpAddresses} from "../../contracts/libraries/HydropumpAddresses.sol";

interface IBribeView {
    function TYPE() external view returns (string memory);
    function isRewardToken(address token) external view returns (bool);
    function rewardData(address token, uint256 epoch)
        external
        view
        returns (uint256 periodFinish, uint256 rewardsPerEpoch, uint256 lastUpdateTime);
    function getEpochStart() external view returns (uint256);
}

/// @notice Drives the buyback against the live Hydropump gauge on Base.
/// @dev Requires BASE_RPC_URL; skipped when unset.
contract BuybackForkTest is Test {
    IERC20 internal constant HYDX = IERC20(HydropumpAddresses.HYDX);
    address internal constant GAUGE_BRIBE = HydropumpAddresses.GAUGE_BRIBE;

    HydropumpBuyback internal buyback;

    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal stranger = makeAddr("stranger");

    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        buyback = new HydropumpBuyback(admin, operator, address(HYDX), GAUGE_BRIBE);
    }

    function test_GaugeBribeAcceptsHydx() public view {
        if (!forked) return;

        assertEq(IBribeView(GAUGE_BRIBE).TYPE(), "Hydrex Bribes: vAMM-HPONE/HPTWO");
        assertTrue(IBribeView(GAUGE_BRIBE).isRewardToken(address(HYDX)), "HYDX must be a reward token");
    }

    function test_BribeDepositsHydxIntoTheLiveGauge() public {
        if (!forked) {
            vm.skip(true);
        }

        uint256 amount = 1_000e18;
        deal(address(HYDX), address(buyback), amount);

        uint256 bribeBalanceBefore = HYDX.balanceOf(GAUGE_BRIBE);
        uint256 epoch = IBribeView(GAUGE_BRIBE).getEpochStart();
        (, uint256 rewardsBefore,) = IBribeView(GAUGE_BRIBE).rewardData(address(HYDX), epoch);

        // Permissionless, so a keeper outage cannot strand the HYDX.
        vm.prank(stranger);
        uint256 sent = buyback.bribe();

        assertEq(sent, amount);
        assertEq(HYDX.balanceOf(address(buyback)), 0, "buyback must retain nothing");
        assertEq(HYDX.balanceOf(GAUGE_BRIBE), bribeBalanceBefore + amount);

        (, uint256 rewardsAfter,) = IBribeView(GAUGE_BRIBE).rewardData(address(HYDX), epoch);
        assertEq(rewardsAfter, rewardsBefore + amount, "bribe must be credited to this epoch");

        console2.log("epoch          ", epoch);
        console2.log("HYDX bribed    ", sent);
        console2.log("epoch rewards  ", rewardsAfter);
    }

    function test_BribeRevertsWhenTargetUnset() public {
        if (!forked) {
            vm.skip(true);
        }

        HydropumpBuyback unset = new HydropumpBuyback(admin, operator, address(HYDX), address(0));
        deal(address(HYDX), address(unset), 1e18);

        vm.expectRevert(HydropumpBuyback.GaugeBribeNotSet.selector);
        unset.bribe();
    }
}
