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
// solhint-disable-next-line contract-name-camelcase
contract Minter_v1 is
    Initializable,
    UUPSUpgradeable,
    ContextUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    BaoOwnableRoles,
    TokenHolder,
    IMinter
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

    // uint256 public constant MAX_TOKEN_AMOUNT = 1e36; // 1e36 is the maximum amount of tokens that can be minted or redeemed
    // uint256 public constant MIN_TOKEN_AMOUNT = 1e3; // 1e9 is the minimum amount of tokens that can be minted or redeemed

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
        uint256 collateralTokenBalance_ = $.underlyingCollateral;

        // slither-disable-next-line incorrect-equality // testing for initial conditions
        if (collateralTokenBalance_ == 0) {
            // there's no collateral tokens,
            // so we get 0 / 0 which we are defining to be 1 in this case.
            // why? because immediately after the first mint of a pegged token, we have a collateral ratio of 1.
            collateralRatio_ = 1 ether;
        } else {
            uint256 peggedTokenBalance_ = $.peggedTokenBalance;
            OracleData memory oracle = _fetchMid($.priceOracle);
            if (peggedTokenBalance_ == 0) {
                // we're going to get a divide by zero!
                // we're not going to revert but return a number!
                // and we're not going to use uint(-1) because that is often used for something else.
                // in 256 bits we have up to 77 digits (before and after the poinyt) to represent big numbers
                // BUT, there are two possibilities:
                // slither-disable-next-line incorrect-equality
                if (oracle.price == 0) {
                    // 1) there is collateral, but the price is 0,
                    //    so we get 0 / 0 which we are defining to be a very big number, in this case
                    //    we don't use the biggest number because the price may be zero due to truncation
                    collateralRatio_ = 1 ether * 1 ether; // that's 54 decimal digits, 36 before the point
                } else {
                    // 2) there is collateral value, because there are leveraged tokens (i.e. all the pegged are redeemed)
                    //    in this case, the collateral ratio is x / 0, which is a very very big number
                    collateralRatio_ = 1 ether * 1 ether * 1 ether; // that's 72 decimal digits, 54 before the point
                }
            } else {
                collateralRatio_ = _collateralRatio(collateralTokenBalance_, oracle.price, peggedTokenBalance_);
            }
        }
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
        (uint256 collateralValue$, uint256 peggedValue$) = _tokenValues$(
            $.peggedTokenBalance,
            $.underlyingCollateral,
            oracle.price
        );
        nav = _leveragedTokenPrice$(collateralValue$, peggedValue$, _leveragedTokenBalance()) / 1 ether;
    }

    function _leveragedTokenPrice$(
        uint256 collateralValue$,
        uint256 peggedValue$,
        uint256 leveragedTokenBalance_
    ) internal pure returns (uint256 nav$) {
        if (leveragedTokenBalance_ == 0) {
            nav$ = 1e36;
        } else {
            // by definition the leveraged token value is the difference between the collateral value and pegged value
            nav$ = Math.mulDiv(collateralValue$ - peggedValue$, 1e18, leveragedTokenBalance_);
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
            (, uint256 peggedValue$) = _tokenValues$(peggedTokenBalance_, $.underlyingCollateral, oracle.price);
            nav = peggedValue$ / peggedTokenBalance_;
        }
    }

    /// @inheritdoc IMinter
    function redeemPeggedForCollateralRatio(
        uint256 targetCollateralRatio
    ) external view returns (uint256 peggedForCollateral, uint256 peggedForLeveraged) {
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
            peggedForLeveraged = peggedTokenBalance_ - (collateralTokenBalance_ * oracle.price) / targetCollateralRatio;
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

    /// @inheritdoc IMinter
    function mintPeggedTokenDryRun(
        uint256 wrappedCollateralIn
    )
        external
        view
        returns (
            int256 incentiveRatio,
            uint256 wrappedFee,
            uint256 wrappedCollateralTaken,
            uint256 peggedMinted,
            uint256 price,
            uint256 rate
        )
    {
        MinterStorage storage $ = _getMinterStorage();
        OracleData memory oracle = _fetchMid($.priceOracle);
        price = oracle.price;
        rate = oracle.rate;
        uint256 underlyingCollateralAdded;
        (wrappedFee, peggedMinted, wrappedCollateralTaken, underlyingCollateralAdded) = _mintPeggedAdjustments(
            $.incentiveConfig[Config_v1.MINT_PEGGED],
            wrappedCollateralIn,
            CollateralRatioData($.underlyingCollateral, oracle.price, oracle.rate, $.peggedTokenBalance)
        );
        // slither-disable-next-line incorrect-equality
        incentiveRatio = wrappedCollateralTaken == 0
            ? int256(1 ether)
            : int256(wrappedFee * 1 ether) / int256(wrappedCollateralTaken);
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
        MinterStorage storage $ = _getMinterStorage();
        OracleData memory oracle = _fetchMid($.priceOracle);
        price = oracle.price;
        rate = oracle.rate;
        peggedRedeemed = peggedIn;
        // TODO: add redeemable check here - same for other dryrun functions
        (wrappedFee, wrappedDiscount, wrappedCollateralReturned, ) = _redeemPeggedAdjustments(
            $.incentiveConfig[Config_v1.REDEEM_PEGGED],
            peggedIn,
            CollateralRatioData($.underlyingCollateral, oracle.price, oracle.rate, $.peggedTokenBalance),
            IERC20(WRAPPED_COLLATERAL_TOKEN).balanceOf($.reservePool)
        );
        // slither-disable-next-line incorrect-equality
        incentiveRatio = peggedRedeemed == 0
            ? int256(1 ether)
            : ((int256(wrappedFee) - int256(wrappedDiscount)) * int256(price)) / int256(peggedRedeemed);
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
        MinterStorage storage $ = _getMinterStorage();
        OracleData memory oracle = _fetchMid($.priceOracle);
        price = oracle.price;
        rate = oracle.rate;
        wrappedCollateralUsed = wrappedCollateralIn;
        (wrappedFee, wrappedDiscount, leveragedMinted, ) = _mintLeveragedAdjustments(
            $.incentiveConfig[Config_v1.MINT_LEVERAGED],
            wrappedCollateralIn,
            CollateralRatioData($.underlyingCollateral, oracle.price, oracle.rate, $.peggedTokenBalance),
            IERC20(WRAPPED_COLLATERAL_TOKEN).balanceOf($.reservePool)
        );
        incentiveRatio = ((int256(wrappedFee) - int256(wrappedDiscount)) * 1 ether) / int256(wrappedCollateralUsed);
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
        MinterStorage storage $ = _getMinterStorage();
        // TODO: what to do if leveragedTokenBalance_ == 0
        OracleData memory oracle = _fetchMid($.priceOracle);
        price = oracle.price;
        rate = oracle.rate;
        (wrappedFee, leveragedRedeemed, wrappedCollateralReturned, ) = _redeemLeveragedAdjustments(
            $.incentiveConfig[Config_v1.REDEEM_LEVERAGED],
            leveragedIn,
            CollateralRatioData($.underlyingCollateral, price, rate, $.peggedTokenBalance)
        );
        // slither-disable-next-line incorrect-equality
        incentiveRatio = int256(
            wrappedCollateralReturned == 0 ? 1 ether : (wrappedFee * 1 ether) / (wrappedCollateralReturned + wrappedFee)
        );
    }

    /// @inheritdoc IMinter
    function harvestable() external view returns (uint256 wrappedAmount) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 rate = _fetchMid($.priceOracle).rate;
        wrappedAmount = 0;
        if (rate > 0) {
            uint256 balance = IERC20(WRAPPED_COLLATERAL_TOKEN).balanceOf(address(this));
            uint256 value = ($.underlyingCollateral * 1 ether) / rate;
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
        wrapped = (wrapped * oracle.rate);
        unchecked {
            wrapped /= 1 ether;
        }
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
        MinterStorage storage $ = _getMinterStorage();
        // work out how much collateral to use
        OracleData memory oracle = _fetchMid($.priceOracle);
        wrappedCollateralIn = Token.allOf(_msgSender(), WRAPPED_COLLATERAL_TOKEN, wrappedCollateralIn);

        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        uint256 underlyingCollateral_ = $.underlyingCollateral;

        // fee, etc. calculation
        uint256 wrappedFee;
        uint256 underlyingCollateralAdded;
        (wrappedFee, peggedOut, wrappedCollateralIn, underlyingCollateralAdded) = _mintPeggedAdjustments(
            $.incentiveConfig[Config_v1.MINT_PEGGED],
            wrappedCollateralIn,
            CollateralRatioData(underlyingCollateral_, oracle.price, oracle.rate, peggedTokenBalance_)
        );

        // slither-disable-next-line incorrect-equality
        if (wrappedCollateralIn == 0) {
            revert MintZeroAmount(PEGGED_TOKEN);
        }

        // check the amounts involved
        // slither-disable-next-line incorrect-equality
        if (peggedOut < minPeggedOut) {
            revert MintInsufficientAmount(PEGGED_TOKEN, peggedOut, minPeggedOut);
        }

        // do the mint for collateral
        _mintPeggedToken(wrappedCollateralIn, peggedOut, receiver);

        // take the fee
        if (wrappedFee > 0) {
            IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer($.feeReceiver, wrappedFee);
        }

        // update our records
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
        (wrappedFee, wrappedDiscount, wrappedCollateralOut, underlyingCollateralRemoved) = _redeemPeggedAdjustments(
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
        (wrappedFee, wrappedDiscount, leveragedOut, underlyingCollateralAdded) = _mintLeveragedAdjustments(
            $.incentiveConfig[Config_v1.MINT_LEVERAGED],
            wrappedCollateralIn,
            CollateralRatioData(underlyingCollateral_, oracle.price, oracle.rate, $.peggedTokenBalance),
            IERC20(WRAPPED_COLLATERAL_TOKEN).balanceOf(reservePool_)
        );
        // slither-disable-next-line incorrect-equality
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
            CollateralRatioData(underlyingCollateral_, oracle.price, oracle.rate, $.peggedTokenBalance)
        );
        // slither-disable-next-line incorrect-equality
        if (leveragedIn == 0) {
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
        uint256 underlyingCollateralIn$ = wrappedCollateralIn * oracle.rate;

        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        uint256 underlyingCollateral_ = $.underlyingCollateral;

        // transfer and mint
        peggedOut = Math.mulDiv(
            underlyingCollateralIn$,
            oracle.price,
            _peggedTokenPrice$(peggedTokenBalance_, underlyingCollateral_, oracle.price)
        );

        _mintPeggedToken(wrappedCollateralIn, peggedOut, receiver);

        // update our records
        $.peggedTokenBalance = peggedTokenBalance_ + peggedOut;
        unchecked {
            underlyingCollateralIn$ /= 1 ether;
        }
        $.underlyingCollateral = underlyingCollateral_ + underlyingCollateralIn$;
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
            if (peggedForCollateral > 0) {
                uint256 underlyingCollateral_ = $.underlyingCollateral;
                uint256 underlyingCollateralOut$ = Math.mulDiv(
                    peggedForCollateral,
                    _peggedTokenPrice$(peggedTokenBalance_, underlyingCollateral_, oracle.price),
                    oracle.price
                );
                wrappedCollateralOut = underlyingCollateralOut$ / oracle.rate;
                // return the collateral
                IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer(receiver, wrappedCollateralOut);
                unchecked {
                    underlyingCollateralOut$ /= 1 ether;
                }
                $.underlyingCollateral = underlyingCollateral_ - underlyingCollateralOut$;
            }

            if (peggedForLeveraged > 0) {
                leveragedOut = _leveragedTokensForPegged(
                    peggedForLeveraged,
                    _leveragedTokenBalance(),
                    peggedTokenBalance_,
                    $.underlyingCollateral,
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
        // leveragedOut = _leveragedTokensForCollateral(
        //     underlyingCollateralIn,
        //     _leveragedTokenBalance(),
        //     $.peggedTokenBalance,
        //     $.underlyingCollateral,
        //     oracle.price
        // );
        (uint256 collateralValue$, uint256 peggedValue$) = _tokenValues$(
            $.peggedTokenBalance,
            $.underlyingCollateral,
            oracle.price
        );
        uint256 underlyingCollateralIn$ = wrappedCollateralIn * oracle.rate;
        uint256 leveragedTokenBalance_ = _leveragedTokenBalance();
        if (leveragedTokenBalance_ > 0) {
            leveragedOut =
                (underlyingCollateralIn$ * oracle.price) /
                _leveragedTokenPrice$(collateralValue$, peggedValue$, leveragedTokenBalance_);
        } else {
            leveragedOut = collateralValue$; // First term
            leveragedOut += Math.mulDiv(underlyingCollateralIn$, oracle.price, 1e18); // Second term
            leveragedOut -= $.peggedTokenBalance * 1e18;
            leveragedOut /= 1e18;
        }

        // mint the tokens to the receiver
        _mintLeveragedToken(wrappedCollateralIn, leveragedOut, receiver);

        // update our records
        $.underlyingCollateral += underlyingCollateralIn$ / 1e18;
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

        (uint256 collateralValue$, uint256 peggedValue$) = _tokenValues$(
            $.peggedTokenBalance,
            $.underlyingCollateral,
            oracle.price
        );
        if (collateralValue$ <= peggedValue$) {
            collateralOut = 0;
        } else {
            uint256 underlyingCollateralOut$;
            if (leveragedTokenBalance_ == 0) {
                underlyingCollateralOut$ = leveragedIn * oracle.price;
            } else {
                underlyingCollateralOut$ = Math.mulDiv(
                    leveragedIn * 1 ether,
                    collateralValue$ - peggedValue$,
                    oracle.price * leveragedTokenBalance_
                );
            }
            collateralOut = underlyingCollateralOut$ / oracle.rate;

            _redeemLeveragedToken(leveragedIn, collateralOut, receiver);

            // update our records
            unchecked {
                underlyingCollateralOut$ /= 1 ether;
            }
            $.underlyingCollateral -= underlyingCollateralOut$;
        }
    }

    ///////////////////////
    // Private functions //
    ///////////////////////

    /// @notice The storage hash for the shared-with-proxy storage
    // chisel eval 'keccak256(abi.encode(uint256(keccak256("bao.storage.Minter")) - 1)) & ~bytes32(uint256(0xff))'
    bytes32 private constant _MINTER_STORAGE = 0x92e73fe9557052b4a0b810a38eb7ef595ff750f166ca39d63b3f4c74937fef00;

    /// @notice Returns a reference to the contract state
    function _getMinterStorage() private pure returns (MinterStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _MINTER_STORAGE
        }
    }

    // Price/Rate Oracle
    // -----------------

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
    /// @param wrappedCollateralIn The amount of collateral to be taken from the sender.
    /// @param peggedOut The amount of pegged to be transferred to the `receiver`.
    /// @param receiver The address of the receiver.

    function _mintPeggedToken(uint256 wrappedCollateralIn, uint256 peggedOut, address receiver) private {
        emit MintPeggedToken(_msgSender(), receiver, wrappedCollateralIn, peggedOut);

        // mint the tokens to the receiver
        // wake-disable-next-line reentrancy // all callers to this function have nonReentrant guard
        IMintable(PEGGED_TOKEN).mint(receiver, peggedOut);

        // take the collateral
        IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransferFrom(_msgSender(), address(this), wrappedCollateralIn);
    }

    /// @notice burn pegged tokens in the way the like to burn
    function _burnPeggedToken(uint256 amount) private {
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

    function _redeemPeggedToken(uint256 peggedIn, uint256 wrappedCollateralOut, address receiver) private {
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

    function _mintLeveragedToken(uint256 wrappedCollateralIn, uint256 leveragedOut, address receiver) private {
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

    function _redeemLeveragedToken(uint256 leveragedIn, uint256 collateralOut, address receiver) private {
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
    ) private pure returns (uint256 amountOut) {
        amountOut = Math.min(amountIn, tokenBalance_);
        // slither-disable-next-line incorrect-equality
        if (amountOut == 0) {
            revert NoRedeemableTokens(token_);
        }
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
        uint256 underlyingCollateralInLeft$;
        uint256 underlyingCollateralHeld$;
        uint256 underlyingCollateralAdded$;
        uint256 peggedTokenHeld$;
        uint256 underlyingFee$;
        uint256 minted$;
        int256 feeError$$;
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
        CollateralRatioData memory cr
    )
        private
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
        if (cr.peggedTokenBalance == 0) {
            revert ActionPaused();
        }
        // find the band and it's lower bound where the current collateral ratio is
        // (note we treat the disallow band as any other here, except that it is the terminal band)
        // slither-disable-next-line uninitialized-local
        MintPeggedWorkspace memory w;
        uint band = _findBand(config_, cr.underlyingCollateral, cr.price, cr.peggedTokenBalance, false); // solhint-disable-line explicit-types
        uint256 peggedTokenPrice$ = _peggedTokenPrice$(cr.peggedTokenBalance, cr.underlyingCollateral, cr.price);

        w.underlyingCollateralInLeft$ = wrappedCollateralIn * cr.rate; // scaled to 1e36
        w.underlyingCollateralHeld$ = cr.underlyingCollateral * 1 ether; // scaled to 1e36
        w.peggedTokenHeld$ = cr.peggedTokenBalance * 1 ether;
        w.underlyingFee$ = 0;
        w.minted$ = 0;
        // simulate minting until we run out of collateral, adding the fee & collateral as we go
        while (true) {
            uint256 bandFeeRatio = uint256(ConfigIncentiveLib._incentiveRatio(config_, band)); // no discounts for this action
            if (bandFeeRatio == 1 ether) {
                // fee ratio of 100% means the action is disallowed, and in the lowest band
                break;
            }

            uint256 collateralInBand$; // includes the fee
            uint256 bandLowerBound = ConfigIncentiveLib._collateralRatioLowerBounds(config_, band);
            if (bandLowerBound <= 1 ether) {
                // We can never mint enough pegged tokens such that we de-peg and
                // if we have already de-pegged, we can use all the collateral given
                collateralInBand$ = w.underlyingCollateralInLeft$;
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
                uint256 phi$ = (bandLowerBound - 1e18) * (1e18 - bandFeeRatio);
                // console2.log("phi$=%s", phi$);
                collateralInBand$ = Math.mulDiv(
                    w.underlyingCollateralHeld$ * cr.price - bandLowerBound * w.peggedTokenHeld$,
                    1e36,
                    cr.price * phi$
                );
                collateralInBand$ = Math.min(w.underlyingCollateralInLeft$, collateralInBand$);
            }
            uint256 bandFee$;
            (bandFee$, w.feeError$$) = _divAccumulateError(collateralInBand$ * bandFeeRatio, w.feeError$$);
            w.underlyingFee$ += bandFee$;
            uint256 collateralAddedInBand$ = collateralInBand$ - bandFee$;
            w.underlyingCollateralAdded$ += collateralAddedInBand$;

            w.underlyingCollateralInLeft$ -= collateralInBand$;

            uint256 peggedMintedInBand$ = Math.mulDiv(collateralAddedInBand$, cr.price * 1 ether, peggedTokenPrice$);

            w.minted$ += peggedMintedInBand$;

            // slither-disable-next-line incorrect-equality
            if (w.underlyingCollateralInLeft$ == 0 || band == 0) {
                // we have run out of collateral for the simulation
                // or we are in the lowest band, so no more, so exit
                break;
            }
            // still some collateral left and we're allowed to mint, so simulate
            w.underlyingCollateralHeld$ += collateralAddedInBand$;
            w.peggedTokenHeld$ += peggedMintedInBand$;
            band--;
        }
        // return the results
        peggedMinted = w.minted$ / 1 ether;
        // first do calculations in underlying collateral
        underlyingCollateralAdded = _round(w.underlyingCollateralAdded$, 1 ether);
        // then wrapped collateral based on the underlying collateral numbers
        wrappedFee = w.underlyingFee$ / cr.rate;
        maxWrappedCollateralIn = (w.underlyingCollateralAdded$ + w.underlyingFee$) / cr.rate;
    }

    struct RedeemPeggedWorkspace {
        uint256 peggedInLeft$;
        uint256 underlyingCollateralHeld$;
        uint256 peggedTokenHeld$;
        uint256 underlyingFee$;
        uint256 underlyingDiscount$;
        uint256 redeemed$;
        int256 feeError$$;
        int256 discountError$$;
        int256 collateralHeldError$$;
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
        private
        pure
        returns (
            uint256 wrappedFee,
            uint256 wrappedDiscount, // amount requested from reserve pool
            uint256 wrappedCollateralReturned, // this includes the discount
            uint256 underlyingCollateralRemoved
        )
    {
        // slither-disable-next-line uninitialized-local
        RedeemPeggedWorkspace memory w;
        // solhint-disable-next-line explicit-types
        uint band = _findBand(config_, cr.underlyingCollateral, cr.price, cr.peggedTokenBalance, true);
        // simulate redeeming until we run out of pegged tokens, adding the fee & bonus as we go
        // We do this band at a time, pro-rating the resulting fee according to how much collateral was needed in
        // each band entered. We use collateral to pro-rate, rather than collateral ratio which would be simpler, because
        // we multiply the resulting ratios by the collateral for the final fee

        // we capture the pegged price now as it doesn't change throughout the process, even if depegged
        uint256 peggedPrice$ = _peggedTokenPrice$(cr.peggedTokenBalance, cr.underlyingCollateral, cr.price);

        w.peggedInLeft$ = peggedIn * 1 ether; // scaled to 1e36
        w.underlyingCollateralHeld$ = cr.underlyingCollateral * 1 ether; // scaled to 1e36
        w.peggedTokenHeld$ = cr.peggedTokenBalance * 1 ether;
        w.underlyingFee$ = 0;
        w.underlyingDiscount$ = 0;
        w.redeemed$ = 0;

        while (w.peggedInLeft$ > 0) {
            uint256 peggedInBand$;
            {
                if (band + 1 == ConfigIncentiveLib._collateralRatioBandCount(config_)) {
                    // the last band goes on forever and there must be more than 1 band
                    peggedInBand$ = w.peggedInLeft$;
                } else {
                    uint256 bandUpperBound = ConfigIncentiveLib._collateralRatioUpperBounds(config_, band);
                    if (bandUpperBound <= 1 ether) {
                        // given the price of the pegged is a proportionate share of the collateral and leveraged tokens are worthless
                        // we redeem all of it (at the depegged rate) in this band, at the rate for the band
                        peggedInBand$ = w.peggedInLeft$;
                    } else {
                        // note the bandUpperBound cannot be == 1 ether so this is safe below
                        peggedInBand$ =
                            (bandUpperBound * w.peggedTokenHeld$ - w.underlyingCollateralHeld$ * cr.price) /
                            (bandUpperBound - 1 ether);
                        peggedInBand$ = Math.min(w.peggedInLeft$, peggedInBand$);
                    }
                }
            }
            // account for pegged being removed
            w.peggedInLeft$ -= peggedInBand$;
            w.redeemed$ += peggedInBand$;
            w.peggedTokenHeld$ -= peggedInBand$;

            {
                uint256 collateralInBand$;
                (collateralInBand$, w.collateralHeldError$$) = _divAccumulateError(
                    Math.mulDiv(peggedInBand$, peggedPrice$, cr.price),
                    w.collateralHeldError$$
                );

                // tally the fee or discount - these values have no effect at the moment:
                // fees have already been accounted for and discounts come from the reserve pool
                int256 bandIncentiveRatio = ConfigIncentiveLib._incentiveRatio(config_, band);
                if (bandIncentiveRatio < 0) {
                    uint256 bandDiscount$;
                    (bandDiscount$, w.discountError$$) = _divAccumulateError(
                        collateralInBand$ * uint256(-bandIncentiveRatio),
                        w.discountError$$
                    );
                    w.underlyingDiscount$ += bandDiscount$;
                } else {
                    uint256 bandFee$;
                    (bandFee$, w.feeError$$) = _divAccumulateError(
                        collateralInBand$ * uint256(bandIncentiveRatio),
                        w.feeError$$
                    );
                    w.underlyingFee$ += bandFee$;
                }
                w.underlyingCollateralHeld$ -= collateralInBand$;
            }
            // still some pegged tokens left so continue redeeing them
            band++;
        }
        wrappedFee = w.underlyingFee$ / cr.rate;
        wrappedDiscount = Math.min(reserveWrappedCapacity, w.underlyingDiscount$ / cr.rate); // amount requested from reserve pool
        uint256 underlyingCollateralRemoved$ = cr.underlyingCollateral * 1 ether - w.underlyingCollateralHeld$;
        underlyingCollateralRemoved = _round(underlyingCollateralRemoved$, 1 ether);
        wrappedCollateralReturned = underlyingCollateralRemoved$ / cr.rate + wrappedDiscount - wrappedFee;
    }

    struct MintLeveragedWorkspace {
        uint256 underlyingCollateralInLeft$;
        uint256 underlyingReserveCapacity$;
        uint256 underlyingCollateralHeld$;
        uint256 underlyingCollateralAdded$;
        uint256 peggedTokenHeld$;
        uint256 underlyingFee$;
        uint256 underlyingDiscount$;
        uint256 bandFeeRatio;
        uint256 bandDiscountRatio;
        uint256 leveragedPrice$;
        uint256 leveragedTokenBalance;
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
    /// @return underlyingCollateralAdded the collateral added to the balance to return the wrappedCollateralIn.

    // slither-disable-next-line cyclomatic-complexity
    function _mintLeveragedAdjustments(
        ConfigIncentiveLib.ActionIncentive memory config_,
        uint256 wrappedCollateralIn,
        CollateralRatioData memory cr,
        uint256 reserveWrappedCapacity
    )
        private
        view
        returns (
            uint256 wrappedFee,
            uint256 wrappedDiscount,
            uint256 leveragedMinted,
            uint256 underlyingCollateralAdded
        )
    {
        // we cannot calculate our collateral ratio scale when there are no pegged tokens as it's infinite i.e. (/0)
        // slither-disable-next-line incorrect-equality
        if (cr.peggedTokenBalance == 0) {
            revert ActionPaused();
        }

        // slither-disable-next-line uninitialized-local
        MintLeveragedWorkspace memory w;
        {
            (uint256 collateralValue$, uint256 peggedValue$) = _tokenValues$(
                cr.peggedTokenBalance,
                cr.underlyingCollateral,
                cr.price
            );
            // leveraged tokens have no value (we may not have quite depegged, though)
            if (collateralValue$ <= peggedValue$) {
                return (0, 0, 0, 0);
            }
            w.leveragedTokenBalance = _leveragedTokenBalance();
            w.leveragedPrice$ = _leveragedTokenPrice$(collateralValue$, peggedValue$, w.leveragedTokenBalance);
        }

        // simulate minting leveaged tokens from current collateral ratio upwards,
        // applying the incentive at the correct ratio as we go.
        // We do this band at a time, pro-rating the resulting fee according to how much collateral was needed in
        // each band entered. We use collateral to pro-rate, rather than collateral ratio which would be simpler, because
        // we multiply the resulting ratios by the collateral for the final fee
        // solhint-disable-next-line explicit-types
        uint band = _findBand(config_, cr.underlyingCollateral, cr.price, cr.peggedTokenBalance, true);
        w.underlyingCollateralInLeft$ = wrappedCollateralIn * cr.rate; // scaled to 1e36
        w.underlyingReserveCapacity$ = reserveWrappedCapacity * cr.rate;
        w.underlyingCollateralHeld$ = cr.underlyingCollateral * 1e18;
        w.peggedTokenHeld$ = cr.peggedTokenBalance * 1e18;

        while (w.underlyingCollateralInLeft$ > 0) {
            // we calculate the collateral and discount for the current band
            uint256 collateralInBand$;
            uint256 bandDiscount$ = 0;
            {
                int256 incentiveRatio = ConfigIncentiveLib._incentiveRatio(config_, band);
                // get the fee and discount ratios
                w.bandFeeRatio = incentiveRatio > 0 ? uint256(incentiveRatio) : 0;
                w.bandDiscountRatio = incentiveRatio < 0 ? uint256(-incentiveRatio) : 0;
            }
            // now get:
            // the collateral in the band,
            // the corresponding discount
            // This is complex because both are dependent on the reservePool capacity which limits the discount which, in turn, inflences the collateral

            if (band + 1 == ConfigIncentiveLib._collateralRatioBandCount(config_)) {
                // the last band has no upper bound and there are at least 2 bands
                // gross collateral includes fees and discounts
                collateralInBand$ = w.underlyingCollateralInLeft$;
                if (w.bandDiscountRatio > 0) {
                    // theoretical
                    bandDiscount$ = (collateralInBand$ * w.bandDiscountRatio) / 1e18;
                    // actual
                    bandDiscount$ = Math.min(bandDiscount$, w.underlyingReserveCapacity$);
                }
            } else if (w.bandDiscountRatio > 0) {
                // discount
                // we calculate the collateralInBand assuming there is no reserve pool capacity limit (for this band)
                collateralInBand$ = Math.mulDiv(
                    ConfigIncentiveLib._collateralRatioUpperBounds(config_, band) * w.peggedTokenHeld$ -
                        w.underlyingCollateralHeld$ * cr.price,
                    1e18,
                    cr.price * (1e18 + w.bandDiscountRatio)
                );
                // user limits how much of the band collateral is used (and the discount)
                collateralInBand$ = Math.min(collateralInBand$, w.underlyingCollateralInLeft$);

                // now check that the reserve pool can do it's corresponding bit
                bandDiscount$ = (collateralInBand$ * w.bandDiscountRatio) / 1e18;
                if (bandDiscount$ > w.underlyingReserveCapacity$) {
                    // Reserve pool has a capacity limit and wont be able to supply it's part of the collateralInBand,
                    // so we shift the onus on reaching the upper bound to the supplied collateral
                    collateralInBand$ += bandDiscount$ - w.underlyingReserveCapacity$;
                    collateralInBand$ = Math.min(collateralInBand$, w.underlyingCollateralInLeft$);
                    bandDiscount$ = w.underlyingReserveCapacity$;
                }
            } else {
                // no discount
                collateralInBand$ = Math.mulDiv(
                    ConfigIncentiveLib._collateralRatioUpperBounds(config_, band) * w.peggedTokenHeld$ -
                        w.underlyingCollateralHeld$ * cr.price,
                    1e18,
                    cr.price * (1e18 - w.bandFeeRatio)
                );
                collateralInBand$ = Math.min(collateralInBand$, w.underlyingCollateralInLeft$);
            }

            // we have, for the band the user collateral needed, and the band discount

            w.underlyingCollateralHeld$ += collateralInBand$;
            w.underlyingCollateralInLeft$ -= collateralInBand$;
            w.underlyingCollateralAdded$ += collateralInBand$;

            if (w.bandFeeRatio > 0) {
                uint256 bandFee$ = (collateralInBand$ * w.bandFeeRatio) / 1e18;
                w.underlyingFee$ += bandFee$;
                w.underlyingCollateralHeld$ -= bandFee$;
                w.underlyingCollateralAdded$ -= bandFee$;
            } else if (bandDiscount$ > 0) {
                w.underlyingDiscount$ += bandDiscount$;
                w.underlyingReserveCapacity$ -= bandDiscount$;
                w.underlyingCollateralHeld$ += bandDiscount$;
                w.underlyingCollateralAdded$ += bandDiscount$;
            }

            band++;
        }

        wrappedDiscount = w.underlyingDiscount$ / cr.rate; // we don't round this as it may overflow the reserve pool
        wrappedFee = _round(w.underlyingFee$, cr.rate);
        if (w.leveragedTokenBalance > 0) {
            leveragedMinted = Math.mulDiv(w.underlyingCollateralAdded$, cr.price, w.leveragedPrice$);
        } else {
            leveragedMinted = Math.mulDiv(w.underlyingCollateralHeld$, cr.price, 1e36) - cr.peggedTokenBalance;
        }
        underlyingCollateralAdded = _round(w.underlyingCollateralAdded$, 1e18);
    }

    struct RedeemLeveragedWorkspace {
        uint256 underlyingCollateralInLeft$; // remaining underlying collateral to process (underlying * 1e18)
        uint256 underlyingFee$$; // Σ(collateralInBand$ * feeRatio)
        uint256 underlyingCollateralRemoved$; // Σ(collateralInBand$) (underlying * 1e18, pre-fee)
        uint256 underlyingCollateralHeld$; // provisional collateral balance (underlying * 1e18)
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
    /// @return wrappedFee the fee charged in collateral tokens.
    /// @return leveragedRedeemed the leveraged tokens to be burned.
    /// @return wrappedCollateralOut the collateral returned to the receiver in exchange for the `leveragedRedeemed`
    /// @return underlyingCollateralRemoved the collateral removed from the system

    function _redeemLeveragedAdjustments(
        ConfigIncentiveLib.ActionIncentive memory config_,
        uint256 leveragedIn,
        CollateralRatioData memory cr
    )
        private
        view
        returns (
            uint256 wrappedFee,
            uint256 leveragedRedeemed,
            uint256 wrappedCollateralOut,
            uint256 underlyingCollateralRemoved
        )
    {
        // slither-disable-next-line incorrect-equality
        if (cr.peggedTokenBalance == 0) {
            revert ActionPaused();
        }
        // slither-disable-next-line uninitialized-local
        RedeemLeveragedWorkspace memory w;

        // we can't meaningfully do anything with leveraged tokens as their value is zero
        // and we an do this once, here, and not in the loop below, because redeeming leveraged tokens, will never cause a re-peg.

        (uint256 collateralValue$, uint256 peggedValue$) = _tokenValues$(
            cr.peggedTokenBalance,
            cr.underlyingCollateral,
            cr.price
        );
        // we know leveraged token balance is > 0
        uint256 leveragedPrice$ = _leveragedTokenPrice$(collateralValue$, peggedValue$, _leveragedTokenBalance());
        // slither-disable-next-line incorrect-equality
        if (leveragedPrice$ == 0) {
            return (0, 0, 0, 0);
        }
        w.underlyingCollateralInLeft$ = Math.mulDiv(leveragedIn, leveragedPrice$, cr.price);
        // solhint-disable-next-line explicit-types
        uint band = _findBand(config_, cr.underlyingCollateral, cr.price, cr.peggedTokenBalance, false);
        w.underlyingCollateralHeld$ = cr.underlyingCollateral * 1e18;

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
            uint256 collateralInBand$;
            {
                // segment pre-fee underlying (1e18 scale):
                // netValue = (segment - fee)*price = segment*(1 - f/1e18)*price/1e18
                // => segment = valueToLowerBound$ * 1e18 / (price * (1 - f))
                // the fee is taken from the returned collateral not the input
                collateralInBand$ =
                    w.underlyingCollateralHeld$ - Math.mulDiv(bandLowerBound * 1e18, cr.peggedTokenBalance, cr.price);
                // collateralInBand$ =
                //     (w.underlyingCollateralHeld$ * cr.price - bandLowerBound * cr.peggedTokenBalance) /
                //     (cr.price * (1e18 - bandFeeRatio));
                collateralInBand$ = Math.min(collateralInBand$, w.underlyingCollateralInLeft$);
            }
            w.underlyingFee$$ += collateralInBand$ * bandFeeRatio;
            w.underlyingCollateralRemoved$ += collateralInBand$;
            w.underlyingCollateralInLeft$ -= collateralInBand$;

            // If we fully traversed this band's remaining distance (collateralInBand$ == segmentTarget$) descend one band.
            // slither-disable-next-line incorrect-equality
            if (w.underlyingCollateralInLeft$ == 0 || band == 0 || bandLowerBound == 1 ether) {
                break;
            }
            w.underlyingCollateralHeld$ -= collateralInBand$;
            band--;
        }

        underlyingCollateralRemoved = _round(w.underlyingCollateralRemoved$, 1e18);
        // calculate the leveraged for the collateral assuming constant leveraged price.
        leveragedRedeemed = (w.underlyingCollateralRemoved$ * cr.price) / leveragedPrice$;
        if (leveragedRedeemed > leveragedIn) {
            leveragedRedeemed = leveragedIn; // rounding guard
        }

        wrappedFee = w.underlyingFee$$ / (cr.rate * 1e18);
        wrappedCollateralOut = w.underlyingCollateralRemoved$ / cr.rate - wrappedFee;
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
        private
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
    function _peggedTokenPrice$(
        uint256 peggedTokenBalance_,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice
    ) private pure returns (uint256 nav$) {
        if (peggedTokenBalance_ > 0) {
            (, nav$) = _tokenValues$(peggedTokenBalance_, collateralTokenBalance_, collateralPrice);
            nav$ = (nav$ * 1 ether) / peggedTokenBalance_;
        } else {
            nav$ = 1 ether * 1 ether;
        }
    }

    function _tokenValues$(
        uint256 peggedTokenBalance_,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice
    ) private pure returns (uint256 collateralValue$, uint256 peggedValue$) {
        collateralValue$ = collateralTokenBalance_ * collateralPrice;
        peggedValue$ = peggedTokenBalance_ * 1 ether;
        // the value of the pegged cannot be greater than the value of the collateral
        if (peggedValue$ > collateralValue$) {
            peggedValue$ = collateralValue$;
        }
    }

    function _leverageRatio(
        uint256 peggedTokenBalance_,
        uint256 underlyingCollateral_,
        uint256 price
    ) internal pure returns (uint256 ratio) {
        (uint256 collateralValue$, uint256 peggedValue$) = _tokenValues$(
            peggedTokenBalance_,
            underlyingCollateral_,
            price
        );
        if (peggedValue$ >= collateralValue$) {
            // it divides by 0 or goes negative!
            ratio = _LEVERAGE_RATIO_CAP;
        } else {
            // we have collateral and it's worth something
            ratio = Math.mulDiv(collateralValue$, 1 ether, collateralValue$ - peggedValue$);
            if (ratio > _LEVERAGE_RATIO_CAP) {
                ratio = _LEVERAGE_RATIO_CAP;
            }
        }
    }

    function _round(uint256 numerator, uint256 denominator) private pure returns (uint256 result) {
        unchecked {
            result = numerator / denominator;
            uint256 remainder = numerator % denominator;

            uint256 halfDenominator = denominator >> 1;

            if (remainder >= halfDenominator) result += 1;
        }
    }

    /// @dev function to accumulate an error term from a divide by 1 ether
    function _divAccumulateError(
        uint256 preDivide$$,
        int256 error$$
    ) private pure returns (uint256 postDivide$, int256 newError$$) {
        unchecked {
            postDivide$ = preDivide$$ / 1 ether; // scaled to 1e36
            newError$$ = error$$ + (int256(preDivide$$) % 1 ether);
            // perform a rounding to nearest
            if (newError$$ >= 0.5 ether) {
                postDivide$ += 1; // rounding up, which is the nearest in this case
                newError$$ -= 1 ether; // remove the above correction
            }
        }
    }

    function _leveragedTokensForPegged(
        uint256 peggedIn,
        uint256 leveragedTokenBalance_,
        uint256 peggedTokenBalance_,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice
    ) private pure returns (uint256 leveragedTokens) {
        // we use leverage ratio for this calculation as it is capped
        if (leveragedTokenBalance_ > 0) {
            uint256 leverageRatio_ = _leverageRatio(peggedTokenBalance_, collateralTokenBalance_, collateralPrice);
            // slither-disable-next-line incorrect-equality
            if (leverageRatio_ == _LEVERAGE_RATIO_CAP) {
                // cap the amount returned
                leveragedTokens = (peggedIn * _LEVERAGE_RATIO_CAP);
                unchecked {
                    leveragedTokens /= 1 ether;
                }
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
    /// @dev This returns the actual mathematical ratio (collateralValue / peggedValue) which may be < 1
    /// in depegged scenarios. No special casing is done in this function - edge cases must be handled by the caller.
    /// @param collateralTokenBalance_ The amount of collateral tokens
    /// @param collateralPrice The price of collateral in terms of the pegged token
    /// @param peggedTokenBalance_ The amount of pegged tokens
    /// @return collateralRatio_ The raw collateral ratio with 18 decimals
    function _collateralRatio(
        uint256 collateralTokenBalance_,
        uint256 collateralPrice,
        uint256 peggedTokenBalance_
    ) private pure returns (uint256 collateralRatio_) {
        collateralRatio_ = (collateralTokenBalance_ * collateralPrice) / peggedTokenBalance_;
    }

    /// @notice Returns the amount of leveraged tokens being managed
    function _leveragedTokenBalance() private view returns (uint256) {
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
    function _fetchMid(address priceOracle_) private view returns (OracleData memory) {
        (uint256 minPrice, uint256 maxPrice, uint256 minRate, uint256 maxRate) = IWrappedPriceOracle(priceOracle_)
            .latestAnswer();
        return OracleData(_round(minPrice + maxPrice, 2), _round(minRate + maxRate, 2));
    }

    /// @notice Returns the min price for the collateral token.
    /// If the safe price is valid it is returned, else the min price.
    /// @dev Checks the returned price is non-zero.
    function _fetchMin(address priceOracle_) private view returns (OracleData memory) {
        // slither-disable-next-line unused-return
        (uint256 minPrice, , uint256 minRate, ) = IWrappedPriceOracle(priceOracle_).latestAnswer();
        return OracleData(minPrice, minRate);
    }

    /// @notice Returns the max price for the collateral token.
    /// If the safe price is valid it is returned, else the max price.
    /// @dev Checks the returned price is non-zero.
    function _fetchMax(address priceOracle_) private view returns (OracleData memory) {
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
