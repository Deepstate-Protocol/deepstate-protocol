// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeepstateGovernor} from "../src/DeepstateGovernor.sol";
import {DeepstateToken} from "../src/DeepstateToken.sol";
import {DeepstateVault} from "../src/DeepstateVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockWETH} from "./mocks/MockWETH.sol";

contract DeepstateGovernanceTest is Test {
    uint48 internal constant VOTING_DELAY = 1;
    uint32 internal constant VOTING_PERIOD = 8;
    uint256 internal constant PROPOSAL_THRESHOLD = 0;
    uint256 internal constant QUORUM_NUMERATOR = 4;
    uint48 internal constant VOTE_EXTENSION = 2;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal newAuction = makeAddr("newAuction");
    address internal newMinter = makeAddr("newMinter");

    DeepstateToken internal deepstate;
    MockERC20 internal valueToken;
    MockWETH internal wrappedNative;
    DeepstateVault internal vault;
    DeepstateGovernor internal governor;

    function setUp() public {
        vm.startPrank(deployer);

        deepstate = new DeepstateToken(deployer, "Deepstate", "DEEP");
        valueToken = new MockERC20("USD Coin", "USDC", 6);
        wrappedNative = new MockWETH();
        vault = new DeepstateVault(
            deployer, address(deepstate), address(valueToken), address(wrappedNative), "vDeep", "vDEEP"
        );
        governor = new DeepstateGovernor(
            IERC20(address(vault)), VOTING_DELAY, VOTING_PERIOD, PROPOSAL_THRESHOLD, QUORUM_NUMERATOR, VOTE_EXTENSION
        );

        deepstate.setMinter(deployer);
        deepstate.mint(alice, 100e18);
        deepstate.transferOwnership(address(governor));
        vault.transferOwnership(address(governor));

        vm.stopPrank();

        vm.startPrank(alice);
        deepstate.approve(address(vault), type(uint256).max);
        vault.deposit(100e18, alice);
        vault.approve(address(governor), type(uint256).max);
        governor.enterGovernance(100e18);
        governor.delegate(alice);
        vm.stopPrank();
    }

    function testEnterExitGovernanceEscrowsVaultSharesOneToOne() public {
        assertEq(vault.balanceOf(address(governor)), 100e18);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(governor.balanceOf(alice), 100e18);
        assertEq(governor.totalSupply(), 100e18);
        assertEq(governor.delegates(alice), alice);
        assertEq(governor.getVotes(alice), 100e18);

        vm.prank(alice);
        governor.exitGovernance(40e18);

        assertEq(vault.balanceOf(address(governor)), 60e18);
        assertEq(vault.balanceOf(alice), 40e18);
        assertEq(governor.balanceOf(alice), 60e18);
        assertEq(governor.totalSupply(), 60e18);
        assertEq(governor.getVotes(alice), 60e18);

        vm.startPrank(alice);
        vault.approve(address(governor), 40e18);
        governor.enterGovernance(40e18);
        vm.stopPrank();

        assertEq(vault.balanceOf(address(governor)), 100e18);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(governor.balanceOf(alice), 100e18);
        assertEq(governor.totalSupply(), 100e18);
        assertEq(governor.getVotes(alice), 100e18);
    }

    function testVaultSharesBackGovernorOwnershipOfVault() public {
        address[] memory targets = new address[](1);
        targets[0] = address(vault);

        uint256[] memory values = new uint256[](1);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(DeepstateVault.setAuction, (newAuction));

        _passProposal(targets, values, calldatas, "set vault auction");

        assertEq(vault.owner(), address(governor));
        assertEq(vault.auction(), newAuction);
    }

    function testGovernorControlsDeepstateMinter() public {
        address[] memory targets = new address[](1);
        targets[0] = address(deepstate);

        uint256[] memory values = new uint256[](1);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(DeepstateToken.setMinter, (newMinter));

        _passProposal(targets, values, calldatas, "set deepstate minter");

        assertEq(deepstate.owner(), address(governor));
        assertEq(deepstate.minter(), newMinter);

        vm.prank(newMinter);
        deepstate.mint(alice, 1e18);
        assertEq(deepstate.balanceOf(alice), 1e18);

        vm.prank(deployer);
        vm.expectRevert(DeepstateToken.NotMinter.selector);
        deepstate.mint(alice, 1e18);
    }

    function _passProposal(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal returns (uint256 proposalId) {
        vm.roll(block.number + 1);

        vm.prank(alice);
        proposalId = governor.propose(targets, values, calldatas, description);

        vm.roll(block.number + governor.votingDelay() + 1);

        vm.prank(alice);
        governor.castVote(proposalId, 1);

        vm.roll(governor.proposalDeadline(proposalId) + 1);

        governor.execute(targets, values, calldatas, keccak256(bytes(description)));
    }
}
