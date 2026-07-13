// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {FeeFlowController} from "fee-flow/FeeFlowController.sol";
import {EthereumVaultConnector} from "evc/EthereumVaultConnector.sol";
import {DeepstateV1} from "deepstate-contracts/DeepstateV1.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeepstateGovernor} from "../src/DeepstateGovernor.sol";
import {DeepstateRewarder} from "../src/DeepstateRewarder.sol";
import {DeepstateToken} from "../src/DeepstateToken.sol";
import {DeepstateVault} from "../src/DeepstateVault.sol";

contract DeployDeepstate is Script {
    uint256 internal constant DEFAULT_FEE_FLOW_INIT_PRICE = 100e6;
    uint256 internal constant DEFAULT_FEE_FLOW_EPOCH_PERIOD = 14 days;
    uint256 internal constant DEFAULT_FEE_FLOW_PRICE_MULTIPLIER = 2e18;
    uint256 internal constant DEFAULT_FEE_FLOW_MIN_INIT_PRICE = 1e6;

    uint48 internal constant DEFAULT_VOTING_DELAY = 1 days;
    uint32 internal constant DEFAULT_VOTING_PERIOD = 1 weeks;
    uint256 internal constant DEFAULT_PROPOSAL_THRESHOLD = 0;
    uint256 internal constant DEFAULT_QUORUM_NUMERATOR = 4;
    uint48 internal constant DEFAULT_VOTE_EXTENSION = 1 days;

    struct Deployment {
        DeepstateToken deepstate;
        DeepstateVault vault;
        DeepstateGovernor governor;
        DeepstateV1 router;
        DeepstateRewarder rewarder;
        EthereumVaultConnector evc;
        FeeFlowController feeFlow;
    }

    struct Config {
        address deployer;
        address valueToken;
        address wrappedNative;
        address rewardTokenOverride;
        address deepstateMinter;
        string tokenName;
        string tokenSymbol;
        string vaultName;
        string vaultSymbol;
        uint16 routerFeeBps;
        uint256 feeFlowInitPrice;
        uint256 feeFlowEpochPeriod;
        uint256 feeFlowPriceMultiplier;
        uint256 feeFlowMinInitPrice;
        uint48 votingDelay;
        uint32 votingPeriod;
        uint256 proposalThreshold;
        uint256 quorumNumerator;
        uint48 voteExtension;
    }

    function run() external returns (Deployment memory deployment) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        Config memory config = _readConfig(vm.addr(deployerPrivateKey));

        vm.startBroadcast(deployerPrivateKey);

        deployment.deepstate = new DeepstateToken(config.deployer, config.tokenName, config.tokenSymbol);
        deployment.router = new DeepstateV1();
        deployment.vault = new DeepstateVault(
            config.deployer,
            address(deployment.deepstate),
            config.valueToken,
            config.wrappedNative,
            config.vaultName,
            config.vaultSymbol
        );
        deployment.evc = new EthereumVaultConnector();
        deployment.feeFlow = new FeeFlowController(
            address(deployment.evc),
            config.feeFlowInitPrice,
            config.valueToken,
            address(deployment.vault),
            config.feeFlowEpochPeriod,
            config.feeFlowPriceMultiplier,
            config.feeFlowMinInitPrice
        );

        address rewardToken =
            config.rewardTokenOverride == address(0) ? address(deployment.deepstate) : config.rewardTokenOverride;
        deployment.rewarder = new DeepstateRewarder(config.deployer, address(deployment.router), rewardToken);
        deployment.governor = new DeepstateGovernor(
            IERC20(address(deployment.vault)),
            config.votingDelay,
            config.votingPeriod,
            config.proposalThreshold,
            config.quorumNumerator,
            config.voteExtension
        );

        deployment.vault.setAuction(address(deployment.feeFlow));
        if (config.deepstateMinter != address(0)) deployment.deepstate.setMinter(config.deepstateMinter);
        if (config.routerFeeBps != 0) deployment.router.setFeeConfig(address(deployment.vault), config.routerFeeBps);

        address governor = address(deployment.governor);
        deployment.deepstate.transferOwnership(governor);
        deployment.vault.transferOwnership(governor);
        deployment.rewarder.transferOwnership(governor);
        deployment.router.transferOwnership(governor);

        require(deployment.deepstate.owner() == governor, "DEEP_OWNER");
        require(deployment.vault.owner() == governor, "VAULT_OWNER");
        require(deployment.rewarder.owner() == governor, "REWARDER_OWNER");
        require(deployment.router.owner() == governor, "ROUTER_OWNER");
        require(deployment.vault.auction() == address(deployment.feeFlow), "VAULT_AUCTION");
        require(deployment.rewarder.engine() == address(deployment.router), "REWARDER_ENGINE");

        vm.stopBroadcast();

        _logDeployment(deployment);
    }

    function _readConfig(address deployer) internal view returns (Config memory config) {
        config.deployer = deployer;
        config.valueToken = vm.envAddress("VALUE_TOKEN");
        config.wrappedNative = vm.envOr("WRAPPED_NATIVE", address(0));
        config.rewardTokenOverride = vm.envOr("REWARD_TOKEN", address(0));
        config.deepstateMinter = vm.envOr("DEEP_MINTER", address(0));
        config.tokenName = vm.envOr("DEEP_TOKEN_NAME", string("Deepstate"));
        config.tokenSymbol = vm.envOr("DEEP_TOKEN_SYMBOL", string("DEEP"));
        config.vaultName = vm.envOr("DEEP_VAULT_NAME", string("vDeep"));
        config.vaultSymbol = vm.envOr("DEEP_VAULT_SYMBOL", string("vDEEP"));
        config.routerFeeBps = _toUint16(vm.envOr("ROUTER_FEE_BPS", uint256(0)));
        config.feeFlowInitPrice = vm.envOr("FEE_FLOW_INIT_PRICE", DEFAULT_FEE_FLOW_INIT_PRICE);
        config.feeFlowEpochPeriod = vm.envOr("FEE_FLOW_EPOCH_PERIOD", DEFAULT_FEE_FLOW_EPOCH_PERIOD);
        config.feeFlowPriceMultiplier = vm.envOr("FEE_FLOW_PRICE_MULTIPLIER", DEFAULT_FEE_FLOW_PRICE_MULTIPLIER);
        config.feeFlowMinInitPrice = vm.envOr("FEE_FLOW_MIN_INIT_PRICE", DEFAULT_FEE_FLOW_MIN_INIT_PRICE);
        config.votingDelay = _toUint48(vm.envOr("GOVERNOR_VOTING_DELAY", uint256(DEFAULT_VOTING_DELAY)));
        config.votingPeriod = _toUint32(vm.envOr("GOVERNOR_VOTING_PERIOD", uint256(DEFAULT_VOTING_PERIOD)));
        config.proposalThreshold = vm.envOr("GOVERNOR_PROPOSAL_THRESHOLD", DEFAULT_PROPOSAL_THRESHOLD);
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

    function _logDeployment(Deployment memory deployment) internal pure {
        console2.log("DeepstateToken", address(deployment.deepstate));
        console2.log("DeepstateVault", address(deployment.vault));
        console2.log("DeepstateGovernor", address(deployment.governor));
        console2.log("DeepstateV1", address(deployment.router));
        console2.log("DeepstateRewarder", address(deployment.rewarder));
        console2.log("EthereumVaultConnector", address(deployment.evc));
        console2.log("FeeFlowController", address(deployment.feeFlow));
    }
}
