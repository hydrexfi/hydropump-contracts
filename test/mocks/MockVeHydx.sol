// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

contract MockVeHydx {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint256) public balanceOfNFT;

    function setPosition(uint256 id, address owner, uint256 power) external {
        ownerOf[id] = owner;
        balanceOfNFT[id] = power;
    }
}
