// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "solady/auth/Ownable.sol";
import {ERC4626} from "solady/tokens/ERC4626.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IBurnableERC20} from "./interfaces/IBurnableERC20.sol";
import {IWrappedNative} from "./interfaces/IWrappedNative.sol";

/// @notice Share vault with ERC-4626 deposit math over a burned accounting asset.
/// @dev ERC-4626 has one underlying asset. This vault deliberately separates the
/// deposit/accounting asset from the value token redeemed by share holders.
contract NigiriVault is ERC4626, Ownable, ReentrancyGuard {
    using FixedPointMathLib for uint256;

    address public immutable depositToken;
    address public immutable valueToken;
    address public immutable wrappedNative;
    uint8 internal immutable depositTokenDecimals;
    string internal vaultName;
    string internal vaultSymbol;

    uint256 public totalBurnedDepositAssets;
    address public auction;

    event DepositAssetBurned(address indexed by, uint256 amount);
    event ValueRedeemed(
        address indexed by, address indexed receiver, address indexed owner, uint256 shares, uint256 valueAssets
    );
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

    constructor(
        address owner_,
        address depositToken_,
        address valueToken_,
        address wrappedNative_,
        string memory name_,
        string memory symbol_
    ) {
        if (owner_ == address(0) || depositToken_ == address(0) || valueToken_ == address(0)) {
            revert ZeroAddress();
        }

        depositToken = depositToken_;
        valueToken = valueToken_;
        wrappedNative = wrappedNative_;
        vaultName = name_;
        vaultSymbol = symbol_;

        (bool success, uint8 result) = _tryGetAssetDecimals(depositToken_);
        depositTokenDecimals = success ? result : _DEFAULT_UNDERLYING_DECIMALS;

        _initializeOwner(owner_);
    }

    receive() external payable {}

    function name() public view override returns (string memory) {
        return vaultName;
    }

    function symbol() public view override returns (string memory) {
        return vaultSymbol;
    }

    /// @notice ERC-4626 accounting asset. Deposits burn this token instead of retaining it.
    function asset() public view override returns (address) {
        return depositToken;
    }

    function totalAssets() public view override returns (uint256) {
        return totalBurnedDepositAssets;
    }

    function _underlyingDecimals() internal view override returns (uint8) {
        return depositTokenDecimals;
    }

    function _useVirtualShares() internal pure override returns (bool) {
        return false;
    }

    function _deposit(address by, address to, uint256 assets, uint256 shares) internal override nonReentrant {
        if (assets == 0) revert ZeroAssets();
        if (shares == 0) revert ZeroShares();

        totalBurnedDepositAssets += assets;
        SafeTransferLib.safeTransferFrom(depositToken, by, address(this), assets);
        IBurnableERC20(depositToken).burn(assets);
        _mint(to, shares);

        emit Deposit(by, to, assets, shares);
        emit DepositAssetBurned(by, assets);
    }

    /// @notice Returns the value token amount currently redeemable for `shares`.
    function convertToValueAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return shares.fullMulDiv(SafeTransferLib.balanceOf(valueToken, address(this)), supply);
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
        if (shares > balanceOf(owner)) revert RedeemMoreThanMax();

        valueAssets = convertToValueAssets(shares);
        if (valueAssets == 0) revert InsufficientValueAssets();

        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        _burn(owner, shares);
        SafeTransferLib.safeTransfer(valueToken, receiver, valueAssets);

        emit ValueRedeemed(msg.sender, receiver, owner, shares, valueAssets);
    }

    /// @dev Strict ERC-4626 withdrawal would return the deposit asset, which is burned here.
    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert UseRedeemValue();
    }

    /// @dev Use `redeemValue` to redeem shares for the value token.
    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert UseRedeemValue();
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
            if (token == depositToken || token == valueToken) revert ProtectedToken();

            uint256 balance = SafeTransferLib.balanceOf(token, address(this));
            if (balance == 0) continue;

            SafeTransferLib.safeTransfer(token, auction_, balance);
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
        SafeTransferLib.safeTransfer(wrappedNative_, auction_, balance);
        emit NativeSweptToAuction(balance);
    }
}
