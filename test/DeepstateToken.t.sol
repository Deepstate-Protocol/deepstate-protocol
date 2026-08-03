// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Test} from "forge-std/Test.sol";

import {DeepstateToken} from "../src/DeepstateToken.sol";

contract DeepstateTokenTest is Test {
    address internal owner = makeAddr("owner");
    address internal minter = makeAddr("minter");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    DeepstateToken internal deepstate;

    function setUp() public {
        deepstate = new DeepstateToken(owner, "Deepstate", "DEEP");
    }

    function testMetadataAndInitialAdmin() public view {
        assertEq(deepstate.name(), "Deepstate");
        assertEq(deepstate.symbol(), "DEEP");
        assertEq(deepstate.decimals(), 18);
        assertTrue(deepstate.hasRole(deepstate.DEFAULT_ADMIN_ROLE(), owner));
        assertEq(deepstate.getRoleAdmin(deepstate.MINTER_ROLE()), deepstate.DEFAULT_ADMIN_ROLE());
        assertEq(deepstate.totalSupply(), 0);
    }

    function testConstructorRejectsZeroAdmin() public {
        vm.expectRevert(DeepstateToken.ZeroAddress.selector);
        new DeepstateToken(address(0), "Deepstate", "DEEP");
    }

    function testOnlyAdminCanGrantAndRevokeMinterRole() public {
        bytes32 minterRole = deepstate.MINTER_ROLE();
        bytes32 adminRole = deepstate.DEFAULT_ADMIN_ROLE();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, adminRole)
        );
        deepstate.grantRole(minterRole, minter);

        vm.prank(owner);
        deepstate.grantRole(minterRole, minter);
        assertTrue(deepstate.hasRole(minterRole, minter));

        vm.prank(owner);
        deepstate.revokeRole(minterRole, minter);
        assertFalse(deepstate.hasRole(minterRole, minter));
    }

    function testMultipleMintersCanMintAndRevocationStopsMinting() public {
        bytes32 minterRole = deepstate.MINTER_ROLE();

        vm.prank(owner);
        deepstate.grantRole(minterRole, minter);
        vm.prank(owner);
        deepstate.grantRole(minterRole, bob);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, minterRole)
        );
        deepstate.mint(alice, 100e18);

        vm.prank(minter);
        vm.expectRevert(DeepstateToken.ZeroAddress.selector);
        deepstate.mint(address(0), 100e18);

        vm.prank(minter);
        deepstate.mint(alice, 100e18);
        vm.prank(bob);
        deepstate.mint(alice, 50e18);

        assertEq(deepstate.balanceOf(alice), 150e18);
        assertEq(deepstate.totalSupply(), 150e18);

        vm.prank(owner);
        deepstate.revokeRole(minterRole, minter);
        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, minter, minterRole)
        );
        deepstate.mint(alice, 1);
    }

    function testBurnReducesBalanceAndSupply() public {
        vm.startPrank(owner);
        deepstate.grantRole(deepstate.MINTER_ROLE(), owner);
        deepstate.mint(alice, 100e18);
        vm.stopPrank();

        vm.prank(alice);
        deepstate.burn(30e18);

        assertEq(deepstate.balanceOf(alice), 70e18);
        assertEq(deepstate.totalSupply(), 70e18);
    }

    function testTransfersAndAllowancesUseOZERC20Behavior() public {
        vm.startPrank(owner);
        deepstate.grantRole(deepstate.MINTER_ROLE(), owner);
        deepstate.mint(alice, 100e18);
        vm.stopPrank();

        vm.prank(alice);
        deepstate.approve(bob, 40e18);

        vm.prank(bob);
        deepstate.transferFrom(alice, bob, 25e18);

        assertEq(deepstate.allowance(alice, bob), 15e18);
        assertEq(deepstate.balanceOf(alice), 75e18);
        assertEq(deepstate.balanceOf(bob), 25e18);
    }
}
