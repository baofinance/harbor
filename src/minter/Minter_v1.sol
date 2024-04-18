// SPDX-License-Identifier: MIT
// coding standards by https://www.rareskills.io/post/solidity-style-guide
// and https://docs.soliditylang.org/en/latest/style-guide.html
pragma solidity 0.8.25;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlDefaultAdminRulesUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IMinter, IMinterTreasury } from "src/minter/IMinter.sol";
import { IMintable } from "src/minter/IMintable.sol";
import { IPriceOracle } from "src/price/IPriceOracle.sol";

import "forge-std/console.sol";

/// @title
/// @author
/// @notice provides a base layer interface for minting and redeeming pegged and leveraged tokens
/// also provides information about the net asset values of the pegged and leveraged tokens
/// @dev uses UUPS proxy, erc7201 storage

// TODO: check what ERC165 is used for
/// @custom:oz-upgrades
contract Minter_v1 is
    Initializable,
    UUPSUpgradeable,
    AccessControlDefaultAdminRulesUpgradeable,
    IMinter,
    IMinterTreasury
{
    using SafeERC20 for IERC20;

    // ratios are stored as uint32, which allows for a maximum value of ~4 billion
    // with decimals = 6, this gives a max ratio of 400,000% and the precision is 0.0001%,
    // e.g. 130.55% is easily catered for
    uint256 private constant RATIO_DECIMALS = 6;

    // zone indices for collateral ration, used to index CollateralRatioZones and the various FeeRatios
    enum CollateralRatioZones {
        bonus,
        rebalance,
        danger,
        normal,
        safe
    }
    uint private constant zones = 5;
    uint private constant zoneBounds = zones - 1;

    // Share-with-proxy Storage
    // ------------------------
    /// @custom:storage-location erc7201:bao.storage.Minter
    struct MinterStorage {
        //                                             slot
        address peggedToken; //                         160
        //                                             slot
        address leveragedToken; //                      160
        //                                             slot
        address collateralToken; //                     160
        // token balances: can't rely on balanceOf(address(this)) for key values
        // pegged token balance - we have to track pegged tokens
        // because we possibly are not the only minters of these pegged tokens
        // we are not likely to use these tokens as bonus because during a bonus period pegged minting
        // will not be allowed
        //                                             slot
        uint256 peggedTokenBalance; //                  256
        // leveragedTokenBalance - we track this here because this contract can also own collateral tokens
        // that will be used for the reserve pool
        //                                             slot
        uint256 leveragedTokenBalance; //               256
        // collateralTokenBalance - we track this here because this contract can also own collateral tokens
        // that will be used for the reserve pool
        // TODO: do we want a collateral cap?
        //                                             slot
        uint256 collateralTokenBalance; //              256
        //                                             slot
        address priceOracle; //                         160
        //                                             slot
        address feeReceiver; //                         160
        //                                             slot
        // CollateralRatioConfig - index is CollateralRatioZones
        uint32[zoneBounds] collateralRatioUpperBounds; //    192
        //                                             slot
        // FeeConfigs  - index is CollateralRatioZones
        uint32[zones] mintPeggedTokenFeeRatios; //      192
        //                                             slot
        uint32[zones] redeemPeggedTokenFeeRatios; //    192
        //                                             slot
        uint32[zones] mintLeveragedTokenFeeRatios; //   192
        //                                             slot
        uint32[zones] redeemLeveragedTokenFeeRatios; // 192
        //                                             slot
        // BonusConfig
        //                                             slot
        // TODO: fold bonus into fee structure, as there is space.
        // bonusTokens given out must be owned by the Minter,
        // if it is the collateral token then only those above the collateral depsited, hence collateralTokenBalance
        // bonus can also be an xtoken? then these may owned by the Minter or can be minted using owned bonus tokens
        address bonusToken; //                          160
        uint32 mintLeveragedBonusRatio; //              192
        uint32 redeemPeggedBonusRatio; //               224
    }

    // keccak256(abi.encode(uint256(keccak256("bao.storage.Minter")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant MINTER_STORAGE = 0x92e73fe9557052b4a0b810a38eb7ef595ff750f166ca39d63b3f4c74937fef00;

    // TODO: also the difference between external and public (apart from the auto generation of getters and setters)
    function _getMinterStorage() private pure returns (MinterStorage storage $) {
        assembly {
            $.slot := MINTER_STORAGE
        }
    }

    // TODO: add function to add a rebalancer, granting role and keeping track of it for liquidation
    bytes32 public constant ZERO_FEE_ROLE = keccak256("ZERO_FEE_ROLE");

    // UUPSUpgradeable functions
    // -------------------------

    function initialize(
        address owner,
        BalanceTokens calldata tokens_,
        address priceOracle_,
        address feeReceiver_,
        CollateralRatioBoundsConfig calldata collateralRatioConfig_,
        FeeConfig calldata feeConfig_,
        BonusConfig calldata bonusConfig_
    ) external initializer {
        // initialise all the state variables
        __AccessControlDefaultAdminRules_init(7 days, owner);
        __UUPSUpgradeable_init();

        MinterStorage storage $ = _getMinterStorage();
        // balance tokens
        $.collateralToken = tokens_.collateralToken;
        $.collateralTokenBalance = 0;
        $.peggedToken = tokens_.peggedToken;
        $.peggedTokenBalance = 0;
        $.leveragedToken = tokens_.leveragedToken;
        $.leveragedTokenBalance = 0;

        _updatePriceOracle(priceOracle_);
        _updateFeeReceiver(feeReceiver_);

        _updateCollateralRatioConfig(collateralRatioConfig_);
        _updateFeeConfig(feeConfig_);
        _updateBonusConfig(bonusConfig_);

        _grantRole(ZERO_FEE_ROLE, owner);
        // TODO: should we be saving the last permissioned price? _fetchSafePrice(priceOracle_)
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // stop the implementation being initialized to any version
        // https://forum.openzeppelin.com/t/what-does-disableinitializers-function-mean/28730
        _disableInitializers();
    }

    // only owners can upgrade this contract
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // Updater functions
    // -----------------

    function updateCollateralRatioConfig(
        CollateralRatioBoundsConfig calldata collateralRatioConfig_
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _updateCollateralRatioConfig(collateralRatioConfig_);
    }

    function _checkCollateralRatioConfigValues(uint256 shouldBeLessEqual, uint256 shouldBeMoreEqual) private pure {
        if (shouldBeLessEqual > shouldBeMoreEqual) {
            revert InvalidCollateralRatioConfig(shouldBeLessEqual, shouldBeMoreEqual);
        }
    }

    function _updateCollateralRatioConfig(CollateralRatioBoundsConfig calldata collateralRatioConfig_) private {
        // check the collateral ratios are greater or equal to the previous
        _checkCollateralRatioConfigValues(
            collateralRatioConfig_.bonusCollateralRatioUpperBound,
            collateralRatioConfig_.rebalanceCollateralRatioUpperBound
        );
        _checkCollateralRatioConfigValues(
            collateralRatioConfig_.rebalanceCollateralRatioUpperBound,
            collateralRatioConfig_.dangerCollateralRatioUpperBound
        );
        _checkCollateralRatioConfigValues(
            collateralRatioConfig_.dangerCollateralRatioUpperBound,
            collateralRatioConfig_.normalCollateralRatioUpperBound
        );
        MinterStorage storage $ = _getMinterStorage();
        $.collateralRatioUpperBounds[uint(CollateralRatioZones.bonus)] = _etherRatio(
            collateralRatioConfig_.bonusCollateralRatioUpperBound
        );
        $.collateralRatioUpperBounds[uint(CollateralRatioZones.rebalance)] = _etherRatio(
            collateralRatioConfig_.rebalanceCollateralRatioUpperBound
        );
        $.collateralRatioUpperBounds[uint(CollateralRatioZones.danger)] = _etherRatio(
            collateralRatioConfig_.dangerCollateralRatioUpperBound
        );
        $.collateralRatioUpperBounds[uint(CollateralRatioZones.normal)] = _etherRatio(
            collateralRatioConfig_.normalCollateralRatioUpperBound
        );
        emit UpdateCollateralRatioConfig(collateralRatioConfig_);
    }

    function updateFeeConfig(FeeConfig calldata feeConfig_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _updateFeeConfig(feeConfig_);
    }

    function _updateFeeConfig(FeeConfig calldata feeConfig_) private {
        // TODO: check the ranges of fee config, between 0 and 1
        MinterStorage storage $ = _getMinterStorage();
        $.mintPeggedTokenFeeRatios[uint(CollateralRatioZones.bonus)] = _etherRatio(
            feeConfig_.mintPeggedToken.bonusFeeRatio
        );
        $.mintPeggedTokenFeeRatios[uint(CollateralRatioZones.rebalance)] = _etherRatio(
            feeConfig_.mintPeggedToken.rebalanceFeeRatio
        );
        $.mintPeggedTokenFeeRatios[uint(CollateralRatioZones.danger)] = _etherRatio(
            feeConfig_.mintPeggedToken.dangerFeeRatio
        );
        $.mintPeggedTokenFeeRatios[uint(CollateralRatioZones.normal)] = _etherRatio(
            feeConfig_.mintPeggedToken.normalFeeRatio
        );
        $.mintPeggedTokenFeeRatios[uint(CollateralRatioZones.safe)] = _etherRatio(
            feeConfig_.mintPeggedToken.safeFeeRatio
        );

        $.redeemPeggedTokenFeeRatios[uint(CollateralRatioZones.bonus)] = _etherRatio(
            feeConfig_.redeemPeggedToken.bonusFeeRatio
        );
        $.redeemPeggedTokenFeeRatios[uint(CollateralRatioZones.rebalance)] = _etherRatio(
            feeConfig_.redeemPeggedToken.rebalanceFeeRatio
        );
        $.redeemPeggedTokenFeeRatios[uint(CollateralRatioZones.danger)] = _etherRatio(
            feeConfig_.redeemPeggedToken.dangerFeeRatio
        );
        $.redeemPeggedTokenFeeRatios[uint(CollateralRatioZones.normal)] = _etherRatio(
            feeConfig_.redeemPeggedToken.normalFeeRatio
        );
        $.redeemPeggedTokenFeeRatios[uint(CollateralRatioZones.safe)] = _etherRatio(
            feeConfig_.redeemPeggedToken.safeFeeRatio
        );

        $.mintLeveragedTokenFeeRatios[uint(CollateralRatioZones.bonus)] = _etherRatio(
            feeConfig_.mintLeveragedToken.bonusFeeRatio
        );
        $.mintLeveragedTokenFeeRatios[uint(CollateralRatioZones.rebalance)] = _etherRatio(
            feeConfig_.mintLeveragedToken.rebalanceFeeRatio
        );
        $.mintLeveragedTokenFeeRatios[uint(CollateralRatioZones.danger)] = _etherRatio(
            feeConfig_.mintLeveragedToken.dangerFeeRatio
        );
        $.mintLeveragedTokenFeeRatios[uint(CollateralRatioZones.normal)] = _etherRatio(
            feeConfig_.mintLeveragedToken.normalFeeRatio
        );
        $.mintLeveragedTokenFeeRatios[uint(CollateralRatioZones.safe)] = _etherRatio(
            feeConfig_.mintLeveragedToken.safeFeeRatio
        );

        $.redeemLeveragedTokenFeeRatios[uint(CollateralRatioZones.bonus)] = _etherRatio(
            feeConfig_.redeemLeveragedToken.bonusFeeRatio
        );
        $.redeemLeveragedTokenFeeRatios[uint(CollateralRatioZones.rebalance)] = _etherRatio(
            feeConfig_.redeemLeveragedToken.rebalanceFeeRatio
        );
        $.redeemLeveragedTokenFeeRatios[uint(CollateralRatioZones.danger)] = _etherRatio(
            feeConfig_.redeemLeveragedToken.dangerFeeRatio
        );
        $.redeemLeveragedTokenFeeRatios[uint(CollateralRatioZones.normal)] = _etherRatio(
            feeConfig_.redeemLeveragedToken.normalFeeRatio
        );
        $.redeemLeveragedTokenFeeRatios[uint(CollateralRatioZones.safe)] = _etherRatio(
            feeConfig_.redeemLeveragedToken.safeFeeRatio
        );

        emit UpdateFeeConfig(feeConfig_);
    }

    function updateBonusConfig(BonusConfig calldata bonusConfig_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _updateBonusConfig(bonusConfig_);
    }

    function _updateBonusConfig(BonusConfig calldata bonusConfig_) private {
        MinterStorage storage $ = _getMinterStorage();
        $.bonusToken = bonusConfig_.bonusToken;
        $.mintLeveragedBonusRatio = _etherRatio(bonusConfig_.mintLeveragedBonusRatio);
        $.redeemPeggedBonusRatio = _etherRatio(bonusConfig_.redeemPeggedBonusRatio);
        emit UpdateBonusConfig(bonusConfig_);
    }

    function updatePriceOracle(address priceOracle_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _updatePriceOracle(priceOracle_);
    }

    function _updatePriceOracle(address priceOracle_) private {
        MinterStorage storage $ = _getMinterStorage();
        address old = $.priceOracle;
        $.priceOracle = priceOracle_;
        emit UpdatePriceOracle(old, priceOracle_);
    }

    function updateFeeReceiver(address feeReceiver_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _updateFeeReceiver(feeReceiver_);
    }
    function _updateFeeReceiver(address feeReceiver_) private {
        MinterStorage storage $ = _getMinterStorage();
        address old = $.feeReceiver;
        $.feeReceiver = feeReceiver_;
        emit UpdateFeeReceiver(old, feeReceiver_);
    }

    // Mint/Redeem Pegged/Leveraged functions
    // --------------------------------------

    /// @inheritdoc IMinter
    function mintPeggedToken(
        uint256 collateralIn,
        address recipient,
        uint256 minPeggedTokenOut
    ) external override returns (uint256 peggedTokenOut) {
        MinterStorage storage $ = _getMinterStorage();
        // work out how much collateral to use
        address collateralToken_ = $.collateralToken;
        collateralIn = _allOf(_msgSender(), collateralToken_, collateralIn);

        uint256 price = _fetchSafePrice($.priceOracle);
        // TODO: handle depegged situation
        uint256 newPeggedToken = (collateralIn * price) / 1 ether;

        // TODO: consider deducting the current fee before calculating the actual fee
        uint256 collateralRatio_ = _collateralRatio(
            $.collateralTokenBalance + collateralIn,
            price,
            $.peggedTokenBalance + newPeggedToken
        );

        uint256 feeRatio = _feeRatio(collateralRatio_, $.collateralRatioUpperBounds, $.mintPeggedTokenFeeRatios);

        uint256 fee = (collateralIn * feeRatio) / 1 ether;
        uint256 collateralUsed = collateralIn - fee;

        // recalculate the amounts involved
        peggedTokenOut = (collateralUsed * price) / 1 ether;
        if (peggedTokenOut < minPeggedTokenOut) {
            revert MintInsufficientAmount($.peggedToken, minPeggedTokenOut, peggedTokenOut);
        }
        IERC20(collateralToken_).safeTransferFrom(_msgSender(), $.feeReceiver, fee);
        _mintPeggedToken(collateralToken_, collateralUsed, $.peggedToken, peggedTokenOut, recipient, fee);
    }

    function freeMintPeggedToken(
        uint256 collateralIn,
        address recipient
    ) external override onlyRole(ZERO_FEE_ROLE) returns (uint256 peggedTokenOut) {
        MinterStorage storage $ = _getMinterStorage();
        // how much collateral to use
        address collateralToken_ = $.collateralToken;
        collateralIn = _allOf(_msgSender(), collateralToken_, collateralIn);

        // transfer and mint
        uint256 price = _fetchSafePrice($.priceOracle);
        peggedTokenOut = (collateralIn * price) / 1 ether;
        _mintPeggedToken(collateralToken_, collateralIn, $.peggedToken, peggedTokenOut, recipient, 0);
    }

    function _mintPeggedToken(
        address collateralToken_,
        uint256 collateralUsed,
        address peggedToken_,
        uint256 peggedTokenOut,
        address recipient,
        uint256 fees // only for the emit
    ) private {
        // slither-disable-next-line incorrect-equality
        if (collateralUsed + fees == 0) {
            revert ZeroInputBalance(collateralToken_);
        }
        emit MintPeggedToken(_msgSender(), recipient, collateralUsed + fees, peggedTokenOut, fees);

        // mint the tokens to the recipient
        IMintable(peggedToken_).mint(recipient, peggedTokenOut);
        // take the collateral
        IERC20(collateralToken_).safeTransferFrom(_msgSender(), address(this), collateralUsed);

        // update our records
        MinterStorage storage $ = _getMinterStorage();
        $.peggedTokenBalance += peggedTokenOut;
        $.collateralTokenBalance += collateralUsed;
    }

    /// @inheritdoc IMinter
    function redeemPeggedToken(
        uint256 peggedTokenIn,
        address recipient,
        uint256 minCollateralOut
    ) external override returns (uint256 collateralOut, uint256 bonus) {
        // TODO: add a bonus here
    }

    // TODO: also add a swap function (free and fee'd) that swaps a pegged token for an xtoken, the free one does so to rebalance
    // TODO: actually get rid of the free functions and replace with the swap?

    /// @inheritdoc IMinter
    function mintLeveragedToken(
        uint256 collateralIn,
        address recipient,
        uint256 minLeveragedTokenOut
    ) external override returns (uint256 leveragedTokenOut, uint256 bonusOut) {
        MinterStorage storage $ = _getMinterStorage();
        address collateralToken_ = $.collateralToken;
        collateralIn = _allOf(_msgSender(), collateralToken_, collateralIn);

        uint256 price = _fetchSafePrice($.priceOracle);
        uint256 currentCollateralRatio = _collateralRatio($.collateralTokenBalance, price, $.peggedTokenBalance);

        uint256 feeRatio = _feeRatio(
            currentCollateralRatio,
            $.collateralRatioUpperBounds,
            $.mintLeveragedTokenFeeRatios
        );

        uint256 fee = (collateralIn * feeRatio) / 1 ether;
        uint256 collateralUsed = collateralIn - fee;
        bonusOut = 0;
        // TODO: add the rebalance pool balance
        if (fee == 0 && currentCollateralRatio < $.collateralRatioUpperBounds[uint(CollateralRatioZones.bonus)]) {
            // TODO: add the bonus here (if rebalance pools are exhausted)
        }

        leveragedTokenOut = _leverageTokensForCollateral(
            collateralUsed,
            $.leveragedTokenBalance,
            $.peggedTokenBalance,
            $.collateralTokenBalance,
            price
        );
        if (leveragedTokenOut < minLeveragedTokenOut) {
            revert MintInsufficientAmount($.leveragedToken, minLeveragedTokenOut, leveragedTokenOut);
        }
        IERC20(collateralToken_).safeTransferFrom(_msgSender(), $.feeReceiver, fee);
        _mintLeveragedToken(
            collateralToken_,
            collateralUsed,
            $.leveragedToken,
            leveragedTokenOut,
            recipient,
            fee,
            bonusOut
        );
    }

    // @inheritdoc IMinter
    function freeMintLeveragedToken(
        uint256 collateralIn,
        address recipient
    ) external override onlyRole(ZERO_FEE_ROLE) returns (uint256 leveragedTokenOut) {
        MinterStorage storage $ = _getMinterStorage();
        // how much collateral to use
        address collateralToken_ = $.collateralToken;
        collateralIn = _allOf(_msgSender(), collateralToken_, collateralIn);

        // mint the tokens to the recipient
        uint256 price = _fetchSafePrice($.priceOracle);

        leveragedTokenOut = _leverageTokensForCollateral(
            collateralIn,
            $.leveragedTokenBalance,
            $.peggedTokenBalance,
            $.collateralTokenBalance,
            price
        );

        _mintLeveragedToken(collateralToken_, collateralIn, $.leveragedToken, leveragedTokenOut, recipient, 0, 0);
    }

    function _mintLeveragedToken(
        address collateralToken_,
        uint256 collateralUsed,
        address leveragedToken_,
        uint256 leveragedTokenOut,
        address recipient,
        uint256 fees, // only for the emit
        uint256 bonus // only for the emit
    ) private {
        // tell the world
        emit MintLeveragedToken(_msgSender(), recipient, collateralUsed + fees, leveragedTokenOut, fees, bonus);

        // mint the tokens to the recipient
        IMintable(leveragedToken_).mint(recipient, leveragedTokenOut);
        // take the collateral
        IERC20(collateralToken_).safeTransferFrom(_msgSender(), address(this), collateralUsed);

        // update our records
        MinterStorage storage $ = _getMinterStorage();
        // console.log("leveragedTokenBalance=%s + %s", $.leveragedTokenBalance, leveragedTokenOut);
        $.leveragedTokenBalance += leveragedTokenOut;
        $.collateralTokenBalance += collateralUsed;
    }

    /// @inheritdoc IMinter
    function redeemLeveragedToken(
        uint256 leveragedTokenIn,
        address recipient,
        uint256 minCollateralOut
    ) external override returns (uint256 collateralOut) {}

    function _allOf(address account, address token, uint256 collateralIn) private view returns (uint256 actualIn) {
        if (collateralIn == type(uint256).max) {
            actualIn = IERC20(token).balanceOf(account);
        } else {
            actualIn = collateralIn;
        }
        // slither-disable-next-line incorrect-equality
        if (actualIn == 0) {
            revert ZeroInputBalance(token);
        }
    }

    // @inheritdoc IMinter
    function freeRedeemLeveragedToken(
        uint256 leveragedTokenIn
    ) external override onlyRole(ZERO_FEE_ROLE) returns (uint256 collateralTokenOut) {
        /*        MinterStorage storage $ = _getMinterStorage();
        // how much collateral to use
        address collateralToken_ = $.collateralToken;
        collateralIn = _allOf(_msgSender(), collateralToken_, collateralIn);

        // mint the tokens to the recipient
        uint256 price = _fetchSafePrice($.priceOracle);

        leveragedTokenOut = _leverageTokensForCollateral(
            collateralIn,
            $.leveragedTokenBalance,
            $.peggedTokenBalance,
            $.collateralTokenBalance,
            price
        );

        _mintLeveragedToken(collateralToken_, collateralIn, $.leveragedToken, leveragedTokenOut, recipient, 0, 0);
*/
    }

    // -------------------------
    // Fee calculation functions
    // -------------------------

    function mintPeggedTokenFeeRatio(uint256 additionalCollateral) external view override returns (uint256 feeRatio) {
        // get the collateral ratio
        //console.log("additionalCollateral=%s", additionalCollateral);
        MinterStorage storage $ = _getMinterStorage();
        uint256 price = _fetchSafePrice($.priceOracle);
        //console.log("price=%s", price);
        uint256 newPeggedToken = (additionalCollateral * price) / 1 ether;
        //console.log("newPeggedToken=%s", newPeggedToken);

        feeRatio = _feeRatio(
            _collateralRatio(
                $.collateralTokenBalance + additionalCollateral,
                price,
                $.peggedTokenBalance + newPeggedToken
            ),
            $.collateralRatioUpperBounds,
            $.mintPeggedTokenFeeRatios
        );
        if (feeRatio == type(uint256).max) {
            feeRatio = 0;
            // disallowed = true;
        }
        //console.log("mintPeggedTokenFeeRatio=%s", feeRatio);
    }

    function redeemPeggedTokenFeeRatio() external view override returns (uint256 feeRatio) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 price = _fetchSafePrice($.priceOracle);
        feeRatio = _feeRatio(
            _collateralRatio($.collateralTokenBalance, price, $.peggedTokenBalance),
            $.collateralRatioUpperBounds,
            $.redeemPeggedTokenFeeRatios
        );
    }

    // TODO: should be fees lower/bonus higher for higher leveraged token redeem amount
    function mintLeveragedTokenFeeRatio() external view override returns (uint256 feeRatio) {
        MinterStorage storage $ = _getMinterStorage();
        // TODO: do we need safe price for this?
        uint256 price = _fetchSafePrice($.priceOracle);
        feeRatio = _feeRatio(
            _collateralRatio($.collateralTokenBalance, price, $.peggedTokenBalance),
            $.collateralRatioUpperBounds,
            $.mintLeveragedTokenFeeRatios
        );
    }

    function redeemLeveragedTokenFeeRatio(
        uint256 reductionOfcollateral
    ) external view override returns (uint256 feeRatio) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 price = _fetchSafePrice($.priceOracle);
        uint256 collateralTokenBalance_ = $.collateralTokenBalance;
        // TODO: make sure there wont be a subtaction underflow
        feeRatio = _feeRatio(
            _collateralRatio(collateralTokenBalance_ - reductionOfcollateral, price, $.peggedTokenBalance),
            $.collateralRatioUpperBounds,
            $.redeemLeveragedTokenFeeRatios
        );
    }

    // TODO: add a function that shifts and scales on x and y and also inverts.
    // TODO: add a function that skews the x and y? so that y is 0.5 at some given intermediate point, not 0.5.
    //       This is to merge bonus and fees?
    //       Or to slowly ramp up fees as CR drops, and rapidly increase as it reaches the next CR config value

    function _smoothstep(uint256 x, uint256 edge0, uint256 edge1) private pure returns (uint256 smoothstep) {
        // see https://en.wikipedia.org/wiki/Smoothstep for details on the below
        // input is in terms of collateral ratio which could be any number > 0
        // it need to be clamped between 0 and criticalCollateralRatio - 1
        // and as the output is 0 - 100% fee the clamping is normalised
        // console.log("newCollateralRatio=%s", newCollateralRatio);

        // TODO: check this for very small x, because, e.g. x*x is even smaller.
        if (x <= edge0) {
            smoothstep = 0;
        } else if (x >= edge1) {
            smoothstep = 1 ether;
        } else {
            // scale 0 to 1 vs edge0 to edge1
            uint256 t = ((x - edge0) * 1 ether) / (edge1 - edge0);
            // do the smoothstep calculation
            // first order smooth
            // 3*x^2 - 2*x^3
            // slither-disable-next-line divide-before-multiply
            smoothstep = (t * t * (3 * 1 ether - 2 * t)) / (10 ** 36);
            /*
            uint256 x2 = (x * x) / (1 ether); // Normalize x^2
            smoothstep = (x2 * (3 ether - 2 * x)) / 1 ether;
            // second order smooth, unfortunately x^5 is likely to underflow, so we need to do more work to get this
            // 6*x^5 - 15*x^4 + 10*x^3
            // smoothstep = (((x2 * x2) / 1 ether) * (((x * (6 * x - 15 ether)) / 1 ether) + 10 ether)) / 1 ether;
            //                    -------------------            ----------------                --------
            //                                            ------------------------------------------------
            //                   ----------------------------------------------------
            */
        }
    }

    function _ratioEther(uint32 field) private pure returns (uint256) {
        return field * 10 ** (18 - RATIO_DECIMALS);
    }

    function _etherRatio(uint256 field) private pure returns (uint32) {
        return uint32(field / 10 ** (18 - RATIO_DECIMALS));
    }

    function _feeRatio(
        uint256 atCollateralRatio,
        uint32[zoneBounds] memory collateralRatios,
        uint32[zones] memory feeRatios
    ) private pure returns (uint256 feeRatio) {
        // find the upper and lower bounds of the collateral ration zone we are in
        // TODO: add zone for depegged
        //console.log("CR=%s", atCollateralRatio);
        for (uint ib = 0; ib < uint(collateralRatios.length); ib++) {
            uint j = collateralRatios.length - 1 - ib;
            //console.log("?%s > collateralRatios[%s](%s)", atCollateralRatio, j, _ratioEther(collateralRatios[j]));
            if (atCollateralRatio > _ratioEther(collateralRatios[j])) {
                // found the upper bound for the zone below
                // console.log("found lower bound at j=%s, CR=%s", j, _ratioEther(collateralRatios[j]));
                if (j == collateralRatios.length - 1) {
                    // in the safe zone, where the fees are flat
                    return _ratioEther(feeRatios[j + 1]);
                }
                uint256 upperBoundFeeRatio = _ratioEther(feeRatios[j + 2]);
                uint256 lowerBoundFeeRatio = _ratioEther(feeRatios[j + 1]);
                if (upperBoundFeeRatio == lowerBoundFeeRatio) {
                    // console.log("lower, upper bound fee=%s, %s", lowerBoundFeeRatio, upperBoundFeeRatio);
                    return upperBoundFeeRatio;
                } else {
                    uint256 upperCollateralRatio = _ratioEther(collateralRatios[j + 1]);
                    uint256 lowerCollateralRatio = _ratioEther(collateralRatios[j]);
                    // console.log("upper bound CR=%s, fee=%s", upperCollateralRatio, upperBoundFeeRatio);
                    // console.log("lower bound CR=%s, fee=%s", lowerCollateralRatio, lowerBoundFeeRatio);
                    // see https://en.wikipedia.org/wiki/Smoothstep for details on the below

                    // scale 0 to 1 vs the two collateral ration edges
                    uint256 t = ((atCollateralRatio - lowerCollateralRatio) * 1 ether) /
                        (upperCollateralRatio - lowerCollateralRatio);
                    // console.log("t=%s", t);
                    // do the smoothstep calculation
                    // first order smooth
                    // 3*x^2 - 2*x^3
                    // slither-disable-next-line divide-before-multiply
                    uint256 smoothstep = (t * t * (3 * 1 ether - 2 * t)) / (10 ** 36);
                    // console.log("smoothstep=%s", smoothstep);
                    /*
                    uint256 x2 = (x * x) / (1 ether); // Normalize x^2
                    smoothstep = (x2 * (3 ether - 2 * x)) / 1 ether;
                    // second order smooth, unfortunately x^5 is likely to underflow, so we need to do more work to get this
                    // 6*x^5 - 15*x^4 + 10*x^3
                    // smoothstep = (((x2 * x2) / 1 ether) * (((x * (6 * x - 15 ether)) / 1 ether) + 10 ether)) / 1 ether;
                    //                    -------------------            ----------------                --------
                    //                                            ------------------------------------------------
                    //                   ----------------------------------------------------
                    */
                    // now scale the smoothstep into fee ratio space and invert it
                    if (upperBoundFeeRatio > lowerBoundFeeRatio) {
                        // step up
                        // console.log("step up=%s", upperBoundFeeRatio - lowerBoundFeeRatio);
                        return ((upperBoundFeeRatio - lowerBoundFeeRatio) * smoothstep) / 1 ether + lowerBoundFeeRatio;
                    } else {
                        // step down
                        // console.log("step down=%s", lowerBoundFeeRatio - upperBoundFeeRatio);
                        return
                            ((lowerBoundFeeRatio - upperBoundFeeRatio) * (1 ether - smoothstep)) /
                            1 ether +
                            upperBoundFeeRatio;
                    }
                }
            }
        }
        // console.log("bonus zone, fee=", _ratioEther(feeRatios[0]));
        return _ratioEther(feeRatios[0]);
    }

    // other calculations
    // ------------------

    function leveragedTokenNAV() external view override returns (uint256 nav) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 leveragedTokenBalance_ = IERC20($.leveragedToken).balanceOf(address(this));
        uint256 price = _fetchSafePrice($.priceOracle);
        nav = _leveragedTokenNAV(leveragedTokenBalance_, $.peggedTokenBalance, $.collateralTokenBalance, price);
    }

    function _leveragedTokenNAV(
        uint256 leveragedTokenBalance_,
        uint256 peggedTokenBalance_,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice
    ) private view returns (uint256 nav) {
        // TODO if the collateral ratio is 0, nav is 0 - check that this doesn't just work out
        // slither-disable-next-line incorrect-equality
        if (leveragedTokenBalance_ == 0) {
            nav = 1 ether;
        } else {
            // TODO: is this the right price?
            uint256 collateralValue = collateralTokenBalance_ * collateralPrice;
            uint256 peggedValue = peggedTokenBalance_ * 1 ether;
            if (collateralValue < peggedValue) {
                // this is where the invariant is, err, variant in that the leveraged value should have gone negative
                // this essentially means that the pegged token is, err, no longer pegged
                // - at least those pegged tokens that are backed by this colllateral
                // TODO: find some way of managing BaoUSD's depegging such that all collateral is taken into account
                // to work out it's NAV given the total supply of pegged = value of the total collateral
                nav = 0;
            } else {
                // this is the invariant collateral value  = pegged value + leveraged value
                nav = (collateralValue - peggedValue) / leveragedTokenBalance_;
                console.log("nav=%s", nav);
                console.log("nav=(%s-%s)/%s", collateralValue, peggedValue, leveragedTokenBalance_);
            }
        }
    }

    function leverageTokensForCollateral(
        uint256 forCollateral
    ) external view override returns (uint256 leveragedTokens) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 price = _fetchSafePrice($.priceOracle);
        leveragedTokens = _leverageTokensForCollateral(
            forCollateral,
            $.leveragedTokenBalance,
            $.peggedTokenBalance,
            $.collateralTokenBalance,
            price
        );
    }

    function _leverageTokensForCollateral(
        uint256 forCollateral,
        uint256 leveragedTokenBalance_,
        uint256 peggedTokenBalance_,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice
    ) private pure returns (uint256 leveragedTokens) {
        // the following assumes that the collateral change is very small compared to the overall collateral
        // because it is the derivative of the legeraged balance with respect to the collateral balance
        // using the invariant collateral value = leveraged value + pegged value.
        // which assumes the leveraged nav doesn't change, i.e. that the invariant is linear in collateral balance
        // which it isn't
        // TODO: work out the acceptable amount of collateral as a ratio that can be added in one go
        // and split this equation into a series of steps, i.e. do a piecewise differentiation, or
        // work out how leveraged nav varies with collateral tokens without using the invariant (if that's possible)
        // or investigate if this is why Aladdin are using the moving average for leverage ratio
        // Note: if leveraged balance is 0 this returns 0, so we have to bootstrap this contract with some leveraged tokens
        //       or work out the correct equation, assuming there is one solution:
        //           leveraged nav can vary or leveraged balance can vary
        leveragedTokens = forCollateral * collateralPrice;
        if (leveragedTokenBalance_ > 0) {
            // TODO: what to do if (collateralTokenBalance_ * collateralPrice) <= peggedTokenBalance_ * 1 ether
            // i.e. when pegged value is greater or equal to collateral value,
            // i.e. when collateral ratio is less than 1, at initialisation or if all pegged are redeemed
            // all at times when we should be quite happily mint more tokens
            leveragedTokens =
                (leveragedTokens * leveragedTokenBalance_) /
                (collateralTokenBalance_ * collateralPrice - peggedTokenBalance_ * 1 ether);
        } else {
            leveragedTokens /= 1 ether; // TODO: check if there can be any starting price
        }
    }

    /// @notice Return the current collateral ratio of the peggedToken to the collateral token, multipled by 1e18.
    function collateralRatio() external view override returns (uint256) {
        MinterStorage storage $ = _getMinterStorage();
        return _collateralRatio($.collateralTokenBalance, _fetchSafePrice($.priceOracle), $.peggedTokenBalance);
    }

    function _collateralRatio(
        uint256 collateralTokenBalance_,
        uint256 collateralPrice,
        uint256 peggedTokenBalance_
    ) private pure returns (uint256 collateralRatio_) {
        //console.log("collateralRatio(%s,%s,%s)", collateralTokenBalance_, collateralPrice, peggedTokenBalance_);
        if (peggedTokenBalance_ == 0) {
            collateralRatio_ = type(uint256).max; // just needs to be high so fees are calculated properly
        } else {
            collateralRatio_ = (collateralTokenBalance_ * collateralPrice) / peggedTokenBalance_;
        }
        // console.log("collateralRatio()=%s", collateralRatio_);
    }

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

    function feeReceiver() external view override returns (address) {
        MinterStorage storage $ = _getMinterStorage();
        return $.feeReceiver;
    }

    // function rateProvider() external view override returns (address) {
    //     MinterStorage storage $ = _getMinterStorage();
    //     return $.rateProvider;
    // }

    function peggedTokenBalance() external view override returns (uint256) {
        MinterStorage storage $ = _getMinterStorage();
        return $.peggedTokenBalance;
    }

    function leveragedTokenBalance() external view override returns (uint256) {
        MinterStorage storage $ = _getMinterStorage();
        return $.leveragedTokenBalance;
    }

    function collateralTokenBalance() external view override returns (uint256) {
        MinterStorage storage $ = _getMinterStorage();
        return $.collateralTokenBalance;
    }

    // fetching collateral price in terms of the pegged token

    function _fetchSafePrice(address priceOracle_) private view returns (uint256 safe) {
        // slither-disable-next-line unused-return
        (bool isValid, uint256 safe_, , ) = IPriceOracle(priceOracle_).getPrice();

        if (!isValid) {
            revert InvalidOraclePrice();
        }
        if (safe_ == 0) {
            revert ZeroOraclePrice();
        }
        safe = safe_;
    }

    function _fetchMinPrice(address priceOracle_) private view returns (uint256 min) {
        // slither-disable-next-line unused-return
        (bool isValid, uint256 safe, uint256 min_, ) = IPriceOracle(priceOracle_).getPrice();
        min = isValid ? safe : min_;
        if (min == 0) {
            revert ZeroOraclePrice();
        }
    }

    function _fetchMaxPrice(address priceOracle_) private view returns (uint256 max) {
        // slither-disable-next-line unused-return
        (bool isValid, uint256 safe, , uint256 max_) = IPriceOracle(priceOracle_).getPrice();
        max = isValid ? safe : max_;
        if (max == 0) {
            revert ZeroOraclePrice();
        }
    }
}
