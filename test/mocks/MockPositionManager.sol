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

    /// @dev Per-position override of the pair, so one test can hold two launches whose pools sort
    ///      differently. Falls back to the default pair when unset.
    mapping(uint256 positionId => address) public pairToken0;
    mapping(uint256 positionId => address) public pairToken1;

    function setPair(address _token0, address _token1) external {
        token0 = _token0;
        token1 = _token1;
    }

    function setPairFor(uint256 positionId, address _token0, address _token1) external {
        pairToken0[positionId] = _token0;
        pairToken1[positionId] = _token1;
    }

    function pairOf(uint256 positionId) public view returns (address, address) {
        address custom = pairToken0[positionId];
        return custom == address(0) ? (token0, token1) : (custom, pairToken1[positionId]);
    }

    function setOwed(uint256 positionId, uint256 amount0, uint256 amount1) external {
        owed0[positionId] = amount0;
        owed1[positionId] = amount1;
    }

    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = (owed0[params.tokenId], owed1[params.tokenId]);
        owed0[params.tokenId] = 0;
        owed1[params.tokenId] = 0;

        (address asset0, address asset1) = pairOf(params.tokenId);
        if (amount0 > 0) IERC20(asset0).transfer(params.recipient, amount0);
        if (amount1 > 0) IERC20(asset1).transfer(params.recipient, amount1);
    }
}
