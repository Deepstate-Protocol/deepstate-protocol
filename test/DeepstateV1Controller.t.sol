// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {DeepstateV1} from "deepstate-contracts/DeepstateV1.sol";

import {DeepstateController} from "../src/DeepstateController.sol";
import {DeepstateV1Controller} from "../src/DeepstateV1Controller.sol";

contract DeepstateV1ControllerTest is Test {
    address internal constant TOKEN0 = address(0x1000);
    address internal constant TOKEN1 = address(0x2000);

    DeepstateV1 internal deepstate;
    DeepstateV1Controller internal controller;

    address internal hookManager = makeAddr("hookManager");
    address internal hook = makeAddr("hook");
    address internal alice = makeAddr("alice");
    address internal feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        deepstate = new DeepstateV1();
        controller = new DeepstateV1Controller(address(this), address(deepstate));
        deepstate.transferOwnership(address(controller));
    }

    function test_ImmutableConfiguration() public view {
        assertEq(controller.owner(), address(this));
        assertEq(address(controller.deepstate()), address(deepstate));
        assertEq(controller.HOOK_MANAGER_ROLE(), 1);
        assertEq(controller.rolesOf(address(this)), 0);
        assertFalse(controller.hasAnyRole(hookManager, controller.HOOK_MANAGER_ROLE()));
        assertEq(deepstate.owner(), address(controller));
    }

    function test_ConstructorValidation() public {
        vm.expectRevert(DeepstateController.InvalidOwner.selector);
        new DeepstateV1Controller(address(0), address(deepstate));

        vm.expectRevert(DeepstateV1Controller.InvalidDeepstate.selector);
        new DeepstateV1Controller(address(this), address(0));

        vm.expectRevert(DeepstateV1Controller.InvalidDeepstate.selector);
        new DeepstateV1Controller(address(this), alice);
    }

    function test_GovernanceCanGrantAndRevokeHookManagerRole() public {
        controller.grantRoles(hookManager, controller.HOOK_MANAGER_ROLE());
        assertTrue(controller.hasAnyRole(hookManager, controller.HOOK_MANAGER_ROLE()));

        controller.revokeRoles(hookManager, controller.HOOK_MANAGER_ROLE());
        assertFalse(controller.hasAnyRole(hookManager, controller.HOOK_MANAGER_ROLE()));
    }

    function test_OnlyGovernanceCanGrantOrRevokeHookManagerRole() public {
        uint256 hookManagerRole = controller.HOOK_MANAGER_ROLE();

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(hookManager);
        controller.grantRoles(hookManager, hookManagerRole);

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(alice);
        controller.revokeRoles(hookManager, hookManagerRole);
    }

    function test_HookManagerCanConfigurePoolHook() public {
        controller.grantRoles(hookManager, controller.HOOK_MANAGER_ROLE());

        vm.prank(hookManager);
        controller.setPoolHookConfig(TOKEN0, TOKEN1, hook, true, false);

        assertEq(deepstate.poolHook(_poolId()), hook);
    }

    function test_HookManagerRolesAreIndependent() public {
        uint256 hookManagerRole = controller.HOOK_MANAGER_ROLE();
        controller.grantRoles(hookManager, hookManagerRole);
        controller.grantRoles(alice, hookManagerRole);
        controller.revokeRoles(hookManager, hookManagerRole);

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(hookManager);
        controller.setPoolHookConfig(TOKEN0, TOKEN1, hook, true, false);

        vm.prank(alice);
        controller.setPoolHookConfig(TOKEN0, TOKEN1, hook, false, true);
        assertEq(deepstate.poolHook(_poolId()), hook);
    }

    function test_GovernanceCanConfigurePoolHookWithoutManager() public {
        controller.setPoolHookConfig(TOKEN0, TOKEN1, hook, false, true);
        assertEq(deepstate.poolHook(_poolId()), hook);

        controller.setPoolHookConfig(TOKEN0, TOKEN1, address(0), false, false);
        assertEq(deepstate.poolHook(_poolId()), address(0));
    }

    function test_RevokedHookManagerImmediatelyLosesHookAccess() public {
        controller.grantRoles(hookManager, controller.HOOK_MANAGER_ROLE());
        controller.revokeRoles(hookManager, controller.HOOK_MANAGER_ROLE());

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(hookManager);
        controller.setPoolHookConfig(TOKEN0, TOKEN1, hook, true, true);

        assertEq(deepstate.poolHook(_poolId()), address(0));
    }

    function test_UnauthorizedAccountCannotConfigurePoolHook() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(alice);
        controller.setPoolHookConfig(TOKEN0, TOKEN1, hook, true, true);
    }

    function test_HookManagerCannotConfigureFeesOrTransferRouterOwnership() public {
        controller.grantRoles(hookManager, controller.HOOK_MANAGER_ROLE());

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(hookManager);
        controller.setDeepstateFeeConfig(feeRecipient, 10);

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(hookManager);
        controller.transferDeepstateOwnership(alice);

        (address recipient, uint16 bps) = deepstate.feeConfig();
        assertEq(recipient, address(0));
        assertEq(bps, 0);
        assertEq(deepstate.owner(), address(controller));
    }

    function test_GovernanceCanConfigureFeesAndRecoverRouterOwnership() public {
        vm.expectEmit(true, false, false, true, address(controller));
        emit DeepstateV1Controller.DeepstateFeeConfigured(feeRecipient, 10);
        controller.setDeepstateFeeConfig(feeRecipient, 10);

        (address recipient, uint16 bps) = deepstate.feeConfig();
        assertEq(recipient, feeRecipient);
        assertEq(bps, 10);

        vm.expectEmit(true, false, false, false, address(controller));
        emit DeepstateV1Controller.DeepstateOwnershipTransferred(alice);
        controller.transferDeepstateOwnership(alice);
        assertEq(deepstate.owner(), alice);
    }

    function test_ControllerCallsFailUntilItOwnsRouter() public {
        DeepstateV1 secondRouter = new DeepstateV1();
        DeepstateV1Controller secondController = new DeepstateV1Controller(address(this), address(secondRouter));
        secondController.grantRoles(hookManager, secondController.HOOK_MANAGER_ROLE());

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(hookManager);
        secondController.setPoolHookConfig(TOKEN0, TOKEN1, hook, true, true);

        vm.expectRevert(Ownable.Unauthorized.selector);
        secondController.setDeepstateFeeConfig(feeRecipient, 10);

        assertEq(secondRouter.poolHook(_poolId()), address(0));
        assertEq(secondRouter.owner(), address(this));
    }

    function test_ControllerOwnerCannotRenounceOwnership() public {
        vm.expectRevert(Ownable.NewOwnerIsZeroAddress.selector);
        controller.renounceOwnership();
    }

    function _poolId() private pure returns (bytes32) {
        return keccak256(abi.encode(TOKEN0, TOKEN1));
    }
}
