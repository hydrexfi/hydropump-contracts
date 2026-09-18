// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title HydropumpRewardDistributor
/// @notice Holds rewards the operator has allocated, until whoever earned them withdraws.
/// @dev Deliberately knows nothing about why anyone is owed anything. The operator holds the emissions
///      stake, works out the split off-chain, and writes the result here; this contract only has to make
///      the result withdrawable and keep one recipient's balance out of another's reach.
///
///      No merkle root, because the operator is trusted either way — it is the one funding this — and a
///      root would add proofs and epochs to a ledger that is already just a mapping.
///
///      Two levels of authority, on purpose. The operator can only ever *give*: `allocate` adds to a
///      balance and pays for what it adds in the same call, so a compromised operator can credit people
///      but cannot take anything, including from this contract. The owner can *take*: rewrite the ledger
///      outright and withdraw regardless of it. The owner is a Safe; the operator is a hot key running a
///      weekly job, and the split is what makes that key survivable.
contract HydropumpRewardDistributor is Ownable2Step {
    using SafeERC20 for IERC20;

    /// @notice Writes allocations. The same key that claims the emissions being allocated.
    address public operator;

    /// @notice What each recipient can withdraw, per token.
    mapping(address recipient => mapping(address token => uint256)) public claimable;

    /// @notice Allocated and not yet withdrawn, per token. What `sweep` is not allowed to touch.
    mapping(address token => uint256) public totalOwed;

    /// @notice Lifetime withdrawn, per recipient and token. Survives a claim, unlike `claimable`.
    mapping(address recipient => mapping(address token => uint256)) public lifetimeClaimed;

    event Allocated(address indexed token, address indexed recipient, uint256 amount);
    event AllocationSet(address indexed token, address indexed recipient, uint256 previous, uint256 amount);
    event EmergencyWithdrawn(address indexed token, address indexed to, uint256 amount);
    event Claimed(address indexed token, address indexed recipient, uint256 amount);
    event OperatorUpdated(address indexed previousOperator, address indexed newOperator);

    error NotOperator();
    error ZeroAddress();
    error LengthMismatch();
    error NothingAllocated();

    modifier onlyOperator() {
        if (msg.sender != operator && msg.sender != owner()) revert NotOperator();
        _;
    }

    constructor(address _owner, address _operator) Ownable(_owner) {
        operator = _operator;
        emit OperatorUpdated(address(0), _operator);
    }

    /*//////////////////////////////////////////////////////////////
                               ALLOCATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Credit recipients and pull the total from the caller in the same transaction.
    /// @dev Funding and crediting together, so the ledger can never promise more than the contract holds.
    ///      Amounts add to whatever a recipient already has, so a weekly run is just another call.
    function allocate(address token, address[] calldata recipients, uint256[] calldata amounts)
        external
        onlyOperator
        returns (uint256 total)
    {
        if (token == address(0)) revert ZeroAddress();
        if (recipients.length != amounts.length) revert LengthMismatch();

        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i] == address(0)) revert ZeroAddress();
            if (amounts[i] == 0) continue;

            total += amounts[i];
            claimable[recipients[i]][token] += amounts[i];
            emit Allocated(token, recipients[i], amounts[i]);
        }

        if (total == 0) revert NothingAllocated();

        totalOwed[token] += total;
        IERC20(token).safeTransferFrom(msg.sender, address(this), total);
    }

    /*//////////////////////////////////////////////////////////////
                                 CLAIM
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw everything a recipient is owed in one token.
    /// @dev Permissionless, and always paid to the recipient rather than the caller — so the operator can
    ///      push payouts without anyone having to come and collect, and pushing costs nobody their reward.
    function claim(address recipient, address token) public returns (uint256 amount) {
        amount = claimable[recipient][token];
        if (amount == 0) return 0;

        claimable[recipient][token] = 0;
        totalOwed[token] -= amount;
        lifetimeClaimed[recipient][token] += amount;

        IERC20(token).safeTransfer(recipient, amount);
        emit Claimed(token, recipient, amount);
    }

    /// @notice `claim` across several tokens at once.
    function claimMany(address recipient, address[] calldata tokens) external returns (uint256[] memory amounts) {
        amounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            amounts[i] = claim(recipient, tokens[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    function setOperator(address newOperator) external onlyOwner {
        emit OperatorUpdated(operator, newOperator);
        operator = newOperator;
    }

    /// @notice Overwrite what recipients are owed, to whatever the owner says — including nothing.
    /// @dev Sets rather than adds, unlike `allocate`, because the reason to reach for this is a number
    ///      that is wrong rather than one that is short. Moves no tokens either way: lowering an
    ///      allocation leaves the funds here for `emergencyWithdraw`, and raising one is a promise the
    ///      owner has to cover.
    function setAllocation(address token, address[] calldata recipients, uint256[] calldata amounts)
        external
        onlyOwner
    {
        if (token == address(0)) revert ZeroAddress();
        if (recipients.length != amounts.length) revert LengthMismatch();

        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i] == address(0)) revert ZeroAddress();

            uint256 previous = claimable[recipients[i]][token];
            claimable[recipients[i]][token] = amounts[i];
            totalOwed[token] = totalOwed[token] - previous + amounts[i];

            emit AllocationSet(token, recipients[i], previous, amounts[i]);
        }
    }

    /// @notice Take any balance out, allocated or not.
    /// @dev Unbounded by design — the point is to be able to empty this contract when something has gone
    ///      wrong, and a hatch that respects the ledger is no use when the ledger is the problem.
    ///
    ///      Leaves `claimable` untouched, so a withdrawal that outruns it makes later claims fail on the
    ///      transfer rather than silently paying some and not others. Zero the ledger with
    ///      `setAllocation` first if the intent is to cancel rather than to rescue.
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();

        IERC20(token).safeTransfer(to, amount);
        emit EmergencyWithdrawn(token, to, amount);
    }
}
