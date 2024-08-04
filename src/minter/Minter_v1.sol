// SPDX-License-Identifier: MIT
// coding standards by https://www.rareskills.io/post/solidity-style-guide
// and https://docs.soliditylang.org/en/latest/style-guide.html
pragma solidity 0.8.25;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransientUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";

import { WordCodec } from "src/common/WordCodec.sol";
import { Token } from "src/common/Token.sol";
import { AccessControl } from "src/common/TokenOwner.sol";

import { IMinter } from "src/minter/IMinter.sol";
import { IMintable, IBurnable, IBurnableFrom } from "src/minter/IMintable.sol";
import { IPriceOracle } from "src/price/IPriceOracle.sol";
import { IReservePool } from "src/minter/IReservePool.sol";

// import { console2 as console } from "forge-std/console2.sol";

import "test/clog.sol";

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
contract Minter_v1 is Initializable, UUPSUpgradeable, AccessControl, ReentrancyGuardTransientUpgradeable, IMinter {
    using SafeERC20 for IERC20;
    using WordCodec for bytes32;

    /********************************
     * Constants                    *
     ********************************/

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

    uint private constant maxBands = 8;
    uint private constant maxBounds = maxBands - 1;

    bytes32 public constant ZERO_FEE_ROLE = keccak256("ZERO_FEE_ROLE");

    /********************************
     * Storage                      *
     ********************************/

    // we use a struct here but implement our own storage within because solidity uses too many slots
    // slot accessors below
    struct ActionIncentive {
        bytes32 slot0;
        // uint32[7] collateralRatioUpperBounds;      0:223
        // uint8 collateralRatioBandCount;          224:231
        // bool depegBandAdded                      232:234
        bytes32 slot1;
        // int32[8] incentiveRatios;                  0:255
    }

    function _incentiveRatioToStorage(int256 ratio) private pure returns (int256) {
        int256 factor = int256(10 ** (18 - INCENTIVE_RATIO_DECIMALS));
        return ((ratio / factor) * factor);
    }

    function _collateralRatioToStorage(uint256 ratio) private pure returns (uint256) {
        uint256 factor = 10 ** (18 - COLLATERAL_RATIO_DECIMALS);
        return ((ratio / factor) * factor);
    }

    function _collateralRatioUpperBounds(ActionIncentive memory config_, uint index) private pure returns (uint256) {
        return config_.slot0.decodeUint(index * 32, 32) * 10 ** (18 - COLLATERAL_RATIO_DECIMALS);
    }
    function _setCollateralRatioUpperBounds(ActionIncentive memory config_, uint index, uint256 value) private pure {
        config_.slot0 = config_.slot0.encodeUint(value / 10 ** (18 - COLLATERAL_RATIO_DECIMALS), index * 32, 32);
    }
    function _collateralRatioBandCount(ActionIncentive memory config_) private pure returns (uint) {
        return config_.slot0.decodeUint(224, 8);
    }
    function _setCollateralRatioBandCount(ActionIncentive memory config_, uint value) private pure {
        config_.slot0 = config_.slot0.encodeUint(value, 224, 8);
    }
    function _depegBandAdded(ActionIncentive memory config_) private pure returns (bool) {
        return config_.slot0.decodeBool(232);
    }
    function _setDepegBandAdded(ActionIncentive memory config_, bool value) private pure {
        config_.slot0 = config_.slot0.encodeBool(value, 232);
    }
    function _incentiveRatio(ActionIncentive memory config_, uint index) private pure returns (int256) {
        return config_.slot1.decodeInt(index * 32, 32) * int256(10 ** (18 - INCENTIVE_RATIO_DECIMALS));
    }
    function _setIncentiveRatio(ActionIncentive memory config_, uint index, int256 value) private pure {
        config_.slot1 = config_.slot1.encodeInt(value / int256(10 ** (18 - INCENTIVE_RATIO_DECIMALS)), index * 32, 32);
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
        //                                             slot
        // we keep track of pegged tokens as they can be minted through other rmeans
        uint256 peggedTokenBalance; //                  256
        //                                             slot
        // TODO: do we want a collateral cap?
        //                                             slot
        address priceOracle; //                         160
        //                                             slot
        address feeReceiver; //                         160
        //                                              slot*2
        uint256 rebalanceCollateralRatioUpperBound; // the upper collateral ratio at which rebalancing begins
        uint256 harvestCollateralRatioUpperBound; // above this harvesting of collateral can begin
        //                                             slot*2
        ActionIncentive mintPeggedIncentiveConfig;
        //                                             slot*2
        ActionIncentive redeemPeggedIncentiveConfig;
        //                                             slot*2
        ActionIncentive mintLeveragedIncentiveConfig;
        //                                             slot*2
        ActionIncentive redeemLeveragedIncentiveConfig;
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

    /********************************
     * Initialisation               *
     ********************************/

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
        __ReentrancyGuardTransient_init();

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
        return interfaceId == type(IMinter).interfaceId || super.supportsInterface(interfaceId);
    }

    /********************************
     * Public View Functions        *
     ********************************/

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

    function reservePool() external view returns (address) {
        MinterStorage storage $ = _getMinterStorage();
        return $.reservePool;
    }

    function peggedTokenBalance() external view override returns (uint256) {
        MinterStorage storage $ = _getMinterStorage();
        return $.peggedTokenBalance;
    }

    function leveragedTokenBalance() external view override returns (uint256) {
        MinterStorage storage $ = _getMinterStorage();
        return _leveragedTokenBalance($.leveragedToken);
    }

    function collateralTokenBalance() external view override returns (uint256) {
        MinterStorage storage $ = _getMinterStorage();
        return _collateralTokenBalance($.collateralToken);
    }

    function config() public view returns (Config memory config_) {
        MinterStorage storage $ = _getMinterStorage();
        config_.rebalanceCollateralRatioUpperBound = $.rebalanceCollateralRatioUpperBound;
        config_.harvestCollateralRatioUpperBound = $.harvestCollateralRatioUpperBound;
        config_.mintPeggedIncentiveConfig = _copyBandsBack($.mintPeggedIncentiveConfig);
        config_.mintLeveragedIncentiveConfig = _copyBandsBack($.mintLeveragedIncentiveConfig);
        config_.redeemPeggedIncentiveConfig = _copyBandsBack($.redeemPeggedIncentiveConfig);
        config_.redeemLeveragedIncentiveConfig = _copyBandsBack($.redeemLeveragedIncentiveConfig);
    }

    function rebalanceCollateralRatio() external view returns (uint256) {
        MinterStorage storage $ = _getMinterStorage();
        return $.rebalanceCollateralRatioUpperBound;
    }

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

    function leverageRatio() external view override returns (uint256) {
        MinterStorage storage $ = _getMinterStorage();
        return
            _leverageRatio(
                _collateralTokenBalance($.collateralToken),
                _fetchSafePrice($.priceOracle),
                $.peggedTokenBalance
            );
    }

    // @InheritDoc IMinter
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

    // @InheritDoc IMinter
    function peggedTokenPrice() external view override returns (uint256 nav) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 price = _fetchSafePrice($.priceOracle);
        nav = _peggedTokenPrice($.peggedTokenBalance, _collateralTokenBalance($.collateralToken), price);
    }

    function leverageTokensForCollateral(
        uint256 forCollateral
    ) external view override returns (uint256 leveragedTokens) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 price = _fetchSafePrice($.priceOracle);
        leveragedTokens = _leveragedTokensForCollateral(
            forCollateral,
            _leveragedTokenBalance($.leveragedToken),
            $.peggedTokenBalance,
            _collateralTokenBalance($.collateralToken),
            price
        );
    }

    // @InheritDoc IMinter
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

    // @InheritDoc IMinter
    function redeemPeggedForCollateralRatio(
        uint256 targetCollateralRatio
    ) external view returns (uint256 peggedTokens) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 collateralPrice = _fetchMaxPrice($.priceOracle);
        uint256 collateralTokenBalance_ = _collateralTokenBalance($.collateralToken);
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        if (targetCollateralRatio > _collateralRatio(collateralTokenBalance_, collateralPrice, peggedTokenBalance_)) {
            peggedTokens = _redeemPeggedForCollateralRatio(
                targetCollateralRatio,
                collateralTokenBalance_,
                collateralPrice,
                peggedTokenBalance_
            );
        } else {
            peggedTokens = 0;
        }
    }

    // @InheritDoc IMinter
    function swapPeggedForLeveragedForCollateralRatio(
        uint256 targetCollateralRatio
    ) external view returns (uint256 peggedTokens) {
        MinterStorage storage $ = _getMinterStorage();
        // TODO: check the price - redeeming pegged is at max price, minting leveraged is at safe price
        uint256 collateralPrice = _fetchMaxPrice($.priceOracle);
        uint256 collateralTokenBalance_ = _collateralTokenBalance($.collateralToken);
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        if (targetCollateralRatio > _collateralRatio(collateralTokenBalance_, collateralPrice, peggedTokenBalance_)) {
            // from the definition of collateral ratio with no change in collateral only change in pegged
            peggedTokens = peggedTokenBalance_ - (collateralTokenBalance_ * collateralPrice) / targetCollateralRatio;
        } else {
            peggedTokens = 0;
        }
    }

    // incentive ratios
    // ----------------

    function mintPeggedTokenIncentiveRatio() external view override returns (int256 incentiveRatio) {
        MinterStorage storage $ = _getMinterStorage();
        ActionIncentive memory config_ = $.mintPeggedIncentiveConfig;
        uint band = _findBand(
            config_,
            _collateralTokenBalance($.collateralToken),
            _fetchSafePrice($.priceOracle),
            $.peggedTokenBalance,
            false
        );
        incentiveRatio = _incentiveRatio(config_, band);
    }

    function redeemPeggedTokenIncentiveRatio() external view override returns (int256 incentiveRatio) {
        MinterStorage storage $ = _getMinterStorage();
        ActionIncentive memory config_ = $.redeemPeggedIncentiveConfig;
        uint band = _findBand(
            config_,
            _collateralTokenBalance($.collateralToken),
            _fetchMaxPrice($.priceOracle),
            $.peggedTokenBalance,
            false
        );
        incentiveRatio = _incentiveRatio(config_, band);
    }

    function mintLeveragedTokenIncentiveRatio() external view override returns (int256 incentiveRatio) {
        MinterStorage storage $ = _getMinterStorage();
        // TODO: do we need safe price for this?
        ActionIncentive memory config_ = $.mintLeveragedIncentiveConfig;
        // just want the fee/bonus at the current collateral
        uint band = _findBand(
            config_,
            _collateralTokenBalance($.collateralToken),
            _fetchSafePrice($.priceOracle),
            $.peggedTokenBalance,
            false
        );
        incentiveRatio = _incentiveRatio(config_, band);
    }

    function redeemLeveragedTokenIncentiveRatio() external view override returns (int256 incentiveRatio) {
        MinterStorage storage $ = _getMinterStorage();
        ActionIncentive memory config_ = $.redeemLeveragedIncentiveConfig;
        incentiveRatio = 0;
        uint band = _findBand(
            config_,
            _collateralTokenBalance($.collateralToken),
            _fetchMinPrice($.priceOracle),
            $.peggedTokenBalance,
            false
        );
        incentiveRatio = _incentiveRatio(config_, band);
    }

    // dry run functions

    function mintPeggedTokenDryRun(
        uint256 collateralIn
    )
        external
        view
        returns (
            int256 incentiveRatio,
            uint256 collateralUsed,
            uint256 peggedMinted,
            uint256 fee,
            uint256 reserveCollateralUsed,
            uint256 price
        )
    {
        // c.log("mintPeggedTokenDryRun...");
        MinterStorage storage $ = _getMinterStorage();
        price = _fetchSafePrice($.priceOracle);
        (fee, collateralUsed) = _mintPeggedAdjustments(
            $.mintPeggedIncentiveConfig,
            collateralIn,
            _collateralTokenBalance($.collateralToken),
            price,
            $.peggedTokenBalance
        );
        incentiveRatio = int256(collateralUsed == 0 ? 1 ether : (fee * 1 ether) / collateralUsed);
        peggedMinted = ((collateralUsed - fee) * price) / 1 ether;
        reserveCollateralUsed = 0;
    }

    function redeemPeggedTokenDryRun(
        uint256 peggedIn
    )
        public
        view
        returns (
            int256 incentiveRatio,
            uint256 peggedRedeemed,
            uint256 collateralReturned,
            uint256 fee,
            uint256 reserveCollateralUsed,
            uint256 price
        )
    {
        MinterStorage storage $ = _getMinterStorage();
        price = _fetchMaxPrice($.priceOracle);
        address collateralToken_ = $.collateralToken;
        uint256 peggedFee;
        (peggedFee, peggedRedeemed, reserveCollateralUsed) = _redeemPeggedAdjustments(
            $.redeemPeggedIncentiveConfig,
            peggedIn,
            _collateralTokenBalance(collateralToken_),
            price,
            $.peggedTokenBalance,
            IERC20(collateralToken_).balanceOf($.reservePool)
        );
        fee = (peggedFee * 1 ether) / price;
        incentiveRatio = peggedRedeemed == 0
            ? int256(1 ether)
            : ((int256(fee) - int256(reserveCollateralUsed)) * int256(price)) / int256(peggedRedeemed);
        collateralReturned = ((peggedRedeemed - peggedFee) * 1 ether) / price + reserveCollateralUsed;
    }

    function mintLeveragedTokenDryRun(
        uint256 collateralIn
    )
        external
        view
        returns (
            int256 incentiveRatio,
            uint256 collateralUsed,
            uint256 leveragedMinted,
            uint256 fee,
            uint256 reserveCollateralUsed,
            uint256 price
        )
    {
        MinterStorage storage $ = _getMinterStorage();
        // TODO: do we need safe price for this?
        address collateralToken_ = $.collateralToken;
        uint256 collateralTokenBalance_ = _collateralTokenBalance(collateralToken_);
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        price = _fetchSafePrice($.priceOracle);
        (fee, reserveCollateralUsed) = _mintLeveragedAdjustments(
            $.mintLeveragedIncentiveConfig,
            collateralIn,
            collateralTokenBalance_,
            price,
            peggedTokenBalance_,
            IERC20(collateralToken_).balanceOf($.reservePool)
        );
        collateralUsed = collateralIn; // we never disallow minting leveraged tokens
        // c.log("collateralUsed", collateralUsed);
        incentiveRatio = ((int256(fee) - int256(reserveCollateralUsed)) * 1 ether) / int256(collateralUsed);
        // c.log("incentiveRatio", incentiveRatio);
        leveragedMinted = _leveragedTokensForCollateral(
            collateralIn + reserveCollateralUsed - fee,
            _leveragedTokenBalance($.leveragedToken),
            peggedTokenBalance_,
            collateralTokenBalance_,
            price
        );
        // c.log("leveragedMinted", leveragedMinted);
    }

    function redeemLeveragedTokenDryRun(
        uint256 leveragedIn
    )
        external
        view
        returns (
            int256 incentiveRatio,
            uint256 leveragedRedeemed,
            uint256 collateralReturned,
            uint256 fee,
            uint256 reserveCollateralUsed,
            uint256 price
        )
    {
        MinterStorage storage $ = _getMinterStorage();
        // TODO: what to do if leveragedTokenBalance_ == 0
        price = _fetchMinPrice($.priceOracle);
        (fee, leveragedRedeemed, collateralReturned) = _redeemLeveragedAdjustments(
            $.redeemLeveragedIncentiveConfig,
            leveragedIn,
            _collateralTokenBalance($.collateralToken),
            price,
            $.peggedTokenBalance,
            _leveragedTokenBalance($.leveragedToken)
        );
        reserveCollateralUsed = 0; // TODO: remove this result?
        incentiveRatio = int256(collateralReturned == 0 ? 1 ether : (fee * 1 ether) / collateralReturned);
    }

    /********************************
     * Public Mutator Functions     *
     ********************************/

    function updateConfig(Config calldata config_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _updateConfig(config_);
    }

    function updatePriceOracle(address priceOracle_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _updatePriceOracle(priceOracle_);
    }

    function updateFeeReceiver(address feeReceiver_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _updateFeeReceiver(feeReceiver_);
    }

    function updateReservePool(address reservePool_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _updateReservePool(reservePool_);
    }

    // minting/redeeming pegged/leveraged tokens
    // -----------------------------------------

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
            $.mintPeggedIncentiveConfig,
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

        if (fee > 0) {
            // c.log("transfer fee", fee);
            IERC20(collateralToken_).safeTransfer($.feeReceiver, fee);
        }
        // update our records
        $.peggedTokenBalance = peggedTokenBalance_ + peggedTokenOut;
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
        uint256 peggedFee;
        (peggedFee, peggedIn, collateralOut) = _redeemPeggedAdjustments(
            $.redeemPeggedIncentiveConfig,
            peggedIn,
            _collateralTokenBalance(collateralToken_),
            price,
            peggedTokenBalance_,
            IERC20(collateralToken_).balanceOf($.reservePool)
        );
        // add any extra collateral
        if (collateralOut > 0) {
            // it's a discount
            // collect the extra collateral, if availablex
            // wake-disable-next-line reentrancy // reservePool is trusted and reentrancy guard
            collateralOut = IReservePool($.reservePool).requestBonus(collateralToken_, address(this), collateralOut);
        }
        // add the redeemed pegged minus the fees
        collateralOut += ((peggedIn - peggedFee) * 1 ether) / price;

        // make sure it meets the minimum requirements
        if (collateralOut < minCollateralOut) {
            revert ReturnInsufficientAmount(collateralToken_, minCollateralOut, collateralOut);
        }

        // redeem pegged tokens and send the remainder of the collateral
        _redeemPeggedToken(peggedToken_, peggedIn, collateralToken_, collateralOut, recipient);

        if (peggedFee > 0) {
            // send the fee
            IERC20(collateralToken_).safeTransfer($.feeReceiver, (peggedFee * 1 ether) / price);
        }

        // update our records
        $.peggedTokenBalance = peggedTokenBalance_ - peggedIn;
    }

    /// @inheritdoc IMinter
    function mintLeveragedToken(
        uint256 collateralIn,
        address recipient,
        uint256 minLeveragedTokenOut
    ) external override nonReentrant returns (uint256 leveragedTokenOut) {
        MinterStorage storage $ = _getMinterStorage();
        address collateralToken_ = $.collateralToken;
        collateralIn = Token.allOf(_msgSender(), collateralToken_, collateralIn);
        // c.log("collateralIn", collateralIn);
        uint256 price = _fetchSafePrice($.priceOracle);
        // c.log("price", price);

        address leveragedToken_ = $.leveragedToken;

        uint256 collateralTokenBalance_ = _collateralTokenBalance(collateralToken_);
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        (uint256 fee, uint256 extraCollateral) = _mintLeveragedAdjustments(
            $.mintLeveragedIncentiveConfig,
            collateralIn,
            collateralTokenBalance_,
            price,
            peggedTokenBalance_,
            IERC20(collateralToken_).balanceOf($.reservePool)
        );
        // c.log("fee, extraCollateral", fee, extraCollateral);
        // net out the fee & extra collateral
        if (extraCollateral > 0) {
            // it's a discount
            // collect the extra collateral, if available
            // wake-disable-next-line reentrancy // reservePool is trusted
            extraCollateral = IReservePool($.reservePool).requestBonus(
                collateralToken_,
                address(this),
                extraCollateral
            );
        }
        // work out how many leveraged tokens are to be minted (including the discount)
        leveragedTokenOut = _leveragedTokensForCollateral(
            collateralIn + extraCollateral - fee,
            _leveragedTokenBalance(leveragedToken_),
            peggedTokenBalance_,
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
        if (fee > 0) {
            IERC20(collateralToken_).safeTransfer($.feeReceiver, fee);
        }
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

        // c.log("leveragedIn", leveragedIn);
        uint256 fee;
        (fee, leveragedIn, collateralOut) = _redeemLeveragedAdjustments(
            $.redeemLeveragedIncentiveConfig,
            leveragedIn,
            collateralTokenBalance_,
            price,
            peggedTokenBalance_,
            leveragedTokenBalance_
        );
        // c.log("leveragedIn", leveragedIn);

        if (collateralOut < minCollateralOut) {
            revert ReturnInsufficientAmount(collateralToken_, minCollateralOut, collateralOut);
        }

        _redeemLeveragedToken(leveragedToken_, leveragedIn, collateralToken_, collateralOut, recipient);

        if (fee > 0) {
            // send the fee
            IERC20(collateralToken_).safeTransfer($.feeReceiver, fee);
        }
    }

    /********************************
     * Restricted Mutator Functions *
     ********************************/

    // fee-free minting/redeeming pegged/leveraged tokens
    // --------------------------------------------------

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

    // @inheritdoc IMinter
    function freeRedeemPeggedToken(
        uint256 peggedIn,
        address recipient
    ) external override nonReentrant onlyRole(ZERO_FEE_ROLE) returns (uint256 collateralOut) {
        MinterStorage storage $ = _getMinterStorage();
        address collateralToken_ = $.collateralToken;
        address peggedToken_ = $.peggedToken;
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        peggedIn = Token.allOf(_msgSender(), peggedToken_, peggedIn);
        peggedIn = _redeemable(peggedToken_, peggedIn, peggedTokenBalance_);

        uint256 price = _fetchMaxPrice($.priceOracle);
        collateralOut = (peggedIn * 1 ether) / price;

        // burn pegged tokens and send the collateral to the receiver
        _redeemPeggedToken(peggedToken_, peggedIn, collateralToken_, collateralOut, recipient);

        // update our records
        $.peggedTokenBalance = peggedTokenBalance_ - peggedIn;
    }

    function freeSwapPeggedForLeveraged(
        uint256 peggedIn,
        address recipient
    ) external override nonReentrant onlyRole(ZERO_FEE_ROLE) returns (uint256 leveragedOut) {
        MinterStorage storage $ = _getMinterStorage();
        address collateralToken_ = $.collateralToken;
        address peggedToken_ = $.peggedToken;
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        address leveragedToken_ = $.leveragedToken;

        peggedIn = Token.allOf(_msgSender(), peggedToken_, peggedIn);
        peggedIn = _redeemable(peggedToken_, peggedIn, peggedTokenBalance_);

        uint256 price = _fetchSafePrice($.priceOracle);

        leveragedOut = _leveragedTokensForCollateral(
            (peggedIn * 1 ether) / price,
            _leveragedTokenBalance(leveragedToken_),
            $.peggedTokenBalance,
            _collateralTokenBalance(collateralToken_),
            price
        );

        // burn pegged tokens and send the collateral
        _swapPeggedForLeveraged(peggedToken_, peggedIn, leveragedToken_, leveragedOut, recipient);

        // update our records
        $.peggedTokenBalance = peggedTokenBalance_ - peggedIn;
    }

    // @inheritdoc IMinter
    function freeMintLeveragedToken(
        uint256 collateralIn,
        address recipient
    ) external override onlyRole(ZERO_FEE_ROLE) nonReentrant returns (uint256 leveragedTokenOut) {
        MinterStorage storage $ = _getMinterStorage();
        // how much collateral to use
        address collateralToken_ = $.collateralToken;
        collateralIn = Token.allOf(_msgSender(), collateralToken_, collateralIn);

        // mint the tokens to the recipient
        address leveragedToken_ = $.leveragedToken;
        leveragedTokenOut = _leveragedTokensForCollateral(
            collateralIn,
            _leveragedTokenBalance(leveragedToken_),
            $.peggedTokenBalance,
            _collateralTokenBalance(collateralToken_),
            _fetchSafePrice($.priceOracle)
        );

        _mintLeveragedToken(collateralToken_, collateralIn, leveragedToken_, leveragedTokenOut, recipient);
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

    /********************************
     * Private functions            *
     ********************************/

    // Config
    // ------

    /**
     * @param config_ is the user friendly config being checked and copied
     * @param disallowNotDiscount if true then the config may have a disallow and not a discount
     * @return out the storage efficient config
     */
    function _checkAndCopyBands(
        IncentiveConfig calldata config_,
        bool disallowNotDiscount
    ) private pure returns (ActionIncentive memory out) {
        // check the array sizes match
        if (config_.incentiveRatios.length < 1) {
            revert TooFewIncentiveRatios(config_.incentiveRatios.length, 1);
        }
        if (config_.incentiveRatios.length != config_.collateralRatioBandUpperBounds.length + 1) {
            revert CollateralRatioBoundsIncentivesLengthsMismatch(
                config_.collateralRatioBandUpperBounds.length,
                config_.incentiveRatios.length
            );
        }

        uint256 prevUpperBound = 0;
        uint iOut = 0;
        _setDepegBandAdded(out, false);
        for (uint i = 0; i < config_.incentiveRatios.length; i++) {
            int256 incentiveRatio = _incentiveRatioToStorage(config_.incentiveRatios[i]);
            if (incentiveRatio != config_.incentiveRatios[i]) {
                revert IncentiveRatioTooPrecise(config_.incentiveRatios[i]);
            }
            // check the incentive array values given
            // if disallowNotDiscount (i.e. mint pegged or redeem leveraged)
            // then check against interval [0, 1] i.e. zero fees to some fees to disallow (100% fees)
            // else check against interval (-1, 1) i.e. some discount to zero to some fees
            if (disallowNotDiscount) {
                // TODO: check these after they have been cycled through the storage
                if (incentiveRatio < 0 ether || incentiveRatio > 1 ether) {
                    revert InvalidIncentiveRatioValue(config_.incentiveRatios[i]);
                }
                // disallows, if they exist, must be at index 0
                if (incentiveRatio == 1 ether && i != 0) {
                    revert InvalidIncentiveRatioValue(config_.incentiveRatios[i]);
                }
            } else {
                // discountNotDisallow
                if (incentiveRatio <= -1 ether || incentiveRatio >= 1 ether) {
                    revert InvalidIncentiveRatioValue(config_.incentiveRatios[i]);
                }
            }

            // check collateral ratio upper bounds are strictly increasing and then copy
            // also, as the pegged price changes at a collateralRatio < 1, we insert an extra boundary at that level
            // but only if one doesn't already exist.
            // if we didn't do it here, we would have to do it in each of the fee calculation functions
            uint256 currentUpperBound;
            if (i < config_.collateralRatioBandUpperBounds.length) {
                currentUpperBound = _collateralRatioToStorage(config_.collateralRatioBandUpperBounds[i]);
                if (currentUpperBound != config_.collateralRatioBandUpperBounds[i]) {
                    revert CollateralRatioBoundTooPrecise(config_.collateralRatioBandUpperBounds[i]);
                }
                // must be strictly increasing
                if (currentUpperBound <= prevUpperBound) {
                    revert InvalidCollateralRatioBoundValue(
                        config_.collateralRatioBandUpperBounds[i],
                        i == 0 ? 0 : config_.collateralRatioBandUpperBounds[i - 1]
                    );
                }
            } else {
                currentUpperBound = type(uint256).max;
            }
            // check for missing depeg boundary and add one unless there is already one
            // also don't add a depeg boundary if it is a disallow band
            if (prevUpperBound < 1 ether && currentUpperBound > 1 ether && incentiveRatio != 1 ether) {
                // this is the band that needs to be split
                // use the same incentive ratio on each side of the split
                _setIncentiveRatio(out, iOut, incentiveRatio);
                _setCollateralRatioUpperBounds(out, iOut, 1 ether);
                _setDepegBandAdded(out, true);
                iOut++;
            }

            _setIncentiveRatio(out, iOut, incentiveRatio);
            if (i < config_.collateralRatioBandUpperBounds.length) {
                _setCollateralRatioUpperBounds(out, iOut, currentUpperBound);
                prevUpperBound = currentUpperBound;
            }
            iOut++;
        }

        if (iOut > maxBands) {
            revert TooManyIncentiveRatios(config_.incentiveRatios.length, maxBands);
        }

        _setCollateralRatioBandCount(out, iOut);
    }

    function _copyBandsBack(ActionIncentive memory config_) private pure returns (IncentiveConfig memory out) {
        uint iOut = 0;
        uint outBands = _collateralRatioBandCount(config_);
        if (_depegBandAdded(config_)) outBands--;
        out.collateralRatioBandUpperBounds = new uint256[](outBands - 1);
        out.incentiveRatios = new int256[](outBands);
        for (uint i = 0; i < _collateralRatioBandCount(config_) - 1; i++) {
            if (!(_depegBandAdded(config_) && _collateralRatioUpperBounds(config_, i) == 1 ether)) {
                out.collateralRatioBandUpperBounds[iOut] = _collateralRatioUpperBounds(config_, i);
                out.incentiveRatios[iOut] = _incentiveRatio(config_, i);
                iOut++;
            }
        }
        out.incentiveRatios[iOut] = _incentiveRatio(config_, _collateralRatioBandCount(config_) - 1);
    }

    function _updateConfig(Config calldata config_) private {
        // TODO: check rebalance pools are exhausted before discounts are handed out?
        // or is this handled by the fact that the CR for discount is much lower than the rebalance CR
        emit UpdateConfig(config_); // the code below may alter the config so emit it soon

        MinterStorage storage $ = _getMinterStorage();

        // action config
        // TODO: consider making those 32 bit and packing them with the address of the rebalance pools/ harvest beneficiary
        $.rebalanceCollateralRatioUpperBound = config_.rebalanceCollateralRatioUpperBound;
        $.harvestCollateralRatioUpperBound = config_.harvestCollateralRatioUpperBound;

        // incentive config
        $.mintPeggedIncentiveConfig = _checkAndCopyBands(config_.mintPeggedIncentiveConfig, true);
        $.mintLeveragedIncentiveConfig = _checkAndCopyBands(config_.mintLeveragedIncentiveConfig, false);
        $.redeemPeggedIncentiveConfig = _checkAndCopyBands(config_.redeemPeggedIncentiveConfig, false);
        $.redeemLeveragedIncentiveConfig = _checkAndCopyBands(config_.redeemLeveragedIncentiveConfig, true);
    }

    // Price Oracle
    // ------------

    function _updatePriceOracle(address priceOracle_) private {
        MinterStorage storage $ = _getMinterStorage();
        address old = $.priceOracle;
        $.priceOracle = priceOracle_;
        emit UpdatePriceOracle(old, priceOracle_);
    }

    // Fee Receiver
    // ------------

    function _updateFeeReceiver(address feeReceiver_) private {
        MinterStorage storage $ = _getMinterStorage();
        address old = $.feeReceiver;
        $.feeReceiver = feeReceiver_;
        emit UpdateFeeReceiver(old, feeReceiver_);
    }

    // ReservePool
    // -----------

    function _updateReservePool(address reservePool_) private {
        MinterStorage storage $ = _getMinterStorage();
        address old = $.reservePool;
        $.reservePool = reservePool_;
        emit UpdateReservePool(old, reservePool_);
    }

    // Mint/Redeem Pegged/Leveraged
    // ----------------------------

    /*
    function _proRatedRatio(
        uint256 lowerCollateralRatio,
        uint256 upperCollateralRatio,
        ActionIncentive memory config_
    ) private pure returns (int256 incentiveRatio) {
        incentiveRatio = 0;
        // find the index, l, where lowerCollateralRatio falls
        uint l;
        // c.log("      collateralRatioBandCount - 1", collateralRatioBandCount(config_) - 1);
        for (l = 0; l < collateralRatioBandCount(config_) - 1; l++) {
            if (lowerCollateralRatio <= _collateralRatioUpperBounds(config_, l)) {
                // c.log(
                //     "      lowerCollateralRatio, collateralRatioUpperBounds[%s]",
                //     lowerCollateralRatio,
                //     l,
                //     _collateralRatioUpperBounds(config_, l)
                // );
                break;
            }
        }
        // find the index, u, where upperCollateralRatio falls
        uint u;
        for (u = l; u < collateralRatioBandCount(config_) - 1; u++) {
            if (upperCollateralRatio <= _collateralRatioUpperBounds(config_, u)) {
                // c.log(
                //     "      upperCollateralRatio, collateralRatioUpperBounds[%s]",
                //     lowerCollateralRatio,
                //     u,
                //     _collateralRatioToEther(collateralRatioUpperBounds[u])
                // );
                break;
            }
        }

        // Calculate pro-rated fee
        if (l == u) {
            incentiveRatio = _incentiveRatio(config_, l);
            // c.log("      incentiveRatio, u=l", uint256(incentiveRatio), l);
        } else {
            // Calculate pro-rated fee for the portion of lowerCollateralRatio in band l
            incentiveRatio = (int256(_collateralRatioUpperBounds(config_, l) - lowerCollateralRatio + 1) *
                _incentiveRatio(config_, l));
            // c.log("     incentiveRatioeRatio, l", uint256(incentiveRatio), l);

            // Calculate pro-rated fee for the full intervals between l and u
            for (uint256 k = l + 1; k < u; k++) {
                incentiveRatio += (int256(_collateralRatioUpperBounds(config_, k) - _collateralRatioUpperBounds(config_, k + 1)) *
                    _incentiveRatio(config_, k));
                // c.log("      incentiveRatio, k", uint256(incentiveRatio), l);
            }

            // Calculate pro-rated fee for the portion of upperCollateralRatio in band u
            incentiveRatio += (int256(upperCollateralRatio - _collateralRatioUpperBounds(config_, u - 1)) *
                _incentiveRatio(config_, u));
            // c.log("      incentiveRatio, u", uint256(incentiveRatio), l);
            incentiveRatio /= int256(upperCollateralRatio - lowerCollateralRatio); // Normalize fee based on range
            // c.log("      incentiveRatio", uint256(incentiveRatio));
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

    function _mintPeggedToken(
        address collateralToken_,
        uint256 collateralIn,
        address peggedToken_,
        uint256 peggedTokenOut,
        address recipient
    ) private {
        emit MintPeggedToken(_msgSender(), recipient, collateralIn, peggedTokenOut);

        // mint the tokens to the recipient
        // wake-disable-next-line reentrancy // all callers to this function have nonReentrant guard
        IMintable(peggedToken_).mint(recipient, peggedTokenOut);
        // c.log("transfer pegged", peggedTokenOut);
        // take the collateral
        IERC20(collateralToken_).safeTransferFrom(_msgSender(), address(this), collateralIn);
        // c.log("transfer collateralIn", collateralIn);
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
        // c.log("transfer peggedIn to minter", peggedIn);
        IERC20(peggedToken_).safeTransferFrom(_msgSender(), address(this), peggedIn);
        // wake-disable-next-line reentrancy // all callers to this function have nonReentrant guard
        // c.log("burn peggedIn", peggedIn);
        IBurnable(peggedToken_).burn(peggedIn);
        // return the collateral
        // c.log("transfer collateralOut", collateralOut);
        IERC20(collateralToken_).safeTransfer(recipient, collateralOut);
    }

    function _swapPeggedForLeveraged(
        address peggedToken_,
        uint256 peggedIn,
        address leveragedToken_,
        uint256 leveragedOut,
        address recipient
    ) private {
        // tell the world
        emit SwapPeggedForLeveraged(_msgSender(), recipient, peggedIn, leveragedOut);
        // burn the tokens from the sender - get them first then burn them
        IERC20(peggedToken_).safeTransferFrom(_msgSender(), address(this), peggedIn);
        // wake-disable-next-line reentrancy // all callers to this function have nonReentrant guard
        IBurnable(peggedToken_).burn(peggedIn);

        // mint the tokens to the recipient
        // wake-disable-next-line reentrancy
        IMintable(leveragedToken_).mint(recipient, leveragedOut);
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
        // wake-disable-next-line reentrancy
        IMintable(leveragedToken_).mint(recipient, leveragedTokenOut);
        // c.log("transfer leveraged out", leveragedTokenOut);
        // take the collateral
        IERC20(collateralToken_).safeTransferFrom(_msgSender(), address(this), collateralIn);
        // c.log("transfer collateral in", collateralIn);
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
        // wake-disable-next-line reentrancy // leveragedToken is trusted
        IBurnableFrom(leveragedToken_).burnFrom(_msgSender(), leveragedIn);
        // return the collateral
        IERC20(collateralToken_).safeTransfer(recipient, collateralOut);
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

    // Adjustments - fees, bonuses and disallows
    // -----------------------------------------

    /**
     * @notice calculates the fee or bonuses relating to the different incentiveRatios
     * It calculates the proportion, in collateral space, the transition from one collateral ratio boundary to another
     * and performs a weighted sum of the fee ratios. It essentially performs a definite integral of the fee function.
     * @param config_ is the collateral ratio boundaries and the fee ratios within each boundary
     * @param collateralIn the proposed amount of collateral being posted in exchange for pegged tokens
     * @param collateralTokenBalance_ is the amount of collateral held. This is used to calculate collateral ratios
     * @param price the value of a collateral token in terms of the pegged token.
     * @param peggedTokenBalance_ is the amount of pegged tokens issued. This is used to calculate collateral ratios
     * @return fee the pro-rated fee
     * @return maxCollateral the amount of collateral that is allowed, according to the config
     */
    function _mintPeggedAdjustments(
        ActionIncentive memory config_,
        uint256 collateralIn,
        uint256 collateralTokenBalance_,
        uint256 price,
        uint256 peggedTokenBalance_
    ) private pure returns (uint256 fee, uint256 maxCollateral) {
        // c.log("_mintPeggedAdjustments...");
        // c.log("collateralIn", collateralIn);
        // c.log("collateralTokenBalance_", collateralTokenBalance_);
        // c.log("price", price);
        // c.log("peggedTokenBalance_", peggedTokenBalance_);
        // we cannot calculate collateral ratio when there are no pegged tokens as it's infinite i.e. (/0)
        if (peggedTokenBalance_ == 0) revert ActionPaused();
        // this calculation doesn't work if we are depegged
        if (_isDepegged(collateralTokenBalance_, price, peggedTokenBalance_)) return (0, 0);

        // find the band and it's lower bound where the current collateral ratio is
        // (note we treat the disallow band as any other here, except that it is the terminal band)
        uint band = _findBand(config_, collateralTokenBalance_, price, peggedTokenBalance_, false);
        fee = 0;
        maxCollateral = 0;
        // simulate minting until we run out of collateral, adding the fee & collateral as we go
        while (true) {
            // c.log("band", band);
            uint256 bandLowerBound = _collateralRatioLowerBounds(config_, band);
            // c.log("bandLowerBound", bandLowerBound);
            uint256 bandFeeRatio = uint256(_incentiveRatio(config_, band)); // no discounts for this action
            // c.log("bandFeeRatio", bandFeeRatio);
            if (bandFeeRatio == 1 ether) {
                // fee ratio of 100% means the action is disallowed, and in the lowest band
                break;
            }

            // uint256 collateralInBand1 = ((collateralTokenBalance_ * price - bandLowerBound * peggedTokenBalance_) *
            //     1 ether) / (price * ((bandLowerBound * (1 ether - bandFeeRatio)) / 1 ether + bandFeeRatio - 1 ether));

            uint256 phi = (bandLowerBound * (1 ether - bandFeeRatio)) + bandFeeRatio * 1 ether - 1 ether * 1 ether;
            uint256 collateralInBand = (collateralTokenBalance_ * 1 ether * 1 ether) /
                phi -
                ((bandLowerBound * peggedTokenBalance_) * 1 ether * 1 ether) /
                (price * phi);
            // if (collateralInBand != collateralInBand1) {
            //     c.log("collateralInBand ", collateralInBand);
            //     c.log("collateralInBand1", collateralInBand1);
            //     revert("better calculation");
            // }
            collateralInBand = Math.min(collateralIn, collateralInBand);
            uint256 bandFee = (collateralInBand * bandFeeRatio) / 1 ether;
            maxCollateral += collateralInBand;
            fee += bandFee;
            collateralIn -= collateralInBand;
            if (collateralIn == 0) {
                // we haverun out of collateral for the simulation
                break;
            }
            // still some collateral left and we're allowed to mint or redeem, so simulate
            collateralTokenBalance_ += collateralInBand - bandFee;
            peggedTokenBalance_ += ((collateralInBand - bandFee) * price) / 1 ether;
            if (band == 0) {
                // we are now in the lowest band, so exit
                break;
            }
            band--;
        }
        // c.log("fee, maxCollateral", fee, maxCollateral);
    }

    /// @param peggedIn the given amount of peggedTokens
    /// @param collateralTokenBalance_ the amount of collateral held
    /// @param price the value in pegged of each collateal token
    /// @param peggedTokenBalance_ the balance of pegged tokens minted
    /// @param reservePoolBalance_ the current balance of the reserve pool
    /// @return peggedFee the fee charged in collateral tokens. the fee ratio is then 'fee' / ('collateralOut' + extraCollateral')
    /// @return peggedRedeemed the collateral returnable from 'peggedIn' pegged tokens. This has the fee deducted.
    /// @return extraCollateral the collateral to be got from the reserve pool

    function _redeemPeggedAdjustments(
        ActionIncentive memory config_,
        uint256 peggedIn,
        uint256 collateralTokenBalance_,
        uint256 price,
        uint256 peggedTokenBalance_,
        uint256 reservePoolBalance_
    ) private pure returns (uint256 peggedFee, uint256 peggedRedeemed, uint256 extraCollateral) {
        // c.log("_redeemPeggedAdjustments...");
        // c.log("peggedIn", peggedIn);
        // c.log("collateralTokenBalance_", collateralTokenBalance_);
        // c.log("price", price);
        // c.log("peggedTokenBalance_", peggedTokenBalance_);
        // c.log("reservePoolBalance_", reservePoolBalance_);
        // we cannot calculate collateral ratio when there are no pegged tokens as it's infinite i.e. (/0)
        if (peggedTokenBalance_ == 0) revert ActionPaused();
        // TODO: test for first mint of pegged, in the context of existing and non-existing leveraged tokens

        // simulate redeeming tokens from current collateral ratio upwards,
        // extracting the fee at the correct ratio as we go.
        // We do this band at a time, pro-rating the resulting fee according to how much collateral was needed in
        // each band entered. We use collateral to pro-rate, rather than collateral ratio which would be simpler, because
        // we multiply the resulting ratios by the collateral for the final fee
        uint band = _findBand(config_, collateralTokenBalance_, price, peggedTokenBalance_, true);
        // simulate redeeming until we run out of pegged tokens, adding the fee & bonus as we go
        while (true) {
            // c.log("band", band);
            int256 bandIncentiveRatio = _incentiveRatio(config_, band);
            // c.log("bandIncentiveRatio", bandIncentiveRatio);
            uint256 peggedInBand;
            if (band == _collateralRatioBandCount(config_) - 1) {
                // the last band goes on forever
                peggedInBand = peggedIn;
            } else {
                uint256 bandUpperBound = _collateralRatioUpperBounds(config_, band);
                if (bandUpperBound <= 1 ether) {
                    // how much pegged do we need to redeem to re-peg?
                    // given the price of the pegged is a proportionate share of the collateral and leveraged tokens are worthless
                    // we have to redeem all of it, so we should simply disallow redeeming de-pegged tokens.
                    break;
                } else {
                    peggedInBand = _redeemPeggedForCollateralRatio(
                        bandUpperBound,
                        collateralTokenBalance_,
                        price,
                        peggedTokenBalance_
                    );
                    // can't have more collateral in the band that there is collateral left
                    peggedInBand = Math.min(peggedIn, peggedInBand);
                }
            }
            peggedRedeemed += peggedInBand;
            if (bandIncentiveRatio > 0) {
                // tally the weighted fee ratios
                // TODO: remove those divisions till the end
                peggedFee += (peggedInBand * uint256(bandIncentiveRatio)) / 1 ether;
            } else if (bandIncentiveRatio < 0) {
                // any truncation below, benefits the
                uint256 extraCollateralInBand = (peggedInBand * uint256(-bandIncentiveRatio)) / price;
                // tally the discounts
                if (extraCollateralInBand <= reservePoolBalance_) {
                    reservePoolBalance_ -= extraCollateralInBand;
                } else {
                    extraCollateralInBand = reservePoolBalance_;
                    reservePoolBalance_ = 0;
                }
                extraCollateral += extraCollateralInBand;
            }

            peggedIn -= peggedInBand;
            if (peggedIn == 0) {
                // no pegged tokens left to simulate redeeming them
                break;
            }
            // still some pegged tokens left and we're allowed to redeem
            peggedTokenBalance_ -= peggedInBand;
            collateralTokenBalance_ -= (peggedInBand * 1 ether) / price;

            band++;
        }
        // c.log("peggedFee, peggedRedeemed, extraCollateral", peggedFee, peggedRedeemed, extraCollateral);
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
    //     // c.log("      targetCollateralRatio", targetCollateralRatio);
    //     // c.log("      collateralTokenBalance_", collateralTokenBalance_);
    //     // c.log("      price", price);
    //     // c.log("      peggedTokenBalance_", peggedTokenBalance_);
    //     // c.log("      incentiveRatio", uint256(incentiveRatio));

    //     collateralTokens =
    //         ((collateralTokenBalance_ * price - targetCollateralRatio * peggedTokenBalance_) * 1 ether) /
    //         uint256(
    //             int256(price) * ((int256(targetCollateralRatio) * (1 ether - incentiveRatio)) / 1 ether - 1 ether + incentiveRatio)
    //         );
    //     // c.log("      collateralTokens", collateralTokens);
    // }

    /**
     * @param collateralIn the given collateral, assumed to be > 0
     *
     */

    function _mintLeveragedAdjustments(
        ActionIncentive memory config_,
        uint256 collateralIn,
        uint256 collateralTokenBalance_,
        uint256 price,
        uint256 peggedTokenBalance_,
        uint256 reservePoolBalance_
    ) private pure returns (uint256 fee, uint256 extraCollateral) {
        // c.log("_mintLeveragedAdjustments...");
        // c.log("collateralIn", collateralIn);
        // c.log("collateralTokenBalance_", collateralTokenBalance_);
        // c.log("price", price);
        // c.log("peggedTokenBalance_", peggedTokenBalance_);
        // c.log("reservePoolBalance_", reservePoolBalance_);

        // we cannot calculate collateral ratio when there are no pegged tokens as it's infinite i.e. (/0)
        if (peggedTokenBalance_ == 0) revert ActionPaused();
        // TODO: test for first mint of pegged, in the context of existing and non-existing leveraged tokens
        // TODO: handle depegged situation, where leveraged token is worth 0 and pegged is worth it's share of collateral

        // simulate minting or redeeming tokens from current collateral ratio upwards or downwards,
        // extracting the fee at the correct ratio as we go.
        // We do this band at a time, pro-rating the resulting fee according to how much collateral was needed in
        // each band entered. We use collateral to pro-rate, rather than collateral ration which would be simpler, because
        // we multiply the resulting ratios by the collateral for the final fee
        uint band = _findBand(config_, collateralTokenBalance_, price, peggedTokenBalance_, true);

        // simulate minting until we run out of collateral, adding the fee & bonus as we go
        while (true) {
            // c.log("_collateralRatio", _collateralRatio(collateralTokenBalance_, price, peggedTokenBalance_));
            // c.log("band", band);
            uint256 bandUpperBound = _collateralRatioUpperBounds(config_, band);
            // c.log("bandUpperBound", bandUpperBound);
            int256 bandIncentiveRatio = _incentiveRatio(config_, band);
            // c.log("bandIncentiveRatio", bandIncentiveRatio);
            uint256 bandFeeRatio = uint256(SignedMath.max(0, bandIncentiveRatio));
            // c.log("bandFeeRatio", bandFeeRatio);

            uint256 collateralInBand;
            if (band == _collateralRatioBandCount(config_) - 1) {
                // the last band has no upper bound
                collateralInBand = collateralIn;
                // c.log("last band");
            } else {
                // the collateral needed to be deposited to reach the upper bound of the band
                // given the band fee is also deducted/added (as it may be a discount)
                // note that 1 - bandFeeRatio must always be positive
                // Note that we calculate the collateral in band even if there is insufficient
                // collateral in the reserve pool to meet the band incentive ratio target
                // TODO: add a test for this situation
                collateralInBand =
                    ((bandUpperBound * peggedTokenBalance_ - collateralTokenBalance_ * price) * 1 ether) /
                    (price * (1 ether - bandFeeRatio));
                // c.log("mid band collateralInBand", collateralInBand);
                // can't have more collateral in the band that there is collateral left
                collateralInBand = Math.min(collateralIn, collateralInBand);
            }
            // c.log("collateralInBand", collateralInBand);
            uint256 bandFee = 0;
            uint256 extraCollateralInBand = 0;
            if (bandIncentiveRatio > 0) {
                bandFee = (collateralInBand * uint256(bandIncentiveRatio)) / 1 ether;
                // c.log("bandFee", bandFee);
                // tally the weighted fee ratios
                fee += bandFee;
            } else if (bandIncentiveRatio < 0) {
                extraCollateralInBand = (collateralInBand * uint256(-bandIncentiveRatio)) / 1 ether;
                // c.log("extraCollateralInBand", extraCollateralInBand);
                // tally the discounts
                if (extraCollateralInBand <= reservePoolBalance_) {
                    reservePoolBalance_ -= extraCollateralInBand;
                    // TODO: recalculate the band incentive ratio
                } else {
                    extraCollateralInBand = reservePoolBalance_;
                    reservePoolBalance_ = 0;
                }
                extraCollateral += extraCollateralInBand;
            }
            collateralIn -= collateralInBand;
            if (collateralIn == 0) {
                // we have run out of collateral for the simulation
                // collateralTokenBalance_ += collateralInBand - bandFee + extraCollateralInBand;
                // c.log("collateralTokenBalance_", collateralTokenBalance_);
                // c.log("_collateralRatio", _collateralRatio(collateralTokenBalance_, price, peggedTokenBalance_));
                break;
            }
            // still some collateral left, so add this collateral to take us to the next band
            // here the reserve pool discount results in more collateral ending up in the minter
            collateralTokenBalance_ += collateralInBand - bandFee + extraCollateralInBand;
            // c.log("collateralTokenBalance_", collateralTokenBalance_);
            // c.log("_collateralRatio", _collateralRatio(collateralTokenBalance_, price, peggedTokenBalance_));

            band++;
        }
        // c.log("fee", fee);
        // c.log("extraCollateral", extraCollateral);
    }

    function _redeemLeveragedAdjustments(
        ActionIncentive memory config_,
        uint256 leveragedIn,
        uint256 startCollateralTokenBalance,
        uint256 price,
        uint256 peggedTokenBalance_,
        uint256 leveragedTokenBalance_
    ) private pure returns (uint256 fee, uint256 leveragedRedeemed, uint256 collateralOut) {
        // we cannot calculate collateral ratio when there are no pegged tokens as it's infinite i.e. (/0)
        if (peggedTokenBalance_ == 0) revert ActionPaused();
        // c.log("leveragedIn", leveragedIn);
        uint256 collateralIn = _collateralForLeveragedTokens(
            leveragedIn,
            leveragedTokenBalance_,
            peggedTokenBalance_,
            startCollateralTokenBalance,
            price
        );
        // c.log("collateralIn", collateralIn);
        // find the band and it's lower bound where the current collateral ratio is
        // (note we treat the disallow band as any other here, except that it is the terminal band)
        uint band = _findBand(config_, startCollateralTokenBalance, price, peggedTokenBalance_, false);
        // simulate redeeming until we run out of leveraged tokens, adding the fee & reserve collateral as we go
        fee = 0;
        collateralOut = 0;
        uint256 collateralTokenBalance_ = startCollateralTokenBalance;
        while (true) {
            // c.log("band", band);
            uint256 bandLowerBound = _collateralRatioLowerBounds(config_, band);
            // c.log("bandLowerBound", bandLowerBound);
            uint256 bandFeeRatio = uint256(_incentiveRatio(config_, band)); // no discounts for this action
            // c.log("bandFeeRatio", bandFeeRatio);
            if (bandFeeRatio == 1 ether) {
                // fee ratio of 100% means the action is disallowed, and in the lowest band
                break;
            }
            uint256 collateralInBand = (collateralTokenBalance_ * price - bandLowerBound * peggedTokenBalance_) / price;
            // c.log("collateralInBand", collateralInBand);
            collateralInBand = Math.min(collateralIn, collateralInBand);

            uint256 bandFee = (collateralInBand * uint256(bandFeeRatio)) / 1 ether;
            collateralOut += collateralInBand - bandFee;
            fee += bandFee;
            collateralIn -= collateralInBand;
            if (collateralIn == 0) {
                // we have run out of collateral
                break;
            }
            // still some collateral left and we're allowed to mint or redeem, so simulate
            collateralTokenBalance_ += collateralInBand;
            if (band == 0) {
                // we are now in the lowest band, so exit
                break;
            }
            band--;
        }
        // c.log("collateralOut=%$s", collateralOut);
        leveragedRedeemed = _leveragedTokensForCollateral(
            collateralOut + fee,
            leveragedTokenBalance_,
            peggedTokenBalance_,
            startCollateralTokenBalance,
            price
        );
        // c.log("leveragedRedeemed=%$s", leveragedRedeemed);
    }

    function _collateralRatioLowerBounds(ActionIncentive memory config_, uint index) private pure returns (uint256) {
        // if we are in the lowest band, the lower bound is 0
        // else its the previous upper bound
        return index == 0 ? 0 ether : _collateralRatioUpperBounds(config_, index - 1);
    }

    function _findBand(
        ActionIncentive memory config_,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice,
        uint256 peggedTokenBalance_,
        bool atLower
    ) private pure returns (uint band) {
        uint256 collateralRatio_ = _collateralRatio(collateralTokenBalance_, collateralPrice, peggedTokenBalance_);
        // c.log("findBand.collateralRatio", collateralRatio_);
        for (band = 0; band < _collateralRatioBandCount(config_) - 1; band++) {
            // c.log("findBand.band", band);
            // c.log(
            //     "findBand._collateralRatioUpperBounds(config_, band)",
            //     _collateralRatioUpperBounds(config_, band)
            // );
            uint256 bandUpperBound = _collateralRatioUpperBounds(config_, band);
            if (atLower) {
                if (collateralRatio_ < bandUpperBound) break;
            } else {
                if (collateralRatio_ <= bandUpperBound) break;
            }
        }
        // c.log("findBand.band.", band);
    }

    // TODO: add a function that shifts and scales on x and y and also inverts.
    // TODO: add a function that skews the x and y? so that y is 0.5 at some given intermediate point, not 0.5.
    //       This is to merge bonus and fees?
    //       Or to slowly ramp up fees as CR drops, and rapidly increase as it reaches the next CR config value

    // function _smoothstep(uint256 x, uint256 edge0, uint256 edge1) private pure returns (uint256 smoothstep) {
    //     // see https://en.wikipedia.org/wiki/Smoothstep for details on the below
    //     // input is in terms of collateral ratio which could be any number > 0
    //     // it need to be clamped between 0 and criticalCollateralRatio - 1
    //     // and as the output is 0 - 100% fee the clamping is normalised
    //     // c.log("newCollateralRatio", newCollateralRatio);

    //     // TODO: check this for very small x, because, e.g. x*x is even smaller.
    //     if (x <= edge0) {
    //         smoothstep = 0;
    //     } else if (x >= edge1) {
    //         smoothstep = 1 ether;
    //     } else {
    //         // scale 0 to 1 vs edge0 to edge1
    //         uint256 t = ((x - edge0) * 1 ether) / (edge1 - edge0);
    //         // do the smoothstep calculation
    //         // first order smooth
    //         // 3*x^2 - 2*x^3
    //         // slither-disable-next-line divide-before-multiply
    //         smoothstep = (t * t * (3 * 1 ether - 2 * t)) / (10 ** 36);
    //         /*
    //         uint256 x2 = (x * x) / (1 ether); // Normalize x^2
    //         smoothstep = (x2 * (3 ether - 2 * x)) / 1 ether;
    //         // second order smooth, unfortunately x^5 is likely to underflow, so we need to do more work to get this
    //         // 6*x^5 - 15*x^4 + 10*x^3
    //         // smoothstep = (((x2 * x2) / 1 ether) * (((x * (6 * x - 15 ether)) / 1 ether) + 10 ether)) / 1 ether;
    //         //                    -------------------            ----------------                --------
    //         //                                            ------------------------------------------------
    //         //                   ----------------------------------------------------
    //         */
    //     }
    // }

    // other calculations
    // ------------------

    // the price of a leveraged token in terms of the pegged token's underlying (i.e. USD for a USD pegged token)
    function _leveragedTokenPrice(
        uint256 leveragedTokenBalance_,
        uint256 peggedTokenBalance_,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice
    ) private pure returns (uint256 nav) {
        // if the collateral ratio is <= 1, nav is 0
        // slither-disable-next-line incorrect-equality
        if (leveragedTokenBalance_ == 0) {
            nav = 1 ether;
        } else {
            if (_isDepegged(collateralTokenBalance_, collateralPrice, peggedTokenBalance_)) {
                nav = 0;
            } else {
                // from the invariant collateral value = pegged value + leveraged value
                nav =
                    (collateralTokenBalance_ * collateralPrice - peggedTokenBalance_ * 1 ether) /
                    leveragedTokenBalance_;
            }
        }
    }

    // the price of a leveraged token in terms of the pegged token's underlying
    function _peggedTokenPrice(
        uint256 peggedTokenBalance_,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice
    ) private pure returns (uint256 nav) {
        // TODO if the collateral ratio is 0, nav is 0 - check that this doesn't just work out
        // slither-disable-next-line incorrect-equality
        if (peggedTokenBalance_ == 0) {
            nav = 1 ether;
        } else {
            if (_isDepegged(collateralTokenBalance_, collateralPrice, peggedTokenBalance_)) {
                // the nav becomes the value of the collateral
                nav = (collateralTokenBalance_ * collateralPrice) / peggedTokenBalance_;
            } else {
                // this is the invariant collateral value  = pegged value + leveraged value
                nav = 1 ether;
            }
        }
    }

    /**
     * @dev pegged value must not be greater than collateral value, i.e. it's depegged
     */
    function _leveragedTokensForCollateral(
        uint256 forCollateral,
        uint256 leveragedTokenBalance_,
        uint256 peggedTokenBalance_,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice
    ) private pure returns (uint256 leveragedTokens) {
        // c.log("_leveragedTokensForCollateral...");
        // c.log("forCollateral", forCollateral);
        // c.log("leveragedTokenBalance_", leveragedTokenBalance_);
        // c.log("peggedTokenBalance_", peggedTokenBalance_);
        // c.log("collateralTokenBalance_", collateralTokenBalance_);
        // c.log("collateralPrice", collateralPrice);
        // the following assumes that the collateral change is small compared to the overall collateral
        // because it is the first derivative of the legeraged balance with respect to the collateral balance
        // using the invariant collateral value = leveraged value + pegged value.
        // this may well be a reasonable assumption
        // TODO: work out the acceptable amount of collateral as a ratio that can be added in one go
        // and split this equation into a series of steps, i.e. do a piecewise differentiation, or
        // work out how leveraged nav varies with collateral tokens without using the invariant (if that's possible)
        // or investigate if this is why Aladdin are using the moving average for leverage ratio
        // Note: if leveraged balance is 0 this returns 0, so we have to bootstrap this contract with some leveraged tokens
        //       or work out the correct equation, assuming there is one solution:
        //           leveraged nav can vary or leveraged balance can vary
        if (leveragedTokenBalance_ > 0) {
            uint256 collateralValue = collateralTokenBalance_ * collateralPrice;
            uint256 peggedValue = peggedTokenBalance_ * 1 ether;
            if (peggedValue >= collateralValue) {
                leveragedTokens = 0;
            } else {
                leveragedTokens =
                    (forCollateral * collateralPrice * leveragedTokenBalance_) /
                    (collateralValue - peggedValue);
            }
        } else {
            leveragedTokens = (forCollateral * collateralPrice) / 1 ether; // TODO: check if there can be any starting price seems moire natural to price it on the same scale as the collateral token
        }
        // c.log("...leveragedTokens", leveragedTokens);
    }

    /**
     * @param leveragedTokenBalance_ the stotal supply of leveraged tokens, required to be > 0
     * @return collateral the amount of collateral a leveraged token is worth
     */
    function _collateralForLeveragedTokens(
        uint256 forLeveraged,
        uint256 leveragedTokenBalance_,
        uint256 peggedTokenBalance_,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice
    ) private pure returns (uint256 collateral) {
        if (_isDepegged(collateralTokenBalance_, collateralPrice, peggedTokenBalance_)) return 0;
        if (leveragedTokenBalance_ == 0) {
            collateral = forLeveraged * collateralPrice;
        } else {
            collateral =
                (forLeveraged * (collateralTokenBalance_ * collateralPrice - peggedTokenBalance_ * 1 ether)) /
                (collateralPrice * leveragedTokenBalance_);
        }
    }

    function _redeemPeggedForCollateralRatio(
        uint256 targetCollateralRatio,
        uint256 collateralTokenBalance_,
        uint256 price,
        uint256 peggedTokenBalance_
    ) private pure returns (uint256 peggedTokens) {
        // c.log("targetCollateralRatio", targetCollateralRatio);
        // c.log("collateralTokenBalance_", collateralTokenBalance_);
        // c.log("price", price);
        // c.log("", peggedTokenBalance_);
        peggedTokens =
            (targetCollateralRatio * peggedTokenBalance_ - collateralTokenBalance_ * price) /
            (targetCollateralRatio - 1 ether);
    }

    function _isDepegged(
        uint256 collateralTokenBalance_,
        uint256 collateralPrice,
        uint256 peggedTokenBalance_
    ) private pure returns (bool) {
        return (collateralTokenBalance_ * collateralPrice) < (peggedTokenBalance_ * 1 ether);
    }

    function _isNearlyDepegged(
        uint256 collateralTokenBalance_,
        uint256 collateralPrice,
        uint256 peggedTokenBalance_
    ) private pure returns (bool) {
        return (collateralTokenBalance_ * collateralPrice) <= (peggedTokenBalance_ * 1 ether);
    }

    /// @dev this is the theoretical collateral ratio
    /// the real collateral ratio never goes below 1 because below 1,
    /// the value of leverged is zero and the value of pegged is it's proportional share of the collteral
    // TODO: determine if the collateralRatio external function should call this or floor it at 1
    function _collateralRatio(
        uint256 collateralTokenBalance_,
        uint256 collateralPrice,
        uint256 peggedTokenBalance_
    ) private pure returns (uint256 collateralRatio_) {
        collateralRatio_ = (collateralTokenBalance_ * collateralPrice) / peggedTokenBalance_;
    }

    /*
     int256 _earningRatio = int256(_state.baseNav).sub(_lastPermissionedPrice).mul(PRECISION_I256).div(
      _lastPermissionedPrice
    );

*/

    function _leverageRatio(
        uint256 collateralTokenBalance_,
        uint256 collateralPrice,
        uint256 peggedTokenBalance_
    ) private pure returns (uint256 ratio) {
        if (_isNearlyDepegged(collateralTokenBalance_, collateralPrice, peggedTokenBalance_)) {
            // under collateral, assume infinite leverage
            // TODO: max leverage ratio (Aladdin use 100e18)
            ratio = type(uint256).max;
        } else {
            ratio =
                (1 ether * 1 ether) /
                (1 ether - (peggedTokenBalance_ * 1 ether * 1 ether) / (collateralTokenBalance_ * collateralPrice));
            // TODO: if (ratio > MAX_LEVERAGE_RATIO) ratio = MAX_LEVERAGE_RATIO;
        }
    }

    function _leveragedTokenBalance(address leveragedToken_) private view returns (uint256) {
        return IERC20(leveragedToken_).totalSupply();
    }

    function _collateralTokenBalance(address collateralToken_) private view returns (uint256) {
        return IERC20(collateralToken_).balanceOf(address(this));
    }

    // fetching collateral price in terms of the pegged token
    // ------------------------------------------------------
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
