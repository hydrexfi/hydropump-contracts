// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The ownership and current voting power reads exposed by Hydrex VotingEscrowV2.
interface IVeHydx {
    function ownerOf(uint256 tokenId) external view returns (address);
    function balanceOfNFT(uint256 tokenId) external view returns (uint256);
}
