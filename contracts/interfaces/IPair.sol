// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Hydrex classic (solidly) pair.
interface IPair {
    function mint(address to) external returns (uint256 liquidity);

    function stable() external view returns (bool);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function getReserves() external view returns (uint256 reserve0, uint256 reserve1, uint256 blockTimestampLast);
}
