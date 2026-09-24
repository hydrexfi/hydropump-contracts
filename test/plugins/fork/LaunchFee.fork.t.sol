// SPDX-License-Identifier: MIT
pragma solidity =0.8.20;

import {Test} from "forge-std/Test.sol";
import {HydrexBasePlugin} from "../../../contracts/plugins/HydrexBasePlugin.sol";
import {AlgebraFeeConfiguration} from "../../../contracts/plugins/base/AlgebraFeeConfiguration.sol";
import {IAlgebraFactory} from "@cryptoalgebra/integral-core/contracts/interfaces/IAlgebraFactory.sol";
import {IAlgebraPool} from "@cryptoalgebra/integral-core/contracts/interfaces/IAlgebraPool.sol";
import {TickMath} from "@cryptoalgebra/integral-core/contracts/libraries/TickMath.sol";

// Minimal standard token used only to exercise real pool accounting on a fork.
contract LaunchFeeForkToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract LaunchFeeForkTest is Test {
    IAlgebraFactory internal constant FACTORY = IAlgebraFactory(0x36077D39cdC65E1e3FB65810430E5b2c4D5fA29E);
    IAlgebraPool internal pool;
    HydrexBasePlugin internal plugin;
    LaunchFeeForkToken internal token0;
    LaunchFeeForkToken internal token1;
    uint256 internal launchBlock;
    uint256 internal initialTime;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")), 51716638);
        require(address(FACTORY).code.length > 0, "factory missing");
        LaunchFeeForkToken a = new LaunchFeeForkToken();
        LaunchFeeForkToken b = new LaunchFeeForkToken();
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);
        pool = IAlgebraPool(FACTORY.createPool(address(token0), address(token1), ""));
        require(address(pool).code.length > 0, "pool missing");
        plugin = new HydrexBasePlugin(
            address(pool), address(FACTORY), address(this), AlgebraFeeConfiguration(0, 0, 0, 0, 1, 1, 10000), 10000
        );
        plugin.changeDynamicFeeStatus(true);
        // Admin impersonation is local to this fork. Production authorization and
        // automatic Hydropump attachment are intentionally not implemented here.
        vm.prank(FACTORY.owner());
        pool.setPlugin(address(plugin));
        pool.initialize(uint160(1 << 96));
        launchBlock = block.number;
        initialTime = block.timestamp;
        pool.mint(address(this), address(this), -60000, 60000, 1e24, "");
        assertEq(plugin.launchBlock(), launchBlock);
    }

    function algebraMintCallback(uint256 amount0, uint256 amount1, bytes calldata) external {
        require(msg.sender == address(pool), "only pool");
        if (amount0 != 0) require(token0.transfer(msg.sender, amount0));
        if (amount1 != 0) require(token1.transfer(msg.sender, amount1));
    }

    function algebraSwapCallback(int256 amount0, int256 amount1, bytes calldata) external {
        require(msg.sender == address(pool), "only pool");
        if (amount0 > 0) require(token0.transfer(msg.sender, uint256(amount0)));
        if (amount1 > 0) require(token1.transfer(msg.sender, uint256(amount1)));
    }

    function _inputSwap(bool direction, bool prepay) internal returns (uint256 output) {
        int256 amount0;
        int256 amount1;
        uint160 limit = direction ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
        if (prepay) {
            (amount0, amount1) =
                pool.swapWithPaymentInAdvance(address(this), address(this), direction, 100 ether, limit, "");
        } else {
            (amount0, amount1) = pool.swap(address(this), direction, 100 ether, limit, "");
        }
        assertEq(direction ? amount0 : amount1, 100 ether);
        output = uint256(-(direction ? amount1 : amount0));
    }

    function _assertSchedule(bool direction, bool prepay) internal {
        uint256 balanceBefore = (direction ? token1 : token0).balanceOf(address(this));
        uint256 first = _inputSwap(direction, prepay);
        assertApproxEqAbs(first, 1 ether, 1e13, "99% charged at launch");
        assertEq((direction ? token1 : token0).balanceOf(address(this)) - balanceBefore, first);
        vm.roll(launchBlock + 5);
        vm.warp(initialTime + 10);
        uint256 middle = _inputSwap(direction, prepay);
        assertApproxEqAbs(middle, 50 ether, 1e16, "50% charged halfway");
        vm.roll(launchBlock + 10);
        vm.warp(initialTime + 20);
        uint256 last = _inputSwap(direction, prepay);
        assertApproxEqAbs(last, 99 ether, 5e16, "1% normal fee restored");
        assertGt(last, middle);
        assertGt(middle, first);
    }

    function test_RealPoolChargesDecayToken0ToToken1() public {
        _assertSchedule(true, false);
    }

    function test_RealPoolChargesDecayToken1ToToken0() public {
        _assertSchedule(false, false);
    }

    function test_PrepaymentCannotBypassLaunchFee() public {
        _assertSchedule(true, true);
    }

    function test_ExactOutputPaysLaunchFee() public {
        (int256 input, int256 output) = pool.swap(address(this), true, -1 ether, TickMath.MIN_SQRT_RATIO + 1, "");
        assertEq(output, -1 ether);
        assertApproxEqAbs(uint256(input), 100 ether, 1e15);
        vm.roll(launchBlock + 10);
        vm.warp(initialTime + 20);
        (input, output) = pool.swap(address(this), true, -1 ether, TickMath.MIN_SQRT_RATIO + 1, "");
        assertEq(output, -1 ether);
        assertApproxEqAbs(uint256(input), uint256(1 ether) * 100 / 99, 1e13);
    }
}
