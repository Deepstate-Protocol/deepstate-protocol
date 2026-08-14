// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {IHook} from "deepstate-contracts/interfaces/IHook.sol";
import {DeepstateV1} from "deepstate-contracts/DeepstateV1.sol";

import {DeepstateRewarder} from "../src/DeepstateRewarder.sol";
import {DeepstateToken} from "../src/DeepstateToken.sol";

contract RewardTestERC20 is ERC20 {
    string private _name;
    string private _symbol;
    uint256 public transferCalls;

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

    function transfer(address to, uint256 amount) public override returns (bool) {
        ++transferCalls;
        return super.transfer(to, amount);
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
    uint96 internal constant NVDA_SIDE_CAP = 500_000_000e18;
    uint32 internal constant NVDA_DURATION = 395 days;
    uint160 internal constant START_QUANTITY = 1e18;
    uint160 internal constant MAX_QUANTITY = 1_000_000e18;
    bytes32 internal constant INVALID_POOL_ID = keccak256("invalid-pool");
    bytes32 internal constant EMPTY_BOOK_ID = keccak256("empty-book");

    DeepstateV1 internal deepstate;
    DeepstateRewarder internal rewarder;
    bytes32 internal configuredPoolId;
    RewardTestERC20 internal token0;
    RewardTestERC20 internal token1;
    RewardTestERC20 internal rewardToken;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        vm.warp(1_000_000);

        RewardTestERC20 a = new RewardTestERC20("A", "A");
        RewardTestERC20 b = new RewardTestERC20("B", "B");
        if (address(a) < address(b)) {
            token0 = a;
            token1 = b;
        } else {
            token0 = b;
            token1 = a;
        }

        deepstate = new DeepstateV1();
        rewardToken = new RewardTestERC20("Reward", "RWD");
        configuredPoolId = deepstate.poolId(address(token0), address(token1));
        rewarder = _deployRewarder(
            address(rewardToken),
            NVDA_SIDE_CAP,
            NVDA_DURATION,
            START_QUANTITY,
            MAX_QUANTITY,
            START_QUANTITY,
            MAX_QUANTITY
        );
        rewardToken.mint(address(rewarder), uint256(NVDA_SIDE_CAP) * 2);
        deepstate.setPoolHookConfig(address(token0), address(token1), address(rewarder), true, true);

        _fundAndApprove(alice);
        _fundAndApprove(bob);
    }

    function test_ImmutableConfiguration() public view {
        assertEq(rewarder.owner(), address(this));
        assertEq(rewarder.deepstate(), address(deepstate));
        assertEq(rewarder.rewardToken(), address(rewardToken));
        assertEq(rewarder.poolId(), configuredPoolId);
        assertEq(rewarder.token0(), address(token0));
        assertEq(rewarder.token1(), address(token1));
        assertEq(rewarder.sideEmissionCap(), NVDA_SIDE_CAP);
        assertEq(rewarder.emissionDuration(), NVDA_DURATION);
        assertEq(rewarder.token0StartQuantity(), START_QUANTITY);
        assertEq(rewarder.token0MaxQuantity(), MAX_QUANTITY);
        assertEq(rewarder.token1StartQuantity(), START_QUANTITY);
        assertEq(rewarder.token1MaxQuantity(), MAX_QUANTITY);
        assertEq(rewardToken.balanceOf(address(rewarder)), uint256(NVDA_SIDE_CAP) * 2);
        assertGt(rewarder.emissionLogDenominatorWad(), 0);
        assertGt(rewarder.token0QuantityLogWad(), 0);
        assertGt(rewarder.token1QuantityLogWad(), 0);
    }

    function test_ConstructorValidation() public {
        vm.expectRevert(DeepstateRewarder.InvalidOwner.selector);
        _newRewarder(
            address(0),
            address(deepstate),
            address(rewardToken),
            configuredPoolId,
            address(token0),
            address(token1),
            NVDA_SIDE_CAP,
            NVDA_DURATION,
            START_QUANTITY,
            MAX_QUANTITY,
            START_QUANTITY,
            MAX_QUANTITY
        );

        vm.expectRevert(DeepstateRewarder.InvalidDeepstate.selector);
        _newRewarder(
            address(this),
            address(0),
            address(rewardToken),
            configuredPoolId,
            address(token0),
            address(token1),
            NVDA_SIDE_CAP,
            NVDA_DURATION,
            START_QUANTITY,
            MAX_QUANTITY,
            START_QUANTITY,
            MAX_QUANTITY
        );

        vm.expectRevert(DeepstateRewarder.InvalidRewardToken.selector);
        _newRewarder(
            address(this),
            address(deepstate),
            address(0),
            configuredPoolId,
            address(token0),
            address(token1),
            NVDA_SIDE_CAP,
            NVDA_DURATION,
            START_QUANTITY,
            MAX_QUANTITY,
            START_QUANTITY,
            MAX_QUANTITY
        );

        vm.expectRevert(DeepstateRewarder.InvalidPool.selector);
        _newRewarder(
            address(this),
            address(deepstate),
            address(rewardToken),
            INVALID_POOL_ID,
            address(token0),
            address(token1),
            NVDA_SIDE_CAP,
            NVDA_DURATION,
            START_QUANTITY,
            MAX_QUANTITY,
            START_QUANTITY,
            MAX_QUANTITY
        );

        vm.expectRevert(DeepstateRewarder.InvalidPool.selector);
        _newRewarder(
            address(this),
            address(deepstate),
            address(rewardToken),
            configuredPoolId,
            address(token1),
            address(token0),
            NVDA_SIDE_CAP,
            NVDA_DURATION,
            START_QUANTITY,
            MAX_QUANTITY,
            START_QUANTITY,
            MAX_QUANTITY
        );

        vm.expectRevert(DeepstateRewarder.InvalidEmissionSchedule.selector);
        _deployRewarder(
            address(rewardToken), 0, NVDA_DURATION, START_QUANTITY, MAX_QUANTITY, START_QUANTITY, MAX_QUANTITY
        );

        vm.expectRevert(DeepstateRewarder.InvalidEmissionSchedule.selector);
        _deployRewarder(
            address(rewardToken),
            NVDA_SIDE_CAP,
            uint32(30 days - 1),
            START_QUANTITY,
            MAX_QUANTITY,
            START_QUANTITY,
            MAX_QUANTITY
        );

        vm.expectRevert(DeepstateRewarder.InvalidQuantitySchedule.selector);
        _deployRewarder(
            address(rewardToken), NVDA_SIDE_CAP, NVDA_DURATION, 0, MAX_QUANTITY, START_QUANTITY, MAX_QUANTITY
        );

        vm.expectRevert(DeepstateRewarder.InvalidQuantitySchedule.selector);
        _deployRewarder(
            address(rewardToken),
            NVDA_SIDE_CAP,
            NVDA_DURATION,
            START_QUANTITY,
            START_QUANTITY,
            START_QUANTITY,
            MAX_QUANTITY
        );

        vm.expectRevert(DeepstateRewarder.InvalidQuantitySchedule.selector);
        _deployRewarder(
            address(rewardToken),
            NVDA_SIDE_CAP,
            NVDA_DURATION,
            START_QUANTITY,
            uint160(999e18),
            START_QUANTITY,
            MAX_QUANTITY
        );
    }

    function test_LogEmissionScheduleMatchesSelectedNVDA_CHECKPOINTS() public view {
        _assertApproxTokens(rewarder.cumulativeEmissionsAtElapsed(1 days), 6_184_677.733838e18);
        _assertApproxTokens(rewarder.cumulativeEmissionsAtElapsed(7 days), 39_556_599.780835e18);
        _assertApproxTokens(rewarder.cumulativeEmissionsAtElapsed(15 days), 76_477_114.24066e18);
        _assertApproxTokens(rewarder.cumulativeEmissionsAtElapsed(30 days), 130_738_490.324383e18);
        _assertApproxTokens(rewarder.cumulativeEmissionsAtElapsed(60 days), 207_215_604.565042e18);
        _assertApproxTokens(rewarder.cumulativeEmissionsAtElapsed(180 days), 367_029_344.314536e18);
        _assertApproxTokens(rewarder.cumulativeEmissionsAtElapsed(365 days), 486_192_683.463157e18);
        assertEq(rewarder.cumulativeEmissionsAtElapsed(395 days), NVDA_SIDE_CAP);
        assertEq(rewarder.cumulativeEmissionsAtElapsed(type(uint256).max), NVDA_SIDE_CAP);
    }

    function testFuzz_EmissionAccountingIsMonotonicAndCapped(uint32 firstOffset, uint32 secondOffset) public view {
        uint256 first = bound(firstOffset, 0, 500 days);
        uint256 second = bound(secondOffset, 0, 500 days);
        if (first > second) (first, second) = (second, first);

        uint256 firstCumulative = rewarder.cumulativeEmissionsAtElapsed(first);
        uint256 secondCumulative = rewarder.cumulativeEmissionsAtElapsed(second);
        assertLe(firstCumulative, secondCumulative);
        assertLe(secondCumulative, NVDA_SIDE_CAP);
    }

    function test_SideClocksActivateIndependentlyAndPersistAcrossEmptyBook() public {
        assertEq(rewarder.emissionStart(address(token0)), 0);
        assertEq(rewarder.emissionStart(address(token1)), 0);
        assertEq(rewarder.fullRewardQuantityAt(address(token0), block.timestamp), START_QUANTITY);

        _execute(address(token0), EMPTY_BOOK_ID, 0, 1);
        uint64 token0Start = rewarder.emissionStart(address(token0));
        assertEq(token0Start, block.timestamp);
        assertEq(rewarder.emissionStart(address(token1)), 0);

        vm.warp(block.timestamp + 1 days);
        _execute(address(token0), EMPTY_BOOK_ID, START_QUANTITY, 0);
        (uint32 nonce, uint64 startedAt) = rewarder.rewardees(address(token0));
        assertEq(nonce, 0);
        assertEq(startedAt, 0);
        assertEq(rewarder.emissionStart(address(token0)), token0Start);

        vm.warp(block.timestamp + 1 days);
        _execute(address(token0), EMPTY_BOOK_ID, 0, 2);
        assertEq(rewarder.emissionStart(address(token0)), token0Start);
        assertGt(rewarder.cumulativeEmissionsAt(address(token0), block.timestamp), 0);
    }

    function test_FullRewardQuantityMatchesMillionFoldCurve() public view {
        assertEq(rewarder.fullRewardQuantityAtElapsed(address(token0), 0), 1e18);
        assertApproxEqRel(rewarder.fullRewardQuantityAtElapsed(address(token0), 5 days), 10e18, 1e10);
        assertApproxEqRel(rewarder.fullRewardQuantityAtElapsed(address(token0), 10 days), 100e18, 1e10);
        assertApproxEqRel(rewarder.fullRewardQuantityAtElapsed(address(token0), 15 days), 1_000e18, 1e10);
        assertApproxEqRel(rewarder.fullRewardQuantityAtElapsed(address(token0), 20 days), 10_000e18, 1e10);
        assertApproxEqRel(rewarder.fullRewardQuantityAtElapsed(address(token0), 25 days), 100_000e18, 1e10);
        assertEq(rewarder.fullRewardQuantityAtElapsed(address(token0), 30 days), 1_000_000e18);
        assertEq(rewarder.fullRewardQuantityAtElapsed(address(token0), 300 days), 1_000_000e18);
    }

    function test_FullRewardQuantityMatchesNVDAFiveThousandCurve() public {
        DeepstateRewarder nvdaRewarder = _deployRewarder(
            address(rewardToken), NVDA_SIDE_CAP, NVDA_DURATION, 1e18, 5_000e18, START_QUANTITY, MAX_QUANTITY
        );

        assertApproxEqRel(nvdaRewarder.fullRewardQuantityAtElapsed(address(token0), 1 days), 1.328309e18, 1e12);
        assertApproxEqRel(nvdaRewarder.fullRewardQuantityAtElapsed(address(token0), 5 days), 4.135186e18, 1e12);
        assertApproxEqRel(nvdaRewarder.fullRewardQuantityAtElapsed(address(token0), 15 days), 70.710678e18, 1e12);
        assertApproxEqRel(nvdaRewarder.fullRewardQuantityAtElapsed(address(token0), 25 days), 1_209.135588e18, 1e12);
        assertEq(nvdaRewarder.fullRewardQuantityAtElapsed(address(token0), 30 days), 5_000e18);
    }

    function testFuzz_FullRewardQuantityIsMonotonic(uint32 firstOffset, uint32 secondOffset) public view {
        uint256 first = bound(firstOffset, 0, 60 days);
        uint256 second = bound(secondOffset, 0, 60 days);
        if (first > second) (first, second) = (second, first);
        assertLe(
            rewarder.fullRewardQuantityAtElapsed(address(token0), first),
            rewarder.fullRewardQuantityAtElapsed(address(token0), second)
        );
    }

    function test_IntegratedRewardsMatchIndependentNumericalVectors() public view {
        _assertApproxTokens(rewarder.previewRewardAtElapsed(address(token0), 0, 1 days, 1e18), 4_962_407.843893e18);
        _assertApproxTokens(rewarder.previewRewardAtElapsed(address(token0), 0, 5 days, 1e18), 11_677_688.307573e18);
        _assertApproxTokens(rewarder.previewRewardAtElapsed(address(token0), 0, 30 days, 1e18), 12_782_943.635188e18);
        _assertApproxTokens(rewarder.previewRewardAtElapsed(address(token0), 0, 30 days, 10e18), 40_127_802.701263e18);
        _assertApproxTokens(
            rewarder.previewRewardAtElapsed(address(token0), 0, 30 days, 1_000e18), 85_170_174.746157e18
        );
        _assertApproxTokens(
            rewarder.previewRewardAtElapsed(address(token0), 5 days, 20 days, 100e18), 34_843_198.007817e18
        );
        _assertApproxTokens(
            rewarder.previewRewardAtElapsed(address(token0), 30 days, 60 days, 500_000e18), 38_238_557.12033e18
        );
    }

    function test_QuantityAtOrAboveTargetReceivesFullSchedule() public view {
        uint256 fullBudget = rewarder.cumulativeEmissionsAtElapsed(30 days);
        assertEq(rewarder.previewRewardAtElapsed(address(token0), 0, 30 days, MAX_QUANTITY), fullBudget);
        assertEq(rewarder.previewRewardAtElapsed(address(token0), 0, 30 days, type(uint160).max), fullBudget);
    }

    function test_RewardIntegrationIsAdditiveAcrossCursorUpdates() public view {
        uint160 amount = 100e18;
        uint256 whole = rewarder.previewRewardAtElapsed(address(token0), 0, 30 days, amount);
        uint256 split = rewarder.previewRewardAtElapsed(address(token0), 0, 7 days, amount)
            + rewarder.previewRewardAtElapsed(address(token0), 7 days, 19 days, amount)
            + rewarder.previewRewardAtElapsed(address(token0), 19 days, 30 days, amount);
        assertApproxEqAbs(split, whole, 10);
    }

    function testFuzz_RewardIntegrationIsAdditive(
        uint32 firstOffset,
        uint32 splitOffset,
        uint32 endOffset,
        uint160 amount
    ) public view {
        uint256 first = bound(firstOffset, 0, NVDA_DURATION);
        uint256 split = bound(splitOffset, first, NVDA_DURATION);
        uint256 end = bound(endOffset, split, NVDA_DURATION);

        uint256 whole = rewarder.previewRewardAtElapsed(address(token0), first, end, amount);
        uint256 partitioned = rewarder.previewRewardAtElapsed(address(token0), first, split, amount)
            + rewarder.previewRewardAtElapsed(address(token0), split, end, amount);
        uint256 delta = partitioned > whole ? partitioned - whole : whole - partitioned;
        assertLe(delta, 1e9 + whole / 1e12);
    }

    function testFuzz_AdjustedRewardIsBoundedAndMonotonic(
        uint32 startOffset,
        uint32 duration_,
        uint160 first,
        uint160 second
    ) public view {
        uint256 start = bound(startOffset, 0, 500 days);
        uint256 end = start + bound(duration_, 0, 500 days);
        if (first > second) (first, second) = (second, first);

        uint256 firstReward = rewarder.previewRewardAtElapsed(address(token0), start, end, first);
        uint256 secondReward = rewarder.previewRewardAtElapsed(address(token0), start, end, second);
        uint256 scheduleBudget =
            rewarder.cumulativeEmissionsAtElapsed(end) - rewarder.cumulativeEmissionsAtElapsed(start);
        assertLe(firstReward, secondReward);
        assertLe(secondReward, scheduleBudget);
    }

    function test_ExecuteAccruesOutgoingTopAndTracksHardCap() public {
        _execute(address(token0), EMPTY_BOOK_ID, 0, 1);
        uint64 start = rewarder.emissionStart(address(token0));
        vm.warp(block.timestamp + NVDA_DURATION + 1 days);

        _execute(address(token0), EMPTY_BOOK_ID, type(uint160).max, 2);
        assertEq(rewarder.balances(EMPTY_BOOK_ID, address(token0), 1), NVDA_SIDE_CAP);
        assertEq(rewarder.totalAccrued(address(token0)), NVDA_SIDE_CAP);
        assertEq(rewarder.cumulativeEmissionsAt(address(token0), block.timestamp), NVDA_SIDE_CAP);
        assertEq(start + NVDA_DURATION < block.timestamp, true);

        vm.warp(block.timestamp + 1 days);
        _execute(address(token0), EMPTY_BOOK_ID, type(uint160).max, 3);
        assertEq(rewarder.balances(EMPTY_BOOK_ID, address(token0), 2), 0);
        assertEq(rewarder.totalAccrued(address(token0)), NVDA_SIDE_CAP);
    }

    function test_EngineHookAccruesAndDistributesDisplacedBid() public {
        bytes32 id = deepstate.bookId(address(token0), address(token1), 0);

        vm.prank(alice);
        bytes32 aliceBid = deepstate.fill(_fill(0, _order(0, 5e18, 0), true, false, false));
        bytes32 aliceOrderId = deepstate.orderId(id, aliceBid);
        (, uint64 startedAt) = rewarder.rewardees(address(token1));
        vm.warp(block.timestamp + 1 days);

        uint256 expected = rewarder.previewReward(address(token1), startedAt, block.timestamp, 5e18);
        vm.prank(bob);
        deepstate.fill(_fill(0, _order(1, 7e18, 0), true, false, false));

        assertEq(rewarder.balances(id, address(token1), MAX_ORDER_NONCE), expected);
        assertEq(rewarder.claimants(aliceOrderId), address(0));
        rewarder.distributeRewards(id, aliceBid, address(token1));
        assertEq(rewardToken.balanceOf(alice), expected);
        assertEq(rewarder.balances(id, address(token1), MAX_ORDER_NONCE), 0);
        assertEq(rewarder.claimants(aliceOrderId), alice);
    }

    function test_InlineRegistrationPreservesFinalAccrualAfterCancel() public {
        bytes32 id = deepstate.bookId(address(token0), address(token1), 0);

        vm.prank(alice);
        bytes32 aliceBid = deepstate.fill(_fill(0, _order(0, 5e18, 0), true, false, false));
        bytes32 aliceOrderId = deepstate.orderId(id, aliceBid);
        (, uint64 startedAt) = rewarder.rewardees(address(token1));
        vm.warp(block.timestamp + 1 days);
        uint256 firstReward = rewarder.previewReward(address(token1), startedAt, block.timestamp, 5e18);

        rewarder.distributeRewards(id, aliceBid, address(token1));
        assertEq(rewardToken.balanceOf(alice), firstReward);
        assertEq(rewarder.claimants(aliceOrderId), alice);
        (, uint64 claimedAt) = rewarder.rewardees(address(token1));
        assertEq(claimedAt, block.timestamp);

        vm.warp(block.timestamp + 1 hours);
        uint256 finalReward = rewarder.previewReward(address(token1), claimedAt, block.timestamp, 5e18);
        vm.prank(alice);
        deepstate.cancel(address(token0), address(token1), 0, aliceBid);
        assertEq(deepstate.ownerOfOrder(aliceOrderId), address(0));
        assertEq(rewarder.balances(id, address(token1), MAX_ORDER_NONCE), finalReward);

        rewarder.distributeRewards(id, aliceBid, address(token1));
        assertEq(rewarder.balances(id, address(token1), MAX_ORDER_NONCE), 0);
        assertEq(rewardToken.balanceOf(alice), firstReward + finalReward);
    }

    function test_PermissionlessRegistrationAllowsClaimAfterCancel() public {
        bytes32 id = deepstate.bookId(address(token0), address(token1), 0);

        vm.prank(alice);
        bytes32 aliceBid = deepstate.fill(_fill(0, _order(0, 5e18, 0), true, false, false));
        bytes32 aliceOrderId = deepstate.orderId(id, aliceBid);
        (, uint64 startedAt) = rewarder.rewardees(address(token1));

        vm.prank(bob);
        address claimant = rewarder.registerClaimant(id, aliceBid);
        assertEq(claimant, alice);
        assertEq(rewarder.claimants(aliceOrderId), alice);

        vm.warp(block.timestamp + 1 days);
        uint256 expected = rewarder.previewReward(address(token1), startedAt, block.timestamp, 5e18);
        vm.prank(alice);
        deepstate.cancel(address(token0), address(token1), 0, aliceBid);
        assertEq(deepstate.ownerOfOrder(aliceOrderId), address(0));

        assertEq(rewarder.registerClaimant(id, aliceBid), alice);
        rewarder.distributeRewards(id, aliceBid, address(token1));
        assertEq(rewardToken.balanceOf(alice), expected);
    }

    function test_RegisteredDisplacedOrderCanClaimAfterNonTopCancel() public {
        bytes32 id = deepstate.bookId(address(token0), address(token1), 0);

        vm.prank(alice);
        bytes32 aliceBid = deepstate.fill(_fill(0, _order(0, 5e18, 0), true, false, false));
        bytes32 aliceOrderId = deepstate.orderId(id, aliceBid);
        rewarder.registerClaimant(id, aliceBid);

        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        deepstate.fill(_fill(0, _order(1, 7e18, 0), true, false, false));
        uint256 expected = rewarder.balances(id, address(token1), MAX_ORDER_NONCE);
        assertGt(expected, 0);

        vm.prank(alice);
        deepstate.cancel(address(token0), address(token1), 0, aliceBid);
        assertEq(deepstate.ownerOfOrder(aliceOrderId), address(0));

        rewarder.distributeRewards(id, aliceBid, address(token1));
        assertEq(rewarder.balances(id, address(token1), MAX_ORDER_NONCE), 0);
        assertEq(rewardToken.balanceOf(alice), expected);
    }

    function test_BatchRegistrationAndClaimPreservesMultipleOrdersAfterCancel() public {
        bytes32 id = deepstate.bookId(address(token0), address(token1), 0);
        uint256 initialTimestamp = block.timestamp;

        vm.prank(alice);
        bytes32 firstAliceBid = deepstate.fill(_fill(0, _order(0, 5e18, 0), true, false, false));
        vm.warp(initialTimestamp + 1 days);
        vm.prank(bob);
        deepstate.fill(_fill(0, _order(1, 7e18, 0), true, false, false));
        vm.warp(initialTimestamp + 2 days);
        vm.prank(alice);
        bytes32 secondAliceBid = deepstate.fill(_fill(0, _order(2, 9e18, 0), true, false, false));

        DeepstateRewarder.OrderReference[] memory registrations = new DeepstateRewarder.OrderReference[](2);
        registrations[0] = DeepstateRewarder.OrderReference({bookId: id, order: firstAliceBid});
        registrations[1] = DeepstateRewarder.OrderReference({bookId: id, order: secondAliceBid});
        vm.prank(bob);
        assertEq(rewarder.registerClaimants(registrations), alice);

        bytes32 firstOrderId = deepstate.orderId(id, firstAliceBid);
        bytes32 secondOrderId = deepstate.orderId(id, secondAliceBid);
        assertEq(rewarder.claimants(firstOrderId), alice);
        assertEq(rewarder.claimants(secondOrderId), alice);

        vm.warp(initialTimestamp + 3 days);
        vm.prank(alice);
        deepstate.cancel(address(token0), address(token1), 0, secondAliceBid);
        vm.prank(alice);
        deepstate.cancel(address(token0), address(token1), 0, firstAliceBid);
        assertEq(deepstate.ownerOfOrder(firstOrderId), address(0));
        assertEq(deepstate.ownerOfOrder(secondOrderId), address(0));

        uint256 firstReward = rewarder.balances(id, address(token1), MAX_ORDER_NONCE);
        uint256 secondReward = rewarder.balances(id, address(token1), MAX_ORDER_NONCE - 2);
        assertGt(firstReward, 0);
        assertGt(secondReward, 0);

        DeepstateRewarder.RewardClaim[] memory claims = new DeepstateRewarder.RewardClaim[](2);
        claims[0] = DeepstateRewarder.RewardClaim({bookId: id, order: firstAliceBid, token: address(token1)});
        claims[1] = DeepstateRewarder.RewardClaim({bookId: id, order: secondAliceBid, token: address(token1)});
        uint256 fundingBefore = rewardToken.balanceOf(address(rewarder));
        rewarder.distributeRewardsBatch(claims);

        uint256 totalReward = firstReward + secondReward;
        assertEq(rewardToken.balanceOf(alice), totalReward);
        assertEq(rewardToken.balanceOf(address(rewarder)), fundingBefore - totalReward);
        assertEq(rewardToken.transferCalls(), 1);
        assertEq(rewarder.balances(id, address(token1), MAX_ORDER_NONCE), 0);
        assertEq(rewarder.balances(id, address(token1), MAX_ORDER_NONCE - 2), 0);
    }

    function test_BatchRegistrationRejectsMixedOwnersAtomically() public {
        bytes32 id = deepstate.bookId(address(token0), address(token1), 0);
        vm.prank(alice);
        bytes32 aliceBid = deepstate.fill(_fill(0, _order(0, 5e18, 0), true, false, false));
        vm.prank(bob);
        bytes32 bobBid = deepstate.fill(_fill(0, _order(1, 7e18, 0), true, false, false));

        DeepstateRewarder.OrderReference[] memory registrations = new DeepstateRewarder.OrderReference[](2);
        registrations[0] = DeepstateRewarder.OrderReference({bookId: id, order: aliceBid});
        registrations[1] = DeepstateRewarder.OrderReference({bookId: id, order: bobBid});

        vm.expectRevert(DeepstateRewarder.ClaimantMismatch.selector);
        rewarder.registerClaimants(registrations);
        assertEq(rewarder.claimants(deepstate.orderId(id, aliceBid)), address(0));
        assertEq(rewarder.claimants(deepstate.orderId(id, bobBid)), address(0));
    }

    function test_BatchClaimRejectsMixedOwnersAtomically() public {
        bytes32 id = deepstate.bookId(address(token0), address(token1), 0);
        uint256 initialTimestamp = block.timestamp;
        vm.prank(alice);
        bytes32 aliceBid = deepstate.fill(_fill(0, _order(0, 5e18, 0), true, false, false));
        vm.warp(initialTimestamp + 1 days);
        vm.prank(bob);
        bytes32 bobBid = deepstate.fill(_fill(0, _order(1, 7e18, 0), true, false, false));
        vm.warp(initialTimestamp + 2 days);
        vm.prank(alice);
        deepstate.fill(_fill(0, _order(2, 9e18, 0), true, false, false));

        uint256 aliceReward = rewarder.balances(id, address(token1), MAX_ORDER_NONCE);
        uint256 bobReward = rewarder.balances(id, address(token1), MAX_ORDER_NONCE - 1);
        assertGt(aliceReward, 0);
        assertGt(bobReward, 0);

        DeepstateRewarder.RewardClaim[] memory claims = new DeepstateRewarder.RewardClaim[](2);
        claims[0] = DeepstateRewarder.RewardClaim({bookId: id, order: aliceBid, token: address(token1)});
        claims[1] = DeepstateRewarder.RewardClaim({bookId: id, order: bobBid, token: address(token1)});

        vm.expectRevert(DeepstateRewarder.ClaimantMismatch.selector);
        rewarder.distributeRewardsBatch(claims);
        assertEq(rewarder.balances(id, address(token1), MAX_ORDER_NONCE), aliceReward);
        assertEq(rewarder.balances(id, address(token1), MAX_ORDER_NONCE - 1), bobReward);
        assertEq(rewarder.claimants(deepstate.orderId(id, aliceBid)), address(0));
        assertEq(rewarder.claimants(deepstate.orderId(id, bobBid)), address(0));
        assertEq(rewardToken.balanceOf(alice), 0);
        assertEq(rewardToken.balanceOf(bob), 0);
        assertEq(rewardToken.transferCalls(), 0);
    }

    function test_BatchClaimChecksOwnerOfZeroRewardCurrentOrder() public {
        bytes32 id = deepstate.bookId(address(token0), address(token1), 0);
        uint256 initialTimestamp = block.timestamp;
        vm.prank(bob);
        bytes32 bobBid = deepstate.fill(_fill(0, _order(0, 5e18, 0), true, false, false));
        vm.warp(initialTimestamp + 1 days);
        vm.prank(alice);
        bytes32 aliceBid = deepstate.fill(_fill(0, _order(1, 7e18, 0), true, false, false));

        uint256 bobReward = rewarder.balances(id, address(token1), MAX_ORDER_NONCE);
        assertGt(bobReward, 0);

        DeepstateRewarder.RewardClaim[] memory claims = new DeepstateRewarder.RewardClaim[](2);
        claims[0] = DeepstateRewarder.RewardClaim({bookId: id, order: bobBid, token: address(token1)});
        claims[1] = DeepstateRewarder.RewardClaim({bookId: id, order: aliceBid, token: address(token1)});

        vm.expectRevert(DeepstateRewarder.ClaimantMismatch.selector);
        rewarder.distributeRewardsBatch(claims);
        assertEq(rewarder.balances(id, address(token1), MAX_ORDER_NONCE), bobReward);
        assertEq(rewarder.claimants(deepstate.orderId(id, bobBid)), address(0));
        assertEq(rewarder.claimants(deepstate.orderId(id, aliceBid)), address(0));
        assertEq(rewardToken.transferCalls(), 0);
    }

    function test_DuplicateBatchClaimCannotPayTwice() public {
        bytes32 id = deepstate.bookId(address(token0), address(token1), 0);
        vm.prank(alice);
        bytes32 aliceBid = deepstate.fill(_fill(0, _order(0, 5e18, 0), true, false, false));
        (, uint64 startedAt) = rewarder.rewardees(address(token1));
        vm.warp(block.timestamp + 1 days);
        uint256 expected = rewarder.previewReward(address(token1), startedAt, block.timestamp, 5e18);

        DeepstateRewarder.RewardClaim[] memory claims = new DeepstateRewarder.RewardClaim[](2);
        claims[0] = DeepstateRewarder.RewardClaim({bookId: id, order: aliceBid, token: address(token1)});
        claims[1] = claims[0];
        rewarder.distributeRewardsBatch(claims);

        assertEq(rewardToken.balanceOf(alice), expected);
        assertEq(rewardToken.transferCalls(), 1);
    }

    function test_BatchClaimAggregatesBidAndAskForSameOwner() public {
        bytes32 id = deepstate.bookId(address(token0), address(token1), 0);
        vm.prank(alice);
        bytes32 aliceBid = deepstate.fill(_fill(0, _order(0, 5e18, 0), true, false, false));
        vm.prank(alice);
        bytes32 aliceAsk = deepstate.fill(_fill(0, _order(20, 8e18, 0), false, false, false));
        (, uint64 bidStartedAt) = rewarder.rewardees(address(token1));
        (, uint64 askStartedAt) = rewarder.rewardees(address(token0));

        vm.warp(block.timestamp + 1 days);
        uint256 bidReward = rewarder.previewReward(address(token1), bidStartedAt, block.timestamp, 5e18);
        uint256 askReward = rewarder.previewReward(address(token0), askStartedAt, block.timestamp, 8e18);

        DeepstateRewarder.RewardClaim[] memory claims = new DeepstateRewarder.RewardClaim[](2);
        claims[0] = DeepstateRewarder.RewardClaim({bookId: id, order: aliceBid, token: address(token1)});
        claims[1] = DeepstateRewarder.RewardClaim({bookId: id, order: aliceAsk, token: address(token0)});
        rewarder.distributeRewardsBatch(claims);

        assertEq(rewardToken.balanceOf(alice), bidReward + askReward);
        assertEq(rewardToken.transferCalls(), 1);
    }

    function test_BatchFunctionsRejectEmptyInput() public {
        DeepstateRewarder.OrderReference[] memory registrations = new DeepstateRewarder.OrderReference[](0);
        vm.expectRevert(DeepstateRewarder.EmptyBatch.selector);
        rewarder.registerClaimants(registrations);

        DeepstateRewarder.RewardClaim[] memory claims = new DeepstateRewarder.RewardClaim[](0);
        vm.expectRevert(DeepstateRewarder.EmptyBatch.selector);
        rewarder.distributeRewardsBatch(claims);
    }

    function test_ClaimTimeAccrualUsesLiveQuantityAfterPartialFill() public {
        bytes32 id = deepstate.bookId(address(token0), address(token1), 0);

        vm.prank(alice);
        bytes32 aliceBid = deepstate.fill(_fill(0, _order(0, 10e18, 0), true, false, false));
        (, uint64 firstStart) = rewarder.rewardees(address(token1));
        vm.warp(block.timestamp + 1 days);
        uint256 firstReward = rewarder.previewReward(address(token1), firstStart, block.timestamp, 10e18);

        vm.prank(bob);
        deepstate.fill(_fill(0, _order(0, 4e18, 0), false, true, false));
        (, uint64 secondStart) = rewarder.rewardees(address(token1));
        (uint32 liveNonce, uint160 liveQuantity) = deepstate.topOrder(id, true);
        assertEq(liveNonce, MAX_ORDER_NONCE);
        assertEq(liveQuantity, 6e18);

        vm.warp(block.timestamp + 1 days);
        uint256 secondReward = rewarder.previewReward(address(token1), secondStart, block.timestamp, 6e18);
        rewarder.distributeRewards(id, aliceBid, address(token1));
        assertApproxEqAbs(rewardToken.balanceOf(alice), firstReward + secondReward, 1);
    }

    function test_AskSideAccruesIndependently() public {
        bytes32 id = deepstate.bookId(address(token0), address(token1), 0);

        vm.prank(alice);
        bytes32 aliceAsk = deepstate.fill(_fill(0, _order(20, 8e18, 0), false, false, false));
        (, uint64 startedAt) = rewarder.rewardees(address(token0));
        assertEq(rewarder.emissionStart(address(token1)), 0);

        vm.warp(block.timestamp + 1 days);
        uint256 expected = rewarder.previewReward(address(token0), startedAt, block.timestamp, 8e18);
        vm.prank(bob);
        deepstate.fill(_fill(0, _order(19, 9e18, 0), false, false, false));

        rewarder.distributeRewards(id, aliceAsk, address(token0));
        assertEq(rewardToken.balanceOf(alice), expected);
    }

    function test_RouterTopOrderReportsBothSidesAndEmptyState() public {
        bytes32 id = deepstate.bookId(address(token0), address(token1), 0);
        (uint32 nonce, uint160 quantity) = deepstate.topOrder(id, true);
        assertEq(nonce, 0);
        assertEq(quantity, 0);

        vm.prank(alice);
        deepstate.fill(_fill(0, _order(0, 5e18, 0), true, false, false));
        vm.prank(bob);
        deepstate.fill(_fill(0, _order(20, 8e18, 0), false, false, false));

        (nonce, quantity) = deepstate.topOrder(id, true);
        assertEq(nonce, MAX_ORDER_NONCE);
        assertEq(quantity, 5e18);
        (nonce, quantity) = deepstate.topOrder(id, false);
        assertEq(nonce, MAX_ORDER_NONCE - 1);
        assertEq(quantity, 8e18);
    }

    function test_WrongBookCannotTriggerLiveAccrual() public {
        bytes32 id = deepstate.bookId(address(token0), address(token1), 0);
        vm.prank(alice);
        bytes32 aliceBid = deepstate.fill(_fill(0, _order(0, 5e18, 0), true, false, false));
        vm.warp(block.timestamp + 1 days);

        rewarder.distributeRewards(EMPTY_BOOK_ID, aliceBid, address(token1));
        assertEq(rewardToken.balanceOf(alice), 0);
        assertEq(rewarder.balances(id, address(token1), MAX_ORDER_NONCE), 0);
    }

    function test_UnregisteredDeletedOrderCannotClaim() public {
        bytes32 id = deepstate.bookId(address(token0), address(token1), 0);
        vm.prank(alice);
        bytes32 aliceBid = deepstate.fill(_fill(0, _order(0, 5e18, 0), true, false, false));
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        deepstate.fill(_fill(0, _order(1, 7e18, 0), true, false, false));

        vm.prank(alice);
        deepstate.cancel(address(token0), address(token1), 0, aliceBid);
        uint256 stranded = rewarder.balances(id, address(token1), MAX_ORDER_NONCE);
        assertGt(stranded, 0);

        vm.expectRevert(DeepstateRewarder.NoOrderOwner.selector);
        rewarder.distributeRewards(id, aliceBid, address(token1));
        assertEq(rewarder.balances(id, address(token1), MAX_ORDER_NONCE), stranded);

        vm.expectRevert(DeepstateRewarder.NoOrderOwner.selector);
        rewarder.registerClaimant(id, aliceBid);
    }

    function test_RegisterClaimantRejectsUnknownOrder() public {
        vm.expectRevert(DeepstateRewarder.NoOrderOwner.selector);
        rewarder.registerClaimant(EMPTY_BOOK_ID, bytes32(uint256(1)));
    }

    function test_ClaimTransfersPrefundedDeepWithoutMintAuthority() public {
        DeepstateToken deep = new DeepstateToken(address(this), "Deepstate", "DEEP");
        DeepstateRewarder prefundedRewarder = _deployRewarder(
            address(deep), NVDA_SIDE_CAP, NVDA_DURATION, START_QUANTITY, MAX_QUANTITY, START_QUANTITY, MAX_QUANTITY
        );
        bytes32 minterRole = deep.MINTER_ROLE();
        deep.grantRole(minterRole, address(this));
        deep.mint(address(prefundedRewarder), uint256(NVDA_SIDE_CAP) * 2);
        deep.revokeRole(minterRole, address(this));
        deepstate.setPoolHookConfig(address(token0), address(token1), address(prefundedRewarder), true, true);

        bytes32 id = deepstate.bookId(address(token0), address(token1), 0);
        vm.prank(alice);
        bytes32 aliceBid = deepstate.fill(_fill(0, _order(0, 5e18, 0), true, false, false));
        vm.warp(block.timestamp + 1 days);
        (, uint64 startedAt) = prefundedRewarder.rewardees(address(token1));
        uint256 expected = prefundedRewarder.previewReward(address(token1), startedAt, block.timestamp, 5e18);
        uint256 supplyBefore = deep.totalSupply();
        uint256 fundingBefore = deep.balanceOf(address(prefundedRewarder));

        prefundedRewarder.distributeRewards(id, aliceBid, address(token1));

        assertFalse(deep.hasRole(minterRole, address(prefundedRewarder)));
        assertEq(deep.totalSupply(), supplyBefore);
        assertEq(deep.balanceOf(address(prefundedRewarder)), fundingBefore - expected);
        assertEq(deep.balanceOf(alice), expected);
    }

    function test_UnfundedRewarderRollsBackClaimAccrual() public {
        DeepstateRewarder unfundedRewarder = _deployRewarder(
            address(rewardToken),
            NVDA_SIDE_CAP,
            NVDA_DURATION,
            START_QUANTITY,
            MAX_QUANTITY,
            START_QUANTITY,
            MAX_QUANTITY
        );
        deepstate.setPoolHookConfig(address(token0), address(token1), address(unfundedRewarder), true, true);

        bytes32 id = deepstate.bookId(address(token0), address(token1), 0);
        vm.prank(alice);
        bytes32 aliceBid = deepstate.fill(_fill(0, _order(0, 5e18, 0), true, false, false));
        vm.warp(block.timestamp + 1 days);
        (, uint64 beforeClaimStart) = unfundedRewarder.rewardees(address(token1));

        vm.expectRevert(ERC20.InsufficientBalance.selector);
        unfundedRewarder.distributeRewards(id, aliceBid, address(token1));
        (, uint64 afterFailedClaimStart) = unfundedRewarder.rewardees(address(token1));
        assertEq(afterFailedClaimStart, beforeClaimStart);
        assertEq(unfundedRewarder.totalAccrued(address(token1)), 0);
        assertEq(unfundedRewarder.claimants(deepstate.orderId(id, aliceBid)), address(0));

        rewardToken.mint(address(unfundedRewarder), uint256(NVDA_SIDE_CAP) * 2);
        unfundedRewarder.distributeRewards(id, aliceBid, address(token1));
        assertGt(rewardToken.balanceOf(alice), 0);
        assertEq(unfundedRewarder.claimants(deepstate.orderId(id, aliceBid)), alice);
    }

    function test_RegisteredPostCancelClaimCanRetryAfterRewarderIsFunded() public {
        DeepstateRewarder unfundedRewarder = _deployRewarder(
            address(rewardToken),
            NVDA_SIDE_CAP,
            NVDA_DURATION,
            START_QUANTITY,
            MAX_QUANTITY,
            START_QUANTITY,
            MAX_QUANTITY
        );
        deepstate.setPoolHookConfig(address(token0), address(token1), address(unfundedRewarder), true, true);

        bytes32 id = deepstate.bookId(address(token0), address(token1), 0);
        vm.prank(alice);
        bytes32 aliceBid = deepstate.fill(_fill(0, _order(0, 5e18, 0), true, false, false));
        bytes32 aliceOrderId = deepstate.orderId(id, aliceBid);
        unfundedRewarder.registerClaimant(id, aliceBid);

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        deepstate.cancel(address(token0), address(token1), 0, aliceBid);
        uint256 pending = unfundedRewarder.balances(id, address(token1), MAX_ORDER_NONCE);
        assertGt(pending, 0);

        vm.expectRevert(ERC20.InsufficientBalance.selector);
        unfundedRewarder.distributeRewards(id, aliceBid, address(token1));
        assertEq(unfundedRewarder.balances(id, address(token1), MAX_ORDER_NONCE), pending);
        assertEq(unfundedRewarder.claimants(aliceOrderId), alice);

        rewardToken.mint(address(unfundedRewarder), uint256(NVDA_SIDE_CAP) * 2);
        unfundedRewarder.distributeRewards(id, aliceBid, address(token1));
        assertEq(unfundedRewarder.balances(id, address(token1), MAX_ORDER_NONCE), 0);
        assertEq(rewardToken.balanceOf(alice), pending);
    }

    function test_ExecuteValidationAndViewsRejectUnknownTokens() public {
        vm.expectRevert(DeepstateRewarder.NotDeepstate.selector);
        rewarder.execute(configuredPoolId, EMPTY_BOOK_ID, address(token0), 1, 1);

        vm.expectRevert(DeepstateRewarder.InvalidPool.selector);
        vm.prank(address(deepstate));
        rewarder.execute(INVALID_POOL_ID, EMPTY_BOOK_ID, address(token0), 1, 1);

        vm.expectRevert(DeepstateRewarder.InvalidHookToken.selector);
        vm.prank(address(deepstate));
        rewarder.execute(configuredPoolId, EMPTY_BOOK_ID, address(rewardToken), 1, 1);

        vm.expectRevert(DeepstateRewarder.InvalidHookToken.selector);
        rewarder.rewardees(address(rewardToken));
        vm.expectRevert(DeepstateRewarder.InvalidHookToken.selector);
        rewarder.emissionStart(address(rewardToken));
        vm.expectRevert(DeepstateRewarder.InvalidHookToken.selector);
        rewarder.fullRewardQuantityAtElapsed(address(rewardToken), 1 days);
        vm.expectRevert(DeepstateRewarder.InvalidHookToken.selector);
        rewarder.distributeRewards(EMPTY_BOOK_ID, bytes32(0), address(rewardToken));
    }

    function test_ExecuteStaysInsideDeepstateHookGasBudget() public {
        uint256 beforeGas = gasleft();
        _execute(address(token0), EMPTY_BOOK_ID, 0, 1);
        uint256 installGas = beforeGas - gasleft();

        vm.warp(block.timestamp + 1 days);
        beforeGas = gasleft();
        _execute(address(token0), EMPTY_BOOK_ID, 5e18, 2);
        uint256 freshAccrualGas = beforeGas - gasleft();

        vm.warp(block.timestamp + 1 days);
        beforeGas = gasleft();
        _execute(address(token0), EMPTY_BOOK_ID, 5e18, 3);
        uint256 warmBalanceGas = beforeGas - gasleft();

        emit log_named_uint("execute install gas", installGas);
        emit log_named_uint("execute fresh accrual gas", freshAccrualGas);
        emit log_named_uint("execute existing balance gas", warmBalanceGas);
        assertLt(installGas, 200_000);
        assertLt(freshAccrualGas, 200_000);
        assertLt(warmBalanceGas, 200_000);
    }

    function test_RevertingRewardHookDoesNotBlockFill() public {
        deepstate.setPoolHookConfig(address(token0), address(token1), address(new RevertingHook()), true, false);

        vm.prank(alice);
        bytes32 resting = deepstate.fill(_fill(0, _order(10, 5e18, 0), true, false, false));

        bytes32 id = deepstate.bookId(address(token0), address(token1), 0);
        assertEq(deepstate.ownerOfOrder(deepstate.orderId(id, resting)), alice);
    }

    function test_InactiveSideCancelDoesNotCallHook() public {
        CountingHook hook = new CountingHook();
        deepstate.setPoolHookConfig(address(token0), address(token1), address(hook), true, false);

        vm.prank(alice);
        bytes32 ask = deepstate.fill(_fill(0, _order(10, 5e18, 0), false, false, false));
        vm.prank(alice);
        deepstate.cancel(address(token0), address(token1), 0, ask);

        assertEq(hook.calls(), 0);
        assertEq(hook.lastToken(), address(0));
    }

    function _deployRewarder(
        address rewardToken_,
        uint96 sideCap,
        uint32 duration,
        uint160 token0Start,
        uint160 token0Max,
        uint160 token1Start,
        uint160 token1Max
    ) internal returns (DeepstateRewarder deployed) {
        return _newRewarder(
            address(this),
            address(deepstate),
            rewardToken_,
            configuredPoolId,
            address(token0),
            address(token1),
            sideCap,
            duration,
            token0Start,
            token0Max,
            token1Start,
            token1Max
        );
    }

    function _newRewarder(
        address owner,
        address deepstate_,
        address rewardToken_,
        bytes32 poolId_,
        address token0_,
        address token1_,
        uint96 sideCap,
        uint32 duration,
        uint160 token0Start,
        uint160 token0Max,
        uint160 token1Start,
        uint160 token1Max
    ) internal returns (DeepstateRewarder deployed) {
        deployed = new DeepstateRewarder(
            owner,
            deepstate_,
            rewardToken_,
            poolId_,
            token0_,
            token1_,
            sideCap,
            duration,
            token0Start,
            token0Max,
            token1Start,
            token1Max
        );
    }

    function _execute(address token, bytes32 bookId, uint160 outgoingAmount, uint32 incomingNonce) internal {
        vm.prank(address(deepstate));
        rewarder.execute(configuredPoolId, bookId, token, outgoingAmount, incomingNonce);
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
        token0.mint(user, 1_000_000_000e18);
        token1.mint(user, 1_000_000_000e18);

        vm.startPrank(user);
        token0.approve(address(deepstate), type(uint256).max);
        token1.approve(address(deepstate), type(uint256).max);
        vm.stopPrank();
    }

    function _order(int32 price, uint160 quantity, uint32 nonce) internal pure returns (bytes32) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes32((uint256(uint32(price)) << 224) | (uint256(quantity) << 64) | uint256(nonce));
    }

    function _assertApproxTokens(uint256 actual, uint256 expected) internal pure {
        assertApproxEqRel(actual, expected, 1e10);
    }
}
