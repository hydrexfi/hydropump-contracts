// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {HydropumpAutoLP} from "../contracts/HydropumpAutoLP.sol";
import {HydropumpFeeEscrow} from "../contracts/HydropumpFeeEscrow.sol";
import {HydropumpLocker} from "../contracts/HydropumpLocker.sol";
import {HydropumpAddresses} from "../contracts/libraries/HydropumpAddresses.sol";
import {MockAlgebraPool} from "./mocks/MockAlgebraPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";

contract HydropumpAutoLPTest is Test {
    address internal constant NPM = HydropumpAddresses.NONFUNGIBLE_POSITION_MANAGER;

    HydropumpLocker internal locker;
    HydropumpFeeEscrow internal escrow;
    HydropumpAutoLP internal strategy;
    MockPositionManager internal npm;
    MockAlgebraPool internal pool;
    MockERC20 internal token;
    MockERC20 internal quote;

    address internal owner = makeAddr("owner");
    address internal launcher = makeAddr("launcher");
    address internal creator = makeAddr("creator");

    function setUp() public {
        vm.etch(NPM, address(new MockPositionManager()).code);
        npm = MockPositionManager(NPM);
        pool = new MockAlgebraPool();
        token = new MockERC20("Token", "TOKEN");
        quote = new MockERC20("Quote", "QUOTE");
        npm.setPair(address(token), address(quote));

        locker = HydropumpLocker(
            address(
                new ERC1967Proxy(
                    address(new HydropumpLocker()),
                    abi.encodeCall(HydropumpLocker.initialize, (owner, launcher, makeAddr("buyback"), 7_500, 2_500))
                )
            )
        );
        escrow = new HydropumpFeeEscrow(owner, address(locker));
        vm.prank(owner);
        locker.setFeeEscrow(address(escrow));

        strategy = HydropumpAutoLP(Clones.clone(address(new HydropumpAutoLP())));
        strategy.initialize(
            address(token), address(quote), address(pool), address(locker), address(escrow), owner, owner
        );

        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (1, 2);
        vm.prank(launcher);
        locker.registerLaunchWithAutoLp(
            address(token), address(quote), address(pool), creator, creator, ids, address(strategy), 1_000
        );
        npm.setPosition(1, 100, 200);
        npm.setPosition(2, 200, 300);
    }

    function test_CompoundsEscrowFeesIntoTheActiveBand() public {
        pool.setTick(250);
        token.mint(NPM, 10_000);
        quote.mint(NPM, 5_000);
        npm.setOwed(1, 10_000, 5_000);
        locker.collect(address(token), 1);

        vm.prank(owner);
        strategy.execute(250, 5, 700, 350);

        assertEq(npm.increased0(2), 800);
        assertEq(npm.increased1(2), 400);
        assertEq(npm.increased0(1), 0, "inactive position unchanged");
        assertEq(token.balanceOf(address(strategy)), 200, "unused balance retained for next cycle");
        assertEq(quote.balanceOf(address(strategy)), 100);
    }

    function test_RevertsWhenNoPositionIsActive() public {
        pool.setTick(350);
        vm.prank(owner);
        vm.expectRevert(HydropumpAutoLP.NoActivePosition.selector);
        strategy.execute(350, 5, 0, 0);
    }

    function test_OnlyOperatorCanExecute() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(HydropumpAutoLP.NotOperator.selector);
        strategy.execute(150, 5, 0, 0);
    }

    function test_OwnerCanRotateOperator() public {
        address nextOperator = makeAddr("nextOperator");
        vm.prank(owner);
        strategy.setOperator(nextOperator);

        pool.setTick(150);
        vm.prank(nextOperator);
        strategy.execute(150, 5, 0, 0);
    }

    function test_ImplementationCannotBeInitialized() public {
        HydropumpAutoLP implementation = new HydropumpAutoLP();
        vm.expectRevert();
        implementation.initialize(
            address(token), address(quote), address(pool), address(locker), address(escrow), owner, owner
        );
    }
}
