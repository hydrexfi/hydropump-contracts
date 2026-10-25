// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ForkFixture} from "./helpers/ForkFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KeeperBuybackBurnFeeUse} from "../../contracts/feeuses/KeeperBuybackBurnFeeUse.sol";
import {IVeHydx} from "../../contracts/interfaces/IVeHydx.sol";
import {HydropumpAddresses} from "../../contracts/libraries/HydropumpAddresses.sol";
import {FeeUses} from "../../contracts/libraries/FeeUses.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";

contract KeeperBuybackForkTest is ForkFixture {
    using stdStorage for StdStorage;
    KeeperBuybackBurnFeeUse internal keeperBuyback;
    IVeHydx internal ve = IVeHydx(HydropumpAddresses.VOTING_ESCROW);
    address internal keeper;

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        keeperBuyback = new KeeperBuybackBurnFeeUse(address(locker), address(ve));
        keeper = ve.ownerOf(1);
        require(ve.balanceOfNFT(1) > 0, "fixture requires an active real veHYDX lock");
        vm.prank(owner);
        registry.replaceFeeUse(FeeUses.BUYBACK_BURN, address(keeperBuyback));
    }

    function _wantToken0() internal pure virtual returns (bool) {
        return true;
    }

    function _ready() internal returns (address token, address pool) {
        (token, pool,,) = _launchOnSide(WETH, _wantToken0(), FeeUses.BUYBACK_BURN);
        vm.prank(creator);
        keeperBuyback.configureBuyback(token, 250);
        _swapIn(alice, WETH, token, 1 ether);
        locker.splitRewards(token);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 2);
    }

    function test_RealVeHolderEarnsBountyAndTaxedOutputIsBurned() public onlyForked {
        (address token,) = _ready();
        uint256 quote = locker.creatorOwed(token, WETH);
        uint256 beforeKeeper = IERC20(WETH).balanceOf(keeper);
        uint256 supply = IERC20(token).totalSupply();
        vm.prank(keeper);
        locker.executeKeeperBuyback(token, 1);
        uint256 paid = IERC20(WETH).balanceOf(keeper) - beforeKeeper;
        assertEq(paid, quote * 250 / 10_000, "full-fill bounty");
        assertEq(locker.creatorOwed(token, WETH), 0);
        assertGt(keeperBuyback.lifetimeBurned(token), 0);
        assertGt(supply - IERC20(token).totalSupply(), keeperBuyback.lifetimeBurned(token), "launch tax also burned");
        assertEq(IERC20(token).balanceOf(address(keeperBuyback)), 0);
        assertEq(IERC20(WETH).balanceOf(address(keeperBuyback)), 0);
    }

    function test_RealNftCannotBeClaimedByAnotherCaller() public onlyForked {
        (address token,) = _ready();
        vm.prank(alice);
        vm.expectRevert(KeeperBuybackBurnFeeUse.IneligibleKeeper.selector);
        locker.executeKeeperBuyback(token, 1);
    }

    function test_RealPartialFillPaysOnlyProportionalBounty() public onlyForked {
        (address token,) = _ready();
        uint256 budget = 10 ether;
        deal(WETH, address(locker), IERC20(WETH).balanceOf(address(locker)) + budget);
        stdstore.target(address(locker)).sig("creatorOwed(address,address)").with_key(token).with_key(WETH)
            .checked_write(budget);
        uint256 beforeKeeper = IERC20(WETH).balanceOf(keeper);
        vm.prank(keeper);
        locker.executeKeeperBuyback(token, 1);
        uint256 paid = IERC20(WETH).balanceOf(keeper) - beforeKeeper;
        uint256 remaining = locker.creatorOwed(token, WETH);
        uint256 spent = budget - paid - remaining;
        assertGt(remaining, 0);
        assertGt(spent, 0);
        assertEq(paid, spent * 250 / 9750);
        assertEq(IERC20(WETH).balanceOf(address(keeperBuyback)), 0);
    }

    function test_PushedRealPoolPaysNoBountyAndRetainsQuote() public onlyForked {
        (address token,) = _ready();
        uint256 quote = locker.creatorOwed(token, WETH);
        _swapIn(bob, WETH, token, 2 ether);
        locker.splitRewards(token);
        quote = locker.creatorOwed(token, WETH);
        uint256 beforeKeeper = IERC20(WETH).balanceOf(keeper);
        vm.prank(keeper);
        locker.executeKeeperBuyback(token, 1);
        assertEq(IERC20(WETH).balanceOf(keeper), beforeKeeper);
        assertEq(locker.creatorOwed(token, WETH), quote);
    }
}

contract KeeperBuybackMirroredForkTest is KeeperBuybackForkTest {
    function _wantToken0() internal pure override returns (bool) {
        return false;
    }
}
