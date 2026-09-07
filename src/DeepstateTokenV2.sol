// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {DeepstateToken} from "./DeepstateToken.sol";
import {ISablierLockupLinearV4} from "./interfaces/ISablierLockupLinearV4.sol";

/// @notice Capped, vote-enabled 2DEEP with automatic self-delegation and two-year endowment minting.
contract DeepstateTokenV2 is DeepstateToken, ERC20Votes, ReentrancyGuard {
    bytes32 public constant ENDOWMENT_MINTER_ROLE = keccak256("ENDOWMENT_MINTER_ROLE");
    uint256 public constant ENDOWMENT_BPS = 30_00;
    uint256 public constant PRIMARY_BPS = 70_00;
    uint40 public constant ENDOWMENT_TERM = 2 * 365 days;
    uint40 public constant VESTING_DURATION = 365 days;

    ISablierLockupLinearV4 public immutable sablierLockup;
    address public immutable endowmentRecipient;

    uint256 public supplyCap;
    uint40 public endowmentEndsAt;

    event SupplyCapRaised(uint256 previousCap, uint256 newCap);
    event EndowmentTermStarted(uint40 endsAt);
    event MintedWithEndowment(
        address indexed caller,
        address indexed mintRecipient,
        uint256 mintAmount,
        address indexed endowmentRecipient,
        uint256 endowmentAmount,
        uint256 streamId
    );

    error InvalidSupplyCap();
    error SupplyCapNotRaised(uint256 currentCap, uint256 proposedCap);
    error SupplyCapExceeded(uint256 cap, uint256 attemptedSupply);
    error EndowmentAmountTooSmall();

    constructor(address admin_, uint256 initialSupplyCap, address sablierLockup_, address endowmentRecipient_)
        DeepstateToken(admin_, "Deepstate 2", "2DEEP")
        EIP712("Deepstate 2", "1")
    {
        if (initialSupplyCap == 0 || initialSupplyCap > type(uint208).max) {
            revert InvalidSupplyCap();
        }
        supplyCap = initialSupplyCap;
        sablierLockup = ISablierLockupLinearV4(sablierLockup_);
        endowmentRecipient = endowmentRecipient_;
    }

    /// @notice Governance may expand issuance but cannot reduce its prior cap commitment.
    function raiseSupplyCap(uint256 newCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 currentCap = supplyCap;
        if (newCap <= currentCap) revert SupplyCapNotRaised(currentCap, newCap);
        if (newCap > type(uint208).max) revert InvalidSupplyCap();

        supplyCap = newCap;
        emit SupplyCapRaised(currentCap, newCap);
    }

    /// @notice Mint `amount` to `to`, automatically adding the Deepstate Inc endowment during its two-year term.
    /// @dev ENDOWMENT_MINTER_ROLE callers start the term on their first mint and receive the automatic 30/70 treatment
    /// until it expires; their later mints continue normally without an endowment. MINTER_ROLE is reserved for raw
    /// migration issuance that must never create a second endowment.
    function mint(address to, uint256 amount) external override nonReentrant {
        if (!hasRole(ENDOWMENT_MINTER_ROLE, msg.sender)) {
            _checkRole(MINTER_ROLE, msg.sender);
            if (to == address(0)) revert ZeroAddress();
            _mint(to, amount);
            return;
        }
        if (to == address(0)) revert ZeroAddress();

        uint40 endsAt = endowmentEndsAt;
        if (endsAt == 0) {
            endsAt = SafeCast.toUint40(block.timestamp + ENDOWMENT_TERM);
            endowmentEndsAt = endsAt;
            emit EndowmentTermStarted(endsAt);
        } else if (block.timestamp >= endsAt) {
            _mint(to, amount);
            return;
        }

        uint256 endowmentAmount = Math.mulDiv(amount, ENDOWMENT_BPS, PRIMARY_BPS);
        if (endowmentAmount == 0) revert EndowmentAmountTooSmall();
        uint128 streamAmount = SafeCast.toUint128(endowmentAmount);

        _mint(to, amount);
        _mint(address(this), endowmentAmount);
        _approve(address(this), address(sablierLockup), endowmentAmount);

        uint256 streamId = sablierLockup.createWithDurationsLL(
            ISablierLockupLinearV4.CreateWithDurations({
                sender: address(this),
                recipient: endowmentRecipient,
                depositAmount: streamAmount,
                token: IERC20(address(this)),
                cancelable: false,
                transferable: true,
                shape: "Deepstate Inc endowment"
            }),
            ISablierLockupLinearV4.UnlockAmounts({start: 0, cliff: 0}),
            1 seconds,
            ISablierLockupLinearV4.Durations({cliff: 0, total: VESTING_DURATION})
        );

        emit MintedWithEndowment(msg.sender, to, amount, endowmentRecipient, endowmentAmount, streamId);
    }

    function clock() public view override returns (uint48) {
        return SafeCast.toUint48(block.timestamp);
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    function _update(address from, address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        if (from == address(0)) {
            uint256 attemptedSupply = totalSupply() + amount;
            uint256 cap = supplyCap;
            if (attemptedSupply > cap) revert SupplyCapExceeded(cap, attemptedSupply);
        }

        super._update(from, to, amount);

        if (to != address(0) && delegates(to) == address(0)) {
            _delegate(to, to);
        }
    }
}
