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
    address internal constant KYBER_ROUTER = HydropumpAddresses.KYBER_ROUTER;
    address internal constant WETH = HydropumpAddresses.WETH;

    /// @dev Block the pinned route was quoted at, and the address it names as sender and recipient.
    uint256 internal constant ROUTE_BLOCK = 51_453_947;
    address internal constant ROUTE_RECIPIENT = 0xE3c2e65e0B7126E0F3485a2deE8e14eb1b9D91BA;
    string internal constant ROUTE_FILE = "script/fixtures/kyber-weth-hydx.txt";

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

    /*//////////////////////////////////////////////////////////////
                              THE SWAP LEG
    //////////////////////////////////////////////////////////////*/

    /// The daily job, against the real aggregator: sell the quote asset for HYDX and bribe the gauge.
    ///
    /// Pinned, because the route is real KyberSwap calldata captured at that block — the aggregator
    /// builds it off-chain and it is only valid where it was quoted. It bakes in its recipient too,
    /// which is why the contract is deployed to the address the route names rather than a fresh one.
    ///
    /// This is the leg the mocked unit tests cannot cover: whether the router we point at actually
    /// accepts what the aggregator hands us. It did not, once — the address was Hydrex's MultiRouter
    /// proxy, which takes its own ABI rather than raw aggregator calldata, and every swap reverted.
    function test_SellsQuoteForHydxThroughTheLiveAggregator() public {
        if (!forked) {
            vm.skip(true);
        }
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), ROUTE_BLOCK);

        HydropumpBuyback pinned = HydropumpBuyback(ROUTE_RECIPIENT);
        deployCodeTo(
            "HydropumpBuyback.sol:HydropumpBuyback",
            abi.encode(admin, operator, address(HYDX), GAUGE_BRIBE),
            ROUTE_RECIPIENT
        );

        uint256 amountIn = 0.1 ether;
        deal(WETH, address(pinned), amountIn);
        assertEq(pinned.router(), KYBER_ROUTER, "the default target must be the aggregator itself");

        HydropumpBuyback.SwapData[] memory swaps = new HydropumpBuyback.SwapData[](1);
        swaps[0] = HydropumpBuyback.SwapData({
            inputToken: WETH,
            amountIn: amountIn,
            routerCalldata: vm.parseBytes(vm.readFile(ROUTE_FILE)),
            minHydxOut: 8_000e18 // the quote was ~8474 HYDX; a loose floor, since this is not a price test
        });

        vm.prank(operator);
        uint256 bought = pinned.buyback(swaps);

        assertGt(bought, 8_000e18, "the route must actually fill");
        assertEq(IERC20(WETH).balanceOf(address(pinned)), 0, "and spend the whole input");
        assertEq(IERC20(WETH).allowance(address(pinned), KYBER_ROUTER), 0, "leaving no standing approval");

        // And straight on into the gauge, which is the whole point of the job.
        uint256 bribeBefore = HYDX.balanceOf(GAUGE_BRIBE);
        uint256 sent = pinned.bribe();

        assertEq(sent, bought, "everything bought is bribed");
        assertEq(HYDX.balanceOf(address(pinned)), 0, "nothing retained");
        assertEq(HYDX.balanceOf(GAUGE_BRIBE), bribeBefore + bought);

        console2.log("WETH in ", amountIn);
        console2.log("HYDX out", bought);
    }

    /// The bound is the only protection on an arbitrary route, so it has to bite against the real router.
    function test_TheBoundBitesOnARealRoute() public {
        if (!forked) {
            vm.skip(true);
        }
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), ROUTE_BLOCK);

        HydropumpBuyback pinned = HydropumpBuyback(ROUTE_RECIPIENT);
        deployCodeTo(
            "HydropumpBuyback.sol:HydropumpBuyback",
            abi.encode(admin, operator, address(HYDX), GAUGE_BRIBE),
            ROUTE_RECIPIENT
        );
        deal(WETH, address(pinned), 0.1 ether);

        HydropumpBuyback.SwapData[] memory swaps = new HydropumpBuyback.SwapData[](1);
        swaps[0] = HydropumpBuyback.SwapData({
            inputToken: WETH,
            amountIn: 0.1 ether,
            routerCalldata: vm.parseBytes(vm.readFile(ROUTE_FILE)),
            minHydxOut: 1_000_000e18 // far above what the route can fill
        });

        vm.prank(operator);
        vm.expectRevert(HydropumpBuyback.InsufficientOutput.selector);
        pinned.buyback(swaps);
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
