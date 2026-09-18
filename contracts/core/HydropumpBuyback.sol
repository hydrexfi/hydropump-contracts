// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBribe} from "../interfaces/IBribe.sol";
import {HydropumpAddresses} from "../libraries/HydropumpAddresses.sol";

/// @title HydropumpBuyback
/// @notice Receives the protocol's share of launch fees from the locker, buys HYDX with it, and bribes
///         the Hydropump gauge.
contract HydropumpBuyback is Ownable2Step {
    using SafeERC20 for IERC20;

    IERC20 public immutable HYDX;

    address public router = HydropumpAddresses.KYBER_ROUTER;

    struct SwapData {
        address inputToken;
        uint256 amountIn;
        bytes routerCalldata;
        uint256 minHydxOut;
    }

    address public operator;
    address public gaugeBribe;

    event Swapped(address indexed inputToken, uint256 amountIn, uint256 hydxOut);
    event RouterUpdated(address indexed previousRouter, address indexed newRouter);
    event BribePlaced(address indexed gaugeBribe, uint256 hydxAmount, uint64 indexed epoch);
    event OperatorUpdated(address indexed previousOperator, address indexed newOperator);
    event GaugeBribeUpdated(address indexed previousBribe, address indexed newBribe);
    event Swept(address indexed asset, address indexed to, uint256 amount);

    error NotOperator();
    error ZeroAddress();
    error SwapFailed();
    error InsufficientOutput();
    error GaugeBribeNotSet();
    error NothingToBribe();
    error LengthMismatch();

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    modifier onlyOperator() {
        if (msg.sender != operator && msg.sender != owner()) revert NotOperator();
        _;
    }

    constructor(address _owner, address _operator, address _hydx, address _gaugeBribe) Ownable(_owner) {
        if (_hydx == address(0)) revert ZeroAddress();
        HYDX = IERC20(_hydx);
        operator = _operator;
        gaugeBribe = _gaugeBribe;

        emit OperatorUpdated(address(0), _operator);
        emit GaugeBribeUpdated(address(0), _gaugeBribe);
    }

    /*//////////////////////////////////////////////////////////////
                               USER WRITE
    //////////////////////////////////////////////////////////////*/

    /// @notice Convert held balances into HYDX along off-chain routes.
    function buyback(SwapData[] calldata swaps) external onlyOperator returns (uint256 totalHydxOut) {
        for (uint256 i = 0; i < swaps.length; i++) {
            totalHydxOut += _swap(swaps[i]);
        }
    }

    /// @notice The daily job: sell everything along the given routes and bribe the proceeds in one call.
    function buybackAndBribe(SwapData[] calldata swaps)
        external
        onlyOperator
        returns (uint256 totalHydxOut, uint256 bribed)
    {
        for (uint256 i = 0; i < swaps.length; i++) {
            totalHydxOut += _swap(swaps[i]);
        }
        bribed = _bribe();
    }

    /// @notice Deposit the full HYDX balance into the Hydropump gauge's bribe contract.
    function bribe() external returns (uint256 amount) {
        return _bribe();
    }

    function _bribe() internal returns (uint256 amount) {
        if (gaugeBribe == address(0)) revert GaugeBribeNotSet();

        amount = HYDX.balanceOf(address(this));
        if (amount == 0) revert NothingToBribe();

        HYDX.forceApprove(gaugeBribe, amount);
        IBribe(gaugeBribe).notifyRewardAmount(address(HYDX), amount);

        emit BribePlaced(gaugeBribe, amount, uint64(block.timestamp / 1 weeks));
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _swap(SwapData calldata swap) internal returns (uint256 hydxOut) {
        uint256 balanceBefore = HYDX.balanceOf(address(this));

        address target = router;
        IERC20(swap.inputToken).forceApprove(target, swap.amountIn);
        (bool success,) = target.call(swap.routerCalldata);
        IERC20(swap.inputToken).forceApprove(target, 0);
        if (!success) revert SwapFailed();

        hydxOut = HYDX.balanceOf(address(this)) - balanceBefore;
        if (hydxOut < swap.minHydxOut) revert InsufficientOutput();

        emit Swapped(swap.inputToken, swap.amountIn, hydxOut);
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    function setOperator(address newOperator) external onlyOwner {
        emit OperatorUpdated(operator, newOperator);
        operator = newOperator;
    }

    function setRouter(address newRouter) external onlyOwner {
        if (newRouter == address(0)) revert ZeroAddress();
        emit RouterUpdated(router, newRouter);
        router = newRouter;
    }

    function setGaugeBribe(address newGaugeBribe) external onlyOwner {
        emit GaugeBribeUpdated(gaugeBribe, newGaugeBribe);
        gaugeBribe = newGaugeBribe;
    }

    /// @notice Recover tokens the buyback has no route for.
    function sweep(address[] calldata assets, address to, uint256[] calldata amounts) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (assets.length != amounts.length) revert LengthMismatch();
        for (uint256 i = 0; i < assets.length; i++) {
            IERC20(assets[i]).safeTransfer(to, amounts[i]);
            emit Swept(assets[i], to, amounts[i]);
        }
    }
}
