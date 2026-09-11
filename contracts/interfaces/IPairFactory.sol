// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Hydrex classic (solidly) pair factory.
interface IPairFactory {
    function createPair(address tokenA, address tokenB, bool stable) external returns (address pair);

    function getPair(address tokenA, address tokenB, bool stable) external view returns (address pair);
}
