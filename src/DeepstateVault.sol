// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";

import {IBurnableERC20} from "./interfaces/IBurnableERC20.sol";
import {IWrappedNative} from "./interfaces/IWrappedNative.sol";

/// @notice STATE governance share vault with ERC-4626 deposit math over burned DEEP.
/// @dev ERC-4626 has one underlying asset. This vault deliberately separates the
/// deposit/accounting asset from the value token redeemed by share holders.
contract DeepstateVault is ERC4626, ERC20Votes, Ownable, ReentrancyGuard {
    using Math for uint256;
    using SafeERC20 for IERC20;
    using SlotDerivation for bytes32;
    using TransientSlot for *;

    bytes32 private constant _REDEEM_CALL_MARKER_SLOT = keccak256("DeepstateVault.redeemAssets.callMarker");
    bytes32 private constant _REDEEM_ASSET_SEEN_SEED = keccak256("DeepstateVault.redeemAssets.assetSeen");

    address public immutable depositToken;
    address public immutable valueToken;
    address public immutable wrappedNative;

    uint256 public totalBurnedDepositAssets;
    address public auction;

    event DepositAssetBurned(address indexed by, uint256 amount);
    event ValueRedeemed(
        address indexed by, address indexed receiver, address indexed owner, uint256 shares, uint256 valueAssets
    );
    event AssetsRedeemed(address indexed by, address indexed receiver, address indexed owner, uint256 shares);
    event AssetRedeemed(address indexed receiver, address indexed asset, uint256 amount);
    event AuctionSet(address indexed auction);
    event SweptToAuction(address indexed token, uint256 amount);
    event NativeSweptToAuction(uint256 amount);

    error ZeroAddress();
    error ZeroShares();
    error ZeroAssets();
    error ProtectedToken();
    error AuctionNotSet();
    error InsufficientValueAssets();
    error UseRedeemValue();
    error WrappedNativeNotSet();
    error EmptyAssetList();
    error DuplicateAsset();
    error InsufficientRedeemableAssets();

    constructor(
        address owner_,
        address depositToken_,
        address valueToken_,
        address wrappedNative_,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) ERC4626(IERC20(depositToken_)) EIP712(name_, "1") Ownable(owner_) {
        if (depositToken_ == address(0) || valueToken_ == address(0)) {
            revert ZeroAddress();
        }

        depositToken = depositToken_;
        valueToken = valueToken_;
        wrappedNative = wrappedNative_;
    }

    receive() external payable {}

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return ERC4626.decimals();
    }

    /// @notice Use wall-clock time for vote checkpoints and Governor settings.
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @notice ERC-6372 clock mode consumed by GovernorVotes.
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    /// @notice ERC-4626 accounting asset. Deposits burn this token instead of retaining it.
    function totalAssets() public view override returns (uint256) {
        return totalBurnedDepositAssets;
    }

    /// @notice Returns the value token amount currently redeemable for `shares`.
    function convertToValueAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return shares.mulDiv(IERC20(valueToken).balanceOf(address(this)), supply);
    }

    function previewRedeemValue(uint256 shares) external view returns (uint256) {
        return convertToValueAssets(shares);
    }

    /// @notice Burns shares and pays the owner a pro-rata amount of the value token.
    function redeemValue(uint256 shares, address receiver, address owner)
        public
        nonReentrant
        returns (uint256 valueAssets)
    {
        if (shares == 0) revert ZeroShares();
        if (shares > balanceOf(owner)) revert ERC4626ExceededMaxRedeem(owner, shares, balanceOf(owner));

        valueAssets = convertToValueAssets(shares);
        if (valueAssets == 0) revert InsufficientValueAssets();

        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        _burn(owner, shares);
        IERC20(valueToken).safeTransfer(receiver, valueAssets);

        emit ValueRedeemed(msg.sender, receiver, owner, shares, valueAssets);
    }

    /// @notice Burns STATE and pays a pro-rata share of each explicitly listed vault asset.
    /// @dev Use address(0) for native ETH. DEEP and STATE cannot be redeemed through this path.
    /// All payouts use pre-burn balances and supply; omitted assets remain in the vault.
    function redeemAssets(uint256 shares, address receiver, address owner, address[] calldata tokens)
        external
        nonReentrant
        returns (uint256[] memory assets)
    {
        if (shares == 0) revert ZeroShares();
        if (receiver == address(0)) revert ZeroAddress();

        uint256 ownerBalance = balanceOf(owner);
        if (shares > ownerBalance) revert ERC4626ExceededMaxRedeem(owner, shares, ownerBalance);

        uint256 length = tokens.length;
        if (length == 0) revert EmptyAssetList();

        uint256 supply = totalSupply();
        uint256 marker = _nextRedeemCallMarker();
        assets = new uint256[](length);
        bool hasAssets;

        for (uint256 i; i < length; ++i) {
            address token = tokens[i];
            if (token == depositToken || token == address(this)) revert ProtectedToken();
            _markAssetSeen(token, marker);

            uint256 amount = shares.mulDiv(_vaultBalance(token), supply);
            assets[i] = amount;
            if (amount != 0) hasAssets = true;
        }

        if (!hasAssets) revert InsufficientRedeemableAssets();
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        _burn(owner, shares);

        for (uint256 i; i < length; ++i) {
            uint256 amount = assets[i];
            if (amount == 0) continue;

            address token = tokens[i];
            if (token == address(0)) Address.sendValue(payable(receiver), amount);
            else IERC20(token).safeTransfer(receiver, amount);

            emit AssetRedeemed(receiver, token, amount);
        }

        emit AssetsRedeemed(msg.sender, receiver, owner, shares);
    }

    /// @dev Strict ERC-4626 withdrawal would return the deposit asset, which is burned here.
    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert UseRedeemValue();
    }

    /// @dev Use `redeemValue` to redeem shares for the value token.
    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert UseRedeemValue();
    }

    /// @dev Standard DEEP withdrawals are unavailable because deposited DEEP is burned.
    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    /// @dev Standard DEEP redemptions are unavailable; use `redeemValue` for the value token.
    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }

    /// @notice Maximum STATE shares an owner may redeem for the value token.
    function maxRedeemValue(address owner) public view returns (uint256) {
        return balanceOf(owner);
    }

    function setAuction(address auction_) external onlyOwner {
        if (auction_ == address(0)) revert ZeroAddress();
        auction = auction_;
        emit AuctionSet(auction_);
    }

    /// @notice Moves non-protected ERC-20 fee assets from the vault to the auction.
    function sweepToAuction(address[] calldata tokens) external onlyOwner nonReentrant {
        address auction_ = auction;
        if (auction_ == address(0)) revert AuctionNotSet();

        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            if (token == depositToken || token == valueToken || token == address(this)) revert ProtectedToken();

            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance == 0) continue;

            IERC20(token).safeTransfer(auction_, balance);
            emit SweptToAuction(token, balance);
        }
    }

    /// @notice Wraps raw ETH fee assets and moves the wrapped native token to the auction.
    function sweepNativeToAuction() external onlyOwner nonReentrant {
        address auction_ = auction;
        if (auction_ == address(0)) revert AuctionNotSet();
        address wrappedNative_ = wrappedNative;
        if (wrappedNative_ == address(0)) revert WrappedNativeNotSet();

        uint256 balance = address(this).balance;
        if (balance == 0) return;

        IWrappedNative(wrappedNative_).deposit{value: balance}();
        IERC20(wrappedNative_).safeTransfer(auction_, balance);
        emit NativeSweptToAuction(balance);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
        if (assets == 0) revert ZeroAssets();
        if (shares == 0) revert ZeroShares();

        IERC20(depositToken).safeTransferFrom(caller, address(this), assets);
        IBurnableERC20(depositToken).burn(assets);
        totalBurnedDepositAssets += assets;
        _mint(receiver, shares);
        _selfDelegateIfUnset(receiver);

        emit Deposit(caller, receiver, assets, shares);
        emit DepositAssetBurned(caller, assets);
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets : assets.mulDiv(supply, totalAssets(), rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? shares : shares.mulDiv(totalAssets(), supply, rounding);
    }

    function _selfDelegateIfUnset(address account) private {
        if (delegates(account) == address(0)) _delegate(account, account);
    }

    function _vaultBalance(address token) private view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    function _nextRedeemCallMarker() private returns (uint256 marker) {
        TransientSlot.Uint256Slot slot = _REDEEM_CALL_MARKER_SLOT.asUint256();
        marker = slot.tload() + 1;
        slot.tstore(marker);
    }

    function _markAssetSeen(address token, uint256 marker) private {
        TransientSlot.Uint256Slot slot = _REDEEM_ASSET_SEEN_SEED.deriveMapping(token).asUint256();
        if (slot.tload() == marker) revert DuplicateAsset();
        slot.tstore(marker);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }
}
