// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {IHook} from "deepstate-contracts/interfaces/IHook.sol";
import {DeepstateV1} from "deepstate-contracts/DeepstateV1.sol";
import {DeepstateRewarder} from "../src/DeepstateRewarder.sol";
import {DeepstateToken} from "../src/DeepstateToken.sol";

contract RewardTestERC20 is ERC20 {
    string private _name;
    string private _symbol;

    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RevertingHook is IHook {
    function execute(bytes32, bytes32, address, uint160, uint32) external pure {
        revert("bad hook");
    }
}

contract CountingHook is IHook {
    uint256 public calls;
    address public lastToken;

    function execute(bytes32, bytes32, address token, uint160, uint32) external {
        calls++;
        lastToken = token;
    }
}

contract DeepstateRewarderTest is Test {
    uint32 internal constant MAX_ORDER_NONCE = type(uint32).max;
    uint128 internal constant INITIAL_SUPPLY = 100e18;
    uint64 internal constant FULL_POOL_SHARE = 1e18;
    bytes32 internal constant INVALID_POOL_ID = keccak256("invalid-pool");
    bytes32 internal constant EMPTY_BOOK_ID = keccak256("empty-book");

    DeepstateV1 internal engine;
    DeepstateRewarder internal rewarder;
    bytes32 internal configuredPoolId;
    RewardTestERC20 internal token0;
    RewardTestERC20 internal token1;
    RewardTestERC20 internal rewardToken;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        RewardTestERC20 a = new RewardTestERC20("A", "A");
        RewardTestERC20 b = new RewardTestERC20("B", "B");
        if (address(a) < address(b)) {
            token0 = a;
            token1 = b;
        } else {
            token0 = b;
            token1 = a;
        }

        engine = new DeepstateV1();
        rewardToken = new RewardTestERC20("Reward", "RWD");
        configuredPoolId = engine.poolId(address(token0), address(token1));
        rewarder = _deployRewarder(uint64(block.timestamp), INITIAL_SUPPLY, INITIAL_SUPPLY, FULL_POOL_SHARE);
        engine.setPoolHookConfig(address(token0), address(token1), address(rewarder), true, true);

        _fundAndApprove(alice);
        _fundAndApprove(bob);
    }

    function test_ImmutableConfiguration() public view {
        assertEq(rewarder.owner(), address(this));
        assertEq(rewarder.engine(), address(engine));
        assertEq(rewarder.rewardToken(), address(rewardToken));
        assertEq(rewarder.poolId(), engine.poolId(address(token0), address(token1)));
        assertEq(rewarder.token0(), address(token0));
        assertEq(rewarder.token1(), address(token1));
        assertEq(rewarder.emissionStart(), block.timestamp);
        assertEq(rewarder.initialSupply(), INITIAL_SUPPLY);
        assertEq(rewarder.bootstrapEmissions(), INITIAL_SUPPLY);
        assertEq(rewarder.poolEmissionShareWad(), FULL_POOL_SHARE);
    }

    function test_ConstructorValidation() public {
        bytes32 pid = configuredPoolId;

        vm.expectRevert(DeepstateRewarder.InvalidEngine.selector);
        new DeepstateRewarder(
            address(this),
            address(0),
            address(rewardToken),
            pid,
            address(token0),
            address(token1),
            uint64(block.timestamp),
            INITIAL_SUPPLY,
            INITIAL_SUPPLY,
            FULL_POOL_SHARE
        );

        vm.expectRevert(DeepstateRewarder.InvalidRewardToken.selector);
        new DeepstateRewarder(
            address(this),
            address(engine),
            address(0),
            pid,
            address(token0),
            address(token1),
            uint64(block.timestamp),
            INITIAL_SUPPLY,
            INITIAL_SUPPLY,
            FULL_POOL_SHARE
        );

        vm.expectRevert(DeepstateRewarder.InvalidPool.selector);
        new DeepstateRewarder(
            address(this),
            address(engine),
            address(rewardToken),
            bytes32(0),
            address(token0),
            address(token1),
            uint64(block.timestamp),
            INITIAL_SUPPLY,
            INITIAL_SUPPLY,
            FULL_POOL_SHARE
        );

        vm.expectRevert(DeepstateRewarder.InvalidPool.selector);
        new DeepstateRewarder(
            address(this),
            address(engine),
            address(rewardToken),
            INVALID_POOL_ID,
            address(token0),
            address(token1),
            uint64(block.timestamp),
            INITIAL_SUPPLY,
            INITIAL_SUPPLY,
            FULL_POOL_SHARE
        );

        vm.expectRevert(DeepstateRewarder.InvalidPool.selector);
        new DeepstateRewarder(
            address(this),
            address(engine),
            address(rewardToken),
            INVALID_POOL_ID,
            address(0),
            address(token1),
            uint64(block.timestamp),
            INITIAL_SUPPLY,
            INITIAL_SUPPLY,
            FULL_POOL_SHARE
        );

        vm.expectRevert(DeepstateRewarder.InvalidPool.selector);
        new DeepstateRewarder(
            address(this),
            address(engine),
            address(rewardToken),
            pid,
            address(token1),
            address(token0),
            uint64(block.timestamp),
            INITIAL_SUPPLY,
            INITIAL_SUPPLY,
            FULL_POOL_SHARE
        );

        vm.expectRevert(DeepstateRewarder.InvalidPoolShare.selector);
        _deployRewarder(uint64(block.timestamp), INITIAL_SUPPLY, INITIAL_SUPPLY, 0);

        vm.expectRevert(DeepstateRewarder.InvalidPoolShare.selector);
        _deployRewarder(uint64(block.timestamp), INITIAL_SUPPLY, INITIAL_SUPPLY, uint64(1e18 + 1));

        vm.expectRevert(DeepstateRewarder.InvalidEmissionSchedule.selector);
        _deployRewarder(0, INITIAL_SUPPLY, INITIAL_SUPPLY, FULL_POOL_SHARE);

        vm.expectRevert(DeepstateRewarder.InvalidEmissionSchedule.selector);
        _deployRewarder(uint64(block.timestamp), 0, 0, FULL_POOL_SHARE);

        vm.expectRevert(DeepstateRewarder.InvalidEmissionSchedule.selector);
        _deployRewarder(uint64(block.timestamp), INITIAL_SUPPLY, INITIAL_SUPPLY - 1, FULL_POOL_SHARE);
    }

    function test_EmissionScheduleHitsMilestonesAndSmoothsBoundary() public view {
        uint256 start = rewarder.emissionStart();

        assertEq(rewarder.cumulativeSupplyAt(start), INITIAL_SUPPLY);
        assertEq(rewarder.cumulativeSupplyAt(start + 30 days), INITIAL_SUPPLY * 2);
        assertApproxEqAbs(rewarder.cumulativeSupplyAt(start + 395 days), INITIAL_SUPPLY * 4, 1e6);

        uint256 beforeBoundary = rewarder.emissionsBetween(start + 30 days - 1, start + 30 days);
        uint256 afterBoundary = rewarder.emissionsBetween(start + 30 days, start + 30 days + 1);
        assertApproxEqRel(beforeBoundary, afterBoundary, 1e12);
    }

    function test_EmissionScheduleIsZeroBeforeStartAndForReversedIntervals() public view {
        uint256 start = rewarder.emissionStart();
        assertEq(rewarder.cumulativeEmissionsAt(start - 1), 0);
        assertEq(rewarder.emissionsBetween(start + 10, start + 10), 0);
        assertEq(rewarder.emissionsBetween(start + 11, start + 10), 0);
    }

    function test_EmissionScheduleCapsWithoutRevertingAfterOneHundredYears() public view {
        uint256 start = rewarder.emissionStart();
        uint256 capTime = start + rewarder.MAX_SCHEDULE_ELAPSED();
        uint256 cappedSupply = rewarder.cumulativeSupplyAt(capTime);

        assertGt(cappedSupply, INITIAL_SUPPLY);
        assertEq(rewarder.cumulativeSupplyAt(capTime + 1), cappedSupply);
        assertEq(rewarder.cumulativeSupplyAt(type(uint256).max), cappedSupply);
        assertEq(rewarder.emissionsBetween(capTime, type(uint256).max), 0);
    }

    function testFuzz_EmissionAccountingIsMonotonicAndAdditive(uint64 firstOffset, uint64 secondOffset) public view {
        uint256 range = rewarder.MAX_SCHEDULE_ELAPSED() + 365 days;
        uint256 first = uint256(firstOffset) % range;
        uint256 second = uint256(secondOffset) % range;
        if (first > second) (first, second) = (second, first);

        uint256 start = rewarder.emissionStart();
        uint256 firstCumulative = rewarder.cumulativeEmissionsAt(start + first);
        uint256 secondCumulative = rewarder.cumulativeEmissionsAt(start + second);
        assertLe(firstCumulative, secondCumulative);
        assertEq(rewarder.emissionsBetween(start + first, start + second), secondCumulative - firstCumulative);
    }

    function test_PoolAllocationAndSidesHardCapSchedule() public {
        DeepstateRewarder partialRewarder =
            _deployRewarder(uint64(block.timestamp), INITIAL_SUPPLY, INITIAL_SUPPLY, uint64(600_000_000_000_000_000));
        uint256 start = block.timestamp + 1 days;
        uint256 end = start + 1 hours;
        uint256 poolBudget = partialRewarder.emissionsBetween(start, end) * 60 / 100;

        uint256 token0Budget = partialRewarder.previewReward(address(token0), start, end);
        uint256 token1Budget = partialRewarder.previewReward(address(token1), start, end);
        assertApproxEqAbs(token0Budget + token1Budget, poolBudget, 1);
        assertEq(token0Budget, token1Budget);

        vm.expectRevert(DeepstateRewarder.InvalidHookToken.selector);
        partialRewarder.previewReward(address(rewardToken), start, end);
    }

    function test_QuantityControllerHasPinnedBoundedResponse() public view {
        assertEq(rewarder.quantityMultiplierWad(0, 100), 0);
        assertEq(rewarder.quantityMultiplierWad(100, 0), 1e18);
        assertEq(rewarder.quantityMultiplierWad(100, 100), 0.5e18);
        assertEq(rewarder.quantityMultiplierWad(200, 100), 0.8e18);
        assertEq(rewarder.quantityMultiplierWad(300, 100), 0.9e18);
        assertEq(rewarder.quantityMultiplierWad(50, 100), 0.2e18);
        assertLt(rewarder.quantityMultiplierWad(type(uint160).max, 1), 1e18 + 1);
    }

    function testFuzz_QuantityControllerNeverExceedsSchedule(uint160 amount, uint160 benchmark) public view {
        uint256 multiplier = rewarder.quantityMultiplierWad(amount, benchmark);
        assertLe(multiplier, 1e18);

        uint256 start = block.timestamp;
        uint256 end = start + 1 days;
        assertLe(
            rewarder.previewAdjustedReward(address(token0), start, end, amount, benchmark),
            rewarder.previewReward(address(token0), start, end)
        );
    }

    function testFuzz_QuantityControllerIsMonotonic(uint160 firstAmount, uint160 secondAmount, uint160 benchmark)
        public
        view
    {
        if (firstAmount > secondAmount) (firstAmount, secondAmount) = (secondAmount, firstAmount);
        assertLe(
            rewarder.quantityMultiplierWad(firstAmount, benchmark),
            rewarder.quantityMultiplierWad(secondAmount, benchmark)
        );
    }

    function test_QuantityControllerIsInvariantToTokenDecimalScale() public view {
        uint256 sixDecimalFactor = rewarder.quantityMultiplierWad(2_000_000, 1_000_000);
        uint256 eighteenDecimalFactor = rewarder.quantityMultiplierWad(2e18, 1e18);
        assertEq(sixDecimalFactor, eighteenDecimalFactor);
        assertEq(sixDecimalFactor, 0.8e18);
    }

    function test_RewardeeViewsSupportBothSidesAndRejectUnknownToken() public {
        (uint32 nonce, uint64 startedAt) = rewarder.rewardees(address(token1));
        assertEq(nonce, 0);
        assertEq(startedAt, 0);
        assertEq(rewarder.referenceAmount(address(token1)), 0);

        vm.expectRevert(DeepstateRewarder.InvalidHookToken.selector);
        rewarder.rewardees(address(rewardToken));
        vm.expectRevert(DeepstateRewarder.InvalidHookToken.selector);
        rewarder.referenceAmount(address(rewardToken));
    }

    function test_FirstRewardeeGetsFullSideBudgetThenConsistentQuantityGetsHalf() public {
        bytes32 pid = rewarder.poolId();
        bytes32 id = engine.bookId(address(token0), address(token1), 0);

        vm.prank(address(engine));
        rewarder.execute(pid, id, address(token0), 0, 2);
        (, uint64 firstStartedAt) = rewarder.rewardees(address(token0));
        vm.warp(vm.getBlockTimestamp() + 1 hours);

        uint256 firstBudget = rewarder.previewReward(address(token0), firstStartedAt, vm.getBlockTimestamp());
        vm.prank(address(engine));
        rewarder.execute(pid, id, address(token0), 100, 3);
        assertEq(rewarder.balances(id, address(token0), 2), firstBudget);
        assertEq(rewarder.referenceAmount(address(token0)), 100);

        (, uint64 secondStartedAt) = rewarder.rewardees(address(token0));
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        uint256 secondBudget = rewarder.previewReward(address(token0), secondStartedAt, vm.getBlockTimestamp());
        vm.prank(address(engine));
        rewarder.execute(pid, id, address(token0), 100, 4);

        assertEq(rewarder.balances(id, address(token0), 3), secondBudget / 2);
        assertEq(rewarder.referenceAmount(address(token0)), 100);
    }

    function test_ReferenceUsesTimeWeightedEmaAndSurvivesEmptySide() public {
        bytes32 pid = rewarder.poolId();

        vm.prank(address(engine));
        rewarder.execute(pid, EMPTY_BOOK_ID, address(token0), 0, 1);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(address(engine));
        rewarder.execute(pid, EMPTY_BOOK_ID, address(token0), 100e18, 2);
        assertEq(rewarder.referenceAmount(address(token0)), 100e18);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(address(engine));
        rewarder.execute(pid, EMPTY_BOOK_ID, address(token0), 170e18, 0);
        (uint32 nonce, uint64 startedAt) = rewarder.rewardees(address(token0));
        assertEq(nonce, 0);
        assertEq(startedAt, 0);
        assertEq(rewarder.referenceAmount(address(token0)), 110e18);

        vm.prank(address(engine));
        rewarder.execute(pid, EMPTY_BOOK_ID, address(token0), 0, 2);
        assertEq(rewarder.referenceAmount(address(token0)), 110e18);
    }

    function test_ReferenceMovesDownByElapsedTimeAndCapsAtFullWindow() public {
        bytes32 pid = rewarder.poolId();

        vm.prank(address(engine));
        rewarder.execute(pid, EMPTY_BOOK_ID, address(token0), 0, 1);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(address(engine));
        rewarder.execute(pid, EMPTY_BOOK_ID, address(token0), 100e18, 2);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(address(engine));
        rewarder.execute(pid, EMPTY_BOOK_ID, address(token0), 30e18, 3);
        assertEq(rewarder.referenceAmount(address(token0)), 90e18);

        vm.warp(vm.getBlockTimestamp() + rewarder.REFERENCE_WINDOW());
        vm.prank(address(engine));
        rewarder.execute(pid, EMPTY_BOOK_ID, address(token0), 40e18, 4);
        assertEq(rewarder.referenceAmount(address(token0)), 40e18);
    }

    function test_RewarderAccruesWhenTopBidIsDisplacedAndDistributes() public {
        bytes32 id = engine.bookId(address(token0), address(token1), 0);

        vm.prank(alice);
        bytes32 aliceBid = engine.fill(_fill(0, _order(10, 5, 0), true, false, false));
        (uint32 firstNonce, uint64 firstStartedAt) = rewarder.rewardees(address(token0));
        assertEq(firstNonce, MAX_ORDER_NONCE);

        vm.warp(vm.getBlockTimestamp() + 11);
        uint256 expectedReward = rewarder.previewReward(address(token0), firstStartedAt, vm.getBlockTimestamp());
        vm.prank(bob);
        engine.fill(_fill(0, _order(11, 7, 0), true, false, false));

        assertEq(rewarder.balances(id, address(token0), MAX_ORDER_NONCE), expectedReward);
        assertEq(rewarder.referenceAmount(address(token0)), 5);

        rewarder.distributeRewards(id, aliceBid, address(token0));
        assertEq(rewardToken.balanceOf(alice), expectedReward);
        assertEq(rewarder.balances(id, address(token0), MAX_ORDER_NONCE), 0);
    }

    function test_RevokedMinterRoleFreezesClaimsWithoutLosingAccrual() public {
        DeepstateToken deep = new DeepstateToken(address(this), "Deepstate", "DEEP");
        DeepstateRewarder roleRewarder = new DeepstateRewarder(
            address(this),
            address(engine),
            address(deep),
            configuredPoolId,
            address(token0),
            address(token1),
            uint64(block.timestamp),
            INITIAL_SUPPLY,
            INITIAL_SUPPLY,
            FULL_POOL_SHARE
        );
        bytes32 minterRole = deep.MINTER_ROLE();
        deep.grantRole(minterRole, address(roleRewarder));
        engine.setPoolHookConfig(address(token0), address(token1), address(roleRewarder), true, true);

        bytes32 id = engine.bookId(address(token0), address(token1), 0);
        vm.prank(alice);
        bytes32 aliceBid = engine.fill(_fill(0, _order(10, 5, 0), true, false, false));
        vm.warp(vm.getBlockTimestamp() + 11);
        vm.prank(bob);
        engine.fill(_fill(0, _order(11, 7, 0), true, false, false));

        uint256 amount = roleRewarder.balances(id, address(token0), MAX_ORDER_NONCE);
        deep.revokeRole(minterRole, address(roleRewarder));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(roleRewarder), minterRole
            )
        );
        roleRewarder.distributeRewards(id, aliceBid, address(token0));
        assertEq(roleRewarder.balances(id, address(token0), MAX_ORDER_NONCE), amount);
        assertEq(deep.balanceOf(alice), 0);

        deep.grantRole(minterRole, address(roleRewarder));
        roleRewarder.distributeRewards(id, aliceBid, address(token0));
        assertEq(roleRewarder.balances(id, address(token0), MAX_ORDER_NONCE), 0);
        assertEq(deep.balanceOf(alice), amount);
    }

    function test_RewarderAccruesBothSidesWithinCombinedPoolBudget() public {
        bytes32 id = engine.bookId(address(token0), address(token1), 0);

        vm.prank(alice);
        engine.fill(_fill(0, _order(10, 5, 0), true, false, false));
        vm.prank(alice);
        engine.fill(_fill(0, _order(20, 8, 0), false, false, false));
        (, uint64 startedAt) = rewarder.rewardees(address(token0));

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(bob);
        engine.fill(_fill(0, _order(11, 7, 0), true, false, false));
        vm.prank(bob);
        engine.fill(_fill(0, _order(19, 9, 0), false, false, false));

        uint256 bidReward = rewarder.balances(id, address(token0), MAX_ORDER_NONCE);
        uint256 askReward = rewarder.balances(id, address(token1), MAX_ORDER_NONCE - 1);
        uint256 currentTime = vm.getBlockTimestamp();
        assertEq(bidReward, rewarder.previewReward(address(token0), startedAt, currentTime));
        assertEq(askReward, rewarder.previewReward(address(token1), startedAt, currentTime));
        assertLe(bidReward + askReward, rewarder.emissionsBetween(startedAt, currentTime));
    }

    function test_RewarderAccruesAdjustedAmountAfterPartialFill() public {
        bytes32 id = engine.bookId(address(token0), address(token1), 0);

        vm.prank(alice);
        engine.fill(_fill(0, _order(10, 5, 0), true, false, false));
        vm.warp(vm.getBlockTimestamp() + 7);

        uint256 firstStart = vm.getBlockTimestamp() - 7;
        vm.prank(bob);
        engine.fill(_fill(0, _order(10, 2, 0), false, true, false));
        uint256 expected = rewarder.previewReward(address(token0), firstStart, vm.getBlockTimestamp());

        vm.warp(vm.getBlockTimestamp() + 3);
        uint256 secondStart = vm.getBlockTimestamp() - 3;
        uint256 secondReward =
            rewarder.previewAdjustedReward(address(token0), secondStart, vm.getBlockTimestamp(), 3, 5);
        vm.prank(bob);
        engine.fill(_fill(0, _order(10, 1, 0), false, true, false));

        assertEq(rewarder.balances(id, address(token0), MAX_ORDER_NONCE), expected + secondReward);
    }

    function test_TopBidFillAndCancelTransitionsAccrue() public {
        bytes32 id = engine.bookId(address(token0), address(token1), 0);

        vm.prank(alice);
        bytes32 aliceBid = engine.fill(_fill(0, _order(10, 5, 0), true, false, false));
        vm.prank(bob);
        engine.fill(_fill(0, _order(9, 7, 0), true, false, false));
        (, uint64 startedAt) = rewarder.rewardees(address(token0));

        vm.warp(vm.getBlockTimestamp() + 13);
        vm.prank(alice);
        engine.cancel(address(token0), address(token1), 0, aliceBid);

        assertEq(
            rewarder.balances(id, address(token0), MAX_ORDER_NONCE),
            rewarder.previewReward(address(token0), startedAt, vm.getBlockTimestamp())
        );
        (uint32 nextNonce,) = rewarder.rewardees(address(token0));
        assertEq(nextNonce, MAX_ORDER_NONCE - 1);
    }

    function test_DistributeRewardsRequiresOrderToStillExist() public {
        bytes32 id = engine.bookId(address(token0), address(token1), 0);

        vm.prank(alice);
        bytes32 aliceBid = engine.fill(_fill(0, _order(10, 5, 0), true, false, false));
        vm.warp(vm.getBlockTimestamp() + 11);
        vm.prank(bob);
        engine.fill(_fill(0, _order(11, 7, 0), true, false, false));

        vm.prank(alice);
        engine.cancel(address(token0), address(token1), 0, aliceBid);

        vm.expectRevert(DeepstateRewarder.NoOrderOwner.selector);
        rewarder.distributeRewards(id, aliceBid, address(token0));
    }

    function test_ExecuteValidationAndZeroBalanceClaim() public {
        bytes32 validPoolId = rewarder.poolId();

        vm.expectRevert(DeepstateRewarder.NotEngine.selector);
        rewarder.execute(INVALID_POOL_ID, EMPTY_BOOK_ID, address(token0), 1, MAX_ORDER_NONCE);

        vm.expectRevert(DeepstateRewarder.InvalidPool.selector);
        vm.prank(address(engine));
        rewarder.execute(INVALID_POOL_ID, EMPTY_BOOK_ID, address(token0), 1, MAX_ORDER_NONCE);

        vm.expectRevert(DeepstateRewarder.InvalidHookToken.selector);
        vm.prank(address(engine));
        rewarder.execute(validPoolId, EMPTY_BOOK_ID, address(rewardToken), 1, MAX_ORDER_NONCE);

        rewarder.distributeRewards(EMPTY_BOOK_ID, _order(10, 1, MAX_ORDER_NONCE), address(token0));
        assertEq(rewardToken.balanceOf(alice), 0);
    }

    function test_ExecuteStaysInsideRouterGasBudgetForFreshAndWarmAccrual() public {
        bytes32 pid = rewarder.poolId();
        bytes32 id = engine.bookId(address(token0), address(token1), 0);

        uint256 beforeGas = gasleft();
        vm.prank(address(engine));
        rewarder.execute(pid, id, address(token0), 0, 1);
        uint256 firstCursorGas = beforeGas - gasleft();

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        beforeGas = gasleft();
        vm.prank(address(engine));
        rewarder.execute(pid, id, address(token0), 100, 1);
        uint256 freshAccrualGas = beforeGas - gasleft();

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        beforeGas = gasleft();
        vm.prank(address(engine));
        rewarder.execute(pid, id, address(token0), 100, 1);
        uint256 warmAccrualGas = beforeGas - gasleft();

        emit log_named_uint("execute first cursor gas", firstCursorGas);
        emit log_named_uint("execute fresh accrual gas", freshAccrualGas);
        emit log_named_uint("execute warm accrual gas", warmAccrualGas);
        assertLt(firstCursorGas, 200_000);
        assertLt(freshAccrualGas, 200_000);
        assertLt(warmAccrualGas, 200_000);
        assertLt(warmAccrualGas, freshAccrualGas);
    }

    function test_ExecuteBeyondScheduleHorizonDoesNotRevertOrExceedCap() public {
        bytes32 pid = rewarder.poolId();
        vm.prank(address(engine));
        rewarder.execute(pid, EMPTY_BOOK_ID, address(token0), 0, 1);
        (, uint64 startedAt) = rewarder.rewardees(address(token0));

        vm.warp(vm.getBlockTimestamp() + rewarder.MAX_SCHEDULE_ELAPSED() + 365 days);
        uint256 cap = rewarder.previewReward(address(token0), startedAt, vm.getBlockTimestamp());
        uint256 beforeGas = gasleft();
        vm.prank(address(engine));
        rewarder.execute(pid, EMPTY_BOOK_ID, address(token0), type(uint160).max, 2);
        uint256 horizonAccrualGas = beforeGas - gasleft();

        assertEq(rewarder.balances(EMPTY_BOOK_ID, address(token0), 1), cap);
        emit log_named_uint("execute horizon accrual gas", horizonAccrualGas);
        assertLt(horizonAccrualGas, 200_000);
    }

    function test_ExecuteAtSameTimestampAndBeforeEmissionStartAccruesNoReward() public {
        DeepstateRewarder futureRewarder =
            _deployRewarder(uint64(block.timestamp + 1 days), INITIAL_SUPPLY, INITIAL_SUPPLY, FULL_POOL_SHARE);
        bytes32 pid = futureRewarder.poolId();

        vm.prank(address(engine));
        futureRewarder.execute(pid, EMPTY_BOOK_ID, address(token0), 0, 1);
        vm.prank(address(engine));
        futureRewarder.execute(pid, EMPTY_BOOK_ID, address(token0), 100, 1);
        assertEq(futureRewarder.balances(EMPTY_BOOK_ID, address(token0), 1), 0);
        assertEq(futureRewarder.referenceAmount(address(token0)), 0);

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(address(engine));
        futureRewarder.execute(pid, EMPTY_BOOK_ID, address(token0), 100, 2);
        assertEq(futureRewarder.balances(EMPTY_BOOK_ID, address(token0), 1), 0);
        assertEq(futureRewarder.referenceAmount(address(token0)), 100);
    }

    function test_RevertingRewardHookDoesNotBlockFill() public {
        engine.setPoolHookConfig(address(token0), address(token1), address(new RevertingHook()), true, false);

        vm.prank(alice);
        bytes32 resting = engine.fill(_fill(0, _order(10, 5, 0), true, false, false));

        bytes32 id = engine.bookId(address(token0), address(token1), 0);
        assertEq(engine.ownerOfOrder(engine.orderId(id, resting)), alice);
    }

    function test_InactiveSideCancelDoesNotCallHook() public {
        CountingHook hook = new CountingHook();
        engine.setPoolHookConfig(address(token0), address(token1), address(hook), true, false);

        vm.prank(alice);
        bytes32 ask = engine.fill(_fill(0, _order(10, 5, 0), false, false, false));
        vm.prank(alice);
        engine.cancel(address(token0), address(token1), 0, ask);

        assertEq(hook.calls(), 0);
        assertEq(hook.lastToken(), address(0));
    }

    function _deployRewarder(uint64 start, uint128 supply, uint128 bootstrap, uint64 poolShare)
        internal
        returns (DeepstateRewarder deployed)
    {
        deployed = new DeepstateRewarder(
            address(this),
            address(engine),
            address(rewardToken),
            configuredPoolId,
            address(token0),
            address(token1),
            start,
            supply,
            bootstrap,
            poolShare
        );
    }

    function _fill(uint256 epoch, bytes32 order, bool isBid, bool noRest, bool fillOrKill)
        internal
        view
        returns (DeepstateV1.FillParams memory params)
    {
        params = DeepstateV1.FillParams({
            token0: address(token0),
            token1: address(token1),
            epoch: epoch,
            order: order,
            isBid: isBid,
            noRest: noRest,
            fillOrKill: fillOrKill
        });
    }

    function _fundAndApprove(address user) internal {
        token0.mint(user, 1_000_000);
        token1.mint(user, 1_000_000);

        vm.startPrank(user);
        token0.approve(address(engine), type(uint256).max);
        token1.approve(address(engine), type(uint256).max);
        vm.stopPrank();
    }

    function _order(int32 price, uint160 quantity, uint32 nonce) internal pure returns (bytes32) {
        return bytes32((uint256(uint32(price)) << 224) | (uint256(quantity) << 64) | uint256(nonce));
    }
}
