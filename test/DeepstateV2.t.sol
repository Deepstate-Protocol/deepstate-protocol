// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {DeepstateTokenV2 as DeepstateToken} from "../src/DeepstateTokenV2.sol";
import {DeepstateGovernorV2 as DeepstateGovernor} from "../src/DeepstateGovernorV2.sol";

contract DeepstateTokenAndGovernorTest is Test {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal guardian = makeAddr("guardian");

    DeepstateToken internal token;
    DeepstateGovernor internal governor;

    function setUp() public {
        token = new DeepstateToken(address(this), 3_000_000_000e18);
        token.grantRole(token.MINTER_ROLE(), address(this));
        token.mint(alice, 100e18);
        governor = new DeepstateGovernor(IVotes(address(token)), 0, 1 days, 1 days, 1, 10, 1 days);
    }

    function testRecipientsSelfDelegateOnMintAndFirstTransfer() public {
        assertEq(token.delegates(alice), alice);
        assertEq(token.getVotes(alice), 100e18);

        vm.prank(alice);
        token.transfer(bob, 25e18);

        assertEq(token.delegates(bob), bob);
        assertEq(token.getVotes(alice), 75e18);
        assertEq(token.getVotes(bob), 25e18);
    }

    function testExplicitDelegationIsPreservedAcrossReceipts() public {
        vm.prank(alice);
        token.delegate(bob);

        token.mint(alice, 10e18);

        assertEq(token.delegates(alice), bob);
        assertEq(token.getVotes(alice), 0);
        assertEq(token.getVotes(bob), 110e18);
    }

    function testOnlyAdminCanRaiseCapAndCapCannotFall() public {
        vm.prank(alice);
        vm.expectRevert();
        token.raiseSupplyCap(4_000_000_000e18);

        vm.expectRevert(
            abi.encodeWithSelector(DeepstateToken.SupplyCapNotRaised.selector, 3_000_000_000e18, 3_000_000_000e18)
        );
        token.raiseSupplyCap(3_000_000_000e18);

        token.raiseSupplyCap(4_000_000_000e18);
        assertEq(token.supplyCap(), 4_000_000_000e18);
    }

    function testMinterCannotExceedCap() public {
        token.grantRole(token.MINTER_ROLE(), bob);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(DeepstateToken.SupplyCapExceeded.selector, 3_000_000_000e18, 3_000_000_001e18)
        );
        token.mint(bob, 3_000_000_000e18 - 100e18 + 1e18);
    }

    function testGovernanceCanAddAndRemoveGuardian() public {
        vm.warp(block.timestamp + 1);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _guardianProposal(true);
        string memory description = "Add guardian";

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        vm.warp(governor.proposalSnapshot(proposalId) + 1);
        vm.prank(alice);
        governor.castVote(proposalId, 1);
        vm.warp(governor.proposalDeadline(proposalId) + 1);
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));

        assertTrue(governor.isGuardian(guardian));

        address[] memory secondTargets = new address[](1);
        secondTargets[0] = bob;
        uint256[] memory secondValues = new uint256[](1);
        bytes[] memory secondCalldatas = new bytes[](1);
        secondCalldatas[0] = "";
        string memory secondDescription = "Cancelable proposal";

        vm.prank(alice);
        uint256 secondId = governor.propose(secondTargets, secondValues, secondCalldatas, secondDescription);
        vm.warp(governor.proposalSnapshot(secondId) + 1);
        vm.prank(guardian);
        governor.cancel(secondTargets, secondValues, secondCalldatas, keccak256(bytes(secondDescription)));

        assertEq(uint8(governor.state(secondId)), 2);
    }

    function testNoGuardianIsConfiguredAtDeployment() public view {
        assertFalse(governor.isGuardian(guardian));
    }

    function _guardianProposal(bool enabled)
        private
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        targets[0] = address(governor);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(DeepstateGovernor.setGuardian, (guardian, enabled));
    }
}
