// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {INonfungiblePositionManager} from "../../contracts/interfaces/INonfungiblePositionManager.sol";
import {ISwapRouter} from "../../contracts/interfaces/ISwapRouter.sol";
import {TickMath} from "../../contracts/libraries/TickMath.sol";

/// @dev Inverse of `TickMath.getSqrtRatioAtTick`, by bisection. Test-only, so the ~21 iterations it costs
///      buy a faithful current tick without pulling in a second tick library.
library MockTickMath {
    /// @dev What `amountIn` is worth at `tick`, ignoring fees and impact. A tick is a token1/token0 ratio
    ///      in raw units, so the two directions are reciprocal. Two mulDivs rather than squaring the sqrt
    ///      price, which overflows a uint256 at high ticks.
    function quoteAtTick(int24 tick, uint256 amountIn, bool zeroForOne) internal pure returns (uint256) {
        uint256 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);
        if (zeroForOne) {
            return Math.mulDiv(Math.mulDiv(amountIn, sqrtPriceX96, 1 << 96), sqrtPriceX96, 1 << 96);
        }
        return Math.mulDiv(Math.mulDiv(amountIn, 1 << 96, sqrtPriceX96), 1 << 96, sqrtPriceX96);
    }

    function tickAtSqrtRatio(uint160 sqrtPriceX96) internal pure returns (int24) {
        int24 low = TickMath.MIN_TICK;
        int24 high = TickMath.MAX_TICK;
        while (low < high) {
            int24 mid = low + (high - low + 1) / 2;
            if (TickMath.getSqrtRatioAtTick(mid) <= sqrtPriceX96) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }
        return low;
    }
}

/// @notice Stand-in for an Algebra Integral pool, carrying only what the launcher reads off one.
contract MockAlgebraPool {
    address public token0;
    address public token1;
    int24 public tickSpacing;
    uint160 public price;

    function init(address _token0, address _token1, int24 _tickSpacing, uint160 _price) external {
        (token0, token1, tickSpacing, price) = (_token0, _token1, _tickSpacing, _price);
    }

    function setPrice(uint160 _price) external {
        price = _price;
    }

    function globalState() external view returns (uint160, int24, uint16, uint16, uint16, bool) {
        return (price, MockTickMath.tickAtSqrtRatio(price), 0, 0, 0, true);
    }

    function liquidity() external pure returns (uint128) {
        return 0;
    }

    function fee() external pure returns (uint16) {
        return 3000;
    }

    /// @dev Test-only escape hatch so the router mock can fill out of the pool's balance.
    function pay(address token, address to, uint256 amount) external {
        IERC20(token).transfer(to, amount);
    }
}

