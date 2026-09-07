// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";

import {DeepstateTokenV2} from "./DeepstateTokenV2.sol";
import {DeepstateRewarderV3} from "./DeepstateRewarderV3.sol";
import {IDeepstateV1} from "./interfaces/IDeepstateV1.sol";

/// @notice Governance-owned factory for fully funded Rewarder V3 programs.
contract DeepstateRewarderFactoryV3 is Ownable {
    struct MarketConfig {
        address token0;
        address token1;
        uint256 token0MaxUnits;
        uint256 token1MaxUnits;
        bool token0Active;
        bool token1Active;
    }

    uint32 public constant EMISSION_DURATION = 365 days;
    uint96 public constant SIDE_EMISSION_CAP = 50_000_000e18;
    uint256 public constant MARKET_FUNDING = 100_000_000e18;
    uint256 public constant MAX_QUANTITY_GROWTH = 1_000_000;

    IDeepstateV1 public immutable deepstate;
    DeepstateTokenV2 public immutable rewardToken;

    event RewarderDeployed(
        bytes32 indexed poolId,
        address indexed rewarder,
        address token0,
        address token1,
        bool token0Active,
        bool token1Active
    );

    error InvalidOwner();
    error QuantityGrowthTooLarge(address token, uint256 maxUnits);

    constructor(address owner_, address deepstate_, address rewardToken_) {
        if (owner_ == address(0)) revert InvalidOwner();

        _initializeOwner(owner_);
        deepstate = IDeepstateV1(deepstate_);
        rewardToken = DeepstateTokenV2(rewardToken_);
    }

    /// @notice Deploy, fund, and install a Rewarder V3 for one canonical pool.
    function deployMarket(MarketConfig calldata config) external onlyOwner returns (DeepstateRewarderV3 rewarder) {
        _validateQuantityGrowth(config.token0, config.token0MaxUnits);
        _validateQuantityGrowth(config.token1, config.token1MaxUnits);

        (uint160 token0StartQuantity, uint160 token0MaxQuantity) =
            _quantitiesForUnits(config.token0, config.token0MaxUnits);
        (uint160 token1StartQuantity, uint160 token1MaxQuantity) =
            _quantitiesForUnits(config.token1, config.token1MaxUnits);
        bytes32 poolId = keccak256(abi.encode(config.token0, config.token1));

        rewarder = new DeepstateRewarderV3(
            address(this),
            address(deepstate),
            address(rewardToken),
            poolId,
            config.token0,
            config.token1,
            SIDE_EMISSION_CAP,
            EMISSION_DURATION,
            token0StartQuantity,
            token0MaxQuantity,
            token1StartQuantity,
            token1MaxQuantity
        );

        rewardToken.mint(address(rewarder), MARKET_FUNDING);
        deepstate.setPoolHookConfig(
            config.token0, config.token1, address(rewarder), config.token0Active, config.token1Active
        );

        emit RewarderDeployed(
            poolId, address(rewarder), config.token0, config.token1, config.token0Active, config.token1Active
        );
    }

    /// @notice Return direct Router administration to this factory's owner.
    /// @dev The factory cannot install another rewarder unless governance later transfers the Router back.
    function returnDeepstateOwnership() external onlyOwner {
        deepstate.transferOwnership(owner());
    }

    /// @notice Burn the full reward-token balance of a Rewarder V3 owned by this factory.
    function burnBalance(address rewarder) external onlyOwner {
        DeepstateRewarderV3(rewarder).burnBalance();
    }

    function renounceOwnership() public payable override onlyOwner {
        revert NewOwnerIsZeroAddress();
    }

    function _quantitiesForUnits(address token, uint256 maxUnits)
        private
        view
        returns (uint160 startQuantity, uint160 maxQuantity)
    {
        uint256 unit = token == address(0) ? 1e18 : 10 ** uint256(IERC20Metadata(token).decimals());
        startQuantity = SafeCastLib.toUint160(unit);
        maxQuantity = SafeCastLib.toUint160(maxUnits * unit);
    }

    function _validateQuantityGrowth(address token, uint256 maxUnits) private pure {
        if (maxUnits > MAX_QUANTITY_GROWTH) revert QuantityGrowthTooLarge(token, maxUnits);
    }

    function _setOwner(address newOwner) internal override {
        if (newOwner == address(this)) revert InvalidOwner();
        super._setOwner(newOwner);
    }
}
