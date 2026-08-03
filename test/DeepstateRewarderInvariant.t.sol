// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {DeepstateRewarder} from "../src/DeepstateRewarder.sol";

contract RewarderInvariantMintable {
    mapping(address account => uint256 balance) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract DeepstateRewarderHandler is Test {
    address public constant TOKEN0 = address(0x1000);
    address public constant TOKEN1 = address(0x2000);
    uint96 public constant SIDE_CAP = 500_000_000e18;
    uint32 public constant DURATION = 395 days;
    bytes32 public constant BOOK_ID = keccak256("invariant-book");

    DeepstateRewarder public immutable rewarder;

    uint256 public recordedToken0Credits;
    uint256 public recordedToken1Credits;
    uint64 public firstToken0Activation;
    uint64 public firstToken1Activation;
    uint32 public expectedToken0Nonce;
    uint32 public expectedToken1Nonce;
    uint64 public expectedToken0Cursor;
    uint64 public expectedToken1Cursor;

    constructor() {
        RewarderInvariantMintable rewardToken = new RewarderInvariantMintable();
        bytes32 poolId = keccak256(abi.encode(TOKEN0, TOKEN1));
        rewarder = new DeepstateRewarder(
            address(this),
            address(this),
            address(rewardToken),
            poolId,
            TOKEN0,
            TOKEN1,
            SIDE_CAP,
            DURATION,
            1e18,
            1_000_000e18,
            1e6,
            1_000_000e6
        );
    }

    function transition(uint8 sideSeed, uint160 outgoingAmount, uint32 incomingSeed, uint32 elapsedSeed) external {
        address token = sideSeed & 1 == 0 ? TOKEN0 : TOKEN1;
        uint32 incomingNonce = incomingSeed % 5 == 0 ? 0 : incomingSeed | 1;
        uint256 elapsed = bound(elapsedSeed, 0, 14 days);
        vm.warp(block.timestamp + elapsed);

        (uint32 outgoingNonce,) = rewarder.rewardees(token);
        uint256 balanceBefore = rewarder.balances(BOOK_ID, token, outgoingNonce);
        uint96 accruedBefore = rewarder.totalAccrued(token);

        rewarder.execute(rewarder.poolId(), BOOK_ID, token, outgoingAmount, incomingNonce);

        uint256 balanceAfter = rewarder.balances(BOOK_ID, token, outgoingNonce);
        uint96 accruedAfter = rewarder.totalAccrued(token);
        assertGe(accruedAfter, accruedBefore);
        assertEq(uint256(accruedAfter - accruedBefore), balanceAfter - balanceBefore);

        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 now64 = uint64(block.timestamp);
        uint64 activation = rewarder.emissionStart(token);
        if (token == TOKEN0) {
            recordedToken0Credits += balanceAfter - balanceBefore;
            if (firstToken0Activation == 0 && incomingNonce != 0) firstToken0Activation = now64;
            expectedToken0Nonce = incomingNonce;
            expectedToken0Cursor = incomingNonce == 0 ? 0 : now64;
            assertEq(activation, firstToken0Activation);
        } else {
            recordedToken1Credits += balanceAfter - balanceBefore;
            if (firstToken1Activation == 0 && incomingNonce != 0) firstToken1Activation = now64;
            expectedToken1Nonce = incomingNonce;
            expectedToken1Cursor = incomingNonce == 0 ? 0 : now64;
            assertEq(activation, firstToken1Activation);
        }
    }
}

contract DeepstateRewarderInvariantTest is StdInvariant, Test {
    DeepstateRewarderHandler internal handler;
    DeepstateRewarder internal rewarder;

    function setUp() public {
        vm.warp(1_000_000);
        handler = new DeepstateRewarderHandler();
        rewarder = handler.rewarder();

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = handler.transition.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_AccruedRewardsEqualRecordedBalanceCredits() public view {
        assertEq(rewarder.totalAccrued(handler.TOKEN0()), handler.recordedToken0Credits());
        assertEq(rewarder.totalAccrued(handler.TOKEN1()), handler.recordedToken1Credits());
    }

    function invariant_EachSideRespectsItsImmutableCap() public view {
        assertLe(rewarder.totalAccrued(handler.TOKEN0()), handler.SIDE_CAP());
        assertLe(rewarder.totalAccrued(handler.TOKEN1()), handler.SIDE_CAP());
        assertLe(
            uint256(rewarder.totalAccrued(handler.TOKEN0())) + rewarder.totalAccrued(handler.TOKEN1()),
            uint256(handler.SIDE_CAP()) * 2
        );
    }

    function invariant_ActivationTimestampsNeverReset() public view {
        assertEq(rewarder.emissionStart(handler.TOKEN0()), handler.firstToken0Activation());
        assertEq(rewarder.emissionStart(handler.TOKEN1()), handler.firstToken1Activation());
    }

    function invariant_RewardeeCursorsMatchEveryTransition() public view {
        (uint32 token0Nonce, uint64 token0Cursor) = rewarder.rewardees(handler.TOKEN0());
        (uint32 token1Nonce, uint64 token1Cursor) = rewarder.rewardees(handler.TOKEN1());
        assertEq(token0Nonce, handler.expectedToken0Nonce());
        assertEq(token0Cursor, handler.expectedToken0Cursor());
        assertEq(token1Nonce, handler.expectedToken1Nonce());
        assertEq(token1Cursor, handler.expectedToken1Cursor());
    }

    function invariant_PublicSchedulesRemainBounded() public view {
        assertEq(rewarder.cumulativeEmissionsAtElapsed(handler.DURATION()), handler.SIDE_CAP());
        assertEq(rewarder.cumulativeEmissionsAtElapsed(type(uint256).max), handler.SIDE_CAP());

        uint256 token0Quantity = rewarder.fullRewardQuantityAtElapsed(handler.TOKEN0(), block.timestamp);
        uint256 token1Quantity = rewarder.fullRewardQuantityAtElapsed(handler.TOKEN1(), block.timestamp);
        assertGe(token0Quantity, 1e18);
        assertLe(token0Quantity, 1_000_000e18);
        assertGe(token1Quantity, 1e6);
        assertLe(token1Quantity, 1_000_000e6);
    }
}
