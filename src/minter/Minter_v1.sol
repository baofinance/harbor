// SPDX-License-Identifier: Unlicense
// coding standards by https://www.rareskills.io/post/solidity-style-guide
// and https://docs.soliditylang.org/en/latest/style-guide.html
pragma solidity 0.8.25;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IMinter, IMinterTreasury } from "./IMinter.sol";
import { IMintable } from "./IMintable.sol";
import { IPriceOracle } from "price/IPriceOracle.sol";

/// @title
/// @author
/// @notice provides a base layer interface for minting and redeeming pegged and leveraged tokens
/// also provides information about the net asset values of the pegged and leveraged tokens
/// @dev uses UUPS proxy, erc7201 storage

/// @custom:oz-upgrades
contract Minter_v1 is Initializable, UUPSUpgradeable, AccessControlUpgradeable, IMinter, IMinterTreasury {
    using SafeERC20 for IERC20;

    /****************
     * storage
     */
    /// @custom:storage-location erc7201:bao.storage.Minter
    struct MinterStorage {
        address peggedToken;
        address leveragedToken;
        address collateralToken;
        address priceOracle;
        address rateProvider;
        uint256 peggedTokenBalance;
        // TODO: check that the below two are packed
        uint128 criticalCollateralRatio;
        uint128 minimumMintPeggedFeeRatio;
    }

    // keccak256(abi.encode(uint256(keccak256("bao.storage.Minter")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant MINTER_STORAGE = 0x92e73fe9557052b4a0b810a38eb7ef595ff750f166ca39d63b3f4c74937fef00;

    function _getMinterStorage() private pure returns (MinterStorage storage $) {
        assembly {
            $.slot := MINTER_STORAGE
        }
    }

    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");

    // UUPSUpgradeable

    function initialize(
        address owner,
        address peggedToken_,
        address leveragedToken_,
        address collateralToken_,
        address priceOracle_,
        address rateProvider_,
        uint128 criticalCollateralRatio_,
        uint128 minimumMintPeggedFeeRatio_
    ) public initializer {
        // initialise all the state variables
        __AccessControl_init();
        __UUPSUpgradeable_init();

        MinterStorage storage $ = _getMinterStorage();
        $.peggedToken = peggedToken_;
        $.leveragedToken = leveragedToken_;
        $.collateralToken = collateralToken_;
        $.priceOracle = priceOracle_;
        // TODO: is this the difference between a wrapped or non-wrapped collateral?
        $.rateProvider = rateProvider_;
        $.peggedTokenBalance = 0;
        $.criticalCollateralRatio = criticalCollateralRatio_;
        $.minimumMintPeggedFeeRatio = minimumMintPeggedFeeRatio_;

        _grantRole(DEFAULT_ADMIN_ROLE, owner);
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

    function freeMintPeggedToken(
        uint256 collateralIn,
        address recipient
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 peggedTokenOut) {
        MinterStorage storage $ = _getMinterStorage();
        // how much collateral to use
        collateralIn = _allOf(_msgSender(), $.collateralToken, collateralIn);

        // transfer and mint
        uint256 price = _fetchSafePrice($.priceOracle);
        peggedTokenOut = _freeMintPeggedToken($.collateralToken, collateralIn, price, $.peggedToken, recipient, 0);
    }

    function _freeMintPeggedToken(
        address collateralToken_,
        uint256 collateralIn,
        uint256 price,
        address peggedToken_,
        address recipient,
        uint256 fees
    ) internal returns (uint256 peggedTokenOut) {
        // get the collateral
        IERC20(collateralToken_).safeTransferFrom(_msgSender(), address(this), collateralIn);

        // mint the tokens to the recipient
        peggedTokenOut = (collateralIn * price) / 1 ether;
        IMintable(peggedToken_).mint(recipient, peggedTokenOut);

        // update our records
        MinterStorage storage $ = _getMinterStorage();
        $.peggedTokenBalance += peggedTokenOut;

        // tell the world
        emit MintPeggedToken(_msgSender(), recipient, collateralIn, peggedTokenOut, fees);
    }

    function mintPeggedTokenFees(uint256 collateralIn) external view override returns (uint256 fees) {
        // get the collateral ratio
        MinterStorage storage $ = _getMinterStorage();
        uint256 price = _fetchSafePrice($.priceOracle);
        uint256 newPeggedToken = (collateralIn * price) / 1 ether;

        fees = _mintPeggedTokenFees(
            IERC20($.collateralToken).balanceOf(address(this)),
            collateralIn,
            price,
            $.peggedTokenBalance + newPeggedToken,
            $.criticalCollateralRatio,
            $.minimumMintPeggedFeeRatio
        );
    }

    function _mintPeggedTokenFees(
        uint256 collateralHolding,
        uint256 newCollateral,
        uint256 collateralPrice,
        uint256 peggedHolding,
        uint128 criticalCollateralRatio,
        uint128 minimumMintPeggedFeeRatio
    ) internal pure returns (uint256 fees) {
        // collateral ratio if we were to execute a zero-fee mint
        uint256 newPeggedTokenOut = (newCollateral * collateralPrice) / 1 ether;
        uint256 newCollateralRatio = _collateralRatio(
            collateralHolding + newCollateral,
            collateralPrice,
            peggedHolding + newPeggedTokenOut
        );

        // see https://en.wikipedia.org/wiki/Smoothstep for details on the below
        // input is in terms of collateral ration which could be any number > 0
        // it need to be clamped between 0 and criticalCollateralRatio - 1
        // and as the output is 0 - 100% fee the clamping is normalised
        uint256 x = newCollateralRatio;
        if (x < 1 ether) x = 0;
        else if (x > criticalCollateralRatio) x = 1 ether;
        else x = ((x - 1 ether) * 1 ether) / (criticalCollateralRatio - 1 ether);

        // now do the smoothstep calculation
        uint256 smoothstep = (((x * x) / 1 ether) * (3 ether - 2 * x)) / 1 ether;

        // with adjustment for turning it upside down and having a minimum fee
        fees = 1 ether - ((1 ether - minimumMintPeggedFeeRatio) * smoothstep) / 1 ether;
    }

    /// @inheritdoc IMinter
    function mintPeggedToken(
        uint256 collateralIn,
        address recipient,
        uint256 minPeggedToken
    )
        external
        override
        returns (
            // TODO: uint256 maxFees maybe (minPeggedToken already covers that, indirectly)
            uint256 peggedTokenOut
        )
    {
        MinterStorage storage $ = _getMinterStorage();
        // work out how much collateral to use
        address msgSender = _msgSender();
        address collateralToken_ = $.collateralToken;
        collateralIn = _allOf(msgSender, collateralToken_, collateralIn);

        // do a zero fee simulation to, err, calculate fees.
        uint256 price = _fetchSafePrice($.priceOracle);
        uint256 newPeggedToken = (collateralIn * price) / 1 ether;
        // uint256 fees = _mintPeggedTokenFees(
        //     IERC20($.collateralToken).balanceOf(address(this)),
        //     collateralIn,
        //     price,
        //     $.peggedTokenBalance + newPeggedToken,
        //     $.criticalCollateralRatio,
        //     $.minimumMintPeggedFeeRatio
        // );

        // TODO: extract fees
        uint256 fees = 0;
        collateralIn -= fees;

        peggedTokenOut = (collateralIn * price) / 1 ether;
        address peggedToken_ = $.peggedToken;
        if (minPeggedToken > 0 && minPeggedToken < peggedTokenOut) revert InsufficientOutput(peggedToken_);

        peggedTokenOut = _freeMintPeggedToken($.collateralToken, collateralIn, price, $.peggedToken, recipient, 0);
    }

    // @inheritdoc IMinterTreasury

    function freeMintLegeragedToken(
        uint256 collateralIn,
        address recipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 peggedTokenOut, uint256 leveragedTokenOut) {
        MinterStorage storage $ = _getMinterStorage();
        // how much collateral to use
        collateralIn = _allOf(_msgSender(), $.collateralToken, collateralIn);
        IERC20($.collateralToken).safeTransferFrom(_msgSender(), address(this), collateralIn);

        // // mint the tokens to the recipient
        uint256 price = _fetchSafePrice($.priceOracle);

        // leveragedTokenOut = (collateralIn * price) / 1 ether / (1 ether - mintPeggedRatio);
        // IMintable($.peggedToken).mint(recipient, peggedTokenOut);
        // IMintable($.leveragedToken).mint(recipient, leveragedTokenOut);
    }

    /// @inheritdoc IMinter
    function mintLeveragedToken(
        uint256 collateralIn,
        address recipient,
        uint256 minXTokenMinted
    ) external override returns (uint256 lTokenMinted, uint256 bonus) {
        MinterStorage storage $ = _getMinterStorage();
        address collateralToken_ = $.collateralToken;
        address leveragedToken_ = $.leveragedToken;
        address priceOracle_ = $.priceOracle;
        address msgSender = _msgSender();

        collateralIn = _allOf(msgSender, collateralToken_, collateralIn);
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
        MinterStorage storage $ = _getMinterStorage();
        return $.collateralToken;
    }

    /// @notice Return the address of the pegged token.
    function peggedToken() external view override returns (address) {
        MinterStorage storage $ = _getMinterStorage();
        return $.peggedToken;
    }

    /// @notice Return the address of the leveraged token.
    function leveragedToken() external view override returns (address) {
        MinterStorage storage $ = _getMinterStorage();
        return $.leveragedToken;
    }

    function priceOracle() external view override returns (address) {
        MinterStorage storage $ = _getMinterStorage();
        return $.priceOracle;
    }

    function rateProvider() external view override returns (address) {
        MinterStorage storage $ = _getMinterStorage();
        return $.rateProvider;
    }

    function peggedTokenBalance() external view override returns (uint256) {
        MinterStorage storage $ = _getMinterStorage();
        return $.peggedTokenBalance;
    }

    /// @notice Return the current collateral ratio of the pToken to the collateral token, multipled by 1e18.
    function collateralRatio() external view override returns (uint256) {
        MinterStorage storage $ = _getMinterStorage();
        return
            _collateralRatio(
                IERC20($.collateralToken).balanceOf(address(this)),
                _fetchSafePrice($.priceOracle),
                $.peggedTokenBalance
            );
    }

    // internal functions do not access storage
    // TODO: move them to a library
    function _allOf(address account, address token, uint256 collateralIn) internal view returns (uint256 actualIn) {
        if (collateralIn == type(uint256).max) {
            actualIn = IERC20(token).balanceOf(account);
        } else {
            actualIn = collateralIn;
        }
        if (actualIn == 0) revert ZeroBalance();
    }

    // fetching collateral price in terms of the pegged token

    function _fetchSafePrice(address priceOracle_) internal view returns (uint256 safe) {
        (bool isValid, uint256 safe_, , ) = IPriceOracle(priceOracle_).getPrice();

        if (!isValid) revert InvalidOraclePrice();
        if (safe_ == 0) revert ZeroOraclePrice();
        safe = safe_;
    }

    function _fetchMinPrice(address priceOracle_) internal view returns (uint256 min) {
        (bool isValid, uint256 safe, uint256 min_, ) = IPriceOracle(priceOracle_).getPrice();
        min = isValid ? safe : min_;
        if (min == 0) revert ZeroOraclePrice();
    }

    function _fetchMaxPrice(address priceOracle_) internal view returns (uint256 max) {
        (bool isValid, uint256 safe, , uint256 max_) = IPriceOracle(priceOracle_).getPrice();
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
