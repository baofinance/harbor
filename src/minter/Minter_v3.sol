// SPDX-License-Identifier: MIT
// coding standards by https://www.rareskills.io/post/solidity-style-guide
// and https://docs.soliditylang.org/en/latest/style-guide.html
pragma solidity 0.8.30;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Token} from "@bao/Token.sol";
import {TokenHolder, ITokenHolder} from "@bao/TokenHolder.sol";

import {BaoOwnableRoles} from "@bao/BaoOwnableRoles.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {IMinter_v3} from "src/interfaces/IMinter_v3.sol";

// different ERC20 mint/burn interfaces
import {IMintable} from "@bao/interfaces/IMintable.sol";
import {IBurnable} from "@bao/interfaces/IBurnable.sol";
import {IBurnableFrom} from "@bao/interfaces/IBurnableFrom.sol";
import {IBurnable2Arg} from "@bao/interfaces/IBurnable2Arg.sol";

import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {IReservePool} from "src/interfaces/IReservePool.sol";

import {ConfigIncentiveLib} from "src/minter/library/ConfigIncentiveLib.sol";
import {Config_v1} from "src/minter/library/Config_v1.sol";

/// @title Bao Minter
/// @author rootminus0x1 based on (albeit significantly modified) Aladdin's FX system
/// @notice Provides a gas-efficient, feature-rich implementation for the `IMinter` interface.
/// Functions are provided for users to mint (for wrapped collateral) and redeem (for wrapped collateral) pegged and leveraged tokens
/// ### Pegged tokens
/// Pegged tokens are ERC20 tokens that are pegged to some price provided by the `priceOracle`.
/// Pegged tokens have value, not just because they provide exposure to a price, for example, a real world asset,
/// but they can also be deposited into one of the stability pools for a reward.
/// <br>
/// Note:
/// * This contract must be given access to mint the pegged tokens by the owners of that pegged token.
/// * This contract does not assume it is the only minter of the pegged tokens. Instead it tracks how many it has
///   minted and
/// ensures that it will not redeem more than it has minted. Pegged tokened minted elsewhere can be used here.
/// * This contract provides the pegging mechanism.
/// #### Price Stability
/// The price stability is provided by a set of stability pools which utilise protected functionality provided by this
/// contract to do so.
/// ### Leveraged Tokens
/// Leveraged tokens are ERC20 tokens that are minted only by this contract. These tokens have value in that they can be
/// redeemed for wrapped collateral at a leveraged ratio, hence the name 'leveraged token'.
/// The leverage mechanism is provided by this contract and is designed such that the leverage ratio increases as the
/// underlying collateral ratio decreases. The leveraged ratio is capped at 100.
/// ### Collateral Ratio
/// The collateral ratio value returned by the this contract is the value of the underlying collateral tokens divided by the value
/// of the pegged tokens, not assuming one pegged token's value is 1 - if the underlying collateral value is less than the
/// value of the underlying collateral, then the pegged token is valued as it's share of the underlying collateral. This effectively
/// places a lower limit on the collateral ratio of 1.
/// The collateral ratio used internally assumes the pegged token value is 1. This allows the collateral ratio to reach 0.
/// and consequently allows the configuration of fees/discounts to be applied in the event of a depeg.
/// ### Fees, discounts and disallows
/// Fees, discounts and disallows are defined by the config. Two arrays, one defining fee/discount/disallow values
/// between -1 and 1, and the other defining the collateral ratio levels at which those values apply.
/// <ul>
/// <li> positive values refer to fees as a ratio of the input tokens, e.g. a fee for minting pegged/leverage tokens would
///   be levied as a portion of the collateral tokens supplied, and a fee for redeeming a token would be a portion of
///   the pegged or leveraged tokens supplied and revalued at their actual price (i.e. pegged tokens can have a price less than 1)
///   at the given collateral ratio level.
/// <li> negative values refer to discounts. The collateral needed to make up the discount is retrieved from the reserve
///   pool. If the reserve pool does not have sufficient collateral to provide the full discount, the discount it can provide is.
/// <li> values == 1 ether are treated as a 'disallow', i.e. the action being requested is disallowed at that collateral
///   ratio level. The interpretation is that the fee is 100% and so we don't apply that. Fees are expected to be much lower than 100%
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
/// Stability pools know about the minter contract they are offering a rebalance service to and set themselves up to use
/// The collateral ratio stored in this contract's config to allow or disallow liquidation calls to them.
/// ### Harvesting
/// Harvesting becomes available to be executed, transferring to the stability pools the value accrued by holding wrapped collateral
/// instead of underlying collateral. A portion of that is handed to the caller of the harvest function as a reward.
/// @dev Uses UUPS proxy, erc7201 storage
/// @dev As openzeppelin's validator doesn't currently support external libraries
/// (see issue: https://github.com/OpenZeppelin/openzeppelin-upgrades/issues/52)
/// we add this:
/// @custom:oz-upgrades-unsafe-allow external-library-linking
/// @custom:oz-upgrades-from src/minter/Minter_v2.sol:Minter_v2
// solhint-disable-next-line contract-name-capwords
contract Minter_v3 is
    Initializable,
    UUPSUpgradeable,
    ContextUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    BaoOwnableRoles,
    TokenHolder,
    IMinter,
    IMinter_v3
{
    using SafeERC20 for IERC20;

    /// @notice raised when the signature for the pegged token's burn function is not known
    error UnrecognisedBurnSignature(string signature);

    ///////////////
    // Constants //
    ///////////////

    /// @notice The role that allows access to the zero fee versions of the functions.
    uint256 public constant ZERO_FEE_ROLE = _ROLE_0;

    /// @notice The role that allows access to the sweep function.
    uint256 public constant HARVESTER_ROLE = _ROLE_1;

    /// @dev the maximum leverage ratio - used to calculate the leverage return on redeeming pegged tokens for leveraged
    uint256 private constant _LEVERAGE_RATIO_CAP = 20 ether;

    ////////////////
    // Immutables //
    ////////////////

    // these variables are set in the constructor, not the initializer, to improve contract size and gas usage
    // to change them the contract must be upgraded
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable WRAPPED_COLLATERAL_TOKEN; // this is the wrapped token
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable PEGGED_TOKEN;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable LEVERAGED_TOKEN;
    // the type of burn signature for burning pegged tokens
    enum BurnSignature {
        Burn1Arg,
        Burn2Arg,
        BurnFrom
    }
    /// @notice The burn signature for the pegged token.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    BurnSignature private immutable _BURN_SIGNATURE;

    /////////////
    // Storage //
    /////////////

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
        // we keep track of pegged tokens as they can be minted through other rmeans
        uint256 peggedTokenBalance; //                  256
        // we keep track of underlying collateal tokens as they are the collateral, not the wrapped collateral tokens
        uint256 underlyingCollateral; //                256
        //                                             slot
        // @custom:security non-reentrant
        address reservePool; //                         160
        //                                             slot
        // @custom:security non-reentrant
        address feeReceiver; //                         160
        //                                             slot
        address priceOracle; //                         160
        //                                             slot*2*4
        ConfigIncentiveLib.ActionIncentive[4] incentiveConfig;
    }

    ////////////////////
    // Initialisation //
    ////////////////////

    // UUPSUpgradeable functions
    // -------------------------

    function initialize(address owner_) external initializer {
        // initialise all the state variables
        _initializeOwner(owner_);
        __UUPSUpgradeable_init();
        __Context_init();
        __ReentrancyGuardTransient_init();
        MinterStorage storage $ = _getMinterStorage();
        $.peggedTokenBalance = 0;
        $.underlyingCollateral = 0;

        // initialise the config to something that works
        Config_v1.defaultIncentive($.incentiveConfig);
    }
    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// https://forum.openzeppelin.com/t/what-does-disableinitializers-function-mean/28730
    /// @custom:oz-upgrades-unsafe-allow constructor
    // slither-disable-next-line missing-zero-check // sanityCheckERC20Token is called
    constructor(
        address collateralToken_,
        address peggedToken_,
        address leveragedToken_,
        string memory peggedBurnSignature
    ) {
        _disableInitializers();

        Token.sanityCheckERC20Token(collateralToken_);
        // slither-disable-next-line missing-zero-check
        WRAPPED_COLLATERAL_TOKEN = collateralToken_;
        Token.sanityCheckERC20Token(leveragedToken_);
        // slither-disable-next-line missing-zero-check
        LEVERAGED_TOKEN = leveragedToken_;
        Token.sanityCheckERC20Token(peggedToken_);
        // slither-disable-next-line missing-zero-check
        PEGGED_TOKEN = peggedToken_;

        // get the type of burn model used by the pegged token
        bytes4 burnSelector = bytes4(keccak256(bytes(peggedBurnSignature)));
        if (burnSelector == bytes4(keccak256("burn(address,uint256)"))) {
            _BURN_SIGNATURE = BurnSignature.Burn2Arg;
        } else if (burnSelector == bytes4(keccak256("burn(uint256)"))) {
            _BURN_SIGNATURE = BurnSignature.Burn1Arg;
        } else if (burnSelector == bytes4(keccak256("burnFrom(address,uint256)"))) {
            _BURN_SIGNATURE = BurnSignature.BurnFrom;
        } else {
            revert UnrecognisedBurnSignature(peggedBurnSignature);
        }
    }

    /// @notice The check that allow this contract to be upgraded:
    /// In UUPS proxies the implementation is responsible for upgrading itself
    /// only owners can upgrade this contract.
    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    /// @notice Returns true if a given interface is supported.
    /// @dev See {IERC165-supportsInterface}.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(IMinter).interfaceId ||
            interfaceId == type(ITokenHolder).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ///////////////////////////
    // Public View Functions //
    ///////////////////////////

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
        return _leveragedTokenBalance();
    }

    /// @inheritdoc IMinter
    function collateralTokenBalance() external view override returns (uint256) {
        MinterStorage storage $ = _getMinterStorage();
        return $.underlyingCollateral;
    }

    /// @inheritdoc IMinter
    function config() external view returns (Config memory config_) {
        MinterStorage storage $ = _getMinterStorage();
        config_ = Config_v1.copyIncentivesBack($.incentiveConfig);
    }

    /// @inheritdoc IMinter
    function collateralRatio() external view override returns (uint256 collateralRatio_) {
        MinterStorage storage $ = _getMinterStorage();
        collateralRatio_ = _collateralRatio(
            $.underlyingCollateral,
            _fetchMid($.priceOracle).price,
            $.peggedTokenBalance
        );
    }

    /// @inheritdoc IMinter
    function leverageRatio() external view override returns (uint256 ratio) {
        MinterStorage storage $ = _getMinterStorage();

        // slither-disable-next-line unused-return we don't need the leveraged value here
        OracleData memory oracle = _fetchMid($.priceOracle);
        ratio = _leverageRatio($.peggedTokenBalance, $.underlyingCollateral, oracle.price);
    }

    /// @inheritdoc IMinter
    function leveragedTokenPrice() external view override returns (uint256 nav) {
        MinterStorage storage $ = _getMinterStorage();
        OracleData memory oracle = _fetchMid($.priceOracle);
        (uint256 collateralValueE36, uint256 peggedValueE36) = _tokenValuesE36(
            $.peggedTokenBalance,
            $.underlyingCollateral,
            oracle.price
        );
        nav = _leveragedTokenPriceE36(collateralValueE36, peggedValueE36, _leveragedTokenBalance()) / 1 ether;
    }

    function _leveragedTokenPriceE36(
        uint256 collateralValueE36,
        uint256 peggedValueE36,
        uint256 leveragedTokenBalance_
    ) internal pure returns (uint256 navE36) {
        if (leveragedTokenBalance_ == 0) {
            navE36 = 1e36;
        } else {
            // by definition the leveraged token value is the difference between the collateral value and pegged value
            navE36 = Math.mulDiv(collateralValueE36 - peggedValueE36, 1e18, leveragedTokenBalance_);
        }
    }

    /// @inheritdoc IMinter
    function peggedTokenPrice() external view override returns (uint256 nav) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        if (peggedTokenBalance_ == 0) {
            nav = 1 ether;
        } else {
            OracleData memory oracle = _fetchMid($.priceOracle);
            (, uint256 peggedValueE36) = _tokenValuesE36(peggedTokenBalance_, $.underlyingCollateral, oracle.price);
            nav = peggedValueE36 / peggedTokenBalance_;
        }
    }

    /// @inheritdoc IMinter
    function redeemPeggedForCollateralRatio(
        uint256 targetCollateralRatio
    ) external view returns (uint256 peggedForCollateral, uint256 peggedForLeveraged) {
        // TODO: add a check for no pegged tokens
        MinterStorage storage $ = _getMinterStorage();
        OracleData memory oracle = _fetchMax($.priceOracle);
        uint256 collateralTokenBalance_ = $.underlyingCollateral;
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        uint256 currentCollateralRatio = _collateralRatio(collateralTokenBalance_, oracle.price, peggedTokenBalance_);
        if (targetCollateralRatio > currentCollateralRatio) {
            if (currentCollateralRatio < 1 ether) {
                // we're depegged, so all we can do is redeem them all
                peggedForCollateral = peggedTokenBalance_;
            } else {
                peggedForCollateral =
                    (targetCollateralRatio * peggedTokenBalance_ - collateralTokenBalance_ * oracle.price) /
                    (targetCollateralRatio - 1 ether);
            }
            peggedForLeveraged =
                peggedTokenBalance_ - Math.mulDiv(collateralTokenBalance_, oracle.price, targetCollateralRatio);
        } else {
            peggedForCollateral = 0;
            peggedForLeveraged = 0;
        }
    }

    // incentive ratios
    // ----------------

    // solhint-disable-next-line explicit-types
    function _lookupIncentiveRatio(uint action) internal view returns (int256 incentiveRatio) {
        MinterStorage storage $ = _getMinterStorage();
        OracleData memory oracle = _fetchMid($.priceOracle);
        uint256 collateralTokenBalance_ = $.underlyingCollateral;
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;

        ConfigIncentiveLib.ActionIncentive memory config_ = $.incentiveConfig[action];
        // solhint-disable-next-line explicit-types
        uint band = _findBand(config_, collateralTokenBalance_, oracle.price, peggedTokenBalance_, false);
        incentiveRatio = ConfigIncentiveLib._incentiveRatio(config_, band);
    }

    /// @inheritdoc IMinter
    function mintPeggedTokenIncentiveRatio() external view override returns (int256 incentiveRatio) {
        incentiveRatio = _lookupIncentiveRatio(Config_v1.MINT_PEGGED);
    }

    /// @inheritdoc IMinter
    function redeemPeggedTokenIncentiveRatio() external view override returns (int256 incentiveRatio) {
        incentiveRatio = _lookupIncentiveRatio(Config_v1.REDEEM_PEGGED);
    }

    /// @inheritdoc IMinter
    function mintLeveragedTokenIncentiveRatio() external view override returns (int256 incentiveRatio) {
        incentiveRatio = _lookupIncentiveRatio(Config_v1.MINT_LEVERAGED);
    }

    /// @inheritdoc IMinter
    function redeemLeveragedTokenIncentiveRatio() external view override returns (int256 incentiveRatio) {
        incentiveRatio = _lookupIncentiveRatio(Config_v1.REDEEM_LEVERAGED);
    }

    // dry run functions
    // here we simulate a mint or redeem taking into account who is making the call for balance.
    // we don't take into account the allowance the Minter contract has for the msgSender because
    // most user interfaces, where the dry run functions are expected to be called will leave changing
    // allowance until the actual mint or redeem function is called.
    // in other words we don't require all conditions to be met for the dry run to succeed if those conditions
    // require gas to be spent on a transaction.

    /// @inheritdoc IMinter
    function mintPeggedTokenDryRun(
        uint256 wrappedCollateralIn
    )
        external
        view
        returns (
            int256 incentiveRatio,
            uint256 wrappedFee,
            uint256 wrappedCollateralUsed,
            uint256 peggedMinted,
            uint256 price,
            uint256 rate
        )
    {
        return mintPeggedTokenDryRun(wrappedCollateralIn, type(uint256).max);
    }

    /// @notice Dry run of a capped mint: computes outcome if total fee is capped at maxFeeRatio of collateral used.
    /// @param wrappedCollateralIn The proposed amount of wrapped collateral.
    /// @param maxFeeRatio The maximum overall fee ratio (18 decimals). e.g. 0.05 ether = 5%.
    function mintPeggedTokenDryRun(
        uint256 wrappedCollateralIn,
        uint256 maxFeeRatio
    )
        public
        view
        returns (
            int256 incentiveRatio,
            uint256 wrappedFee,
            uint256 wrappedCollateralUsed,
            uint256 peggedMinted,
            uint256 price,
            uint256 rate
        )
    {
        wrappedCollateralIn = Token.allOfQuiet(_msgSender(), WRAPPED_COLLATERAL_TOKEN, wrappedCollateralIn);
        MinterStorage storage $ = _getMinterStorage();
        OracleData memory oracle = _fetchMid($.priceOracle);
        price = oracle.price;
        rate = oracle.rate;
        uint256 maxFeeE36 = maxFeeRatio == type(uint256).max
            ? type(uint256).max
            : Math.mulDiv(wrappedCollateralIn, maxFeeRatio, 1 ether) * oracle.rate;
        uint256 underlyingCollateralAdded;
        (wrappedFee, peggedMinted, wrappedCollateralUsed, underlyingCollateralAdded) = _mintPeggedAdjustments(
            $.incentiveConfig[Config_v1.MINT_PEGGED],
            wrappedCollateralIn,
            CollateralRatioData($.underlyingCollateral, oracle.price, oracle.rate, $.peggedTokenBalance),
            maxFeeE36
        );
        // slither-disable-next-line incorrect-equality
        incentiveRatio = wrappedCollateralUsed == 0
            ? _lookupIncentiveRatio(Config_v1.MINT_PEGGED)
            : int256(Math.mulDiv(wrappedFee, 1 ether, wrappedCollateralUsed));
    }

    /// @inheritdoc IMinter
    function redeemPeggedTokenDryRun(
        uint256 peggedIn
    )
        external
        view
        returns (
            int256 incentiveRatio,
            uint256 wrappedFee,
            uint256 wrappedDiscount,
            uint256 peggedRedeemed,
            uint256 wrappedCollateralReturned,
            uint256 price,
            uint256 rate
        )
    {
        peggedIn = Token.allOfQuiet(_msgSender(), PEGGED_TOKEN, peggedIn);
        MinterStorage storage $ = _getMinterStorage();
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        peggedIn = _redeemableQuiet(peggedIn, peggedTokenBalance_);
        OracleData memory oracle = _fetchMid($.priceOracle);
        price = oracle.price;
        rate = oracle.rate;
        peggedRedeemed = peggedIn;
        uint256 peggedPriceE36;
        (wrappedFee, wrappedDiscount, wrappedCollateralReturned, , peggedPriceE36) = _redeemPeggedAdjustments(
            $.incentiveConfig[Config_v1.REDEEM_PEGGED],
            peggedIn,
            CollateralRatioData($.underlyingCollateral, price, rate, peggedTokenBalance_),
            IERC20(WRAPPED_COLLATERAL_TOKEN).balanceOf($.reservePool)
        );
        // slither-disable-next-line incorrect-equality
        if (peggedRedeemed == 0) {
            incentiveRatio = _lookupIncentiveRatio(Config_v1.REDEEM_PEGGED);
        } else {
            uint256 incentive;
            int256 sign;
            if (wrappedFee > wrappedDiscount) {
                incentive = wrappedFee - wrappedDiscount;
                sign = 1;
            } else {
                incentive = wrappedDiscount - wrappedFee;
                sign = -1;
            }
            incentiveRatio =
                sign * int256(Math.mulDiv(incentive * 1e18, price * rate, peggedRedeemed * peggedPriceE36));
        }
    }

    /// @inheritdoc IMinter
    function mintLeveragedTokenDryRun(
        uint256 wrappedCollateralIn
    )
        external
        view
        returns (
            int256 incentiveRatio,
            uint256 wrappedFee,
            uint256 wrappedDiscount,
            uint256 wrappedCollateralUsed,
            uint256 leveragedMinted,
            uint256 price,
            uint256 rate
        )
    {
        wrappedCollateralIn = Token.allOfQuiet(_msgSender(), WRAPPED_COLLATERAL_TOKEN, wrappedCollateralIn);
        MinterStorage storage $ = _getMinterStorage();
        OracleData memory oracle = _fetchMid($.priceOracle);
        price = oracle.price;
        rate = oracle.rate;
        (wrappedFee, wrappedDiscount, leveragedMinted, wrappedCollateralUsed, ) = _mintLeveragedAdjustments(
            $.incentiveConfig[Config_v1.MINT_LEVERAGED],
            wrappedCollateralIn,
            CollateralRatioData($.underlyingCollateral, oracle.price, oracle.rate, $.peggedTokenBalance),
            IERC20(WRAPPED_COLLATERAL_TOKEN).balanceOf($.reservePool)
        );
        // slither-disable-next-line incorrect-equality
        if (wrappedCollateralUsed == 0) {
            incentiveRatio = _lookupIncentiveRatio(Config_v1.MINT_LEVERAGED);
        } else {
            uint256 incentive;
            int256 sign;
            if (wrappedFee > wrappedDiscount) {
                incentive = wrappedFee - wrappedDiscount;
                sign = 1;
            } else {
                incentive = wrappedDiscount - wrappedFee;
                sign = -1;
            }
            incentiveRatio = sign * int256(Math.mulDiv(incentive, 1 ether, wrappedCollateralUsed));
        }
    }

    /// @inheritdoc IMinter
    function redeemLeveragedTokenDryRun(
        uint256 leveragedIn
    )
        external
        view
        returns (
            int256 incentiveRatio,
            uint256 wrappedFee,
            uint256 leveragedRedeemed,
            uint256 wrappedCollateralReturned,
            uint256 price,
            uint256 rate
        )
    {
        leveragedIn = Token.allOfQuiet(_msgSender(), LEVERAGED_TOKEN, leveragedIn);
        MinterStorage storage $ = _getMinterStorage();
        uint256 leveragedTokenBalance_ = _leveragedTokenBalance();
        leveragedIn = _redeemableQuiet(leveragedIn, leveragedTokenBalance_);
        OracleData memory oracle = _fetchMid($.priceOracle);
        price = oracle.price;
        rate = oracle.rate;
        (wrappedFee, leveragedRedeemed, wrappedCollateralReturned, ) = _redeemLeveragedAdjustments(
            $.incentiveConfig[Config_v1.REDEEM_LEVERAGED],
            leveragedIn,
            CollateralRatioData($.underlyingCollateral, price, rate, $.peggedTokenBalance),
            leveragedTokenBalance_
        );
        // slither-disable-next-line incorrect-equality
        incentiveRatio = wrappedCollateralReturned == 0
            ? _lookupIncentiveRatio(Config_v1.REDEEM_LEVERAGED)
            : int256(Math.mulDiv(wrappedFee, 1 ether, wrappedCollateralReturned + wrappedFee));
    }

    /// @inheritdoc IMinter
    function harvestable() external view returns (uint256 wrappedAmount) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 rate = _fetchMid($.priceOracle).rate;
        wrappedAmount = 0;
        if (rate > 0) {
            uint256 balance = IERC20(WRAPPED_COLLATERAL_TOKEN).balanceOf(address(this));
            uint256 value = Math.mulDiv($.underlyingCollateral, 1 ether, rate);
            wrappedAmount = (balance > value) ? balance - value : 0;
        }
    }

    //////////////////////////////
    // Public Mutator Functions //
    //////////////////////////////

    /// @inheritdoc IMinter
    function reset() external onlyOwner {
        MinterStorage storage $ = _getMinterStorage();
        uint256 underlying = $.underlyingCollateral;
        uint256 wrapped = IERC20(WRAPPED_COLLATERAL_TOKEN).balanceOf(address(this));
        OracleData memory oracle = _fetchMid($.priceOracle);
        wrapped = Math.mulDiv(wrapped, oracle.rate, 1 ether);
        emit Reset(underlying, wrapped);
        $.underlyingCollateral = wrapped;
    }

    /// @inheritdoc IMinter
    function updateConfig(Config calldata config_) external override onlyOwner {
        // or is this handled by the fact that the CR for discount is much lower than the rebalance CR
        emit UpdateConfig(config_); // the code below may alter the config so emit it soon

        MinterStorage storage $ = _getMinterStorage();

        // incentive config

        Config_v1.checkAndCopyIncentives(config_, $.incentiveConfig);
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
        uint256 wrappedCollateralIn,
        address receiver,
        uint256 minPeggedOut
    ) external override nonReentrant returns (uint256 peggedOut) {
        (peggedOut, ) = _mintPeggedTokenCapped(wrappedCollateralIn, receiver, minPeggedOut, type(uint256).max);
    }

    /// @notice Mint pegged tokens with a fee cap. Stops minting when cumulative fee would exceed maxFeeRatio.
    /// Returns (0, 0) gracefully if the fee exceeds the cap from the start (does not revert).
    /// @param wrappedCollateralIn The amount of wrapped collateral to post. Use type(uint256).max for all.
    /// @param receiver The address to receive minted pegged tokens.
    /// @param minPeggedOut Minimum acceptable pegged output. 0 means no check.
    /// @param maxFeeRatio Maximum overall fee ratio (18 decimals). e.g. 0.05 ether = 5%.
    /// @return peggedOut The amount of pegged tokens minted.
    /// @return wrappedCollateralUsed The amount of wrapped collateral actually consumed (collateral added + fee).
    function mintPeggedToken(
        uint256 wrappedCollateralIn,
        address receiver,
        uint256 minPeggedOut,
        uint256 maxFeeRatio
    ) external nonReentrant returns (uint256 peggedOut, uint256 wrappedCollateralUsed) {
        (peggedOut, wrappedCollateralUsed) = _mintPeggedTokenCapped(
            wrappedCollateralIn,
            receiver,
            minPeggedOut,
            maxFeeRatio
        );
    }

    function _mintPeggedTokenCapped(
        uint256 wrappedCollateralIn,
        address receiver,
        uint256 minPeggedOut,
        uint256 maxFeeRatio
    ) internal returns (uint256 peggedOut, uint256 wrappedCollateralUsed) {
        MinterStorage storage $ = _getMinterStorage();
        OracleData memory oracle = _fetchMid($.priceOracle);
        wrappedCollateralIn = Token.allOf(_msgSender(), WRAPPED_COLLATERAL_TOKEN, wrappedCollateralIn);

        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        uint256 underlyingCollateral_ = $.underlyingCollateral;

        uint256 maxFeeE36 = maxFeeRatio == type(uint256).max
            ? type(uint256).max
            : Math.mulDiv(wrappedCollateralIn, maxFeeRatio, 1 ether) * oracle.rate;

        uint256 wrappedFee;
        uint256 underlyingCollateralAdded;
        (wrappedFee, peggedOut, wrappedCollateralUsed, underlyingCollateralAdded) = _mintPeggedAdjustments(
            $.incentiveConfig[Config_v1.MINT_PEGGED],
            wrappedCollateralIn,
            CollateralRatioData(underlyingCollateral_, oracle.price, oracle.rate, peggedTokenBalance_),
            maxFeeE36
        );

        // slither-disable-next-line incorrect-equality
        if (wrappedCollateralUsed == 0) {
            if (maxFeeRatio == type(uint256).max) {
                // Uncapped: zero means minting is disallowed by config
                revert MintZeroAmount(PEGGED_TOKEN);
            }
            // Capped: fee exceeds cap from the start — return (0, 0) gracefully
            return (0, 0);
        }

        if (peggedOut < minPeggedOut) {
            revert MintInsufficientAmount(PEGGED_TOKEN, peggedOut, minPeggedOut);
        }

        // _mintPeggedToken pulls only wrappedCollateralUsed from sender via safeTransferFrom
        _mintPeggedToken(wrappedCollateralUsed, peggedOut, receiver);

        if (wrappedFee > 0) {
            IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer($.feeReceiver, wrappedFee);
        }

        $.underlyingCollateral = underlyingCollateral_ + underlyingCollateralAdded;
        $.peggedTokenBalance = peggedTokenBalance_ + peggedOut;
    }

    /// @inheritdoc IMinter

    function redeemPeggedToken(
        uint256 peggedIn,
        address receiver,
        uint256 minWrappedCollateralOut
    )
        external
        override
        nonReentrant
        returns (
            uint256 wrappedCollateralOut // wake-disable-line reentrancy
        )
    {
        MinterStorage storage $ = _getMinterStorage();
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        peggedIn = Token.allOf(_msgSender(), PEGGED_TOKEN, peggedIn);
        peggedIn = _redeemable(PEGGED_TOKEN, peggedIn, peggedTokenBalance_);

        OracleData memory oracle = _fetchMax($.priceOracle);
        uint256 underlyingCollateral_ = $.underlyingCollateral;
        address reservePool_ = $.reservePool;

        uint256 wrappedFee;
        uint256 wrappedDiscount;
        uint256 underlyingCollateralRemoved;
        (wrappedFee, wrappedDiscount, wrappedCollateralOut, underlyingCollateralRemoved, ) = _redeemPeggedAdjustments(
            $.incentiveConfig[Config_v1.REDEEM_PEGGED],
            peggedIn,
            CollateralRatioData(underlyingCollateral_, oracle.price, oracle.rate, peggedTokenBalance_),
            IERC20(WRAPPED_COLLATERAL_TOKEN).balanceOf(reservePool_)
        );
        // make sure it meets the minimum requirements
        if (wrappedCollateralOut < minWrappedCollateralOut) {
            revert ReturnInsufficientAmount(WRAPPED_COLLATERAL_TOKEN, wrappedCollateralOut, minWrappedCollateralOut);
        }
        // slither-disable-next-line incorrect-equality
        if (wrappedCollateralOut == 0) {
            revert ReturnZeroAmount(WRAPPED_COLLATERAL_TOKEN);
        }

        // do the fee (feeReceiver) / discount (reservePool)
        if (wrappedFee > 0) {
            // send the fee
            IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer($.feeReceiver, wrappedFee);
        }
        if (wrappedDiscount > 0) {
            // it's a discount, so collect the extra collateral, if available
            // wake-disable-next-line reentrancy // reservePool is trusted and reentrancy guard
            uint256 actualBonus = IReservePool($.reservePool).requestBonus(
                WRAPPED_COLLATERAL_TOKEN,
                address(this),
                wrappedDiscount
            );
            if (actualBonus != wrappedDiscount) {
                revert RequestedBonusNotGiven(wrappedDiscount, actualBonus);
            }
        }

        // redeem pegged tokens and send the remainder of the collateral
        _redeemPeggedToken(peggedIn, wrappedCollateralOut, receiver);

        // update our records
        $.peggedTokenBalance = peggedTokenBalance_ - peggedIn;
        $.underlyingCollateral = underlyingCollateral_ - underlyingCollateralRemoved;
    }

    /// @inheritdoc IMinter
    function mintLeveragedToken(
        uint256 wrappedCollateralIn,
        address receiver,
        uint256 minLeveragedOut
    ) external override nonReentrant returns (uint256 leveragedOut) {
        MinterStorage storage $ = _getMinterStorage();
        wrappedCollateralIn = Token.allOf(_msgSender(), WRAPPED_COLLATERAL_TOKEN, wrappedCollateralIn);

        OracleData memory oracle = _fetchMid($.priceOracle);
        uint256 wrappedFee;
        uint256 wrappedDiscount;
        uint256 underlyingCollateral_ = $.underlyingCollateral;
        uint256 underlyingCollateralAdded;
        address reservePool_ = $.reservePool;
        (
            wrappedFee,
            wrappedDiscount,
            leveragedOut,
            wrappedCollateralIn,
            underlyingCollateralAdded
        ) = _mintLeveragedAdjustments(
                $.incentiveConfig[Config_v1.MINT_LEVERAGED],
                wrappedCollateralIn,
                CollateralRatioData(underlyingCollateral_, oracle.price, oracle.rate, $.peggedTokenBalance),
                IERC20(WRAPPED_COLLATERAL_TOKEN).balanceOf(reservePool_)
            );
        if (wrappedDiscount > 0) {
            // it's a discount, so collect the extra collateral, if available
            // wake-disable-next-line reentrancy // reservePool is trusted
            uint256 actualBonus = IReservePool(reservePool_).requestBonus(
                WRAPPED_COLLATERAL_TOKEN,
                address(this),
                wrappedDiscount
            );
            if (actualBonus != wrappedDiscount) {
                revert RequestedBonusNotGiven(wrappedDiscount, actualBonus);
            }
        }
        // make sure it meets the minimum requirements
        if (leveragedOut < minLeveragedOut) {
            revert MintInsufficientAmount(LEVERAGED_TOKEN, leveragedOut, minLeveragedOut);
        }
        // mint the leveraged tokens and take wrappedCollateralIn
        _mintLeveragedToken(wrappedCollateralIn, leveragedOut, receiver);
        // take the fee
        if (wrappedFee > 0) {
            IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer($.feeReceiver, wrappedFee);
        }
        // update our records
        $.underlyingCollateral = underlyingCollateral_ + underlyingCollateralAdded;
    }

    /// @inheritdoc IMinter
    function redeemLeveragedToken(
        uint256 leveragedIn,
        address receiver,
        uint256 minWrappedCollateralOut
    ) external override returns (uint256 wrappedCollateralOut) {
        MinterStorage storage $ = _getMinterStorage();
        leveragedIn = Token.allOf(_msgSender(), LEVERAGED_TOKEN, leveragedIn);

        uint256 leveragedTokenBalance_ = _leveragedTokenBalance();
        leveragedIn = _redeemable(LEVERAGED_TOKEN, leveragedIn, leveragedTokenBalance_);
        OracleData memory oracle = _fetchMin($.priceOracle);

        uint256 underlyingCollateral_ = $.underlyingCollateral;

        uint256 wrappedFee;
        uint256 underlyingCollateralOut;
        (wrappedFee, leveragedIn, wrappedCollateralOut, underlyingCollateralOut) = _redeemLeveragedAdjustments(
            $.incentiveConfig[Config_v1.REDEEM_LEVERAGED],
            leveragedIn,
            CollateralRatioData(underlyingCollateral_, oracle.price, oracle.rate, $.peggedTokenBalance),
            leveragedTokenBalance_
        );
        // slither-disable-next-line incorrect-equality
        if (wrappedCollateralOut == 0) {
            revert ReturnZeroAmount(WRAPPED_COLLATERAL_TOKEN);
        }
        if (wrappedCollateralOut < minWrappedCollateralOut) {
            revert ReturnInsufficientAmount(WRAPPED_COLLATERAL_TOKEN, wrappedCollateralOut, minWrappedCollateralOut);
        }

        _redeemLeveragedToken(leveragedIn, wrappedCollateralOut, receiver);

        if (wrappedFee > 0) {
            // send the fee
            IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer($.feeReceiver, wrappedFee);
        }

        // update our records
        $.underlyingCollateral = underlyingCollateral_ - underlyingCollateralOut;
    }

    //////////////////////////////////
    // Restricted Mutator Functions //
    //////////////////////////////////

    // fee-free minting/redeeming pegged/leveraged tokens
    // --------------------------------------------------

    /// @inheritdoc IMinter
    function freeMintPeggedToken(
        uint256 wrappedCollateralIn,
        address receiver
    ) external override onlyRoles(ZERO_FEE_ROLE) nonReentrant returns (uint256 peggedOut) {
        MinterStorage storage $ = _getMinterStorage();
        OracleData memory oracle = _fetchMid($.priceOracle);
        uint256 underlyingCollateralInE36 = wrappedCollateralIn * oracle.rate;

        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        uint256 underlyingCollateral_ = $.underlyingCollateral;

        // transfer and mint
        peggedOut = Math.mulDiv(
            underlyingCollateralInE36,
            oracle.price,
            _peggedTokenPriceE36(peggedTokenBalance_, underlyingCollateral_, oracle.price)
        );

        _mintPeggedToken(wrappedCollateralIn, peggedOut, receiver);

        // update our records
        $.peggedTokenBalance = peggedTokenBalance_ + peggedOut;
        $.underlyingCollateral = underlyingCollateral_ + underlyingCollateralInE36 / 1 ether;
    }

    // @inheritdoc IMinter
    function freeRedeemPeggedToken(
        uint256 peggedForCollateral,
        uint256 peggedForLeveraged,
        address receiver
    ) external nonReentrant onlyRoles(ZERO_FEE_ROLE) returns (uint256 wrappedCollateralOut, uint256 leveragedOut) {
        if (peggedForCollateral + peggedForLeveraged > 0) {
            MinterStorage storage $ = _getMinterStorage();
            uint256 peggedTokenBalance_ = $.peggedTokenBalance;

            if ((peggedForCollateral + peggedForLeveraged) > peggedTokenBalance_) {
                revert InsufficientRedeemableTokens(
                    PEGGED_TOKEN,
                    peggedTokenBalance_,
                    peggedForCollateral + peggedForLeveraged
                );
            }

            OracleData memory oracle = _fetchMax($.priceOracle);
            // Snapshot original state so both paths price against the same pre-burn balances,
            // consistent with how redeemPeggedForCollateralRatio computed the amounts.
            uint256 underlyingCollateral_ = $.underlyingCollateral;

            if (peggedForCollateral > 0) {
                uint256 underlyingCollateralOutE36 = Math.mulDiv(
                    peggedForCollateral,
                    _peggedTokenPriceE36(peggedTokenBalance_, underlyingCollateral_, oracle.price),
                    oracle.price
                );
                wrappedCollateralOut = underlyingCollateralOutE36 / oracle.rate;
                // return the collateral
                IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer(receiver, wrappedCollateralOut);
                $.underlyingCollateral = underlyingCollateral_ - underlyingCollateralOutE36 / 1 ether;
            }

            if (peggedForLeveraged > 0) {
                leveragedOut = _leveragedTokensForPegged(
                    peggedForLeveraged,
                    _leveragedTokenBalance(),
                    peggedTokenBalance_,
                    underlyingCollateral_,
                    oracle.price
                );
                // mint the tokens to the receiver
                // wake-disable-next-line reentrancy
                IMintable(LEVERAGED_TOKEN).mint(receiver, leveragedOut);
            }

            emit RedeemPeggedToken(
                _msgSender(),
                receiver,
                peggedForLeveraged + peggedForCollateral,
                wrappedCollateralOut,
                leveragedOut
            );

            // burn the tokens from the sender - deal with the different burn signatures for ERC20 contracts
            _burnPeggedToken(peggedForCollateral + peggedForLeveraged);
            // update our records
            $.peggedTokenBalance = peggedTokenBalance_ - (peggedForCollateral + peggedForLeveraged);
        }
    }

    // @inheritdoc IMinter
    function freeMintLeveragedToken(
        uint256 wrappedCollateralIn,
        address receiver
    ) external override onlyRoles(ZERO_FEE_ROLE) nonReentrant returns (uint256 leveragedOut) {
        MinterStorage storage $ = _getMinterStorage();
        // how much collateral to use
        OracleData memory oracle = _fetchMid($.priceOracle);
        (uint256 collateralValueE36, uint256 peggedValueE36) = _tokenValuesE36(
            $.peggedTokenBalance,
            $.underlyingCollateral,
            oracle.price
        );
        uint256 underlyingCollateralInE36 = wrappedCollateralIn * oracle.rate;
        uint256 leveragedTokenBalance_ = _leveragedTokenBalance();
        if (leveragedTokenBalance_ > 0) {
            leveragedOut =
                (underlyingCollateralInE36 * oracle.price) /
                _leveragedTokenPriceE36(collateralValueE36, peggedValueE36, leveragedTokenBalance_);
        } else {
            leveragedOut = collateralValueE36; // First term
            leveragedOut += Math.mulDiv(underlyingCollateralInE36, oracle.price, 1e18); // Second term
            leveragedOut -= $.peggedTokenBalance * 1e18;
            leveragedOut /= 1e18;
        }

        // mint the tokens to the receiver
        _mintLeveragedToken(wrappedCollateralIn, leveragedOut, receiver);

        // update our records
        $.underlyingCollateral += underlyingCollateralInE36 / 1e18;
    }

    // @inheritdoc IMinter
    function freeRedeemLeveragedToken(
        uint256 leveragedIn,
        address receiver
    ) external override onlyRoles(ZERO_FEE_ROLE) returns (uint256 collateralOut) {
        MinterStorage storage $ = _getMinterStorage();

        uint256 leveragedTokenBalance_ = _leveragedTokenBalance();
        leveragedIn = _redeemable(LEVERAGED_TOKEN, leveragedIn, leveragedTokenBalance_);

        OracleData memory oracle = _fetchMin($.priceOracle);

        (uint256 collateralValueE36, uint256 peggedValueE36) = _tokenValuesE36(
            $.peggedTokenBalance,
            $.underlyingCollateral,
            oracle.price
        );
        if (collateralValueE36 <= peggedValueE36) {
            collateralOut = 0;
        } else {
            uint256 underlyingCollateralOutE36;
            if (leveragedTokenBalance_ == 0) {
                underlyingCollateralOutE36 = leveragedIn * oracle.price;
            } else {
                underlyingCollateralOutE36 = Math.mulDiv(
                    leveragedIn * 1 ether,
                    collateralValueE36 - peggedValueE36,
                    oracle.price * leveragedTokenBalance_
                );
            }
            collateralOut = underlyingCollateralOutE36 / oracle.rate;

            _redeemLeveragedToken(leveragedIn, collateralOut, receiver);

            // update our records
            $.underlyingCollateral -= underlyingCollateralOutE36 / 1 ether;
        }
    }

    ///////////////////////
    // Private functions //
    ///////////////////////

    /// @notice The storage hash for the shared-with-proxy storage
    // chisel eval 'keccak256(abi.encode(uint256(keccak256("bao.storage.Minter")) - 1)) & ~bytes32(uint256(0xff))'
    bytes32 private constant _MINTER_STORAGE = 0x92e73fe9557052b4a0b810a38eb7ef595ff750f166ca39d63b3f4c74937fef00;

    /// @notice Returns a reference to the contract state
    function _getMinterStorage() internal pure returns (MinterStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _MINTER_STORAGE
        }
    }

    // Price/Rate Oracle
    // -----------------

    /// @notice Updates the price oracle address.
    function _updatePriceOracle(address priceOracle_) internal {
        MinterStorage storage $ = _getMinterStorage();
        address old = $.priceOracle;
        $.priceOracle = priceOracle_;
        emit UpdatePriceOracle(old, priceOracle_);
    }

    // Fee Receiver
    // ------------

    /// @notice Updates the fee receiver address.
    function _updateFeeReceiver(address feeReceiver_) internal {
        MinterStorage storage $ = _getMinterStorage();
        address old = $.feeReceiver;
        $.feeReceiver = feeReceiver_;
        emit UpdateFeeReceiver(old, feeReceiver_);
    }

    // ReservePool
    // -----------

    /// @notice Updates the reserve pool address.
    function _updateReservePool(address reservePool_) internal {
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
    /// @param wrappedCollateralIn The amount of collateral to be taken from the sender.
    /// @param peggedOut The amount of pegged to be transferred to the `receiver`.
    /// @param receiver The address of the receiver.

    function _mintPeggedToken(uint256 wrappedCollateralIn, uint256 peggedOut, address receiver) internal {
        emit MintPeggedToken(_msgSender(), receiver, wrappedCollateralIn, peggedOut);

        // mint the tokens to the receiver
        // wake-disable-next-line reentrancy // all callers to this function have nonReentrant guard
        IMintable(PEGGED_TOKEN).mint(receiver, peggedOut);

        // take the collateral
        IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransferFrom(_msgSender(), address(this), wrappedCollateralIn);
    }

    /// @notice burn pegged tokens in the way the like to burn
    function _burnPeggedToken(uint256 amount) internal {
        if (_BURN_SIGNATURE == BurnSignature.Burn2Arg) {
            IBurnable2Arg(PEGGED_TOKEN).burn(_msgSender(), amount);
        } else if (_BURN_SIGNATURE == BurnSignature.BurnFrom) {
            IBurnableFrom(PEGGED_TOKEN).burnFrom(_msgSender(), amount);
        } else if (_BURN_SIGNATURE == BurnSignature.Burn1Arg) {
            // get the tokens here first
            IERC20(PEGGED_TOKEN).safeTransferFrom(_msgSender(), address(this), amount);
            IBurnable(PEGGED_TOKEN).burn(amount);
        } // no need to check for others because the constructor does this
    }

    /// @notice Perform the transfers and event emissions for redeeming pegged tokens
    /// Fees and discounts transfers and event emissions are not handled here.
    /// @dev no checks for zeros values are performed.
    /// @param peggedIn The amount of pegged tokens to be taken from the sender.
    /// @param wrappedCollateralOut The amount of collateral to be transferred to the `receiver`.
    /// @param receiver The address of the receiver.

    function _redeemPeggedToken(uint256 peggedIn, uint256 wrappedCollateralOut, address receiver) internal {
        // tell the world
        emit RedeemPeggedToken(_msgSender(), receiver, peggedIn, wrappedCollateralOut, 0);

        // burn the tokens from the sender - deal with the different burn signatures for ERC20 contracts
        _burnPeggedToken(peggedIn);

        // return the collateral
        IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer(receiver, wrappedCollateralOut);
    }

    /// @notice Perform the transfers and event emissions for minting leveraged tokens
    /// Fees and discounts transfers and event emissions are not handled here.
    /// @dev no checks for zeros values are performed.
    /// @param wrappedCollateralIn The amount of collateral to be taken from the sender.
    /// @param leveragedOut The amount of leveraged to be transferred to the `receiver`.
    /// @param receiver The address of the receiver.

    function _mintLeveragedToken(uint256 wrappedCollateralIn, uint256 leveragedOut, address receiver) internal {
        // slither-disable-next-line incorrect-equality
        if (leveragedOut == 0) {
            revert ReturnZeroAmount(LEVERAGED_TOKEN);
        }
        // tell the world
        emit MintLeveragedToken(_msgSender(), receiver, wrappedCollateralIn, leveragedOut);
        // mint the tokens to the receiver
        // wake-disable-next-line reentrancy
        IMintable(LEVERAGED_TOKEN).mint(receiver, leveragedOut);
        // take the collateral
        IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransferFrom(_msgSender(), address(this), wrappedCollateralIn);
    }

    /// @notice Perform the transfers and event emissions for redeeming leveraged tokens.
    /// Fees and discounts transfers and event emissions are not handled here.
    /// @dev no checks for zeros values are performed.
    /// @param leveragedIn The amount of leveraged tokens to be taken from the sender.
    /// @param collateralOut The amount of collateral to be transferred to the `receiver`.
    /// @param receiver The address of the receiver.

    function _redeemLeveragedToken(uint256 leveragedIn, uint256 collateralOut, address receiver) internal {
        // tell the world
        emit RedeemLeveragedToken(_msgSender(), receiver, leveragedIn, collateralOut);
        // burn the leveraged
        // wake-disable-next-line reentrancy // leveragedToken is trusted
        IBurnableFrom(LEVERAGED_TOKEN).burnFrom(_msgSender(), leveragedIn);
        // return the collateral
        IERC20(WRAPPED_COLLATERAL_TOKEN /*  */).safeTransfer(receiver, collateralOut);
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
    ) internal pure returns (uint256 amountOut) {
        amountOut = _redeemableQuiet(amountIn, tokenBalance_);
        // slither-disable-next-line incorrect-equality
        if (amountOut == 0) {
            revert NoRedeemableTokens(token_);
        }
    }

    function _redeemableQuiet(uint256 amountIn, uint256 tokenBalance_) internal pure returns (uint256 amountOut) {
        amountOut = Math.min(amountIn, tokenBalance_);
    }

    // Adjustments - fees, bonuses and disallows
    // -----------------------------------------
    // Each of the algorithms simulates the operation {mint/redeem}/{Pegged/Leveraged} in a loop covering each fee band
    // Much of the operations are performed and some results are returned at 1e36 precision.
    // This is because, particularly for collateral based results, the result is transformed into a wrapped collateral basis,
    // which can reduce precision through dividing before multiplying across function call boundaries.
    // The fee calculation also takes into account truncations due to divisions such that each iteration of the loop
    // adds back truncations from previous iterations to the current iteration. This is an adaption of the Kahan–Babuška summation
    // algorithm, which is used to reduce numerical errors in floating point arithmetic, to integer arithmetic in solidity.
    // Although it is anticipated that few fee calculations will cross more than one boundary, we should still handle the case well,
    // and fairly, where, say a large deposit is made in the face of a relatively small collateral balance or when fee boundaries
    // are placed closely together to create the correct incentives for investors.

    struct CollateralRatioData {
        uint256 underlyingCollateral;
        uint256 price;
        uint256 rate;
        uint256 peggedTokenBalance;
    }

    struct MintPeggedWorkspace {
        uint band; // solhint-disable-line explicit-types
        uint256 underlyingCollateralInLeftE36;
        uint256 underlyingCollateralHeldE36;
        uint256 underlyingCollateralAddedE36;
        uint256 peggedTokenHeldE36;
        uint256 underlyingFeeE36;
        uint256 mintedE36;
        int256 feeErrorE54;
        bool feeCapped;
        uint256 peggedTokenPriceE36;
    }

    /// @notice Perform a dry run of a mint pegged to calculate the various transfers of tokens.
    /// Fees, discounts and disallows relating to the different incentiveRatios values are calculated as sum, weighted
    /// in proportion, in collateral space, to the amount spent within each collateral ratio boundary.
    /// It essentially performs a definite integral of the fee function.
    /// @param config_ The collateral ratio boundaries and the incentive ratios within each boundary,
    /// for minting pegged tokens.
    /// @param wrappedCollateralIn The proposed amount of wrapped collateral being posted in exchange for pegged tokens.
    /// @param cr contains:
    ///    UnderlyingCollateral The amount of collateral held. This is used to calculate collateral ratios.
    ///    The price value of a collateral token in terms of the pegged token, and the rate of wrapped collateral to underlying collateral.
    ///    peggedTokenBalance The amount of pegged tokens issued. This is used to calculate collateral ratios.
    /// @return wrappedFee The pro-rated fee, in wrapped collateral terms.
    /// @return peggedMinted the amount of pegged tokens minted after fees are taken into account
    /// @return maxWrappedCollateralIn the amount of wrapped collateral that is allowed, according to the config
    /// @return underlyingCollateralAdded the amount of underlying collateral added to the backing of the pegged tokens

    function _mintPeggedAdjustments(
        ConfigIncentiveLib.ActionIncentive memory config_,
        uint256 wrappedCollateralIn,
        CollateralRatioData memory cr,
        uint256 maxFeeE36
    )
        internal
        pure
        returns (
            uint256 wrappedFee,
            uint256 peggedMinted,
            uint256 maxWrappedCollateralIn,
            uint256 underlyingCollateralAdded
        )
    {
        // we cannot calculate collateral ratio when there are no pegged tokens as it's infinite i.e. (/0)
        // slither-disable-next-line incorrect-equality
        // if (cr.peggedTokenBalance == 0) {
        //     revert ActionPaused();
        // }
        // find the band and it's lower bound where the current collateral ratio is
        // (note we treat the disallow band as any other here, except that it is the terminal band)
        MintPeggedWorkspace memory w;
        w.band = _findBand(config_, cr.underlyingCollateral, cr.price, cr.peggedTokenBalance, false);
        w.peggedTokenPriceE36 = _peggedTokenPriceE36(cr.peggedTokenBalance, cr.underlyingCollateral, cr.price);

        w.underlyingCollateralInLeftE36 = wrappedCollateralIn * cr.rate; // scaled to 1e36
        w.underlyingCollateralHeldE36 = cr.underlyingCollateral * 1 ether; // scaled to 1e36
        w.peggedTokenHeldE36 = cr.peggedTokenBalance * 1 ether;
        w.underlyingFeeE36 = 0;
        w.mintedE36 = 0;
        // simulate minting until we run out of collateral, adding the fee & collateral as we go
        while (true) {
            uint256 bandFeeRatio = uint256(ConfigIncentiveLib._incentiveRatio(config_, w.band)); // no discounts for this action
            // slither-disable-next-line incorrect-equality, the vaule 1 ether corresponds to a specific meaning
            if (bandFeeRatio == 1 ether) {
                // fee ratio of 100% means the action is disallowed, and in the lowest band
                break;
            }

            uint256 collateralInBandE36; // includes the fee
            uint256 bandLowerBound = ConfigIncentiveLib._collateralRatioLowerBounds(config_, w.band);
            if (bandLowerBound <= 1 ether) {
                // We can never mint enough pegged tokens such that we de-peg and
                // if we have already de-pegged, we can use all the collateral given
                collateralInBandE36 = w.underlyingCollateralInLeftE36;
            } else {
                // here we can assume pegged tokens are not de-pegged
                // we have collateral ratio R = C.p / Z
                // where p = price of collateral in pegged tokens, C = collateral balance and Z = pegged token balance
                // adding fee ratio, f, change in collateral, dC, and change in pegged, dZ, we have
                //   R = ((C + dC - dC * f) * p) / (Z + dZ - dZ * f)
                // captures the changes in pegged and collateral in order for R to be the lower bound, for a given constant fee ratio, f
                // now, dZ = dC * p and solving for dC gives us
                //   dC = (C * p - R * Z) / (p * phi)
                // where phi = R * (1 - f) - 1 + f = (R - 1) * (1 - f)
                uint256 phiE36 = (bandLowerBound - 1e18) * (1e18 - bandFeeRatio);
                collateralInBandE36 = Math.mulDiv(
                    w.underlyingCollateralHeldE36 * cr.price - bandLowerBound * w.peggedTokenHeldE36,
                    1e36,
                    cr.price * phiE36
                );
                collateralInBandE36 = Math.min(w.underlyingCollateralInLeftE36, collateralInBandE36);
            }
            // Cap collateral to stay within fee budget (skip when uncapped)
            if (maxFeeE36 != type(uint256).max) {
                uint256 remainingFeeE36 = maxFeeE36 - w.underlyingFeeE36;
                uint256 maxCollateralForFeeE36 = Math.mulDiv(remainingFeeE36, 1 ether, bandFeeRatio);
                if (collateralInBandE36 > maxCollateralForFeeE36) {
                    collateralInBandE36 = maxCollateralForFeeE36;
                    w.feeCapped = true;
                }
            }

            uint256 bandFeeE36;
            (bandFeeE36, w.feeErrorE54) = _divAccumulateError(collateralInBandE36 * bandFeeRatio, w.feeErrorE54);
            w.underlyingFeeE36 += bandFeeE36;
            uint256 collateralAddedInBandE36 = collateralInBandE36 - bandFeeE36;
            w.underlyingCollateralAddedE36 += collateralAddedInBandE36;

            w.underlyingCollateralInLeftE36 -= collateralInBandE36;

            uint256 peggedMintedInBandE36 = Math.mulDiv(
                collateralAddedInBandE36,
                cr.price * 1 ether,
                w.peggedTokenPriceE36
            );

            w.mintedE36 += peggedMintedInBandE36;

            // slither-disable-next-line incorrect-equality
            if (w.feeCapped || w.underlyingCollateralInLeftE36 == 0 || w.band == 0) {
                // we have hit the fee cap, run out of collateral, or are in the lowest band
                break;
            }
            // still some collateral left and we're allowed to mint, so simulate
            w.underlyingCollateralHeldE36 += collateralAddedInBandE36;
            w.peggedTokenHeldE36 += peggedMintedInBandE36;
            w.band--;
        }
        // return the results
        peggedMinted = w.mintedE36 / 1 ether;
        // first do calculations in underlying collateral
        underlyingCollateralAdded = _round(w.underlyingCollateralAddedE36, 1 ether);
        // then wrapped collateral based on the underlying collateral numbers
        wrappedFee = w.underlyingFeeE36 / cr.rate;
        maxWrappedCollateralIn = (w.underlyingCollateralAddedE36 + w.underlyingFeeE36) / cr.rate;
    }

    struct RedeemPeggedWorkspace {
        uint256 peggedInLeftE36;
        uint256 underlyingCollateralHeldE36;
        uint256 peggedTokenHeldE36;
        uint256 underlyingFeeE36;
        uint256 underlyingDiscountE36;
        uint256 redeemedE36;
        int256 feeErrorE54;
        int256 discountErrorE54;
        int256 collateralHeldErrorE54;
    }

    /// @notice Perform a dry run of a redeem pegged to calculate the various transfers of tokens
    /// Fees and discounts relating to the different incentiveRatios values are calculated as sum, weighted
    /// in proportion, in collateral space, to the amount spent within each collateral ratio boundary.
    /// It essentially performs a definite integral of the fee function.
    /// @param config_ The collateral ratio boundaries and the incentive ratios within each boundary,
    /// for redeeming pegged tokens.
    /// @param peggedIn The given amount of pegged tokens.
    /// @param cr contains:
    ///    UnderlyingCollateral The amount of collateral held. This is used to calculate collateral ratios.
    ///    The price value of a collateral token in terms of the pegged token, and the rate of wrapped collateral to underlying collateral.
    ///    peggedTokenBalance The amount of pegged tokens issued. This is used to calculate collateral ratios.
    /// @param reserveWrappedCapacity The current balance of the reserve pool (scaled to 1e36).
    /// @return wrappedFee the fee charged in wrapped collateral tokens.
    /// @return wrappedDiscount the discount given in wrapped collateral tokens.
    /// @return wrappedCollateralReturned the wrapped collateral returned to the receiver in exchange for the 'peggedRedeemed'
    /// @return underlyingCollateralRemoved the collateral removed from the balance to return the peggedIn.

    function _redeemPeggedAdjustments(
        ConfigIncentiveLib.ActionIncentive memory config_,
        uint256 peggedIn,
        CollateralRatioData memory cr,
        uint256 reserveWrappedCapacity
    )
        internal
        pure
        returns (
            uint256 wrappedFee,
            uint256 wrappedDiscount, // amount requested from reserve pool
            uint256 wrappedCollateralReturned, // this includes the discount
            uint256 underlyingCollateralRemoved,
            uint256 peggedPriceE36
        )
    {
        RedeemPeggedWorkspace memory w;
        // solhint-disable-next-line explicit-types
        uint band = _findBand(config_, cr.underlyingCollateral, cr.price, cr.peggedTokenBalance, true);
        // simulate redeeming until we run out of pegged tokens, adding the fee & bonus as we go
        // We do this band at a time, pro-rating the resulting fee according to how much collateral was needed in
        // each band entered. We use collateral to pro-rate, rather than collateral ratio which would be simpler, because
        // we multiply the resulting ratios by the collateral for the final fee

        // we capture the pegged price now as it doesn't change throughout the process, even if depegged
        peggedPriceE36 = _peggedTokenPriceE36(cr.peggedTokenBalance, cr.underlyingCollateral, cr.price);

        w.peggedInLeftE36 = peggedIn * 1 ether; // scaled to 1e36
        w.underlyingCollateralHeldE36 = cr.underlyingCollateral * 1 ether; // scaled to 1e36
        w.peggedTokenHeldE36 = cr.peggedTokenBalance * 1 ether;
        w.underlyingFeeE36 = 0;
        w.underlyingDiscountE36 = 0;
        w.redeemedE36 = 0;

        while (w.peggedInLeftE36 > 0) {
            uint256 peggedInBandE36;
            {
                if (band + 1 == ConfigIncentiveLib._collateralRatioBandCount(config_)) {
                    // the last band goes on forever and there must be more than 1 band
                    peggedInBandE36 = w.peggedInLeftE36;
                } else {
                    uint256 bandUpperBound = ConfigIncentiveLib._collateralRatioUpperBounds(config_, band);
                    if (bandUpperBound <= 1 ether) {
                        // given the price of the pegged is a proportionate share of the collateral and leveraged tokens are worthless
                        // we redeem all of it (at the depegged rate) in this band, at the rate for the band
                        peggedInBandE36 = w.peggedInLeftE36;
                    } else {
                        // note the bandUpperBound cannot be == 1 ether so this is safe below
                        peggedInBandE36 =
                            (bandUpperBound * w.peggedTokenHeldE36 - w.underlyingCollateralHeldE36 * cr.price) /
                            (bandUpperBound - 1 ether);
                        peggedInBandE36 = Math.min(w.peggedInLeftE36, peggedInBandE36);
                    }
                }
            }
            // account for pegged being removed
            w.peggedInLeftE36 -= peggedInBandE36;
            w.redeemedE36 += peggedInBandE36;
            w.peggedTokenHeldE36 -= peggedInBandE36;

            {
                uint256 collateralInBandE36;
                (collateralInBandE36, w.collateralHeldErrorE54) = _divAccumulateError(
                    Math.mulDiv(peggedInBandE36, peggedPriceE36, cr.price),
                    w.collateralHeldErrorE54
                );

                // tally the fee or discount - these values have no effect at the moment:
                // fees have already been accounted for and discounts come from the reserve pool
                int256 bandIncentiveRatio = ConfigIncentiveLib._incentiveRatio(config_, band);
                if (bandIncentiveRatio < 0) {
                    uint256 bandDiscountE36;
                    (bandDiscountE36, w.discountErrorE54) = _divAccumulateError(
                        collateralInBandE36 * uint256(-bandIncentiveRatio),
                        w.discountErrorE54
                    );
                    w.underlyingDiscountE36 += bandDiscountE36;
                } else {
                    uint256 bandFeeE36;
                    (bandFeeE36, w.feeErrorE54) = _divAccumulateError(
                        collateralInBandE36 * uint256(bandIncentiveRatio),
                        w.feeErrorE54
                    );
                    w.underlyingFeeE36 += bandFeeE36;
                }
                w.underlyingCollateralHeldE36 -= collateralInBandE36;
            }
            // still some pegged tokens left so continue redeeing them
            band++;
        }
        wrappedFee = w.underlyingFeeE36 / cr.rate;
        wrappedDiscount = Math.min(reserveWrappedCapacity, w.underlyingDiscountE36 / cr.rate); // amount requested from reserve pool
        uint256 underlyingCollateralRemovedE36 = cr.underlyingCollateral * 1 ether - w.underlyingCollateralHeldE36;
        underlyingCollateralRemoved = underlyingCollateralRemovedE36 / 1 ether; // don't round this as it may push CR the wrong way
        wrappedCollateralReturned = underlyingCollateralRemovedE36 / cr.rate + wrappedDiscount - wrappedFee;
    }

    struct MintLeveragedWorkspace {
        uint band; // solhint-disable-line explicit-types
        uint256 underlyingCollateralInLeftE36;
        uint256 underlyingReserveCapacityE36;
        uint256 underlyingCollateralHeldE36;
        uint256 underlyingCollateralAddedE36;
        uint256 peggedTokenHeldE36;
        uint256 underlyingFeeE36;
        uint256 underlyingDiscountE36;
        uint256 bandFeeRatio;
        uint256 bandDiscountRatio;
        uint256 leveragedPriceE36;
        uint256 leveragedTokenBalance;
        uint256 collateralValueE36;
        uint256 peggedValueE36;
    }

    /// @notice Perform a dry run of a mint pegged to calculate the various transfers of tokens.
    /// Fees, discounts and disallows relating to the different incentiveRatios values are calculated as sum, weighted
    /// in proportion, in collateral space, to the amount spent within each collateral ratio boundary.
    /// It essentially performs a definite integral of the fee function.
    /// @param config_ The collateral ratio boundaries and the incentive ratios within each boundary,
    /// for minting leveraged tokens.
    /// @param wrappedCollateralIn The proposed amount of wrapped collateral being posted in exchange for leveraged tokens
    /// @param cr contains:
    ///    UnderlyingCollateral The amount of collateral held. This is used to calculate collateral ratios.
    ///    The price value of a collateral token in terms of the pegged token, and the rate of wrapped collateral to underlying collateral.
    ///    peggedTokenBalance The amount of pegged tokens issued. This is used to calculate collateral ratios.
    /// @param reserveWrappedCapacity The current balance of the reserve pool.
    /// @return wrappedFee The pro-rated fee, in wrapped collateral terms.
    /// @return wrappedDiscount the discount given in wrapped collateral tokens.
    /// @return leveragedMinted The amount of leveraged tokens minted, after fees and discounts are taken into account.
    /// @return maxWrappedCollateralIn the collateral used from the wrappedCollateralIn.
    /// @return underlyingCollateralAdded the collateral added to the balance to return the wrappedCollateralIn.

    // slither-disable-next-line cyclomatic-complexity
    function _mintLeveragedAdjustments(
        ConfigIncentiveLib.ActionIncentive memory config_,
        uint256 wrappedCollateralIn,
        CollateralRatioData memory cr,
        uint256 reserveWrappedCapacity
    )
        internal
        view
        returns (
            uint256 wrappedFee,
            uint256 wrappedDiscount,
            uint256 leveragedMinted,
            uint256 maxWrappedCollateralIn,
            uint256 underlyingCollateralAdded
        )
    {
        MintLeveragedWorkspace memory w;
        (w.collateralValueE36, w.peggedValueE36) = _tokenValuesE36(
            cr.peggedTokenBalance,
            cr.underlyingCollateral,
            cr.price
        );
        // leveraged tokens have no value (we may not have quite depegged, though)
        if (w.collateralValueE36 <= w.peggedValueE36) {
            return (0, 0, 0, 0, 0);
        }
        maxWrappedCollateralIn = wrappedCollateralIn;
        w.leveragedTokenBalance = _leveragedTokenBalance();

        // simulate minting leveaged tokens from current collateral ratio upwards,
        // applying the incentive at the correct ratio as we go.
        // We do this band at a time, pro-rating the resulting fee according to how much collateral was needed in
        // each band entered. We use collateral to pro-rate, rather than collateral ratio which would be simpler, because
        // we multiply the resulting ratios by the collateral for the final fee
        // solhint-disable-next-line explicit-types
        w.band = _findBand(config_, cr.underlyingCollateral, cr.price, cr.peggedTokenBalance, true);
        w.underlyingCollateralInLeftE36 = wrappedCollateralIn * cr.rate; // scaled to 1e36
        w.underlyingReserveCapacityE36 = reserveWrappedCapacity * cr.rate;
        w.underlyingCollateralHeldE36 = cr.underlyingCollateral * 1e18;
        w.underlyingCollateralAddedE36 = 0;
        w.peggedTokenHeldE36 = cr.peggedTokenBalance * 1e18;

        while (w.underlyingCollateralInLeftE36 > 0) {
            // we calculate the collateral and discount for the current band
            uint256 collateralInBandE36;
            uint256 bandDiscountE36 = 0;
            {
                int256 incentiveRatio = ConfigIncentiveLib._incentiveRatio(config_, w.band);
                // get the fee and discount ratios
                w.bandFeeRatio = incentiveRatio > 0 ? uint256(incentiveRatio) : 0;
                w.bandDiscountRatio = incentiveRatio < 0 ? uint256(-incentiveRatio) : 0;
            }
            // now get:
            // the collateral in the band,
            // the corresponding discount
            // This is complex because both are dependent on the reservePool capacity which limits the discount which, in turn, inflences the collateral

            // slither-disable-next-line incorrect-equality
            if (w.band + 1 == ConfigIncentiveLib._collateralRatioBandCount(config_)) {
                // the last band has no upper bound and there are at least 2 bands
                // gross collateral includes fees and discounts
                collateralInBandE36 = w.underlyingCollateralInLeftE36;
                if (w.bandDiscountRatio > 0) {
                    // theoretical
                    bandDiscountE36 = Math.mulDiv(collateralInBandE36, w.bandDiscountRatio, 1e18);
                    // actual
                    bandDiscountE36 = Math.min(bandDiscountE36, w.underlyingReserveCapacityE36);
                }
            } else if (w.bandDiscountRatio > 0) {
                // discount
                // we calculate the collateralInBand assuming there is no reserve pool capacity limit (for this band)
                collateralInBandE36 = Math.mulDiv(
                    ConfigIncentiveLib._collateralRatioUpperBounds(config_, w.band) * w.peggedTokenHeldE36 -
                        w.underlyingCollateralHeldE36 * cr.price,
                    1e18,
                    cr.price * (1e18 + w.bandDiscountRatio)
                );
                // user limits how much of the band collateral is used (and the discount)
                collateralInBandE36 = Math.min(collateralInBandE36, w.underlyingCollateralInLeftE36);

                // now check that the reserve pool can do it's corresponding bit
                bandDiscountE36 = Math.mulDiv(collateralInBandE36, w.bandDiscountRatio, 1e18);
                if (bandDiscountE36 > w.underlyingReserveCapacityE36) {
                    // Reserve pool has a capacity limit and wont be able to supply it's part of the collateralInBand,
                    // so we shift the onus on reaching the upper bound to the supplied collateral
                    collateralInBandE36 += bandDiscountE36 - w.underlyingReserveCapacityE36;
                    collateralInBandE36 = Math.min(collateralInBandE36, w.underlyingCollateralInLeftE36);
                    bandDiscountE36 = w.underlyingReserveCapacityE36;
                }
            } else {
                // no discount
                collateralInBandE36 = Math.mulDiv(
                    ConfigIncentiveLib._collateralRatioUpperBounds(config_, w.band) * w.peggedTokenHeldE36 -
                        w.underlyingCollateralHeldE36 * cr.price,
                    1e18,
                    cr.price * (1e18 - w.bandFeeRatio)
                );
                collateralInBandE36 = Math.min(collateralInBandE36, w.underlyingCollateralInLeftE36);
            }

            // we have, for the band the user collateral needed, and the band discount

            w.underlyingCollateralHeldE36 += collateralInBandE36;
            w.underlyingCollateralInLeftE36 -= collateralInBandE36;
            w.underlyingCollateralAddedE36 += collateralInBandE36;

            if (w.bandFeeRatio > 0) {
                uint256 bandFeeE36 = Math.mulDiv(collateralInBandE36, w.bandFeeRatio, 1e18);
                w.underlyingFeeE36 += bandFeeE36;
                w.underlyingCollateralHeldE36 -= bandFeeE36;
                w.underlyingCollateralAddedE36 -= bandFeeE36;
            } else if (bandDiscountE36 > 0) {
                w.underlyingDiscountE36 += bandDiscountE36;
                w.underlyingReserveCapacityE36 -= bandDiscountE36;
                w.underlyingCollateralHeldE36 += bandDiscountE36;
                w.underlyingCollateralAddedE36 += bandDiscountE36;
            }

            w.band++;
        }
        wrappedDiscount = w.underlyingDiscountE36 / cr.rate; // we don't round this as it may overflow the reserve pool
        wrappedFee = _round(w.underlyingFeeE36, cr.rate);
        if (w.leveragedTokenBalance > 0) {
            leveragedMinted = Math.mulDiv(
                w.underlyingCollateralAddedE36,
                cr.price * w.leveragedTokenBalance,
                w.collateralValueE36 - w.peggedValueE36
            );
        } else if (w.underlyingCollateralAddedE36 > 0) {
            leveragedMinted = Math.mulDiv(w.underlyingCollateralHeldE36, cr.price, 1e18) - w.peggedValueE36;
        } else {
            leveragedMinted = 0;
        }
        leveragedMinted = _round(leveragedMinted, 1e18);
        underlyingCollateralAdded = _round(w.underlyingCollateralAddedE36, 1e18);
    }

    struct RedeemLeveragedWorkspace {
        uint256 underlyingCollateralInE36;
        uint256 underlyingCollateralInLeftE36; // remaining underlying collateral to process (underlying * 1e18)
        uint256 underlyingFeeE54; // Σ(collateralInBandE36 * feeRatio)
        uint256 underlyingCollateralRemovedE36; // Σ(collateralInBandE36) (underlying * 1e18, pre-fee)
        uint256 underlyingCollateralHeldE36; // provisional collateral balance (underlying * 1e18)
    }

    /// @notice Perform a dry run of a redeem leveraged to calculate the various transfers of tokens
    /// Fees and disallows relating to the different incentiveRatios values are calculated as sum, weighted
    /// in proportion, in collateral space, to the amount spent within each collateral ratio boundary.
    /// It essentially performs a definite integral of the fee function.
    /// @param config_ The collateral ratio boundaries and the incentive ratios within each boundary,
    /// for redeeming leveraged tokens.
    /// @param leveragedIn The given amount of leveraged tokens.
    /// @param cr contains:
    ///    UnderlyingCollateral The amount of collateral held. This is used to calculate collateral ratios.
    ///    The price value of a collateral token in terms of the pegged token, and the rate of wrapped collateral to underlying collateral.
    ///    peggedTokenBalance The amount of pegged tokens issued. This is used to calculate collateral ratios.
    /// @param leveragedTokenBalance_ the current supply of leveraged tokens, assumed to be > 0.
    /// @return wrappedFee the fee charged in collateral tokens.
    /// @return leveragedRedeemed the leveraged tokens to be burned.
    /// @return wrappedCollateralOut the collateral returned to the receiver in exchange for the `leveragedRedeemed`
    /// @return underlyingCollateralRemoved the collateral removed from the system

    function _redeemLeveragedAdjustments(
        ConfigIncentiveLib.ActionIncentive memory config_,
        uint256 leveragedIn,
        CollateralRatioData memory cr,
        uint256 leveragedTokenBalance_
    )
        internal
        pure
        returns (
            uint256 wrappedFee,
            uint256 leveragedRedeemed,
            uint256 wrappedCollateralOut,
            uint256 underlyingCollateralRemoved
        )
    {
        RedeemLeveragedWorkspace memory w;

        // we can't meaningfully do anything with leveraged tokens as their value is zero
        // and we an do this once, here, and not in the loop below, because redeeming leveraged tokens, will never cause a re-peg.
        {
            (uint256 collateralValueE36, uint256 peggedValueE36) = _tokenValuesE36(
                cr.peggedTokenBalance,
                cr.underlyingCollateral,
                cr.price
            );
            if (collateralValueE36 <= peggedValueE36 || leveragedTokenBalance_ == 0 || leveragedIn == 0) {
                // there is no value in the leveraged being offered
                return (0, 0, 0, 0);
            }

            // we know leveraged token balance is > 0
            w.underlyingCollateralInE36 = Math.mulDiv(
                collateralValueE36 - peggedValueE36,
                leveragedIn * 1e18,
                cr.price * leveragedTokenBalance_
            );
            w.underlyingCollateralInLeftE36 = w.underlyingCollateralInE36;
        }
        // solhint-disable-next-line explicit-types
        uint band = _findBand(config_, cr.underlyingCollateral, cr.price, cr.peggedTokenBalance, false);
        w.underlyingCollateralHeldE36 = cr.underlyingCollateral * 1e18;

        while (true) {
            uint256 bandFeeRatio = uint256(ConfigIncentiveLib._incentiveRatio(config_, band)); // no discounts for this action
            if (bandFeeRatio == 1 ether) {
                // fee ratio of 100% means the action is disallowed, and in the lowest band
                break;
            }
            uint256 bandLowerBound = ConfigIncentiveLib._collateralRatioLowerBounds(config_, band);
            if (bandLowerBound < 1 ether) {
                // depegged (as there is always a CR = 1 boundary) means we disallow redeeming leveraged
                // because the price has become 0
                break;
            }
            uint256 collateralInBandE36;
            {
                // segment pre-fee underlying (1e18 scale):
                // netValue = (segment - fee)*price = segment*(1 - f/1e18)*price/1e18
                // => segment = valueToLowerBoundE36 * 1e18 / (price * (1 - f))
                // the fee is taken from the returned collateral not the input
                collateralInBandE36 =
                    w.underlyingCollateralHeldE36 - Math.mulDiv(bandLowerBound * 1e18, cr.peggedTokenBalance, cr.price);
                collateralInBandE36 = Math.min(collateralInBandE36, w.underlyingCollateralInLeftE36);
            }
            w.underlyingFeeE54 += collateralInBandE36 * bandFeeRatio;
            w.underlyingCollateralRemovedE36 += collateralInBandE36;
            w.underlyingCollateralInLeftE36 -= collateralInBandE36;

            // If we fully traversed this band's remaining distance (collateralInBandE36 == segmentTargetE36) descend one band.
            // slither-disable-next-line incorrect-equality
            if (w.underlyingCollateralInLeftE36 == 0 || band == 0 || bandLowerBound == 1 ether) {
                break;
            }
            w.underlyingCollateralHeldE36 -= collateralInBandE36;
            band--;
        }
        underlyingCollateralRemoved = _round(w.underlyingCollateralRemovedE36, 1e18);
        // calculate the leveraged for the collateral assuming constant leveraged price.
        leveragedRedeemed = Math.mulDiv(leveragedIn, w.underlyingCollateralRemovedE36, w.underlyingCollateralInE36);

        wrappedFee = w.underlyingFeeE54 / (cr.rate * 1e18);
        wrappedCollateralOut = w.underlyingCollateralRemovedE36 / cr.rate - wrappedFee;
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
        ConfigIncentiveLib.ActionIncentive memory config_,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice,
        uint256 peggedTokenBalance_,
        bool atLower
    )
        internal
        pure
        returns (
            uint band // solhint-disable-line explicit-types
        )
    {
        uint256 collateralRatio_ = _collateralRatio(collateralTokenBalance_, collateralPrice, peggedTokenBalance_);
        for (band = 0; band < ConfigIncentiveLib._collateralRatioBandCount(config_) - 1; band++) {
            uint256 bandUpperBound = ConfigIncentiveLib._collateralRatioUpperBounds(config_, band);
            if (atLower) {
                if (collateralRatio_ < bandUpperBound) {
                    break;
                }
            } else {
                if (collateralRatio_ <= bandUpperBound) {
                    break;
                }
            }
        }
    }

    // other calculations
    // ------------------

    // the price of a pegged token taking into account de-peg rate
    function _peggedTokenPriceE36(
        uint256 peggedTokenBalance_,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice
    ) internal pure returns (uint256 navE36) {
        if (peggedTokenBalance_ > 0) {
            (, navE36) = _tokenValuesE36(peggedTokenBalance_, collateralTokenBalance_, collateralPrice);
            navE36 = Math.mulDiv(navE36, 1 ether, peggedTokenBalance_);
        } else {
            navE36 = 1 ether * 1 ether;
        }
    }

    function _tokenValuesE36(
        uint256 peggedTokenBalance_,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice
    ) internal pure returns (uint256 collateralValueE36, uint256 peggedValueE36) {
        collateralValueE36 = collateralTokenBalance_ * collateralPrice;
        peggedValueE36 = peggedTokenBalance_ * 1 ether;
        // the value of the pegged cannot be greater than the value of the collateral
        if (peggedValueE36 > collateralValueE36) {
            peggedValueE36 = collateralValueE36;
        }
    }

    function _leverageRatio(
        uint256 peggedTokenBalance_,
        uint256 underlyingCollateral_,
        uint256 price
    ) internal pure returns (uint256 ratio) {
        (uint256 collateralValueE36, uint256 peggedValueE36) = _tokenValuesE36(
            peggedTokenBalance_,
            underlyingCollateral_,
            price
        );
        if (peggedValueE36 >= collateralValueE36) {
            // it divides by 0 or goes negative!
            ratio = _LEVERAGE_RATIO_CAP;
        } else {
            // we have collateral and it's worth something
            ratio = Math.mulDiv(collateralValueE36, 1 ether, collateralValueE36 - peggedValueE36);
            if (ratio > _LEVERAGE_RATIO_CAP) {
                ratio = _LEVERAGE_RATIO_CAP;
            }
        }
    }

    function _round(uint256 numerator, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            result = numerator / denominator;
            uint256 remainder = numerator % denominator;

            uint256 halfDenominator = denominator >> 1;

            if (remainder >= halfDenominator) result += 1;
        }
    }

    /// @dev function to accumulate an error term from a divide by 1 ether
    function _divAccumulateError(
        uint256 preDivideE54,
        int256 errorE54
    ) internal pure returns (uint256 postDivideE36, int256 newErrorE54) {
        unchecked {
            postDivideE36 = preDivideE54 / 1 ether; // scaled to 1e36
            newErrorE54 = errorE54 + (int256(preDivideE54) % 1 ether);
            // perform a rounding to nearest
            if (newErrorE54 >= 0.5 ether) {
                postDivideE36 += 1; // rounding up, which is the nearest in this case
                newErrorE54 -= 1 ether; // remove the above correction
            }
        }
    }

    function _leveragedTokensForPegged(
        uint256 peggedIn,
        uint256 leveragedTokenBalance_,
        uint256 peggedTokenBalance_,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice
    ) internal pure returns (uint256 leveragedTokens) {
        // we use leverage ratio for this calculation as it is capped
        if (leveragedTokenBalance_ > 0) {
            uint256 leverageRatio_ = _leverageRatio(peggedTokenBalance_, collateralTokenBalance_, collateralPrice);
            // slither-disable-next-line incorrect-equality
            if (leverageRatio_ == _LEVERAGE_RATIO_CAP) {
                // cap the amount returned
                leveragedTokens = Math.mulDiv(peggedIn, _LEVERAGE_RATIO_CAP, 1 ether);
            } else {
                // Convert using leverage ratio approach as this is only called in a rebalance context
                leveragedTokens = Math.mulDiv(
                    peggedIn * leveragedTokenBalance_,
                    leverageRatio_,
                    collateralTokenBalance_ * collateralPrice
                );
            }
        } else {
            leveragedTokens = peggedIn; // TODO: the third place initial price of 1 ether is assumed
        }
    }

    /// @notice Calculates the raw collateral ratio without any flooring.
    /// @dev This returns the actual mathematical ratio (collateralValue / peggedValue) which may be < 1 in depegged scenarios.
    /// Semantics:
    /// - Hot path (pegged > 0): single branch then mulDiv; zero collateral/price naturally yields 0.
    /// - If pegged == 0:
    ///     - If price == 0 => 0  (collateral has zero value; limit as Z→0+ is 0)
    ///     - Else if collateral == 0 => 1e18 (define 0/0 as 1.0)
    ///     - Else => +infinity encoded as 1e36
    /// @param collateralTokenBalance_ The amount of collateral tokens
    /// @param collateralPrice The price of collateral in terms of the pegged token
    /// @param peggedTokenBalance_ The amount of pegged tokens
    /// @return collateralRatio_ The raw collateral ratio with 18 decimals
    function _collateralRatio(
        uint256 collateralTokenBalance_,
        uint256 collateralPrice,
        uint256 peggedTokenBalance_
    ) internal pure returns (uint256 collateralRatio_) {
        // Hot path: pegged > 0 → just compute the ratio (covers collateral==0 or price==0 as 0).
        // slither-disable-next-line incorrect-equality
        if (peggedTokenBalance_ != 0) {
            return Math.mulDiv(collateralTokenBalance_, collateralPrice, peggedTokenBalance_);
        }

        // Cold path: pegged == 0 → handle edge semantics without doing mulDiv.
        // slither-disable-next-line incorrect-equality
        if (collateralPrice == 0) {
            return 0; // zero value collateral implies CR→0 in the Z→0+ limit
        }
        // slither-disable-next-line incorrect-equality
        if (collateralTokenBalance_ == 0) {
            return 1 ether; // define 0/0 as 1.0
        }
        return 1 ether * 1 ether; // encode +infinity as 1e36
    }

    /// @notice Returns the amount of leveraged tokens being managed
    function _leveragedTokenBalance() internal view returns (uint256) {
        return IERC20(LEVERAGED_TOKEN).totalSupply();
    }

    // fetching collateral price in terms of the pegged tokens
    // -------------------------------------------------------

    struct OracleData {
        uint256 price;
        uint256 rate;
    }

    /// @notice Returns the safe price for the collateral token.
    /// @dev Checks safe price non-zero.
    function _fetchMid(address priceOracle_) internal view returns (OracleData memory) {
        (uint256 minPrice, uint256 maxPrice, uint256 minRate, uint256 maxRate) = IWrappedPriceOracle(priceOracle_)
            .latestAnswer();
        return OracleData(_round(minPrice + maxPrice, 2), _round(minRate + maxRate, 2));
    }

    /// @notice Returns the min price for the collateral token.
    /// If the safe price is valid it is returned, else the min price.
    /// @dev Checks the returned price is non-zero.
    function _fetchMin(address priceOracle_) internal view returns (OracleData memory) {
        // slither-disable-next-line unused-return
        (uint256 minPrice, , uint256 minRate, ) = IWrappedPriceOracle(priceOracle_).latestAnswer();
        return OracleData(minPrice, minRate);
    }

    /// @notice Returns the max price for the collateral token.
    /// If the safe price is valid it is returned, else the max price.
    /// @dev Checks the returned price is non-zero.
    function _fetchMax(address priceOracle_) internal view returns (OracleData memory) {
        // slither-disable-next-line unused-return
        (, uint256 maxPrice, , uint256 maxRate) = IWrappedPriceOracle(priceOracle_).latestAnswer();
        return OracleData(maxPrice, maxRate);
    }

    // Harvesting support
    // -------------------------------------------------------
    /// @notice function used to control access to the sweep function for extracting harvestable amounts
    function _checkSweeper() internal view override(TokenHolder) {
        _checkOwnerOrRoles(HARVESTER_ROLE);
    }
}