/// @notice Stand-in for the Algebra position manager, etched at the address the contracts hardcode.
/// @dev Deliberately not a reimplementation of Uniswap's liquidity math — the fork tests cover the real
///      thing. What it reproduces exactly is the one rule the curve depends on: a range takes only token0
///      while the price sits at or below its lower bound, only token1 at or above its upper bound, and both
///      strictly between. That boundary, the equal case included, is the whole reason band 0 mints without a
///      wei of quote, so it is the part worth modelling precisely.
contract MockAlgebra {
    struct Position {
        address token0;
        address token1;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        address owner;
        uint128 owed0;
        uint128 owed1;
    }

    /// @notice Spacing given to every pool this mock creates. Tests vary it to prove the curve aligns.
    int24 public nextTickSpacing = 200;

    uint256 public nextId = 1;
    mapping(bytes32 pair => address) public pools;
    mapping(uint256 id => Position) internal _positions;

    // Optional caps simulate a ratio-limited partial fill. Real liquidity math is covered on fork.
    uint256 public usageCap0;
    uint256 public usageCap1;

    function setUsageCaps(uint256 cap0, uint256 cap1) external {
        (usageCap0, usageCap1) = (cap0, cap1);
    }

    /// @notice Extra amounts `mint` reports as consumed, so the launcher's own `QuoteConsumed` assertion
    ///         can be exercised. Zero everywhere except the test that pokes at it.
    uint256 public phantom0;
    uint256 public phantom1;

    error Unsorted();
    error PoolMissing();
    error ZeroLiquidity();

    function setPhantomUsage(uint256 _phantom0, uint256 _phantom1) external {
        (phantom0, phantom1) = (_phantom0, _phantom1);
    }

    function setTickSpacing(int24 spacing) external {
        nextTickSpacing = spacing;
    }

    function poolFor(address tokenA, address tokenB) public view returns (address) {
        return pools[keccak256(abi.encodePacked(tokenA, tokenB))];
    }

    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        address,
        uint160 sqrtPriceX96,
        bytes calldata
    ) external returns (address pool) {
        if (token0 >= token1) revert Unsorted();

        pool = poolFor(token0, token1);
        if (pool != address(0)) return pool;

        pool = address(new MockAlgebraPool());
        MockAlgebraPool(pool).init(token0, token1, nextTickSpacing, sqrtPriceX96);
        pools[keccak256(abi.encodePacked(token0, token1))] = pool;
    }

    function mint(INonfungiblePositionManager.MintParams calldata params)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        if (params.token0 >= params.token1) revert Unsorted();

        address pool = poolFor(params.token0, params.token1);
        if (pool == address(0)) revert PoolMissing();

        uint160 current = MockAlgebraPool(pool).price();

        // A range needs token0 while the price is below its top, and token1 while it is above its bottom.
        // At or below the bottom that leaves token0 alone; at or above the top, token1 alone; anywhere
        // strictly between, both. The equal cases are what let band 0 open flush against the price.
        bool needs0 = current < TickMath.getSqrtRatioAtTick(params.tickUpper);
        bool needs1 = current > TickMath.getSqrtRatioAtTick(params.tickLower);

        // Real liquidity is the min over the sides a range needs, so a zero on any required side is a
        // zero position — which the position manager rejects rather than mints.
        if (needs0 && params.amount0Desired == 0) revert ZeroLiquidity();
        if (needs1 && params.amount1Desired == 0) revert ZeroLiquidity();

        amount0 = needs0 ? params.amount0Desired : 0;
        amount1 = needs1 ? params.amount1Desired : 0;

        if (amount0 > 0) IERC20(params.token0).transferFrom(msg.sender, pool, amount0);
        if (amount1 > 0) IERC20(params.token1).transferFrom(msg.sender, pool, amount1);

        // Reported, not moved: the point is only to make the launcher's assertion see a non-zero.
        amount0 += phantom0;
        amount1 += phantom1;

        // Not the real curve math, only something positive and monotone in the deposit.
        liquidity = uint128((amount0 + amount1) >> 32);

        tokenId = nextId++;
        _positions[tokenId] = Position({
            token0: params.token0,
            token1: params.token1,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: liquidity,
            owner: params.recipient,
            owed0: 0,
            owed1: 0
        });
    }

    /// @dev Mirrors `mint`'s rule for which sides a range needs, and keeps the position's owner — the
    ///      whole point being that adding to a locked position does not move it.
    function increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams calldata params)
        external
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        Position storage position = _positions[params.tokenId];
        address pool = poolFor(position.token0, position.token1);
        uint160 current = MockAlgebraPool(pool).price();

        bool needs0 = current < TickMath.getSqrtRatioAtTick(position.tickUpper);
        bool needs1 = current > TickMath.getSqrtRatioAtTick(position.tickLower);

        amount0 = needs0 ? params.amount0Desired : 0;
        amount1 = needs1 ? params.amount1Desired : 0;
        if (amount0 == 0 && amount1 == 0) revert ZeroLiquidity();

        if (usageCap0 != 0 && amount0 > usageCap0) amount0 = usageCap0;
        if (usageCap1 != 0 && amount1 > usageCap1) amount1 = usageCap1;

        if (amount0 > 0) IERC20(position.token0).transferFrom(msg.sender, pool, amount0);
        if (amount1 > 0) IERC20(position.token1).transferFrom(msg.sender, pool, amount1);

        liquidity = uint128((amount0 + amount1) >> 32);
        position.liquidity += liquidity;
    }

    function setOwed(uint256 tokenId, uint128 owed0, uint128 owed1) external {
        _positions[tokenId].owed0 = owed0;
        _positions[tokenId].owed1 = owed1;
    }

    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage position = _positions[params.tokenId];
        (amount0, amount1) = (position.owed0, position.owed1);
        (position.owed0, position.owed1) = (0, 0);

        if (amount0 > 0) IERC20(position.token0).transfer(params.recipient, amount0);
        if (amount1 > 0) IERC20(position.token1).transfer(params.recipient, amount1);
    }

    /// @dev The real twelve-value shape, because `AutoLpFeeUse` reads a band's range off it.
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96,
            address,
            address token0,
            address token1,
            address,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256,
            uint256,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        Position memory position = _positions[tokenId];
        return (
            0,
            address(0),
            position.token0,
            position.token1,
            address(0),
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            0,
            0,
            position.owed0,
            position.owed1
        );
    }

    function range(uint256 tokenId) external view returns (int24 tickLower, int24 tickUpper) {
        Position memory position = _positions[tokenId];
        return (position.tickLower, position.tickUpper);
    }

    function liquidityOf(uint256 tokenId) external view returns (uint128) {
        return _positions[tokenId].liquidity;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return _positions[tokenId].owner;
    }
}

/// @notice Lets the swap-router mock move tokens the pool holds without an approval dance.
interface IMockPoolPayer {
    function pay(address token, address to, uint256 amount) external;
}

/// @notice Stand-in for the Algebra swap router, etched at the address the contracts hardcode.
/// @dev Fills at the pool's own spot price less a flat fee, out of the pool's balance, then steps the price
///      a fixed number of ticks in whichever direction the trade implies. Not a curve — the fork tests
///      price real swaps — but pricing off spot rather than a constant is what makes a TWAP bound testable:
///      a test can shove spot away from the time-weighted tick and watch the bound reject the fill.
contract MockSwapRouter {
    MockAlgebra public immutable manager;

    /// @notice Fee taken off the fill, in hundredths of a bip.
    uint256 public feePips = 3_000;

    /// @notice Ticks the price moves per fill.
    int24 public bump = 500;

    constructor(MockAlgebra _manager) {
        manager = _manager;
    }

    function configure(uint256 _feePips, int24 _bump) external {
        (feePips, bump) = (_feePips, _bump);
    }

    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata params) external returns (uint256 amountOut) {
        (address token0, address token1) =
            params.tokenIn < params.tokenOut ? (params.tokenIn, params.tokenOut) : (params.tokenOut, params.tokenIn);

        address pool = manager.poolFor(token0, token1);
        require(pool != address(0), "no pool");

        int24 spot = MockTickMath.tickAtSqrtRatio(MockAlgebraPool(pool).price());
        amountOut = MockTickMath.quoteAtTick(spot, params.amountIn, params.tokenIn == token0);
        amountOut -= (amountOut * feePips) / 1_000_000;
        require(amountOut >= params.amountOutMinimum, "Too little received");

        IERC20(params.tokenIn).transferFrom(msg.sender, pool, params.amountIn);
        IMockPoolPayer(pool).pay(params.tokenOut, params.recipient, amountOut);

        int24 moved = params.tokenOut == token0 ? spot + bump : spot - bump;
        MockAlgebraPool(pool).setPrice(TickMath.getSqrtRatioAtTick(moved));
    }
}
