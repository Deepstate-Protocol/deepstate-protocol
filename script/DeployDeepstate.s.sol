// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {DeepstateV1} from "deepstate-contracts/DeepstateV1.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {DeepstateGovernor} from "../src/DeepstateGovernor.sol";
import {DeepstateRewarder} from "../src/DeepstateRewarder.sol";
import {DeepstateToken} from "../src/DeepstateToken.sol";
import {DeepstateVault} from "../src/DeepstateVault.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

contract DeployDeepstate is Script {
    uint16 internal constant DEFAULT_ROUTER_FEE_BPS = 10;

    uint48 internal constant DEFAULT_GOVERNANCE_START_DELAY = 15 days;
    uint48 internal constant DEFAULT_VOTING_DELAY = 3 days;
    uint32 internal constant DEFAULT_VOTING_PERIOD = 1 weeks;
    uint256 internal constant DEFAULT_PROPOSAL_THRESHOLD_NUMERATOR = 1;
    uint256 internal constant DEFAULT_QUORUM_NUMERATOR = 10;
    uint48 internal constant DEFAULT_VOTE_EXTENSION = 1 days;

    uint96 internal constant NVDA_SIDE_EMISSION_CAP = 500_000_000e18;
    uint96 internal constant DEEP_SIDE_EMISSION_CAP = 250_000_000e18;
    uint32 internal constant NVDA_EMISSION_DURATION = 395 days;
    uint32 internal constant DEEP_EMISSION_DURATION = 60 days;

    uint160 internal constant USDG_START_QUANTITY = 1e6;
    uint160 internal constant USDG_MAX_QUANTITY = 1_000_000e6;
    uint160 internal constant NVDA_START_QUANTITY = 1e18;
    uint160 internal constant NVDA_MAX_QUANTITY = 5_000e18;
    uint160 internal constant DEEP_START_QUANTITY = 1e18;
    uint160 internal constant DEEP_MAX_QUANTITY = 1_000_000e18;

    struct Deployment {
        DeepstateToken deepstate;
        DeepstateVault vault;
        DeepstateGovernor governor;
        DeepstateV1 router;
        DeepstateRewarder nvdaRewarder;
        DeepstateRewarder deepRewarder;
    }

    struct Config {
        address deployer;
        address valueToken;
        address nvdaToken;
        address deepstateMinter;
        string tokenName;
        string tokenSymbol;
        string vaultName;
        string vaultSymbol;
        uint16 routerFeeBps;
        uint48 governanceStartDelay;
        uint48 votingDelay;
        uint32 votingPeriod;
        uint256 proposalThresholdNumerator;
        uint256 quorumNumerator;
        uint48 voteExtension;
    }

    function run() external returns (Deployment memory deployment) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        Config memory config = _readConfig(vm.addr(deployerPrivateKey));

        vm.startBroadcast(deployerPrivateKey);
        deployment = _deploy(config);
        vm.stopBroadcast();

        _logDeployment(deployment);
    }

    function _deploy(Config memory config) internal returns (Deployment memory deployment) {
        require(IERC20Decimals(config.valueToken).decimals() == 6, "VALUE_TOKEN_DECIMALS");
        require(IERC20Decimals(config.nvdaToken).decimals() == 18, "NVDA_TOKEN_DECIMALS");

        deployment.deepstate = new DeepstateToken(config.deployer, config.tokenName, config.tokenSymbol);
        deployment.router = new DeepstateV1();
        deployment.vault = new DeepstateVault(
            config.deployer, address(deployment.deepstate), config.valueToken, config.vaultName, config.vaultSymbol
        );

        deployment.nvdaRewarder = _deployRewarder(
            config,
            deployment,
            config.nvdaToken,
            NVDA_SIDE_EMISSION_CAP,
            NVDA_EMISSION_DURATION,
            NVDA_START_QUANTITY,
            NVDA_MAX_QUANTITY
        );
        deployment.deepRewarder = _deployRewarder(
            config,
            deployment,
            address(deployment.deepstate),
            DEEP_SIDE_EMISSION_CAP,
            DEEP_EMISSION_DURATION,
            DEEP_START_QUANTITY,
            DEEP_MAX_QUANTITY
        );
        deployment.governor = new DeepstateGovernor(
            IVotes(address(deployment.vault)),
            config.governanceStartDelay,
            config.votingDelay,
            config.votingPeriod,
            config.proposalThresholdNumerator,
            config.quorumNumerator,
            config.voteExtension
        );

        bytes32 minterRole = deployment.deepstate.MINTER_ROLE();
        deployment.deepstate.grantRole(minterRole, address(deployment.nvdaRewarder));
        deployment.deepstate.grantRole(minterRole, address(deployment.deepRewarder));
        if (config.deepstateMinter != address(0)) deployment.deepstate.grantRole(minterRole, config.deepstateMinter);
        if (config.routerFeeBps != 0) deployment.router.setFeeConfig(address(deployment.vault), config.routerFeeBps);

        address governor = address(deployment.governor);
        bytes32 adminRole = deployment.deepstate.DEFAULT_ADMIN_ROLE();
        deployment.deepstate.grantRole(adminRole, governor);
        deployment.deepstate.renounceRole(adminRole, config.deployer);
        deployment.vault.transferOwnership(governor);
        deployment.nvdaRewarder.transferOwnership(governor);
        deployment.deepRewarder.transferOwnership(governor);
        deployment.router.transferOwnership(governor);

        require(deployment.deepstate.hasRole(adminRole, governor), "DEEP_ADMIN");
        require(!deployment.deepstate.hasRole(adminRole, config.deployer), "DEPLOYER_DEEP_ADMIN");
        require(deployment.deepstate.hasRole(minterRole, address(deployment.nvdaRewarder)), "NVDA_REWARDER_MINTER");
        require(deployment.deepstate.hasRole(minterRole, address(deployment.deepRewarder)), "DEEP_REWARDER_MINTER");
        require(deployment.vault.owner() == governor, "VAULT_OWNER");
        require(deployment.nvdaRewarder.owner() == governor, "NVDA_REWARDER_OWNER");
        require(deployment.deepRewarder.owner() == governor, "DEEP_REWARDER_OWNER");
        require(deployment.router.owner() == governor, "ROUTER_OWNER");
        require(deployment.nvdaRewarder.deepstate() == address(deployment.router), "NVDA_REWARDER_DEEPSTATE");
        require(deployment.deepRewarder.deepstate() == address(deployment.router), "DEEP_REWARDER_DEEPSTATE");
        require(
            deployment.router.poolHook(deployment.nvdaRewarder.poolId()) == address(deployment.nvdaRewarder),
            "NVDA_REWARDER_HOOK"
        );
        require(
            deployment.router.poolHook(deployment.deepRewarder.poolId()) == address(deployment.deepRewarder),
            "DEEP_REWARDER_HOOK"
        );
        require(
            deployment.governor.governanceStart() == block.timestamp + config.governanceStartDelay, "GOVERNANCE_START"
        );
        require(
            deployment.governor.proposalThresholdNumerator() == config.proposalThresholdNumerator, "PROPOSAL_THRESHOLD"
        );
        require(deployment.governor.quorumNumerator() == config.quorumNumerator, "QUORUM");
    }

    function _readConfig(address deployer) internal view returns (Config memory config) {
        config.deployer = deployer;
        config.valueToken = vm.envAddress("VALUE_TOKEN");
        config.nvdaToken = vm.envAddress("NVDA_TOKEN");
        config.deepstateMinter = vm.envOr("DEEP_MINTER", address(0));
        config.tokenName = vm.envOr("DEEP_TOKEN_NAME", string("Deepstate"));
        config.tokenSymbol = vm.envOr("DEEP_TOKEN_SYMBOL", string("DEEP"));
        config.vaultName = vm.envOr("DEEP_VAULT_NAME", string("Deepstate Governance"));
        config.vaultSymbol = vm.envOr("DEEP_VAULT_SYMBOL", string("STATE"));
        config.routerFeeBps = _toUint16(vm.envOr("ROUTER_FEE_BPS", uint256(DEFAULT_ROUTER_FEE_BPS)));
        config.governanceStartDelay =
            _toUint48(vm.envOr("GOVERNOR_START_DELAY", uint256(DEFAULT_GOVERNANCE_START_DELAY)));
        config.votingDelay = _toUint48(vm.envOr("GOVERNOR_VOTING_DELAY", uint256(DEFAULT_VOTING_DELAY)));
        config.votingPeriod = _toUint32(vm.envOr("GOVERNOR_VOTING_PERIOD", uint256(DEFAULT_VOTING_PERIOD)));
        config.proposalThresholdNumerator =
            vm.envOr("GOVERNOR_PROPOSAL_THRESHOLD_NUMERATOR", DEFAULT_PROPOSAL_THRESHOLD_NUMERATOR);
        config.quorumNumerator = vm.envOr("GOVERNOR_QUORUM_NUMERATOR", DEFAULT_QUORUM_NUMERATOR);
        config.voteExtension = _toUint48(vm.envOr("GOVERNOR_VOTE_EXTENSION", uint256(DEFAULT_VOTE_EXTENSION)));
    }

    function _toUint16(uint256 value) internal pure returns (uint16) {
        require(value <= type(uint16).max, "UINT16_OVERFLOW");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(value);
    }

    function _toUint32(uint256 value) internal pure returns (uint32) {
        require(value <= type(uint32).max, "UINT32_OVERFLOW");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(value);
    }

    function _toUint48(uint256 value) internal pure returns (uint48) {
        require(value <= type(uint48).max, "UINT48_OVERFLOW");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint48(value);
    }

    function _sortTokens(address a, address b) internal pure returns (address token0, address token1) {
        require(a != b && a != address(0) && b != address(0), "INVALID_REWARD_POOL");
        return a < b ? (a, b) : (b, a);
    }

    function _deployRewarder(
        Config memory config,
        Deployment memory deployment,
        address marketToken,
        uint96 sideCap,
        uint32 duration,
        uint160 marketStartQuantity,
        uint160 marketMaxQuantity
    ) internal returns (DeepstateRewarder rewarder) {
        (address poolToken0, address poolToken1) = _sortTokens(marketToken, config.valueToken);
        bool marketIsToken0 = marketToken == poolToken0;
        uint160 token0Start = marketIsToken0 ? marketStartQuantity : USDG_START_QUANTITY;
        uint160 token0Max = marketIsToken0 ? marketMaxQuantity : USDG_MAX_QUANTITY;
        uint160 token1Start = marketIsToken0 ? USDG_START_QUANTITY : marketStartQuantity;
        uint160 token1Max = marketIsToken0 ? USDG_MAX_QUANTITY : marketMaxQuantity;
        bytes32 rewardPoolId = deployment.router.poolId(poolToken0, poolToken1);

        rewarder = new DeepstateRewarder(
            config.deployer,
            address(deployment.router),
            address(deployment.deepstate),
            rewardPoolId,
            poolToken0,
            poolToken1,
            sideCap,
            duration,
            token0Start,
            token0Max,
            token1Start,
            token1Max
        );
        deployment.router.setPoolHookConfig(poolToken0, poolToken1, address(rewarder), true, true);
    }

    function _logDeployment(Deployment memory deployment) internal pure {
        console2.log("DeepstateToken", address(deployment.deepstate));
        console2.log("DeepstateVault", address(deployment.vault));
        console2.log("DeepstateGovernor", address(deployment.governor));
        console2.log("DeepstateV1", address(deployment.router));
        console2.log("NVDA/USDG DeepstateRewarder", address(deployment.nvdaRewarder));
        console2.log("DEEP/USDG DeepstateRewarder", address(deployment.deepRewarder));
    }
}
