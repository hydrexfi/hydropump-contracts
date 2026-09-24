// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

interface IHydropumpPoolDeployer {
    function launcher() external view returns (address);
    function algebraFactory() external view returns (address);
    function pluginByPool(address pool) external view returns (address);
    function createPool(address token0, address token1) external returns (address);
}
