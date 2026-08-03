// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Test} from "forge-std/Test.sol";

import {DeployDeepstate} from "../script/DeployDeepstate.s.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DeployDeepstateTest is DeployDeepstate, Test {
    address internal additionalMinter = makeAddr("additionalMinter");
    address internal alice = makeAddr("alice");

    function testDeploymentAppliesLaunchPolicyAndAuthorityTopology() public {
        MockERC20 valueToken = new MockERC20("USDG", "USDG", 6);
        Config memory config = Config({
            deployer: address(this),
            valueToken: address(valueToken),
            wrappedNative: address(0),
            deepstateMinter: additionalMinter,
            tokenName: "Deepstate",
            tokenSymbol: "DEEP",
            vaultName: "Deepstate Governance",
            vaultSymbol: "STATE",
            routerFeeBps: 10,
            feeFlowInitPrice: DEFAULT_FEE_FLOW_INIT_PRICE,
            feeFlowEpochPeriod: DEFAULT_FEE_FLOW_EPOCH_PERIOD,
            feeFlowPriceMultiplier: DEFAULT_FEE_FLOW_PRICE_MULTIPLIER,
            feeFlowMinInitPrice: DEFAULT_FEE_FLOW_MIN_INIT_PRICE,
            governanceStartDelay: DEFAULT_GOVERNANCE_START_DELAY,
            votingDelay: DEFAULT_VOTING_DELAY,
            votingPeriod: DEFAULT_VOTING_PERIOD,
            proposalThresholdNumerator: DEFAULT_PROPOSAL_THRESHOLD_NUMERATOR,
            quorumNumerator: DEFAULT_QUORUM_NUMERATOR,
            voteExtension: DEFAULT_VOTE_EXTENSION,
            rewardEmissionStart: uint64(block.timestamp),
            rewardPoolShareWad: 1e18,
            rewardInitialSupply: 1e18
        });

        Deployment memory deployment = _deploy(config);
        bytes32 adminRole = deployment.deepstate.DEFAULT_ADMIN_ROLE();
        bytes32 minterRole = deployment.deepstate.MINTER_ROLE();

        assertTrue(deployment.deepstate.hasRole(adminRole, address(deployment.governor)));
        assertFalse(deployment.deepstate.hasRole(adminRole, address(this)));
        assertTrue(deployment.deepstate.hasRole(minterRole, address(deployment.rewarder)));
        assertTrue(deployment.deepstate.hasRole(minterRole, additionalMinter));

        assertEq(deployment.vault.owner(), address(deployment.governor));
        assertEq(deployment.rewarder.owner(), address(deployment.governor));
        assertEq(deployment.router.owner(), address(deployment.governor));
        assertEq(deployment.governor.governanceStart(), block.timestamp + 25 days);
        assertEq(deployment.governor.votingDelay(), 3 days);
        assertEq(deployment.governor.votingPeriod(), 1 weeks);
        assertEq(deployment.governor.proposalThresholdNumerator(), 1);
        assertEq(deployment.governor.quorumNumerator(), 10);
        assertFalse(deployment.governor.proposalNeedsQueuing(0));

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), adminRole)
        );
        deployment.deepstate.grantRole(minterRole, alice);

        vm.prank(additionalMinter);
        deployment.deepstate.mint(alice, 1e18);
        assertEq(deployment.deepstate.balanceOf(alice), 1e18);
    }

    function testConfigReadsExplicitGovernanceLaunchParameters() public {
        MockERC20 valueToken = new MockERC20("USDG", "USDG", 6);
        vm.setEnv("VALUE_TOKEN", vm.toString(address(valueToken)));
        vm.setEnv("REWARD_INITIAL_SUPPLY", vm.toString(uint256(1e18)));
        vm.setEnv("GOVERNOR_START_DELAY", vm.toString(uint256(17 days)));
        vm.setEnv("GOVERNOR_PROPOSAL_THRESHOLD_NUMERATOR", "3");
        vm.setEnv("GOVERNOR_QUORUM_NUMERATOR", "12");

        Config memory config = _readConfig(address(this));

        assertEq(config.governanceStartDelay, 17 days);
        assertEq(config.proposalThresholdNumerator, 3);
        assertEq(config.quorumNumerator, 12);
    }
}
