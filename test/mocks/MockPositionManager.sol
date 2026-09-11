// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {INonfungiblePositionManager} from "../../contracts/interfaces/INonfungiblePositionManager.sol";

/// @notice Minimal stand-in for the Algebra position manager, etched at the address the contracts hardcode.
contract MockPositionManager {
    address public token0;
    address public token1;
    uint256 public owed0;
    uint256 public owed1;

    function setPair(address _token0, address _token1) external {
        token0 = _token0;
        token1 = _token1;
    }

    function setOwed(uint256 _owed0, uint256 _owed1) external {
        owed0 = _owed0;
        owed1 = _owed1;
    }

    function positions(uint256)
        external
        view
        returns (uint96, address, address, address, address, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        return (0, address(0), token0, token1, address(0), int24(0), int24(0), 0, 0, 0, 0, 0);
    }

    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = (owed0, owed1);
        (owed0, owed1) = (0, 0);
        if (amount0 > 0) IERC20(token0).transfer(params.recipient, amount0);
        if (amount1 > 0) IERC20(token1).transfer(params.recipient, amount1);
    }

    /// @notice Simulates the position manager handing an LP NFT to a locker
    function deposit(address to, uint256 tokenId, bytes calldata data) external returns (bytes4) {
        return IERC721Receiver(to).onERC721Received(address(this), address(this), tokenId, data);
    }
}
