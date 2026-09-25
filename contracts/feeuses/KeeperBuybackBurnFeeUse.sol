// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {BuybackBurnFeeUse} from "./BuybackBurnFeeUse.sol";
import {IKeeperBuyback} from "../interfaces/IKeeperBuyback.sol";
import {IVeHydx} from "../interfaces/IVeHydx.sol";

/// @notice Per-launch buybacks executable only by owners of active veHYDX positions.
/// @dev Creator setup is write-once. Bounties come only from the current quote allocation, never donations
///      or existing launch-token fees. Invariant: quote spent + bounty + returned quote == quote allocated.
contract KeeperBuybackBurnFeeUse is BuybackBurnFeeUse, IKeeperBuyback, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_BOUNTY_BPS = 250;
    IVeHydx public immutable votingEscrow;

    struct BuybackConfig {
        uint16 bountyBps;
        bool configured;
    }
    mapping(address token => BuybackConfig) public buybackConfig;
    address private _keeper;

    event BuybackConfigured(address indexed token, uint16 bountyBps);
    event KeeperBountyPaid(address indexed token, address indexed keeper, address indexed quoteToken, uint256 amount);

    error NotCreator();
    error AlreadyConfigured();
    error NotConfigured();
    error InvalidBounty();
    error IneligibleKeeper();
    error KeeperEntryRequired();

    constructor(address locker_, address votingEscrow_) BuybackBurnFeeUse(locker_) {
        if (votingEscrow_.code.length == 0) revert ZeroAddress();
        votingEscrow = IVeHydx(votingEscrow_);
    }

    /// @notice Creator's setup step after launch; 250 means a maximum 2.5% of the executed budget.
    /// @dev No implicit default: unconfigured launches cannot spend, and the chosen rate cannot change.
    function configureBuyback(address token, uint16 bountyBps) external {
        if (msg.sender != locker.creatorOf(token)) revert NotCreator();
        if (buybackConfig[token].configured) revert AlreadyConfigured();
        if (bountyBps > MAX_BOUNTY_BPS) revert InvalidBounty();
        buybackConfig[token] = BuybackConfig(bountyBps, true);
        emit BuybackConfigured(token, bountyBps);
    }

    /// @dev Prevents spendCreatorShare/handleCreatorRewards/handleAllRewards bypassing the keeper check.
    function onFees(address, address[] calldata, uint256[] calldata) external view override {
        if (msg.sender != address(locker)) revert NotLocker();
        revert KeeperEntryRequired();
    }

    /// @dev Only the guarded locker supplies keeper identity. Approval/delegation alone is insufficient.
    function onFeesForKeeper(
        address token,
        address[] calldata assets,
        uint256[] calldata amounts,
        address keeper,
        uint256 veTokenId
    ) external nonReentrant {
        if (msg.sender != address(locker)) revert NotLocker();
        if (!buybackConfig[token].configured) revert NotConfigured();
        if (votingEscrow.ownerOf(veTokenId) != keeper || votingEscrow.balanceOfNFT(veTokenId) == 0) {
            revert IneligibleKeeper();
        }
        _keeper = keeper;
        _handleFees(token, assets, amounts);
        _keeper = address(0);
    }

    /// @dev Reserve the bounty first; partial fills earn proportionally, rounded down. No bought tokens
    ///      means no bounty. All unspent input and unused bounty reserve return to the creator ledger.
    function _buy(address token, address quoteToken, uint256 quoteAmount)
        internal
        override
        returns (uint256 quoteSpent, uint256 bought)
    {
        uint256 bps = buybackConfig[token].bountyBps;
        uint256 reserved = Math.mulDiv(quoteAmount, bps, 10_000);
        (quoteSpent, bought) = _swapQuote(token, quoteToken, quoteAmount - reserved);
        uint256 bounty;
        if (bought > 0 && quoteSpent > 0) {
            bounty = Math.min(reserved, Math.mulDiv(quoteSpent, bps, 10_000 - bps));
        }
        if (bounty > 0) {
            IERC20(quoteToken).safeTransfer(_keeper, bounty);
            emit KeeperBountyPaid(token, _keeper, quoteToken, bounty);
        }
        _returnQuote(token, quoteToken, quoteAmount - quoteSpent - bounty);
    }
}
