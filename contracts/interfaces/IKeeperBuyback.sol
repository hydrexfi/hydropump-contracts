// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IKeeperBuyback {
    function onFeesForKeeper(
        address token,
        address[] calldata assets,
        uint256[] calldata amounts,
        address keeper,
        uint256 veTokenId
    ) external;
}
