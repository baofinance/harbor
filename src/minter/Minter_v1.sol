// SPDX-License-Identifier: MIT
// coding standards by https://www.rareskills.io/post/solidity-style-guide
// and https://docs.soliditylang.org/en/latest/style-guide.html
pragma solidity 0.8.25;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import { WordCodec } from "src/common/WordCodec.sol";
import { Token } from "src/common/Token.sol";
import { AccessControl } from "src/common/TokenOwner.sol";

import { IMinter, IMinterTreasury } from "src/minter/IMinter.sol";
import { IMintable, IBurnable, IBurnableFrom } from "src/minter/IMintable.sol";
import { IPriceOracle } from "src/price/IPriceOracle.sol";
import { IReservePool } from "src/minter/IReservePool.sol";

import "forge-std/console.sol";

/// @title
/// @author
/// @notice provides an interface for minting and redeeming pegged and leveraged tokens
/// There are two interfaces, one anyone can call
///     here fees are charged and discounts given depending on the starting and ending collateral ratios,
///     and the configured fee/discount levels
/// one protected for special use
///     here there are no fees nor discounts
/// also provides the net asset values and leverage ratio of the leveraged tokens
/// @dev uses UUPS proxy, erc7201 storage

/// @custom:oz-upgrades
contract Minter_v1 is Initializable, UUPSUpgradeable, AccessControl, ReentrancyGuard, IMinter, IMinterTreasury {
    using SafeERC20 for IERC20;
    using WordCodec for bytes32;

    // collateral ratio bounds are stored as uint32, which allows for a maximum value of ~4 billion
    // with decimals = 6, this gives a max ratio of 4,000 (400,000%) with precision of 0.000001 (0.0001%),
    // e.g. 130.55% is easily catered for
    // this allow 8 of these to be stored in a slot. As we need 5, we need a whole slot
    uint private constant COLLATERAL_RATIO_DECIMALS = 6;

    // fee & bonus ratios are stored as int32, which allows for -2 billion to 2 billion
    // with decimals = 9, this gives a max ratio of 2 (200%) with precision of 0.000000001 (0.0000001%),
    // these ratios must be in the range [-1, 1] [-100%, 100%]
    // this allow 8 of these to be stored in a slot. As we need 6, we need a whole slot
    uint private constant INCENTIVE_RATIO_DECIMALS = 9;

    uint private constant maxBands = 6;
    uint private constant maxBounds = maxBands - 1;

    // we use astruct here but implement our own storage because solidity uses too many slots
    struct ActionIncentive {
        bytes32 slot0;
        // we store the disallow bound as the first uint32
        // uint32[maxBounds] collateralRatioUpperBounds;      0:192
        // uint32 collateralRatioBandCount;                 192: 32
        bytes32 slot1;
        // int32[maxBands] incentiveRatios;                   0:192
    }

    function _collateralRatioUpperBounds(ActionIncentive memory config, uint index) private pure returns (uint256) {
        return config.slot0.decodeUint(index * 32, 32) * 10 ** (18 - COLLATERAL_RATIO_DECIMALS);
    }
    function _setCollateralRatioUpperBounds(ActionIncentive memory config, uint index, uint256 value) private pure {
        config.slot0 = config.slot0.insertUint(value / 10 ** (18 - COLLATERAL_RATIO_DECIMALS), index * 32, 32);
    }
    function collateralRatioBandCount(ActionIncentive memory config) private pure returns (uint) {
        return config.slot0.decodeUint(160, 32);
    }
    function setCollateralRatioBandCount(ActionIncentive memory config, uint value) private pure {
        config.slot0 = config.slot0.insertUint(value, 160, 32);
    }
    function _incentiveRatio(ActionIncentive memory config, uint index) private pure returns (int256) {
        return config.slot1.decodeInt(index * 32, 32) * int256(10 ** (18 - INCENTIVE_RATIO_DECIMALS));
    }

    function _setIncentiveRatio(ActionIncentive memory config, uint index, int256 value) private pure {
        config.slot1 = config.slot1.insertInt(value / int256(10 ** (18 - INCENTIVE_RATIO_DECIMALS)), index * 32, 32);
    }

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
        //                                             slot
        address reservePool; //                         160
        // token balances: can't rely on balanceOf(address(this)) for key values
        // pegged token balance - we have to track pegged tokens
        // because we possibly are not the only minters of these pegged tokens
        // we are not likely to use these tokens as bonus because during a bonus period pegged minting
        // will not be allowed
        //                                             slot
        // we keep track of pegged tokens and collateral tokens because they both have a life
        // outside of this system. Leverage tokens, however, only exist in the context of this system
        // so we use their totalSupply number instead.
        // this should be tracked by the pegged token itself, recording how much is minted/redeemed by each minter
        uint256 peggedTokenBalance; //                  256
        //                                             slot
        // uint256 leveragedTokenBalance; //               256
        // collateralTokenBalance - we track this here because this contract can also own collateral tokens
        // that will be used for the reserve pool
        // TODO: do we want a collateral cap?
        // it's just the ownership of collateralTokens
        // so: reserve pool is a separate contract
        //                                             slot
        //uint256 collateralTokenBalance; //              256
        //                                             slot
        address priceOracle; //                         160
        //                                             slot
        address feeReceiver; //                         160
        //                                              slot*2
        uint256 rebalanceCollateralRatioUpperBound; // the upper collateral ratio at which rebalancing begins
        uint256 normalCollateralRatioUpperBound; // above this harvesting of collateral can begin
        //                                             slot*2
        ActionIncentive mintPeggedConfig;
        //                                             slot*2
        ActionIncentive redeemPeggedConfig;
        //                                             slot*2
        ActionIncentive mintLeveragedConfig;
        //                                             slot*2
        ActionIncentive redeemLeveragedConfig;
        //                                             slot
        address bonusToken; //                          160
    }

    // keccak256(abi.encode(uint256(keccak256("bao.storage.Minter")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant MINTER_STORAGE = 0x92e73fe9557052b4a0b810a38eb7ef595ff750f166ca39d63b3f4c74937fef00;

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
        address reservePool_,
        Config calldata config_
    ) external initializer {
        // initialise all the state variables
        __AccessControl_init(owner);
        __UUPSUpgradeable_init();

        MinterStorage storage $ = _getMinterStorage();
        // balance tokens
        Token.ensureERC20Token(tokens_.collateralToken);
        Token.ensureERC20Token(tokens_.peggedToken);
        Token.ensureERC20Token(tokens_.leveragedToken);

        $.collateralToken = tokens_.collateralToken;
        $.peggedToken = tokens_.peggedToken;
        $.peggedTokenBalance = 0;
        $.leveragedToken = tokens_.leveragedToken;

        _updatePriceOracle(priceOracle_);
        _updateFeeReceiver(feeReceiver_);
        _updateReservePool(reservePool_);
        _updateConfig(config_);
        // wake-disable-next-line unchecked-return-value
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

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(IMinter).interfaceId ||
            interfaceId == type(IMinterTreasury).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    // Updater functions
    // -----------------

    function updateConfig(Config calldata config) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _updateConfig(config);
    }

    function _copyBands(
        IncentiveConfig calldata config,
        uint256 disallowCollateralRatioUpperBound_
    ) private pure returns (ActionIncentive memory out) {
        if (config.collateralRatioBandUpperBounds.length > maxBounds) {
            revert TooManyCollateralRatioBounds(config.collateralRatioBandUpperBounds.length);
        }
        if (config.incentiveRatios.length > maxBands) {
            revert TooManyIncentiveRatios(config.incentiveRatios.length);
        }
        if (config.incentiveRatios.length != config.collateralRatioBandUpperBounds.length + 1) {
            revert CollateralRatioBoundsIncentivesLengthsMismatch(
                config.collateralRatioBandUpperBounds.length,
                config.incentiveRatios.length
            );
        }

        uint offset = 0;
        if (disallowCollateralRatioUpperBound_ != 0) {
            offset = 1;
            _setCollateralRatioUpperBounds(out, 0, disallowCollateralRatioUpperBound_);
            _setIncentiveRatio(out, 0, 0); // disallow carries a 0 fee
        }
        setCollateralRatioBandCount(out, config.incentiveRatios.length + offset);

        // check monotonically increasing, and greater than disallow ratio, and then copy
        uint256 min = 0;
        for (uint i = 0; i < config.collateralRatioBandUpperBounds.length; i++) {
            uint256 value = config.collateralRatioBandUpperBounds[i];
            // disallow must be at a lower collateral ratio than any fee boundary (or the fee boundary is ignored!)
            if (i == 0 && value <= disallowCollateralRatioUpperBound_) {
                revert InvalidCollateralRatioBoundValue(value, disallowCollateralRatioUpperBound_);
            }
            // must be monotonically increasing
            if (value < min) {
                revert InvalidCollateralRatioBoundValue(value, min);
            }
            min = value;
            _setCollateralRatioUpperBounds(out, i + offset, value);
            //clog("  upper bounds", i, value);
        }
        // check in range [-1, 1] and copy
        for (uint i = 0; i < config.incentiveRatios.length; i++) {
            int256 value = config.incentiveRatios[i];
            if (value > 1 ether || value < -1 ether) {
                revert InvalidIncentiveRatioValue(value);
            }
            // also any bonus ratio cannot be in the highest collateral band
            if (i == config.incentiveRatios.length && value < 0) {
                revert InvalidIncentiveRatioValue(value);
            }
            _setIncentiveRatio(out, i + offset, value);
            //clog("  incentive ratio", i, value);
        }
    }

    function _updateConfig(Config calldata config) private {
        // TODO: check rebalance pools are exhausted before discounts are handed out?
        // or is this handled by the fact that the CR for discount is much lower than the rebalance CR

        MinterStorage storage $ = _getMinterStorage();

        // action config
        // TODO: consider making those 32 bit
        $.rebalanceCollateralRatioUpperBound = config.rebalanceCollateralRatioUpperBound;
        $.normalCollateralRatioUpperBound = config.normalCollateralRatioUpperBound;
        // clog("rebalanceCollateralRatioUpperBound", $.rebalanceCollateralRatioUpperBound);
        // clog("normalCollateralRatioUpperBound", $.normalCollateralRatioUpperBound);

        // incentive config
        // clog("mintPeggedConfig:");
        $.mintPeggedConfig = _copyBands(
            config.mintPeggedIncentiveConfig,
            config.disallowMintPeggedCollateralRatioUpperBound
        );
        // clog("mintLeveragedConfig:");
        $.mintLeveragedConfig = _copyBands(config.mintLeveragedIncentiveConfig, 0);
        // clog("redeemPeggedConfig:");
        $.redeemPeggedConfig = _copyBands(config.redeemPeggedIncentiveConfig, 0);
        // clog("redeemLeveragedConfig:");
        $.redeemLeveragedConfig = _copyBands(
            config.redeemLeveragedIncentiveConfig,
            config.disallowRedeemLeveragedCollateralRatioUpperBound
        );

        emit UpdateConfig(config);
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

    function updateFeeReceiver(address feeReceiver_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _updateFeeReceiver(feeReceiver_);
    }

    function _updateFeeReceiver(address feeReceiver_) private {
        MinterStorage storage $ = _getMinterStorage();
        address old = $.feeReceiver;
        $.feeReceiver = feeReceiver_;
        emit UpdateFeeReceiver(old, feeReceiver_);
    }

    function updateReservePool(address reservePool_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _updateReservePool(reservePool_);
    }

    function _updateReservePool(address reservePool_) private {
        MinterStorage storage $ = _getMinterStorage();
        address old = $.reservePool;
        $.reservePool = reservePool_;
        emit UpdateReservePool(old, reservePool_);
    }

    // Mint/Redeem Pegged/Leveraged functions
    // --------------------------------------

    /// @inheritdoc IMinter
    function mintPeggedToken(
        uint256 collateralIn,
        address recipient,
        uint256 minPeggedTokenOut
    ) external override nonReentrant returns (uint256 peggedTokenOut) {
        MinterStorage storage $ = _getMinterStorage();
        // work out how much collateral to use
        address collateralToken_ = $.collateralToken;
        collateralIn = Token.allOf(_msgSender(), collateralToken_, collateralIn);

        uint256 price = _fetchSafePrice($.priceOracle);
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        uint256 collateralTokenBalance_ = _collateralTokenBalance(collateralToken_);

        // fee calculation
        uint256 fee;
        (fee, collateralIn) = _mintPeggedAdjustments(
            $.mintPeggedConfig,
            collateralIn,
            collateralTokenBalance_,
            price,
            peggedTokenBalance_
        );
        // TODO: handle bonuses?

        address peggedToken_ = $.peggedToken;
        if (collateralIn == 0) revert MintZeroAmount(peggedToken_);

        // recalculate the amounts involved
        peggedTokenOut = ((collateralIn - fee) * price) / 1 ether;

        if (peggedTokenOut < minPeggedTokenOut) {
            revert MintInsufficientAmount(peggedToken_, minPeggedTokenOut, peggedTokenOut);
        }

        _mintPeggedToken(collateralToken_, collateralIn, peggedToken_, peggedTokenOut, recipient);

        IERC20(collateralToken_).safeTransfer($.feeReceiver, fee);

        // update our records
        $.peggedTokenBalance = peggedTokenBalance_ + peggedTokenOut;
    }

    /*
    function _proRatedRatio(
        uint256 lowerCollateralRatio,
        uint256 upperCollateralRatio,
        ActionIncentive memory config
    ) private pure returns (int256 incentiveRatio) {
        incentiveRatio = 0;
        // find the index, l, where lowerCollateralRatio falls
        uint l;
        // console.log("      collateralRatioBandCount - 1=%s", collateralRatioBandCount(config) - 1);
        for (l = 0; l < collateralRatioBandCount(config) - 1; l++) {
            if (lowerCollateralRatio <= _collateralRatioUpperBounds(config, l)) {
                // console.log(
                //     "      lowerCollateralRatio=%s, collateralRatioUpperBounds[%s]=%s",
                //     lowerCollateralRatio,
                //     l,
                //     _collateralRatioUpperBounds(config, l)
                // );
                break;
            }
        }
        // find the index, u, where upperCollateralRatio falls
        uint u;
        for (u = l; u < collateralRatioBandCount(config) - 1; u++) {
            if (upperCollateralRatio <= _collateralRatioUpperBounds(config, u)) {
                // console.log(
                //     "      upperCollateralRatio=%s, collateralRatioUpperBounds[%s]=%s",
                //     lowerCollateralRatio,
                //     u,
                //     _collateralRatioToEther(collateralRatioUpperBounds[u])
                // );
                break;
            }
        }

        // Calculate pro-rated fee
        if (l == u) {
            incentiveRatio = _incentiveRatio(config, l);
            // console.log("      incentiveRatio=%s, u=l=%s", uint256(incentiveRatio), l);
        } else {
            // Calculate pro-rated fee for the portion of lowerCollateralRatio in band l
            incentiveRatio = (int256(_collateralRatioUpperBounds(config, l) - lowerCollateralRatio + 1) *
                _incentiveRatio(config, l));
            // console.log("     incentiveRatioeRatio=%s, l=%s", uint256(incentiveRatio), l);

            // Calculate pro-rated fee for the full intervals between l and u
            for (uint256 k = l + 1; k < u; k++) {
                incentiveRatio += (int256(_collateralRatioUpperBounds(config, k) - _collateralRatioUpperBounds(config, k + 1)) *
                    _incentiveRatio(config, k));
                // console.log("      incentiveRatio=%s, k=%s", uint256(incentiveRatio), l);
            }

            // Calculate pro-rated fee for the portion of upperCollateralRatio in band u
            incentiveRatio += (int256(upperCollateralRatio - _collateralRatioUpperBounds(config, u - 1)) *
                _incentiveRatio(config, u));
            // console.log("      incentiveRatio=%s, u=%s", uint256(incentiveRatio), l);
            incentiveRatio /= int256(upperCollateralRatio - lowerCollateralRatio); // Normalize fee based on range
            // console.log("      incentiveRatio=%s", uint256(incentiveRatio));
        }
    }
    */

    /*
        simulate minting or redeeming tokens from current collateral ratio upwards or downwards,
        extracting the fee at the correct ratio as we go.
        We do this band at a time, pro-rating the resulting fee according to how much collateral was needed in
        each band entered. We use collateral to pro-rate, rather than collateral ration which would be simpler, because
        we multiply the resulting ratios by the collateral for the final fee

   */

    /**
     * @notice calculates the fee or bonuses relating to the different incentiveRatios
     * It calculates the proportion, in collateral space, the transition from one collateral ratio boundary to another
     * and performs a weighted sum of the fee ratios. It essentially performs a definite integral of the fee function.
     * @param config is the collateral ratio boundaries and the fee ratios within each boundary
     * @param collateralIn the proposed amount of collateral being posted in exchange for pegged tokens
     * @param price the value of a collateral token in terms of the pegged token.
     * @param collateralTokenBalance_ is the amount of collateral held. This is used to calculate collateral ratios
     * @param peggedTokenBalance_ is the amount of pegged tokens issued. This is used to calculate collateral ratios
     * @return fee the pro-rated fee
     * @return maxCollateral the amount of collateral that is allowed, according to the config
     */
    function _mintPeggedAdjustments(
        ActionIncentive memory config,
        uint256 collateralIn,
        uint256 collateralTokenBalance_,
        uint256 price,
        uint256 peggedTokenBalance_
    ) private pure returns (uint256 fee, uint256 maxCollateral) {
        // we cannot calculate collateral ratio when there are no pegged tokens as it's infinite i.e. (/0)
        if (peggedTokenBalance_ == 0) revert ActionPaused();

        // find the band and it's lower bound where the current collateral ratio is
        // (note we treat the disallow band as any other here, except that it is the terminal band)
        (uint band, uint256 bandLowerBound) = _findBandAndLowerBound(
            config,
            collateralTokenBalance_,
            price,
            peggedTokenBalance_
        );
        if (band == 0) {
            // in disallow band for mint pegged or redeem leveraged
            return (0, 0);
        }
        // simulate minting until we run out of collateral, adding the fee & bonus as we go
        while (true) {
            uint256 bandFeeRatio = uint256(SignedMath.max(_incentiveRatio(config, band), 0));
            uint256 collateralInBand = ((collateralTokenBalance_ * price - bandLowerBound * peggedTokenBalance_) *
                1 ether) / (price * ((bandLowerBound * (1 ether - bandFeeRatio)) / 1 ether - 1 ether + bandFeeRatio));

            collateralInBand = Math.min(collateralIn, collateralInBand);
            uint256 bandFee = (collateralInBand * bandFeeRatio) / 1 ether;
            maxCollateral += collateralInBand;
            fee += bandFee;
            collateralIn -= collateralInBand;
            if (collateralIn == 0 || band == 1) {
                // we have either:
                //      run out of collateral
                // or:
                //      arrived in the lowest band and we have more collateral than the band allows
                //      so all we can use is the collateral in the band as the rest is disallowed
                return (fee, maxCollateral);
            }
            // still some collateral left and we're allowed to mint or redeem, so simulate
            collateralTokenBalance_ += collateralInBand - bandFee;
            peggedTokenBalance_ += ((collateralInBand - bandFee) * price) / 1 ether;

            band--;
            bandLowerBound = _collateralRatioUpperBounds(config, band - 1);
        }
    }

    /*
     * @dev formula derived by taking the collateral ratio formula an backing out the collateral needed
     * fees are deducted beforehand, thus applying to both the collateral token and pegged token balances
     * this function can be used to calcuilate
     * 1) piecewise pro-rated fee ratios for multiple fee zones
     * 2) the disallowed collateral amount given a disallow collateral ratio and a calculated fee ratio
     * @param targetCollateralRatio the collateral ratio we aim to get to, with the returned collateral tokens
     * @param collateralTokenBalance_ the collateral token balance of the minter
     * @param price the price of the collateral in pegged token units
     * @param peggedTokenBalance_  the pegged tokend minted by the minter
     * @param incentiveRatio  the singular fee ratio applied between the current collateral ratio (given by the parameters)
     */
    // function _collateralTokensForCollateralRatio(
    //     uint256 targetCollateralRatio,
    //     uint256 collateralTokenBalance_,
    //     uint256 price,
    //     uint256 peggedTokenBalance_,
    //     // TODO: make this a uint256 and ignre all negative fees
    //     int256 incentiveRatio
    // ) private pure returns (uint256 collateralTokens) {
    //     // console.log("      targetCollateralRatio=%s", targetCollateralRatio);
    //     // console.log("      collateralTokenBalance_=%s", collateralTokenBalance_);
    //     // console.log("      price=%s", price);
    //     // console.log("      peggedTokenBalance_=%s", peggedTokenBalance_);
    //     // console.log("      incentiveRatio=%s", uint256(incentiveRatio));

    //     collateralTokens =
    //         ((collateralTokenBalance_ * price - targetCollateralRatio * peggedTokenBalance_) * 1 ether) /
    //         uint256(
    //             int256(price) * ((int256(targetCollateralRatio) * (1 ether - incentiveRatio)) / 1 ether - 1 ether + incentiveRatio)
    //         );
    //     // console.log("      collateralTokens=%s", collateralTokens);
    // }

    function freeMintPeggedToken(
        uint256 collateralIn,
        address recipient
    ) external override onlyRole(ZERO_FEE_ROLE) nonReentrant returns (uint256 peggedTokenOut) {
        MinterStorage storage $ = _getMinterStorage();
        // how much collateral to use
        address collateralToken_ = $.collateralToken;
        collateralIn = Token.allOf(_msgSender(), collateralToken_, collateralIn);

        // transfer and mint
        uint256 price = _fetchSafePrice($.priceOracle);
        peggedTokenOut = (collateralIn * price) / 1 ether;
        _mintPeggedToken(collateralToken_, collateralIn, $.peggedToken, peggedTokenOut, recipient);

        // update our records
        $.peggedTokenBalance += peggedTokenOut;
    }

    function _mintPeggedToken(
        address collateralToken_,
        uint256 collateralIn,
        address peggedToken_,
        uint256 peggedTokenOut,
        address recipient
    ) private {
        emit MintPeggedToken(_msgSender(), recipient, collateralIn, peggedTokenOut);

        // mint the tokens to the recipient
        // as all callers to this function have nonReentrant guard
        // wake-disable-next-line reentrancy
        IMintable(peggedToken_).mint(recipient, peggedTokenOut);
        // take the collateral
        IERC20(collateralToken_).safeTransferFrom(_msgSender(), address(this), collateralIn);
    }

    /**
     * @dev never returns a non-positive amountOut. reverts instead
     * @return amountOut the peggedIn or peggedTokenBalance whatever is the smaller
     */
    function _redeemable(
        address token_,
        uint256 amountIn,
        uint256 tokenBalance_
    ) private pure returns (uint256 amountOut) {
        amountOut = Math.min(amountIn, tokenBalance_);
        // slither-disable-next-line incorrect-equality
        if (amountOut == 0) {
            revert NoRedeemableTokens(token_);
        }
    }

    /// @inheritdoc IMinter
    function redeemPeggedToken(
        uint256 peggedIn,
        address recipient,
        uint256 minCollateralOut
    ) external override nonReentrant returns (uint256 collateralOut) {
        MinterStorage storage $ = _getMinterStorage();
        address collateralToken_ = $.collateralToken;
        address peggedToken_ = $.peggedToken;
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        peggedIn = Token.allOf(_msgSender(), peggedToken_, peggedIn);
        peggedIn = _redeemable(peggedToken_, peggedIn, peggedTokenBalance_);

        uint256 price = _fetchMaxPrice($.priceOracle);

        // the equivalent collateral for the pegged tokens
        collateralOut = (peggedIn * 1 ether) / price;

        (uint256 fee, uint256 extraCollateral) = _redeemPeggedAdjustments(
            $.redeemPeggedConfig,
            collateralOut,
            _collateralTokenBalance(collateralToken_),
            price,
            peggedTokenBalance_,
            IERC20(collateralToken_).balanceOf($.reservePool)
        );
        // net out the fee & extra collateral
        if (extraCollateral > 0) {
            // it's a discount
            // collect the extra collateral, if available
            extraCollateral = IReservePool($.reservePool).requestBonus(
                collateralToken_,
                address(this),
                extraCollateral
            );
            collateralOut += extraCollateral;
        }
        collateralOut -= fee;

        // calculate the collateral returned and make sure it meets the minimum requirements
        if (collateralOut < minCollateralOut) {
            revert ReturnInsufficientAmount(collateralToken_, minCollateralOut, collateralOut);
        }

        // redeem pegged tokens and send the remainder of the collateral
        _redeemPeggedToken(peggedToken_, peggedIn, collateralToken_, collateralOut, recipient);

        if (fee > 0) {
            // send the fee
            IERC20(collateralToken_).safeTransfer($.feeReceiver, fee);
        }

        // update our records
        $.peggedTokenBalance = peggedTokenBalance_ - peggedIn;
    }

    // @inheritdoc IMinter
    function freeRedeemPeggedToken(
        uint256 peggedIn,
        address recipient
    ) external override onlyRole(ZERO_FEE_ROLE) returns (uint256 collateralOut) {
        MinterStorage storage $ = _getMinterStorage();
        address collateralToken_ = $.collateralToken;
        address peggedToken_ = $.peggedToken;
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        peggedIn = Token.allOf(_msgSender(), peggedToken_, peggedIn);
        peggedIn = _redeemable(peggedToken_, peggedIn, peggedTokenBalance_);

        uint256 price = _fetchMaxPrice($.priceOracle);
        collateralOut = (peggedIn * 1 ether) / price;

        // burn pegged tokens and send the of the collateral
        _redeemPeggedToken(peggedToken_, peggedIn, collateralToken_, collateralOut, recipient);

        // update our records
        $.peggedTokenBalance = peggedTokenBalance_ - peggedIn;
    }

    function _redeemPeggedToken(
        address peggedToken_,
        uint256 peggedIn,
        address collateralToken_,
        uint256 collateralOut,
        address recipient
    ) private {
        // tell the world
        emit RedeemPeggedToken(_msgSender(), recipient, peggedIn, collateralOut);
        // burn the tokens from the sender - get them first then burn them
        IERC20(peggedToken_).safeTransferFrom(_msgSender(), address(this), peggedIn);
        IBurnable(peggedToken_).burn(peggedIn);
        // return the collateral
        IERC20(collateralToken_).safeTransfer(recipient, collateralOut);
    }

    // TODO: also add a swap function (free and fee'd) that swaps a pegged token for an xtoken, the free one does so to rebalance
    // TODO: actually get rid of the free functions and replace with the swap?

    /// @inheritdoc IMinter
    function mintLeveragedToken(
        uint256 collateralIn,
        address recipient,
        uint256 minLeveragedTokenOut
    ) external override returns (uint256 leveragedTokenOut) {
        MinterStorage storage $ = _getMinterStorage();
        address collateralToken_ = $.collateralToken;
        collateralIn = Token.allOf(_msgSender(), collateralToken_, collateralIn);
        uint256 price = _fetchSafePrice($.priceOracle);

        address leveragedToken_ = $.leveragedToken;

        uint256 collateralTokenBalance_ = _collateralTokenBalance(collateralToken_);
        // uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        (uint256 fee, uint256 extraCollateral) = _mintLeveragedAdjustments(
            $.mintLeveragedConfig,
            collateralIn,
            collateralTokenBalance_,
            price,
            $.peggedTokenBalance,
            IERC20(collateralToken_).balanceOf($.reservePool)
        );
        // net out the fee & extra collateral
        if (extraCollateral > 0) {
            // it's a discount
            // collect the extra collateral, if available
            extraCollateral = IReservePool($.reservePool).requestBonus(
                collateralToken_,
                address(this),
                extraCollateral
            );
        }
        // work out how many leveraged tokens are to be minted (including the discount)
        leveragedTokenOut = _leverageTokensForCollateral(
            collateralIn - fee + extraCollateral,
            _leveragedTokenBalance(leveragedToken_),
            $.peggedTokenBalance,
            collateralTokenBalance_,
            price
        );
        // make sure it meets the minimum requirements
        if (leveragedTokenOut < minLeveragedTokenOut) {
            revert MintInsufficientAmount(leveragedToken_, minLeveragedTokenOut, leveragedTokenOut);
        }
        // mint the leveraged tokens and take collateralIn
        _mintLeveragedToken(collateralToken_, collateralIn, leveragedToken_, leveragedTokenOut, recipient);
        // take the fee
        IERC20(collateralToken_).safeTransfer($.feeReceiver, fee);
    }

    function _findBandAndUpperBound(
        ActionIncentive memory config,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice,
        uint256 peggedTokenBalance_
    ) private pure returns (uint band, uint256 bandUpperBound) {
        uint256 collateralRatio_ = _collateralRatio(collateralTokenBalance_, collateralPrice, peggedTokenBalance_);
        for (; band < collateralRatioBandCount(config) - 1; band++) {
            bandUpperBound = _collateralRatioUpperBounds(config, band);
            if (collateralRatio_ <= bandUpperBound) {
                break;
            }
        }
    }

    function _findBandAndLowerBound(
        ActionIncentive memory config,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice,
        uint256 peggedTokenBalance_
    ) private pure returns (uint band, uint256 bandLowerBound) {
        uint256 collateralRatio_ = _collateralRatio(collateralTokenBalance_, collateralPrice, peggedTokenBalance_);
        for (band = collateralRatioBandCount(config) - 1; band > 0; band--) {
            // we add 2 here to ensure rounding errors don't result in the collateral ratio being
            // less than or equal to the the disallow collateral ratio upper bound.
            bandLowerBound = _collateralRatioUpperBounds(config, band - 1) + 2;
            if (collateralRatio_ >= bandLowerBound) {
                break;
            }
        }
    }

    /**
     * @param collateralIn the given collateral, assumed to be > 0
     *
     */

    function _mintLeveragedAdjustments(
        ActionIncentive memory config,
        uint256 collateralIn,
        uint256 collateralTokenBalance_,
        uint256 price,
        uint256 peggedTokenBalance_,
        uint256 reservePoolBalance_
    ) private pure returns (uint256 fee, uint256 extraCollateral) {
        // we cannot calculate collateral ratio when there are no pegged tokens as it's infinite i.e. (/0)
        if (peggedTokenBalance_ == 0) revert ActionPaused();
        // TODO: test for first mint of pegged, in the context of existing and non-existing leveraged tokens
        // TODO: handle depegged situation, where leveraged token is worth 0 and pegged is worth it's share of collateral

        // simulate minting or redeeming tokens from current collateral ratio upwards or downwards,
        // extracting the fee at the correct ratio as we go.
        // We do this band at a time, pro-rating the resulting fee according to how much collateral was needed in
        // each band entered. We use collateral to pro-rate, rather than collateral ration which would be simpler, because
        // we multiply the resulting ratios by the collateral for the final fee

        (uint band, uint256 bandUpperBound) = _findBandAndUpperBound(
            config,
            collateralTokenBalance_,
            price,
            peggedTokenBalance_
        );

        // simulate minting until we run out of collateral, adding the fee & bonus as we go
        while (true) {
            int256 bandIncentiveRatio = _incentiveRatio(config, band);

            if (band == collateralRatioBandCount(config) - 1) {
                // in last band for mint leveraged, note that it cannot be negative by config update check
                fee += (collateralIn * uint256(bandIncentiveRatio)) / 1 ether;
                // there should be no extra collateral here
                // TODO: make sure in updateConfig that there is no discount at the top band
                break;
            }
            uint256 bandFeeRatio = uint256(SignedMath.max(0, bandIncentiveRatio));
            // the collateral in the band given the band fee
            uint256 collateralInBand = ((bandUpperBound * peggedTokenBalance_ - collateralTokenBalance_ * price) *
                1 ether) / (price * (1 ether - bandFeeRatio));

            // can't have more collateral in the band that there is collateral left
            collateralInBand = Math.min(collateralIn, collateralInBand);
            uint256 extraCollateralInBand = 0;
            uint256 bandFee = 0;
            if (bandIncentiveRatio > 0) {
                bandFee = (collateralInBand * uint256(bandIncentiveRatio)) / 1 ether;
                // tally the weighted fee ratios
                fee += bandFee;
            } else if (bandIncentiveRatio < 0) {
                extraCollateralInBand = (collateralInBand * uint256(-bandIncentiveRatio)) / 1 ether;
                // tally the discounts
                if (extraCollateralInBand <= reservePoolBalance_) {
                    reservePoolBalance_ -= extraCollateralInBand;
                } else {
                    extraCollateralInBand = reservePoolBalance_;
                    reservePoolBalance_ = 0;
                }
                extraCollateral += extraCollateralInBand;
            }
            collateralIn -= collateralInBand;
            if (collateralIn == 0) break;
            // still some collateral left and we're allowed to mint or redeem
            // add the incentiveRatio for this band
            collateralTokenBalance_ += collateralInBand - bandFee + extraCollateralInBand;

            band++;
            bandUpperBound = _collateralRatioUpperBounds(config, band);
        }
    }

    // @inheritdoc IMinter
    function freeMintLeveragedToken(
        uint256 collateralIn,
        address recipient
    ) external override onlyRole(ZERO_FEE_ROLE) returns (uint256 leveragedTokenOut) {
        MinterStorage storage $ = _getMinterStorage();
        // how much collateral to use
        address collateralToken_ = $.collateralToken;
        collateralIn = Token.allOf(_msgSender(), collateralToken_, collateralIn);

        // mint the tokens to the recipient
        uint256 price = _fetchSafePrice($.priceOracle);

        address leveragedToken_ = $.leveragedToken;
        uint256 collateralTokenBalance_ = _collateralTokenBalance(collateralToken_);
        leveragedTokenOut = _leverageTokensForCollateral(
            collateralIn,
            _leveragedTokenBalance(leveragedToken_),
            $.peggedTokenBalance,
            collateralTokenBalance_,
            price
        );

        _mintLeveragedToken(collateralToken_, collateralIn, leveragedToken_, leveragedTokenOut, recipient);
    }

    function _mintLeveragedToken(
        address collateralToken_,
        uint256 collateralIn,
        address leveragedToken_,
        uint256 leveragedTokenOut,
        address recipient
    ) private {
        // tell the world
        emit MintLeveragedToken(_msgSender(), recipient, collateralIn, leveragedTokenOut);

        // mint the tokens to the recipient
        IMintable(leveragedToken_).mint(recipient, leveragedTokenOut);
        // take the collateral
        IERC20(collateralToken_).safeTransferFrom(_msgSender(), address(this), collateralIn);
    }

    /// @inheritdoc IMinter
    function redeemLeveragedToken(
        uint256 leveragedIn,
        address recipient,
        uint256 minCollateralOut
    ) external override returns (uint256 collateralOut) {
        MinterStorage storage $ = _getMinterStorage();
        address leveragedToken_ = $.leveragedToken;
        leveragedIn = Token.allOf(_msgSender(), leveragedToken_, leveragedIn);

        uint256 leveragedTokenBalance_ = _leveragedTokenBalance(leveragedToken_);
        leveragedIn = _redeemable(leveragedToken_, leveragedIn, leveragedTokenBalance_);
        uint256 price = _fetchMinPrice($.priceOracle);
        address collateralToken_ = $.collateralToken;
        uint256 collateralTokenBalance_ = _collateralTokenBalance(collateralToken_);
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;

        collateralOut = _collateralForLeveragedTokens(
            leveragedIn,
            leveragedTokenBalance_,
            peggedTokenBalance_,
            collateralTokenBalance_,
            price
        );

        uint256 fee;
        (fee, collateralOut) = _redeemLeveragedAdjustments(
            $.redeemLeveragedConfig,
            collateralOut,
            collateralTokenBalance_,
            price,
            peggedTokenBalance_
        );

        collateralOut -= fee;
        if (collateralOut < minCollateralOut) {
            revert ReturnInsufficientAmount(collateralToken_, minCollateralOut, collateralOut);
        }

        _redeemLeveragedToken(leveragedToken_, leveragedIn, collateralToken_, collateralOut, recipient);

        if (fee > 0) {
            // send the fee
            IERC20(collateralToken_).safeTransfer($.feeReceiver, fee);
        }
    }

    function _redeemLeveragedAdjustments(
        ActionIncentive memory config,
        uint256 collateralIn,
        uint256 collateralTokenBalance_,
        uint256 price,
        uint256 peggedTokenBalance_
    ) private pure returns (uint256 fee, uint256 maxCollateral) {
        // we cannot calculate collateral ratio when there are no pegged tokens as it's infinite i.e. (/0)
        if (peggedTokenBalance_ == 0) revert ActionPaused();

        // find the band and it's lower bound where the current collateral ratio is
        // (note we treat the disallow band as any other here, except that it is the terminal band)
        (uint band, uint256 bandLowerBound) = _findBandAndLowerBound(
            config,
            collateralTokenBalance_,
            price,
            peggedTokenBalance_
        );
        if (band == 0) {
            // in disallow band for mint pegged or redeem leveraged
            return (0, 0);
        }
        // simulate minting until we run out of collateral, adding the fee & bonus as we go
        while (true) {
            uint256 bandFeeRatio = uint256(SignedMath.max(0, _incentiveRatio(config, band)));
            uint256 collateralInBand = ((collateralTokenBalance_ * price - bandLowerBound * peggedTokenBalance_) *
                1 ether) / (price * (1 ether - bandFeeRatio));
            collateralInBand = Math.min(collateralIn, collateralInBand);
            uint256 bandFee = (collateralInBand * uint256(bandFeeRatio)) / 1 ether;
            maxCollateral += collateralInBand;
            fee += bandFee;
            collateralIn -= collateralInBand;
            if (collateralIn == 0 || band == 1) {
                // we have either:
                //      run out of collateral
                // or:
                //      arrived in the lowest band and we have more collateral than the band allows
                //      so all we can use is the collateral in the band as the rest is disallowed
                // or
                break;
            }
            // still some collateral left and we're allowed to mint or redeem, so simulate
            collateralTokenBalance_ += collateralInBand - bandFee;

            band--;
            bandLowerBound = _collateralRatioUpperBounds(config, band - 1);
        }
    }

    // @inheritdoc IMinter
    function freeRedeemLeveragedToken(
        uint256 leveragedIn,
        address recipient
    ) external override onlyRole(ZERO_FEE_ROLE) returns (uint256 collateralOut) {
        MinterStorage storage $ = _getMinterStorage();
        // how much collateral to use
        address leveragedToken_ = $.leveragedToken;
        leveragedIn = Token.allOf(_msgSender(), leveragedToken_, leveragedIn);

        uint256 leveragedTokenBalance_ = _leveragedTokenBalance(leveragedToken_);
        leveragedIn = _redeemable(leveragedToken_, leveragedIn, leveragedTokenBalance_);

        uint256 price = _fetchMinPrice($.priceOracle);

        address collateralToken_ = $.collateralToken;
        collateralOut = _collateralForLeveragedTokens(
            leveragedIn,
            leveragedTokenBalance_,
            $.peggedTokenBalance,
            _collateralTokenBalance(collateralToken_),
            price
        );

        _redeemLeveragedToken(leveragedToken_, leveragedIn, collateralToken_, collateralOut, recipient);
    }

    function _redeemLeveragedToken(
        address leveragedToken_,
        uint256 leveragedIn,
        address collateralToken_,
        uint256 collateralOut,
        address recipient
    ) private {
        // tell the world
        emit RedeemLeveragedToken(_msgSender(), recipient, leveragedIn, collateralOut);
        // burn the leveraged
        IBurnableFrom(leveragedToken_).burnFrom(_msgSender(), leveragedIn);
        // return the collateral
        IERC20(collateralToken_).safeTransfer(recipient, collateralOut);
    }

    // -------------------------
    // Fee calculation functions
    // -------------------------

    function mintPeggedTokenIncentiveRatio(
        uint256 collateralIn
    ) external view override returns (int256 incentiveRatio, uint256 maxCollateral) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 price = _fetchSafePrice($.priceOracle);
        ActionIncentive memory config = $.mintPeggedConfig;
        if (collateralIn == 0) {
            (uint band, ) = _findBandAndLowerBound(
                config,
                _collateralTokenBalance($.collateralToken),
                price,
                $.peggedTokenBalance
            );
            if (band == 0) {
                // TODO: ensure there is always a band 1
                incentiveRatio = _incentiveRatio(config, 1);
            } else {
                incentiveRatio = _incentiveRatio(config, band);
            }
        } else {
            // fee calculation
            uint256 fee;
            (fee, maxCollateral) = _mintPeggedAdjustments(
                config,
                collateralIn,
                _collateralTokenBalance($.collateralToken),
                price,
                $.peggedTokenBalance
            );
            incentiveRatio = maxCollateral == 0 ? _incentiveRatio(config, 1) : int256((fee * 1 ether) / maxCollateral);
        }
    }

    function redeemPeggedTokenIncentiveRatio(uint256 peggedIn) external view override returns (int256 incentiveRatio) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 price = _fetchMaxPrice($.priceOracle);
        ActionIncentive memory config = $.redeemPeggedConfig;
        if (peggedIn == 0) {
            // just want the fee/bonus at the current collateral
            (uint band, ) = _findBandAndUpperBound(
                config,
                _collateralTokenBalance($.collateralToken),
                price,
                $.peggedTokenBalance
            );
            incentiveRatio = _incentiveRatio(config, band);
        } else {
            uint256 collateralIn = (peggedIn * 1 ether) / price;
            address collateralToken_ = $.collateralToken;
            (uint256 fee, uint256 extraCollateral) = _redeemPeggedAdjustments(
                config,
                collateralIn,
                _collateralTokenBalance(collateralToken_),
                price,
                $.peggedTokenBalance,
                IERC20(collateralToken_).balanceOf($.reservePool)
            );
            incentiveRatio = ((int256(fee) - int256(extraCollateral)) * 1 ether) / int256(collateralIn);
        }
    }

    /**
     * @param collateralIn the given collateral, assumed to be > 0
     *
     */

    function _redeemPeggedAdjustments(
        ActionIncentive memory config,
        uint256 collateralIn,
        uint256 collateralTokenBalance_,
        uint256 price,
        uint256 peggedTokenBalance_,
        uint256 reservePoolBalance_
    ) private pure returns (uint256 fee, uint256 extraCollateral) {
        // we cannot calculate collateral ratio when there are no pegged tokens as it's infinite i.e. (/0)
        if (peggedTokenBalance_ == 0) revert ActionPaused();
        // TODO: test for first mint of pegged, in the context of existing and non-existing leveraged tokens
        // TODO: handle depegged situation, where leveraged token is worth 0 and pegged is worth it's share of collateral

        // simulate minting or redeeming tokens from current collateral ratio upwards or downwards,
        // extracting the fee at the correct ratio as we go.
        // We do this band at a time, pro-rating the resulting fee according to how much collateral was needed in
        // each band entered. We use collateral to pro-rate, rather than collateral ration which would be simpler, because
        // we multiply the resulting ratios by the collateral for the final fee
        (uint band, uint256 bandUpperBound) = _findBandAndUpperBound(
            config,
            collateralTokenBalance_,
            price,
            peggedTokenBalance_
        );

        // simulate minting until we run out of collateral, adding the fee & bonus as we go
        while (true) {
            int256 bandIncentiveRatio = _incentiveRatio(config, band);
            uint256 bandFeeRatio = uint256(SignedMath.max(0, bandIncentiveRatio));
            uint256 bandFee;
            if (band == collateralRatioBandCount(config) - 1) {
                // in last band for mint leveraged, note that it cannot be negative by config update check
                bandFee = (collateralIn * uint256(bandIncentiveRatio)) / 1 ether;
                fee += bandFee;
                collateralTokenBalance_ -= collateralIn;
                peggedTokenBalance_ -= ((collateralIn * price) / 1 ether);
                break;
            }

            // TODO: reduce calcs by factoring out price? (same for mint pegged adjustments)
            // TODO: factor out this equation into a separate function
            uint256 collateralInBand = ((bandUpperBound * peggedTokenBalance_ - collateralTokenBalance_ * price) *
                1 ether) / (price * ((bandUpperBound * (1 ether - bandFeeRatio)) / 1 ether - 1 ether + bandFeeRatio));
            // can't have more collateral in the band that there is collateral left
            collateralInBand = Math.min(collateralIn, collateralInBand);
            bandFee = 0;
            if (bandIncentiveRatio > 0) {
                bandFee = (collateralInBand * uint256(bandIncentiveRatio)) / 1 ether;
                // tally the weighted fee ratios
                fee += bandFee;
            } else if (bandIncentiveRatio < 0) {
                uint256 extraCollateralInBand = (collateralInBand * uint256(-bandIncentiveRatio)) / 1 ether;
                // tally the discounts
                if (extraCollateralInBand <= reservePoolBalance_) {
                    reservePoolBalance_ -= extraCollateralInBand;
                } else {
                    extraCollateralInBand = reservePoolBalance_;
                    reservePoolBalance_ = 0;
                }
                extraCollateral += extraCollateralInBand;
            }
            collateralIn -= collateralInBand;
            if (collateralIn == 0) break;
            // still some collateral left and we're allowed to mint or redeem
            // add the incentiveRatio for this band

            // TODO: what happens if subtracted, above, is greater than the balance, below?
            // we need to check for this before we leave the loop above
            // TODO: add a test for this
            collateralTokenBalance_ -= collateralInBand;
            peggedTokenBalance_ -= ((collateralInBand * price) / 1 ether);

            band++;
            bandUpperBound = _collateralRatioUpperBounds(config, band);
        }
    }

    // TODO: should be fees lower/bonus higher for higher leveraged token redeem amount
    function mintLeveragedTokenIncentiveRatio(
        uint256 collateralIn
    ) external view override returns (int256 incentiveRatio) {
        MinterStorage storage $ = _getMinterStorage();
        // TODO: do we need safe price for this?
        uint256 price = _fetchSafePrice($.priceOracle);
        ActionIncentive memory config = $.mintLeveragedConfig;
        if (collateralIn == 0) {
            // just want the fee/bonus at the current collateral
            (uint band, ) = _findBandAndUpperBound(
                config,
                _collateralTokenBalance($.collateralToken),
                price,
                $.peggedTokenBalance
            );
            incentiveRatio = _incentiveRatio(config, band);
        } else {
            address collateralToken_ = $.collateralToken;
            (uint256 fee, uint256 extraCollateral) = _mintLeveragedAdjustments(
                config,
                collateralIn,
                _collateralTokenBalance(collateralToken_),
                price,
                $.peggedTokenBalance,
                IERC20(collateralToken_).balanceOf($.reservePool)
            );
            incentiveRatio = ((int256(fee) - int256(extraCollateral)) * 1 ether) / int256(collateralIn);
        }
    }

    function redeemLeveragedTokenIncentiveRatio(
        uint256 leveragedIn
    ) external view override returns (int256 incentiveRatio, uint256 maxCollateral) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 price = _fetchMinPrice($.priceOracle);
        uint256 collateralTokenBalance_ = _collateralTokenBalance($.collateralToken);
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        ActionIncentive memory config = $.redeemLeveragedConfig;

        incentiveRatio = 0;
        uint256 leveragedTokenBalance_ = _leveragedTokenBalance($.leveragedToken);

        if (leveragedIn == 0 || leveragedTokenBalance_ == 0) {
            (uint band, ) = _findBandAndLowerBound(config, collateralTokenBalance_, price, peggedTokenBalance_);
            if (band == 0) {
                // TODO: ensure there is always a band 1
                incentiveRatio = _incentiveRatio(config, 1);
            } else {
                incentiveRatio = _incentiveRatio(config, band);
            }
        } else {
            // fee calculation
            uint256 collateralIn = _collateralForLeveragedTokens(
                leveragedIn,
                _leveragedTokenBalance($.leveragedToken),
                peggedTokenBalance_,
                collateralTokenBalance_,
                price
            );

            uint256 fee;
            (fee, maxCollateral) = _mintPeggedAdjustments(
                config,
                collateralIn,
                collateralTokenBalance_,
                price,
                peggedTokenBalance_
            );
            incentiveRatio = maxCollateral == 0 ? _incentiveRatio(config, 1) : int256((fee * 1 ether) / maxCollateral);
        }
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

    // other calculations
    // ------------------

    // the price of a leveraged token in terms of the pegged token's underlying
    function leveragedTokenPrice() external view override returns (uint256 nav) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 price = _fetchSafePrice($.priceOracle);
        nav = _leveragedTokenPrice(
            _leveragedTokenBalance($.leveragedToken),
            $.peggedTokenBalance,
            _collateralTokenBalance($.collateralToken),
            price
        );
    }

    // the price of a leveraged token in terms of the pegged token's underlying
    function _leveragedTokenPrice(
        uint256 leveragedTokenBalance_,
        uint256 peggedTokenBalance_,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice
    ) private pure returns (uint256 nav) {
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
            _leveragedTokenBalance($.leveragedToken),
            $.peggedTokenBalance,
            _collateralTokenBalance($.collateralToken),
            price
        );
    }
    /**
     * @dev pegged value must not be greater than collateral value, i.e. it's depegged
     */
    function _leverageTokensForCollateral(
        uint256 forCollateral,
        uint256 leveragedTokenBalance_,
        uint256 peggedTokenBalance_,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice
    ) private pure returns (uint256 leveragedTokens) {
        // the following assumes that the collateral change is small compared to the overall collateral
        // because it is the derivative of the legeraged balance with respect to the collateral balance
        // using the invariant collateral value = leveraged value + pegged value.
        // this may well be a reasonable assumption
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

    function collateralForLeverageTokens(
        uint256 forLeveragedTokens
    ) external view override returns (uint256 leveragedTokens) {
        MinterStorage storage $ = _getMinterStorage();
        leveragedTokens = _collateralForLeveragedTokens(
            forLeveragedTokens,
            _leveragedTokenBalance($.leveragedToken),
            $.peggedTokenBalance,
            _collateralTokenBalance($.collateralToken),
            _fetchMinPrice($.priceOracle)
        );
    }

    // @param leveragedTokenBalance the stotal supply of leveraged tokens, required to be > 0
    function _collateralForLeveragedTokens(
        uint256 forLeveraged,
        uint256 leveragedTokenBalance_,
        uint256 peggedTokenBalance_,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice
    ) private pure returns (uint256 collateral) {
        if (leveragedTokenBalance_ == 0) {
            collateral = forLeveraged * collateralPrice;
        } else {
            collateral =
                (forLeveraged * (collateralTokenBalance_ * collateralPrice - peggedTokenBalance_ * 1 ether)) /
                (collateralPrice * leveragedTokenBalance_);
        }
    }

    /// @notice Return the current collateral ratio of the peggedToken to the collateral token, multipled by 1e18.
    function collateralRatio() external view override returns (uint256) {
        MinterStorage storage $ = _getMinterStorage();
        if ($.peggedTokenBalance == 0) {
            return type(uint256).max; // TODO: consider reverting here
        } else {
            return
                _collateralRatio(
                    _collateralTokenBalance($.collateralToken),
                    _fetchSafePrice($.priceOracle),
                    $.peggedTokenBalance
                );
        }
    }

    function _collateralRatio(
        uint256 collateralTokenBalance_,
        uint256 collateralPrice,
        uint256 peggedTokenBalance_
    ) private pure returns (uint256 collateralRatio_) {
        //console.log("collateralRatio(%s,%s,%s)", collateralTokenBalance_, collateralPrice, peggedTokenBalance_);
        collateralRatio_ = (collateralTokenBalance_ * collateralPrice) / peggedTokenBalance_;
        // console.log("collateralRatio()=%s", collateralRatio_);
    }

    /*
     int256 _earningRatio = int256(_state.baseNav).sub(_lastPermissionedPrice).mul(PRECISION_I256).div(
      _lastPermissionedPrice
    );

             function leverageRatio(
    SwapState memory state,
    uint256 beta,
    int256 earningRatio


  ) internal pure returns (uint256 ratio) {
    // (1 - rho * beta * (1 + r)) / (1 - rho)
    uint256 rho = state.fSupply.mul(state.fNav).mul(PRECISION).div(state.baseSupply.mul(state.baseNav));
    uint256 x = rho.mul(beta).mul(uint256(PRECISION_I256 + earningRatio)).div(PRECISION * PRECISION);
    ratio = PRECISION.sub(x).mul(PRECISION).div(PRECISION - rho);
    if (ratio > MAX_LEVERAGE_RATIO) ratio = MAX_LEVERAGE_RATIO;
  }
*/

    function leverageRatio() external view override returns (uint256) {
        MinterStorage storage $ = _getMinterStorage();
        return
            _leverageRatio(
                _collateralTokenBalance($.collateralToken),
                _fetchSafePrice($.priceOracle),
                $.peggedTokenBalance
            );
    }

    function _leverageRatio(
        uint256 collateralTokenBalance_,
        uint256 collateralPrice,
        uint256 peggedTokenBalance_
    ) private pure returns (uint256 ratio) {
        // ratio = (1 - rho * beta * (1 + r)) / (1 - rho), and beta = 0
        // ratio = 1 / (1 - rho)
        // rho = inverse of the collateral ratio
        uint256 rho = peggedTokenBalance_ / (collateralTokenBalance_ * collateralPrice);
        if (rho >= 1 ether) {
            // under collateral, assume infinite leverage
            // TODO: max leverage ratio
            ratio = type(uint256).max;
        } else {
            ratio = (1 ether * 1 ether) / (1 ether - rho);
            // TODO: if (ratio > MAX_LEVERAGE_RATIO) ratio = MAX_LEVERAGE_RATIO;
        }
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

    function peggedTokenBalance() external view override returns (uint256) {
        MinterStorage storage $ = _getMinterStorage();
        return $.peggedTokenBalance;
    }

    function leveragedTokenBalance() external view override returns (uint256) {
        MinterStorage storage $ = _getMinterStorage();
        return _leveragedTokenBalance($.leveragedToken);
    }

    function _leveragedTokenBalance(address leveragedToken_) private view returns (uint256) {
        return IERC20(leveragedToken_).totalSupply();
    }

    function collateralTokenBalance() external view override returns (uint256) {
        MinterStorage storage $ = _getMinterStorage();
        return _collateralTokenBalance($.collateralToken);
    }

    function _collateralTokenBalance(address collateralToken_) private view returns (uint256) {
        return IERC20(collateralToken_).balanceOf(address(this));
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
