// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

contract MockAlgebraPool {
    int24 public tick;

    function setTick(int24 newTick) external {
        tick = newTick;
    }

    function globalState()
        external
        view
        returns (
            uint160 price,
            int24 currentTick,
            uint16 lastFee,
            uint16 pluginConfig,
            uint16 communityFee,
            bool unlocked
        )
    {
        return (0, tick, 0, 0, 0, true);
    }
}
