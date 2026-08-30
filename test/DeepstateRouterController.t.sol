// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {DeepstateV1} from "deepstate-contracts/DeepstateV1.sol";

import {DeepstateRouterController} from "../src/DeepstateRouterController.sol";

contract DeepstateRouterControllerTest is Test {
    address internal constant TOKEN0 = address(0x1000);
    address internal constant TOKEN1 = address(0x2000);

    DeepstateV1 internal deepstate;
    DeepstateRouterController internal controller;

    address internal hookManager = makeAddr("hookManager");
    address internal hook = makeAddr("hook");
    address internal alice = makeAddr("alice");
    address internal feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        deepstate = new DeepstateV1();
        controller = new DeepstateRouterController(address(this), address(deepstate));
        deepstate.transferOwnership(address(controller));
    }

    function test_ImmutableConfiguration() public view {
        assertEq(controller.owner(), address(this));
        assertEq(address(controller.deepstate()), address(deepstate));
        assertEq(controller.hookManager(), address(0));
        assertEq(deepstate.owner(), address(controller));
    }

    function test_ConstructorValidation() public {
        vm.expectRevert(DeepstateRouterController.InvalidOwner.selector);
        new DeepstateRouterController(address(0), address(deepstate));

        vm.expectRevert(DeepstateRouterController.InvalidDeepstate.selector);
        new DeepstateRouterController(address(this), address(0));

        vm.expectRevert(DeepstateRouterController.InvalidDeepstate.selector);
        new DeepstateRouterController(address(this), alice);
    }

    function test_GovernanceCanSetAndRevokeHookManager() public {
        vm.expectEmit(true, true, false, false, address(controller));
        emit DeepstateRouterController.HookManagerSet(address(0), hookManager);
        controller.setHookManager(hookManager);
        assertEq(controller.hookManager(), hookManager);

        vm.expectEmit(true, true, false, false, address(controller));
        emit DeepstateRouterController.HookManagerSet(hookManager, address(0));
        controller.setHookManager(address(0));
        assertEq(controller.hookManager(), address(0));
    }

    function test_OnlyGovernanceCanSetHookManager() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(hookManager);
        controller.setHookManager(hookManager);

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(alice);
        controller.setHookManager(alice);
    }

    function test_HookManagerCanConfigurePoolHook() public {
        controller.setHookManager(hookManager);

        vm.prank(hookManager);
        controller.setPoolHookConfig(TOKEN0, TOKEN1, hook, true, false);

        assertEq(deepstate.poolHook(_poolId()), hook);
    }

    function test_GovernanceCanConfigurePoolHookWithoutManager() public {
        controller.setPoolHookConfig(TOKEN0, TOKEN1, hook, false, true);
        assertEq(deepstate.poolHook(_poolId()), hook);

        controller.setPoolHookConfig(TOKEN0, TOKEN1, address(0), false, false);
        assertEq(deepstate.poolHook(_poolId()), address(0));
    }

    function test_RevokedHookManagerImmediatelyLosesHookAccess() public {
        controller.setHookManager(hookManager);
        controller.setHookManager(address(0));

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
        controller.setHookManager(hookManager);

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
        emit DeepstateRouterController.DeepstateFeeConfigured(feeRecipient, 10);
        controller.setDeepstateFeeConfig(feeRecipient, 10);

        (address recipient, uint16 bps) = deepstate.feeConfig();
        assertEq(recipient, feeRecipient);
        assertEq(bps, 10);

        vm.expectEmit(true, false, false, false, address(controller));
        emit DeepstateRouterController.DeepstateOwnershipTransferred(alice);
        controller.transferDeepstateOwnership(alice);
        assertEq(deepstate.owner(), alice);
    }

    function test_ControllerCallsFailUntilItOwnsRouter() public {
        DeepstateV1 secondRouter = new DeepstateV1();
        DeepstateRouterController secondController = new DeepstateRouterController(address(this), address(secondRouter));
        secondController.setHookManager(hookManager);

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(hookManager);
        secondController.setPoolHookConfig(TOKEN0, TOKEN1, hook, true, true);

        vm.expectRevert(Ownable.Unauthorized.selector);
        secondController.setDeepstateFeeConfig(feeRecipient, 10);

        assertEq(secondRouter.poolHook(_poolId()), address(0));
        assertEq(secondRouter.owner(), address(this));
    }

    function _poolId() private pure returns (bytes32) {
        return keccak256(abi.encode(TOKEN0, TOKEN1));
    }
}
