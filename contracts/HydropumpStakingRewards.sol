// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {HydropumpFeeEscrow} from "./HydropumpFeeEscrow.sol";

/// @title HydropumpStakingRewards
/// @notice Per-launch staking group distributing two LP-fee assets pro rata to launch-token stakers.
contract HydropumpStakingRewards is Initializable {
    using SafeERC20 for IERC20;

    uint256 internal constant Q128 = 1 << 128;

    struct RewardState {
        uint256 rewardPerTokenX128;
    }

    struct UserReward {
        uint256 rewardPerTokenPaidX128;
        uint256 accrued;
    }

    IERC20 public stakingToken;
    address public quoteToken;
    HydropumpFeeEscrow public feeEscrow;
    address public locker;
    bytes32 public escrowAccount;
    address public noStakerRecipient;
    uint64 public minStakeDuration;
    uint256 public totalStaked;

    mapping(address user => uint256 amount) public balanceOf;
    mapping(address user => uint256 timestamp) public unlockTime;
    mapping(address rewardToken => RewardState state) public rewardState;
    mapping(address user => mapping(address rewardToken => UserReward reward)) public userReward;

    bool private _executing;

    event Staked(address indexed user, uint256 amount, uint256 unlockTime);
    event Unstaked(address indexed user, uint256 amount);
    event RewardSynced(address indexed rewardToken, uint256 amount);
    event RewardClaimed(address indexed user, address indexed rewardToken, uint256 amount);
    event NoStakerRewardPaid(address indexed recipient, address indexed rewardToken, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error StakeLocked();
    error InsufficientStake();
    error ReentrantCall();
    error NotLocker();

    modifier nonReentrant() {
        if (_executing) revert ReentrantCall();
        _executing = true;
        _;
        _executing = false;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address stakingToken_,
        address quoteToken_,
        address feeEscrow_,
        address locker_,
        address noStakerRecipient_,
        uint64 minStakeDuration_
    ) external initializer {
        if (
            stakingToken_ == address(0) || quoteToken_ == address(0) || feeEscrow_ == address(0)
                || locker_ == address(0) || noStakerRecipient_ == address(0)
        ) {
            revert ZeroAddress();
        }
        stakingToken = IERC20(stakingToken_);
        quoteToken = quoteToken_;
        feeEscrow = HydropumpFeeEscrow(feeEscrow_);
        locker = locker_;
        escrowAccount = keccak256(abi.encode("HYDROPUMP_STAKING_REWARDS", stakingToken_));
        noStakerRecipient = noStakerRecipient_;
        minStakeDuration = minStakeDuration_;
    }

    function setNoStakerRecipient(address newRecipient) external {
        if (msg.sender != locker) revert NotLocker();
        if (newRecipient == address(0)) revert ZeroAddress();
        noStakerRecipient = newRecipient;
    }

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _syncRewards();
        _checkpoint(msg.sender, address(stakingToken));
        _checkpoint(msg.sender, quoteToken);

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        totalStaked += amount;
        balanceOf[msg.sender] += amount;
        unlockTime[msg.sender] = block.timestamp + minStakeDuration;
        emit Staked(msg.sender, amount, unlockTime[msg.sender]);
    }

    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp < unlockTime[msg.sender]) revert StakeLocked();
        if (amount > balanceOf[msg.sender]) revert InsufficientStake();
        _syncRewards();
        _checkpoint(msg.sender, address(stakingToken));
        _checkpoint(msg.sender, quoteToken);

        balanceOf[msg.sender] -= amount;
        totalStaked -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claim(address[] calldata rewardTokens) external nonReentrant returns (uint256[] memory amounts) {
        _syncRewards();
        amounts = new uint256[](rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address rewardToken = rewardTokens[i];
            _checkpoint(msg.sender, rewardToken);
            uint256 amount = userReward[msg.sender][rewardToken].accrued;
            if (amount == 0) continue;
            userReward[msg.sender][rewardToken].accrued = 0;
            amounts[i] = amount;
            IERC20(rewardToken).safeTransfer(msg.sender, amount);
            emit RewardClaimed(msg.sender, rewardToken, amount);
        }
    }

    function syncRewards() external nonReentrant {
        _syncRewards();
    }

    function earned(address user, address rewardToken) external view returns (uint256) {
        UserReward memory reward = userReward[user][rewardToken];
        return reward.accrued
            + Math.mulDiv(
                balanceOf[user], rewardState[rewardToken].rewardPerTokenX128 - reward.rewardPerTokenPaidX128, Q128
            );
    }

    function _syncRewards() internal {
        _syncReward(address(stakingToken));
        _syncReward(quoteToken);
    }

    function _syncReward(address rewardToken) internal {
        uint256 beforeBalance = IERC20(rewardToken).balanceOf(address(this));
        feeEscrow.claim(escrowAccount, rewardToken);
        uint256 received = IERC20(rewardToken).balanceOf(address(this)) - beforeBalance;
        RewardState storage state = rewardState[rewardToken];
        if (totalStaked == 0) {
            if (received > 0) {
                IERC20(rewardToken).safeTransfer(noStakerRecipient, received);
                emit NoStakerRewardPaid(noStakerRecipient, rewardToken, received);
            }
            return;
        }

        if (received == 0) return;
        state.rewardPerTokenX128 += Math.mulDiv(received, Q128, totalStaked);
        emit RewardSynced(rewardToken, received);
    }

    function _checkpoint(address user, address rewardToken) internal {
        RewardState storage state = rewardState[rewardToken];
        UserReward storage reward = userReward[user][rewardToken];
        reward.accrued += Math.mulDiv(balanceOf[user], state.rewardPerTokenX128 - reward.rewardPerTokenPaidX128, Q128);
        reward.rewardPerTokenPaidX128 = state.rewardPerTokenX128;
    }
}
