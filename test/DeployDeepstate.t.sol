// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Test} from "forge-std/Test.sol";

import {DeployDeepstate} from "../script/DeployDeepstate.s.sol";
import {DeepstateRewarder} from "../src/DeepstateRewarder.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DeployDeepstateTest is DeployDeepstate, Test {
    uint96 internal constant SIDE_EMISSION_CAP = 500_000_000e18;
    uint256 internal constant REWARD_FUNDING = uint256(SIDE_EMISSION_CAP) * 2;

    address internal initialMinterA = makeAddr("initialMinterA");
    address internal initialMinterB = makeAddr("initialMinterB");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");

    function testRunLoadsConfigBroadcastsPipelineAndWritesAddressManifest() public {
        uint256 privateKey = 0xA11CE;
        address deployer = vm.addr(privateKey);
        MockERC20 valueToken = new MockERC20("USDG", "USDG", 6);
        MockERC20 marketToken = new MockERC20("NVIDIA", "NVDA", 18);
        string memory examplePath = string.concat(vm.projectRoot(), "/script/config/production.example.json");
        string memory configPath = string.concat(vm.projectRoot(), "/deployments/test-run-config.json");
        string memory outputPath = string.concat(vm.projectRoot(), "/deployments/test-run-addresses.json");
        string memory json = vm.readFile(examplePath);

        vm.writeFile(configPath, json);
        vm.writeJson(vm.toString(block.chainid), configPath, ".deployment.expectedChainId");
        vm.writeJson(string.concat("\"", vm.toString(deployer), "\""), configPath, ".deployment.expectedDeployer");
        vm.writeJson(
            string.concat("\"", vm.toString(address(valueToken)), "\""), configPath, ".externalTokens.valueToken"
        );
        vm.writeJson(
            string.concat("\"", vm.toString(address(marketToken)), "\""), configPath, ".externalTokens.marketToken"
        );
        vm.setEnv("PRIVATE_KEY", vm.toString(privateKey));
        vm.setEnv("DEEPSTATE_DEPLOYMENT_CONFIG", configPath);
        vm.setEnv("DEEPSTATE_DEPLOYMENT_OUTPUT", outputPath);

        Deployment memory deployment = this.run();
        string memory simulationManifest = vm.readFile(outputPath);
        assertTrue(vm.parseJsonBool(simulationManifest, ".simulationVerificationPassed"));
        assertFalse(vm.parseJsonBool(simulationManifest, ".liveRpcVerificationPassed"));

        Deployment memory verified = this.verify();
        string memory manifest = vm.readFile(outputPath);

        assertEq(vm.parseJsonAddress(manifest, ".deployer"), deployer);
        assertEq(vm.parseJsonAddress(manifest, ".deepstateToken"), address(deployment.deepstateToken));
        assertEq(vm.parseJsonAddress(manifest, ".stateVault"), address(deployment.stateVault));
        assertEq(vm.parseJsonAddress(manifest, ".governor"), address(deployment.governor));
        assertEq(vm.parseJsonAddress(manifest, ".router"), address(deployment.router));
        assertEq(vm.parseJsonAddress(manifest, ".marketRewarder"), address(deployment.marketRewarder));
        assertEq(address(verified.governor), address(deployment.governor));
        assertTrue(vm.parseJsonBool(manifest, ".simulationVerificationPassed"));
        assertTrue(vm.parseJsonBool(manifest, ".liveRpcVerificationPassed"));
        assertFalse(vm.parseJsonBool(manifest, ".marketTokenValidationSkipped"));
        assertEq(deployment.stateVault.owner(), address(deployment.governor));
        assertEq(deployment.router.owner(), address(deployment.governor));

        vm.removeFile(configPath);
        vm.removeFile(outputPath);
    }

    function testDeploysConfiguresAndVerifiesEveryLaunchParameter() public {
        MockERC20 valueToken = new MockERC20("USDG", "USDG", 6);
        MockERC20 marketToken = new MockERC20("NVIDIA", "NVDA", 18);
        Config memory config = _config(address(valueToken), address(marketToken));
        config.deepToken.name = "Deepstate Production";
        config.deepToken.symbol = "DEEP-P";
        config.vault.name = "Deepstate Voting Power";
        config.vault.symbol = "STATE-P";
        config.governance.startDelay = 17 days;
        config.governance.votingDelay = 4 days;
        config.governance.votingPeriod = 9 days;
        config.governance.proposalThresholdNumerator = 2;
        config.governance.quorumNumerator = 12;
        config.governance.voteExtension = 2 days;
        config.rewarder.emissionDuration = 200 days;
        config.rewarder.marketStartQuantity = 2e18;
        config.rewarder.marketMaxQuantity = 4_000e18;
        config.rewarder.valueStartQuantity = 2e6;
        config.rewarder.valueMaxQuantity = 2_000_000e6;

        Deployment memory deployment = this.deployForTest(config);
        bytes32 adminRole = deployment.deepstateToken.DEFAULT_ADMIN_ROLE();
        bytes32 minterRole = deployment.deepstateToken.MINTER_ROLE();
        address governor = address(deployment.governor);

        assertEq(deployment.deepstateToken.name(), "Deepstate Production");
        assertEq(deployment.deepstateToken.symbol(), "DEEP-P");
        assertEq(deployment.stateVault.name(), "Deepstate Voting Power");
        assertEq(deployment.stateVault.symbol(), "STATE-P");
        assertEq(deployment.deepstateToken.totalSupply(), REWARD_FUNDING);
        assertEq(deployment.deepstateToken.balanceOf(address(deployment.marketRewarder)), REWARD_FUNDING);
        assertTrue(deployment.deepstateToken.hasRole(adminRole, governor));
        assertFalse(deployment.deepstateToken.hasRole(adminRole, address(this)));
        assertEq(deployment.deepstateToken.defaultAdminCount(), 1);
        assertTrue(deployment.deepstateToken.hasRole(minterRole, initialMinterA));
        assertTrue(deployment.deepstateToken.hasRole(minterRole, initialMinterB));
        assertFalse(deployment.deepstateToken.hasRole(minterRole, address(this)));
        assertFalse(deployment.deepstateToken.hasRole(minterRole, address(deployment.marketRewarder)));

        assertEq(deployment.stateVault.owner(), governor);
        assertEq(deployment.marketRewarder.owner(), governor);
        assertEq(deployment.router.owner(), governor);
        assertEq(address(deployment.governor.token()), address(deployment.stateVault));
        assertEq(deployment.governor.governanceStart(), block.timestamp + 17 days);
        assertEq(deployment.governor.votingDelay(), 4 days);
        assertEq(deployment.governor.votingPeriod(), 9 days);
        assertEq(deployment.governor.proposalThresholdNumerator(), 2);
        assertEq(deployment.governor.quorumNumerator(), 12);
        assertEq(deployment.governor.lateQuorumVoteExtension(), 2 days);

        assertEq(deployment.marketRewarder.sideEmissionCap(), SIDE_EMISSION_CAP);
        assertEq(deployment.marketRewarder.emissionDuration(), 200 days);
        _assertRewardQuantities(
            deployment.marketRewarder, address(marketToken), address(valueToken), 2e18, 4_000e18, 2e6, 2_000_000e6
        );

        bytes32 poolId = deployment.router.poolId(address(marketToken), address(valueToken));
        assertEq(deployment.router.poolHook(poolId), address(deployment.marketRewarder));
        (address configuredFeeRecipient, uint16 feeBps) = deployment.router.feeConfig();
        assertEq(configuredFeeRecipient, address(deployment.stateVault));
        assertEq(feeBps, 10);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), adminRole)
        );
        deployment.deepstateToken.grantRole(minterRole, alice);

        vm.prank(initialMinterA);
        deployment.deepstateToken.mint(alice, 1e18);
        assertEq(deployment.deepstateToken.balanceOf(alice), 1e18);
    }

    function testSupportsExplicitCustomFeeRecipientAndDisabledPoolHooks() public {
        MockERC20 valueToken = new MockERC20("USDG", "USDG", 6);
        MockERC20 marketToken = new MockERC20("NVIDIA", "NVDA", 18);
        Config memory config = _config(address(valueToken), address(marketToken));
        config.deepToken.initialMinters = new address[](0);
        config.router.useVaultAsFeeRecipient = false;
        config.router.feeRecipient = feeRecipient;
        config.router.feeBps = 37;
        config.rewarder.marketBuySideActive = false;
        config.rewarder.valueBuySideActive = false;

        Deployment memory deployment = this.deployForTest(config);

        (address configuredFeeRecipient, uint16 feeBps) = deployment.router.feeConfig();
        assertEq(configuredFeeRecipient, feeRecipient);
        assertEq(feeBps, 37);
        assertEq(deployment.router.poolHook(deployment.marketRewarder.poolId()), address(0));
    }

    function testParsesTheVersionedProductionConfigWithoutNumericPrecisionLoss() public view {
        string memory path = string.concat(vm.projectRoot(), "/script/config/production.example.json");
        Config memory config = _parseConfig(vm.readFile(path));

        assertEq(config.environment.expectedChainId, 46_630);
        assertEq(config.externalTokens.valueToken, 0x7E955252E15c84f5768B83c41a71F9eba181802F);
        assertEq(config.externalTokens.marketToken, 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC);
        assertEq(config.deepToken.name, "Deepstate");
        assertEq(config.deepToken.symbol, "DEEP");
        assertEq(config.deepToken.initialMinters.length, 0);
        assertEq(config.router.feeBps, 10);
        assertTrue(config.router.useVaultAsFeeRecipient);
        assertEq(config.governance.startDelay, 15 days);
        assertEq(config.governance.votingDelay, 3 days);
        assertEq(config.governance.votingPeriod, 7 days);
        assertEq(config.governance.proposalThresholdNumerator, 1);
        assertEq(config.governance.quorumNumerator, 10);
        assertEq(config.governance.voteExtension, 1 days);
        assertEq(config.rewarder.sideEmissionCap, SIDE_EMISSION_CAP);
        assertEq(config.rewarder.initialFunding, REWARD_FUNDING);
        assertEq(config.rewarder.emissionDuration, 395 days);
        assertEq(config.rewarder.marketStartQuantity, 1e18);
        assertEq(config.rewarder.marketMaxQuantity, 5_000e18);
        assertEq(config.rewarder.valueStartQuantity, 1e6);
        assertEq(config.rewarder.valueMaxQuantity, 1_000_000e6);
        assertTrue(config.rewarder.marketBuySideActive);
        assertTrue(config.rewarder.valueBuySideActive);
    }

    function testConfigParserRejectsUnknownSchemaAndNarrowingOverflow() public {
        string memory path = string.concat(vm.projectRoot(), "/script/config/production.example.json");
        string memory json = vm.readFile(path);
        string memory wrongSchema = vm.replace(json, "\"schemaVersion\": 1", "\"schemaVersion\": 2");

        vm.expectRevert(abi.encodeWithSelector(ConfigSchemaMismatch.selector, 1, 2));
        this.parseConfigForTest(wrongSchema);

        string memory overflowingFee = vm.replace(json, "\"feeBps\": 10", "\"feeBps\": 65536");
        vm.expectRevert(
            abi.encodeWithSelector(ConfigValueOutOfRange.selector, "router.feeBps", uint256(65_536), uint256(65_535))
        );
        this.parseConfigForTest(overflowingFee);
    }

    function testManifestRoundTripBindsAddressesToConfigAndChain() public {
        MockERC20 valueToken = new MockERC20("USDG", "USDG", 6);
        MockERC20 marketToken = new MockERC20("NVIDIA", "NVDA", 18);
        Config memory config = _config(address(valueToken), address(marketToken));
        Deployment memory deployment = this.deployForTest(config);
        bytes32 configHash = keccak256("production-config");
        string memory path = string.concat(vm.projectRoot(), "/deployments/test-production-manifest.json");

        _writeManifest(config, deployment, configHash, path, true);
        string memory manifest = vm.readFile(path);
        Deployment memory parsed = _deploymentFromManifest(manifest, configHash);

        assertEq(address(parsed.deepstateToken), address(deployment.deepstateToken));
        assertEq(address(parsed.stateVault), address(deployment.stateVault));
        assertEq(address(parsed.governor), address(deployment.governor));
        assertEq(address(parsed.router), address(deployment.router));
        assertEq(address(parsed.marketRewarder), address(deployment.marketRewarder));
        assertEq(vm.parseJsonAddress(manifest, ".valueToken"), address(valueToken));
        assertEq(vm.parseJsonAddress(manifest, ".marketToken"), address(marketToken));
        assertEq(vm.parseJsonAddress(manifest, ".routerFeeRecipient"), address(deployment.stateVault));
        assertTrue(vm.parseJsonBool(manifest, ".simulationVerificationPassed"));
        assertTrue(vm.parseJsonBool(manifest, ".liveRpcVerificationPassed"));
        assertFalse(vm.parseJsonBool(manifest, ".marketTokenValidationSkipped"));

        vm.expectRevert(abi.encodeWithSelector(ManifestConfigMismatch.selector, bytes32(uint256(1)), configHash));
        this.parseManifestForTest(manifest, bytes32(uint256(1)));

        vm.removeFile(path);
    }

    function testValidationRejectsWrongChainAndSignerBeforeDeployment() public {
        MockERC20 valueToken = new MockERC20("USDG", "USDG", 6);
        MockERC20 marketToken = new MockERC20("NVIDIA", "NVDA", 18);
        Config memory config = _config(address(valueToken), address(marketToken));
        config.environment.expectedChainId = block.chainid + 1;

        vm.expectRevert(abi.encodeWithSelector(WrongChain.selector, block.chainid + 1, block.chainid));
        this.validateForTest(config, address(this));

        config.environment.expectedChainId = block.chainid;
        vm.expectRevert(abi.encodeWithSelector(WrongDeployer.selector, address(this), alice));
        this.validateForTest(config, alice);
    }

    function testValidationRejectsUnexpectedTokenCodeAndDecimals() public {
        MockERC20 valueToken = new MockERC20("USDG", "USDG", 6);
        MockERC20 marketToken = new MockERC20("NVIDIA", "NVDA", 18);
        Config memory config = _config(address(valueToken), address(marketToken));
        config.externalTokens.marketToken = alice;

        vm.expectRevert(abi.encodeWithSelector(MissingCode.selector, "externalTokens.marketToken", alice));
        this.validateForTest(config, address(this));

        MockERC20 wrongDecimals = new MockERC20("NVIDIA", "NVDA", 8);
        config.externalTokens.marketToken = address(wrongDecimals);
        vm.expectRevert(
            abi.encodeWithSelector(TokenDecimalsMismatch.selector, address(wrongDecimals), uint8(18), uint8(8))
        );
        this.validateForTest(config, address(this));
    }

    function testMarketTokenValidationBypassIsTestnetOnlyAndKeepsValueTokenValidation() public {
        uint256 originalChainId = block.chainid;
        vm.chainId(ROBINHOOD_TESTNET_CHAIN_ID);

        MockERC20 valueToken = new MockERC20("USDG", "USDG", 6);
        Config memory config = _config(address(valueToken), alice);
        config.environment.expectedChainId = ROBINHOOD_TESTNET_CHAIN_ID;

        this.validateWithMarketTokenBypassForTest(config, address(this));
        Deployment memory deployment = this.deployWithMarketTokenBypassForTest(config);
        assertEq(deployment.marketRewarder.token0(), alice < address(valueToken) ? alice : address(valueToken));

        string memory manifestPath = string.concat(vm.projectRoot(), "/deployments/test-bypass-manifest.json");
        _writeManifest(config, deployment, keccak256("bypass-config"), manifestPath, true, true);
        assertTrue(vm.parseJsonBool(vm.readFile(manifestPath), ".marketTokenValidationSkipped"));
        vm.removeFile(manifestPath);

        config.externalTokens.valueToken = feeRecipient;
        vm.expectRevert(abi.encodeWithSelector(MissingCode.selector, "externalTokens.valueToken", feeRecipient));
        this.validateWithMarketTokenBypassForTest(config, address(this));

        vm.chainId(4_663);
        config.environment.expectedChainId = 4_663;
        config.externalTokens.valueToken = address(valueToken);
        vm.expectRevert(
            abi.encodeWithSelector(InvalidConfig.selector, "deployment.skipMarketTokenValidationOnlyOnRobinhoodTestnet")
        );
        this.validateWithMarketTokenBypassForTest(config, address(this));

        vm.chainId(originalChainId);
    }

    function testValidationRejectsInconsistentFundingAndMinterAuthority() public {
        MockERC20 valueToken = new MockERC20("USDG", "USDG", 6);
        MockERC20 marketToken = new MockERC20("NVIDIA", "NVDA", 18);
        Config memory config = _config(address(valueToken), address(marketToken));
        config.rewarder.initialFunding = REWARD_FUNDING - 1;

        vm.expectRevert(abi.encodeWithSelector(InvalidConfig.selector, "rewarder.initialFunding"));
        this.validateForTest(config, address(this));

        config.rewarder.initialFunding = REWARD_FUNDING;
        config.deepToken.initialMinters[1] = initialMinterA;
        vm.expectRevert(abi.encodeWithSelector(InvalidConfig.selector, "deepToken.duplicateMinter"));
        this.validateForTest(config, address(this));

        config.deepToken.initialMinters[1] = address(this);
        vm.expectRevert(abi.encodeWithSelector(InvalidConfig.selector, "deepToken.initialMinters"));
        this.validateForTest(config, address(this));
    }

    function testValidationRejectsUnsafeGovernanceFeeAndQuantityRanges() public {
        MockERC20 valueToken = new MockERC20("USDG", "USDG", 6);
        MockERC20 marketToken = new MockERC20("NVIDIA", "NVDA", 18);
        Config memory config = _config(address(valueToken), address(marketToken));
        config.router.feeBps = 101;

        vm.expectRevert(abi.encodeWithSelector(InvalidConfig.selector, "router.feeBps"));
        this.validateForTest(config, address(this));

        config.router.feeBps = 10;
        config.governance.votingDelay = 1 days - 1;
        vm.expectRevert(abi.encodeWithSelector(InvalidConfig.selector, "governance.votingDelay"));
        this.validateForTest(config, address(this));

        config.governance.votingDelay = 3 days;
        config.rewarder.marketMaxQuantity = config.rewarder.marketStartQuantity * 999;
        vm.expectRevert(abi.encodeWithSelector(InvalidConfig.selector, "rewarder.marketQuantity"));
        this.validateForTest(config, address(this));
    }

    function deployForTest(Config calldata config) external returns (Deployment memory) {
        return _deploy(config);
    }

    function deployWithMarketTokenBypassForTest(Config calldata config) external returns (Deployment memory) {
        return _deploy(config, true);
    }

    function validateForTest(Config calldata config, address signer) external view {
        _validateConfig(config, signer);
    }

    function validateWithMarketTokenBypassForTest(Config calldata config, address signer) external view {
        _validateConfig(config, signer, true);
    }

    function parseManifestForTest(string calldata json, bytes32 configHash) external view returns (Deployment memory) {
        return _deploymentFromManifest(json, configHash);
    }

    function parseConfigForTest(string calldata json) external pure returns (Config memory) {
        return _parseConfig(json);
    }

    function _config(address valueToken, address marketToken) private view returns (Config memory config) {
        config.environment.expectedChainId = block.chainid;
        config.environment.expectedDeployer = address(this);
        config.externalTokens.valueToken = valueToken;
        config.externalTokens.valueTokenDecimals = 6;
        config.externalTokens.marketToken = marketToken;
        config.externalTokens.marketTokenDecimals = 18;
        config.deepToken.name = "Deepstate";
        config.deepToken.symbol = "DEEP";
        config.deepToken.initialMinters = new address[](2);
        config.deepToken.initialMinters[0] = initialMinterA;
        config.deepToken.initialMinters[1] = initialMinterB;
        config.vault.name = "Deepstate Governance";
        config.vault.symbol = "STATE";
        config.router.feeBps = 10;
        config.router.useVaultAsFeeRecipient = true;
        config.router.feeRecipient = address(0);
        config.governance.startDelay = 15 days;
        config.governance.votingDelay = 3 days;
        config.governance.votingPeriod = 7 days;
        config.governance.proposalThresholdNumerator = 1;
        config.governance.quorumNumerator = 10;
        config.governance.voteExtension = 1 days;
        config.rewarder.sideEmissionCap = SIDE_EMISSION_CAP;
        config.rewarder.initialFunding = REWARD_FUNDING;
        config.rewarder.emissionDuration = 395 days;
        config.rewarder.marketStartQuantity = 1e18;
        config.rewarder.marketMaxQuantity = 5_000e18;
        config.rewarder.valueStartQuantity = 1e6;
        config.rewarder.valueMaxQuantity = 1_000_000e6;
        config.rewarder.marketBuySideActive = true;
        config.rewarder.valueBuySideActive = true;
    }

    function _assertRewardQuantities(
        DeepstateRewarder rewarder,
        address marketToken,
        address valueToken,
        uint160 marketStart,
        uint160 marketMaximum,
        uint160 valueStart,
        uint160 valueMaximum
    ) private view {
        if (marketToken < valueToken) {
            assertEq(rewarder.token0(), marketToken);
            assertEq(rewarder.token0StartQuantity(), marketStart);
            assertEq(rewarder.token0MaxQuantity(), marketMaximum);
            assertEq(rewarder.token1(), valueToken);
            assertEq(rewarder.token1StartQuantity(), valueStart);
            assertEq(rewarder.token1MaxQuantity(), valueMaximum);
        } else {
            assertEq(rewarder.token0(), valueToken);
            assertEq(rewarder.token0StartQuantity(), valueStart);
            assertEq(rewarder.token0MaxQuantity(), valueMaximum);
            assertEq(rewarder.token1(), marketToken);
            assertEq(rewarder.token1StartQuantity(), marketStart);
            assertEq(rewarder.token1MaxQuantity(), marketMaximum);
        }
    }
}
