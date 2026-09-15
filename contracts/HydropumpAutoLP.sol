// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {HydropumpFeeEscrow} from "./HydropumpFeeEscrow.sol";
import {HydropumpAddresses} from "./libraries/HydropumpAddresses.sol";
import {IAlgebraPool} from "./interfaces/IAlgebraPool.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";

interface IHydropumpCompounder {
    function getPositions(address token) external view returns (uint256[] memory);

    function compound(
        address token,
        uint256 positionIndex,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        int24 expectedTick,
        uint24 maxTickDeviation
    ) external returns (uint128 liquidity, uint256 amount0, uint256 amount1);
}

/// @title HydropumpAutoLP
/// @notice Per-launch strategy that compounds its escrow allocation into the currently active locked band.
contract HydropumpAutoLP is Initializable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    INonfungiblePositionManager public constant nonfungiblePositionManager =
        INonfungiblePositionManager(HydropumpAddresses.NONFUNGIBLE_POSITION_MANAGER);

    address public launchToken;
    address public quoteToken;
    IAlgebraPool public pool;
    IHydropumpCompounder public locker;
    HydropumpFeeEscrow public feeEscrow;
    bytes32 public escrowAccount;
    address public operator;
    bool private _executing;

    event Compounded(uint256 indexed positionId, uint256 amount0, uint256 amount1, uint128 liquidity);

    error ZeroAddress();
    error NoActivePosition();
    error NotOperator();
    error ReentrantCall();

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
        address launchToken_,
        address quoteToken_,
        address pool_,
        address locker_,
        address feeEscrow_,
        address owner_,
        address operator_
    ) external initializer {
        if (
            launchToken_ == address(0) || quoteToken_ == address(0) || pool_ == address(0) || locker_ == address(0)
                || feeEscrow_ == address(0) || owner_ == address(0) || operator_ == address(0)
        ) revert ZeroAddress();

        __Ownable_init(owner_);

        launchToken = launchToken_;
        quoteToken = quoteToken_;
        pool = IAlgebraPool(pool_);
        locker = IHydropumpCompounder(locker_);
        feeEscrow = HydropumpFeeEscrow(feeEscrow_);
        escrowAccount = keccak256(abi.encode("HYDROPUMP_AUTO_LP_FEES", launchToken_));
        operator = operator_;
    }

    /// @notice Pull all accrued auto-LP fees and add the usable balances to the band active at the current tick.
    /// @dev Unused assets remain in this strategy and are included in the next compounding cycle.
    function execute(int24 expectedTick, uint24 maxTickDeviation, uint256 amount0Min, uint256 amount1Min)
        external
        nonReentrant
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        if (msg.sender != operator) revert NotOperator();
        feeEscrow.claim(escrowAccount, launchToken);
        feeEscrow.claim(escrowAccount, quoteToken);

        (, int24 currentTick,,,,) = pool.globalState();
        uint256[] memory positionIds = locker.getPositions(launchToken);
        uint256 activeIndex = type(uint256).max;
        uint256 activePositionId;

        for (uint256 i = 0; i < positionIds.length; i++) {
            (,,,,, int24 tickLower, int24 tickUpper,,,,,) = nonfungiblePositionManager.positions(positionIds[i]);
            if (currentTick >= tickLower && currentTick < tickUpper) {
                activeIndex = i;
                activePositionId = positionIds[i];
                break;
            }
        }
        if (activeIndex == type(uint256).max) revert NoActivePosition();

        uint256 balance0 = IERC20(launchToken).balanceOf(address(this));
        uint256 balance1 = IERC20(quoteToken).balanceOf(address(this));
        IERC20(launchToken).forceApprove(address(locker), balance0);
        IERC20(quoteToken).forceApprove(address(locker), balance1);

        (liquidity, amount0, amount1) = locker.compound(
            launchToken, activeIndex, balance0, balance1, amount0Min, amount1Min, expectedTick, maxTickDeviation
        );

        IERC20(launchToken).forceApprove(address(locker), 0);
        IERC20(quoteToken).forceApprove(address(locker), 0);
        emit Compounded(activePositionId, amount0, amount1, liquidity);
    }

    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert ZeroAddress();
        operator = newOperator;
    }
}
