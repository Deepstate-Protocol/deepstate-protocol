// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

import {DeepstateRewarderV2} from "../src/DeepstateRewarderV2.sol";

contract RewarderV2TestToken is ERC20 {
    function name() public pure override returns (string memory) {
        return "Reward";
    }

    function symbol() public pure override returns (string memory) {
        return "RWD";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DeepstateRewarderV2Test is Test {
    uint96 internal constant SIDE_CAP = 500_000_000e18;
    address internal constant DEEPSTATE = address(0x1000);
    address internal constant TOKEN0 = address(0x2000);
    address internal constant TOKEN1 = address(0x3000);

    RewarderV2TestToken internal rewardToken;
    DeepstateRewarderV2 internal rewarder;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        rewardToken = new RewarderV2TestToken();
        rewarder = new DeepstateRewarderV2(
            address(this),
            DEEPSTATE,
            address(rewardToken),
            keccak256(abi.encode(TOKEN0, TOKEN1)),
            TOKEN0,
            TOKEN1,
            SIDE_CAP,
            395 days,
            1e18,
            5_000e18,
            1e6,
            1_000_000e6
        );
        rewardToken.mint(address(rewarder), uint256(SIDE_CAP) * 2);
    }

    function test_InheritsRewarderConfiguration() public view {
        assertEq(rewarder.owner(), address(this));
        assertEq(rewarder.factory(), address(this));
        assertEq(rewarder.deepstate(), DEEPSTATE);
        assertEq(rewarder.rewardToken(), address(rewardToken));
        assertEq(rewarder.token0(), TOKEN0);
        assertEq(rewarder.token1(), TOKEN1);
        assertEq(rewarder.sideEmissionCap(), SIDE_CAP);
    }

    function test_OwnerCanWithdrawEntireRewardBalance() public {
        uint256 expected = rewardToken.balanceOf(address(rewarder));

        vm.expectEmit(true, false, false, true, address(rewarder));
        emit DeepstateRewarderV2.RewardBalanceWithdrawn(alice, expected);
        uint256 withdrawn = rewarder.withdrawRewardBalance(alice);

        assertEq(withdrawn, expected);
        assertEq(rewardToken.balanceOf(address(rewarder)), 0);
        assertEq(rewardToken.balanceOf(alice), expected);
    }

    function test_NonOwnerCannotWithdrawRewardBalance() public {
        uint256 fundingBefore = rewardToken.balanceOf(address(rewarder));

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(alice);
        rewarder.withdrawRewardBalance(alice);

        assertEq(rewardToken.balanceOf(address(rewarder)), fundingBefore);
        assertEq(rewardToken.balanceOf(alice), 0);
    }

    function test_WithdrawRewardBalanceRejectsZeroReceiver() public {
        vm.expectRevert(DeepstateRewarderV2.InvalidReceiver.selector);
        rewarder.withdrawRewardBalance(address(0));
    }

    function test_WithdrawEmptyRewardBalanceReturnsZero() public {
        rewarder.withdrawRewardBalance(alice);

        vm.expectEmit(true, false, false, true, address(rewarder));
        emit DeepstateRewarderV2.RewardBalanceWithdrawn(bob, 0);
        uint256 withdrawn = rewarder.withdrawRewardBalance(bob);

        assertEq(withdrawn, 0);
        assertEq(rewardToken.balanceOf(bob), 0);
    }
}
