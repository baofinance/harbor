// SPDX-License-Identifier: MIT
// coding standards by https://www.rareskills.io/post/solidity-style-guide
// and https://docs.soliditylang.org/en/latest/style-guide.html
pragma solidity 0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {WordCodec} from "src/common/WordCodec.sol";
import {Token} from "@bao/Token.sol";
import {BaoOwnableRoles} from "@bao/BaoOwnableRoles.sol";

import {BaoOwnableRoles} from "@bao/BaoOwnableRoles.sol";
import {IMinter} from "@interfaces/IMinter.sol";
import {IMintable} from "@bao/interfaces/IMintable.sol";
import {IBurnable} from "@bao/interfaces/IBurnable.sol";
import {IBurnable2Arg} from "@bao/interfaces/IBurnable2Arg.sol";
import {IBurnableFrom} from "@bao/interfaces/IBurnableFrom.sol";
import {IPriceOracle} from "src/price/IPriceOracle.sol";
import {IReservePool} from "@interfaces/IReservePool.sol";

/// @title Bao Minter
/// @author rootminus0x1 based on (albeit significantly modified) Aladdin's FX system
/// @notice Provides a gas-efficient, feature-rich implementation for the `IMinter` interface.
/// Functions are provided for users to mint (for collateral) and redeem (for collateral) pegged and leveraged tokens
/// ### Pegged tokens
/// Pegged tokens are ERC20 tokens that are pegged to some price provided by the `priceOracle`.
/// Pegged tokens have value, not just because they provide exposure to a price, for example, a real world asset,
/// but they can also be deposited into one of the rebalance pools for a reward.
/// <br>
/// Note:
/// * This contract must be given access to mint the pegged tokens by the owners of that pegged token.
/// * This contract does not assume it is the only minter of the pegged tokens. Instead it tracks how many it has
///   minted and
/// ensures that it will not redeem more than it has minted. Pegged tokened minted elsewhere can be used here.
/// * This contract provides the pegging mechanism.
/// #### Price Stability
/// The price stability is provided by a set of rebalance pools which utilise protected functionality provided by this
/// contract to do so.
/// ### Leveraged Tokens
/// Leveraged tokens are ERC20 tokens that are minted only by this contract. These tokens have value in that they can be
/// redeemed for collateral at a leveraged ratio, hence the name 'leveraged token'.
/// The leverage mechanism is provided by this contract and are designed such that the leverage ratio increases as the
/// collateral ratio decreases. The leveraged ratio is capped at 100,000.
// TODO: cap the leveraged ratio?, and test it
/// ### Collateral Ratio
/// The collateral ratio value referred to in this contract is the value of the collateral tokens divided by the value
/// of the pegged tokens, assuming one pegged token's value is 1. This allows the collateral ratio to reach 0.
/// In reality the pegged token's value changes when the collateral value drops below the value of the pegged tokens and
/// adjusts such that the value of the pegged tokens managed equals the value of the collateral.
/// ### Fees, discounts and disallows
/// Fees, discounts and disallows are defined by the config. Two arrays, one defining fee/discount/disallow values
/// between -1 and 1, and the other defining the collateral ratio levels at which those values apply.
/// <ul>
/// <li> positive values refer to fees as a ratio of the input tokens, e.g. a fee for minting pegged/leverage tokens would
///   be levied as a portion of the collateral tokens supplied, and a fee for redeeming a token would be a portion of
///   the pegged or leveraged tokens supplied and revalued at their price at the given collateral ratio level.
/// <li> negative values refer to discounts. The collateral needed to make up the discount is retrieved from the reserve
///   pool.
/// <li> values == 1 ether are treated as a 'disallow', i.e. the action being requested is disallowed at that collateral
///   ratio level.
/// </ul>
/// The collateral ratio levels are defined by an array of upper bounds, each strictly increasing from the previous one.
/// Some actions - minting pegged tokens and redeemin leveraged tokens - tend to lower the collateral ratio and other
/// actions - redeeming pegged tokens and minting leveraged tokens - tend to increase the collateral ratio. This means
/// two things:
/// 1. if an action results in the collateral ratio crossing one or more of the bounds then the fee and discount
///    (and both may apply) are each applied to the portion of collateral that is processed within each bound. This
///    means that the fees and discounts applied net and are also a definite integral of the collateral-fee/discount
///    function, i.e. the same fees/discounts apply whether the action is performed one dollat at a time or in much
///    larger chunks. This is, of course, within the precision of the uint256 datatype.
///    'disallow' applies then the action is not permitted at the collateral ratio and effectively limits the amount of
///    collateral that can be processed.
/// 2. Disallows ony apply to actions that tend to lower collateral ratio, and must only be in the first element of the
///    array. The author also cannot envisage a situation where a discount is applied to an action that lowers
///    collateral ratio and so configs that contain them are rejected.
/// ### Rebalancing
/// Rebalance pools know about the minter contract they are offering a rebalance service to and set themselves up to use
/// The collateral ratio stored in this contract's config to allow or disallow liquidation calls to them.
/// ### Harvesting
/// Harvesting occurs when collateral ratio levels reach the level defined in the config. Harvesting works by taking
/// increases in collateral value and sending that collateral to the harvest receiver for distribution to rebalance
/// pools as rewards and/or reserve pools, etc.
// TODO: implement harvesting
/// @dev Uses UUPS proxy, erc7201 storage
// solhint-disable-next-line contract-name-camelcase
contract Minter_v1 is
    Initializable,
    UUPSUpgradeable,
    ContextUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    BaoOwnableRoles,
    IMinter
{
    using SafeERC20 for IERC20;
    using WordCodec for bytes32;

    ///////////////
    // Constants //
    ///////////////

    /// @notice The precision at which incentive ratios are stored.
    /// @dev Fee & bonus ratios are stored as int32, which allows for -2 billion to 2 billion.
    /// With decimals = 9, this gives a max ratio of 2 (200%) with precision of 0.000000001 (0.0000001%),
    /// these ratios must be in the range [-1, 1] [-100%, 100%].
    /// This allows 8 of these to be stored in a slot.
    uint private constant _INCENTIVE_RATIO_DECIMALS = 9; // solhint-disable-line explicit-types

    /// @notice The precision at which collateral ratio bounds are stored.
    /// @dev Collateral ratio bounds are stored as uint32, which allows for a maximum value of ~4 billion.
    /// With decimals = 6, this gives a max ratio of 4,000 (400,000%) with precision of 0.000001 (0.0001%),
    /// e.g. 130.55% is easily catered for.
    /// This allows 8 of these to be stored in a slot. As there is one fewer bound, we only store 7. This, cunningly,
    /// leaves space for a count so that we can have "up to" 7 bounds and 8 fee/discount levels
    uint private constant _COLLATERAL_RATIO_DECIMALS = 6; // solhint-disable-line explicit-types

    /// @notice The maximum number of fee/discount value bands that can be stored
    /// @dev This is private because the public interface may differ, in particular to handle the piecewise valuation
    /// of pegged tokens, an extra boundary (and band) is added if not present around the depeg point
    uint private constant _MAX_BANDS = 8; // solhint-disable-line explicit-types
    /// @notice The maximum number of collateral ratio bounds for fee/discount variation that can be stored
    /// @dev This is private because the public interface may differ, in particular to handle the piecewise valuation
    /// of pegged tokens, an extra boundary (and band) is added if not present around the depeg point
    uint private constant _MAX_BOUNDS = _MAX_BANDS - 1; // solhint-disable-line explicit-types

    /// @notice The role that allows access to the zero fee versions of the functions.
    uint256 public constant ZERO_FEE_ROLE = _ROLE_0;

    /////////////
    // Storage //
    /////////////

    struct Pegged {
        address token; //                               160
        bytes4 burnInterfaceId; //                      164
    }

    // Share-with-proxy Storage
    // ------------------------
    /// @custom:storage-location erc7201:bao.storage.Minter
    /// @notice The state of this Minter contract.
    /// <br>
    /// It contains:
    /// * the addresses of the pegged, leveraged and collateral tokens
    /// * the pegged token balance - the total number of pegged tokens minted by this contract.
    ///   Other contracts may also mint these tokens and so we cannot just use the totalSupply of them
    /// * the addresses of the reserve pool (where discounts come from) and fee receiver (where fees go to)
    /// * the address of the price oracle, which provides the price of the collateral and also, if the collateral is
    ///   wrapped, the rate at which the token represents the token it wraps.
    /// * the rebalance and harvest collateral ratio trigger points
    /// * the fee/discount/disallow configurations for minting/redeeming pegged/leveraged tokens
    /// @dev The entire state of the contract is in this struct so that changing the layout during an upgrade is
    /// simplified. See ERC 7201.
    /// @dev As most of the content is addresses and structs, solidity lays it out in memory efficiently.
    /// Where it doesn't we use structs containing bytes32, each representing a slot of storage.
    struct MinterStorage {
        //                                             slot
        Pegged pegged; //                               164
        //                                             slot
        address leveragedToken; //                      160
        //                                             slot
        address collateralToken; //                     160
        //                                             slot
        // we keep track of pegged tokens as they can be minted through other rmeans
        uint256 peggedTokenBalance; //                  256
        //                                             slot
        // @custom:security non-reentrant
        address reservePool; //                         160
        //                                             slot
        // @custom:security non-reentrant
        address feeReceiver; //                         160
        //                                             slot
        // TODO: do we want a collateral cap?
        //                                             slot
        address priceOracle; //                         160
        //                                              slot*2
        uint256 rebalanceCollateralRatioUpperBound; // the upper collateral ratio at which rebalancing begins
        // TODO:
        uint256 harvestCollateralRatioLowerBound; // above this harvesting of collateral can begin
        //                                             slot*2
        ActionIncentive mintPeggedIncentiveConfig;
        //                                             slot*2
        ActionIncentive redeemPeggedIncentiveConfig;
        //                                             slot*2
        ActionIncentive mintLeveragedIncentiveConfig;
        //                                             slot*2
        ActionIncentive redeemLeveragedIncentiveConfig;
    }

    // TODO: add function to add a rebalancer, granting role and keeping track of it for liquidation?

    ////////////////////
    // Initialisation //
    ////////////////////

    // UUPSUpgradeable functions
    // -------------------------

    // TODO: take stuff out of this and put it in deploy script
    function initialize(
        address owner_,
        BalanceTokens calldata tokens_,
        bytes4 peggedBurnInterfaceId_,
        address priceOracle_,
        address feeReceiver_,
        address reservePool_,
        Config calldata config_
    ) external initializer {
        // initialise all the state variables
        _initializeOwner(owner_);
        __UUPSUpgradeable_init();
        __Context_init();
        __ReentrancyGuardTransient_init();

        MinterStorage storage $ = _getMinterStorage();
        // balance tokens
        Token.ensureERC20Token(tokens_.collateralToken);
        Token.ensureERC20Token(tokens_.peggedToken);
        Token.ensureERC20Token(tokens_.leveragedToken);

        $.collateralToken = tokens_.collateralToken;
        $.pegged = Pegged(tokens_.peggedToken, peggedBurnInterfaceId_);
        $.peggedTokenBalance = 0;
        $.leveragedToken = tokens_.leveragedToken;

        _updatePriceOracle(priceOracle_);
        _updateFeeReceiver(feeReceiver_);
        _updateReservePool(reservePool_);
        _updateConfig(config_);
        // wake-disable-next-line unchecked-return-value
        _grantRoles(owner_, ZERO_FEE_ROLE);
        // TODO: should we be saving the last permissioned price? _fetchSafePrice(priceOracle_)
    }

    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// https://forum.openzeppelin.com/t/what-does-disableinitializers-function-mean/28730
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice The check that allow this contract to be upgraded:
    /// In UUPS proxies the implementation is responsible for upgrading itself
    /// only owners can upgrade this contract.
    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    /// @notice Returns true if a given interface is supported.
    /// @dev See {IERC165-supportsInterface}.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IMinter).interfaceId || super.supportsInterface(interfaceId);
    }

    ///////////////////////////
    // Public View Functions //
    ///////////////////////////

    /// @inheritdoc IMinter
    function collateralToken() external view override(IMinter) returns (address) {
        MinterStorage storage $ = _getMinterStorage();
        return $.collateralToken;
    }

    /// @inheritdoc IMinter
    function peggedToken() external view override(IMinter) returns (address) {
        MinterStorage storage $ = _getMinterStorage();
        return $.pegged.token;
    }

    /// @inheritdoc IMinter
    function leveragedToken() external view override(IMinter) returns (address) {
        MinterStorage storage $ = _getMinterStorage();
        return $.leveragedToken;
    }

    /// @inheritdoc IMinter
    function priceOracle() external view override returns (address) {
        MinterStorage storage $ = _getMinterStorage();
        return $.priceOracle;
    }

    /// @inheritdoc IMinter
    function feeReceiver() external view override returns (address) {
        MinterStorage storage $ = _getMinterStorage();
        return $.feeReceiver;
    }

    /// @inheritdoc IMinter
    function reservePool() external view returns (address) {
        MinterStorage storage $ = _getMinterStorage();
        return $.reservePool;
    }

    /// @inheritdoc IMinter
    function peggedTokenBalance() external view override returns (uint256) {
        MinterStorage storage $ = _getMinterStorage();
        return $.peggedTokenBalance;
    }

    /// @inheritdoc IMinter
    function leveragedTokenBalance() external view override returns (uint256) {
        MinterStorage storage $ = _getMinterStorage();
        return _leveragedTokenBalance($.leveragedToken);
    }

    /// @inheritdoc IMinter
    function collateralTokenBalance() external view override returns (uint256) {
        MinterStorage storage $ = _getMinterStorage();
        return _collateralTokenBalance($.collateralToken);
    }

    /// @inheritdoc IMinter
    function config() public view returns (Config memory config_) {
        MinterStorage storage $ = _getMinterStorage();
        config_.rebalanceCollateralRatioUpperBound = $.rebalanceCollateralRatioUpperBound;
        config_.harvestCollateralRatioLowerBound = $.harvestCollateralRatioLowerBound;
        config_.mintPeggedIncentiveConfig = _copyBandsBack($.mintPeggedIncentiveConfig);
        config_.redeemPeggedIncentiveConfig = _copyBandsBack($.redeemPeggedIncentiveConfig);
        config_.mintLeveragedIncentiveConfig = _copyBandsBack($.mintLeveragedIncentiveConfig);
        config_.redeemLeveragedIncentiveConfig = _copyBandsBack($.redeemLeveragedIncentiveConfig);
    }

    /// @inheritdoc IMinter
    function rebalanceCollateralRatio() external view returns (uint256) {
        MinterStorage storage $ = _getMinterStorage();
        return $.rebalanceCollateralRatioUpperBound;
    }

    /// @inheritdoc IMinter
    function collateralRatio() external view override returns (uint256) {
        MinterStorage storage $ = _getMinterStorage();
        if ($.peggedTokenBalance == 0) {
            return type(uint256).max; // TODO: consider reverting here or returning 1 ether
        } else {
            return
                _collateralRatio(
                    _collateralTokenBalance($.collateralToken),
                    _fetchSafePrice($.priceOracle),
                    $.peggedTokenBalance
                );
        }
    }

    /// @inheritdoc IMinter
    function leverageRatio() external view override returns (uint256) {
        MinterStorage storage $ = _getMinterStorage();
        return
            _leverageRatio(
                _collateralTokenBalance($.collateralToken),
                _fetchSafePrice($.priceOracle),
                $.peggedTokenBalance
            );
    }

    /// @inheritdoc IMinter
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

    /// @inheritdoc IMinter
    function peggedTokenPrice() external view override returns (uint256 nav) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 price = _fetchSafePrice($.priceOracle);
        nav = _peggedTokenPrice$($.peggedTokenBalance, _collateralTokenBalance($.collateralToken), price) / 1 ether;
    }

    /// @inheritdoc IMinter
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

    /// @inheritdoc IMinter
    function collateralForLeverageTokens(
        uint256 forLeveragedTokens
    ) external view override returns (uint256 collateral) {
        MinterStorage storage $ = _getMinterStorage();
        // TODO: add check for being depegged here and remove it from the below function
        collateral = _collateralForLeveragedTokens(
            forLeveragedTokens,
            _leveragedTokenBalance($.leveragedToken),
            $.peggedTokenBalance,
            _collateralTokenBalance($.collateralToken),
            _fetchMinPrice($.priceOracle)
        );
    }

    /// @inheritdoc IMinter
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

    /// @inheritdoc IMinter
    function swapPeggedForLeveragedForCollateralRatio(
        uint256 targetCollateralRatio
    ) external view returns (uint256 peggedTokens) {
        MinterStorage storage $ = _getMinterStorage();
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

    /// @inheritdoc IMinter
    function mintPeggedTokenIncentiveRatio() external view override returns (int256 incentiveRatio) {
        MinterStorage storage $ = _getMinterStorage();
        ActionIncentive memory config_ = $.mintPeggedIncentiveConfig;
        // solhint-disable-next-line explicit-types
        uint band = _findBand(
            config_,
            _collateralTokenBalance($.collateralToken),
            _fetchSafePrice($.priceOracle),
            $.peggedTokenBalance,
            false
        );
        incentiveRatio = _incentiveRatio(config_, band);
    }

    /// @inheritdoc IMinter
    function redeemPeggedTokenIncentiveRatio() external view override returns (int256 incentiveRatio) {
        MinterStorage storage $ = _getMinterStorage();
        ActionIncentive memory config_ = $.redeemPeggedIncentiveConfig;
        // solhint-disable-next-line explicit-types
        uint band = _findBand(
            config_,
            _collateralTokenBalance($.collateralToken),
            _fetchMaxPrice($.priceOracle),
            $.peggedTokenBalance,
            false
        );
        incentiveRatio = _incentiveRatio(config_, band);
    }

    /// @inheritdoc IMinter
    function mintLeveragedTokenIncentiveRatio() external view override returns (int256 incentiveRatio) {
        MinterStorage storage $ = _getMinterStorage();
        ActionIncentive memory config_ = $.mintLeveragedIncentiveConfig;
        // just want the fee/bonus at the current collateral
        // solhint-disable-next-line explicit-types
        uint band = _findBand(
            config_,
            _collateralTokenBalance($.collateralToken),
            _fetchSafePrice($.priceOracle),
            $.peggedTokenBalance,
            false
        );
        incentiveRatio = _incentiveRatio(config_, band);
    }

    /// @inheritdoc IMinter
    function redeemLeveragedTokenIncentiveRatio() external view override returns (int256 incentiveRatio) {
        MinterStorage storage $ = _getMinterStorage();
        ActionIncentive memory config_ = $.redeemLeveragedIncentiveConfig;
        // solhint-disable-next-line explicit-types
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

    /// @inheritdoc IMinter
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
        MinterStorage storage $ = _getMinterStorage();
        price = _fetchSafePrice($.priceOracle);
        (fee, peggedMinted, collateralUsed) = _mintPeggedAdjustments(
            $.mintPeggedIncentiveConfig,
            collateralIn,
            _collateralTokenBalance($.collateralToken),
            price,
            $.peggedTokenBalance
        );
        reserveCollateralUsed = 0;
        incentiveRatio = int256(
            collateralUsed == 0 ? 1 ether : ((fee - reserveCollateralUsed) * 1 ether) / collateralUsed
        );
    }

    /// @inheritdoc IMinter
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
        (fee, peggedRedeemed, collateralReturned, reserveCollateralUsed) = _redeemPeggedAdjustments(
            $.redeemPeggedIncentiveConfig,
            peggedIn,
            _collateralTokenBalance(collateralToken_),
            price,
            $.peggedTokenBalance,
            IERC20(collateralToken_).balanceOf($.reservePool)
        );
        // slither-disable-next-line incorrect-equality
        incentiveRatio = peggedRedeemed == 0
            ? int256(1 ether)
            : ((int256(fee) - int256(reserveCollateralUsed)) * int256(price)) / int256(peggedRedeemed);
    }

    /// @inheritdoc IMinter
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
        address collateralToken_ = $.collateralToken;
        uint256 collateralTokenBalance_ = _collateralTokenBalance(collateralToken_);
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        price = _fetchSafePrice($.priceOracle);
        (fee, leveragedMinted, reserveCollateralUsed) = _mintLeveragedAdjustments(
            $.mintLeveragedIncentiveConfig,
            collateralIn,
            Balances(collateralTokenBalance_, peggedTokenBalance_, _leveragedTokenBalance($.leveragedToken)),
            price,
            IERC20(collateralToken_).balanceOf($.reservePool)
        );
        collateralUsed = collateralIn; // we never disallow minting leveraged tokens
        incentiveRatio = ((int256(fee) - int256(reserveCollateralUsed)) * 1 ether) / int256(collateralUsed);
    }

    /// @inheritdoc IMinter
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
        // slither-disable-next-line incorrect-equality
        incentiveRatio = int256(collateralReturned == 0 ? 1 ether : (fee * 1 ether) / collateralReturned);
    }

    //////////////////////////////
    // Public Mutator Functions //
    //////////////////////////////

    /// @inheritdoc IMinter
    function updateConfig(Config calldata config_) external override onlyOwner {
        _updateConfig(config_);
    }

    /// @inheritdoc IMinter
    function updatePriceOracle(address priceOracle_) external onlyOwner {
        _updatePriceOracle(priceOracle_);
    }

    /// @inheritdoc IMinter
    function updateFeeReceiver(address feeReceiver_) external override onlyOwner {
        _updateFeeReceiver(feeReceiver_);
    }

    /// @inheritdoc IMinter
    function updateReservePool(address reservePool_) external override onlyOwner {
        _updateReservePool(reservePool_);
    }

    // minting/redeeming pegged/leveraged tokens
    // -----------------------------------------

    /// @inheritdoc IMinter
    function mintPeggedToken(
        uint256 collateralIn,
        address receiver,
        uint256 minPeggedOut
    ) external override nonReentrant returns (uint256 peggedOut) {
        MinterStorage storage $ = _getMinterStorage();
        // work out how much collateral to use
        address collateralToken_ = $.collateralToken;
        collateralIn = Token.allOf(_msgSender(), collateralToken_, collateralIn);

        uint256 price = _fetchSafePrice($.priceOracle);
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        uint256 collateralTokenBalance_ = _collateralTokenBalance(collateralToken_);

        // fee calculation
        uint256 fee;
        (fee, peggedOut, collateralIn) = _mintPeggedAdjustments(
            $.mintPeggedIncentiveConfig,
            collateralIn,
            collateralTokenBalance_,
            price,
            peggedTokenBalance_
        );

        address peggedToken_ = $.pegged.token;
        if (collateralIn == 0) revert MintZeroAmount(peggedToken_);

        // recalculate the amounts involved
        if (peggedOut == 0) revert MintZeroAmount(peggedToken_);
        if (peggedOut < minPeggedOut) {
            revert MintInsufficientAmount(peggedToken_, minPeggedOut, peggedOut);
        }

        _mintPeggedToken(collateralToken_, collateralIn, peggedToken_, peggedOut, receiver);

        if (fee > 0) {
            IERC20(collateralToken_).safeTransfer($.feeReceiver, fee);
        }
        // update our records
        $.peggedTokenBalance = peggedTokenBalance_ + peggedOut;
    }

    /// @inheritdoc IMinter
    function redeemPeggedToken(
        uint256 peggedIn,
        address receiver,
        uint256 minCollateralOut
    ) external override nonReentrant returns (uint256 collateralOut) {
        MinterStorage storage $ = _getMinterStorage();
        address collateralToken_ = $.collateralToken;
        Pegged memory pegged_ = $.pegged;
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        peggedIn = Token.allOf(_msgSender(), pegged_.token, peggedIn);
        peggedIn = _redeemable(pegged_.token, peggedIn, peggedTokenBalance_);

        uint256 price = _fetchMaxPrice($.priceOracle);
        uint256 fee;
        uint256 extraCollateral;
        (fee, peggedIn, collateralOut, extraCollateral) = _redeemPeggedAdjustments(
            $.redeemPeggedIncentiveConfig,
            peggedIn,
            _collateralTokenBalance(collateralToken_),
            price,
            peggedTokenBalance_,
            IERC20(collateralToken_).balanceOf($.reservePool)
        );
        // slither-disable-next-line incorrect-equality
        if (peggedIn == 0) {
            revert ReturnZeroAmount(collateralToken_);
        }
        // add any extra collateral (we reuse the collateralOut variable)
        if (extraCollateral > 0) {
            // it's a discount, so collect the extra collateral, if available
            // TODO: check rebalance pools are exhausted before discounts are handed out?
            // wake-disable-next-line reentrancy // reservePool is trusted and reentrancy guard
            extraCollateral = IReservePool($.reservePool).requestBonus(
                collateralToken_,
                address(this),
                extraCollateral
            );
        }

        // make sure it meets the minimum requirements
        // slither-disable-next-line incorrect-equality
        if (collateralOut == 0) {
            revert ReturnZeroAmount(pegged_.token);
        }

        if (collateralOut < minCollateralOut) {
            revert ReturnInsufficientAmount(collateralToken_, minCollateralOut, collateralOut);
        }

        // redeem pegged tokens and send the remainder of the collateral
        _redeemPeggedToken(pegged_, peggedIn, collateralToken_, collateralOut, receiver);

        if (fee > 0) {
            // send the fee
            IERC20(collateralToken_).safeTransfer($.feeReceiver, fee);
        }

        // update our records
        $.peggedTokenBalance = peggedTokenBalance_ - peggedIn;
    }

    /// @inheritdoc IMinter
    function mintLeveragedToken(
        uint256 collateralIn,
        address receiver,
        uint256 minLeveragedOut
    ) external override nonReentrant returns (uint256 leveragedOut) {
        MinterStorage storage $ = _getMinterStorage();
        address collateralToken_ = $.collateralToken;
        collateralIn = Token.allOf(_msgSender(), collateralToken_, collateralIn);

        address leveragedToken_ = $.leveragedToken;
        uint256 fee;
        uint256 extraCollateral;
        (fee, leveragedOut, extraCollateral) = _mintLeveragedAdjustments(
            $.mintLeveragedIncentiveConfig,
            collateralIn,
            Balances(
                _collateralTokenBalance(collateralToken_),
                $.peggedTokenBalance,
                _leveragedTokenBalance(leveragedToken_)
            ),
            _fetchSafePrice($.priceOracle),
            IERC20(collateralToken_).balanceOf($.reservePool)
        );
        // slither-disable-next-line incorrect-equality
        if (leveragedOut == 0) {
            revert ReturnZeroAmount(leveragedToken_);
        }
        // net out the fee & extra collateral
        if (extraCollateral > 0) {
            // TODO: check rebalance pools are exhausted before discounts are handed out?
            // it's a discount, so collect the extra collateral, if available
            // wake-disable-next-line reentrancy // reservePool is trusted
            extraCollateral = IReservePool($.reservePool).requestBonus(
                collateralToken_,
                address(this),
                extraCollateral
            );
            // TODO: what happens if extraCollateral is not available, and the leveragedOut value is therefore wrong?
        }
        // make sure it meets the minimum requirements
        if (leveragedOut < minLeveragedOut) {
            revert MintInsufficientAmount(leveragedToken_, minLeveragedOut, leveragedOut);
        }
        // mint the leveraged tokens and take collateralIn
        _mintLeveragedToken(collateralToken_, collateralIn, leveragedToken_, leveragedOut, receiver);
        // take the fee
        if (fee > 0) {
            IERC20(collateralToken_).safeTransfer($.feeReceiver, fee);
        }
    }

    /// @inheritdoc IMinter
    function redeemLeveragedToken(
        uint256 leveragedIn,
        address receiver,
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

        uint256 fee;
        (fee, leveragedIn, collateralOut) = _redeemLeveragedAdjustments(
            $.redeemLeveragedIncentiveConfig,
            leveragedIn,
            collateralTokenBalance_,
            price,
            peggedTokenBalance_,
            leveragedTokenBalance_
        );
        // slither-disable-next-line incorrect-equality
        if (leveragedIn == 0) {
            revert ReturnZeroAmount(collateralToken_);
        }
        if (collateralOut < minCollateralOut) {
            revert ReturnInsufficientAmount(collateralToken_, minCollateralOut, collateralOut);
        }

        _redeemLeveragedToken(leveragedToken_, leveragedIn, collateralToken_, collateralOut, receiver);

        if (fee > 0) {
            // send the fee
            IERC20(collateralToken_).safeTransfer($.feeReceiver, fee);
        }
    }

    //////////////////////////////////
    // Restricted Mutator Functions //
    //////////////////////////////////

    // fee-free minting/redeeming pegged/leveraged tokens
    // --------------------------------------------------

    /// @inheritdoc IMinter
    function freeMintPeggedToken(
        uint256 collateralIn,
        address receiver
    ) external override onlyRoles(ZERO_FEE_ROLE) nonReentrant returns (uint256 peggedOut) {
        MinterStorage storage $ = _getMinterStorage();
        // how much collateral to use
        address collateralToken_ = $.collateralToken;
        collateralIn = Token.allOf(_msgSender(), collateralToken_, collateralIn);

        // transfer and mint
        uint256 price = _fetchSafePrice($.priceOracle);
        peggedOut = (collateralIn * price) / 1 ether;
        _mintPeggedToken(collateralToken_, collateralIn, $.pegged.token, peggedOut, receiver);

        // update our records
        $.peggedTokenBalance += peggedOut;
    }

    // @inheritdoc IMinter
    function freeRedeemPeggedToken(
        uint256 peggedIn,
        address receiver
    ) external override nonReentrant onlyRoles(ZERO_FEE_ROLE) returns (uint256 collateralOut) {
        MinterStorage storage $ = _getMinterStorage();
        address collateralToken_ = $.collateralToken;
        Pegged memory pegged_ = $.pegged;
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        peggedIn = Token.allOf(_msgSender(), pegged_.token, peggedIn);
        peggedIn = _redeemable(pegged_.token, peggedIn, peggedTokenBalance_);

        uint256 price = _fetchMaxPrice($.priceOracle);
        collateralOut =
            (peggedIn * _peggedTokenPrice$(peggedTokenBalance_, _collateralTokenBalance(collateralToken_), price)) /
            (price * 1 ether);

        // burn pegged tokens and send the collateral to the receiver
        _redeemPeggedToken(pegged_, peggedIn, collateralToken_, collateralOut, receiver);

        // update our records
        $.peggedTokenBalance = peggedTokenBalance_ - peggedIn;
    }

    /// @inheritdoc IMinter
    function freeSwapPeggedForLeveraged(
        uint256 peggedIn,
        address receiver
    ) external override nonReentrant onlyRoles(ZERO_FEE_ROLE) returns (uint256 leveragedOut) {
        MinterStorage storage $ = _getMinterStorage();
        address collateralToken_ = $.collateralToken;
        address peggedToken_ = $.pegged.token;
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        address leveragedToken_ = $.leveragedToken;

        peggedIn = Token.allOf(_msgSender(), peggedToken_, peggedIn);
        peggedIn = _redeemable(peggedToken_, peggedIn, peggedTokenBalance_);

        uint256 price = _fetchSafePrice($.priceOracle);

        leveragedOut = _leveragedTokensForPegged(
            peggedIn,
            _leveragedTokenBalance(leveragedToken_),
            peggedTokenBalance_,
            _collateralTokenBalance(collateralToken_),
            price
        );

        // burn pegged tokens and send the collateral
        _swapPeggedForLeveraged(peggedToken_, peggedIn, leveragedToken_, leveragedOut, receiver);

        // update our records
        $.peggedTokenBalance = peggedTokenBalance_ - peggedIn;
    }

    // @inheritdoc IMinter
    function freeMintLeveragedToken(
        uint256 collateralIn,
        address receiver
    ) external override onlyRoles(ZERO_FEE_ROLE) nonReentrant returns (uint256 leveragedOut) {
        MinterStorage storage $ = _getMinterStorage();
        // how much collateral to use
        address collateralToken_ = $.collateralToken;
        collateralIn = Token.allOf(_msgSender(), collateralToken_, collateralIn);

        // mint the tokens to the receiver
        address leveragedToken_ = $.leveragedToken;
        leveragedOut = _leveragedTokensForCollateral(
            collateralIn,
            _leveragedTokenBalance(leveragedToken_),
            $.peggedTokenBalance,
            _collateralTokenBalance(collateralToken_),
            _fetchSafePrice($.priceOracle)
        );

        _mintLeveragedToken(collateralToken_, collateralIn, leveragedToken_, leveragedOut, receiver);
    }

    // @inheritdoc IMinter
    function freeRedeemLeveragedToken(
        uint256 leveragedIn,
        address receiver
    ) external override onlyRoles(ZERO_FEE_ROLE) returns (uint256 collateralOut) {
        MinterStorage storage $ = _getMinterStorage();
        // how much collateral to use
        address leveragedToken_ = $.leveragedToken;
        leveragedIn = Token.allOf(_msgSender(), leveragedToken_, leveragedIn);

        uint256 leveragedTokenBalance_ = _leveragedTokenBalance(leveragedToken_);
        leveragedIn = _redeemable(leveragedToken_, leveragedIn, leveragedTokenBalance_);

        uint256 price = _fetchMinPrice($.priceOracle);

        address collateralToken_ = $.collateralToken;
        // TODO: add check for depegged here as we'll remove it from below
        collateralOut = _collateralForLeveragedTokens(
            leveragedIn,
            leveragedTokenBalance_,
            $.peggedTokenBalance,
            _collateralTokenBalance(collateralToken_),
            price
        );

        _redeemLeveragedToken(leveragedToken_, leveragedIn, collateralToken_, collateralOut, receiver);
    }

    ///////////////////////
    // Private functions //
    ///////////////////////

    /// @notice The storage hash for the shared-with-proxy storage
    /// @dev keccak256(abi.encode(uint256(keccak256("bao.storage.Minter")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant _MINTER_STORAGE = 0x92e73fe9557052b4a0b810a38eb7ef595ff750f166ca39d63b3f4c74937fef00;

    /// @notice Returns a reference to the contract state
    function _getMinterStorage() private pure returns (MinterStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _MINTER_STORAGE
        }
    }

    // Config
    // ------

    /// @notice The storage format for the array of incentive ratios and collateral ratio bound.
    /// @dev We use a struct here but implement our own storage within because solidity uses too many slots
    /// @dev There are a set of accessor functions for each logical item in the structure.
    struct ActionIncentive {
        bytes32 slot0;
        // uint32[7] collateralRatioUpperBounds;      0:223
        // uint8 collateralRatioBandCount;          224:231
        // bool depegBandAdded                      232:234
        bytes32 slot1;
        // int32[8] incentiveRatios;                  0:255
    }

    // slot accessors for ActionIncentive
    /// @notice Returns a collateral ratio bound at the given index
    // solhint-disable-next-line explicit-types
    function _collateralRatioUpperBounds(ActionIncentive memory config_, uint index) private pure returns (uint256) {
        return config_.slot0.decodeUint(index * 32, 32) * 10 ** (18 - _COLLATERAL_RATIO_DECIMALS);
    }

    /// @notice Returns a collateral ratio lower bound at the given index`
    // solhint-disable-next-line explicit-types
    function _collateralRatioLowerBounds(ActionIncentive memory config_, uint index) private pure returns (uint256) {
        // if we are in the lowest band, the lower bound is 0
        // else its the previous upper bound
        return index == 0 ? 0 ether : _collateralRatioUpperBounds(config_, index - 1);
    }

    /// @notice Stores a collateral ratio bound at the given index
    // solhint-disable-next-line explicit-types
    function _setCollateralRatioUpperBounds(ActionIncentive memory config_, uint index, uint256 value) private pure {
        config_.slot0 = config_.slot0.encodeUint(value / 10 ** (18 - _COLLATERAL_RATIO_DECIMALS), index * 32, 32);
    }

    /// @notice Returns the collateral ratio bound count
    // solhint-disable-next-line explicit-types
    function _collateralRatioBandCount(ActionIncentive memory config_) private pure returns (uint) {
        return config_.slot0.decodeUint(224, 8);
    }

    /// @notice Stored the collateral ratio bound count
    // solhint-disable-next-line explicit-types
    function _setCollateralRatioBandCount(ActionIncentive memory config_, uint value) private pure {
        config_.slot0 = config_.slot0.encodeUint(value, 224, 8);
    }

    /// @notice Returns a incentive ratio at the given index
    // solhint-disable-next-line explicit-types
    function _incentiveRatio(ActionIncentive memory config_, uint index) private pure returns (int256) {
        return config_.slot1.decodeInt(index * 32, 32) * int256(10 ** (18 - _INCENTIVE_RATIO_DECIMALS));
    }

    /// @notice Stores a incentive ratio at the given index
    // solhint-disable-next-line explicit-types
    function _setIncentiveRatio(ActionIncentive memory config_, uint index, int256 value) private pure {
        config_.slot1 = config_.slot1.encodeInt(value / int256(10 ** (18 - _INCENTIVE_RATIO_DECIMALS)), index * 32, 32);
    }

    /// @notice Returns whether a depeg boundary has been added. This is used when returning the config to
    /// a caller to return it in the same form it was provided.
    function _depegBandAdded(ActionIncentive memory config_) private pure returns (bool) {
        return config_.slot0.decodeBool(232);
    }

    /// @notice Stores whether a depeg boundary has been added.
    function _setDepegBandAdded(ActionIncentive memory config_, bool value) private pure {
        config_.slot0 = config_.slot0.encodeBool(value, 232);
    }

    /// @notice Returns the value of an incentive ratio after it has been cycled (and possibly truncated) through its
    /// storage.
    function _incentiveRatioToStoragePrecision(int256 ratio) private pure returns (int256) {
        int256 factor = int256(10 ** (18 - _INCENTIVE_RATIO_DECIMALS));
        // slither-disable-next-line divide-before-multiply
        return ((ratio / factor) * factor);
    }

    /// @notice Returns the value of an collateral ratio bound after it has been cycled (and possibly truncated) through
    /// its storage
    function _collateralRatioToStoragePrecision(uint256 ratio) private pure returns (uint256) {
        uint256 factor = 10 ** (18 - _COLLATERAL_RATIO_DECIMALS);
        // slither-disable-next-line divide-before-multiply
        return ((ratio / factor) * factor);
    }

    /// @notice Checks a given incentive config for errors and returns it ready for storage
    /// @param config_ The user friendly config being checked and copied.
    /// @param disallowNotDiscount If true then the config may have a disallow and not a discount.
    /// @return out the storage efficient config.
    // slither-disable-next-line cyclomatic-complexity as this code is simple in what it tries to do, it's just that there are a few checks
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
        out = ActionIncentive(0, 0);
        uint256 prevUpperBound = 0;
        uint iOut = 0; // solhint-disable-line explicit-types
        // solhint-disable-next-line explicit-types
        for (uint i = 0; i < config_.incentiveRatios.length; i++) {
            int256 incentiveRatio = _incentiveRatioToStoragePrecision(config_.incentiveRatios[i]);
            // incentive ratios cannot be too precise for the storage schema
            if (incentiveRatio != config_.incentiveRatios[i]) {
                revert IncentiveRatioTooPrecise(config_.incentiveRatios[i]);
            }

            // check the incentive array values given
            // if disallowNotDiscount (i.e. mint pegged or redeem leveraged) then
            // check against interval [0, 1] i.e. zero fees to some fees to disallow (100% fees)
            //    also disallow is only valid in the first band
            // else (i.e. redeem pegged or mint leveraged)
            // check against interval (-1, 1) i.e. some discount; to zero; to some fees
            if (disallowNotDiscount) {
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
            uint256 currentUpperBound;
            if (i < config_.collateralRatioBandUpperBounds.length) {
                currentUpperBound = _collateralRatioToStoragePrecision(config_.collateralRatioBandUpperBounds[i]);
                if (currentUpperBound != config_.collateralRatioBandUpperBounds[i]) {
                    revert CollateralRatioBoundTooPrecise(config_.collateralRatioBandUpperBounds[i]);
                }
                if ((i == 0 && currentUpperBound < 1 ether) || (i > 0 && currentUpperBound <= 1 ether)) {
                    revert InvalidCollateralRatioBoundValue(currentUpperBound, i);
                }
            } else {
                currentUpperBound = type(uint256).max;
            }

            if (i == 0) {
                // add a depeg boundary as the first band one unless
                //  - there is already one
                //  - it is a disallow band
                // if we didn't do it here, we would have to do it in each of the fee calculation functions
                // this makes the check against band == 0 the same as a check for depegged
                // it also makes the math simpler - how do we manage multiple incentive ratios for the depegged situation?
                // especially as the actual collateral ratio (not the one we calculate as collateralRatio()) never goes below 1 ether
                if (currentUpperBound == 1 ether || incentiveRatio == 1 ether) {
                    // we have a user defined depegged boundary or a disallow bound
                    _setDepegBandAdded(out, false);
                } else {
                    // add the depeg and use the same incentive ratio on each side of the depeg boundary
                    _setIncentiveRatio(out, iOut, incentiveRatio);
                    _setCollateralRatioUpperBounds(out, iOut, 1 ether);
                    _setDepegBandAdded(out, true);
                    iOut++;
                }
            } else {
                // each subsequent must be strictly increasing (at the storage precision)
                if (currentUpperBound <= prevUpperBound) {
                    revert CollateralRatioBoundValueNotIncreasing(
                        config_.collateralRatioBandUpperBounds[i],
                        i,
                        config_.collateralRatioBandUpperBounds[i - 1]
                    );
                }
            }
            if (iOut >= _MAX_BANDS) {
                revert TooManyIncentiveRatios(config_.incentiveRatios.length, config_.incentiveRatios.length - 1);
            }
            _setIncentiveRatio(out, iOut, incentiveRatio);
            if (i < config_.collateralRatioBandUpperBounds.length) {
                _setCollateralRatioUpperBounds(out, iOut, currentUpperBound);
                prevUpperBound = currentUpperBound;
            }
            iOut++;
        }
        _setCollateralRatioBandCount(out, iOut);
    }

    function _copyBandsBack(ActionIncentive memory config_) private pure returns (IncentiveConfig memory out) {
        uint iOut = 0; // solhint-disable-line explicit-types
        uint outBands = _collateralRatioBandCount(config_); // solhint-disable-line explicit-types
        if (_depegBandAdded(config_)) outBands--;
        out.collateralRatioBandUpperBounds = new uint256[](outBands - 1);
        out.incentiveRatios = new int256[](outBands);
        // solhint-disable-next-line explicit-types
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
        // or is this handled by the fact that the CR for discount is much lower than the rebalance CR
        emit UpdateConfig(config_); // the code below may alter the config so emit it soon

        MinterStorage storage $ = _getMinterStorage();

        // action config
        // TODO: consider making those 32 bit and packing them with the address of the rebalance pools/ harvest beneficiary
        $.rebalanceCollateralRatioUpperBound = config_.rebalanceCollateralRatioUpperBound;
        $.harvestCollateralRatioLowerBound = config_.harvestCollateralRatioLowerBound;

        // incentive config
        $.mintPeggedIncentiveConfig = _checkAndCopyBands(config_.mintPeggedIncentiveConfig, true);
        $.mintLeveragedIncentiveConfig = _checkAndCopyBands(config_.mintLeveragedIncentiveConfig, false);
        $.redeemPeggedIncentiveConfig = _checkAndCopyBands(config_.redeemPeggedIncentiveConfig, false);
        $.redeemLeveragedIncentiveConfig = _checkAndCopyBands(config_.redeemLeveragedIncentiveConfig, true);
    }

    // Price Oracle
    // ------------

    /// @notice Updates the price oracle address.
    function _updatePriceOracle(address priceOracle_) private {
        MinterStorage storage $ = _getMinterStorage();
        address old = $.priceOracle;
        $.priceOracle = priceOracle_;
        emit UpdatePriceOracle(old, priceOracle_);
    }

    // Fee Receiver
    // ------------

    /// @notice Updates the fee receiver address.
    function _updateFeeReceiver(address feeReceiver_) private {
        MinterStorage storage $ = _getMinterStorage();
        address old = $.feeReceiver;
        $.feeReceiver = feeReceiver_;
        emit UpdateFeeReceiver(old, feeReceiver_);
    }

    // ReservePool
    // -----------

    /// @notice Updates the reserve pool address.
    function _updateReservePool(address reservePool_) private {
        MinterStorage storage $ = _getMinterStorage();
        address old = $.reservePool;
        $.reservePool = reservePool_;
        emit UpdateReservePool(old, reservePool_);
    }

    // Mint/Redeem Pegged/Leveraged
    // ----------------------------

    /// @notice Perform the transfers and event emissions for minting pegged tokens.
    /// Fees and discounts transfers and event emissions are not handled here.
    /// @dev no checks for zeros values are performed.
    /// @param collateralToken_ The address of the collateral token.
    /// @param collateralIn The amount of collateral to be taken from the sender.
    /// @param peggedToken_ The address of the pegged token.
    /// @param peggedOut The amount of pegged to be transferred to the `receiver`.
    /// @param receiver The address of the receiver.

    function _mintPeggedToken(
        address collateralToken_,
        uint256 collateralIn,
        address peggedToken_,
        uint256 peggedOut,
        address receiver
    ) private {
        emit MintPeggedToken(_msgSender(), receiver, collateralIn, peggedOut);

        // mint the tokens to the receiver
        // wake-disable-next-line reentrancy // all callers to this function have nonReentrant guard
        IMintable(peggedToken_).mint(receiver, peggedOut);

        // take the collateral
        IERC20(collateralToken_).safeTransferFrom(_msgSender(), address(this), collateralIn);
    }

    /// @notice Perform the transfers and event emissions for redeeming pegged tokens
    /// Fees and discounts transfers and event emissions are not handled here.
    /// @dev no checks for zeros values are performed.
    /// @param pegged_ The address of the pegged token and it's burn interface
    /// @param peggedIn The amount of pegged tokens to be taken from the sender.
    /// @param collateralToken_ The address of the collateral token.
    /// @param collateralOut The amount of collateral to be transferred to the `receiver`.
    /// @param receiver The address of the receiver.

    function _redeemPeggedToken(
        Pegged memory pegged_,
        uint256 peggedIn,
        address collateralToken_,
        uint256 collateralOut,
        address receiver
    ) private {
        // tell the world
        emit RedeemPeggedToken(_msgSender(), receiver, peggedIn, collateralOut);
        // burn the tokens from the sender
        if (pegged_.burnInterfaceId == type(IBurnable).interfaceId) {
            // get the tokens here first
            IERC20(pegged_.token).safeTransferFrom(_msgSender(), address(this), peggedIn);
            IBurnable(pegged_.token).burn(peggedIn);
        } else if (pegged_.burnInterfaceId == type(IBurnable2Arg).interfaceId) {
            IBurnable2Arg(pegged_.token).burn(_msgSender(), peggedIn);
        } else if (pegged_.burnInterfaceId == type(IBurnableFrom).interfaceId) {
            IBurnableFrom(pegged_.token).burnFrom(_msgSender(), peggedIn);
        } else {
            revert UnsupportedBurnInterface(pegged_.burnInterfaceId);
        }
        // return the collateral
        IERC20(collateralToken_).safeTransfer(receiver, collateralOut);
    }

    /// @notice Perform the transfers and event emissions for redeeming pegged tokens for leveraged tokens
    /// Fees and discounts transfers and event emissions are not handled here.
    /// @dev no checks for zeros values are performed.
    /// @param peggedToken_ The address of the pegged token.
    /// @param peggedIn The amount of pegged tokens to be taken from the sender.
    /// @param leveragedToken_ The address of the leveraged token.
    /// @param leveragedOut The amount of leveraged to be transferred to the `receiver`.
    /// @param receiver The address of the receiver.

    function _swapPeggedForLeveraged(
        address peggedToken_,
        uint256 peggedIn,
        address leveragedToken_,
        uint256 leveragedOut,
        address receiver
    ) private {
        // tell the world
        emit SwapPeggedForLeveraged(_msgSender(), receiver, peggedIn, leveragedOut);
        // burn the tokens from the sender - get them first then burn them
        IERC20(peggedToken_).safeTransferFrom(_msgSender(), address(this), peggedIn);
        // wake-disable-next-line reentrancy // all callers to this function have nonReentrant guard
        IBurnable(peggedToken_).burn(peggedIn);
        // mint the tokens to the receiver
        // wake-disable-next-line reentrancy
        IMintable(leveragedToken_).mint(receiver, leveragedOut);
    }

    /// @notice Perform the transfers and event emissions for minting leveraged tokens
    /// Fees and discounts transfers and event emissions are not handled here.
    /// @dev no checks for zeros values are performed.
    /// @param collateralToken_ The address of the collateral token.
    /// @param collateralIn The amount of collateral to be taken from the sender.
    /// @param leveragedToken_ The address of the leveraged token.
    /// @param leveragedOut The amount of leveraged to be transferred to the `receiver`.
    /// @param receiver The address of the receiver.

    function _mintLeveragedToken(
        address collateralToken_,
        uint256 collateralIn,
        address leveragedToken_,
        uint256 leveragedOut,
        address receiver
    ) private {
        // tell the world
        emit MintLeveragedToken(_msgSender(), receiver, collateralIn, leveragedOut);
        // mint the tokens to the receiver
        // wake-disable-next-line reentrancy
        IMintable(leveragedToken_).mint(receiver, leveragedOut);
        // take the collateral
        IERC20(collateralToken_).safeTransferFrom(_msgSender(), address(this), collateralIn);
    }

    /// @notice Perform the transfers and event emissions for redeeming leveraged tokens.
    /// Fees and discounts transfers and event emissions are not handled here.
    /// @dev no checks for zeros values are performed.
    /// @param leveragedToken_ The address of the leveraged token.
    /// @param leveragedIn The amount of leveraged tokens to be taken from the sender.
    /// @param collateralToken_ The address of the collateral token.
    /// @param collateralOut The amount of collateral to be transferred to the `receiver`.
    /// @param receiver The address of the receiver.

    function _redeemLeveragedToken(
        address leveragedToken_,
        uint256 leveragedIn,
        address collateralToken_,
        uint256 collateralOut,
        address receiver
    ) private {
        // tell the world
        emit RedeemLeveragedToken(_msgSender(), receiver, leveragedIn, collateralOut);
        // burn the leveraged
        // wake-disable-next-line reentrancy // leveragedToken is trusted
        IBurnableFrom(leveragedToken_).burnFrom(_msgSender(), leveragedIn);
        // return the collateral
        IERC20(collateralToken_).safeTransfer(receiver, collateralOut);
    }

    /// @notice Checks and returns whether a token can be redeemed.
    /// @param token_ The token being checked.
    /// @param amountIn The proposed amount to redeem.
    /// @param tokenBalance_ The amount of the `token_` managed.
    /// @return amountOut the amountIn or tokenBalance whatever is the smaller
    /// @dev never returns a non-positive amountOut. reverts instead

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

    /// @notice Perform a dry run of a mint pegged to calculate the various transfers of tokens.
    /// Fees, discounts and disallows relating to the different incentiveRatios values are calculated as sum, weighted
    /// in proportion, in collateral space, to the amount spent within each collateral ratio boundary.
    /// It essentially performs a definite integral of the fee function.
    /// @param config_ The collateral ratio boundaries and the incentive ratios within each boundary,
    /// for minting pegged tokens.
    /// @param collateralIn The proposed amount of collateral being posted in exchange for pegged tokens.
    /// @param collateralTokenBalance_ The amount of collateral held. This is used to calculate collateral ratios.
    /// @param price The value of a collateral token in terms of the pegged token.
    /// @param peggedTokenBalance_ The amount of pegged tokens issued. This is used to calculate collateral ratios.
    /// @return fee The pro-rated fee.
    /// @return peggedMinted the amount of pegged tokens minted (i.e after fees and discounts)
    /// @return maxCollateral the amount of collateral that is allowed, according to the config

    function _mintPeggedAdjustments(
        ActionIncentive memory config_,
        uint256 collateralIn,
        uint256 collateralTokenBalance_,
        uint256 price,
        uint256 peggedTokenBalance_
    ) private pure returns (uint256 fee, uint256 peggedMinted, uint256 maxCollateral) {
        // we cannot calculate collateral ratio when there are no pegged tokens as it's infinite i.e. (/0)
        if (peggedTokenBalance_ == 0) revert ActionPaused();

        // find the band and it's lower bound where the current collateral ratio is
        // (note we treat the disallow band as any other here, except that it is the terminal band)
        uint band = _findBand(config_, collateralTokenBalance_, price, peggedTokenBalance_, false); // solhint-disable-line explicit-types
        fee = 0;
        peggedMinted = 0;
        maxCollateral = 0;
        // simulate minting until we run out of collateral, adding the fee & collateral as we go
        while (true) {
            uint256 bandFeeRatio = uint256(_incentiveRatio(config_, band)); // no discounts for this action
            if (bandFeeRatio == 1 ether) {
                // fee ratio of 100% means the action is disallowed, and in the lowest band
                break;
            }
            uint256 collateralInBand;
            if (band == 0) {
                // TODO: band 0 doesn't exactly equal _depegged (out by one)
                // TODO: band 1 may also be depegged! - maybe we only allow a single depegged band
                // if we check for _depegged then the phi calc below results in an underflow as band lower bound is 0
                collateralInBand = collateralIn;
            } else {
                uint256 bandLowerBound = _collateralRatioLowerBounds(config_, band);
                uint256 phi = (bandLowerBound * (1 ether - bandFeeRatio)) + bandFeeRatio * 1 ether - 1 ether * 1 ether;
                if (phi == 0) {
                    collateralInBand = collateralIn;
                } else {
                    collateralInBand =
                        (collateralTokenBalance_ * 1 ether * 1 ether) /
                        phi -
                        ((bandLowerBound * peggedTokenBalance_) * 1 ether * 1 ether) /
                        (price * phi);

                    collateralInBand = Math.min(collateralIn, collateralInBand);
                }
            }
            uint256 bandFee = (collateralInBand * bandFeeRatio) / 1 ether;
            maxCollateral += collateralInBand;
            fee += bandFee;
            collateralIn -= collateralInBand;
            uint256 collateralAddedInBand = collateralInBand - bandFee;
            uint256 peggedMintedInBand = (collateralAddedInBand * price * 1 ether) /
                _peggedTokenPrice$(peggedTokenBalance_, collateralTokenBalance_, price);
            peggedMinted += peggedMintedInBand;

            if (collateralIn == 0) {
                // we haverun out of collateral for the simulation
                break;
            }
            // still some collateral left and we're allowed to mint or redeem, so simulate
            collateralTokenBalance_ += collateralAddedInBand;
            peggedTokenBalance_ += peggedMintedInBand;
            if (band == 0) {
                // we are now in the lowest band, so exit
                break;
            }
            band--;
        }
    }

    /// @notice Perform a dry run of a redeem pegged to calculate the various transfers of tokens
    /// Fees and discounts relating to the different incentiveRatios values are calculated as sum, weighted
    /// in proportion, in collateral space, to the amount spent within each collateral ratio boundary.
    /// It essentially performs a definite integral of the fee function.
    /// @param config_ The collateral ratio boundaries and the incentive ratios within each boundary,
    /// for redeeming pegged tokens.
    /// @param peggedIn The given amount of pegged tokens.
    /// @param collateralTokenBalance_ The amount of collateral held.
    /// @param price The value in pegged of each collateral token.
    /// @param peggedTokenBalance_ The balance of pegged tokens minted.
    /// @param reservePoolBalance_ The current balance of the reserve pool.
    /// @return fee the fee charged in collateral tokens.
    /// @return peggedRedeemed the collateral returnable from 'peggedIn' pegged tokens. This has the fee deducted.
    /// @return collateralReturned the collateral returned to the receiver in exchange for the 'peggedRedeemed'
    /// @return extraCollateral the collateral to be got from the reserve pool

    function _redeemPeggedAdjustments(
        ActionIncentive memory config_,
        uint256 peggedIn,
        uint256 collateralTokenBalance_,
        uint256 price,
        uint256 peggedTokenBalance_,
        uint256 reservePoolBalance_
    ) private pure returns (uint256 fee, uint256 peggedRedeemed, uint256 collateralReturned, uint256 extraCollateral) {
        // we cannot calculate collateral ratio when there are no pegged tokens as it's infinite i.e. (/0)
        if (peggedTokenBalance_ == 0) revert ActionPaused();
        // TODO: test for first mint of pegged, in the context of existing and non-existing leveraged tokens

        uint band = _findBand(config_, collateralTokenBalance_, price, peggedTokenBalance_, true); // solhint-disable-line explicit-types
        // simulate redeeming until we run out of pegged tokens, adding the fee & bonus as we go
        // We do this band at a time, pro-rating the resulting fee according to how much collateral was needed in
        // each band entered. We use collateral to pro-rate, rather than collateral ratio which would be simpler, because
        // we multiply the resulting ratios by the collateral for the final fee
        fee = 0;
        peggedRedeemed = 0;
        collateralReturned = 0;
        extraCollateral = 0;
        while (true) {
            uint256 collateralInBand$;
            {
                uint256 peggedInBand;
                if (band == _collateralRatioBandCount(config_) - 1) {
                    // the last band goes on forever
                    peggedInBand = peggedIn;
                } else {
                    uint256 bandUpperBound = _collateralRatioUpperBounds(config_, band);
                    if (bandUpperBound <= 1 ether) {
                        // given the price of the pegged is a proportionate share of the collateral and leveraged tokens are worthless
                        // we redeem all of it (at the depegged rate) in this band, at the rate for the band
                        peggedInBand = peggedIn;
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
                // slither-disable-next-line divide-before-multiply
                collateralInBand$ =
                    (peggedInBand * _peggedTokenPrice$(peggedTokenBalance_, collateralTokenBalance_, price)) /
                    price;
                collateralReturned += collateralInBand$;
                peggedIn -= peggedInBand;
                peggedRedeemed += peggedInBand;
                peggedTokenBalance_ -= peggedInBand;
            }
            {
                // we now switch to calculations in collateral
                int256 bandIncentiveRatio = _incentiveRatio(config_, band);
                if (bandIncentiveRatio > 0) {
                    // tally the weighted fee ratios
                    // we keep peggedFee at a factor of 1 ether too much to avoid losing precison
                    // then divide by 1 ether at the end
                    fee += (collateralInBand$ * uint256(bandIncentiveRatio)) / 1 ether;
                } else if (bandIncentiveRatio < 0) {
                    // slither-disable-next-line divide-before-multiply as any truncation below, benefits the reserve pool by a smidgin
                    uint256 extraCollateralInBand = (collateralInBand$ * uint256(-bandIncentiveRatio)) /
                        (1 ether * 1 ether);
                    // tally the discounts
                    if (extraCollateralInBand <= reservePoolBalance_) {
                        reservePoolBalance_ -= extraCollateralInBand;
                    } else {
                        // although we don't get the full amount of collateral from the reserve pool, we are happy
                        // because that extra collateral isn't used in the collateral balance it doesn't affect the
                        // simulation, only the collateral returned
                        extraCollateralInBand = reservePoolBalance_;
                        reservePoolBalance_ = 0;
                    }
                    extraCollateral += extraCollateralInBand;
                }
            }
            if (peggedIn == 0) {
                // no pegged tokens left to simulate redeeming them
                break;
            }
            // still some pegged tokens left and we're allowed to redeem
            collateralTokenBalance_ -= collateralInBand$ / 1 ether;

            band++;
        }
        // TODO: calculate the extra collateral and fee at 1e36 in the above loop too, for more precision
        collateralReturned = (collateralReturned + extraCollateral * 1 ether - fee) / 1 ether;
        // as we didn't divide by 1 ether in the above loop, we do it now.
        fee /= 1 ether;
    }

    /// @dev Balances is used to reduce stack space for the functions it is used in.
    /// @notice Contains the balances of the three tokens used in this contract
    struct Balances {
        uint256 collateral;
        uint256 pegged;
        uint256 leveraged;
    }

    /// @notice Perform a dry run of a mint pegged to calculate the various transfers of tokens.
    /// Fees, discounts and disallows relating to the different incentiveRatios values are calculated as sum, weighted
    /// in proportion, in collateral space, to the amount spent within each collateral ratio boundary.
    /// It essentially performs a definite integral of the fee function.
    /// @param config_ The collateral ratio boundaries and the incentive ratios within each boundary,
    /// for minting leveraged tokens.
    /// @param collateralIn The given amount of collateral tokens, assumed to be > 0.
    /// @param balanceOf The amount of collateral, pegged and leveraged tokens managed.
    /// @param price The value in pegged of each collateral token.
    /// @param reservePoolBalance_ The current balance of the reserve pool.
    /// @return fee The fee charged in collateral tokens.
    /// @return leveragedMinted The amount of leveraged tokens minted.
    /// @return extraCollateral The collateral to be got from the reserve pool to make a discount

    function _mintLeveragedAdjustments(
        ActionIncentive memory config_,
        uint256 collateralIn,
        Balances memory balanceOf,
        uint256 price,
        uint256 reservePoolBalance_
    ) private pure returns (uint256 fee, uint256 leveragedMinted, uint256 extraCollateral) {
        // we cannot calculate collateral ratio when there are no pegged tokens as it's infinite i.e. (/0)
        // slither-disable-next-line incorrect-equality
        if (balanceOf.pegged == 0) revert ActionPaused();
        // we can't meaningfully do anything with leveraged tokens as their value is zero
        if (_isDepegged(balanceOf.collateral, price, balanceOf.pegged)) revert ActionPaused();

        // simulate minting leveaged tokens from current collateral ratio upwards,
        // applying the incentive at the correct ratio as we go.
        // We do this band at a time, pro-rating the resulting fee according to how much collateral was needed in
        // each band entered. We use collateral to pro-rate, rather than collateral ratio which would be simpler, because
        // we multiply the resulting ratios by the collateral for the final fee
        uint band = _findBand(config_, balanceOf.collateral, price, balanceOf.pegged, true); // solhint-disable-line explicit-types

        // simulate minting until we run out of collateral, adding the fee & bonus as we go
        fee = 0;
        leveragedMinted = 0;
        extraCollateral = 0;
        while (true) {
            int256 bandIncentiveRatio = _incentiveRatio(config_, band);
            uint256 collateralInBand;
            if (band == _collateralRatioBandCount(config_) - 1) {
                // the last band has no upper bound
                collateralInBand = collateralIn;
            } else {
                // the collateral needed to be deposited to reach the upper bound of the band taking fees into account
                // The fee is deducted because it goes to the fee receiver
                // The discount is added because it ends up in the collateral balance and more leveraged tokens go to the receiver
                // note that 1 - bandIncentiveRatio must always be positive, which it is as:
                //   * fees < 1 ether. if is was = 1 ether then this would be a disallow band.
                //   * discount < 0
                // slither-disable-next-line divide-before-multiply
                collateralInBand =
                    ((_collateralRatioUpperBounds(config_, band) * balanceOf.pegged - balanceOf.collateral * price) *
                        1 ether) /
                    (price * uint256(1 ether - bandIncentiveRatio));
                // can't have more collateral in the band that there is collateral left
                collateralInBand = Math.min(collateralIn, collateralInBand);
            }
            uint256 bandFee = 0;
            uint256 extraCollateralInBand = 0;
            if (bandIncentiveRatio > 0) {
                bandFee = (collateralInBand * uint256(bandIncentiveRatio)) / 1 ether;
                // tally the weighted fee ratios
                fee += bandFee;
            } else if (bandIncentiveRatio < 0) {
                // slither-disable-next-line divide-before-multiply as any truncation benefits slightly the reserve pool
                extraCollateralInBand = (collateralInBand * uint256(-bandIncentiveRatio)) / 1 ether;
                // tally the discounts
                if (extraCollateralInBand <= reservePoolBalance_) {
                    reservePoolBalance_ -= extraCollateralInBand;
                } else {
                    // TODO:
                    // if there is insufficient collateral in the reserve pool then we comtinue the loop at the same band,
                    // first setting the discount to zero. This is because the reserve (extra) collateral ends up in the
                    // collateral balance and so affects the simulation
                    extraCollateralInBand = reservePoolBalance_;
                    reservePoolBalance_ = 0;
                }
                extraCollateral += extraCollateralInBand;
            }
            {
                uint256 leveragedInBand = _leveragedTokensForCollateral(
                    collateralInBand + extraCollateralInBand - bandFee,
                    balanceOf.leveraged,
                    balanceOf.pegged,
                    balanceOf.collateral,
                    price
                );
                leveragedMinted += leveragedInBand;
                balanceOf.leveraged += leveragedInBand;
            }
            collateralIn -= collateralInBand;
            // slither-disable-next-line incorrect-equality
            if (collateralIn == 0) {
                // we have run out of collateral for the simulation
                // collateralTokenBalance_ += collateralInBand - bandFee + extraCollateralInBand;
                break;
            }
            // still some collateral left, so add this collateral to take us to the next band
            // here the reserve pool discount results in more collateral ending up in the minter
            balanceOf.collateral += collateralInBand - bandFee + extraCollateralInBand;
            band++;
        }
    }
    /// @notice Perform a dry run of a redeem leveraged to calculate the various transfers of tokens
    /// Fees, discounts and disallows relating to the different incentiveRatios values are calculated as sum, weighted
    /// in proportion, in collateral space, to the amount spent within each collateral ratio boundary.
    /// It essentially performs a definite integral of the fee function.
    /// @param config_ The collateral ratio boundaries and the incentive ratios within each boundary,
    /// for redeeming leveraged tokens.
    /// @param leveragedIn The given amount of leveraged tokens.
    /// @param startCollateralTokenBalance The amount of collateral held.
    /// @param price The value in pegged of each collateral token.
    /// @param peggedTokenBalance_ The balance of pegged tokens managed.
    /// @param leveragedTokenBalance_ The current balance of the reserve pool.
    /// @return fee the fee charged in collateral tokens.
    /// @return leveragedRedeemed the leveraged tokens to be burned.
    /// @return collateralOut the collateral returned to the receiver in exchange for the `leveragedRedeemed`

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
        // we can't meaningfully do anything with leveraged tokens as their value is zero
        // and we an do this once, here, and not in the loop below, because redeeming tokens, albeit reducing the
        // collateral ratio, will never cause a depeg.
        if (_isDepegged(startCollateralTokenBalance, price, peggedTokenBalance_)) revert ActionPaused();

        uint256 collateralIn = _collateralForLeveragedTokens(
            leveragedIn,
            leveragedTokenBalance_,
            peggedTokenBalance_,
            startCollateralTokenBalance,
            price
        );
        // find the band and it's lower bound where the current collateral ratio is
        // (note we treat the disallow band as any other here, except that it is the terminal band)
        uint band = _findBand(config_, startCollateralTokenBalance, price, peggedTokenBalance_, false); // solhint-disable-line explicit-types
        // simulate redeeming until we run out of leveraged tokens, adding the fee & reserve collateral as we go

        fee = 0;
        collateralOut = 0;
        uint256 collateralTokenBalance_ = startCollateralTokenBalance;
        while (true) {
            uint256 bandLowerBound = _collateralRatioLowerBounds(config_, band);
            uint256 bandFeeRatio = uint256(_incentiveRatio(config_, band)); // no discounts for this action
            if (bandFeeRatio == 1 ether) {
                // fee ratio of 100% means the action is disallowed, and in the lowest band
                break;
            }
            // slither-disable-next-line divide-before-multiply
            uint256 collateralInBand = (collateralTokenBalance_ * price - bandLowerBound * peggedTokenBalance_) / price;
            collateralInBand = Math.min(collateralIn, collateralInBand);
            // slither-disable-next-line divide-before-multiply
            uint256 bandFee = (collateralInBand * uint256(bandFeeRatio)) / 1 ether;
            collateralOut += collateralInBand - bandFee;
            fee += bandFee;
            collateralIn -= collateralInBand;
            // slither-disable-next-line incorrect-equality
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
        leveragedRedeemed = _leveragedTokensForCollateral(
            collateralOut + fee,
            leveragedTokenBalance_,
            peggedTokenBalance_,
            startCollateralTokenBalance,
            price
        );
    }

    /// @notice Returns the collateral ratio band given `collateralTokenBalance_`, `collateralPrice`, and
    /// `peggedTokenBalance_`.
    /// @param config_ Contains the collateral ratio boundaries to be searched.
    /// for redeeming leveraged tokens.
    /// @param collateralTokenBalance_ The amount of collateral managed. Used to calculate the modified collateral ratio.
    /// @param collateralPrice The price of the collateral. Used to calculate the modified collateral ratio.
    /// @param peggedTokenBalance_ The amount of pegged tokens managed. Used to calculate the modified collateral ratio.
    /// @param atLower {bool} Indicates the starting point for the search, i.e. if it true the search will go toward
    /// increasing collateral ratio.

    function _findBand(
        ActionIncentive memory config_,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice,
        uint256 peggedTokenBalance_,
        bool atLower
    )
        private
        pure
        returns (
            uint band // solhint-disable-line explicit-types
        )
    {
        uint256 collateralRatio_ = _collateralRatio(collateralTokenBalance_, collateralPrice, peggedTokenBalance_);
        for (band = 0; band < _collateralRatioBandCount(config_) - 1; band++) {
            uint256 bandUpperBound = _collateralRatioUpperBounds(config_, band);
            if (atLower) {
                if (collateralRatio_ < bandUpperBound) break;
            } else {
                if (collateralRatio_ <= bandUpperBound) break;
            }
        }
    }

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
    function _peggedTokenPrice$(
        uint256 peggedTokenBalance_,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice
    ) private pure returns (uint256 nav$) {
        // TODO if the collateral ratio is 0, nav is 0 - check that this doesn't just work out
        // slither-disable-next-line incorrect-equality
        if (peggedTokenBalance_ == 0) {
            nav$ = 1 ether * 1 ether;
        } else {
            if (_isDepegged(collateralTokenBalance_, collateralPrice, peggedTokenBalance_)) {
                // the nav becomes the value of the collateral
                nav$ = (collateralTokenBalance_ * collateralPrice * 1 ether) / peggedTokenBalance_;
            } else {
                // this is the invariant collateral value  = pegged value + leveraged value
                nav$ = 1 ether * 1 ether;
            }
        }
    }

    /// @dev pegged value must not be greater than collateral value, i.e. it's depegged

    function _leveragedTokensForCollateral(
        uint256 collateralIn,
        uint256 leveragedTokenBalance_,
        uint256 peggedTokenBalance_,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice
    ) private pure returns (uint256 leveragedTokens) {
        // this is the first derivative of the leveraged balance with respect to the collateral balance
        // in the invariant: collateral value = leveraged value + pegged value.
        // Note: if leveraged balance is 0 this returns 0, so we have to bootstrap this contract with some leveraged tokens
        //       or work out the correct equation, assuming there is one solution:
        //           leveraged nav can vary or leveraged balance can vary
        if (leveragedTokenBalance_ > 0) {
            int256 collateralDifference = int256(collateralTokenBalance_ * collateralPrice) -
                int256(peggedTokenBalance_ * 1 ether);
            if (collateralDifference <= 0) {
                leveragedTokens = 0;
            } else {
                leveragedTokens =
                    (collateralIn * collateralPrice * leveragedTokenBalance_) /
                    uint256(collateralDifference);
            }
        } else {
            leveragedTokens = (collateralIn * collateralPrice) / 1 ether; // TODO: check if there can be any starting price seems moire natural to price it on the same scale as the collateral token
        }
    }

    function _leveragedTokensForPegged(
        uint256 peggedIn,
        uint256 leveragedTokenBalance_,
        uint256 peggedTokenBalance_,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice
    ) private pure returns (uint256 leveragedTokens) {
        // this is the first derivative of the legeraged balance with respect to the collateral balance
        // in the invariant: collateral value = leveraged value + pegged value.
        if (leveragedTokenBalance_ > 0) {
            uint256 collateralValue = collateralTokenBalance_ * collateralPrice;
            uint256 peggedValue = peggedTokenBalance_ * 1 ether;
            if (peggedValue >= collateralValue) {
                leveragedTokens = 0;
            } else {
                leveragedTokens = (peggedIn * 1 ether * leveragedTokenBalance_) / (collateralValue - peggedValue);
            }
        } else {
            leveragedTokens = peggedIn; // TODO: check if there can be any starting price seems moire natural to price it on the same scale as the collateral token
        }
    }

    /// @notice Returns the amount of collateral equivalent to the given amount of leveraged tokens.
    /// @param forLeveraged The given amount of leveraged tokens.
    /// @param leveragedTokenBalance_ The total supply of leveraged tokens, required to be > 0.
    /// @param peggedTokenBalance_ The amount of pegged tokens managed.
    /// @param collateralTokenBalance_ The amount of collateral managed.
    /// @param collateralPrice The price of collateral in terms of pegged token underlying.
    /// @return collateral The amount of collateral `forLeveraged` leveraged tokens are worth.

    // TODO: whereever there is a collateral balance and price passed, pass the product instead.
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

    /// @notice Returns a modified collateral ratio.
    /// The real collateral ratio (collateral value / pegged value) behaves badly in three ways:
    /// 1) when the number of pegged tokens drops to 0, collateral ratio becomes infinite
    /// 2) when nothing has been minted it is undefined then snaps to 1 when either token is minted
    /// 3) it floors at 1 because below 1, the value of a pegged token is it's proportional share of the collteral.
    // TODO:
    /// we solve all three issues by adding 1 to the collateral value and 1 to the pegged token value.
    /// This gives a very good approximation to the real collateral ratio above 1 and a useful value below 1.
    /// Its useful because it allows us to create different incentive ratios when the system depegs.
    /// The collateral ratio when only leveraged tokens have been minted is then just the collateral value.
    /// The value of a leveraged token is then the same as the value of a collaterla token.
    /// Unfortunately the value truncates too much returning a lower than real collateral value.
    /// The solution adopted is to scale the 1 added to the collateral value by the collateral price. This gives a
    /// better result when the system is pegged.
    /// @dev this is a modified theoretical collateral ratio
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
            // TODO: max leverage ratio (Aladdin use 100e18)?
            ratio = type(uint256).max;
        } else {
            // TODO: modify the equation so it doesn't go infinite if there is no collateral
            // TODO: rearrange the equation below so it doesn't divide twice
            ratio =
                (1 ether * 1 ether) /
                (1 ether - (peggedTokenBalance_ * 1 ether * 1 ether) / (collateralTokenBalance_ * collateralPrice));
            // TODO: if (ratio > MAX_LEVERAGE_RATIO) ratio = MAX_LEVERAGE_RATIO;
        }
    }

    /// @notice Returns the amount of leveraged tokens being managed
    function _leveragedTokenBalance(address leveragedToken_) private view returns (uint256) {
        return IERC20(leveragedToken_).totalSupply();
    }

    /// @notice Returns the amount of collateral being managed
    function _collateralTokenBalance(address collateralToken_) private view returns (uint256) {
        return IERC20(collateralToken_).balanceOf(address(this));
    }

    // fetching collateral price in terms of the pegged tokens
    // -------------------------------------------------------

    /// @notice Returns the safe price for the collateral token.
    /// @dev Checks safe price non-zero.
    function _fetchSafePrice(address priceOracle_) private view returns (uint256 safe) {
        safe = IPriceOracle(priceOracle_).latestAnswer() * 10 ** (18 - IPriceOracle(priceOracle_).decimals());
        if (safe == 0) {
            revert ZeroOraclePrice();
        }
    }

    /// @notice Returns the min price for the collateral token.
    /// If the safe price is valid it is returned, else the min price.
    /// @dev Checks the returned price is non-zero.
    function _fetchMinPrice(address priceOracle_) private view returns (uint256 min) {
        min = _fetchSafePrice(priceOracle_);
    }

    /// @notice Returns the max price for the collateral token.
    /// If the safe price is valid it is returned, else the max price.
    /// @dev Checks the returned price is non-zero.
    function _fetchMaxPrice(address priceOracle_) private view returns (uint256 max) {
        max = _fetchSafePrice(priceOracle_);
    }
}
