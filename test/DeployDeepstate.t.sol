// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Test} from "forge-std/Test.sol";

import {DeployDeepstate} from "../script/DeployDeepstate.s.sol";
import {DeepstateRewarder} from "../src/DeepstateRewarder.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DeployDeepstateTest is DeployDeepstate, Test {
    address internal additionalMinter = makeAddr("additionalMinter");
    address internal alice = makeAddr("alice");

    function testDeploymentAppliesLaunchPolicyAndAuthorityTopology() public {
        MockERC20 valueToken = new MockERC20("USDG", "USDG", 6);
        MockERC20 nvdaToken = new MockERC20("NVIDIA", "NVDA", 18);
        Config memory config = Config({
            deployer: address(this),
            valueToken: address(valueToken),
            nvdaToken: address(nvdaToken),
            deepstateMinter: additionalMinter,
            tokenName: "Deepstate",
            tokenSymbol: "DEEP",
            vaultName: "Deepstate Governance",
            vaultSymbol: "STATE",
            routerFeeBps: 10,
            governanceStartDelay: DEFAULT_GOVERNANCE_START_DELAY,
            votingDelay: DEFAULT_VOTING_DELAY,
            votingPeriod: DEFAULT_VOTING_PERIOD,
            proposalThresholdNumerator: DEFAULT_PROPOSAL_THRESHOLD_NUMERATOR,
            quorumNumerator: DEFAULT_QUORUM_NUMERATOR,
            voteExtension: DEFAULT_VOTE_EXTENSION
        });

        Deployment memory deployment = _deploy(config);
        bytes32 adminRole = deployment.deepstate.DEFAULT_ADMIN_ROLE();
        bytes32 minterRole = deployment.deepstate.MINTER_ROLE();

        assertTrue(deployment.deepstate.hasRole(adminRole, address(deployment.governor)));
        assertFalse(deployment.deepstate.hasRole(adminRole, address(this)));
        assertFalse(deployment.deepstate.hasRole(minterRole, address(deployment.nvdaRewarder)));
        assertFalse(deployment.deepstate.hasRole(minterRole, address(this)));
        assertTrue(deployment.deepstate.hasRole(minterRole, additionalMinter));
        assertEq(deployment.deepstate.totalSupply(), NVDA_REWARD_ALLOCATION);
        assertEq(deployment.deepstate.balanceOf(address(deployment.nvdaRewarder)), NVDA_REWARD_ALLOCATION);

        assertEq(deployment.vault.owner(), address(deployment.governor));
        assertEq(deployment.nvdaRewarder.owner(), address(deployment.governor));
        assertEq(deployment.router.owner(), address(deployment.governor));
        assertEq(deployment.governor.governanceStart(), block.timestamp + 15 days);
        assertEq(deployment.governor.votingDelay(), 3 days);
        assertEq(deployment.governor.votingPeriod(), 1 weeks);
        assertEq(deployment.governor.proposalThresholdNumerator(), 1);
        assertEq(deployment.governor.quorumNumerator(), 10);
        assertFalse(deployment.governor.proposalNeedsQueuing(0));

        assertEq(deployment.nvdaRewarder.sideEmissionCap(), NVDA_SIDE_EMISSION_CAP);
        assertEq(deployment.nvdaRewarder.emissionDuration(), NVDA_EMISSION_DURATION);
        assertEq(deployment.router.poolHook(deployment.nvdaRewarder.poolId()), address(deployment.nvdaRewarder));
        bytes32 deepPoolId = deployment.router.poolId(address(deployment.deepstate), address(valueToken));
        assertEq(deployment.router.poolHook(deepPoolId), address(0));
        _assertRewardQuantities(deployment.nvdaRewarder, address(nvdaToken), address(valueToken), 5_000e18);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), adminRole)
        );
        deployment.deepstate.grantRole(minterRole, alice);

        vm.prank(additionalMinter);
        deployment.deepstate.mint(alice, 1e18);
        assertEq(deployment.deepstate.balanceOf(alice), 1e18);
        assertEq(deployment.deepstate.totalSupply(), NVDA_REWARD_ALLOCATION + 1e18);
    }

    function testConfigReadsExplicitGovernanceLaunchParameters() public {
        MockERC20 valueToken = new MockERC20("USDG", "USDG", 6);
        MockERC20 nvdaToken = new MockERC20("NVIDIA", "NVDA", 18);
        vm.setEnv("VALUE_TOKEN", vm.toString(address(valueToken)));
        vm.setEnv("NVDA_TOKEN", vm.toString(address(nvdaToken)));
        vm.setEnv("GOVERNOR_START_DELAY", vm.toString(uint256(17 days)));
        vm.setEnv("GOVERNOR_PROPOSAL_THRESHOLD_NUMERATOR", "3");
        vm.setEnv("GOVERNOR_QUORUM_NUMERATOR", "12");

        Config memory config = _readConfig(address(this));

        assertEq(config.governanceStartDelay, 17 days);
        assertEq(config.proposalThresholdNumerator, 3);
        assertEq(config.quorumNumerator, 12);
        assertEq(config.routerFeeBps, 10);
        assertEq(config.nvdaToken, address(nvdaToken));
    }

    function testDeploymentRejectsUnexpectedExternalTokenDecimals() public {
        MockERC20 badValueToken = new MockERC20("USDG", "USDG", 18);
        MockERC20 nvdaToken = new MockERC20("NVIDIA", "NVDA", 18);
        Config memory config = _config(address(badValueToken), address(nvdaToken));

        vm.expectRevert(bytes("VALUE_TOKEN_DECIMALS"));
        this.deployForTest(config);

        MockERC20 valueToken = new MockERC20("USDG", "USDG", 6);
        MockERC20 badNvdaToken = new MockERC20("NVIDIA", "NVDA", 6);
        config = _config(address(valueToken), address(badNvdaToken));

        vm.expectRevert(bytes("NVDA_TOKEN_DECIMALS"));
        this.deployForTest(config);
    }

    function deployForTest(Config calldata config) external returns (Deployment memory) {
        return _deploy(config);
    }

    function _config(address valueToken, address nvdaToken) private view returns (Config memory config) {
        config = Config({
            deployer: address(this),
            valueToken: valueToken,
            nvdaToken: nvdaToken,
            deepstateMinter: address(0),
            tokenName: "Deepstate",
            tokenSymbol: "DEEP",
            vaultName: "Deepstate Governance",
            vaultSymbol: "STATE",
            routerFeeBps: DEFAULT_ROUTER_FEE_BPS,
            governanceStartDelay: DEFAULT_GOVERNANCE_START_DELAY,
            votingDelay: DEFAULT_VOTING_DELAY,
            votingPeriod: DEFAULT_VOTING_PERIOD,
            proposalThresholdNumerator: DEFAULT_PROPOSAL_THRESHOLD_NUMERATOR,
            quorumNumerator: DEFAULT_QUORUM_NUMERATOR,
            voteExtension: DEFAULT_VOTE_EXTENSION
        });
    }

    function _assertRewardQuantities(
        DeepstateRewarder rewarder,
        address marketToken,
        address valueToken,
        uint160 marketMaximum
    ) private view {
        if (marketToken < valueToken) {
            assertEq(rewarder.token0(), marketToken);
            assertEq(rewarder.token0StartQuantity(), 1e18);
            assertEq(rewarder.token0MaxQuantity(), marketMaximum);
            assertEq(rewarder.token1(), valueToken);
            assertEq(rewarder.token1StartQuantity(), 1e6);
            assertEq(rewarder.token1MaxQuantity(), 1_000_000e6);
        } else {
            assertEq(rewarder.token0(), valueToken);
            assertEq(rewarder.token0StartQuantity(), 1e6);
            assertEq(rewarder.token0MaxQuantity(), 1_000_000e6);
            assertEq(rewarder.token1(), marketToken);
            assertEq(rewarder.token1StartQuantity(), 1e18);
            assertEq(rewarder.token1MaxQuantity(), marketMaximum);
        }
    }
}
