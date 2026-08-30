// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

import {DeepstateMinterController} from "../src/DeepstateMinterController.sol";
import {DeepstateToken} from "../src/DeepstateToken.sol";
import {MockSablierLockupLinearV4} from "./mocks/MockSablierLockupLinearV4.sol";

contract DeepstateMinterControllerTest is Test {
    DeepstateToken internal deep;
    DeepstateMinterController internal minterController;
    MockSablierLockupLinearV4 internal sablier;

    address internal recipient = makeAddr("recipient");
    address internal mintRecipient = makeAddr("mintRecipient");
    address internal unauthorized = makeAddr("unauthorized");

    function setUp() public {
        deep = new DeepstateToken(address(this), "Deepstate", "DEEP");
        sablier = new MockSablierLockupLinearV4();
        minterController = new DeepstateMinterController(address(this), address(deep), address(sablier), recipient);

        deep.grantRole(deep.MINTER_ROLE(), address(minterController));
        minterController.grantRole(minterController.MINTER_ROLE(), address(this));
    }

    function test_ImmutableConfigurationAndInitialAuthority() public view {
        assertEq(address(minterController.rewardToken()), address(deep));
        assertEq(address(minterController.sablierLockup()), address(sablier));
        assertEq(minterController.recipient(), recipient);
        assertEq(minterController.RECIPIENT_ALLOCATION_BPS(), 3_000);
        assertEq(minterController.BPS_DENOMINATOR(), 10_000);
        assertEq(minterController.VESTING_DURATION(), 365 days);
        assertTrue(minterController.hasRole(minterController.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(minterController.hasRole(minterController.MINTER_ROLE(), address(this)));
        assertTrue(deep.hasRole(deep.MINTER_ROLE(), address(minterController)));
    }

    function test_ConstructorValidation() public {
        vm.expectRevert(DeepstateMinterController.InvalidAdmin.selector);
        new DeepstateMinterController(address(0), address(deep), address(sablier), recipient);

        vm.expectRevert(DeepstateMinterController.InvalidRewardToken.selector);
        new DeepstateMinterController(address(this), address(0), address(sablier), recipient);

        vm.expectRevert(DeepstateMinterController.InvalidRewardToken.selector);
        new DeepstateMinterController(address(this), unauthorized, address(sablier), recipient);

        vm.expectRevert(DeepstateMinterController.InvalidSablierLockup.selector);
        new DeepstateMinterController(address(this), address(deep), address(0), recipient);

        vm.expectRevert(DeepstateMinterController.InvalidSablierLockup.selector);
        new DeepstateMinterController(address(this), address(deep), unauthorized, recipient);

        vm.expectRevert(DeepstateMinterController.InvalidRecipient.selector);
        new DeepstateMinterController(address(this), address(deep), address(sablier), address(0));
    }

    function test_MintCreatesExactNonCancelableOneYearStream() public {
        uint256 amount = 100_000_000e18;
        uint256 vestingAmount = 30_000_000e18;

        vm.expectEmit(true, true, true, true, address(minterController));
        emit DeepstateMinterController.MintedWithVesting(
            address(this), mintRecipient, amount, recipient, vestingAmount, 1
        );
        uint256 streamId = minterController.mint(mintRecipient, amount);

        assertEq(streamId, 1);
        assertEq(deep.balanceOf(mintRecipient), amount);
        assertEq(deep.balanceOf(address(sablier)), vestingAmount);
        assertEq(deep.balanceOf(address(minterController)), 0);
        assertEq(deep.totalSupply(), amount + vestingAmount);
        assertEq(deep.allowance(address(minterController), address(sablier)), 0);

        MockSablierLockupLinearV4.Stream memory created = sablier.stream(streamId);
        assertEq(created.funder, address(minterController));
        assertEq(created.sender, address(minterController));
        assertEq(created.recipient, recipient);
        assertEq(created.token, address(deep));
        assertEq(created.depositAmount, vestingAmount);
        assertFalse(created.cancelable);
        assertFalse(created.transferable);
        assertEq(created.shape, "Deepstate allocation");
        assertEq(created.startUnlockAmount, 0);
        assertEq(created.cliffUnlockAmount, 0);
        assertEq(created.granularity, 0);
        assertEq(created.cliffDuration, 0);
        assertEq(created.totalDuration, 365 days);
    }

    function test_EachMintCreatesAnIndependentStream() public {
        uint256 firstStreamId = minterController.mint(mintRecipient, 100e18);
        vm.warp(block.timestamp + 30 days);
        uint256 secondStreamId = minterController.mint(mintRecipient, 200e18);

        assertEq(firstStreamId, 1);
        assertEq(secondStreamId, 2);
        assertEq(sablier.stream(firstStreamId).depositAmount, 30e18);
        assertEq(sablier.stream(secondStreamId).depositAmount, 60e18);
        assertEq(deep.balanceOf(mintRecipient), 300e18);
        assertEq(deep.balanceOf(address(sablier)), 90e18);
    }

    function test_MintRoundsRecipientAllocationDown() public {
        minterController.mint(mintRecipient, 4);

        assertEq(deep.balanceOf(mintRecipient), 4);
        assertEq(deep.balanceOf(address(sablier)), 1);
        assertEq(deep.totalSupply(), 5);
    }

    function test_MintPreservesPreexistingControllerBalance() public {
        deep.grantRole(deep.MINTER_ROLE(), address(this));
        deep.mint(address(minterController), 11);

        minterController.mint(mintRecipient, 100e18);

        assertEq(deep.balanceOf(address(minterController)), 11);
        assertEq(deep.allowance(address(minterController), address(sablier)), 0);
    }

    function test_RevertWhenCallerLacksControllerMinterRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, minterController.MINTER_ROLE()
            )
        );
        vm.prank(unauthorized);
        minterController.mint(mintRecipient, 100e18);
    }

    function test_AdminCanGrantAndRevokeControllerMinterRole() public {
        minterController.grantRole(minterController.MINTER_ROLE(), unauthorized);
        vm.prank(unauthorized);
        minterController.mint(mintRecipient, 100e18);

        minterController.revokeRole(minterController.MINTER_ROLE(), unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, minterController.MINTER_ROLE()
            )
        );
        vm.prank(unauthorized);
        minterController.mint(mintRecipient, 100e18);
    }

    function test_RevertWhenNonAdminChangesMinterRole() public {
        bytes32 minterRole = minterController.MINTER_ROLE();
        bytes32 adminRole = minterController.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, adminRole)
        );
        vm.prank(unauthorized);
        minterController.grantRole(minterRole, unauthorized);
    }

    function test_RevertForZeroMintRecipientOrDustAmount() public {
        vm.expectRevert(DeepstateMinterController.InvalidMintRecipient.selector);
        minterController.mint(address(0), 100e18);

        vm.expectRevert(DeepstateMinterController.MintAmountTooSmall.selector);
        minterController.mint(mintRecipient, 3);

        assertEq(deep.totalSupply(), 0);
        assertEq(sablier.nextStreamId(), 1);
    }

    function test_RevertWhenVestingAmountExceedsSablierUint128Limit() public {
        uint256 amount = Math.mulDiv(uint256(type(uint128).max) + 1, 10_000, 3_000, Math.Rounding.Ceil);
        uint256 vestingAmount = Math.mulDiv(amount, 3_000, 10_000);

        vm.expectRevert(abi.encodeWithSelector(DeepstateMinterController.VestingAmountTooLarge.selector, vestingAmount));
        minterController.mint(mintRecipient, amount);
    }

    function test_MissingTokenMinterRoleRevertsAtomically() public {
        deep.revokeRole(deep.MINTER_ROLE(), address(minterController));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(minterController), deep.MINTER_ROLE()
            )
        );
        minterController.mint(mintRecipient, 100e18);

        assertEq(deep.totalSupply(), 0);
        assertEq(sablier.nextStreamId(), 1);
    }

    function test_SablierRevertRollsBackBothMints() public {
        sablier.setRevertCreate(true);

        vm.expectRevert(MockSablierLockupLinearV4.CreateReverted.selector);
        minterController.mint(mintRecipient, 100e18);

        assertEq(deep.totalSupply(), 0);
        assertEq(deep.balanceOf(mintRecipient), 0);
        assertEq(deep.balanceOf(address(minterController)), 0);
        assertEq(deep.allowance(address(minterController), address(sablier)), 0);
        assertEq(sablier.nextStreamId(), 1);
    }

    function test_SablierCannotReenterEvenWhenIncorrectlyGrantedMinterRole() public {
        minterController.grantRole(minterController.MINTER_ROLE(), address(sablier));
        sablier.setReentry(
            address(minterController), abi.encodeCall(DeepstateMinterController.mint, (mintRecipient, 100e18))
        );

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        minterController.mint(mintRecipient, 100e18);

        assertEq(deep.totalSupply(), 0);
        assertEq(sablier.nextStreamId(), 1);
    }

    function test_MissingSablierTokenPullRollsBackBothMintsAndStream() public {
        sablier.setSkipTokenPull(true);

        vm.expectRevert(abi.encodeWithSelector(DeepstateMinterController.StreamFundingMismatch.selector, 0, 30e18));
        minterController.mint(mintRecipient, 100e18);

        assertEq(deep.totalSupply(), 0);
        assertEq(deep.balanceOf(mintRecipient), 0);
        assertEq(deep.balanceOf(address(minterController)), 0);
        assertEq(deep.allowance(address(minterController), address(sablier)), 0);
        assertEq(sablier.nextStreamId(), 1);
    }

    function testFuzz_MintAlwaysCreatesExactAdditionalAllocation(uint128 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 4, type(uint96).max);
        uint256 expectedVesting = Math.mulDiv(amount, 3_000, 10_000);

        uint256 streamId = minterController.mint(mintRecipient, amount);

        assertEq(deep.balanceOf(mintRecipient), amount);
        assertEq(deep.balanceOf(address(sablier)), expectedVesting);
        assertEq(deep.totalSupply(), amount + expectedVesting);
        assertEq(sablier.stream(streamId).depositAmount, expectedVesting);
    }
}
