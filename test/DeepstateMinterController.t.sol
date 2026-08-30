// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";

import {DeepstateMinterController} from "../src/DeepstateMinterController.sol";
import {DeepstateToken} from "../src/DeepstateToken.sol";
import {MockSablierLockupLinearV4} from "./mocks/MockSablierLockupLinearV4.sol";

contract DeepstateMinterControllerTest is Test {
    uint256 internal constant MINT_CAP = 20_000_000_000e18;

    DeepstateToken internal deep;
    DeepstateMinterController internal minterController;
    MockSablierLockupLinearV4 internal sablier;

    address internal recipient = makeAddr("recipient");
    address internal mintRecipient = makeAddr("mintRecipient");
    address internal unauthorized = makeAddr("unauthorized");
    address internal newGovernance = makeAddr("newGovernance");

    function setUp() public {
        deep = new DeepstateToken(address(this), "Deepstate", "DEEP");
        sablier = new MockSablierLockupLinearV4();
        minterController =
            new DeepstateMinterController(address(this), address(deep), address(sablier), recipient, MINT_CAP);

        deep.grantRole(deep.MINTER_ROLE(), address(minterController));
    }

    function test_ImmutableConfigurationAndInitialAuthority() public view {
        assertEq(address(minterController.rewardToken()), address(deep));
        assertEq(address(minterController.sablierLockup()), address(sablier));
        assertEq(minterController.recipient(), recipient);
        assertEq(minterController.mintCap(), MINT_CAP);
        assertEq(minterController.RECIPIENT_ALLOCATION_BPS(), 3_000);
        assertEq(minterController.BPS_DENOMINATOR(), 10_000);
        assertEq(minterController.VESTING_DURATION(), 365 days);
        assertEq(minterController.TOKEN_ADMINISTRATION_DURATION(), 2 * 365 days);
        assertEq(minterController.owner(), address(this));
        assertEq(minterController.tokenAdministrationEndsAt(), 0);
        assertFalse(minterController.tokenAdministrationReturned());
        assertTrue(minterController.hasRole(minterController.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(minterController.hasRole(minterController.MINTER_ROLE(), address(this)));
        assertTrue(deep.hasRole(deep.MINTER_ROLE(), address(minterController)));
    }

    function test_ConstructorValidation() public {
        vm.expectRevert(DeepstateMinterController.InvalidOwner.selector);
        new DeepstateMinterController(address(0), address(deep), address(sablier), recipient, MINT_CAP);

        vm.expectRevert(DeepstateMinterController.InvalidRewardToken.selector);
        new DeepstateMinterController(address(this), address(0), address(sablier), recipient, MINT_CAP);

        vm.expectRevert(DeepstateMinterController.InvalidRewardToken.selector);
        new DeepstateMinterController(address(this), unauthorized, address(sablier), recipient, MINT_CAP);

        vm.expectRevert(DeepstateMinterController.InvalidSablierLockup.selector);
        new DeepstateMinterController(address(this), address(deep), address(0), recipient, MINT_CAP);

        vm.expectRevert(DeepstateMinterController.InvalidSablierLockup.selector);
        new DeepstateMinterController(address(this), address(deep), unauthorized, recipient, MINT_CAP);

        vm.expectRevert(DeepstateMinterController.InvalidRecipient.selector);
        new DeepstateMinterController(address(this), address(deep), address(sablier), address(0), MINT_CAP);

        vm.expectRevert(DeepstateMinterController.InvalidMintCap.selector);
        new DeepstateMinterController(address(this), address(deep), address(sablier), recipient, 0);
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

    function test_ActivateTokenAdministrationStartsTwoYearTermAndEnsuresMinterRole() public {
        deep.revokeRole(deep.MINTER_ROLE(), address(minterController));
        deep.grantRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController));

        uint40 expectedEndsAt = uint40(block.timestamp + 2 * 365 days);
        vm.expectEmit(true, false, false, true, address(minterController));
        emit DeepstateMinterController.TokenAdministrationActivated(expectedEndsAt);
        minterController.activateTokenAdministration();

        assertEq(minterController.tokenAdministrationEndsAt(), expectedEndsAt);
        assertFalse(minterController.tokenAdministrationReturned());
        assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController)));
        assertTrue(deep.hasRole(deep.MINTER_ROLE(), address(minterController)));
    }

    function test_RevertActivationWithoutTokenAdminOrByNonOwnerOrTwice() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(unauthorized);
        minterController.activateTokenAdministration();

        vm.expectRevert(DeepstateMinterController.ControllerNotTokenAdmin.selector);
        minterController.activateTokenAdministration();

        deep.grantRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController));
        minterController.activateTokenAdministration();

        vm.expectRevert(DeepstateMinterController.TokenAdministrationAlreadyActivated.selector);
        minterController.activateTokenAdministration();
    }

    function test_OwnerCannotReturnTokenAdministrationBeforeDeadline() public {
        _activateSoleTokenAdministration();
        uint40 endsAt = minterController.tokenAdministrationEndsAt();

        vm.expectRevert(abi.encodeWithSelector(DeepstateMinterController.TokenAdministrationActive.selector, endsAt));
        minterController.returnTokenAdministration();

        assertFalse(minterController.tokenAdministrationReturned());
        assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController)));
        assertEq(deep.defaultAdminCount(), 1);
    }

    function test_AnyoneCanReturnTokenAdministrationAtExactDeadline() public {
        _activateSoleTokenAdministration();
        uint40 endsAt = minterController.tokenAdministrationEndsAt();

        vm.warp(endsAt - 1);
        vm.expectRevert(abi.encodeWithSelector(DeepstateMinterController.TokenAdministrationActive.selector, endsAt));
        vm.prank(unauthorized);
        minterController.returnTokenAdministration();

        vm.warp(endsAt);
        vm.prank(unauthorized);
        minterController.returnTokenAdministration();

        assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController)));
        assertEq(deep.defaultAdminCount(), 1);
    }

    function test_ReturnUsesCurrentOwnerAfterOwnershipTransfer() public {
        _activateSoleTokenAdministration();

        minterController.transferOwnership(newGovernance);
        assertEq(minterController.owner(), newGovernance);
        assertFalse(minterController.hasRole(minterController.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(minterController.hasRole(minterController.DEFAULT_ADMIN_ROLE(), newGovernance));
        assertFalse(minterController.hasRole(minterController.MINTER_ROLE(), address(this)));
        assertTrue(minterController.hasRole(minterController.MINTER_ROLE(), newGovernance));

        vm.warp(minterController.tokenAdministrationEndsAt());
        vm.prank(unauthorized);
        minterController.returnTokenAdministration();

        assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), newGovernance));
        assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController)));
        assertEq(deep.defaultAdminCount(), 1);
    }

    function test_OwnerMintAuthorityRotatesWithOwnership() public {
        DeepstateMinterController ownerController =
            new DeepstateMinterController(address(this), address(deep), address(sablier), recipient, MINT_CAP);
        deep.grantRole(deep.MINTER_ROLE(), address(ownerController));

        assertTrue(ownerController.hasRole(ownerController.MINTER_ROLE(), address(this)));
        ownerController.mint(mintRecipient, 100e18);
        ownerController.transferOwnership(newGovernance);

        assertFalse(ownerController.hasRole(ownerController.MINTER_ROLE(), address(this)));
        assertTrue(ownerController.hasRole(ownerController.MINTER_ROLE(), newGovernance));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), ownerController.MINTER_ROLE()
            )
        );
        ownerController.mint(mintRecipient, 100e18);

        vm.prank(newGovernance);
        ownerController.mint(mintRecipient, 100e18);

        assertEq(deep.balanceOf(mintRecipient), 200e18);
        assertEq(deep.balanceOf(address(sablier)), 60e18);
    }

    function test_TwoStepOwnershipHandoverSynchronizesControllerAdmin() public {
        vm.prank(newGovernance);
        minterController.requestOwnershipHandover();
        minterController.completeOwnershipHandover(newGovernance);

        assertEq(minterController.owner(), newGovernance);
        assertFalse(minterController.hasRole(minterController.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(minterController.hasRole(minterController.DEFAULT_ADMIN_ROLE(), newGovernance));
        assertFalse(minterController.hasRole(minterController.MINTER_ROLE(), address(this)));
        assertTrue(minterController.hasRole(minterController.MINTER_ROLE(), newGovernance));
    }

    function test_TransferOwnershipToCurrentOwnerPreservesRoles() public {
        minterController.transferOwnership(address(this));

        assertEq(minterController.owner(), address(this));
        assertTrue(minterController.hasRole(minterController.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(minterController.hasRole(minterController.MINTER_ROLE(), address(this)));

        minterController.mint(mintRecipient, 100e18);
        assertEq(deep.balanceOf(mintRecipient), 100e18);
    }

    function test_ControllerOwnerCannotRenounceOrLoseDefaultAdmin() public {
        bytes32 controllerAdminRole = minterController.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(Ownable.NewOwnerIsZeroAddress.selector);
        minterController.renounceOwnership();

        vm.expectRevert(DeepstateMinterController.OwnerMustRetainDefaultAdmin.selector);
        minterController.revokeRole(controllerAdminRole, address(this));

        vm.expectRevert(DeepstateMinterController.OwnerMustRetainDefaultAdmin.selector);
        minterController.renounceRole(controllerAdminRole, address(this));

        vm.expectRevert(DeepstateMinterController.OwnerMustRetainDefaultAdmin.selector);
        minterController.grantRole(controllerAdminRole, unauthorized);
    }

    function test_RevertReturnBeforeActivationAfterReturnOrWithoutTokenAdmin() public {
        vm.expectRevert(DeepstateMinterController.TokenAdministrationNotActive.selector);
        minterController.returnTokenAdministration();

        _activateSoleTokenAdministration();
        bytes32 tokenAdminRole = deep.DEFAULT_ADMIN_ROLE();
        vm.prank(address(minterController));
        deep.grantRole(tokenAdminRole, address(this));
        deep.revokeRole(tokenAdminRole, address(minterController));
        vm.warp(minterController.tokenAdministrationEndsAt());

        vm.expectRevert(DeepstateMinterController.ControllerNotTokenAdmin.selector);
        minterController.returnTokenAdministration();

        deep.grantRole(tokenAdminRole, address(minterController));
        minterController.returnTokenAdministration();

        vm.expectRevert(DeepstateMinterController.TokenAdministrationAlreadyReturned.selector);
        minterController.returnTokenAdministration();
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

    function test_MintCapIncludesExistingRequestedAndVestedSupply() public {
        DeepstateMinterController cappedController = _newControllerWithCap(130e18);

        deep.grantRole(deep.MINTER_ROLE(), address(this));
        deep.mint(unauthorized, 5);

        vm.expectRevert(abi.encodeWithSelector(DeepstateMinterController.MintCapExceeded.selector, 130e18, 130e18 + 5));
        cappedController.mint(mintRecipient, 100e18);

        assertEq(deep.totalSupply(), 5);
        assertEq(sablier.nextStreamId(), 1);
    }

    function test_BurnReopensMintCapacity() public {
        DeepstateMinterController cappedController = _newControllerWithCap(130e18);

        cappedController.mint(mintRecipient, 100e18);
        assertEq(deep.totalSupply(), 130e18);

        vm.expectRevert(abi.encodeWithSelector(DeepstateMinterController.MintCapExceeded.selector, 130e18, 130e18 + 5));
        cappedController.mint(mintRecipient, 4);

        vm.prank(mintRecipient);
        deep.burn(5);
        cappedController.mint(mintRecipient, 4);

        assertEq(deep.totalSupply(), 130e18);
        assertEq(deep.balanceOf(mintRecipient), 100e18 - 1);
        assertEq(deep.balanceOf(address(sablier)), 30e18 + 1);
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

    function test_ControllerMinterCanRenounceRole() public {
        bytes32 minterRole = minterController.MINTER_ROLE();
        minterController.grantRole(minterRole, unauthorized);

        vm.prank(unauthorized);
        minterController.renounceRole(minterRole, unauthorized);

        assertFalse(minterController.hasRole(minterRole, unauthorized));
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
        uint256 maximumAmount = Math.mulDiv(MINT_CAP, 10_000, 13_000);
        uint256 amount = bound(uint256(rawAmount), 4, maximumAmount);
        uint256 expectedVesting = Math.mulDiv(amount, 3_000, 10_000);

        uint256 streamId = minterController.mint(mintRecipient, amount);

        assertEq(deep.balanceOf(mintRecipient), amount);
        assertEq(deep.balanceOf(address(sablier)), expectedVesting);
        assertEq(deep.totalSupply(), amount + expectedVesting);
        assertEq(sablier.stream(streamId).depositAmount, expectedVesting);
    }

    function _activateSoleTokenAdministration() internal {
        deep.grantRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController));
        minterController.activateTokenAdministration();
        deep.renounceRole(deep.DEFAULT_ADMIN_ROLE(), address(this));

        assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController)));
        assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(this)));
        assertEq(deep.defaultAdminCount(), 1);
    }

    function _newControllerWithCap(uint256 cap) internal returns (DeepstateMinterController controller) {
        controller = new DeepstateMinterController(address(this), address(deep), address(sablier), recipient, cap);
        deep.grantRole(deep.MINTER_ROLE(), address(controller));
        controller.grantRole(controller.MINTER_ROLE(), address(this));
    }
}
