// SPDX-License-Identifier: MIT
// coding standards by https://www.rareskills.io/post/solidity-style-guide
// and https://docs.soliditylang.org/en/latest/style-guide.html
pragma solidity 0.8.25;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
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
contract Minter_v1 is Initializable, UUPSUpgradeable, AccessControlUpgradeable, IMinter, IMinterTreasury {
    using SafeERC20 for IERC20;

    // ratios are stored as uint32, which allows for a maximum value of ~4 billion
    // with decimals = 6, this gives a max ratio of 400,000% and the precision is 0.0001%,
    // e.g. 130.55% is easily catered for
    uint256 private constant RATIO_DECIMALS = 6;

    // Share-with-proxy Storage
    // ------------------------
    /// @custom:storage-location erc7201:bao.storage.Minter
    struct MinterStorage {
        //                                          slot
        address peggedToken; //                         160
        //                                          slot
        address leveragedToken; //                      160
        //                                          slot
        address collateralToken; //                     160
        // pegged token balance - we have to track pegged tokens
        // because we possibly are not the only minters of these pegged tokens
        // we are not likely to use these tokens as bonus because during a bonus period pegged minting
        // will not be allowed
        //                                          slot
        uint256 peggedTokenBalance; //                  256
        // leveragedTokenBalance - we track this here because this contract can also own collateral tokens
        // that will be used for the reserve pool
        //                                          slot
        uint256 leveragedTokenBalance; //              256
        // collateralTokenBalance - we track this here because this contract can also own collateral tokens
        // that will be used for the reserve pool
        //                                          slot
        uint256 collateralTokenBalance; //              256
        //                                          slot
        address priceOracle; //                         160
        //                                          slot
        address feeReceiver; //                         160
        //
        // CollateralRatioConfig
        //                                          slot
        uint32 bonusCollateralRatioUpperBound; //        32
        uint32 rebalanceCollateralRatioUpperBound; //    64
        uint32 safeCollateralRatioLowerBound; //         96
        // FeeConfig
        uint32 safeMintPeggedTokenFeeRatio; //          128
        uint32 safeRedeemPeggedTokenFeeRatio; //        160
        uint32 safeMintLeveragedTokenFeeRatio; //       192
        uint32 safeRedeemLeveragedTokenFeeRatio; //     256
        // BonusConfig
        //                                          slot
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
        CollateralRatioConfig calldata collateralRatioConfig_,
        FeeConfig calldata feeConfig_,
        BonusConfig calldata bonusConfig_
    ) external initializer {
        // initialise all the state variables
        __AccessControl_init();
        __UUPSUpgradeable_init();

        MinterStorage storage $ = _getMinterStorage();
        // balance tokens
        $.collateralToken = tokens_.collateralToken;
        $.peggedToken = tokens_.peggedToken;
        $.leveragedToken = tokens_.leveragedToken;

        $.peggedTokenBalance = 0;

        _updatePriceOracle(priceOracle_);
        _updateFeeReceiver(feeReceiver_);

        _updateCollateralRatioConfig(collateralRatioConfig_);
        _updateFeeConfig(feeConfig_);
        _updateBonusConfig(bonusConfig_);

        _grantRole(DEFAULT_ADMIN_ROLE, owner);
        _grantRole(ZERO_FEE_ROLE, owner);
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
        CollateralRatioConfig calldata collateralRatioConfig_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _updateCollateralRatioConfig(collateralRatioConfig_);
    }

    function _updateCollateralRatioConfig(CollateralRatioConfig calldata collateralRatioConfig_) private {
        if (
            collateralRatioConfig_.safeCollateralRatioLowerBound <
            collateralRatioConfig_.rebalanceCollateralRatioUpperBound
        ) {
            revert InvalidCollateralRatioConfig(
                collateralRatioConfig_.rebalanceCollateralRatioUpperBound,
                collateralRatioConfig_.safeCollateralRatioLowerBound
            );
        }
        if (
            collateralRatioConfig_.rebalanceCollateralRatioUpperBound <
            collateralRatioConfig_.bonusCollateralRatioUpperBound
        ) {
            revert InvalidCollateralRatioConfig(
                collateralRatioConfig_.bonusCollateralRatioUpperBound,
                collateralRatioConfig_.rebalanceCollateralRatioUpperBound
            );
        }
        MinterStorage storage $ = _getMinterStorage();
        $.bonusCollateralRatioUpperBound = _etherRatio(collateralRatioConfig_.bonusCollateralRatioUpperBound);
        $.rebalanceCollateralRatioUpperBound = _etherRatio(collateralRatioConfig_.rebalanceCollateralRatioUpperBound);
        $.safeCollateralRatioLowerBound = _etherRatio(collateralRatioConfig_.safeCollateralRatioLowerBound);
        emit UpdateCollateralRatioConfig(collateralRatioConfig_);
    }

    function updateFeeConfig(FeeConfig calldata feeConfig_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _updateFeeConfig(feeConfig_);
    }

    function _updateFeeConfig(FeeConfig calldata feeConfig_) private {
        MinterStorage storage $ = _getMinterStorage();
        $.safeMintPeggedTokenFeeRatio = _etherRatio(feeConfig_.safeMintPeggedTokenFeeRatio);
        $.safeRedeemPeggedTokenFeeRatio = _etherRatio(feeConfig_.safeRedeemPeggedTokenFeeRatio);
        $.safeMintLeveragedTokenFeeRatio = _etherRatio(feeConfig_.safeMintLeveragedTokenFeeRatio);
        $.safeRedeemLeveragedTokenFeeRatio = _etherRatio(feeConfig_.safeRedeemLeveragedTokenFeeRatio);
        emit UpdateFeeConfig(feeConfig_);
    }

    function updateBonusConfig(BonusConfig calldata bonusConfig_) external onlyRole(DEFAULT_ADMIN_ROLE) {
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
        uint256 newPeggedToken = (collateralIn * price) / 1 ether;

        uint256 feeRatio = _mintPeggedTokenFeeRatio(
            _collateralRatio($.collateralTokenBalance + collateralIn, price, $.peggedTokenBalance + newPeggedToken),
            $.rebalanceCollateralRatioUpperBound,
            $.safeCollateralRatioLowerBound,
            $.safeMintPeggedTokenFeeRatio
        );

        uint256 fee = (collateralIn * feeRatio) / 1 ether;
        collateralIn -= fee;

        // recalculate the amounts involved
        peggedTokenOut = (collateralIn * price) / 1 ether;
        if (peggedTokenOut < minPeggedTokenOut) {
            revert InsufficientOutput($.peggedToken, minPeggedTokenOut, peggedTokenOut);
        }
        IERC20(collateralToken_).safeTransferFrom(_msgSender(), $.feeReceiver, fee);
        _mintPeggedToken(collateralToken_, collateralIn, $.peggedToken, peggedTokenOut, recipient, fee);
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
        uint256 collateralIn,
        address peggedToken_,
        uint256 peggedTokenOut,
        address recipient,
        uint256 fees // only for the emit
    ) private {
        // slither-disable-next-line incorrect-equality
        if (collateralIn == 0) {
            revert MintZeroAmount();
        }
        emit MintPeggedToken(_msgSender(), recipient, collateralIn, peggedTokenOut, fees);

        // mint the tokens to the recipient
        IMintable(peggedToken_).mint(recipient, peggedTokenOut);
        // take the collateral
        IERC20(collateralToken_).safeTransferFrom(_msgSender(), address(this), collateralIn);

        // update our records
        MinterStorage storage $ = _getMinterStorage();
        $.peggedTokenBalance += peggedTokenOut;
        $.collateralTokenBalance += collateralIn;
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
        uint256 leveragedPrice = _leveragedTokenNAV(
            $.leveragedTokenBalance,
            $.peggedTokenBalance,
            $.collateralTokenBalance,
            price
        );
        uint256 currentCollateralRatio = _collateralRatio($.collateralTokenBalance, price, $.peggedTokenBalance);

        uint256 feeRatio = _mintLeveragedTokenFeeRatio(
            currentCollateralRatio,
            $.rebalanceCollateralRatioUpperBound,
            $.safeCollateralRatioLowerBound,
            $.safeMintPeggedTokenFeeRatio
        );

        uint256 fee = (collateralIn * feeRatio) / 1 ether;
        collateralIn -= fee;
        bonusOut = 0;
        // TODO: add the rebalance pool balance
        if (fee == 0 && currentCollateralRatio < $.bonusCollateralRatioUpperBound) {
            // TODO: add the bonus here (if rebalance pools are exhausted)
        }

        // recalculate the amounts involved
        leveragedTokenOut = (collateralIn * price) / leveragedPrice;
        if (leveragedTokenOut < minLeveragedTokenOut) {
            revert InsufficientOutput($.leveragedToken, minLeveragedTokenOut, leveragedTokenOut);
        }
        IERC20(collateralToken_).safeTransferFrom(_msgSender(), $.feeReceiver, fee);
        _mintLeveragedToken(
            collateralToken_,
            collateralIn,
            $.leveragedToken,
            leveragedTokenOut,
            recipient,
            fee,
            bonusOut
        );
    }

    // @inheritdoc IMinter
    function freeMintLegeragedToken(
        uint256 collateralIn,
        address recipient
    ) external onlyRole(ZERO_FEE_ROLE) returns (uint256 leveragedTokenOut) {
        MinterStorage storage $ = _getMinterStorage();
        // how much collateral to use
        address collateralToken_ = $.collateralToken;
        collateralIn = _allOf(_msgSender(), collateralToken_, collateralIn);
        IERC20(collateralToken_).safeTransferFrom(_msgSender(), address(this), collateralIn);

        // // mint the tokens to the recipient
        uint256 price = _fetchSafePrice($.priceOracle);
        uint256 leveragedPrice = _leveragedTokenNAV(
            $.leveragedTokenBalance,
            $.peggedTokenBalance,
            $.collateralTokenBalance,
            price
        );
        leveragedTokenOut = (collateralIn * price) / leveragedPrice;

        _mintLeveragedToken(collateralToken_, collateralIn, $.leveragedToken, leveragedTokenOut, recipient, 0, 0);
    }

    function _mintLeveragedToken(
        address collateralToken_,
        uint256 collateralIn,
        address leveragedToken_,
        uint256 leveragedTokenOut,
        address recipient,
        uint256 fees, // only for the emit
        uint256 bonus // only for the emit
    ) private {
        // slither-disable-next-line incorrect-equality
        if (collateralIn == 0) {
            revert MintZeroAmount();
        }
        // tell the world
        emit MintLeveragedToken(_msgSender(), recipient, collateralIn, leveragedTokenOut, fees, bonus);

        // mint the tokens to the recipient
        IMintable(leveragedToken_).mint(recipient, leveragedTokenOut);
        // take the collateral
        IERC20(collateralToken_).safeTransferFrom(_msgSender(), address(this), collateralIn);

        // update our records
        MinterStorage storage $ = _getMinterStorage();
        $.leveragedTokenBalance += leveragedTokenOut;
        $.collateralTokenBalance += collateralIn;
    }

    /// @inheritdoc IMinter
    function redeemPeggedToken(
        uint256 peggedTokenIn,
        address recipient,
        uint256 minCollateralOut
    ) external override returns (uint256 collateralOut, uint256 bonus) {
        // TODO: add a bonus here
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
            revert ZeroBalance();
        }
    }

    // -------------------------
    // Fee calculation functions
    // -------------------------

    function mintPeggedTokenFeeRatio(uint256 additionalCollateral) external view override returns (uint256 fees) {
        // get the collateral ratio
        MinterStorage storage $ = _getMinterStorage();
        uint256 price = _fetchSafePrice($.priceOracle);
        uint256 newPeggedToken = (additionalCollateral * price) / 1 ether;

        fees = _mintPeggedTokenFeeRatio(
            _collateralRatio(
                $.collateralTokenBalance + additionalCollateral,
                price,
                $.peggedTokenBalance + newPeggedToken
            ),
            $.rebalanceCollateralRatioUpperBound,
            $.safeCollateralRatioLowerBound,
            $.safeMintPeggedTokenFeeRatio
        );
    }

    function redeemPeggedTokenFeeRatio() external view override returns (uint256 fees) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 price = _fetchSafePrice($.priceOracle);
        fees = _redeemPeggedTokenFeeRatio(
            _collateralRatio($.collateralTokenBalance, price, $.peggedTokenBalance),
            $.rebalanceCollateralRatioUpperBound,
            $.safeCollateralRatioLowerBound,
            $.safeRedeemPeggedTokenFeeRatio
        );
    }

    // TODO: should be fees lower/bonus higher for higher leveraged token redeem amount
    function mintLeveragedTokenFeeRatio() external view override returns (uint256 fees) {
        MinterStorage storage $ = _getMinterStorage();
        // TODO: do we need safe price for this?
        uint256 price = _fetchSafePrice($.priceOracle);
        fees = _mintLeveragedTokenFeeRatio(
            _collateralRatio($.collateralTokenBalance, price, $.peggedTokenBalance),
            $.rebalanceCollateralRatioUpperBound,
            $.safeCollateralRatioLowerBound,
            $.safeMintLeveragedTokenFeeRatio
        );
    }

    function redeemLeveragedTokenFeeRatio(uint256 reductionOfcollateral) external view override returns (uint256 fees) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 price = _fetchSafePrice($.priceOracle);
        uint256 collateralTokenBalance = $.collateralTokenBalance;
        // TODO: make sure there wont be a subtaction underflow
        fees = _redeemLeveragedTokenFeeRatio(
            _collateralRatio(collateralTokenBalance - reductionOfcollateral, price, $.peggedTokenBalance),
            $.rebalanceCollateralRatioUpperBound,
            $.safeCollateralRatioLowerBound,
            $.safeRedeemLeveragedTokenFeeRatio
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

    // all fees are calculated based on the collateral ratio after the action has been performed
    function _mintPeggedTokenFeeRatio(
        uint256 atCollateralRatio,
        uint32 rebalanceCollateralRatioUpperBound,
        uint32 safeCollateralRatioLowerBound,
        uint32 safeMintPeggedTokenFeeRatio
    ) private pure returns (uint256 fees) {
        uint256 smoothstep = _smoothstep(
            atCollateralRatio,
            _ratioEther(rebalanceCollateralRatioUpperBound),
            _ratioEther(safeCollateralRatioLowerBound)
        );
        // adjustment for turning it upside down and having a minimum fee
        fees = 1 ether - ((1 ether - _ratioEther(safeMintPeggedTokenFeeRatio)) * smoothstep) / 1 ether;
    }

    function _redeemPeggedTokenFeeRatio(
        uint256 atCollateralRatio,
        uint32 rebalanceCollateralRatioUpperBound,
        uint32 safeCollateralRatioLowerBound,
        uint32 safeRedeemPeggedTokenFeeRatio
    ) private pure returns (uint256 fees) {
        uint256 smoothstep = _smoothstep(
            atCollateralRatio,
            _ratioEther(rebalanceCollateralRatioUpperBound),
            _ratioEther(safeCollateralRatioLowerBound)
        );
        // adjustment for fee
        fees = (_ratioEther(safeRedeemPeggedTokenFeeRatio) * smoothstep) / 1 ether;
    }

    function _mintLeveragedTokenFeeRatio(
        uint256 atCollateralRatio,
        uint32 rebalanceCollateralRatioUpperBound,
        uint32 safeCollateralRatioLowerBound,
        uint32 safeMintLeveragedTokenFeeRatio
    ) private pure returns (uint256 fees) {
        uint256 smoothstep = _smoothstep(
            atCollateralRatio,
            _ratioEther(rebalanceCollateralRatioUpperBound),
            _ratioEther(safeCollateralRatioLowerBound)
        );
        // adjustment for turning it upside down and having a minimum fee
        fees = (_ratioEther(safeMintLeveragedTokenFeeRatio) * smoothstep) / 1 ether;
    }

    function _redeemLeveragedTokenFeeRatio(
        uint256 atCollateralRatio,
        uint32 rebalanceCollateralRatioUpperBound,
        uint32 safeCollateralRatioLowerBound,
        uint32 safeRedeemLeveragedTokenFeeRatio
    ) private pure returns (uint256 fees) {
        uint256 smoothstep = _smoothstep(
            atCollateralRatio,
            _ratioEther(rebalanceCollateralRatioUpperBound),
            _ratioEther(safeCollateralRatioLowerBound)
        );
        // adjustment for fee
        fees = 1 ether - ((1 ether - _ratioEther(safeRedeemLeveragedTokenFeeRatio)) * smoothstep) / 1 ether;
    }

    // other calculations
    // ------------------

    function leveragedTokenNAV() external view override returns (uint256 nav) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 leveragedTokenBalance = IERC20($.leveragedToken).balanceOf(address(this));
        uint256 price = _fetchSafePrice($.priceOracle);
        nav = _leveragedTokenNAV(leveragedTokenBalance, $.peggedTokenBalance, $.collateralTokenBalance, price);
    }

    function _leveragedTokenNAV(
        uint256 leveragedTokenBalance,
        uint256 peggedTokenBalance_,
        uint256 collateralTokenBalance,
        uint256 collateralPrice
    ) private pure returns (uint256 nav) {
        // TODO if the collateral ratio is 0, nav is 0 - check that this doesn't just work out
        // slither-disable-next-line incorrect-equality
        if (leveragedTokenBalance == 0) {
            nav = 1 ether;
        } else {
            // TODO: is this the right price?
            uint256 collateralValue = (collateralTokenBalance * collateralPrice) / 1 ether;
            if (collateralValue <= peggedTokenBalance_) {
                // this is where the invariant is, err, variant in that the leveraged value should have gone negative
                // this essentially means that the pegged token is, err, no longer pegged
                // - at least those pegged tokens that are backed by this colllateral
                // TODO: find some way of managing BaoUSD's depegging such that all collateral is taken into account
                // to work out it's NAV given the total supply of pegged = value of the total collateral
                nav = 0;
            } else {
                // this is the invariant collateral value  = pegged value + leveraged value
                nav = (collateralValue - peggedTokenBalance_) / leveragedTokenBalance;
            }
        }
    }

    /// @notice Return the current collateral ratio of the peggedToken to the collateral token, multipled by 1e18.
    function collateralRatio() external view override returns (uint256) {
        MinterStorage storage $ = _getMinterStorage();
        return _collateralRatio($.collateralTokenBalance, _fetchSafePrice($.priceOracle), $.peggedTokenBalance);
    }

    function _collateralRatio(
        uint256 collateralTokenBalance,
        uint256 collateralPrice,
        uint256 peggedTokenBalance_
    ) private pure returns (uint256 collateralRatio_) {
        collateralRatio_ = (collateralTokenBalance * collateralPrice) / peggedTokenBalance_;
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
