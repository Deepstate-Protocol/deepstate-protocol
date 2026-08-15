// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {DeepstateV1} from "deepstate-contracts/DeepstateV1.sol";
import {Script, console2} from "forge-std/Script.sol";

import {DeepstateGovernor} from "../src/DeepstateGovernor.sol";
import {DeepstateRewarder} from "../src/DeepstateRewarder.sol";
import {DeepstateToken} from "../src/DeepstateToken.sol";
import {DeepstateVault} from "../src/DeepstateVault.sol";

/// @notice Production deployment, configuration, and state-verification pipeline.
/// @dev Every constructor and mutable launch parameter is loaded from a required JSON file.
/// The private key remains separate so it is never committed with the deployment configuration.
contract DeployDeepstate is Script {
    uint256 internal constant CONFIG_SCHEMA_VERSION = 1;
    uint256 internal constant MANIFEST_SCHEMA_VERSION = 1;
    uint256 internal constant ROBINHOOD_TESTNET_CHAIN_ID = 46_630;
    uint8 internal constant REQUIRED_VALUE_TOKEN_DECIMALS = 6;
    uint16 internal constant MAX_ROUTER_FEE_BPS = 100;
    uint256 internal constant MIN_QUANTITY_GROWTH = 1_000;
    uint48 internal constant MIN_VOTING_DELAY = 1 days;
    uint48 internal constant MAX_VOTING_DELAY = 30 days;
    uint32 internal constant MAX_VOTING_PERIOD = 30 days;
    uint48 internal constant MAX_VOTE_EXTENSION = 7 days;
    uint256 internal constant GOVERNANCE_PERCENT_DENOMINATOR = 100;
    uint32 internal constant MIN_EMISSION_DURATION = 30 days;
    uint256 private constant _ROUTER_POOL_CONFIG_MAPPING_SLOT = 2;
    uint256 private constant _ROUTER_TOKEN0_HOOK_FLAG = uint256(1) << 254;
    uint256 private constant _ROUTER_TOKEN1_HOOK_FLAG = uint256(1) << 255;

    struct EnvironmentConfig {
        uint256 expectedChainId;
        address expectedDeployer;
    }

    struct ExternalTokensConfig {
        address valueToken;
        uint8 valueTokenDecimals;
        address marketToken;
        uint8 marketTokenDecimals;
    }

    struct DeepTokenConfig {
        string name;
        string symbol;
        address[] initialMinters;
    }

    struct VaultConfig {
        string name;
        string symbol;
    }

    struct RouterConfig {
        uint16 feeBps;
        bool useVaultAsFeeRecipient;
        address feeRecipient;
    }

    struct GovernanceConfig {
        uint48 startDelay;
        uint48 votingDelay;
        uint32 votingPeriod;
        uint256 proposalThresholdNumerator;
        uint256 quorumNumerator;
        uint48 voteExtension;
    }

    struct RewarderConfig {
        uint96 sideEmissionCap;
        uint256 initialFunding;
        uint32 emissionDuration;
        uint160 marketStartQuantity;
        uint160 marketMaxQuantity;
        uint160 valueStartQuantity;
        uint160 valueMaxQuantity;
        bool marketBuySideActive;
        bool valueBuySideActive;
    }

    struct Config {
        EnvironmentConfig environment;
        ExternalTokensConfig externalTokens;
        DeepTokenConfig deepToken;
        VaultConfig vault;
        RouterConfig router;
        GovernanceConfig governance;
        RewarderConfig rewarder;
    }

    struct Deployment {
        DeepstateToken deepstateToken;
        DeepstateVault stateVault;
        DeepstateGovernor governor;
        DeepstateV1 router;
        DeepstateRewarder marketRewarder;
    }

    error WrongChain(uint256 expected, uint256 actual);
    error WrongDeployer(address expected, address actual);
    error InvalidConfig(string field);
    error ConfigValueOutOfRange(string field, uint256 value, uint256 maximum);
    error MissingCode(string field, address account);
    error TokenDecimalsMismatch(address token, uint8 expected, uint8 actual);
    error DeploymentVerificationFailed(string check);
    error ManifestConfigMismatch(bytes32 expected, bytes32 actual);
    error ConfigSchemaMismatch(uint256 expected, uint256 actual);
    error ManifestSchemaMismatch(uint256 expected, uint256 actual);

    /// @notice Simulate, deploy, configure, verify, and emit a deployment manifest.
    function run() external returns (Deployment memory deployment) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        string memory configPath = vm.envString("DEEPSTATE_DEPLOYMENT_CONFIG");
        string memory outputPath = vm.envString("DEEPSTATE_DEPLOYMENT_OUTPUT");
        string memory configJson = vm.readFile(configPath);
        Config memory config = _parseConfig(configJson);
        address signer = vm.addr(privateKey);
        bool skipMarketTokenValidation = vm.envOr("DEEPSTATE_SKIP_MARKET_TOKEN_VALIDATION", false);

        _validateConfig(config, signer, skipMarketTokenValidation);

        vm.startBroadcast(privateKey);
        deployment = _deploy(config, skipMarketTokenValidation);
        vm.stopBroadcast();

        _writeManifest(config, deployment, keccak256(bytes(configJson)), outputPath, false, skipMarketTokenValidation);
        _logDeployment(deployment, outputPath);
    }

    /// @notice Re-read the manifest and verify the deployed state against the source configuration.
    /// @dev The production shell entrypoint calls this against the live RPC after broadcasting.
    function verify() external returns (Deployment memory deployment) {
        string memory configPath = vm.envString("DEEPSTATE_DEPLOYMENT_CONFIG");
        string memory outputPath = vm.envString("DEEPSTATE_DEPLOYMENT_OUTPUT");
        string memory configJson = vm.readFile(configPath);
        string memory manifestJson = vm.readFile(outputPath);
        Config memory config = _parseConfig(configJson);
        bool skipMarketTokenValidation = vm.envOr("DEEPSTATE_SKIP_MARKET_TOKEN_VALIDATION", false);

        _validateConfig(config, config.environment.expectedDeployer, skipMarketTokenValidation);
        deployment = _deploymentFromManifest(manifestJson, keccak256(bytes(configJson)));
        _verifyDeployment(config, deployment, 0);
        _writeManifest(config, deployment, keccak256(bytes(configJson)), outputPath, true, skipMarketTokenValidation);
        _logDeployment(deployment, outputPath);
    }

    function _deploy(Config memory config) internal returns (Deployment memory deployment) {
        return _deploy(config, false);
    }

    function _deploy(Config memory config, bool skipMarketTokenValidation)
        internal
        returns (Deployment memory deployment)
    {
        _validateConfig(config, config.environment.expectedDeployer, skipMarketTokenValidation);
        // `_validateConfig` bounds the timestamp to uint48.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint48 deployedAt = uint48(block.timestamp);

        deployment = _deployContracts(config);
        _configureContracts(config, deployment);
        _verifyDeployment(config, deployment, deployedAt);
    }

    function _deployContracts(Config memory config) internal returns (Deployment memory deployment) {
        address deployer = config.environment.expectedDeployer;

        deployment.deepstateToken = new DeepstateToken(deployer, config.deepToken.name, config.deepToken.symbol);
        deployment.router = new DeepstateV1();
        deployment.stateVault = new DeepstateVault(
            deployer,
            address(deployment.deepstateToken),
            config.externalTokens.valueToken,
            config.vault.name,
            config.vault.symbol
        );

        (address token0, address token1) =
            _sortTokens(config.externalTokens.marketToken, config.externalTokens.valueToken);
        bool marketIsToken0 = config.externalTokens.marketToken == token0;
        uint160 token0Start = marketIsToken0 ? config.rewarder.marketStartQuantity : config.rewarder.valueStartQuantity;
        uint160 token0Max = marketIsToken0 ? config.rewarder.marketMaxQuantity : config.rewarder.valueMaxQuantity;
        uint160 token1Start = marketIsToken0 ? config.rewarder.valueStartQuantity : config.rewarder.marketStartQuantity;
        uint160 token1Max = marketIsToken0 ? config.rewarder.valueMaxQuantity : config.rewarder.marketMaxQuantity;

        deployment.marketRewarder = new DeepstateRewarder(
            deployer,
            address(deployment.router),
            address(deployment.deepstateToken),
            deployment.router.poolId(token0, token1),
            token0,
            token1,
            config.rewarder.sideEmissionCap,
            config.rewarder.emissionDuration,
            token0Start,
            token0Max,
            token1Start,
            token1Max
        );
        deployment.governor = new DeepstateGovernor(
            IVotes(address(deployment.stateVault)),
            config.governance.startDelay,
            config.governance.votingDelay,
            config.governance.votingPeriod,
            config.governance.proposalThresholdNumerator,
            config.governance.quorumNumerator,
            config.governance.voteExtension
        );
    }

    function _configureContracts(Config memory config, Deployment memory deployment) internal {
        DeepstateToken token = deployment.deepstateToken;
        bytes32 minterRole = token.MINTER_ROLE();
        address deployer = config.environment.expectedDeployer;

        token.grantRole(minterRole, deployer);
        token.mint(address(deployment.marketRewarder), config.rewarder.initialFunding);
        token.revokeRole(minterRole, deployer);

        uint256 minterCount = config.deepToken.initialMinters.length;
        for (uint256 i; i < minterCount; ++i) {
            token.grantRole(minterRole, config.deepToken.initialMinters[i]);
        }

        deployment.router.setFeeConfig(_feeRecipient(config, deployment), config.router.feeBps);

        (address token0, address token1) =
            _sortTokens(config.externalTokens.marketToken, config.externalTokens.valueToken);
        (bool token0Active, bool token1Active) = _hookFlags(config, token0);
        address hook = token0Active || token1Active ? address(deployment.marketRewarder) : address(0);
        deployment.router.setPoolHookConfig(token0, token1, hook, token0Active, token1Active);

        address governor = address(deployment.governor);
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();
        token.grantRole(adminRole, governor);
        token.renounceRole(adminRole, deployer);
        deployment.stateVault.transferOwnership(governor);
        deployment.marketRewarder.transferOwnership(governor);
        deployment.router.transferOwnership(governor);
    }

    function _validateConfig(Config memory config, address signer) internal view {
        _validateConfig(config, signer, false);
    }

    function _validateConfig(Config memory config, address signer, bool skipMarketTokenValidation) internal view {
        if (config.environment.expectedChainId == 0) revert InvalidConfig("deployment.expectedChainId");
        if (block.chainid != config.environment.expectedChainId) {
            revert WrongChain(config.environment.expectedChainId, block.chainid);
        }
        if (config.environment.expectedDeployer == address(0)) {
            revert InvalidConfig("deployment.expectedDeployer");
        }
        if (signer != config.environment.expectedDeployer) {
            revert WrongDeployer(config.environment.expectedDeployer, signer);
        }

        ExternalTokensConfig memory tokens = config.externalTokens;
        if (tokens.valueToken == address(0)) revert InvalidConfig("externalTokens.valueToken");
        if (tokens.marketToken == address(0)) revert InvalidConfig("externalTokens.marketToken");
        if (tokens.valueToken == tokens.marketToken) revert InvalidConfig("externalTokens.distinctTokens");
        if (tokens.valueTokenDecimals != REQUIRED_VALUE_TOKEN_DECIMALS) {
            revert InvalidConfig("externalTokens.valueTokenDecimalsMustBe6");
        }
        _requireCode("externalTokens.valueToken", tokens.valueToken);
        _requireDecimals(tokens.valueToken, tokens.valueTokenDecimals);
        if (skipMarketTokenValidation) {
            if (block.chainid != ROBINHOOD_TESTNET_CHAIN_ID) {
                revert InvalidConfig("deployment.skipMarketTokenValidationOnlyOnRobinhoodTestnet");
            }
        } else {
            _requireCode("externalTokens.marketToken", tokens.marketToken);
            _requireDecimals(tokens.marketToken, tokens.marketTokenDecimals);
        }

        if (bytes(config.deepToken.name).length == 0) revert InvalidConfig("deepToken.name");
        if (bytes(config.deepToken.symbol).length == 0) revert InvalidConfig("deepToken.symbol");
        if (bytes(config.vault.name).length == 0) revert InvalidConfig("vault.name");
        if (bytes(config.vault.symbol).length == 0) revert InvalidConfig("vault.symbol");
        _validateMinters(config.deepToken.initialMinters, config.environment.expectedDeployer);

        if (config.router.feeBps > MAX_ROUTER_FEE_BPS) revert InvalidConfig("router.feeBps");
        if (config.router.useVaultAsFeeRecipient) {
            if (config.router.feeRecipient != address(0)) revert InvalidConfig("router.feeRecipientMustBeZero");
        } else if (config.router.feeBps != 0 && config.router.feeRecipient == address(0)) {
            revert InvalidConfig("router.feeRecipient");
        }

        GovernanceConfig memory governance = config.governance;
        if (block.timestamp > type(uint48).max || governance.startDelay > type(uint48).max - block.timestamp) {
            revert InvalidConfig("governance.startDelay");
        }
        if (governance.votingDelay < MIN_VOTING_DELAY || governance.votingDelay > MAX_VOTING_DELAY) {
            revert InvalidConfig("governance.votingDelay");
        }
        if (governance.votingPeriod == 0 || governance.votingPeriod > MAX_VOTING_PERIOD) {
            revert InvalidConfig("governance.votingPeriod");
        }
        if (
            governance.proposalThresholdNumerator == 0
                || governance.proposalThresholdNumerator > GOVERNANCE_PERCENT_DENOMINATOR
        ) {
            revert InvalidConfig("governance.proposalThresholdNumerator");
        }
        if (governance.quorumNumerator == 0 || governance.quorumNumerator > GOVERNANCE_PERCENT_DENOMINATOR) {
            revert InvalidConfig("governance.quorumNumerator");
        }
        if (governance.voteExtension > MAX_VOTE_EXTENSION) revert InvalidConfig("governance.voteExtension");

        RewarderConfig memory rewarder = config.rewarder;
        if (rewarder.sideEmissionCap == 0) revert InvalidConfig("rewarder.sideEmissionCap");
        if (rewarder.initialFunding != uint256(rewarder.sideEmissionCap) * 2) {
            revert InvalidConfig("rewarder.initialFunding");
        }
        if (rewarder.emissionDuration < MIN_EMISSION_DURATION) {
            revert InvalidConfig("rewarder.emissionDuration");
        }
        _validateQuantitySchedule("rewarder.marketQuantity", rewarder.marketStartQuantity, rewarder.marketMaxQuantity);
        _validateQuantitySchedule("rewarder.valueQuantity", rewarder.valueStartQuantity, rewarder.valueMaxQuantity);
    }

    function _verifyDeployment(Config memory config, Deployment memory deployment, uint48 deployedAt) internal view {
        _verifyCode("DeepstateToken.code", address(deployment.deepstateToken));
        _verifyCode("DeepstateVault.code", address(deployment.stateVault));
        _verifyCode("DeepstateGovernor.code", address(deployment.governor));
        _verifyCode("DeepstateV1.code", address(deployment.router));
        _verifyCode("DeepstateRewarder.code", address(deployment.marketRewarder));

        _verifyTokenAndVault(config, deployment);
        _verifyAuthority(config, deployment);
        _verifyGovernance(config, deployment, deployedAt);
        _verifyRewarder(config, deployment);
        _verifyRouterHooks(config, deployment);
        _verifyRouterFee(config, deployment);
    }

    function _verifyTokenAndVault(Config memory config, Deployment memory deployment) private view {
        DeepstateToken token = deployment.deepstateToken;
        DeepstateVault vault = deployment.stateVault;

        _verify(_same(token.name(), config.deepToken.name), "DeepstateToken.name");
        _verify(_same(token.symbol(), config.deepToken.symbol), "DeepstateToken.symbol");
        _verify(token.decimals() == 18, "DeepstateToken.decimals");
        _verify(_same(vault.name(), config.vault.name), "DeepstateVault.name");
        _verify(_same(vault.symbol(), config.vault.symbol), "DeepstateVault.symbol");
        _verify(vault.decimals() == 18, "DeepstateVault.decimals");
        _verify(vault.asset() == address(token), "DeepstateVault.asset");
        _verify(vault.depositToken() == address(token), "DeepstateVault.depositToken");
        _verify(vault.valueToken() == config.externalTokens.valueToken, "DeepstateVault.valueToken");
        _verify(vault.totalSupply() == 0, "DeepstateVault.initialSupply");
        _verify(vault.totalBurnedDepositAssets() == 0, "DeepstateVault.initialBurnedAssets");
        _verify(_same(vault.CLOCK_MODE(), "mode=timestamp"), "DeepstateVault.clockMode");
    }

    function _verifyAuthority(Config memory config, Deployment memory deployment) private view {
        DeepstateToken token = deployment.deepstateToken;
        DeepstateRewarder rewarder = deployment.marketRewarder;
        address governorAddress = address(deployment.governor);

        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();
        bytes32 minterRole = token.MINTER_ROLE();
        _verify(token.hasRole(adminRole, governorAddress), "DeepstateToken.governorAdmin");
        _verify(!token.hasRole(adminRole, config.environment.expectedDeployer), "DeepstateToken.deployerAdmin");
        _verify(token.defaultAdminCount() == 1, "DeepstateToken.adminCount");
        _verify(!token.hasRole(minterRole, config.environment.expectedDeployer), "DeepstateToken.deployerMinter");
        _verify(!token.hasRole(minterRole, address(rewarder)), "DeepstateToken.rewarderMinter");
        for (uint256 i; i < config.deepToken.initialMinters.length; ++i) {
            _verify(token.hasRole(minterRole, config.deepToken.initialMinters[i]), "DeepstateToken.initialMinter");
        }
        _verify(token.totalSupply() == config.rewarder.initialFunding, "DeepstateToken.initialSupply");
        _verify(
            token.balanceOf(address(rewarder)) == config.rewarder.initialFunding, "DeepstateRewarder.initialFunding"
        );

        _verify(deployment.stateVault.owner() == governorAddress, "DeepstateVault.owner");
        _verify(rewarder.owner() == governorAddress, "DeepstateRewarder.owner");
        _verify(deployment.router.owner() == governorAddress, "DeepstateV1.owner");
    }

    function _verifyGovernance(Config memory config, Deployment memory deployment, uint48 deployedAt) private view {
        DeepstateGovernor governor = deployment.governor;

        _verify(address(governor.token()) == address(deployment.stateVault), "DeepstateGovernor.token");
        _verify(governor.votingDelay() == config.governance.votingDelay, "DeepstateGovernor.votingDelay");
        _verify(governor.votingPeriod() == config.governance.votingPeriod, "DeepstateGovernor.votingPeriod");
        _verify(
            governor.proposalThresholdNumerator() == config.governance.proposalThresholdNumerator,
            "DeepstateGovernor.proposalThreshold"
        );
        _verify(governor.quorumNumerator() == config.governance.quorumNumerator, "DeepstateGovernor.quorum");
        _verify(
            governor.lateQuorumVoteExtension() == config.governance.voteExtension, "DeepstateGovernor.voteExtension"
        );
        _verify(!governor.proposalNeedsQueuing(0), "DeepstateGovernor.noTimelock");
        if (deployedAt != 0) {
            _verify(
                governor.governanceStart() == deployedAt + config.governance.startDelay,
                "DeepstateGovernor.governanceStart"
            );
        } else {
            _verify(
                governor.governanceStart() <= block.timestamp + config.governance.startDelay,
                "DeepstateGovernor.governanceStartRange"
            );
        }
    }

    function _verifyRewarder(Config memory config, Deployment memory deployment) private view {
        DeepstateRewarder rewarder = deployment.marketRewarder;
        DeepstateV1 router = deployment.router;
        (address token0, address token1) =
            _sortTokens(config.externalTokens.marketToken, config.externalTokens.valueToken);
        bytes32 rewardPoolId = router.poolId(token0, token1);

        _verify(rewarder.deepstate() == address(router), "DeepstateRewarder.deepstate");
        _verify(rewarder.rewardToken() == address(deployment.deepstateToken), "DeepstateRewarder.rewardToken");
        _verify(rewarder.poolId() == rewardPoolId, "DeepstateRewarder.poolId");
        _verify(rewarder.token0() == token0, "DeepstateRewarder.token0");
        _verify(rewarder.token1() == token1, "DeepstateRewarder.token1");
        _verify(rewarder.sideEmissionCap() == config.rewarder.sideEmissionCap, "DeepstateRewarder.sideCap");
        _verify(rewarder.emissionDuration() == config.rewarder.emissionDuration, "DeepstateRewarder.emissionDuration");
        if (config.externalTokens.marketToken == token0) {
            _verify(
                rewarder.token0StartQuantity() == config.rewarder.marketStartQuantity,
                "DeepstateRewarder.marketStartQuantity"
            );
            _verify(
                rewarder.token0MaxQuantity() == config.rewarder.marketMaxQuantity, "DeepstateRewarder.marketMaxQuantity"
            );
            _verify(
                rewarder.token1StartQuantity() == config.rewarder.valueStartQuantity,
                "DeepstateRewarder.valueStartQuantity"
            );
            _verify(
                rewarder.token1MaxQuantity() == config.rewarder.valueMaxQuantity, "DeepstateRewarder.valueMaxQuantity"
            );
        } else {
            _verify(
                rewarder.token1StartQuantity() == config.rewarder.marketStartQuantity,
                "DeepstateRewarder.marketStartQuantity"
            );
            _verify(
                rewarder.token1MaxQuantity() == config.rewarder.marketMaxQuantity, "DeepstateRewarder.marketMaxQuantity"
            );
            _verify(
                rewarder.token0StartQuantity() == config.rewarder.valueStartQuantity,
                "DeepstateRewarder.valueStartQuantity"
            );
            _verify(
                rewarder.token0MaxQuantity() == config.rewarder.valueMaxQuantity, "DeepstateRewarder.valueMaxQuantity"
            );
        }
    }

    function _verifyRouterHooks(Config memory config, Deployment memory deployment) private view {
        DeepstateV1 router = deployment.router;
        (address token0, address token1) =
            _sortTokens(config.externalTokens.marketToken, config.externalTokens.valueToken);
        bytes32 rewardPoolId = router.poolId(token0, token1);
        (bool token0Active, bool token1Active) = _hookFlags(config, token0);
        address expectedHook = token0Active || token1Active ? address(deployment.marketRewarder) : address(0);
        _verify(router.poolHook(rewardPoolId) == expectedHook, "DeepstateV1.poolHook");
        // DeepstateV1 currently has no public hook-flag getter. Slot 2 is pinned by its
        // compiler storage layout; deployment tests fail if that dependency layout changes.
        bytes32 poolConfigSlot = keccak256(abi.encode(rewardPoolId, _ROUTER_POOL_CONFIG_MAPPING_SLOT));
        uint256 poolConfig = uint256(vm.load(address(router), poolConfigSlot));
        _verify((poolConfig & _ROUTER_TOKEN0_HOOK_FLAG != 0) == token0Active, "DeepstateV1.token0HookActive");
        _verify((poolConfig & _ROUTER_TOKEN1_HOOK_FLAG != 0) == token1Active, "DeepstateV1.token1HookActive");
    }

    function _verifyRouterFee(Config memory config, Deployment memory deployment) private view {
        DeepstateV1 router = deployment.router;
        (address feeRecipient, uint16 feeBps) = router.feeConfig();
        _verify(feeRecipient == _feeRecipient(config, deployment), "DeepstateV1.feeRecipient");
        _verify(feeBps == config.router.feeBps, "DeepstateV1.feeBps");
    }

    function _parseConfig(string memory json) internal pure returns (Config memory config) {
        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        if (schemaVersion != CONFIG_SCHEMA_VERSION) {
            revert ConfigSchemaMismatch(CONFIG_SCHEMA_VERSION, schemaVersion);
        }
        config.environment.expectedChainId = vm.parseJsonUint(json, ".deployment.expectedChainId");
        config.environment.expectedDeployer = vm.parseJsonAddress(json, ".deployment.expectedDeployer");

        config.externalTokens.valueToken = vm.parseJsonAddress(json, ".externalTokens.valueToken");
        config.externalTokens.valueTokenDecimals =
            _toUint8(vm.parseJsonUint(json, ".externalTokens.valueTokenDecimals"), "externalTokens.valueTokenDecimals");
        config.externalTokens.marketToken = vm.parseJsonAddress(json, ".externalTokens.marketToken");
        config.externalTokens.marketTokenDecimals = _toUint8(
            vm.parseJsonUint(json, ".externalTokens.marketTokenDecimals"), "externalTokens.marketTokenDecimals"
        );

        config.deepToken.name = vm.parseJsonString(json, ".deepToken.name");
        config.deepToken.symbol = vm.parseJsonString(json, ".deepToken.symbol");
        config.deepToken.initialMinters = vm.parseJsonAddressArray(json, ".deepToken.initialMinters");
        config.vault.name = vm.parseJsonString(json, ".vault.name");
        config.vault.symbol = vm.parseJsonString(json, ".vault.symbol");

        config.router.feeBps = _toUint16(vm.parseJsonUint(json, ".router.feeBps"), "router.feeBps");
        config.router.useVaultAsFeeRecipient = vm.parseJsonBool(json, ".router.useVaultAsFeeRecipient");
        config.router.feeRecipient = vm.parseJsonAddress(json, ".router.feeRecipient");

        config.governance.startDelay =
            _toUint48(vm.parseJsonUint(json, ".governance.startDelay"), "governance.startDelay");
        config.governance.votingDelay =
            _toUint48(vm.parseJsonUint(json, ".governance.votingDelay"), "governance.votingDelay");
        config.governance.votingPeriod =
            _toUint32(vm.parseJsonUint(json, ".governance.votingPeriod"), "governance.votingPeriod");
        config.governance.proposalThresholdNumerator = vm.parseJsonUint(json, ".governance.proposalThresholdNumerator");
        config.governance.quorumNumerator = vm.parseJsonUint(json, ".governance.quorumNumerator");
        config.governance.voteExtension =
            _toUint48(vm.parseJsonUint(json, ".governance.voteExtension"), "governance.voteExtension");

        config.rewarder.sideEmissionCap =
            _toUint96(vm.parseJsonUint(json, ".rewarder.sideEmissionCap"), "rewarder.sideEmissionCap");
        config.rewarder.initialFunding = vm.parseJsonUint(json, ".rewarder.initialFunding");
        config.rewarder.emissionDuration =
            _toUint32(vm.parseJsonUint(json, ".rewarder.emissionDuration"), "rewarder.emissionDuration");
        config.rewarder.marketStartQuantity =
            _toUint160(vm.parseJsonUint(json, ".rewarder.marketStartQuantity"), "rewarder.marketStartQuantity");
        config.rewarder.marketMaxQuantity =
            _toUint160(vm.parseJsonUint(json, ".rewarder.marketMaxQuantity"), "rewarder.marketMaxQuantity");
        config.rewarder.valueStartQuantity =
            _toUint160(vm.parseJsonUint(json, ".rewarder.valueStartQuantity"), "rewarder.valueStartQuantity");
        config.rewarder.valueMaxQuantity =
            _toUint160(vm.parseJsonUint(json, ".rewarder.valueMaxQuantity"), "rewarder.valueMaxQuantity");
        config.rewarder.marketBuySideActive = vm.parseJsonBool(json, ".rewarder.marketBuySideActive");
        config.rewarder.valueBuySideActive = vm.parseJsonBool(json, ".rewarder.valueBuySideActive");
    }

    function _deploymentFromManifest(string memory json, bytes32 expectedConfigHash)
        internal
        view
        returns (Deployment memory deployment)
    {
        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        if (schemaVersion != MANIFEST_SCHEMA_VERSION) {
            revert ManifestSchemaMismatch(MANIFEST_SCHEMA_VERSION, schemaVersion);
        }
        uint256 manifestChainId = vm.parseJsonUint(json, ".chainId");
        if (manifestChainId != block.chainid) revert WrongChain(manifestChainId, block.chainid);
        bytes32 manifestConfigHash = vm.parseJsonBytes32(json, ".configHash");
        if (manifestConfigHash != expectedConfigHash) {
            revert ManifestConfigMismatch(expectedConfigHash, manifestConfigHash);
        }

        deployment.deepstateToken = DeepstateToken(vm.parseJsonAddress(json, ".deepstateToken"));
        deployment.stateVault = DeepstateVault(payable(vm.parseJsonAddress(json, ".stateVault")));
        deployment.governor = DeepstateGovernor(payable(vm.parseJsonAddress(json, ".governor")));
        deployment.router = DeepstateV1(payable(vm.parseJsonAddress(json, ".router")));
        deployment.marketRewarder = DeepstateRewarder(vm.parseJsonAddress(json, ".marketRewarder"));
    }

    function _writeManifest(
        Config memory config,
        Deployment memory deployment,
        bytes32 configHash,
        string memory outputPath,
        bool liveRpcVerificationPassed
    ) internal {
        _writeManifest(config, deployment, configHash, outputPath, liveRpcVerificationPassed, false);
    }

    function _writeManifest(
        Config memory config,
        Deployment memory deployment,
        bytes32 configHash,
        string memory outputPath,
        bool liveRpcVerificationPassed,
        bool marketTokenValidationSkipped
    ) internal {
        string memory objectKey = "deepstate-production-deployment";
        vm.serializeUint(objectKey, "schemaVersion", MANIFEST_SCHEMA_VERSION);
        vm.serializeUint(objectKey, "chainId", block.chainid);
        vm.serializeBytes32(objectKey, "configHash", configHash);
        vm.serializeAddress(objectKey, "deployer", config.environment.expectedDeployer);
        vm.serializeAddress(objectKey, "valueToken", config.externalTokens.valueToken);
        vm.serializeAddress(objectKey, "marketToken", config.externalTokens.marketToken);
        vm.serializeBool(objectKey, "marketTokenValidationSkipped", marketTokenValidationSkipped);
        vm.serializeAddress(objectKey, "deepstateToken", address(deployment.deepstateToken));
        vm.serializeAddress(objectKey, "stateVault", address(deployment.stateVault));
        vm.serializeAddress(objectKey, "governor", address(deployment.governor));
        vm.serializeAddress(objectKey, "router", address(deployment.router));
        vm.serializeAddress(objectKey, "marketRewarder", address(deployment.marketRewarder));
        vm.serializeAddress(objectKey, "initialMinters", config.deepToken.initialMinters);

        (address token0, address token1) =
            _sortTokens(config.externalTokens.marketToken, config.externalTokens.valueToken);
        vm.serializeAddress(objectKey, "poolToken0", token0);
        vm.serializeAddress(objectKey, "poolToken1", token1);
        vm.serializeBytes32(objectKey, "rewardPoolId", deployment.router.poolId(token0, token1));
        vm.serializeAddress(objectKey, "routerFeeRecipient", _feeRecipient(config, deployment));
        vm.serializeUint(objectKey, "routerFeeBps", config.router.feeBps);
        vm.serializeBool(objectKey, "marketBuySideActive", config.rewarder.marketBuySideActive);
        vm.serializeBool(objectKey, "valueBuySideActive", config.rewarder.valueBuySideActive);
        vm.serializeUint(objectKey, "governanceStart", deployment.governor.governanceStart());
        vm.serializeUint(objectKey, "verificationBlock", block.number);
        vm.serializeUint(objectKey, "verificationTimestamp", block.timestamp);
        vm.serializeBool(objectKey, "simulationVerificationPassed", true);
        string memory manifest = vm.serializeBool(objectKey, "liveRpcVerificationPassed", liveRpcVerificationPassed);
        vm.writeJson(manifest, outputPath);
    }

    function _feeRecipient(Config memory config, Deployment memory deployment) internal pure returns (address) {
        return config.router.useVaultAsFeeRecipient ? address(deployment.stateVault) : config.router.feeRecipient;
    }

    function _hookFlags(Config memory config, address token0)
        internal
        pure
        returns (bool token0Active, bool token1Active)
    {
        if (config.externalTokens.marketToken == token0) {
            return (config.rewarder.marketBuySideActive, config.rewarder.valueBuySideActive);
        }
        return (config.rewarder.valueBuySideActive, config.rewarder.marketBuySideActive);
    }

    function _validateMinters(address[] memory minters, address deployer) internal pure {
        for (uint256 i; i < minters.length; ++i) {
            address minter = minters[i];
            if (minter == address(0) || minter == deployer) revert InvalidConfig("deepToken.initialMinters");
            for (uint256 j; j < i; ++j) {
                if (minter == minters[j]) revert InvalidConfig("deepToken.duplicateMinter");
            }
        }
    }

    function _validateQuantitySchedule(string memory field, uint160 start, uint160 maximum) internal pure {
        if (start == 0 || maximum <= start || uint256(maximum) / start < MIN_QUANTITY_GROWTH) {
            revert InvalidConfig(field);
        }
    }

    function _sortTokens(address a, address b) internal pure returns (address token0, address token1) {
        if (a == address(0) || b == address(0) || a == b) revert InvalidConfig("externalTokens.rewardPool");
        return a < b ? (a, b) : (b, a);
    }

    function _requireCode(string memory field, address account) private view {
        if (account.code.length == 0) revert MissingCode(field, account);
    }

    function _requireDecimals(address token, uint8 expected) private view {
        uint8 actual = IERC20Metadata(token).decimals();
        if (actual != expected) revert TokenDecimalsMismatch(token, expected, actual);
    }

    function _verifyCode(string memory check, address account) private view {
        if (account.code.length == 0) revert DeploymentVerificationFailed(check);
    }

    function _verify(bool condition, string memory check) private pure {
        if (!condition) revert DeploymentVerificationFailed(check);
    }

    function _same(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _toUint8(uint256 value, string memory field) internal pure returns (uint8) {
        if (value > type(uint8).max) revert ConfigValueOutOfRange(field, value, type(uint8).max);
        // Value is explicitly bounded above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(value);
    }

    function _toUint16(uint256 value, string memory field) internal pure returns (uint16) {
        if (value > type(uint16).max) revert ConfigValueOutOfRange(field, value, type(uint16).max);
        // Value is explicitly bounded above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(value);
    }

    function _toUint32(uint256 value, string memory field) internal pure returns (uint32) {
        if (value > type(uint32).max) revert ConfigValueOutOfRange(field, value, type(uint32).max);
        // Value is explicitly bounded above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(value);
    }

    function _toUint48(uint256 value, string memory field) internal pure returns (uint48) {
        if (value > type(uint48).max) revert ConfigValueOutOfRange(field, value, type(uint48).max);
        // Value is explicitly bounded above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint48(value);
    }

    function _toUint96(uint256 value, string memory field) internal pure returns (uint96) {
        if (value > type(uint96).max) revert ConfigValueOutOfRange(field, value, type(uint96).max);
        // Value is explicitly bounded above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint96(value);
    }

    function _toUint160(uint256 value, string memory field) internal pure returns (uint160) {
        if (value > type(uint160).max) revert ConfigValueOutOfRange(field, value, type(uint160).max);
        // Value is explicitly bounded above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(value);
    }

    function _logDeployment(Deployment memory deployment, string memory outputPath) internal pure {
        console2.log("Deepstate production deployment verified");
        console2.log("DeepstateToken", address(deployment.deepstateToken));
        console2.log("DeepstateVault", address(deployment.stateVault));
        console2.log("DeepstateGovernor", address(deployment.governor));
        console2.log("DeepstateV1", address(deployment.router));
        console2.log("DeepstateRewarder", address(deployment.marketRewarder));
        console2.log("Address manifest", outputPath);
    }
}
