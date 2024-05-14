// SPDX-License-Identifier: MIT
// coding standards by https://www.rareskills.io/post/solidity-style-guide
// and https://docs.soliditylang.org/en/latest/style-guide.html
pragma solidity 0.8.25;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlDefaultAdminRulesUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { WordCodec } from "src/common/WordCodec.sol";
import { Token } from "src/common/Token.sol";

import { IMinter, IMinterTreasury } from "src/minter/IMinter.sol";
import { IMintable } from "src/minter/IMintable.sol";
import { IPriceOracle } from "src/price/IPriceOracle.sol";
import { IReservePool } from "src/minter/IReservePool.sol";

import "forge-std/console.sol";

/// @title
/// @author
/// @notice provides a base layer interface for minting and redeeming pegged and leveraged tokens
/// also provides information about the net asset values of the pegged and leveraged tokens
/// @dev uses UUPS proxy, erc7201 storage

/// @custom:oz-upgrades
contract Minter_v1 is
    Initializable,
    UUPSUpgradeable,
    AccessControlDefaultAdminRulesUpgradeable,
    IMinter,
    IMinterTreasury
{
    using SafeERC20 for IERC20;
    using WordCodec for bytes32;

    // collateral ratio bounds are stored as uint32, which allows for a maximum value of ~4 billion
    // with decimals = 6, this gives a max ratio of 4,000 (400,000%) with precision of 0.000001 (0.0001%),
    // e.g. 130.55% is easily catered for
    // this allow 8 of these to be stored in a slot. As we need 5, we need a whole slot
    uint private constant COLLATERAL_RATIO_DECIMALS = 6;

    // fee & bonus ratios are stored as int16, which allows for -2 billion to 2 billion
    // with decimals = 9, this gives a max ratio of 2 (200%) with precision of 0.000000001 (0.0000001%),
    // these ratios must be in the range [-1, 1] [-100%, 100%]
    // this allow 8 of these to be stored in a slot. As we need 6, we need a whole slot
    uint private constant INCENTIVE_RATIO_DECIMALS = 9;

    // zone indices for collateral ration, used to index CollateralRatioZones and the various FeeRatios
    enum CollateralRatioZones {
        bonus,
        rebalance,
        danger,
        normal
    }
    uint private constant maxBands = 6;
    uint private constant maxBounds = maxBands - 1;

    // we use astruct here but implement our own storage because solidity uses too many slots
    struct ActionIncentive {
        bytes32 slot0;
        // uint32[maxBounds] collateralRatioUpperBounds;      0:160
        // uint32 collateralRatioBandCount;                 160: 32
        // uint32 disallowcollateralRatioUpperBound         192: 32
        bytes32 slot1;
        // int32[maxBands] incentiveRatios;                   0:192
    }

    function collateralRatioUpperBounds(ActionIncentive memory config, uint index) private pure returns (uint256) {
        return config.slot0.decodeUint(index * 32, 32) * 10 ** (18 - COLLATERAL_RATIO_DECIMALS);
    }
    function setCollateralRatioUpperBounds(ActionIncentive memory config, uint index, uint256 value) private pure {
        config.slot0 = config.slot0.insertUint(value / 10 ** (18 - COLLATERAL_RATIO_DECIMALS), index * 32, 32);
    }
    function collateralRatioBandCount(ActionIncentive memory config) private pure returns (uint) {
        return config.slot0.decodeUint(160, 32);
    }
    function setCollateralRatioBandCount(ActionIncentive memory config, uint value) private pure {
        config.slot0 = config.slot0.insertUint(value, 160, 32);
    }
    function disallowCollateralRatioUpperBound(ActionIncentive memory config) private pure returns (uint256) {
        return config.slot0.decodeUint(192, 32) * 10 ** (18 - COLLATERAL_RATIO_DECIMALS);
    }
    function setDisallowCollateralRatioUpperBound(ActionIncentive memory config, uint256 value) private pure {
        config.slot0 = config.slot0.insertUint(value / 10 ** (18 - COLLATERAL_RATIO_DECIMALS), 192, 32);
    }
    function incentiveRatios(ActionIncentive memory config, uint index) private pure returns (int256) {
        return config.slot1.decodeInt(index * 32, 32) * int256(10 ** (18 - INCENTIVE_RATIO_DECIMALS));
    }
    function setIncentiveRatios(ActionIncentive memory config, uint index, int256 value) private pure {
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
        // TODO: remove the collateralTokenBalance
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
        address reservePool_,
        Config calldata config_
    ) external initializer {
        // initialise all the state variables
        __AccessControlDefaultAdminRules_init(7 days, owner);
        __UUPSUpgradeable_init();

        MinterStorage storage $ = _getMinterStorage();
        // balance tokens
        if (!Token.isERC20(tokens_.collateralToken)) revert Token.NotERC20Token(tokens_.collateralToken);

        $.collateralToken = tokens_.collateralToken;
        $.peggedToken = tokens_.peggedToken;
        $.peggedTokenBalance = 0;
        $.leveragedToken = tokens_.leveragedToken;

        _updatePriceOracle(priceOracle_);
        _updateFeeReceiver(feeReceiver_);
        _updateReservePool(reservePool_);
        _updateConfig(config_);

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
        setDisallowCollateralRatioUpperBound(out, disallowCollateralRatioUpperBound_);

        setCollateralRatioBandCount(out, config.incentiveRatios.length);

        // check monotonically increasing and copy;
        uint256 min = 0;
        for (uint i = 0; i < uint(config.collateralRatioBandUpperBounds.length); i++) {
            uint256 value = config.collateralRatioBandUpperBounds[i];
            if (value < min) {
                revert InvalidCollateralRatioBoundValue(value, min);
            }
            min = value;
            setCollateralRatioUpperBounds(out, i, value);
        }
        // check in range [-1, 1] and copy
        for (uint i = 0; i < uint(config.incentiveRatios.length); i++) {
            int256 value = config.incentiveRatios[i];
            if (value > 1 ether || value < -1 ether) {
                revert InvalidIncentiveRatioValue(value);
            }
            setIncentiveRatios(out, i, value);
        }
    }

    function _updateConfig(Config calldata config) private {
        // check the configs are monotonically increasing, bonus, rebalance, danger, normal
        MinterStorage storage $ = _getMinterStorage();

        // action config
        // TODO: consider making those 32 bit
        $.rebalanceCollateralRatioUpperBound = config.rebalanceCollateralRatioUpperBound;
        $.normalCollateralRatioUpperBound = config.normalCollateralRatioUpperBound;

        // incentive config
        $.mintPeggedConfig = _copyBands(
            config.mintPeggedIncentiveConfig,
            config.disallowMintPeggedCollateralRatioUpperBound
        );
        $.mintLeveragedConfig = _copyBands(config.mintLeveragedIncentiveConfig, 0);
        $.redeemPeggedConfig = _copyBands(config.redeemPeggedIncentiveConfig, 0);
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
    ) external override returns (uint256 peggedTokenOut) {
        MinterStorage storage $ = _getMinterStorage();
        // work out how much collateral to use
        address collateralToken_ = $.collateralToken;
        collateralIn = _allOf(_msgSender(), collateralToken_, collateralIn);

        uint256 price = _fetchSafePrice($.priceOracle);
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        uint256 collateralTokenBalance_ = _collateralTokenBalance(collateralToken_);

        // fee calculation
        int256 feeRatio;
        (collateralIn, feeRatio) = _mintPeggedAdjustments(
            $.mintPeggedConfig,
            collateralIn,
            price,
            collateralTokenBalance_,
            peggedTokenBalance_
        );
        // console.log("feeRatio=%s", uint256(feeRatio));
        int256 fee = (int256(collateralIn) * feeRatio) / 1 ether;
        // TODO: handle the case where fee is negative!
        collateralIn = uint256(int256(collateralIn) - fee);
        // console.log("fee=%s, collateralIn=%s", uint256(fee), collateralIn);

        address peggedToken_ = $.peggedToken;
        if (collateralIn == 0) revert MintZeroAmount(peggedToken_);

        // recalculate the amounts involved
        peggedTokenOut = (collateralIn * price) / 1 ether;

        if (peggedTokenOut < minPeggedTokenOut) {
            revert MintInsufficientAmount(peggedToken_, minPeggedTokenOut, peggedTokenOut);
        }

        IERC20(collateralToken_).safeTransferFrom(_msgSender(), $.feeReceiver, uint256(fee));
        _mintPeggedToken(collateralToken_, collateralIn, peggedToken_, peggedTokenOut, recipient, uint256(fee));

        // update our records
        $.peggedTokenBalance = peggedTokenBalance_ + peggedTokenOut;
    }

    function _proRatedRatio(
        uint256 lowerCollateralRatio,
        uint256 upperCollateralRatio,
        ActionIncentive memory config
    ) private pure returns (int256 feeRatio) {
        feeRatio = 0;
        // find the index, l, where lowerCollateralRatio falls
        uint l;
        // console.log("      collateralRatioBandCount - 1=%s", collateralRatioBandCount(config) - 1);
        for (l = 0; l < collateralRatioBandCount(config) - 1; l++) {
            if (lowerCollateralRatio <= collateralRatioUpperBounds(config, l)) {
                // console.log(
                //     "      lowerCollateralRatio=%s, collateralRatioUpperBounds[%s]=%s",
                //     lowerCollateralRatio,
                //     l,
                //     collateralRatioUpperBounds(config, l)
                // );
                break;
            }
        }
        // find the index, u, where upperCollateralRatio falls
        uint u;
        for (u = l; u < collateralRatioBandCount(config) - 1; u++) {
            if (upperCollateralRatio <= collateralRatioUpperBounds(config, u)) {
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
            feeRatio = incentiveRatios(config, l);
            // console.log("      feeRatio=%s, u=l=%s", uint256(feeRatio), l);
        } else {
            // Calculate pro-rated fee for the portion of lowerCollateralRatio in band l
            feeRatio = (int256(collateralRatioUpperBounds(config, l) - lowerCollateralRatio + 1) *
                incentiveRatios(config, l));
            // console.log("     feeRatio=%s, l=%s", uint256(feeRatio), l);

            // Calculate pro-rated fee for the full intervals between l and u
            for (uint256 k = l + 1; k < u; k++) {
                feeRatio += (int256(collateralRatioUpperBounds(config, k) - collateralRatioUpperBounds(config, k + 1)) *
                    incentiveRatios(config, k));
                // console.log("      feeRatio=%s, k=%s", uint256(feeRatio), l);
            }

            // Calculate pro-rated fee for the portion of upperCollateralRatio in band u
            feeRatio += (int256(upperCollateralRatio - collateralRatioUpperBounds(config, u - 1)) *
                incentiveRatios(config, u));
            // console.log("      feeRatio=%s, u=%s", uint256(feeRatio), l);
            feeRatio /= int256(upperCollateralRatio - lowerCollateralRatio); // Normalize fee based on range
            // console.log("      feeRatio=%s", uint256(feeRatio));
        }
    }

    /**
     * @notice calculates the fee or bonuses relating to the different feeRatios
     * It calculates the proportion, in collateral ratio space, the transition from one collateral ratio boundary to another
     * and performs a weighted sum of the fee ratios. It essentially performs a definite integral of the fee function.
     * @param config is the collateral ratio boundaries and the fee ratios within each boundary
     * @param collateralIn the proposed amount of collateral being posted in exchange for pegged tokens
     * @param price the value of a collateral token in terms of the pegged token.
     * @param collateralTokenBalance_ is the amount of collateral held. This is used to calculate collateral ratios
     * @param peggedTokenBalance_ is the amount of pegged tokens issued. This is used to calculate collateral ratios
     * @return collateralInUsed the amount of collateral to be used, e.g. this amount can be multiplied by feeRatio to get the fee
     * @return feeRatio the pro-rated fee
     */
    function _mintPeggedAdjustments(
        ActionIncentive memory config,
        uint256 collateralIn,
        uint256 price,
        uint256 collateralTokenBalance_,
        uint256 peggedTokenBalance_
    ) private pure returns (uint256 collateralInUsed, int256 feeRatio) {
        //console.log("  collateralIn=%s", collateralIn);
        // we cannot calculate collateral ratio when there are no pegged tokens as it's infinite i.e. (/0)
        if (peggedTokenBalance_ == 0) revert ActionPaused();
        uint256 currentCollateralRatio = _collateralRatio(collateralTokenBalance_, price, peggedTokenBalance_);
        // console.log("  currentCollateralRatio=%s", currentCollateralRatio);
        // why add 2 for the lower bound? because we want to ensure that the below calculations do not result in a
        // collateral ratio less than the disallow upper bound.
        uint256 collateralRatioLowerBound = disallowCollateralRatioUpperBound(config) + 2;
        // console.log("  collateralRatioLowerBound=%s", collateralRatioLowerBound);
        // as minting never increases collateral ratio if we are currently disallowed then there's no collateral used and the fee ratio is 0
        if (currentCollateralRatio < collateralRatioLowerBound) return (0, 0);

        // TODO: handle depegged situation, where leveraged token is worth 0 and pegged is worth it's share of collateral
        uint256 proposedCollateralRatio = _collateralRatio(
            collateralTokenBalance_ + collateralIn,
            price,
            peggedTokenBalance_ + (collateralIn * price) / 1 ether
        );
        // console.log("  proposedCollateralRatio=%s", proposedCollateralRatio);

        // can't mint/redeem triggering a rebalance, so adjust the collateralIn to prevent this
        if (proposedCollateralRatio < collateralRatioLowerBound) {
            proposedCollateralRatio = collateralRatioLowerBound;
            // console.log("  proposedCollateralRatio=%s (limited)", proposedCollateralRatio);
            feeRatio = _proRatedRatio(proposedCollateralRatio, currentCollateralRatio, config);
            // formula derived by taking the collateral ratio formula an backing out the collateral needed
            // fees are deducted before hand, thus applying to both the collateral token and pegged token balances
            // without consideroing fees:
            // collateralInUsed =
            //     ((collateralTokenBalance_ * price - proposedCollateralRatio * peggedTokenBalance_) * 1 ether) /
            //     ((proposedCollateralRatio - 1 ether) * price);
            // considering fees:
            collateralInUsed =
                ((collateralTokenBalance_ * price - proposedCollateralRatio * peggedTokenBalance_) * 1 ether) /
                uint256(
                    int256(price) *
                        ((int256(proposedCollateralRatio) * (1 ether - feeRatio)) / 1 ether - 1 ether + feeRatio)
                );
        } else {
            collateralInUsed = collateralIn;
            // calculate the fee as a pro-rata of each of the collateral zones it is in
            feeRatio = _proRatedRatio(proposedCollateralRatio, currentCollateralRatio, config);
        }
        // console.log("   feeRatio=%s", uint256(feeRatio));
        // console.log("   collateralInUsed=%s", collateralInUsed);
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

        // update our records
        $.peggedTokenBalance += peggedTokenOut;
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

        address leveragedToken_ = $.leveragedToken;

        uint256 leveragedTokenBalance_ = _leveragedTokenBalance(leveragedToken_);
        uint256 collateralTokenBalance_ = _collateralTokenBalance(collateralToken_);
        // uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        int256 fee = (_mintLeveragedAdjustments(
            $.mintLeveragedConfig,
            collateralIn,
            price,
            collateralTokenBalance_,
            $.peggedTokenBalance
        ) * int256(collateralIn)) / 1 ether;

        // TODO: add the rebalance pool balance
        if (fee >= 0) {
            collateralIn -= uint256(fee);
            bonusOut = 0;
        } else {
            // TODO: add the bonus here (if rebalance pools are exhausted)
            IReservePool($.reservePool).requestBonus(collateralToken_, recipient, uint256(-fee));
        }

        leveragedTokenOut = _leverageTokensForCollateral(
            collateralIn,
            leveragedTokenBalance_,
            $.peggedTokenBalance,
            collateralTokenBalance_,
            price
        );

        if (leveragedTokenOut < minLeveragedTokenOut) {
            revert MintInsufficientAmount(leveragedToken_, minLeveragedTokenOut, leveragedTokenOut);
        }
        IERC20(collateralToken_).safeTransferFrom(_msgSender(), $.feeReceiver, uint256(fee));
        _mintLeveragedToken(
            collateralToken_,
            collateralIn,
            leveragedToken_,
            leveragedTokenOut,
            recipient,
            uint256(fee),
            bonusOut
        );
    }

    function _mintLeveragedAdjustments(
        ActionIncentive memory config,
        uint256 collateralIn,
        uint256 price,
        uint256 collateralTokenBalance_,
        uint256 peggedTokenBalance_
    ) private pure returns (int256 feeRatio) {
        // we cannot calculate collateral ratio when there are no pegged tokens as it's infinite i.e. (/0)
        if (peggedTokenBalance_ == 0) revert ActionPaused();
        uint256 currentCollateralRatio = _collateralRatio(collateralTokenBalance_, price, peggedTokenBalance_);

        uint256 proposedCollateralRatio = _collateralRatio(
            collateralTokenBalance_ + collateralIn,
            price,
            peggedTokenBalance_
        );
        //console.log("   proposedCollateralRatio=%s", proposedCollateralRatio);

        // calculate the fee
        feeRatio = _proRatedRatio(currentCollateralRatio, proposedCollateralRatio, config);
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

        address leveragedToken_ = $.leveragedToken;
        uint256 collateralTokenBalance_ = _collateralTokenBalance(collateralToken_);
        leveragedTokenOut = _leverageTokensForCollateral(
            collateralIn,
            _leveragedTokenBalance(leveragedToken_),
            $.peggedTokenBalance,
            collateralTokenBalance_,
            price
        );

        _mintLeveragedToken(collateralToken_, collateralIn, leveragedToken_, leveragedTokenOut, recipient, 0, 0);
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
    }

    /// @inheritdoc IMinter
    function redeemLeveragedToken(
        uint256 leveragedTokenIn,
        address recipient,
        uint256 minCollateralOut
    ) external override returns (uint256 collateralOut) {}

    function _allOf(address account, address token, uint256 tokenIn) private view returns (uint256 actualIn) {
        if (tokenIn == type(uint256).max) {
            actualIn = IERC20(token).balanceOf(account);
        } else {
            actualIn = tokenIn;
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

    function mintPeggedTokenFeeRatio(uint256 additionalCollateral) external view override returns (int256 feeRatio) {
        // get the collateral ratio
        //console.log("additionalCollateral=%s", additionalCollateral);
        MinterStorage storage $ = _getMinterStorage();
        uint256 price = _fetchSafePrice($.priceOracle);

        // console.log("about to call adjustments");
        // fee calculation
        uint256 collateralUsed;
        (collateralUsed, feeRatio) = _mintPeggedAdjustments(
            $.mintPeggedConfig,
            additionalCollateral,
            price,
            _collateralTokenBalance($.collateralToken),
            $.peggedTokenBalance
        );
        //console.log("mintPeggedTokenFeeRatio=%s", feeRatio);
    }

    function redeemPeggedTokenFeeRatio(uint256 reductionOfPegged) external view override returns (int256 feeRatio) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 price = _fetchSafePrice($.priceOracle);
        feeRatio = 0;
    }

    // TODO: should be fees lower/bonus higher for higher leveraged token redeem amount
    function mintLeveragedTokenFeeRatio(uint256 additionalCollateral) external view override returns (int256 feeRatio) {
        MinterStorage storage $ = _getMinterStorage();
        // TODO: do we need safe price for this?
        uint256 price = _fetchSafePrice($.priceOracle);
        feeRatio = _mintLeveragedAdjustments(
            $.mintLeveragedConfig,
            additionalCollateral,
            price,
            _collateralTokenBalance($.collateralToken),
            $.peggedTokenBalance
        );
    }

    function redeemLeveragedTokenFeeRatio(
        uint256 reductionOfLeveraged
    ) external view override returns (int256 feeRatio) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 price = _fetchSafePrice($.priceOracle);
        uint256 collateralTokenBalance_ = _collateralTokenBalance($.collateralToken);
        // TODO: make sure there wont be a subtaction underflow
        feeRatio = 0;
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

    /*
    function _feeRatio(
        uint256 atCollateralRatio,
        uint32[zoneBounds] memory collateralRatios,
        uint32[zones] memory feeRatios
    ) private pure returns (uint256 feeRatio, CollateralRatioZones zone) {
        // find the upper and lower bounds of the collateral ration zone we are in
        if (atCollateralRatio > _ratioEther(collateralRatios[collateralRatios.length - 1])) {
            // > normalUpperBound, so in safe zone
            return (_ratioEther(feeRatios[uint(CollateralRatioZones.safe)]), CollateralRatioZones.safe);
        }
        //console.log("CR=%s", atCollateralRatio);
        for (uint ib = 1; ib < uint(collateralRatios.length); ib++) {
            // ib goes from 1 to 3
            uint z = collateralRatios.length - ib; // goes from 3 (normal) to 1 (rebalance)
            //console.log("?%s > collateralRatios[%s](%s)", atCollateralRatio, zone, _ratioEther(collateralRatios[zone]));
            if (atCollateralRatio > _ratioEther(collateralRatios[z - 1])) {
                // found the upper bound for the zone below
                uint256 upperBoundFeeRatio = _ratioEther(feeRatios[z + 1]);
                uint256 lowerBoundFeeRatio = _ratioEther(feeRatios[z]);
                if (upperBoundFeeRatio == lowerBoundFeeRatio) {
                    // console.log("lower, upper bound fee=%s, %s", lowerBoundFeeRatio, upperBoundFeeRatio);
                    return (upperBoundFeeRatio, CollateralRatioZones(z));
                } else {
                    uint256 upperCollateralRatio = _ratioEther(collateralRatios[z]);
                    uint256 lowerCollateralRatio = _ratioEther(collateralRatios[z - 1]);
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

                    //uint256 x2 = (x * x) / (1 ether); // Normalize x^2
                    //smoothstep = (x2 * (3 ether - 2 * x)) / 1 ether;
                    // second order smooth, unfortunately x^5 is likely to underflow, so we need to do more work to get this
                    // 6*x^5 - 15*x^4 + 10*x^3
                    // smoothstep = (((x2 * x2) / 1 ether) * (((x * (6 * x - 15 ether)) / 1 ether) + 10 ether)) / 1 ether;
                    //                    -------------------            ----------------                --------
                    //                                            ------------------------------------------------
                    //                   ----------------------------------------------------

                    // now scale the smoothstep into fee ratio space and invert it
                    if (upperBoundFeeRatio > lowerBoundFeeRatio) {
                        // step up
                        // console.log("step up=%s", upperBoundFeeRatio - lowerBoundFeeRatio);
                        return (
                            ((upperBoundFeeRatio - lowerBoundFeeRatio) * smoothstep) / 1 ether + lowerBoundFeeRatio,
                            CollateralRatioZones(z)
                        );
                    } else {
                        // step down
                        // console.log("step down=%s", lowerBoundFeeRatio - upperBoundFeeRatio);
                        return (
                            ((lowerBoundFeeRatio - upperBoundFeeRatio) * (1 ether - smoothstep)) /
                                1 ether +
                                upperBoundFeeRatio,
                            CollateralRatioZones(z)
                        );
                    }
                }
            }
        }
        // console.log("bonus zone, fee=", _ratioEther(feeRatios[0]));
        return (_ratioEther(feeRatios[0]), CollateralRatioZones.bonus);
    }
*/
    // other calculations
    // ------------------

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

    function _leveragedTokenPrice(
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
            _leveragedTokenBalance($.leveragedToken),
            $.peggedTokenBalance,
            _collateralTokenBalance($.collateralToken),
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
        return
            _collateralRatio(
                _collateralTokenBalance($.collateralToken),
                _fetchSafePrice($.priceOracle),
                $.peggedTokenBalance
            );
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
