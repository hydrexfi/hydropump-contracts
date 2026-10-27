// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {HydropumpLauncher} from "../../contracts/core/HydropumpLauncher.sol";
import {HydropumpLocker} from "../../contracts/core/HydropumpLocker.sol";
import {HydropumpRotator} from "../../contracts/core/HydropumpRotator.sol";
import {PairDirectory} from "../../contracts/helpers/PairDirectory.sol";
import {IAlgebraPool} from "../../contracts/interfaces/IAlgebraPool.sol";
import {INonfungiblePositionManager} from "../../contracts/interfaces/INonfungiblePositionManager.sol";
import {ISwapRouter} from "../../contracts/interfaces/ISwapRouter.sol";
import {FeeUses} from "../../contracts/libraries/FeeUses.sol";
import {HydropumpAddresses} from "../../contracts/libraries/HydropumpAddresses.sol";
import {TickMath} from "../../contracts/libraries/TickMath.sol";
import {DeployRotator} from "../../script/deploy/DeployRotator.s.sol";

/// @notice The rotation rollout rehearsed against production: the real deploy script, the locker upgrade
///         and `setRotator` as the locker's owner, targets set by the live operator, then launches made
///         through the live launcher, traded, aged, rotated and redeemed.
/// @dev Pinned to a block so every run sees the same 413 live launches and reruns come from the RPC cache.
contract ProdRolloutForkTest is Test {
    uint256 internal constant FORK_BLOCK = 53_166_380;
    uint256 internal constant PROD_DEPLOY_BLOCK = 51_785_877;

    HydropumpLauncher internal constant LAUNCHER = HydropumpLauncher(0x1a7460cfc2B44EB2FfB9879612E726bF6bf52745);
    HydropumpLocker internal constant LOCKER = HydropumpLocker(0x9c11834644C91A73AA959b01Bb7F1E148AF40D43);
    PairDirectory internal constant DIRECTORY = PairDirectory(0x22c104bf0cCc2258911FFA4DF7eC80f199ea0827);

    INonfungiblePositionManager internal constant NPM =
        INonfungiblePositionManager(HydropumpAddresses.NONFUNGIBLE_POSITION_MANAGER);
    ISwapRouter internal constant ROUTER = ISwapRouter(HydropumpAddresses.SWAP_ROUTER);

    address internal constant WETH = HydropumpAddresses.WETH;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant HYDX = HydropumpAddresses.HYDX;

    /// @dev Throwaway key for the rehearsal's deployer. Never a real one.
    uint256 internal constant DEPLOYER_KEY = 0xD3B10;

    HydropumpRotator internal rotator;
    address internal safe;
    address internal operator;
    bool internal forked;
    uint256 private _accounts;

    struct LiveLaunch {
        address token;
        bytes record;
        uint128 feesToken;
        uint128 feesQuote;
        uint256 owedToken;
        uint256 owedQuote;
        uint128[] liquidity;
    }

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, FORK_BLOCK);
        forked = true;
        safe = LOCKER.owner();
        operator = DIRECTORY.owner();
    }

    modifier onlyForked() {
        if (!forked) vm.skip(true);
        _;
    }

    // ---------------------------------------------------------------- rollout

    /// @dev The three steps, in the order the rollout runs them.
    function _rollout() internal {
        // 1. DeployRotator, run as written, with the live roles.
        address deployer = vm.addr(DEPLOYER_KEY);
        vm.deal(deployer, 1 ether);
        vm.setEnv("DEPLOYER_KEY", vm.toString(DEPLOYER_KEY));
        vm.setEnv("LOCKER_ADDRESS", vm.toString(address(LOCKER)));
        vm.setEnv("HYDROPUMP_ADMIN", vm.toString(safe));
        vm.setEnv("HYDROPUMP_OWNER", vm.toString(safe));
        vm.setEnv("HYDROPUMP_OPERATOR", vm.toString(operator));
        uint64 nonce = vm.getNonce(deployer);
        new DeployRotator().run();
        rotator = HydropumpRotator(vm.computeCreateAddress(deployer, nonce));
        assertGt(address(rotator).code.length, 0, "rotator deployed");
        assertEq(address(rotator.locker()), address(LOCKER));
        assertEq(rotator.owner(), safe);
        assertEq(rotator.operator(), operator);

        // 2. The Safe upgrades the locker.
        address implementation = address(new HydropumpLocker());
        vm.prank(safe);
        LOCKER.upgradeToAndCall(implementation, "");

        // 3. The Safe points it at the rotator, which fixes rotationStart.
        vm.prank(safe);
        LOCKER.setRotator(address(rotator));
        assertEq(LOCKER.rotator(), address(rotator));
        assertEq(LOCKER.rotationStart(), block.timestamp);
    }

    // ---------------------------------------------------------------- helpers

    function _account(string memory label) internal returns (address) {
        return makeAddr(string.concat(label, "-", vm.toString(++_accounts)));
    }

    function _pass(uint256 seconds_) internal {
        vm.roll(vm.getBlockNumber() + seconds_ / 2 + 1);
        vm.warp(vm.getBlockTimestamp() + seconds_);
    }

    /// @dev Quote raw units worth `usd`, priced off the directory: a launch opens at $5k on its start tick.
    function _usd(address quote, uint256 usd) internal view returns (uint256) {
        (, int24 startTick,) = DIRECTORY.quoteTokens(quote);
        uint256 sqrtPrice = TickMath.getSqrtRatioAtTick(startTick);
        uint256 openRaw = Math.mulDiv(Math.mulDiv(LAUNCHER.SUPPLY(), sqrtPrice, 1 << 96), sqrtPrice, 1 << 96);
        return openRaw * usd / 5_000;
    }

    function _launch(address quote, bytes32 feeUse, uint256 creatorBuyUsd) internal returns (address token) {
        address creator = _account("creator");
        uint256 fee = LAUNCHER.launchFee();
        vm.deal(creator, fee);
        uint256 buyAmount = creatorBuyUsd == 0 ? 0 : _usd(quote, creatorBuyUsd);
        if (buyAmount > 0) {
            deal(quote, creator, buyAmount);
            vm.prank(creator);
            IERC20(quote).approve(address(LAUNCHER), buyAmount);
        }
        vm.prank(creator);
        (token,,) = LAUNCHER.launch{value: fee}(
            HydropumpLauncher.LaunchParams({
                name: "Rehearsal",
                symbol: "RHRSL",
                quoteToken: quote,
                creatorRecipient: creator,
                buyAmount: buyAmount,
                feeUse: feeUse
            })
        );
        _pass(20); // past the launch tax
    }

    function _buy(address who, address quote, address token, uint256 usd) internal returns (uint256 out) {
        uint256 amount = _usd(quote, usd);
        deal(quote, who, IERC20(quote).balanceOf(who) + amount);
        vm.startPrank(who);
        IERC20(quote).approve(address(ROUTER), amount);
        out = ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: quote,
                tokenOut: token,
                deployer: address(0),
                recipient: who,
                deadline: block.timestamp,
                amountIn: amount,
                amountOutMinimum: 0,
                limitSqrtPrice: 0
            })
        );
        vm.stopPrank();
    }

    function _sell(address who, address token, address quote, uint256 amount) internal returns (uint256 out) {
        vm.startPrank(who);
        IERC20(token).approve(address(ROUTER), amount);
        out = ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: quote,
                deployer: address(0),
                recipient: who,
                deadline: block.timestamp,
                amountIn: amount,
                amountOutMinimum: 0,
                limitSqrtPrice: 0
            })
        );
        vm.stopPrank();
    }

    function _setTarget(address quote, address target) internal {
        address[] memory quotes = new address[](1);
        address[] memory targets = new address[](1);
        (quotes[0], targets[0]) = (quote, target);
        vm.prank(operator);
        rotator.setTargets(quotes, targets);
    }

    /// @dev A target grown well past its open, so one buy can take a dead pool: the 25% cap is about 3% of
    ///      its market cap on this curve.
    function _target(address quote) internal returns (address target) {
        target = _launch(quote, FeeUses.CREATOR_BALANCE, 500);
        for (uint256 i = 0; i < 6; i++) {
            _buy(_account("whale"), quote, target, 2_000);
        }
        _pass(2 hours); // let its average settle on the new price
        _setTarget(quote, target);
    }

    function _redeemAll(address who, address dead) internal returns (uint256 out) {
        uint256 held = IERC20(dead).balanceOf(who);
        if (held == 0) return 0;
        vm.startPrank(who);
        IERC20(dead).approve(address(rotator), held);
        out = rotator.redeem(dead, held);
        vm.stopPrank();
    }

    function _bandLiquidity(address token) internal view returns (uint128 total) {
        uint256[] memory ids = LOCKER.getPositions(token);
        for (uint256 i = 0; i < ids.length; i++) {
            (,,,,,,, uint128 liquidity,,,,) = NPM.positions(ids[i]);
            total += liquidity;
        }
    }

    function _revertSelector(address target, bytes memory call) internal returns (bytes4 selector) {
        (bool ok, bytes memory err) = target.call(call);
        assertFalse(ok, "expected a revert");
        assembly {
            selector := mload(add(err, 0x20))
        }
    }

    // ---------------------------------------------------------------- live launches

    /// @dev Launches `from` to `to` (exclusive) of the live roster, in registration order. Checked in
    ///      chunks so one dropped RPC connection costs a chunk, not the whole roster.
    function _liveLaunches(uint256 from, uint256 to) internal returns (LiveLaunch[] memory launches) {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = HydropumpLocker.LaunchRegistered.selector;
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(PROD_DEPLOY_BLOCK, FORK_BLOCK, address(LOCKER), topics);
        assertEq(logs.length, 413, "fixture: the live roster at the pinned block");
        if (to > logs.length) to = logs.length;

        launches = new LiveLaunch[](to - from);
        for (uint256 i = 0; i < launches.length; i++) {
            address token = address(uint160(uint256(logs[from + i].topics[1])));
            HydropumpLocker.Launch memory launch = LOCKER.getLaunch(token);
            (uint128 feesToken, uint128 feesQuote) = LOCKER.lifetimeFees(token);

            uint128[] memory liquidity = new uint128[](launch.positionIds.length);
            for (uint256 j = 0; j < liquidity.length; j++) {
                (,,,,,,, liquidity[j],,,,) = NPM.positions(launch.positionIds[j]);
            }
            launches[i] = LiveLaunch({
                token: token,
                record: abi.encode(launch),
                feesToken: feesToken,
                feesQuote: feesQuote,
                owedToken: LOCKER.creatorOwed(token, token),
                owedQuote: LOCKER.creatorOwed(token, launch.quoteToken),
                liquidity: liquidity
            });
        }
    }

    /// Every launch the locker held before the upgrade: same record, same fee books, same liquidity, never
    /// releasable, and still paying fees. In five chunks that together cover all 413.
    function test_LiveLaunches000To099StayLocked() public onlyForked {
        _checkLiveLaunches(0, 100);
    }

    function test_LiveLaunches100To199StayLocked() public onlyForked {
        _checkLiveLaunches(100, 200);
    }

    function test_LiveLaunches200To299StayLocked() public onlyForked {
        _checkLiveLaunches(200, 300);
    }

    function test_LiveLaunches300To399StayLocked() public onlyForked {
        _checkLiveLaunches(300, 400);
    }

    function test_LiveLaunches400To412StayLocked() public onlyForked {
        _checkLiveLaunches(400, 413);
    }

    function _checkLiveLaunches(uint256 from, uint256 to) internal {
        LiveLaunch[] memory launches = _liveLaunches(from, to);
        console2.log("live launches checked", launches.length);

        address launcherBefore = LOCKER.launcher();
        address registryBefore = LOCKER.feeUseRegistry();
        address recipientBefore = LOCKER.protocolFeeRecipient();
        (uint64 creatorFee, uint64 protocolFee) = (LOCKER.creatorFee(), LOCKER.protocolFee());
        uint256[3] memory protocolOwed =
            [LOCKER.protocolOwed(WETH), LOCKER.protocolOwed(USDC), LOCKER.protocolOwed(HYDX)];

        _rollout();

        assertEq(LOCKER.launcher(), launcherBefore);
        assertEq(LOCKER.feeUseRegistry(), registryBefore);
        assertEq(LOCKER.protocolFeeRecipient(), recipientBefore);
        assertEq(LOCKER.creatorFee(), creatorFee);
        assertEq(LOCKER.protocolFee(), protocolFee);
        assertEq(LOCKER.protocolOwed(WETH), protocolOwed[0]);
        assertEq(LOCKER.protocolOwed(USDC), protocolOwed[1]);
        assertEq(LOCKER.protocolOwed(HYDX), protocolOwed[2]);

        // A year on, so age is never the reason.
        _pass(365 days);
        uint256 b20Quoted;

        for (uint256 i = 0; i < launches.length; i++) {
            LiveLaunch memory live = launches[i];
            address token = live.token;

            assertEq(abi.encode(LOCKER.getLaunch(token)), live.record, "launch record");
            (uint128 feesToken, uint128 feesQuote) = LOCKER.lifetimeFees(token);
            assertEq(feesToken, live.feesToken, "lifetime fees");
            assertEq(feesQuote, live.feesQuote, "lifetime fees");
            HydropumpLocker.Launch memory launch = LOCKER.getLaunch(token);
            assertEq(LOCKER.creatorOwed(token, token), live.owedToken, "creator owed");
            assertEq(LOCKER.creatorOwed(token, launch.quoteToken), live.owedQuote, "creator owed");

            assertEq(
                _revertSelector(address(rotator), abi.encodeCall(HydropumpRotator.checkRotatable, (token))),
                HydropumpRotator.PredatesRotation.selector,
                "rotator refuses it"
            );
            vm.prank(address(rotator));
            assertEq(
                _revertSelector(address(LOCKER), abi.encodeCall(HydropumpLocker.releaseLiquidity, (token))),
                HydropumpLocker.NotRotatable.selector,
                "locker refuses it"
            );

            // A B20 equity quote is a Base precompile the fork cannot execute, so its pool cannot be touched
            // here (see LaunchB20.fork.t.sol). Everything above still ran for it.
            if (launch.quoteToken.code.length > 1) LOCKER.splitRewards(token);
            else b20Quoted++;
            for (uint256 j = 0; j < live.liquidity.length; j++) {
                (,,,,,,, uint128 liquidity,,,,) = NPM.positions(launch.positionIds[j]);
                assertEq(liquidity, live.liquidity[j], "band liquidity");
            }
        }
        console2.log("of which B20-quoted, fee split not simulated", b20Quoted);
    }

    // ---------------------------------------------------------------- lifecycle

    /// One dead launch, start to finish, on WETH: launch with a creator buy, three holders trading, fees
    /// handled, a week of nothing, rotation by a stranger, every holder redeeming, and the launcher, the
    /// target and the dead launch's fee calls all still working afterwards.
    function test_FullLifecycleOnWeth() public onlyForked {
        _rollout();
        address target = _target(WETH);

        address dead = _launch(WETH, FeeUses.CREATOR_BALANCE, 100);
        address creator = LOCKER.creatorRecipient(dead);
        address[3] memory holders = [_account("holder"), _account("holder"), _account("holder")];
        _buy(holders[0], WETH, dead, 200);
        _buy(holders[1], WETH, dead, 600);
        uint256 bought = _buy(holders[2], WETH, dead, 400);
        _sell(holders[2], dead, WETH, bought / 3);
        LOCKER.handleAllRewards(dead);
        _buy(holders[0], WETH, dead, 50); // fees still to split at rotation

        // Not yet: a week has not passed.
        assertEq(
            _revertSelector(address(rotator), abi.encodeCall(HydropumpRotator.rotate, (dead))),
            HydropumpRotator.TooYoung.selector
        );

        _pass(7 days);
        assertTrue(rotator.isRotatable(dead), "a week old and under $20k");

        address pool = LOCKER.poolOf(dead);
        uint256 creatorWethBefore = IERC20(WETH).balanceOf(creator);
        uint256 poolWeth = IERC20(WETH).balanceOf(pool);
        int24 targetSpotBefore = _spot(target);

        vm.prank(_account("stranger"));
        (uint256 quoteSpent, uint256 targetBought) = rotator.rotate(dead);

        assertEq(_bandLiquidity(dead), 0, "every band emptied");
        assertGt(IERC20(WETH).balanceOf(creator), creatorWethBefore, "creator's booked fees paid out");
        assertGt(quoteSpent, poolWeth * 99 / 100, "the pool's quote, spent");
        assertEq(IERC20(WETH).balanceOf(address(rotator)), 0, "in one buy");
        assertEq(IERC20(target).balanceOf(address(rotator)), targetBought);
        console2.log("rotation: WETH spent", quoteSpent);
        console2.log("target ticks moved by the one buy", _ticksMoved(target, targetSpotBefore));

        // Every holder, and the creator for their fee tokens, redeems; the order makes no difference.
        uint256 supply = IERC20(dead).totalSupply();
        uint256 paid;
        for (uint256 i = 0; i < 3; i++) {
            uint256 share = IERC20(dead).balanceOf(holders[i]);
            uint256 out = _redeemAll(holders[i], dead);
            assertApproxEqAbs(out, targetBought * share / supply, 2, "pro rata");
            paid += out;
        }
        paid += _redeemAll(creator, dead);
        // What nobody can redeem is the pool's leftover: Algebra's community fee on sells, taken in the
        // launch token and kept outside every band. Its share of the target stays in the rotator.
        uint256 unredeemable = IERC20(dead).totalSupply();
        assertEq(unredeemable, IERC20(dead).balanceOf(pool), "only the pool's community-fee leftover is out");
        assertLt(unredeemable * 10_000 / supply, 1, "under 0.01% of the supply");
        assertApproxEqAbs(
            IERC20(target).balanceOf(address(rotator)), targetBought * unredeemable / supply, 10, "its share stays"
        );
        assertApproxEqAbs(paid + IERC20(target).balanceOf(address(rotator)), targetBought, 10, "the rest paid out");

        // Afterwards: the target trades, the dead launch's fee calls are harmless, and the launcher launches.
        _sell(holders[0], target, WETH, IERC20(target).balanceOf(holders[0]));
        LOCKER.handleAllRewards(dead);
        _launch(WETH, FeeUses.CREATOR_BALANCE, 0);
    }

    /// Each of the three fee uses, with fees spent before rotation (auto-LP compounds into a band, buyback
    /// burns), rotates cleanly into one shared target with separate ledgers.
    function test_EveryFeeUseRotatesIntoOneTarget() public onlyForked {
        _rollout();
        address target = _target(WETH);

        bytes32[3] memory uses = [FeeUses.CREATOR_BALANCE, FeeUses.AUTO_LP, FeeUses.BUYBACK_BURN];
        address[3] memory deads;
        address[3] memory holders;
        for (uint256 i = 0; i < 3; i++) {
            deads[i] = _launch(WETH, uses[i], 0);
            holders[i] = _account("holder");
            uint256 got = _buy(holders[i], WETH, deads[i], 300);
            _sell(holders[i], deads[i], WETH, got / 4);
            _buy(_account("trader"), WETH, deads[i], 100);
            LOCKER.handleAllRewards(deads[i]);
        }

        _pass(7 days);
        uint256 rotatorTarget;
        for (uint256 i = 0; i < 3; i++) {
            assertTrue(rotator.isRotatable(deads[i]));
            (, uint256 bought) = rotator.rotate(deads[i]);
            rotatorTarget += bought;
            (address storedTarget, uint256 held) = rotator.rotations(deads[i]);
            assertEq(storedTarget, target);
            assertEq(held, bought, "own ledger");
            assertEq(_bandLiquidity(deads[i]), 0);
            _pass(1 hours); // the target's average catches up between rotations
        }
        assertEq(IERC20(target).balanceOf(address(rotator)), rotatorTarget, "ledgers add up");

        for (uint256 i = 0; i < 3; i++) {
            assertGt(_redeemAll(holders[i], deads[i]), 0);
        }
    }

    /// The same on a 6-decimal quote and on HYDX.
    function test_RotatesOnUsdcAndHydx() public onlyForked {
        _rollout();
        address[2] memory quotes = [USDC, HYDX];
        for (uint256 q = 0; q < 2; q++) {
            address quote = quotes[q];
            address target = _target(quote);
            address dead = _launch(quote, FeeUses.CREATOR_BALANCE, 0);
            address holder = _account("holder");
            _buy(holder, quote, dead, 400);

            _pass(7 days);
            assertTrue(rotator.isRotatable(dead), "under $20k");
            (uint256 spent, uint256 bought) = rotator.rotate(dead);
            assertGt(spent, 0);
            assertEq(IERC20(quote).balanceOf(address(rotator)), 0, "one buy");

            uint256 out = _redeemAll(holder, dead);
            assertGt(out, 0);
            assertApproxEqAbs(out, bought, bought / 100, "the only holder takes nearly all of it");
            assertEq(IERC20(target).balanceOf(holder), out);
        }
    }

    // ---------------------------------------------------------------- refusals

    function test_RefusalsAgainstLiveState() public onlyForked {
        _rollout();
        address target = _target(WETH);

        // Pumped past $20k inside the last day.
        address pumped = _launch(WETH, FeeUses.CREATOR_BALANCE, 0);
        _pass(7 days);
        _buy(_account("pumper"), WETH, pumped, 4_000);
        _pass(2 hours);
        assertEq(
            _revertSelector(address(rotator), abi.encodeCall(HydropumpRotator.checkRotatable, (pumped))),
            HydropumpRotator.ValuationTooHigh.selector
        );

        // A target in its launch-tax window.
        address dead = _launch(WETH, FeeUses.CREATOR_BALANCE, 0);
        _buy(_account("holder"), WETH, dead, 200);
        _pass(7 days);
        address fresh = _launch(WETH, FeeUses.CREATOR_BALANCE, 0);
        vm.roll(vm.getBlockNumber() - 9); // back inside its 10-block window
        _setTarget(WETH, fresh);
        assertEq(
            _revertSelector(address(rotator), abi.encodeCall(HydropumpRotator.rotate, (dead))),
            HydropumpRotator.InvalidTarget.selector
        );
        vm.roll(vm.getBlockNumber() + 20);
        _setTarget(WETH, target);

        // No target for the quote.
        address usdcDead = _launch(USDC, FeeUses.CREATOR_BALANCE, 0);
        _pass(7 days);
        assertEq(
            _revertSelector(address(rotator), abi.encodeCall(HydropumpRotator.rotate, (usdcDead))),
            HydropumpRotator.NoTarget.selector
        );

        // A target on another quote, or set by anyone but the operator.
        address[] memory quotes = new address[](1);
        address[] memory targets = new address[](1);
        (quotes[0], targets[0]) = (USDC, target);
        vm.prank(operator);
        vm.expectRevert(HydropumpRotator.InvalidTarget.selector);
        rotator.setTargets(quotes, targets);
        (quotes[0], targets[0]) = (WETH, target);
        vm.prank(_account("stranger"));
        vm.expectRevert(HydropumpRotator.NotOperator.selector);
        rotator.setTargets(quotes, targets);

        // Only the rotator releases; only once.
        vm.prank(_account("stranger"));
        vm.expectRevert(HydropumpLocker.NotRotator.selector);
        LOCKER.releaseLiquidity(dead);
        rotator.rotate(dead);
        assertEq(
            _revertSelector(address(rotator), abi.encodeCall(HydropumpRotator.rotate, (dead))),
            HydropumpRotator.AlreadyRotated.selector
        );

        // Redeeming needs a rotation.
        vm.expectRevert(HydropumpRotator.NotRotated.selector);
        rotator.redeem(pumped, 1);
    }

    // ---------------------------------------------------------------- one-buy capacity

    /// A dead pool too big for a small target's 25% headroom reverts the whole rotation and leaves the
    /// launch untouched. Once the target has grown and its average settled, the same rotation goes through.
    function test_ARotationTooBigForTheTargetWaitsForItToGrow() public onlyForked {
        _rollout();
        address small = _launch(WETH, FeeUses.CREATOR_BALANCE, 100);
        _setTarget(WETH, small);

        address dead = _launch(WETH, FeeUses.CREATOR_BALANCE, 0);
        _buy(_account("holder"), WETH, dead, 1_500);
        _pass(7 days);
        assertTrue(rotator.isRotatable(dead));

        uint128 liquidityBefore = _bandLiquidity(dead);
        assertEq(
            _revertSelector(address(rotator), abi.encodeCall(HydropumpRotator.rotate, (dead))),
            HydropumpRotator.SlippageTooHigh.selector
        );
        assertEq(_bandLiquidity(dead), liquidityBefore, "nothing released");
        assertFalse(LOCKER.released(dead));

        for (uint256 i = 0; i < 8; i++) {
            _buy(_account("whale"), WETH, small, 2_000);
        }
        _pass(2 hours);
        (uint256 spent,) = rotator.rotate(dead);
        assertGt(spent, 0, "rotated once the target could take it");
    }

    // ---------------------------------------------------------------- price helpers

    function _spot(address token) internal view returns (int24 tick) {
        (, tick,,,,) = IAlgebraPool(LOCKER.poolOf(token)).globalState();
    }

    function _ticksMoved(address token, int24 before) internal view returns (int256) {
        int256 moved = int256(_spot(token)) - before;
        return moved < 0 ? -moved : moved;
    }
}
