// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";

import {DeepstateRewarderV2} from "./DeepstateRewarderV2.sol";
import {DeepstateV1Controller} from "./DeepstateV1Controller.sol";
import {DeepstateToken} from "./DeepstateToken.sol";
import {IDeepstateMinterController} from "./interfaces/IDeepstateMinterController.sol";
import {IDeepstateV1} from "./interfaces/IDeepstateV1.sol";

/// @title Deepstate Rewarder Factory
/// @notice Governance-owned CREATE2 factory for operator-launched market reward programs.
/// @dev The factory must hold the minter controller's MINTER_ROLE and be the V1 controller's hook manager.
contract DeepstateRewarderFactory is Ownable {
    struct MarketConfig {
        address token0;
        address token1;
        uint160 token0StartQuantity;
        uint160 token0MaxQuantity;
        uint160 token1StartQuantity;
        uint160 token1MaxQuantity;
        bool token0Active;
        bool token1Active;
    }

    /// @notice Minimum interval between successful operator or governance market deployments.
    uint256 public constant DEPLOYMENT_COOLDOWN = 3 days;
    /// @notice Duration encoded into every factory rewarder.
    uint32 public constant EMISSION_DURATION = 395 days;
    /// @notice Maximum scheduled emissions for each side, for one billion DEEP total per market.
    uint96 public constant SIDE_EMISSION_CAP = 500_000_000e18;
    /// @notice Initial DEEP minted to each rewarder. Further funding requires governance.
    uint256 public constant INITIAL_FUNDING = 100_000_000e18;

    DeepstateV1Controller public immutable deepstateV1Controller;
    IDeepstateV1 public immutable deepstate;
    IDeepstateMinterController public immutable minterController;
    DeepstateToken public immutable rewardToken;

    /// @notice Revocable operator permitted to launch and retire factory markets.
    address public operator;
    /// @notice Earliest timestamp at which another market may be deployed.
    uint256 public nextDeploymentAt;
    /// @notice Nonce assigned to the next successful CREATE2 deployment.
    uint256 public deploymentCount;

    mapping(bytes32 poolId => address rewarder) public activeRewarder;
    mapping(address rewarder => bytes32 poolId) public rewarderPool;

    event OperatorSet(address indexed previousOperator, address indexed newOperator);
    event MarketDeployed(
        bytes32 indexed poolId,
        uint256 indexed deploymentNonce,
        address indexed rewarder,
        bytes32 salt,
        address token0,
        address token1,
        bool token0Active,
        bool token1Active
    );
    event MarketRemoved(bytes32 indexed poolId, address indexed rewarder, uint256 burnedAmount);

    error InvalidOwner();
    error InvalidDeepstateV1Controller();
    error DeepstateV1ControllerOwnerMismatch(address expected, address actual);
    error InvalidMinterController();
    error MinterControllerOwnerMismatch(address expected, address actual);
    error InvalidRewardToken();
    error InvalidPool();
    error InvalidHookFlags();
    error DeploymentCooldown(uint256 nextDeploymentAt);
    error ActiveMarketExists(bytes32 poolId, address rewarder);
    error ExistingPoolHook(bytes32 poolId, address hook);
    error UnexpectedPoolHook(bytes32 poolId, address expected, address actual);
    error MarketNotActive(bytes32 poolId);

    constructor(address owner_, address deepstateV1Controller_, address minterController_) {
        if (owner_ == address(0)) revert InvalidOwner();
        if (deepstateV1Controller_ == address(0) || deepstateV1Controller_.code.length == 0) {
            revert InvalidDeepstateV1Controller();
        }
        if (minterController_ == address(0) || minterController_.code.length == 0) {
            revert InvalidMinterController();
        }

        _initializeOwner(owner_);
        deepstateV1Controller = DeepstateV1Controller(deepstateV1Controller_);
        address deepstateV1ControllerOwner = deepstateV1Controller.owner();
        if (deepstateV1ControllerOwner != owner_) {
            revert DeepstateV1ControllerOwnerMismatch(owner_, deepstateV1ControllerOwner);
        }
        deepstate = deepstateV1Controller.deepstate();
        minterController = IDeepstateMinterController(minterController_);
        address minterControllerOwner = minterController.owner();
        if (minterControllerOwner != owner_) {
            revert MinterControllerOwnerMismatch(owner_, minterControllerOwner);
        }
        address deepstateToken_ = minterController.deepstateToken();
        if (deepstateToken_ == address(0) || deepstateToken_.code.length == 0) revert InvalidRewardToken();
        rewardToken = DeepstateToken(deepstateToken_);
    }

    modifier onlyOperatorOrOwner() {
        _checkOperatorOrOwner();
        _;
    }

    /// @notice Appoint or revoke the operator. Set zero to revoke without replacement.
    function setOperator(address newOperator) external onlyOwner {
        address previousOperator = operator;
        operator = newOperator;
        emit OperatorSet(previousOperator, newOperator);
    }

    /// @notice Deploy, initially fund, and install a deterministic rewarder for one pool.
    /// @dev Both sides share a one-billion-DEEP schedule but receive only 100 million DEEP initially.
    function deployMarket(MarketConfig calldata config)
        external
        onlyOperatorOrOwner
        returns (DeepstateRewarderV2 rewarder)
    {
        bytes32 poolId_ = _validateMarket(config);
        uint256 next = nextDeploymentAt;
        if (block.timestamp < next) revert DeploymentCooldown(next);

        address active = activeRewarder[poolId_];
        if (active != address(0)) revert ActiveMarketExists(poolId_, active);

        address existingHook = deepstate.poolHook(poolId_);
        if (existingHook != address(0)) revert ExistingPoolHook(poolId_, existingHook);

        uint256 nonce = deploymentCount;
        bytes32 salt = marketSalt(poolId_, nonce);

        deploymentCount = nonce + 1;
        nextDeploymentAt = block.timestamp + DEPLOYMENT_COOLDOWN;

        rewarder = new DeepstateRewarderV2{salt: salt}(
            address(this),
            address(deepstate),
            address(rewardToken),
            poolId_,
            config.token0,
            config.token1,
            SIDE_EMISSION_CAP,
            EMISSION_DURATION,
            config.token0StartQuantity,
            config.token0MaxQuantity,
            config.token1StartQuantity,
            config.token1MaxQuantity
        );

        activeRewarder[poolId_] = address(rewarder);
        rewarderPool[address(rewarder)] = poolId_;

        minterController.mint(address(rewarder), INITIAL_FUNDING);
        deepstateV1Controller.setPoolHookConfig(
            config.token0, config.token1, address(rewarder), config.token0Active, config.token1Active
        );

        emit MarketDeployed(
            poolId_,
            nonce,
            address(rewarder),
            salt,
            config.token0,
            config.token1,
            config.token0Active,
            config.token1Active
        );
    }

    /// @notice Remove a factory market and burn its remaining DEEP balance.
    /// @dev Retiring a market deliberately makes its unpaid claims unclaimable unless governance
    /// later funds the detached rewarder directly.
    function removeMarket(address token0, address token1) external onlyOperatorOrOwner returns (uint256 burnedAmount) {
        bytes32 poolId_ = _poolId(token0, token1);
        address rewarder = activeRewarder[poolId_];
        if (rewarder == address(0)) revert MarketNotActive(poolId_);

        address currentHook = deepstate.poolHook(poolId_);
        if (currentHook == rewarder) {
            deepstateV1Controller.setPoolHookConfig(token0, token1, address(0), false, false);
        } else if (currentHook != address(0)) {
            revert UnexpectedPoolHook(poolId_, rewarder, currentHook);
        }
        delete activeRewarder[poolId_];
        delete rewarderPool[rewarder];

        burnedAmount = DeepstateRewarderV2(rewarder).burnBalance();

        emit MarketRemoved(poolId_, rewarder, burnedAmount);
    }

    /// @notice CREATE2 salt for a pool and global deployment nonce.
    function marketSalt(bytes32 poolId_, uint256 deploymentNonce) public pure returns (bytes32) {
        return keccak256(abi.encode(poolId_, deploymentNonce));
    }

    /// @notice Predict a rewarder address using the factory and a deployment nonce.
    function predictRewarderAddress(MarketConfig calldata config, uint256 deploymentNonce)
        external
        view
        returns (address predicted)
    {
        bytes32 poolId_ = _validateMarket(config);
        bytes32 salt = marketSalt(poolId_, deploymentNonce);
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(DeepstateRewarderV2).creationCode,
                abi.encode(
                    address(this),
                    address(deepstate),
                    address(rewardToken),
                    poolId_,
                    config.token0,
                    config.token1,
                    SIDE_EMISSION_CAP,
                    EMISSION_DURATION,
                    config.token0StartQuantity,
                    config.token0MaxQuantity,
                    config.token1StartQuantity,
                    config.token1MaxQuantity
                )
            )
        );

        predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    function _validateMarket(MarketConfig calldata config) private pure returns (bytes32 poolId_) {
        if (config.token0 >= config.token1) revert InvalidPool();
        if (!config.token0Active && !config.token1Active) revert InvalidHookFlags();
        poolId_ = keccak256(abi.encode(config.token0, config.token1));
    }

    function _poolId(address token0, address token1) private pure returns (bytes32 poolId_) {
        if (token0 >= token1) revert InvalidPool();
        poolId_ = keccak256(abi.encode(token0, token1));
    }

    function _checkOperatorOrOwner() private view {
        if (msg.sender != operator) _checkOwner();
    }
}
