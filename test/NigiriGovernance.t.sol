// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {NigiriGovernor} from "../src/NigiriGovernor.sol";
import {NigiriToken} from "../src/NigiriToken.sol";
import {NigiriVault} from "../src/NigiriVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockWETH} from "./mocks/MockWETH.sol";

contract NigiriGovernanceTest is Test {
    uint48 internal constant VOTING_DELAY = 1;
    uint32 internal constant VOTING_PERIOD = 8;
    uint256 internal constant PROPOSAL_THRESHOLD = 0;
    uint256 internal constant QUORUM_NUMERATOR = 4;
    uint48 internal constant VOTE_EXTENSION = 2;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal newAuction = makeAddr("newAuction");
    address internal newMinter = makeAddr("newMinter");

    NigiriToken internal nigiri;
    MockERC20 internal valueToken;
    MockWETH internal wrappedNative;
    NigiriVault internal vault;
    NigiriGovernor internal governor;

    function setUp() public {
        vm.startPrank(deployer);

        nigiri = new NigiriToken(deployer, "Nigiri", "NIGIRI");
        valueToken = new MockERC20("USD Coin", "USDC", 6);
        wrappedNative = new MockWETH();
        vault = new NigiriVault(
            deployer, address(nigiri), address(valueToken), address(wrappedNative), "vNigiri", "vNIGIRI"
        );
        governor = new NigiriGovernor(
            IVotes(address(vault)), VOTING_DELAY, VOTING_PERIOD, PROPOSAL_THRESHOLD, QUORUM_NUMERATOR, VOTE_EXTENSION
        );

        nigiri.setMinter(deployer);
        nigiri.mint(alice, 100e18);
        nigiri.transferOwnership(address(governor));
        vault.transferOwnership(address(governor));

        vm.stopPrank();

        vm.startPrank(alice);
        nigiri.approve(address(vault), type(uint256).max);
        vault.deposit(100e18, alice);
        vault.delegate(alice);
        vm.stopPrank();
    }

    function testVaultSharesBackGovernorOwnershipOfVault() public {
        address[] memory targets = new address[](1);
        targets[0] = address(vault);

        uint256[] memory values = new uint256[](1);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(NigiriVault.setAuction, (newAuction));

        _passProposal(targets, values, calldatas, "set vault auction");

        assertEq(vault.owner(), address(governor));
        assertEq(vault.auction(), newAuction);
    }

    function testGovernorControlsNigiriMinter() public {
        address[] memory targets = new address[](1);
        targets[0] = address(nigiri);

        uint256[] memory values = new uint256[](1);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(NigiriToken.setMinter, (newMinter));

        _passProposal(targets, values, calldatas, "set nigiri minter");

        assertEq(nigiri.owner(), address(governor));
        assertEq(nigiri.minter(), newMinter);

        vm.prank(newMinter);
        nigiri.mint(alice, 1e18);
        assertEq(nigiri.balanceOf(alice), 1e18);

        vm.prank(deployer);
        vm.expectRevert(NigiriToken.NotMinter.selector);
        nigiri.mint(alice, 1e18);
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
