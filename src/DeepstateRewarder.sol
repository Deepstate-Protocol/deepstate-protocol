// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IHook} from "deepstate-contracts/interfaces/IHook.sol";
import {IOrderBook} from "./interfaces/IOrderBook.sol";

/// @title Deepstate Rewarder
/// @notice Pool-specific accounting for a finite DEEP market-making program.
/// @dev
/// One rewarder is deployed per pool. Each side receives an independent immutable emission cap and
/// starts its own clock when Deepstate first reports a live top order. Emissions follow a normalized
/// logarithmic curve, while the quantity required for full rewards grows geometrically for 30 days.
/// Amounts below that target earn linearly; amounts at or above it earn the full scheduled budget.
contract DeepstateRewarder is Ownable, IHook {
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC20;

    /// @notice Time constant used by the logarithmic cumulative emission curve.
    uint256 public constant EMISSION_TIME_CONSTANT = 30 days;
    /// @notice Duration of each side's geometric full-reward-quantity ramp.
    uint256 public constant QUANTITY_RAMP_PERIOD = 30 days;

    uint256 internal constant _WAD = 1e18;
    uint256 internal constant _MIN_QUANTITY_GROWTH_WAD = 1_000e18;
    uint256 internal constant _E1_ITERATIONS = 16;

    /// @notice Deepstate order book authorized to update reward cursors.
    address public immutable deepstate;
    /// @notice Prefunded token transferred when rewards are claimed.
    address public immutable rewardToken;
    /// @notice Sorted-token pool id accepted by this rewarder.
    bytes32 public immutable poolId;
    /// @notice Lower sorted pool token.
    address public immutable token0;
    /// @notice Higher sorted pool token.
    address public immutable token1;

    /// @notice Lifetime emission cap for each side of the book.
    uint96 public immutable sideEmissionCap;
    /// @notice Number of seconds over which each side can earn its cap.
    uint32 public immutable emissionDuration;
    /// @notice Natural log of `1 + emissionDuration / 30 days`, WAD-scaled.
    uint128 public immutable emissionLogDenominatorWad;

    uint160 public immutable token0StartQuantity;
    uint160 public immutable token0MaxQuantity;
    uint160 public immutable token1StartQuantity;
    uint160 public immutable token1MaxQuantity;
    uint128 public immutable token0QuantityLogWad;
    uint128 public immutable token1QuantityLogWad;

    // Packed as: total accrued (96) | side activation (64) | current top start (64) | nonce (32).
    uint256 private _token0State;
    uint256 private _token1State;
    bytes32 private _token0BookId;
    bytes32 private _token1BookId;

    mapping(bytes32 bookId => mapping(address token => mapping(uint32 orderNonce => uint256 balance))) public balances;
    /// @notice Verified reward recipient for a canonical Deepstate order id.
    mapping(bytes32 orderId => address claimant) public claimants;

    event ClaimantRegistered(bytes32 indexed orderId, address indexed claimant);
    event RewardsDistributed(bytes32 bookId, bytes32 order, address token, address owner, uint256 amount);

    error InvalidOwner();
    error InvalidDeepstate();
    error InvalidRewardToken();
    error InvalidPool();
    error InvalidEmissionSchedule();
    error InvalidQuantitySchedule();
    error NotDeepstate();
    error InvalidHookToken();
    error NoOrderOwner();

    constructor(
        address owner_,
        address deepstate_,
        address rewardToken_,
        bytes32 poolId_,
        address token0_,
        address token1_,
        uint96 sideEmissionCap_,
        uint32 emissionDuration_,
        uint160 token0StartQuantity_,
        uint160 token0MaxQuantity_,
        uint160 token1StartQuantity_,
        uint160 token1MaxQuantity_
    ) {
        if (owner_ == address(0)) revert InvalidOwner();
        if (deepstate_ == address(0)) revert InvalidDeepstate();
        if (rewardToken_ == address(0)) revert InvalidRewardToken();
        if (poolId_ == bytes32(0) || token0_ >= token1_ || poolId_ != _poolId(token0_, token1_)) {
            revert InvalidPool();
        }
        if (sideEmissionCap_ == 0 || emissionDuration_ < QUANTITY_RAMP_PERIOD) {
            revert InvalidEmissionSchedule();
        }

        uint256 token0Log = _validateQuantitySchedule(token0StartQuantity_, token0MaxQuantity_);
        uint256 token1Log = _validateQuantitySchedule(token1StartQuantity_, token1MaxQuantity_);
        uint256 durationRatioWad = (EMISSION_TIME_CONSTANT + emissionDuration_).fullMulDiv(_WAD, EMISSION_TIME_CONSTANT);
        uint256 emissionLog = uint256(FixedPointMathLib.lnWad(int256(durationRatioWad)));

        _initializeOwner(owner_);
        deepstate = deepstate_;
        rewardToken = rewardToken_;
        poolId = poolId_;
        token0 = token0_;
        token1 = token1_;
        sideEmissionCap = sideEmissionCap_;
        emissionDuration = emissionDuration_;
        emissionLogDenominatorWad = uint128(emissionLog);
        token0StartQuantity = token0StartQuantity_;
        token0MaxQuantity = token0MaxQuantity_;
        token1StartQuantity = token1StartQuantity_;
        token1MaxQuantity = token1MaxQuantity_;
        token0QuantityLogWad = uint128(token0Log);
        token1QuantityLogWad = uint128(token1Log);
    }

    /// @notice Current top-order cursor for one side.
    function rewardees(address token) external view returns (uint32 orderNonce, uint64 startedAt) {
        (orderNonce, startedAt,,) = _unpackState(_packedState(token));
    }

    /// @notice Timestamp when one side's finite schedule was activated, or zero before activation.
    function emissionStart(address token) public view returns (uint64 activatedAt) {
        (,, activatedAt,) = _unpackState(_packedState(token));
    }

    /// @notice Rewards accrued against one side's immutable cap, whether claimed or still owed.
    function totalAccrued(address token) public view returns (uint96 accrued) {
        (,,, accrued) = _unpackState(_packedState(token));
    }

    /// @notice Book containing the currently tracked top order for one side.
    function rewardeeBookId(address token) external view returns (bytes32) {
        if (token == token0) return _token0BookId;
        if (token == token1) return _token1BookId;
        revert InvalidHookToken();
    }

    /// @notice Cumulative maximum emissions for one side after `elapsed` schedule seconds.
    function cumulativeEmissionsAtElapsed(uint256 elapsed) public view returns (uint256) {
        uint256 duration = emissionDuration;
        if (elapsed == 0) return 0;
        if (elapsed >= duration) return sideEmissionCap;

        uint256 ratioWad = (EMISSION_TIME_CONSTANT + elapsed).fullMulDiv(_WAD, EMISSION_TIME_CONSTANT);
        uint256 logWad = uint256(FixedPointMathLib.lnWad(int256(ratioWad)));
        return uint256(sideEmissionCap).fullMulDiv(logWad, emissionLogDenominatorWad);
    }

    /// @notice Cumulative maximum emissions for a side at an absolute timestamp.
    function cumulativeEmissionsAt(address token, uint256 timestamp_) public view returns (uint256) {
        uint64 start = emissionStart(token);
        if (start == 0 || timestamp_ <= start) return 0;
        return cumulativeEmissionsAtElapsed(timestamp_ - start);
    }

    /// @notice Maximum side emissions between two absolute timestamps.
    function emissionsBetween(address token, uint256 start, uint256 end) public view returns (uint256) {
        if (end <= start) return 0;
        return cumulativeEmissionsAt(token, end) - cumulativeEmissionsAt(token, start);
    }

    /// @notice Quantity required to earn the full side budget after `elapsed` schedule seconds.
    function fullRewardQuantityAtElapsed(address token, uint256 elapsed) public view returns (uint256) {
        (uint160 startQuantity, uint160 maxQuantity, uint128 quantityLogWad) = _quantityConfig(token);
        if (elapsed >= QUANTITY_RAMP_PERIOD) return maxQuantity;

        uint256 exponentWad = uint256(quantityLogWad).fullMulDiv(elapsed, QUANTITY_RAMP_PERIOD);
        return uint256(startQuantity).fullMulDiv(_expWad(int256(exponentWad)), _WAD);
    }

    /// @notice Quantity required to earn the full side budget at an absolute timestamp.
    function fullRewardQuantityAt(address token, uint256 timestamp_) external view returns (uint256) {
        uint64 start = emissionStart(token);
        if (start == 0 || timestamp_ <= start) {
            (uint160 startQuantity,,) = _quantityConfig(token);
            return startQuantity;
        }
        return fullRewardQuantityAtElapsed(token, timestamp_ - start);
    }

    /// @notice Quantity-adjusted reward over an elapsed schedule interval.
    /// @dev This integrates the moving quantity target over time rather than sampling an endpoint.
    function previewRewardAtElapsed(address token, uint256 start, uint256 end, uint160 amount)
        public
        view
        returns (uint256)
    {
        if (end <= start || amount == 0) return 0;
        uint256 intervalStart = start;
        (uint160 startQuantity, uint160 maxQuantity, uint128 quantityLogWad) = _quantityConfig(token);
        uint256 duration = emissionDuration;
        if (start >= duration) return 0;
        if (end > duration) end = duration;

        if (amount >= maxQuantity) {
            return cumulativeEmissionsAtElapsed(end) - cumulativeEmissionsAtElapsed(start);
        }

        uint256 reward;
        uint256 crossover = _crossoverTime(amount, startQuantity, maxQuantity, quantityLogWad);

        if (start < crossover) {
            uint256 fullEnd = end < crossover ? end : crossover;
            reward = cumulativeEmissionsAtElapsed(fullEnd) - cumulativeEmissionsAtElapsed(start);
            start = fullEnd;
        }

        if (start < end && start < QUANTITY_RAMP_PERIOD) {
            uint256 rampEnd = end < QUANTITY_RAMP_PERIOD ? end : QUANTITY_RAMP_PERIOD;
            reward += _rampAdjustedReward(start, rampEnd, amount, startQuantity, quantityLogWad);
            start = rampEnd;
        }

        if (start < end) {
            uint256 tailBudget = cumulativeEmissionsAtElapsed(end) - cumulativeEmissionsAtElapsed(start);
            reward += tailBudget.fullMulDiv(amount, maxQuantity);
        }

        uint256 maximum = cumulativeEmissionsAtElapsed(end) - cumulativeEmissionsAtElapsed(intervalStart);
        return reward > maximum ? maximum : reward;
    }

    /// @notice Quantity-adjusted reward over an absolute interval for an activated side.
    function previewReward(address token, uint256 start, uint256 end, uint160 amount) public view returns (uint256) {
        uint64 activatedAt = emissionStart(token);
        if (activatedAt == 0 || end <= activatedAt || end <= start) return 0;
        if (start < activatedAt) start = activatedAt;
        return previewRewardAtElapsed(token, start - activatedAt, end - activatedAt, amount);
    }

    /// @inheritdoc IHook
    function execute(bytes32 poolId_, bytes32 bookId, address token, uint160 outgoingAmount, uint32 incomingOrderNonce)
        external
    {
        if (msg.sender != deepstate) revert NotDeepstate();
        if (poolId_ != poolId) revert InvalidPool();

        bool isToken0 = token == token0;
        if (!isToken0 && token != token1) revert InvalidHookToken();

        uint256 packed = isToken0 ? _token0State : _token1State;
        (uint32 outgoingNonce, uint64 topStartedAt, uint64 activatedAt, uint96 accrued) = _unpackState(packed);
        bytes32 outgoingBookId = isToken0 ? _token0BookId : _token1BookId;

        if (
            outgoingAmount != 0 && outgoingNonce != 0 && topStartedAt != 0 && activatedAt != 0
                && block.timestamp > topStartedAt
        ) {
            uint256 reward = previewReward(token, topStartedAt, block.timestamp, outgoingAmount);
            reward = _remainingReward(accrued, reward);
            if (reward != 0) {
                balances[outgoingBookId][token][outgoingNonce] += reward;
                accrued += uint96(reward);
            }
        }

        if (incomingOrderNonce == 0) {
            topStartedAt = 0;
        } else {
            if (activatedAt == 0) activatedAt = uint64(block.timestamp);
            topStartedAt = uint64(block.timestamp);
            if (isToken0) {
                if (_token0BookId != bookId) _token0BookId = bookId;
            } else if (_token1BookId != bookId) {
                _token1BookId = bookId;
            }
        }

        uint256 nextState = _packState(incomingOrderNonce, topStartedAt, activatedAt, accrued);
        if (isToken0) _token0State = nextState;
        else _token1State = nextState;
    }

    /// @notice Cache the engine-verified owner that may claim rewards for an order after it is deleted.
    /// @dev Anyone may register an active order, but the engine alone determines its claimant.
    function registerClaimant(bytes32 bookId, bytes32 order) external returns (address claimant) {
        return _resolveClaimant(bookId, order);
    }

    /// @notice Accrue a live top order and pay all rewards to its verified claimant.
    /// @dev Lazily registers an active order. Register before cancellation to preserve claims after
    /// the engine permanently deletes ownership.
    function distributeRewards(bytes32 bookId, bytes32 order, address token) external {
        bool isToken0 = token == token0;
        if (!isToken0 && token != token1) revert InvalidHookToken();

        uint32 nonce = uint32(uint256(order));
        uint256 packed = isToken0 ? _token0State : _token1State;
        (uint32 currentNonce, uint64 topStartedAt, uint64 activatedAt, uint96 accrued) = _unpackState(packed);
        bytes32 currentBookId = isToken0 ? _token0BookId : _token1BookId;
        bool isCurrent = currentNonce == nonce && currentBookId == bookId && topStartedAt != 0;

        uint256 amount = balances[bookId][token][nonce];
        if (amount == 0 && !isCurrent) return;

        address claimant = _resolveClaimant(bookId, order);

        if (isCurrent && block.timestamp > topStartedAt) {
            (uint32 liveNonce, uint160 liveAmount) = IOrderBook(deepstate).topOrder(bookId, !isToken0);
            if (liveNonce == nonce && liveAmount != 0) {
                uint256 liveReward = previewReward(token, topStartedAt, block.timestamp, liveAmount);
                liveReward = _remainingReward(accrued, liveReward);
                if (liveReward != 0) {
                    amount += liveReward;
                    accrued += uint96(liveReward);
                    balances[bookId][token][nonce] = amount;
                }
                uint256 nextState = _packState(currentNonce, uint64(block.timestamp), activatedAt, accrued);
                if (isToken0) _token0State = nextState;
                else _token1State = nextState;
            }
        }

        if (amount == 0) return;
        balances[bookId][token][nonce] = 0;
        IERC20(rewardToken).safeTransfer(claimant, amount);

        emit RewardsDistributed(bookId, order, token, claimant, amount);
    }

    function _resolveClaimant(bytes32 bookId, bytes32 order) private returns (address claimant) {
        IOrderBook orderBook = IOrderBook(deepstate);
        bytes32 id = orderBook.orderId(bookId, order);
        claimant = claimants[id];
        if (claimant != address(0)) return claimant;

        claimant = orderBook.ownerOfOrder(id);
        if (claimant == address(0)) revert NoOrderOwner();

        claimants[id] = claimant;
        emit ClaimantRegistered(id, claimant);
    }

    function _rampAdjustedReward(
        uint256 start,
        uint256 end,
        uint160 amount,
        uint160 startQuantity,
        uint128 quantityLogWad
    ) private view returns (uint256) {
        if (end <= start) return 0;

        uint256 startTerm = _scaledE1Term(quantityLogWad, start);
        uint256 endTerm = _scaledE1Term(quantityLogWad, end);
        uint256 integralWad = (startTerm - endTerm).fullMulDiv(amount, startQuantity);
        return uint256(sideEmissionCap).fullMulDiv(integralWad, emissionLogDenominatorWad);
    }

    /// @dev Returns `exp(a*tau) * E1(a*(tau+t))`, WAD-scaled, with
    /// `a = ln(max/start) / QUANTITY_RAMP_PERIOD` and `tau = EMISSION_TIME_CONSTANT`.
    function _scaledE1Term(uint128 quantityLogWad, uint256 elapsed) private pure returns (uint256) {
        uint256 logWad = quantityLogWad;
        uint256 exponentWad = logWad.fullMulDiv(elapsed, QUANTITY_RAMP_PERIOD);
        uint256 argumentWad = logWad.fullMulDiv(EMISSION_TIME_CONSTANT + elapsed, QUANTITY_RAMP_PERIOD);
        uint256 factorWad = _e1ContinuedFractionFactor(argumentWad);
        return _expWad(-int256(exponentWad)).fullMulDiv(factorWad, _WAD);
    }

    /// @dev Continued-fraction factor `h(x)` where `E1(x) = exp(-x) * h(x)`.
    function _e1ContinuedFractionFactor(uint256 xWad) private pure returns (uint256 hWad) {
        int256 b = int256(xWad + _WAD);
        int256 c = 1e36;
        int256 d = int256(_WAD * _WAD / uint256(b));
        int256 h = d;

        for (uint256 i = 1; i <= _E1_ITERATIONS; ++i) {
            int256 an = -int256(i * i * _WAD);
            b += int256(2 * _WAD);
            d = b + an * d / int256(_WAD);
            d = int256(_WAD * _WAD) / d;
            c = b + an * int256(_WAD) / c;
            h = h * (d * c / int256(_WAD)) / int256(_WAD);
        }

        return uint256(h);
    }

    function _crossoverTime(uint160 amount, uint160 startQuantity, uint160 maxQuantity, uint128 quantityLogWad)
        private
        pure
        returns (uint256)
    {
        if (amount <= startQuantity) return 0;
        if (amount >= maxQuantity) return QUANTITY_RAMP_PERIOD;

        uint256 ratioWad = uint256(amount).fullMulDiv(_WAD, startQuantity);
        uint256 amountLogWad = uint256(FixedPointMathLib.lnWad(int256(ratioWad)));
        return amountLogWad.fullMulDiv(QUANTITY_RAMP_PERIOD, quantityLogWad);
    }

    function _remainingReward(uint96 accrued, uint256 reward) private view returns (uint256) {
        uint256 remaining = uint256(sideEmissionCap) - accrued;
        return reward > remaining ? remaining : reward;
    }

    function _quantityConfig(address token)
        private
        view
        returns (uint160 startQuantity, uint160 maxQuantity, uint128 quantityLogWad)
    {
        if (token == token0) return (token0StartQuantity, token0MaxQuantity, token0QuantityLogWad);
        if (token == token1) return (token1StartQuantity, token1MaxQuantity, token1QuantityLogWad);
        revert InvalidHookToken();
    }

    function _validateQuantitySchedule(uint160 startQuantity, uint160 maxQuantity)
        private
        pure
        returns (uint256 logWad)
    {
        if (startQuantity == 0 || maxQuantity <= startQuantity) {
            revert InvalidQuantitySchedule();
        }
        uint256 ratioWad = uint256(maxQuantity).fullMulDiv(_WAD, startQuantity);
        if (ratioWad < _MIN_QUANTITY_GROWTH_WAD) revert InvalidQuantitySchedule();
        logWad = uint256(FixedPointMathLib.lnWad(int256(ratioWad)));
        if (logWad > type(uint128).max) revert InvalidQuantitySchedule();
    }

    function _packState(uint32 nonce, uint64 topStartedAt, uint64 activatedAt, uint96 accrued)
        private
        pure
        returns (uint256)
    {
        return uint256(nonce) | (uint256(topStartedAt) << 32) | (uint256(activatedAt) << 96) | (uint256(accrued) << 160);
    }

    function _unpackState(uint256 packed)
        private
        pure
        returns (uint32 nonce, uint64 topStartedAt, uint64 activatedAt, uint96 accrued)
    {
        nonce = uint32(packed);
        topStartedAt = uint64(packed >> 32);
        activatedAt = uint64(packed >> 96);
        accrued = uint96(packed >> 160);
    }

    function _packedState(address token) private view returns (uint256) {
        if (token == token0) return _token0State;
        if (token == token1) return _token1State;
        revert InvalidHookToken();
    }

    function _expWad(int256 x) private pure returns (uint256) {
        return uint256(FixedPointMathLib.expWad(x));
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
