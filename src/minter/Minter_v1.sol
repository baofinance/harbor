// SPDX-License-Identifier: Unlicense
// coding standards by https://www.rareskills.io/post/solidity-style-guide
// and https://docs.soliditylang.org/en/latest/style-guide.html
pragma solidity 0.8.25;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IMinter } from "./IMinter.sol";
import { IMintable } from "./IMintable.sol";
import { IPriceOracle } from "price/IPriceOracle.sol";

/// @title
/// @author
/// @notice provides a base layer interface for minting and redeeming pegged and leveraged tokens
/// also provides information about the net asset values of the pegged and leveraged tokens
/// @dev uses UUPS proxy, erc7201 storage

/// @custom:oz-upgrades
contract Minter_v1 is Initializable, UUPSUpgradeable, AccessControlUpgradeable, IMinter {
    using SafeERC20 for IERC20;
    /****************
     * storage
     */
    /// @custom:storage-location erc7201:bao.storage.Minter
    struct Storage {
        address peggedToken;
        address leveragedToken;
        address collateralToken;
        address priceOracle;
        address rateProvider;
    }

    // keccak256(abi.encode(uint256(keccak256("bao.storage.Minter")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant MINTER_STORAGE = 0x92e73fe9557052b4a0b810a38eb7ef595ff750f166ca39d63b3f4c74937fef00;

    function _storage() private pure returns (Storage storage $) {
        assembly {
            $.slot := MINTER_STORAGE
        }
    }

    /// @dev The precision used to compute nav.
    uint256 internal constant PRECISION = 1e18;

    // UUPSUpgradeable

    function initialize(
        address owner,
        address peggedToken_,
        address leveragedToken_,
        address collateralToken_,
        address priceOracle,
        address rateProvider,
        uint256 collateralIn,
        uint256 mintPeggedRatio
    ) public initializer {
        if (mintPeggedRatio > PRECISION) revert InvalidRatio();
        // initialise all the state variables
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, owner);

        _storage().peggedToken = peggedToken_;
        _storage().leveragedToken = leveragedToken_;
        _storage().collateralToken = collateralToken_;
        _storage().priceOracle = priceOracle;
        // TODO: is this the difference between a wrapped or non-wrapped collateral?
        _storage().rateProvider = rateProvider;

        // how much collateral to use
        collateralIn = _allOf(collateralIn);
        uint256 price = _fetchSafePrice();

        // IERC20(collateralToken_).safeTransferFrom(_msgSender(), address(this), collateralIn);

        // // mint the tokens back to the caller
        // uint256 peggedTokenOut = (collateralIn * price) / PRECISION / mintPeggedRatio;
        // uint256 leveragedTokenOut = (collateralIn * price) / PRECISION / (PRECISION - mintPeggedRatio);
        // IMintable(peggedToken_).mint(_msgSender(), peggedTokenOut);
        // IMintable(leveragedToken_).mint(_msgSender(), leveragedTokenOut);
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // stop the implementation being initialized to any version
        // https://forum.openzeppelin.com/t/what-does-disableinitializers-function-mean/28730
        _disableInitializers();
    }

    // only owners can upgrade this contract
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // External mutator functions

    /// @inheritdoc IMinter
    function mintPeggedToken(
        uint256 collateralIn,
        address recipient,
        uint256 minPTokenMinted
    ) external override returns (uint256 pTokenMinted) {
        collateralIn = _allOf(collateralIn);
        uint256 price = _fetchSafePrice();
    }

    /// @inheritdoc IMinter
    function mintLeveragedToken(
        uint256 collateralIn,
        address recipient,
        uint256 minXTokenMinted
    ) external override returns (uint256 lTokenMinted, uint256 bonus) {
        collateralIn = _allOf(collateralIn);
    }

    /// @inheritdoc IMinter
    function redeemPeggedToken(
        uint256 fTokenIn,
        address recipient,
        uint256 minCollateralOut
    ) external override returns (uint256 collateralOut, uint256 bonus) {}

    /// @inheritdoc IMinter
    function redeemLeveragedToken(
        uint256 leveragedTokenIn,
        address recipient,
        uint256 minCollateralOut
    ) external override returns (uint256 collateralOut) {}

    // External view functions

    /// @notice Return the address of the collateral (collateral) token
    function collateralToken() external view override returns (address) {
        return _storage().collateralToken;
    }

    /// @notice Return the address of the pegged token.
    function peggedToken() external view override returns (address) {
        return _storage().peggedToken;
    }

    /// @notice Return the address of the leveraged token.
    function leveragedToken() external view override returns (address) {
        return _storage().leveragedToken;
    }

    /// @notice Return the current collateral ratio of the pToken to the collateral token, multipled by 1e18.
    function collateralRatio() external view returns (uint256) {
        uint256 collateralAmount = IERC20(_storage().collateralToken).balanceOf(address(this));
        uint256 peggedAmount = IERC20(_storage().peggedToken).balanceOf(address(this));
        return _collateralRatio(collateralAmount, _fetchSafePrice(), peggedAmount);
    }

    function _allOf(uint256 collateralIn) internal view returns (uint256 actualCollateralIn) {
        if (collateralIn == type(uint256).max) {
            actualCollateralIn = IERC20(_storage().collateralToken).balanceOf(_msgSender());
        } else {
            actualCollateralIn = collateralIn;
        }
        if (actualCollateralIn == 0) revert ZeroCollateral();
    }

    // fetching collateral price in terms of the pegged token

    function _fetchSafePrice() internal view returns (uint256 safe) {
        (bool isValid, uint256 safe_, , ) = IPriceOracle(_storage().priceOracle).getPrice();

        if (!isValid) revert InvalidOraclePrice();
        if (safe_ == 0) revert ZeroOraclePrice();
        safe = safe_;
    }

    function _fetchMinPrice() internal view returns (uint256 min) {
        (bool isValid, uint256 safe, uint256 min_, ) = IPriceOracle(_storage().priceOracle).getPrice();
        min = isValid ? safe : min_;
        if (min == 0) revert ZeroOraclePrice();
    }

    function _fetchMaxPrice() internal view returns (uint256 max) {
        (bool isValid, uint256 safe, , uint256 max_) = IPriceOracle(_storage().priceOracle).getPrice();
        max = isValid ? safe : max_;
        if (max == 0) revert ZeroOraclePrice();
    }

    // collateral calculations

    function _collateralRatio(
        uint256 collateralAmount,
        uint256 collateralPrice,
        uint256 peggedAmount
    ) internal pure returns (uint256 collateralRatio_) {
        collateralRatio_ = (collateralAmount * collateralPrice) / peggedAmount;
    }
}
