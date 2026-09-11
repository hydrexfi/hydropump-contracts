// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HydropumpBuyback} from "../contracts/HydropumpBuyback.sol";
import {HydropumpAddresses} from "../contracts/libraries/HydropumpAddresses.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

contract MockBribe {
    mapping(address => uint256) public received;

    function notifyRewardAmount(address rewardsToken, uint256 reward) external {
        received[rewardsToken] += reward;
        MockERC20(rewardsToken).transferFrom(msg.sender, address(this), reward);
    }
}

contract HydropumpBuybackTest is Test {
    HydropumpBuyback internal buyback;
    MockERC20 internal hydx;
    MockERC20 internal weth;
    MockERC20 internal usdc;
    MockRouter internal router;
    MockBribe internal gaugeBribe;

    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        hydx = new MockERC20("Hydrex", "HYDX");
        weth = new MockERC20("Wrapped Ether", "WETH");
        usdc = new MockERC20("USD Coin", "USDC");
        // The router is a constant on the contract, so put the mock's code at that address.
        vm.etch(HydropumpAddresses.MULTI_ROUTER, address(new MockRouter()).code);
        router = MockRouter(HydropumpAddresses.MULTI_ROUTER);
        gaugeBribe = new MockBribe();

        buyback = new HydropumpBuyback(owner, operator, address(hydx), address(gaugeBribe));
    }

    function _swapData(MockERC20 tokenIn, uint256 amountIn, uint256 out, uint256 minOut)
        internal
        view
        returns (HydropumpBuyback.SwapData memory)
    {
        return HydropumpBuyback.SwapData({
            inputToken: address(tokenIn),
            amountIn: amountIn,
            routerCalldata: abi.encodeCall(
                MockRouter.swap, (address(tokenIn), amountIn, address(hydx), out, address(buyback))
            ),
            minHydxOut: minOut
        });
    }

    function test_ConvertsManyAssetsInOneCall() public {
        weth.mint(address(buyback), 1e18);
        usdc.mint(address(buyback), 500e6);

        HydropumpBuyback.SwapData[] memory swaps = new HydropumpBuyback.SwapData[](2);
        swaps[0] = _swapData(weth, 1e18, 100e18, 90e18);
        swaps[1] = _swapData(usdc, 500e6, 40e18, 40e18);

        vm.prank(operator);
        uint256 out = buyback.buyback(swaps);

        assertEq(out, 140e18);
        assertEq(hydx.balanceOf(address(buyback)), 140e18);
        assertEq(weth.balanceOf(address(buyback)), 0);
        assertEq(usdc.balanceOf(address(buyback)), 0);
    }

    function test_RouteCalldataIsBuiltOffChain() public {
        weth.mint(address(buyback), 1e18);

        // The contract never encodes a path itself; whatever the operator built off-chain is executed.
        HydropumpBuyback.SwapData[] memory swaps = new HydropumpBuyback.SwapData[](1);
        swaps[0] = _swapData(weth, 1e18, 7e18, 0);

        vm.prank(operator);
        buyback.buyback(swaps);

        assertEq(hydx.balanceOf(address(buyback)), 7e18);
    }

    function test_RouterIsHardcoded() public view {
        assertEq(buyback.MULTI_ROUTER(), HydropumpAddresses.MULTI_ROUTER);
    }

    function test_RevertsWhenOutputMissesTheBound() public {
        weth.mint(address(buyback), 1e18);
        HydropumpBuyback.SwapData[] memory swaps = new HydropumpBuyback.SwapData[](1);
        swaps[0] = _swapData(weth, 1e18, 10e18, 11e18);

        vm.prank(operator);
        vm.expectRevert(HydropumpBuyback.InsufficientOutput.selector);
        buyback.buyback(swaps);
    }

    function test_RouteSendingOutputElsewhereFailsTheBound() public {
        weth.mint(address(buyback), 1e18);

        HydropumpBuyback.SwapData[] memory swaps = new HydropumpBuyback.SwapData[](1);
        swaps[0] = _swapData(weth, 1e18, 10e18, 1);
        swaps[0].routerCalldata = abi.encodeCall(MockRouter.swap, (address(weth), 1e18, address(hydx), 10e18, stranger));

        // Output is measured as this contract's balance delta, so a misdirected route cannot pass.
        vm.prank(operator);
        vm.expectRevert(HydropumpBuyback.InsufficientOutput.selector);
        buyback.buyback(swaps);
    }

    function test_FailedRouteRevertsAndLeavesNoApproval() public {
        weth.mint(address(buyback), 1e18);
        HydropumpBuyback.SwapData[] memory swaps = new HydropumpBuyback.SwapData[](1);
        swaps[0] = _swapData(weth, 1e18, 1e18, 0);
        swaps[0].routerCalldata = abi.encodeCall(MockRouter.fail, ());

        vm.prank(operator);
        vm.expectRevert(HydropumpBuyback.SwapFailed.selector);
        buyback.buyback(swaps);

        assertEq(weth.allowance(address(buyback), address(router)), 0);
    }

    function test_BuybackIsOperatorGated() public {
        vm.prank(stranger);
        vm.expectRevert(HydropumpBuyback.NotOperator.selector);
        buyback.buyback(new HydropumpBuyback.SwapData[](0));
    }

    function test_BribeIsPermissionlessAndSendsEverything() public {
        hydx.mint(address(buyback), 42e18);

        vm.prank(stranger);
        uint256 amount = buyback.bribe();

        assertEq(amount, 42e18);
        assertEq(gaugeBribe.received(address(hydx)), 42e18);
        assertEq(hydx.balanceOf(address(buyback)), 0);
        assertEq(hydx.balanceOf(stranger), 0);
    }

    function test_BribeRevertsWithNothingToSend() public {
        vm.expectRevert(HydropumpBuyback.NothingToBribe.selector);
        buyback.bribe();
    }

    function test_AdminSettersAreOwnerOnly() public {
        vm.prank(stranger);
        vm.expectRevert();
        buyback.setOperator(stranger);

        vm.prank(owner);
        buyback.setOperator(stranger);
        assertEq(buyback.operator(), stranger);
    }

    function test_SweepIsBatchedAndOwnerOnly() public {
        weth.mint(address(buyback), 1e18);

        vm.prank(stranger);
        vm.expectRevert();
        buyback.sweep(_one(address(weth)), stranger, _oneUint(1e18));

        vm.prank(owner);
        vm.expectRevert(HydropumpBuyback.LengthMismatch.selector);
        buyback.sweep(_one(address(weth)), owner, new uint256[](2));

        vm.prank(owner);
        buyback.sweep(_one(address(weth)), owner, _oneUint(1e18));
        assertEq(weth.balanceOf(owner), 1e18);
    }

    function _one(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _oneUint(uint256 v) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = v;
    }
}
