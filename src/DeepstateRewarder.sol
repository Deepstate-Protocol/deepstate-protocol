// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IHook} from "deepstate-contracts/interfaces/IHook.sol";
import {IOrderBook} from "./interfaces/IOrderBook.sol";

interface IMintableRewardToken {
    function mint(address to, uint256 amount) external;
}

/// @title Deepstate Rewarder
/// @notice Pool-specific accounting for a capped DEEP liquidity-emission schedule.
/// @dev One rewarder is deployed per pool. Its immutable pool allocation is split equally between
/// both book sides. Rewards compare each outgoing top amount with that side's moving reference;
/// comparisons are unitless, so token decimals do not affect the multiplier. The reward token must
/// expose `mint(address,uint256)` and authorize this contract to mint.
contract DeepstateRewarder is Ownable, IHook {
    using FixedPointMathLib for uint256;

    uint256 public constant BOOTSTRAP_PERIOD = 30 days;
    uint256 public constant ANNUAL_PERIOD = 365 days;
    uint256 public constant REFERENCE_WINDOW = 7 days;
    uint256 public constant MAX_SCHEDULE_YEARS = 100;
    uint256 public constant MAX_SCHEDULE_ELAPSED = BOOTSTRAP_PERIOD + MAX_SCHEDULE_YEARS * ANNUAL_PERIOD;

    uint256 internal constant _WAD = 1e18;
    int256 internal constant _LN2_WAD = 693147180559945309;
    int256 internal constant _BOOTSTRAP_DECAY_WAD = 3440171329752580000;

    address public immutable engine;
    address public immutable rewardToken;
    bytes32 public immutable poolId;
    address public immutable token0;
    address public immutable token1;
    uint64 public immutable emissionStart;
    uint64 public immutable poolEmissionShareWad;
    uint128 public immutable initialSupply;
    uint128 public immutable bootstrapEmissions;

    // Packed as: referenceAmount (160 bits) | startedAt (64 bits) | orderNonce (32 bits).
    uint256 private _token0Rewardee;
    uint256 private _token1Rewardee;

    mapping(bytes32 bookId => mapping(address token => mapping(uint32 orderNonce => uint256 balance))) public balances;

    event RewardsDistributed(bytes32 bookId, bytes32 order, address token, address owner, uint256 amount);

    error InvalidEngine();
    error InvalidRewardToken();
    error InvalidPool();
    error InvalidPoolShare();
    error InvalidEmissionSchedule();
    error NotEngine();
    error InvalidHookToken();
    error NoOrderOwner();

    constructor(
        address owner_,
        address engine_,
        address rewardToken_,
        bytes32 poolId_,
        address token0_,
        address token1_,
        uint64 emissionStart_,
        uint128 initialSupply_,
        uint128 bootstrapEmissions_,
        uint64 poolEmissionShareWad_
    ) {
        if (engine_ == address(0)) revert InvalidEngine();
        if (rewardToken_ == address(0)) revert InvalidRewardToken();
        if (poolId_ == bytes32(0) || token0_ == address(0) || token0_ >= token1_) revert InvalidPool();
        if (poolId_ != _poolId(token0_, token1_)) revert InvalidPool();
        if (poolEmissionShareWad_ == 0 || poolEmissionShareWad_ > _WAD) revert InvalidPoolShare();
        // Equal bootstrap emissions and initial supply give 100% inflation over the first 30 days.
        if (emissionStart_ == 0 || initialSupply_ == 0 || bootstrapEmissions_ != initialSupply_) {
            revert InvalidEmissionSchedule();
        }

        _initializeOwner(owner_);
        engine = engine_;
        rewardToken = rewardToken_;
        poolId = poolId_;
        token0 = token0_;
        token1 = token1_;
        emissionStart = emissionStart_;
        initialSupply = initialSupply_;
        bootstrapEmissions = bootstrapEmissions_;
        poolEmissionShareWad = poolEmissionShareWad_;
    }

    /// @notice Current order nonce and start time for one book side.
    function rewardees(address token) external view returns (uint32 orderNonce, uint64 startedAt) {
        (orderNonce, startedAt,) = _unpackRewardee(_packedRewardee(token));
    }

    /// @notice Moving quantity reference for one book side.
    function referenceAmount(address token) external view returns (uint160 movingReference) {
        (,, movingReference) = _unpackRewardee(_packedRewardee(token));
    }

    /// @notice Total schedule emissions between two timestamps before pool and side allocation.
    function emissionsBetween(uint256 start, uint256 end) public view returns (uint256) {
        if (end <= start) return 0;
        return cumulativeEmissionsAt(end) - cumulativeEmissionsAt(start);
    }

    /// @notice Cumulative schedule emissions, capped after 100 annual doubling periods.
    function cumulativeEmissionsAt(uint256 timestamp_) public view returns (uint256) {
        uint64 start = emissionStart;
        if (timestamp_ <= start) return 0;
        return _cumulativeSupplyAtElapsed(timestamp_ - start) - initialSupply;
    }

    function cumulativeSupplyAt(uint256 timestamp_) external view returns (uint256) {
        uint64 start = emissionStart;
        if (timestamp_ <= start) return initialSupply;
        return _cumulativeSupplyAtElapsed(timestamp_ - start);
    }

    /// @notice Maximum emission budget for one side over an interval.
    function previewReward(address token, uint256 start, uint256 end) public view returns (uint256) {
        _validateHookToken(token);
        return emissionsBetween(start, end).fullMulDiv(poolEmissionShareWad, 2 * _WAD);
    }

    /// @notice Reward after applying the side's bounded quantity multiplier.
    function previewAdjustedReward(address token, uint256 start, uint256 end, uint160 amount, uint160 benchmark)
        public
        view
        returns (uint256)
    {
        return previewReward(token, start, end).fullMulDiv(quantityMultiplierWad(amount, benchmark), _WAD);
    }

    /// @notice Bounded quantity controller: first=100%, equal=50%, 2x=80%, 3x=90%.
    function quantityMultiplierWad(uint160 amount, uint160 benchmark) public pure returns (uint256) {
        if (amount == 0) return 0;
        if (benchmark == 0) return _WAD;

        uint256 ratio;
        uint256 square;
        if (amount >= benchmark) {
            ratio = uint256(benchmark).fullMulDiv(_WAD, amount);
            square = ratio.fullMulDiv(ratio, _WAD);
            return _WAD.fullMulDiv(_WAD, _WAD + square);
        }

        ratio = uint256(amount).fullMulDiv(_WAD, benchmark);
        square = ratio.fullMulDiv(ratio, _WAD);
        return square.fullMulDiv(_WAD, _WAD + square);
    }

    /// @inheritdoc IHook
    function execute(bytes32 poolId_, bytes32 bookId, address token, uint160 outgoingAmount, uint32 incomingOrderNonce)
        external
    {
        if (msg.sender != engine) revert NotEngine();
        if (poolId_ != poolId) revert InvalidPool();

        bool isToken0 = token == token0;
        if (!isToken0 && token != token1) revert InvalidHookToken();

        uint256 packedRewardee = isToken0 ? _token0Rewardee : _token1Rewardee;
        (uint32 outgoingOrderNonce, uint64 startedAt, uint160 benchmark) = _unpackRewardee(packedRewardee);
        uint160 nextReference = benchmark;

        if (outgoingAmount != 0) {
            if (outgoingOrderNonce != 0 && startedAt != 0 && block.timestamp > startedAt) {
                uint256 reward = previewAdjustedReward(token, startedAt, block.timestamp, outgoingAmount, benchmark);
                if (reward != 0) balances[bookId][token][outgoingOrderNonce] += reward;
                nextReference = _nextReference(benchmark, outgoingAmount, block.timestamp - startedAt);
            }
        }

        uint256 nextRewardee = _packRewardee(incomingOrderNonce, block.timestamp, nextReference);
        if (isToken0) _token0Rewardee = nextRewardee;
        else _token1Rewardee = nextRewardee;
    }

    /// @notice Claim previously accrued rewards while the engine still records the order owner.
    function distributeRewards(bytes32 bookId, bytes32 order, address token) external {
        uint32 nonce = uint32(uint256(order));
        uint256 amount = balances[bookId][token][nonce];
        if (amount == 0) return;

        address owner = IOrderBook(engine).ownerOfOrder(IOrderBook(engine).orderId(bookId, order));
        if (owner == address(0)) revert NoOrderOwner();

        balances[bookId][token][nonce] = 0;
        IMintableRewardToken(rewardToken).mint(owner, amount);

        emit RewardsDistributed(bookId, order, token, owner, amount);
    }

    function _cumulativeSupplyAtElapsed(uint256 elapsed) internal view returns (uint256) {
        if (elapsed > MAX_SCHEDULE_ELAPSED) elapsed = MAX_SCHEDULE_ELAPSED;

        uint256 initialSupply_ = initialSupply;
        uint256 bootstrapEmissions_ = bootstrapEmissions;
        if (elapsed <= BOOTSTRAP_PERIOD) {
            return initialSupply_ + bootstrapEmissions_.fullMulDiv(_bootstrapProgressWad(elapsed), _WAD);
        }

        uint256 supplyAfterBootstrap = initialSupply_ + bootstrapEmissions_;
        int256 exponent = _LN2_WAD * int256(elapsed - BOOTSTRAP_PERIOD) / int256(ANNUAL_PERIOD);
        return supplyAfterBootstrap.fullMulDiv(_expWad(exponent), _WAD);
    }

    function _bootstrapProgressWad(uint256 elapsed) internal pure returns (uint256) {
        int256 exponent = -(_BOOTSTRAP_DECAY_WAD * int256(elapsed) / int256(BOOTSTRAP_PERIOD));
        uint256 numerator = _WAD - _expWad(exponent);
        uint256 denominator = _WAD - _expWad(-_BOOTSTRAP_DECAY_WAD);
        return numerator.fullMulDiv(_WAD, denominator);
    }

    function _expWad(int256 x) internal pure returns (uint256) {
        return uint256(FixedPointMathLib.expWad(x));
    }

    function _nextReference(uint160 benchmark, uint160 amount, uint256 elapsed) internal pure returns (uint160) {
        if (benchmark == 0) return amount;
        if (elapsed >= REFERENCE_WINDOW) return amount;

        if (amount >= benchmark) {
            uint256 increase = (uint256(amount) - benchmark).fullMulDiv(elapsed, REFERENCE_WINDOW);
            return uint160(uint256(benchmark) + increase);
        }

        uint256 decrease = (uint256(benchmark) - amount).fullMulDiv(elapsed, REFERENCE_WINDOW);
        return uint160(uint256(benchmark) - decrease);
    }

    function _packRewardee(uint32 orderNonce, uint256 timestamp_, uint160 benchmark) private pure returns (uint256) {
        uint256 packed = uint256(benchmark) << 96;
        if (orderNonce == 0) return packed;
        return packed | uint256(orderNonce) | (uint256(uint64(timestamp_)) << 32);
    }

    function _unpackRewardee(uint256 packedRewardee)
        private
        pure
        returns (uint32 orderNonce, uint64 startedAt, uint160 benchmark)
    {
        orderNonce = uint32(packedRewardee);
        startedAt = uint64(packedRewardee >> 32);
        benchmark = uint160(packedRewardee >> 96);
    }

    function _packedRewardee(address token) private view returns (uint256) {
        if (token == token0) return _token0Rewardee;
        if (token == token1) return _token1Rewardee;
        revert InvalidHookToken();
    }

    function _validateHookToken(address token) private view {
        if (token != token0 && token != token1) revert InvalidHookToken();
    }

    function _poolId(address token0_, address token1_) private pure returns (bytes32 id) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, token0_)
            mstore(add(ptr, 0x20), token1_)
            id := keccak256(ptr, 0x40)
        }
    }
}
