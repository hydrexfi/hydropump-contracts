// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from "../../contracts/interfaces/INonfungiblePositionManager.sol";

/// @notice Minimal stand-in for the Algebra position manager, etched at the address the contracts hardcode.
contract MockPositionManager {
    address public token0;
    address public token1;
    mapping(uint256 positionId => uint256) public owed0;
    mapping(uint256 positionId => uint256) public owed1;
    mapping(uint256 positionId => int24) public tickLower;
    mapping(uint256 positionId => int24) public tickUpper;
    mapping(uint256 positionId => uint256) public increased0;
    mapping(uint256 positionId => uint256) public increased1;

    function setPair(address _token0, address _token1) external {
        token0 = _token0;
        token1 = _token1;
    }

    function setOwed(uint256 positionId, uint256 amount0, uint256 amount1) external {
        owed0[positionId] = amount0;
        owed1[positionId] = amount1;
    }

    function setPosition(uint256 positionId, int24 lower, int24 upper) external {
        tickLower[positionId] = lower;
        tickUpper[positionId] = upper;
    }

    function positions(uint256 tokenId)
        external
        view
        returns (uint96, address, address, address, address, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        return (0, address(0), token0, token1, address(0), tickLower[tokenId], tickUpper[tokenId], 0, 0, 0, 0, 0);
    }

    function increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams calldata params)
        external
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        amount0 = params.amount0Desired * 4 / 5;
        amount1 = params.amount1Desired * 4 / 5;
        require(amount0 >= params.amount0Min && amount1 >= params.amount1Min, "slippage");
        if (amount0 > 0) IERC20(token0).transferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) IERC20(token1).transferFrom(msg.sender, address(this), amount1);
        increased0[params.tokenId] += amount0;
        increased1[params.tokenId] += amount1;
        liquidity = uint128(amount0 + amount1);
    }

    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = (owed0[params.tokenId], owed1[params.tokenId]);
        owed0[params.tokenId] = 0;
        owed1[params.tokenId] = 0;
        if (amount0 > 0) IERC20(token0).transfer(params.recipient, amount0);
        if (amount1 > 0) IERC20(token1).transfer(params.recipient, amount1);
    }
}
