// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HydropumpStakingRewards} from "../contracts/HydropumpStakingRewards.sol";
import {HydropumpFeeEscrow} from "../contracts/HydropumpFeeEscrow.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract NaiveProRataRewards {
    MockERC20 public immutable stakingToken;
    MockERC20 public immutable rewardToken;
    uint256 public totalStaked;
    mapping(address => uint256) public balanceOf;

    constructor(MockERC20 stakingToken_, MockERC20 rewardToken_) {
        stakingToken = stakingToken_;
        rewardToken = rewardToken_;
    }

    function stake(uint256 amount) external {
        stakingToken.transferFrom(msg.sender, address(this), amount);
        balanceOf[msg.sender] += amount;
        totalStaked += amount;
    }

    function claimable(address user) external view returns (uint256) {
        return rewardToken.balanceOf(address(this)) * balanceOf[user] / totalStaked;
    }
}

contract HydropumpStakingRewardsTest is Test {
    MockERC20 internal token;
    MockERC20 internal quote;
    HydropumpFeeEscrow internal escrow;
    HydropumpStakingRewards internal staking;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal creator = makeAddr("creator");
    uint64 internal constant MIN_DURATION = 7 days;

    function setUp() public {
        token = new MockERC20("Launch", "LAUNCH");
        quote = new MockERC20("Quote", "QUOTE");
        escrow = new HydropumpFeeEscrow(address(this), address(this));
        staking = HydropumpStakingRewards(Clones.clone(address(new HydropumpStakingRewards())));
        staking.initialize(address(token), address(quote), address(escrow), address(this), creator, MIN_DURATION);

        token.mint(alice, 100 ether);
        token.mint(bob, 100 ether);
        vm.prank(alice);
        token.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        token.approve(address(staking), type(uint256).max);
    }

    function test_NaiveCurrentBalanceAccountingLetsLateStakerTakePastRewards() public {
        NaiveProRataRewards naive = new NaiveProRataRewards(token, quote);
        vm.prank(alice);
        token.approve(address(naive), type(uint256).max);
        vm.prank(bob);
        token.approve(address(naive), type(uint256).max);
        vm.prank(alice);
        naive.stake(100 ether);
        quote.mint(address(naive), 100 ether);

        vm.prank(bob);
        naive.stake(100 ether);

        assertEq(naive.claimable(bob), 50 ether, "late staker steals half of already-earned rewards");
    }

    function test_SnapshotPreventsLateStakerFromClaimingPastRewards() public {
        vm.prank(alice);
        staking.stake(100 ether);
        _credit(address(quote), 100 ether);
        staking.syncRewards();

        vm.prank(bob);
        staking.stake(100 ether);

        assertEq(staking.earned(alice, address(quote)), 100 ether);
        assertEq(staking.earned(bob, address(quote)), 0);
    }

    function test_MinimumDurationIsSelectedAtDeploymentAndEnforced() public {
        vm.prank(alice);
        staking.stake(10 ether);
        assertEq(staking.unlockTime(alice), block.timestamp + MIN_DURATION);

        vm.prank(alice);
        vm.expectRevert(HydropumpStakingRewards.StakeLocked.selector);
        staking.unstake(10 ether);

        vm.warp(block.timestamp + MIN_DURATION);
        vm.prank(alice);
        staking.unstake(10 ether);
        assertEq(token.balanceOf(alice), 100 ether);
    }

    function test_RewardsAfterBobJoinsAreSplitProRata() public {
        vm.prank(alice);
        staking.stake(100 ether);
        vm.prank(bob);
        staking.stake(100 ether);
        _credit(address(quote), 100 ether);
        staking.syncRewards();

        assertEq(staking.earned(alice, address(quote)), 50 ether);
        assertEq(staking.earned(bob, address(quote)), 50 ether);
    }

    function test_FirstLateStakerCannotInheritRewardsFromAnEmptyGroup() public {
        _credit(address(quote), 100 ether);
        staking.syncRewards();
        assertEq(quote.balanceOf(creator), 100 ether);

        vm.prank(alice);
        staking.stake(100 ether);

        assertEq(staking.earned(alice, address(quote)), 0);
    }

    function test_OnlyLockerCanUpdateNoStakerRecipient() public {
        vm.prank(alice);
        vm.expectRevert(HydropumpStakingRewards.NotLocker.selector);
        staking.setNoStakerRecipient(alice);

        staking.setNoStakerRecipient(bob);
        assertEq(staking.noStakerRecipient(), bob);
    }

    function test_StakerCanClaimBothFeeAssets() public {
        vm.prank(alice);
        staking.stake(100 ether);
        _credit(address(token), 20 ether);
        _credit(address(quote), 40 ether);

        address[] memory rewardTokens = new address[](2);
        (rewardTokens[0], rewardTokens[1]) = (address(token), address(quote));
        vm.prank(alice);
        uint256[] memory claimed = staking.claim(rewardTokens);

        assertApproxEqAbs(claimed[0], 20 ether, 1);
        assertApproxEqAbs(claimed[1], 40 ether, 1);
        assertApproxEqAbs(token.balanceOf(alice), 20 ether, 1, "staked principal remains in the group");
        assertApproxEqAbs(quote.balanceOf(alice), 40 ether, 1);
        assertEq(staking.balanceOf(alice), 100 ether);
    }

    function _credit(address rewardToken, uint256 amount) internal {
        quote.mint(address(this), rewardToken == address(quote) ? amount : 0);
        token.mint(address(this), rewardToken == address(token) ? amount : 0);
        IERC20(rewardToken).approve(address(escrow), amount);
        escrow.credit(staking.escrowAccount(), address(staking), rewardToken, amount);
    }
}
