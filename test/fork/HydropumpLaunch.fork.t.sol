// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HydropumpLauncher} from "../../contracts/core/HydropumpLauncher.sol";
import {HydropumpLocker} from "../../contracts/core/HydropumpLocker.sol";
import {IAlgebraPool} from "../../contracts/interfaces/IAlgebraPool.sol";
import {FeeUses} from "../../contracts/libraries/FeeUses.sol";
import {ForkFixture} from "./helpers/ForkFixture.sol";

/// @dev Algebra Integral pools expose where their community fee goes; the repo's IAlgebraPool does not need it.
interface IAlgebraPoolCommunityVault {
    function communityVault() external view returns (address);
}

/// @notice A full launch against the live Hydrex deployment on Base, on both sides of the pair.
contract HydropumpLaunchForkTest is ForkFixture {
    /// @dev Algebra's share of every swap fee on a launch pool, in Algebra's per-mille units (1000 = all of it).
    ///      Hydrex sets it as the factory default (`setDefaultCommunityFee(15)`, block 51,695,670), so a
    ///      pre-gauge Hydropump pool pays Algebra its 1.5% at the pool, and the locked positions keep the rest.
    ///      A gauged pool instead runs at 1000 and pays Algebra at the fee splitter.
    uint16 internal constant ALGEBRA_COMMUNITY_FEE = 15;
    uint16 internal constant GAUGED_COMMUNITY_FEE = 1000;

    function test_LaunchSeedsTheCurveAndLocksEveryPositionAsToken0() public onlyForked {
        (address token, address pool, uint256[] memory ids, address account) = _launchOnSide(WETH, true, bytes32(0));

        assertLt(uint160(token), uint160(WETH));
        assertEq(IAlgebraPool(pool).token0(), token, "launch token is token0");
        assertEq(IAlgebraPool(pool).token1(), WETH);
        assertEq(_currentTick(pool), WETH_START_TICK, "pool opens at the configured tick");
        _assertCurveShape(token, WETH, pool, ids);

        // Supply is what reached the pool, not what was minted: rounding left over from the bands is
        // burnt rather than paid out, so the two are equal and both a hair under `SUPPLY()`.
        assertEq(IERC20(token).totalSupply(), IERC20(token).balanceOf(pool), "all of it is in the pool");
        assertLe(IERC20(token).totalSupply(), launcher.SUPPLY());
        assertApproxEqRel(IERC20(token).totalSupply(), launcher.SUPPLY(), 1e12, "and only a hair under");
        assertEq(IERC20(token).balanceOf(address(launcher)), 0, "launcher holds nothing after");
        assertEq(IERC20(token).balanceOf(account), 0, "and the creator starts with none");

        HydropumpLocker.Launch memory launch = locker.getLaunch(token);
        assertEq(launch.pool, pool);
        assertEq(launch.creator, account);

        console2.log("token0 launch", token);
        console2.log("pool         ", pool);
    }

    /// The same launch with the token above the quote. Algebra sorts the pair by address, so the pool opens
    /// at the negated tick and the bands descend from it — the same ladder, reflected.
    function test_LaunchSeedsTheCurveAndLocksEveryPositionAsToken1() public onlyForked {
        (address token, address pool, uint256[] memory ids,) = _launchOnSide(WETH, false, bytes32(0));

        assertGt(uint160(token), uint160(WETH));
        assertEq(IAlgebraPool(pool).token0(), WETH);
        assertEq(IAlgebraPool(pool).token1(), token, "launch token is token1");
        assertEq(_currentTick(pool), -WETH_START_TICK, "pool opens at the negated tick");
        _assertCurveShape(token, WETH, pool, ids);

        console2.log("token1 launch", token);
        console2.log("pool         ", pool);
    }

    /// The two orientations have to open at the same price in quote terms, or a launch would be worth a
    /// different amount depending on an address it does not control.
    function test_BothOrientationsOpenAtTheSamePrice() public onlyForked {
        (address up, address upPool,,) = _launchOnSide(WETH, true, bytes32(0));
        (address down, address downPool,,) = _launchOnSide(WETH, false, bytes32(0));

        assertEq(_currentTick(downPool), -_currentTick(upPool), "opening ticks must be reciprocal");
        assertApproxEqRel(
            _priceE18(upPool, up, WETH), _priceE18(downPool, down, WETH), 0.0002e18, "price survives the mirror"
        );
    }

    /// HYDX at 0x00000e7e... is the quote the mirror exists for: nothing can sort below it, so before this
    /// it was only launchable after roughly 1.16M keccaks of salt mining. Now it just launches.
    function test_AQuoteNothingCanSortBelowLaunchesImmediately() public onlyForked {
        (address token, address pool, uint256[] memory ids) = _launchFrom(creator, HYDX, bytes32(0), 0);

        assertGt(uint160(token), uint160(HYDX), "no address sorts below HYDX in practice");
        assertEq(_currentTick(pool), -HYDX_START_TICK);
        _assertCurveShape(token, HYDX, pool, ids);

        console2.log("HYDX-quoted launch", token);
    }

    /// There is nothing to supply, nothing to mine, and nothing to predict. An address comes out of
    /// `CREATE` and the `Launched` event is where anyone finds out what it was.
    function test_AddressesAreOnlyKnowableAfterTheFact() public onlyForked {
        vm.recordLogs();
        (address token,,) = _launchFrom(creator, WETH, bytes32(0), 0);

        bytes32 signature =
            keccak256("Launched(address,address,address,address,int24,uint256[],string,string,bytes32,uint64)");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != signature) continue;
            found = true;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), token);
        }
        assertTrue(found, "the launch must announce its address");
        assertGt(token.code.length, 0);

        // And a second launch is simply a different address, with nothing shared between them.
        (address second,,) = _launchFrom(creator, WETH, bytes32(0), 0);
        assertTrue(second != token);
    }

    function test_TheDevBuyFillsInTheSameTransactionOnBothSides() public onlyForked {
        uint256 buyAmount = 0.05 ether;

        _arrangeSide(WETH, true);
        address upAccount = creator;
        (address token, address pool,) = _launchFrom(upAccount, WETH, bytes32(0), buyAmount);
        assertGt(IERC20(token).balanceOf(upAccount), 0, "buyer receives tokens");
        assertEq(IERC20(WETH).balanceOf(address(launcher)), 0, "no quote stranded");
        _assertQuoteAfterInitialBuy(pool, buyAmount);
        _assertBuyLandedInPoolOrVault(pool, buyAmount);
        assertGt(_currentTick(pool), WETH_START_TICK, "buying token0 raises token1/token0");
        uint256 upFill = IERC20(token).balanceOf(upAccount);

        _arrangeSide(WETH, false);
        address downAccount = creator;
        (address mirrored, address mirroredPool,) = _launchFrom(downAccount, WETH, bytes32(0), buyAmount);
        assertGt(IERC20(mirrored).balanceOf(downAccount), 0);
        _assertQuoteAfterInitialBuy(mirroredPool, buyAmount);
        _assertBuyLandedInPoolOrVault(mirroredPool, buyAmount);
        assertLt(_currentTick(mirroredPool), -WETH_START_TICK, "buying token1 lowers it");

        // Opposite directions on the tick, the same thing economically — and the same fill, because either
        // side of the price is the same ladder.
        assertApproxEqRel(IERC20(mirrored).balanceOf(downAccount), upFill, 0.005e18, "fills must match");
    }

    /// A launch pool pays Algebra its 1.5% and nothing more. A gauged Hydrex CL pool runs at communityFee
    /// 1000/1000, which would send every swap fee to the community vault and leave the locked positions —
    /// and so every fee use — with nothing; a launch pool must never open like that.
    function test_LaunchPoolsPayOnlyAlgebrasCommunityFeeOnEitherSide() public onlyForked {
        (, address pool,,) = _launchOnSide(WETH, true, bytes32(0));
        (,,,, uint16 communityFee,) = IAlgebraPool(pool).globalState();
        assertEq(communityFee, ALGEBRA_COMMUNITY_FEE, "launch pools pay Algebra 1.5% and keep the rest with the LP");
        assertLt(communityFee, GAUGED_COMMUNITY_FEE, "a launch pool must not open as a gauged pool");

        (, address mirroredPool,,) = _launchOnSide(WETH, false, bytes32(0));
        (,,,, uint16 mirroredCommunityFee,) = IAlgebraPool(mirroredPool).globalState();
        assertEq(mirroredCommunityFee, ALGEBRA_COMMUNITY_FEE);
    }

    function _assertQuoteAfterInitialBuy(address pool, uint256 amount) internal view {
        (,,,, uint16 communityFee,) = IAlgebraPool(pool).globalState();
        uint256 community = amount * 990000 / 1000000 * communityFee / 1000;
        assertApproxEqAbs(IERC20(WETH).balanceOf(pool), amount - community, 10);
    }

    function test_LaunchFeeAccumulatesAndIsClaimable() public onlyForked {
        _launchFrom(creator, WETH, bytes32(0), 0);
        assertEq(address(launcher).balance, LAUNCH_FEE);

        uint256 surplus = 0.002 ether;
        vm.prank(creator);
        launcher.launch{value: LAUNCH_FEE + surplus}(
            HydropumpLauncher.LaunchParams({
                name: "Beta",
                symbol: "BETA",
                quoteToken: WETH,
                creatorRecipient: creator,
                buyAmount: 0,
                feeUse: bytes32(0)
            })
        );
        assertEq(address(launcher).balance, LAUNCH_FEE * 2 + surplus, "surplus is kept");

        address sink = makeAddr("sink");
        vm.prank(admin);
        assertEq(launcher.claimLaunchFees(sink), LAUNCH_FEE * 2 + surplus);
        assertEq(sink.balance, LAUNCH_FEE * 2 + surplus);
    }

    function test_AFeeUseChosenAtLaunchIsRecorded() public onlyForked {
        (address token,,) = _launchFrom(creator, WETH, FeeUses.BUYBACK_BURN, 0);

        assertEq(registry.feeUseOf(token), FeeUses.BUYBACK_BURN);
        assertEq(registry.implementationFor(token), address(buybackBurn));
    }

    /// @dev The dev buy's quote ends up in the pool, apart from Algebra's community share of the swap fee,
    ///      which the pool forwards to its community vault. So: some quote left the pool (the fee is charged),
    ///      no more than Algebra's share of the whole input could have (nothing else takes quote), and the
    ///      vault holds at least that much. The vault can be shared with other pools, so its balance is only
    ///      a lower bound, not an exact match.
    function _assertBuyLandedInPoolOrVault(address pool, uint256 buyAmount) internal view {
        uint256 inPool = IERC20(WETH).balanceOf(pool);
        assertLe(inPool, buyAmount, "the pool cannot hold more quote than was bought with");
        uint256 toCommunity = buyAmount - inPool;
        assertGt(toCommunity, 0, "Algebra's community share was charged on the buy");
        assertLe(toCommunity, buyAmount * ALGEBRA_COMMUNITY_FEE / 1000, "only Algebra's share may leave the pool");
        address vault = IAlgebraPoolCommunityVault(pool).communityVault();
        assertGe(IERC20(WETH).balanceOf(vault), toCommunity, "what left the pool reached the community vault");
    }
}
