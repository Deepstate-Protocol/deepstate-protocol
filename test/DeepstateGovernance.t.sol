// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {DeepstateGovernor} from "../src/DeepstateGovernor.sol";
import {DeepstateToken} from "../src/DeepstateToken.sol";
import {DeepstateVault} from "../src/DeepstateVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract BlockClockVotes {
    function clock() external view returns (uint48) {
        return uint48(block.number);
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=blocknumber&from=default";
    }
}

contract IncorrectTimestampVotes {
    function clock() external view returns (uint48) {
        return uint48(block.timestamp + 1);
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=timestamp";
    }
}

contract MissingClockVotes {}

contract MissingModeVotes {
    function clock() external view returns (uint48) {
        return uint48(block.timestamp);
    }
}

contract DeepstateGovernanceTest is Test {
    uint48 internal constant GOVERNANCE_START_DELAY = 15 days;
    uint48 internal constant VOTING_DELAY = 3 days;
    uint32 internal constant VOTING_PERIOD = 1 weeks;
    uint256 internal constant PROPOSAL_THRESHOLD_NUMERATOR = 1;
    uint256 internal constant QUORUM_NUMERATOR = 10;
    uint48 internal constant VOTE_EXTENSION = 1 days;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal newVaultOwner = makeAddr("newVaultOwner");
    address internal newMinter = makeAddr("newMinter");

    DeepstateToken internal deepstate;
    MockERC20 internal valueToken;
    DeepstateVault internal vault;
    DeepstateGovernor internal governor;
    uint48 internal governanceDeployedAt;

    function setUp() public {
        vm.startPrank(deployer);

        deepstate = new DeepstateToken(deployer, "Deepstate", "DEEP");
        valueToken = new MockERC20("USDG", "USDG", 6);
        vault = new DeepstateVault(deployer, address(deepstate), address(valueToken), "Deepstate Governance", "STATE");
        governanceDeployedAt = uint48(block.timestamp);
        governor = new DeepstateGovernor(
            IVotes(address(vault)),
            GOVERNANCE_START_DELAY,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD_NUMERATOR,
            QUORUM_NUMERATOR,
            VOTE_EXTENSION
        );

        bytes32 minterRole = deepstate.MINTER_ROLE();
        deepstate.grantRole(minterRole, deployer);
        deepstate.mint(alice, 100e18);
        deepstate.mint(bob, 100e18);
        deepstate.revokeRole(minterRole, deployer);
        deepstate.grantRole(deepstate.DEFAULT_ADMIN_ROLE(), address(governor));
        deepstate.renounceRole(deepstate.DEFAULT_ADMIN_ROLE(), deployer);
        vault.transferOwnership(address(governor));

        vm.stopPrank();

        vm.startPrank(alice);
        deepstate.approve(address(vault), type(uint256).max);
        vault.deposit(100e18, alice);
        vm.stopPrank();

        vm.prank(bob);
        deepstate.approve(address(vault), type(uint256).max);
    }

    function testVaultSharesAreStateGovernanceVotes() public view {
        assertEq(vault.name(), "Deepstate Governance");
        assertEq(vault.symbol(), "STATE");
        assertEq(vault.balanceOf(alice), 100e18);
        assertEq(vault.totalSupply(), 100e18);
        assertEq(vault.delegates(alice), alice);
        assertEq(vault.getVotes(alice), 100e18);
        assertEq(address(governor.token()), address(vault));
        assertEq(vault.clock(), block.timestamp);
        assertEq(vault.CLOCK_MODE(), "mode=timestamp");
        assertEq(governor.clock(), block.timestamp);
        assertEq(governor.CLOCK_MODE(), "mode=timestamp");
        assertEq(governor.governanceStart(), block.timestamp + GOVERNANCE_START_DELAY);
    }

    function testGovernorRejectsNonTimestampVotingToken() public {
        BlockClockVotes blockClockVotes = new BlockClockVotes();
        vm.expectRevert(DeepstateGovernor.TimestampClockRequired.selector);
        _deployGovernor(IVotes(address(blockClockVotes)));

        IncorrectTimestampVotes incorrectTimestampVotes = new IncorrectTimestampVotes();
        vm.expectRevert(DeepstateGovernor.TimestampClockRequired.selector);
        _deployGovernor(IVotes(address(incorrectTimestampVotes)));

        MissingClockVotes missingClockVotes = new MissingClockVotes();
        vm.expectRevert(DeepstateGovernor.TimestampClockRequired.selector);
        _deployGovernor(IVotes(address(missingClockVotes)));

        MissingModeVotes missingModeVotes = new MissingModeVotes();
        vm.expectRevert(DeepstateGovernor.TimestampClockRequired.selector);
        _deployGovernor(IVotes(address(missingModeVotes)));
    }

    function testGovernanceLaunchPolicy() public {
        _startGovernance();
        vm.warp(vm.getBlockTimestamp() + 1);

        uint256 snapshot = governor.clock() - 1;
        assertEq(governor.governanceStart(), governanceDeployedAt + GOVERNANCE_START_DELAY);
        assertEq(governor.votingDelay(), 3 days);
        assertEq(governor.votingPeriod(), 1 weeks);
        assertEq(governor.proposalThresholdNumerator(), 1);
        assertEq(governor.PROPOSAL_THRESHOLD_DENOMINATOR(), 100);
        assertEq(governor.proposalThreshold(), 1e18);
        assertEq(governor.quorumNumerator(), 10);
        assertEq(governor.quorumDenominator(), 100);
        assertEq(governor.quorum(snapshot), 10e18);
    }

    function testVotingDelayMaximumAppliesAtDeploymentAndGovernanceUpdates() public {
        uint48 maximum = governor.MAX_VOTING_DELAY();
        DeepstateGovernor boundaryGovernor = new DeepstateGovernor(
            IVotes(address(vault)),
            GOVERNANCE_START_DELAY,
            maximum,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD_NUMERATOR,
            QUORUM_NUMERATOR,
            VOTE_EXTENSION
        );
        assertEq(boundaryGovernor.votingDelay(), maximum);

        uint48 invalidDelay = maximum + 1;
        vm.expectRevert(
            abi.encodeWithSelector(DeepstateGovernor.VotingDelayAboveMaximum.selector, invalidDelay, maximum)
        );
        new DeepstateGovernor(
            IVotes(address(vault)),
            GOVERNANCE_START_DELAY,
            invalidDelay,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD_NUMERATOR,
            QUORUM_NUMERATOR,
            VOTE_EXTENSION
        );

        vm.prank(address(governor));
        governor.setVotingDelay(maximum);
        assertEq(governor.votingDelay(), maximum);

        vm.prank(address(governor));
        vm.expectRevert(
            abi.encodeWithSelector(DeepstateGovernor.VotingDelayAboveMaximum.selector, invalidDelay, maximum)
        );
        governor.setVotingDelay(invalidDelay);
        assertEq(governor.votingDelay(), maximum);
    }

    function testLateQuorumExtensionMaximumAppliesAtDeploymentAndGovernanceUpdates() public {
        uint48 maximum = governor.MAX_LATE_QUORUM_VOTE_EXTENSION();
        DeepstateGovernor boundaryGovernor = new DeepstateGovernor(
            IVotes(address(vault)),
            GOVERNANCE_START_DELAY,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD_NUMERATOR,
            QUORUM_NUMERATOR,
            maximum
        );
        assertEq(boundaryGovernor.lateQuorumVoteExtension(), maximum);

        uint48 invalidExtension = maximum + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateGovernor.LateQuorumVoteExtensionAboveMaximum.selector, invalidExtension, maximum
            )
        );
        new DeepstateGovernor(
            IVotes(address(vault)),
            GOVERNANCE_START_DELAY,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD_NUMERATOR,
            QUORUM_NUMERATOR,
            invalidExtension
        );

        vm.prank(address(governor));
        governor.setLateQuorumVoteExtension(maximum);
        assertEq(governor.lateQuorumVoteExtension(), maximum);

        vm.prank(address(governor));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateGovernor.LateQuorumVoteExtensionAboveMaximum.selector, invalidExtension, maximum
            )
        );
        governor.setLateQuorumVoteExtension(invalidExtension);
        assertEq(governor.lateQuorumVoteExtension(), maximum);
    }

    function testProposalThresholdIsOneAtClockOrigin() public {
        vm.warp(0);
        assertEq(governor.proposalThreshold(), 1);
    }

    function testZeroSupplyEpochStillRequiresOnePastVoteToPropose() public {
        _startGovernance();

        valueToken.mint(address(vault), 1e6);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeemValue(shares, alice, alice);
        vm.warp(vm.getBlockTimestamp() + 1);

        assertEq(vault.totalSupply(), 0);
        assertEq(governor.proposalThreshold(), 1);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            _proposal(address(vault), abi.encodeCall(Ownable.transferOwnership, (newVaultOwner)), "zero supply");

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IGovernor.GovernorInsufficientProposerVotes.selector, bob, uint256(0), uint256(1))
        );
        governor.propose(targets, values, calldatas, description);
    }

    function testProposalCreationIsBlockedUntilExactGovernanceStart() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            _proposal(address(vault), abi.encodeCall(Ownable.transferOwnership, (newVaultOwner)), "bootstrap boundary");

        uint48 start = governor.governanceStart();
        vm.warp(start - 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(DeepstateGovernor.GovernanceNotStarted.selector, uint48(start - 1), start)
        );
        governor.propose(targets, values, calldatas, description);

        vm.warp(start);
        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        assertEq(governor.proposalProposer(proposalId), alice);
    }

    function testProposalThresholdTracksOnePercentOfStateSupplyAndRoundsUp() public {
        _startGovernance();

        vm.prank(bob);
        vault.deposit(5e17, bob);
        vm.warp(vm.getBlockTimestamp() + 1);

        assertEq(vault.totalSupply(), 100.5e18);
        assertEq(governor.proposalThreshold(), 1.005e18);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            _proposal(address(vault), abi.encodeCall(Ownable.transferOwnership, (newVaultOwner)), "below one percent");

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorInsufficientProposerVotes.selector, bob, uint256(5e17), uint256(1.005e18)
            )
        );
        governor.propose(targets, values, calldatas, description);

        vm.prank(bob);
        vault.deposit(99.5e18, bob);
        vm.warp(vm.getBlockTimestamp() + 1);

        assertEq(vault.totalSupply(), 200e18);
        assertEq(governor.proposalThreshold(), 2e18);
    }

    function testProposalThresholdFractionCanOnlyBeChangedThroughGovernance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, alice));
        governor.updateProposalThresholdNumerator(2);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) = _proposal(
            address(governor),
            abi.encodeCall(DeepstateGovernor.updateProposalThresholdNumerator, (2)),
            "raise proposal threshold"
        );
        _passProposal(targets, values, calldatas, description);

        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(governor.proposalThresholdNumerator(), 2);
        assertEq(governor.proposalThreshold(), 2e18);
    }

    function testInvalidAndAbsoluteProposalThresholdUpdatesRevert() public {
        uint256 denominator = governor.PROPOSAL_THRESHOLD_DENOMINATOR();
        vm.prank(address(governor));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateGovernor.InvalidProposalThresholdFraction.selector, uint256(101), denominator
            )
        );
        governor.updateProposalThresholdNumerator(101);

        vm.prank(address(governor));
        vm.expectRevert(DeepstateGovernor.AbsoluteProposalThresholdUnsupported.selector);
        governor.setProposalThreshold(1e18);
    }

    function testVaultSharesBackGovernorOwnershipOfVault() public {
        address[] memory targets = new address[](1);
        targets[0] = address(vault);

        uint256[] memory values = new uint256[](1);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(Ownable.transferOwnership, (newVaultOwner));

        _passProposal(targets, values, calldatas, "transfer vault ownership");

        assertEq(vault.owner(), newVaultOwner);
    }

    function testGovernorControlsDeepstateMinter() public {
        address[] memory targets = new address[](1);
        targets[0] = address(deepstate);

        uint256[] memory values = new uint256[](1);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IAccessControl.grantRole, (deepstate.MINTER_ROLE(), newMinter));

        _passProposal(targets, values, calldatas, "grant deepstate minter");

        assertTrue(deepstate.hasRole(deepstate.DEFAULT_ADMIN_ROLE(), address(governor)));
        assertTrue(deepstate.hasRole(deepstate.MINTER_ROLE(), newMinter));

        vm.prank(newMinter);
        deepstate.mint(alice, 1e18);
        assertEq(deepstate.balanceOf(alice), 1e18);

        bytes32 minterRole = deepstate.MINTER_ROLE();
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, minterRole)
        );
        deepstate.mint(alice, 1e18);
    }

    function testPostSnapshotDepositDoesNotAddVotesToActiveProposal() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            _proposal(address(vault), abi.encodeCall(Ownable.transferOwnership, (newVaultOwner)), "snapshot deposit");

        _startGovernance();
        vm.warp(vm.getBlockTimestamp() + 1);

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.warp(vm.getBlockTimestamp() + governor.votingDelay() + 1);

        vm.prank(bob);
        vault.deposit(100e18, bob);

        vm.prank(bob);
        governor.castVote(proposalId, 1);

        (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) = governor.proposalVotes(proposalId);
        assertEq(againstVotes, 0);
        assertEq(forVotes, 0);
        assertEq(abstainVotes, 0);

        vm.prank(alice);
        governor.castVote(proposalId, 1);

        (, forVotes,) = governor.proposalVotes(proposalId);
        assertEq(forVotes, 100e18);
    }

    function testPostSnapshotTransferDoesNotRemoveVotingPowerForActiveProposal() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            _proposal(address(vault), abi.encodeCall(Ownable.transferOwnership, (newVaultOwner)), "snapshot transfer");

        _startGovernance();
        vm.warp(vm.getBlockTimestamp() + 1);

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.warp(vm.getBlockTimestamp() + governor.votingDelay() + 1);

        vm.prank(alice);
        vault.transfer(bob, 100e18);

        assertEq(vault.getVotes(alice), 0);
        assertEq(vault.getVotes(bob), 0);

        vm.prank(alice);
        governor.castVote(proposalId, 1);

        (, uint256 forVotes,) = governor.proposalVotes(proposalId);
        assertEq(forVotes, 100e18);
    }

    function testPostSnapshotDelegationDoesNotAddVotingPowerForActiveProposal() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            _proposal(address(vault), abi.encodeCall(Ownable.transferOwnership, (newVaultOwner)), "snapshot delegation");

        vm.prank(bob);
        vault.delegate(alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);

        _startGovernance();
        vm.warp(vm.getBlockTimestamp() + 1);

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.warp(vm.getBlockTimestamp() + governor.votingDelay() + 1);

        vm.prank(bob);
        vault.delegate(bob);

        vm.prank(bob);
        governor.castVote(proposalId, 1);

        (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) = governor.proposalVotes(proposalId);
        assertEq(againstVotes, 0);
        assertEq(forVotes, 0);
        assertEq(abstainVotes, 0);

        vm.prank(alice);
        governor.castVote(proposalId, 1);

        (, forVotes,) = governor.proposalVotes(proposalId);
        assertEq(forVotes, 200e18);
    }

    function testLateQuorumExtensionUsesTimestampSeconds() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            _proposal(address(vault), abi.encodeCall(Ownable.transferOwnership, (newVaultOwner)), "late quorum");

        _startGovernance();
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        uint256 originalDeadline = governor.proposalDeadline(proposalId);
        vm.warp(originalDeadline - VOTE_EXTENSION / 2);
        vm.prank(alice);
        governor.castVote(proposalId, 1);

        assertEq(governor.proposalDeadline(proposalId), vm.getBlockTimestamp() + VOTE_EXTENSION);
    }

    function _passProposal(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal returns (uint256 proposalId) {
        _startGovernance();
        vm.warp(vm.getBlockTimestamp() + 1);

        vm.prank(alice);
        proposalId = governor.propose(targets, values, calldatas, description);

        vm.warp(vm.getBlockTimestamp() + governor.votingDelay() + 1);

        vm.prank(alice);
        governor.castVote(proposalId, 1);

        vm.warp(governor.proposalDeadline(proposalId) + 1);

        governor.execute(targets, values, calldatas, keccak256(bytes(description)));
    }

    function _proposal(address target, bytes memory callData, string memory description)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory)
    {
        targets = new address[](1);
        targets[0] = target;

        values = new uint256[](1);

        calldatas = new bytes[](1);
        calldatas[0] = callData;

        return (targets, values, calldatas, description);
    }

    function _deployGovernor(IVotes votes) private returns (DeepstateGovernor deployed) {
        deployed = new DeepstateGovernor(
            votes,
            GOVERNANCE_START_DELAY,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD_NUMERATOR,
            QUORUM_NUMERATOR,
            VOTE_EXTENSION
        );
    }

    function _startGovernance() private {
        uint48 start = governor.governanceStart();
        if (block.timestamp < start) vm.warp(start);
    }
}
