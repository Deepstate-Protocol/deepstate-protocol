// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";

import {DeepstateRewarderV2} from "../src/DeepstateRewarderV2.sol";
import {DeepstateToken} from "../src/DeepstateToken.sol";

contract DeepstateRewarderV2Test is Test {
    uint96 internal constant SIDE_CAP = 500_000_000e18;
    address internal constant DEEPSTATE = address(0x1000);
    address internal constant TOKEN0 = address(0x2000);
    address internal constant TOKEN1 = address(0x3000);

    DeepstateToken internal rewardToken;
    DeepstateRewarderV2 internal rewarder;
    address internal alice = makeAddr("alice");

    function setUp() public {
        rewardToken = new DeepstateToken(address(this), "Reward", "RWD");
        rewardToken.grantRole(rewardToken.MINTER_ROLE(), address(this));
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
        assertEq(rewarder.deepstate(), DEEPSTATE);
        assertEq(rewarder.rewardToken(), address(rewardToken));
        assertEq(rewarder.token0(), TOKEN0);
        assertEq(rewarder.token1(), TOKEN1);
        assertEq(rewarder.sideEmissionCap(), SIDE_CAP);
    }

    function test_OwnerCanBurnEntireLiveRewardBalance() public {
        uint256 funding = rewardToken.balanceOf(address(rewarder));

        vm.expectEmit(false, false, false, true, address(rewarder));
        emit DeepstateRewarderV2.RewardBalanceBurned(funding);
        uint256 burned = rewarder.burnBalance();

        assertEq(burned, funding);
        assertEq(rewardToken.balanceOf(address(rewarder)), 0);
        assertEq(rewardToken.totalSupply(), 0);
    }

    function test_NonOwnerCannotBurnRewardBalance() public {
        uint256 fundingBefore = rewardToken.balanceOf(address(rewarder));

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(alice);
        rewarder.burnBalance();

        assertEq(rewardToken.balanceOf(address(rewarder)), fundingBefore);
        assertEq(rewardToken.totalSupply(), fundingBefore);
    }

    function test_BurnBalanceReturnsZeroForEmptyRewarder() public {
        uint256 funding = rewardToken.balanceOf(address(rewarder));
        rewarder.burnBalance();

        vm.expectEmit(false, false, false, true, address(rewarder));
        emit DeepstateRewarderV2.RewardBalanceBurned(0);
        uint256 burned = rewarder.burnBalance();

        assertEq(burned, 0);
        assertEq(funding, uint256(SIDE_CAP) * 2);
        assertEq(rewardToken.balanceOf(address(rewarder)), 0);
        assertEq(rewardToken.totalSupply(), 0);
    }
}
