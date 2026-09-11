// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

interface IAlgebraPool {
    function token0() external view returns (address);

    function token1() external view returns (address);

    function liquidity() external view returns (uint128);

    function globalState()
        external
        view
        returns (uint160 price, int24 tick, uint16 lastFee, uint16 pluginConfig, uint16 communityFee, bool unlocked);
}
