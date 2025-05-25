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
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

import {Token} from "@bao/Token.sol";
import {TokenHolder, ITokenHolder} from "@bao/TokenHolder.sol";

import {BaoOwnableRoles} from "@bao/BaoOwnableRoles.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {IMintable} from "@bao/interfaces/IMintable.sol";
import {IBurnable} from "@bao/interfaces/IBurnable.sol";
import {IBurnableFrom} from "@bao/interfaces/IBurnableFrom.sol";
import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {IReservePool} from "src/interfaces/IReservePool.sol";

import {ConfigIncentiveLib} from "src/minter/lib/ConfigIncentiveLib.sol";
import {Config_v1} from "src/minter/lib/Config_v1.sol";

/// @title Bao Minter
/// @author rootminus0x1 based on (albeit significantly modified) Aladdin's FX system
/// @notice Provides a gas-efficient, feature-rich implementation for the `IMinter` interface.
/// Functions are provided for users to mint (for wrapped collateral) and redeem (for wrapped collateral) pegged and leveraged tokens
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
/// Rebalance pools know about the minter contract they are offering a rebalance service to and set themselves up to use
/// The collateral ratio stored in this contract's config to allow or disallow liquidation calls to them.
/// ### Harvesting
/// Harvesting becomes available to be executed, transferring to the rebalance pools the value accrued by holding wrapped collateral
/// instead of underlying collateral. A portion of that is handed to the caller of the harvest function as a reward.
/// @dev Uses UUPS proxy, erc7201 storage
/// @dev As openzeppelin's validator doesn't currently suppoprt external libraries
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
    // using ConfigIncentiveLib for ActionIncentive;
    // using WordCodec for bytes32;

    ///////////////
    // Constants //
    ///////////////

    // /// @notice The precision at which incentive ratios are stored.
    // /// @dev Fee & bonus ratios are stored as int32, which allows for -2 billion to 2 billion.
    // /// With decimals = 9, this gives a max ratio of 2 (200%) with precision of 0.000000001 (0.0000001%),
    // /// these ratios must be in the range [-1, 1] [-100%, 100%].
    // /// This allows 8 of these to be stored in a slot.
    // uint private constant _INCENTIVE_RATIO_DECIMALS = 9; // solhint-disable-line explicit-types

    // /// @notice The precision at which collateral ratio bounds are stored.
    // /// @dev Collateral ratio bounds are stored as uint32, which allows for a maximum value of ~4 billion.
    // /// With decimals = 6, this gives a max ratio of 4,000 (400,000%) with precision of 0.000001 (0.0001%),
    // /// e.g. 130.55% is easily catered for.
    // /// This allows 8 of these to be stored in a slot. As there is one fewer bound, we only store 7. This, cunningly,
    // /// leaves space for a count so that we can have "up to" 7 bounds and 8 fee/discount levels
    // uint private constant _COLLATERAL_RATIO_DECIMALS = 6; // solhint-disable-line explicit-types

    // /// @notice The maximum number of fee/discount value bands that can be stored
    // /// @dev This is private because the public interface may differ, in particular to handle the piecewise valuation
    // /// of pegged tokens, an extra boundary (and band) is added if not present around the depeg point
    // uint private constant _MAX_BANDS = 8; // solhint-disable-line explicit-types
    // /// @notice The maximum number of collateral ratio bounds for fee/discount variation that can be stored
    // /// @dev This is private because the public interface may differ, in particular to handle the piecewise valuation
    // /// of pegged tokens, an extra boundary (and band) is added if not present around the depeg point
    // uint private constant _MAX_BOUNDS = _MAX_BANDS - 1; // solhint-disable-line explicit-types

    /// @notice The role that allows access to the zero fee versions of the functions.
    uint256 public constant ZERO_FEE_ROLE = _ROLE_0;

    /// @notice The role that allows access to the sweep function.
    uint256 public constant HARVESTER_ROLE = _ROLE_1;

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
        // TODO: merge harvestBountyRatio with underlyingCollateral into 1 slot?
        uint256 underlyingCollateral; //                256
        //                                             slot
        // @custom:security non-reentrant
        address reservePool; //                         160
        //                                             slot
        // @custom:security non-reentrant
        address feeReceiver; //                         160
        //                                             slot
        address priceOracle; //                         160
        //                                              slot
        uint256 rebalanceCollateralRatioUpperBound; // the upper collateral ratio at which rebalancing begins
        //                                              slot
        uint256 harvestBountyRatio;
        //                                             slot*2
        ConfigIncentiveLib.ActionIncentive mintPeggedIncentiveConfig;
        //                                             slot*2
        ConfigIncentiveLib.ActionIncentive redeemPeggedIncentiveConfig;
        //                                             slot*2
        ConfigIncentiveLib.ActionIncentive mintLeveragedIncentiveConfig;
        //                                             slot*2
        ConfigIncentiveLib.ActionIncentive redeemLeveragedIncentiveConfig;
    }

    // TODO: add function to add a rebalancer, granting role and keeping track of it for liquidation?

    ////////////////////
    // Initialisation //
    ////////////////////

    // UUPSUpgradeable functions
    // -------------------------

    // TODO: take stuff out of this and put it in deploy script
    function initialize(address owner_) external initializer {
        // initialise all the state variables
        _initializeOwner(owner_);
        __UUPSUpgradeable_init();
        __Context_init();
        __ReentrancyGuardTransient_init();
        MinterStorage storage $ = _getMinterStorage();
        $.peggedTokenBalance = 0;
    }

    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// https://forum.openzeppelin.com/t/what-does-disableinitializers-function-mean/28730
    /// @custom:oz-upgrades-unsafe-allow constructor
    // slither-disable-next-line missing-zero-check // ensureERC20Token is called
    constructor(address collateralToken_, address peggedToken_, address leveragedToken_) {
        _disableInitializers();

        Token.ensureERC20Token(collateralToken_);
        Token.ensureERC20Token(peggedToken_);
        Token.ensureERC20Token(leveragedToken_);

        WRAPPED_COLLATERAL_TOKEN = collateralToken_;
        PEGGED_TOKEN = peggedToken_;
        LEVERAGED_TOKEN = leveragedToken_;
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
    function config() public view returns (Config memory config_) {
        MinterStorage storage $ = _getMinterStorage();
        config_.rebalanceCollateralRatioUpperBound = $.rebalanceCollateralRatioUpperBound;
        config_.mintPeggedIncentiveConfig = Config_v1.copyBandsBack($.mintPeggedIncentiveConfig);
        config_.redeemPeggedIncentiveConfig = Config_v1.copyBandsBack($.redeemPeggedIncentiveConfig);
        config_.mintLeveragedIncentiveConfig = Config_v1.copyBandsBack($.mintLeveragedIncentiveConfig);
        config_.redeemLeveragedIncentiveConfig = Config_v1.copyBandsBack($.redeemLeveragedIncentiveConfig);
    }

    /// @inheritdoc IMinter
    function rebalanceCollateralRatio() external view returns (uint256) {
        MinterStorage storage $ = _getMinterStorage();
        return $.rebalanceCollateralRatioUpperBound;
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
        (uint256 collateralValue$, uint256 peggedValue$) = _tokenValues$(
            $.peggedTokenBalance,
            $.underlyingCollateral,
            oracle.price
        );
        if (peggedValue$ >= collateralValue$) {
            // it divides by 0 or goes negative!
            ratio = 100 ether;
        } else {
            // we have collateral and it's worth something
            // ratio = (1 ether * 1 ether) / (1 ether - (peggedValue$ / (collateralValue$ / 1 ether)));
            ratio = (1 ether * 1 ether) / (1 ether - ((peggedValue$ * 1 ether) / collateralValue$));
            if (ratio > 100 ether) ratio = 100 ether;
        }
    }

    /// @inheritdoc IMinter
    function leveragedTokenPrice() external view override returns (uint256 nav) {
        uint256 leveragedBalance = _leveragedTokenBalance();
        if (leveragedBalance == 0) {
            nav = 1 ether;
        } else {
            MinterStorage storage $ = _getMinterStorage();
            OracleData memory oracle = _fetchMid($.priceOracle);
            (uint256 collateralValue$, uint256 peggedValue$) = _tokenValues$(
                $.peggedTokenBalance,
                $.underlyingCollateral,
                oracle.price
            );
            // by definition the leveraged token value is the difference
            nav = (collateralValue$ - peggedValue$) / leveragedBalance;
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
    function leveragedTokensForCollateral(
        uint256 forWrappedCollateral
    ) external view override returns (uint256 leveragedTokens) {
        MinterStorage storage $ = _getMinterStorage();
        OracleData memory oracle = _fetchMid($.priceOracle);
        leveragedTokens = _leveragedTokensForCollateral(
            _underlyingValueOf(forWrappedCollateral, oracle.rate),
            _leveragedTokenBalance(),
            $.peggedTokenBalance,
            $.underlyingCollateral,
            oracle.price
        );
    }

    /// @inheritdoc IMinter
    function collateralForLeverageTokens(
        uint256 forLeveragedTokens
    ) external view override returns (uint256 wrappedCollateral) {
        MinterStorage storage $ = _getMinterStorage();
        OracleData memory oracle = _fetchMid($.priceOracle);
        // TODO: add check for being depegged here and remove it from the below function
        wrappedCollateral = _wrappedValueOf(
            _underlyingCollateralForLeveragedTokens(
                forLeveragedTokens,
                _leveragedTokenBalance(),
                $.peggedTokenBalance,
                $.underlyingCollateral,
                oracle.price
            ),
            oracle.rate
        );
    }

    /// @inheritdoc IMinter
    function redeemPeggedForCollateralRatio(
        uint256 targetCollateralRatio
    ) external view returns (uint256 peggedTokens) {
        MinterStorage storage $ = _getMinterStorage();
        OracleData memory oracle = _fetchMax($.priceOracle);
        uint256 collateralTokenBalance_ = $.underlyingCollateral;
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        if (targetCollateralRatio > _collateralRatio(collateralTokenBalance_, oracle.price, peggedTokenBalance_)) {
            peggedTokens = _redeemPeggedForCollateralRatio(
                targetCollateralRatio,
                collateralTokenBalance_,
                oracle.price,
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
        OracleData memory oracle = _fetchMax($.priceOracle);
        uint256 collateralTokenBalance_ = $.underlyingCollateral;
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        if (targetCollateralRatio > _collateralRatio(collateralTokenBalance_, oracle.price, peggedTokenBalance_)) {
            // from the definition of collateral ratio with no change in collateral only change in pegged
            peggedTokens = peggedTokenBalance_ - (collateralTokenBalance_ * oracle.price) / targetCollateralRatio;
        } else {
            peggedTokens = 0;
        }
    }

    // incentive ratios
    // ----------------

    /// @inheritdoc IMinter
    function mintPeggedTokenIncentiveRatio() external view override returns (int256 incentiveRatio) {
        MinterStorage storage $ = _getMinterStorage();
        ConfigIncentiveLib.ActionIncentive memory config_ = $.mintPeggedIncentiveConfig;
        // solhint-disable-next-line explicit-types
        OracleData memory oracle = _fetchMid($.priceOracle);
        uint band = _findBand(config_, $.underlyingCollateral, oracle.price, $.peggedTokenBalance, false); // solhint-disable-line explicit-types
        incentiveRatio = ConfigIncentiveLib._incentiveRatio(config_, band);
    }

    /// @inheritdoc IMinter
    function redeemPeggedTokenIncentiveRatio() external view override returns (int256 incentiveRatio) {
        MinterStorage storage $ = _getMinterStorage();
        ConfigIncentiveLib.ActionIncentive memory config_ = $.redeemPeggedIncentiveConfig;
        // solhint-disable-next-line explicit-types
        OracleData memory oracle = _fetchMax($.priceOracle);
        uint band = _findBand(config_, $.underlyingCollateral, oracle.price, $.peggedTokenBalance, false); // solhint-disable-line explicit-types
        incentiveRatio = ConfigIncentiveLib._incentiveRatio(config_, band);
    }

    /// @inheritdoc IMinter
    function mintLeveragedTokenIncentiveRatio() external view override returns (int256 incentiveRatio) {
        MinterStorage storage $ = _getMinterStorage();
        ConfigIncentiveLib.ActionIncentive memory config_ = $.mintLeveragedIncentiveConfig;
        // just want the fee/bonus at the current collateral
        OracleData memory oracle = _fetchMid($.priceOracle);
        // solhint-disable-next-line explicit-types
        uint band = _findBand(config_, $.underlyingCollateral, oracle.price, $.peggedTokenBalance, false);
        incentiveRatio = ConfigIncentiveLib._incentiveRatio(config_, band);
    }

    /// @inheritdoc IMinter
    function redeemLeveragedTokenIncentiveRatio() external view override returns (int256 incentiveRatio) {
        MinterStorage storage $ = _getMinterStorage();
        ConfigIncentiveLib.ActionIncentive memory config_ = $.redeemLeveragedIncentiveConfig;
        OracleData memory oracle = _fetchMin($.priceOracle);
        // solhint-disable-next-line explicit-types
        uint band = _findBand(config_, $.underlyingCollateral, oracle.price, $.peggedTokenBalance, false);
        incentiveRatio = ConfigIncentiveLib._incentiveRatio(config_, band);
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
        uint256 underlyingFee;
        uint256 underlyingCollateralTaken;
        (underlyingFee, peggedMinted, underlyingCollateralTaken) = _mintPeggedAdjustments(
            $.mintPeggedIncentiveConfig,
            _underlyingValueOf(wrappedCollateralIn, rate),
            $.underlyingCollateral,
            price,
            $.peggedTokenBalance
        );
        wrappedFee = _wrappedValueOf(underlyingFee, rate);
        wrappedCollateralTaken = _wrappedValueOf(underlyingCollateralTaken, rate);
        // slither-disable-next-line incorrect-equality
        incentiveRatio = wrappedCollateralTaken == 0
            ? int256(1 ether)
            : int256(wrappedFee * 1 ether) / int256(wrappedCollateralTaken);
    }

    /// @inheritdoc IMinter
    function redeemPeggedTokenDryRun(
        uint256 peggedIn
    )
        public
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
        uint256 underlyingFee$;
        uint256 underlyingDiscount$;
        uint256 underlyingCollateralReturned$;
        (underlyingFee$, underlyingDiscount$, peggedRedeemed, underlyingCollateralReturned$) = _redeemPeggedAdjustments(
            $.redeemPeggedIncentiveConfig,
            peggedIn,
            $.underlyingCollateral,
            price,
            $.peggedTokenBalance,
            _underlyingValueOf(IERC20(WRAPPED_COLLATERAL_TOKEN).balanceOf($.reservePool) * 1 ether, rate)
        );
        wrappedCollateralReturned = _wrappedValueOf(underlyingCollateralReturned$, rate) / 1 ether;
        wrappedFee = _wrappedValueOf(underlyingFee$, rate) / 1 ether;
        wrappedDiscount = _wrappedValueOf(underlyingDiscount$, rate) / 1 ether;
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
        uint256 underlyingFee;
        uint256 underlyingDiscount;
        (underlyingFee, underlyingDiscount, leveragedMinted) = _mintLeveragedAdjustments(
            $.mintLeveragedIncentiveConfig,
            _underlyingValueOf(wrappedCollateralIn, rate),
            Balances($.underlyingCollateral, $.peggedTokenBalance, _leveragedTokenBalance()),
            price,
            _underlyingValueOf(IERC20(WRAPPED_COLLATERAL_TOKEN).balanceOf($.reservePool), rate)
        );
        wrappedCollateralUsed = wrappedCollateralIn; // we never disallow minting leveraged tokens
        wrappedFee = _wrappedValueOf(underlyingFee, rate);
        wrappedDiscount = _wrappedValueOf(underlyingDiscount, rate);
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
        uint256 underlyingFee;
        uint256 underlyingCollateralReturned;
        (underlyingFee, leveragedRedeemed, underlyingCollateralReturned) = _redeemLeveragedAdjustments(
            $.redeemLeveragedIncentiveConfig,
            leveragedIn,
            $.underlyingCollateral,
            price,
            $.peggedTokenBalance,
            _leveragedTokenBalance()
        );
        wrappedCollateralReturned = _wrappedValueOf(underlyingCollateralReturned, rate);
        wrappedFee = _wrappedValueOf(underlyingFee, rate);
        // slither-disable-next-line incorrect-equality
        incentiveRatio = int256(
            underlyingCollateralReturned == 0 ? 1 ether : (wrappedFee * 1 ether) / wrappedCollateralReturned
        );
    }

    /// @inheritdoc IMinter
    function harvestable() external view returns (uint256 wrappedAmount) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 balance = IERC20(WRAPPED_COLLATERAL_TOKEN).balanceOf(address(this));
        uint256 value = _wrappedValueOf($.underlyingCollateral, _fetchMid($.priceOracle).rate);
        wrappedAmount = (balance > value) ? balance - value : 0;
    }

    //////////////////////////////
    // Public Mutator Functions //
    //////////////////////////////

    /// @inheritdoc IMinter
    function updateConfig(Config calldata config_) external override onlyOwner {
        // or is this handled by the fact that the CR for discount is much lower than the rebalance CR
        emit UpdateConfig(config_); // the code below may alter the config so emit it soon

        MinterStorage storage $ = _getMinterStorage();

        // action config
        $.rebalanceCollateralRatioUpperBound = config_.rebalanceCollateralRatioUpperBound;

        // incentive config
        $.mintPeggedIncentiveConfig = Config_v1.checkAndCopyBands(
            "mint pegged",
            config_.mintPeggedIncentiveConfig,
            true
        );
        $.redeemPeggedIncentiveConfig = Config_v1.checkAndCopyBands(
            "redeem pegged",
            config_.redeemPeggedIncentiveConfig,
            false
        );
        $.mintLeveragedIncentiveConfig = Config_v1.checkAndCopyBands(
            "mint leveraged",
            config_.mintLeveragedIncentiveConfig,
            false
        );
        $.redeemLeveragedIncentiveConfig = Config_v1.checkAndCopyBands(
            "redeem leveraged",
            config_.redeemLeveragedIncentiveConfig,
            true
        );
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
        uint256 underlyingFee;
        uint256 underlyingCollateralIn;
        (underlyingFee, peggedOut, underlyingCollateralIn) = _mintPeggedAdjustments(
            $.mintPeggedIncentiveConfig,
            _underlyingValueOf(wrappedCollateralIn, oracle.rate),
            underlyingCollateral_,
            oracle.price,
            peggedTokenBalance_
        );

        // slither-disable-next-line incorrect-equality
        if (underlyingCollateralIn == 0) revert MintZeroAmount(PEGGED_TOKEN);

        // check the amounts involved
        // slither-disable-next-line incorrect-equality        if (peggedOut == 0) revert MintZeroAmount(PEGGED_TOKEN);
        if (peggedOut < minPeggedOut) {
            revert MintInsufficientAmount(PEGGED_TOKEN, minPeggedOut, peggedOut);
        }

        // do the mint for collateral
        _mintPeggedToken(_wrappedValueOf(underlyingCollateralIn, oracle.rate), peggedOut, receiver);

        // take the fee
        uint256 wrappedFee = _wrappedValueOf(underlyingFee, oracle.rate);
        if (underlyingFee > 0) {
            IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer($.feeReceiver, wrappedFee);
        }

        // update our records
        $.underlyingCollateral = underlyingCollateral_ + underlyingCollateralIn - wrappedFee;
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

        uint256 underlyingFee$;
        uint256 underlyingDiscount$;
        uint256 underlyingCollateralOut$;
        (underlyingFee$, underlyingDiscount$, peggedIn, underlyingCollateralOut$) = _redeemPeggedAdjustments(
            $.redeemPeggedIncentiveConfig,
            peggedIn,
            underlyingCollateral_,
            oracle.price,
            peggedTokenBalance_,
            _underlyingValueOf(IERC20(WRAPPED_COLLATERAL_TOKEN).balanceOf(reservePool_), oracle.rate) * 1 ether
        );
        // slither-disable-next-line incorrect-equality
        if (peggedIn == 0) {
            revert ReturnZeroAmount(WRAPPED_COLLATERAL_TOKEN);
        }
        wrappedCollateralOut = _wrappedValueOf(underlyingCollateralOut$, oracle.rate) / 1 ether;
        // make sure it meets the minimum requirements
        // slither-disable-next-line incorrect-equality
        if (wrappedCollateralOut == 0) {
            revert ReturnZeroAmount(PEGGED_TOKEN);
        }
        underlyingCollateral_ -= (underlyingCollateralOut$ / 1 ether);

        // do the fee (feeReceiver) / discount (reservePool)
        if (underlyingFee$ > 0) {
            // send the fee
            IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer(
                $.feeReceiver,
                _wrappedValueOf(underlyingFee$, oracle.rate) / 1 ether
            );
            underlyingCollateral_ -= (underlyingFee$ / 1 ether);
        }
        if (underlyingDiscount$ > 0) {
            uint256 requestedBonus = _wrappedValueOf(underlyingDiscount$, oracle.rate) / 1 ether;
            // it's a discount, so collect the extra collateral, if available
            // wake-disable-next-line reentrancy // reservePool is trusted and reentrancy guard
            uint256 actualBonus = IReservePool($.reservePool).requestBonus(
                WRAPPED_COLLATERAL_TOKEN,
                address(this),
                requestedBonus
            );
            if (actualBonus != requestedBonus) revert RequestedBonusNotGiven(requestedBonus, actualBonus);
            underlyingCollateral_ += underlyingDiscount$ / 1 ether;
        }

        if (wrappedCollateralOut < minWrappedCollateralOut) {
            revert ReturnInsufficientAmount(WRAPPED_COLLATERAL_TOKEN, minWrappedCollateralOut, wrappedCollateralOut);
        }

        // redeem pegged tokens and send the remainder of the collateral
        _redeemPeggedToken(peggedIn, wrappedCollateralOut, receiver);

        // update our records
        $.peggedTokenBalance = peggedTokenBalance_ - peggedIn;
        $.underlyingCollateral = underlyingCollateral_;
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
        uint256 underlyingFee;
        uint256 underlyingDiscount;
        uint256 underlyingCollateralIn = _underlyingValueOf(wrappedCollateralIn, oracle.rate);
        uint256 underlyingCollateral_ = $.underlyingCollateral;
        address reservePool_ = $.reservePool;
        (underlyingFee, underlyingDiscount, leveragedOut) = _mintLeveragedAdjustments(
            $.mintLeveragedIncentiveConfig,
            underlyingCollateralIn,
            Balances(underlyingCollateral_, $.peggedTokenBalance, _leveragedTokenBalance()),
            oracle.price,
            _underlyingValueOf(IERC20(WRAPPED_COLLATERAL_TOKEN).balanceOf(reservePool_), oracle.rate)
        );
        underlyingCollateral_ += underlyingCollateralIn;
        // slither-disable-next-line incorrect-equality
        if (leveragedOut == 0) {
            revert ReturnZeroAmount(LEVERAGED_TOKEN);
        }
        if (underlyingDiscount > 0) {
            uint256 requestedBonus = _wrappedValueOf(underlyingDiscount, oracle.rate);
            // it's a discount, so collect the extra collateral, if available
            // wake-disable-next-line reentrancy // reservePool is trusted
            uint256 actualBonus = IReservePool(reservePool_).requestBonus(
                WRAPPED_COLLATERAL_TOKEN,
                address(this),
                requestedBonus
            );
            if (actualBonus != requestedBonus) revert RequestedBonusNotGiven(requestedBonus, actualBonus);
            // for minting leveraged, the discount collateral is held by the minter
            underlyingCollateral_ += underlyingDiscount;
        }
        // make sure it meets the minimum requirements
        if (leveragedOut < minLeveragedOut) {
            revert MintInsufficientAmount(LEVERAGED_TOKEN, minLeveragedOut, leveragedOut);
        }
        // mint the leveraged tokens and take wrappedCollateralIn
        _mintLeveragedToken(wrappedCollateralIn, leveragedOut, receiver);
        // take the fee
        if (underlyingFee > 0) {
            IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer(
                $.feeReceiver,
                uint256(_wrappedValueOf(underlyingFee, oracle.rate))
            );
            underlyingCollateral_ -= underlyingFee;
        }
        // update our records
        $.underlyingCollateral = underlyingCollateral_;
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

        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        uint256 underlyingCollateral_ = $.underlyingCollateral;

        uint256 underlyingFee;
        uint256 underlyingCollateralOut;
        (underlyingFee, leveragedIn, underlyingCollateralOut) = _redeemLeveragedAdjustments(
            $.redeemLeveragedIncentiveConfig,
            leveragedIn,
            underlyingCollateral_,
            oracle.price,
            peggedTokenBalance_,
            leveragedTokenBalance_
        );
        // slither-disable-next-line incorrect-equality
        if (leveragedIn == 0) {
            revert ReturnZeroAmount(WRAPPED_COLLATERAL_TOKEN);
        }
        wrappedCollateralOut = _wrappedValueOf(underlyingCollateralOut, oracle.rate);
        if (wrappedCollateralOut < minWrappedCollateralOut) {
            revert ReturnInsufficientAmount(WRAPPED_COLLATERAL_TOKEN, minWrappedCollateralOut, wrappedCollateralOut);
        }

        _redeemLeveragedToken(leveragedIn, wrappedCollateralOut, receiver);

        if (underlyingFee > 0) {
            // send the fee
            IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer($.feeReceiver, _wrappedValueOf(underlyingFee, oracle.rate));
        }

        // update our records
        $.underlyingCollateral = underlyingCollateral_ - underlyingCollateralOut - underlyingFee;
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
        // how much collateral to use
        wrappedCollateralIn = Token.allOf(_msgSender(), WRAPPED_COLLATERAL_TOKEN, wrappedCollateralIn);
        // TODO: should this be the mid price/rate?
        OracleData memory oracle = _fetchMid($.priceOracle);
        uint256 underlyingCollateralIn = _underlyingValueOf(wrappedCollateralIn, oracle.rate);

        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        uint256 underlyingCollateral_ = $.underlyingCollateral;
        // transfer and mint

        // TODO: should this use the actual price not the 1 ether price, i.e. mint them at the depegged amount
        peggedOut =
            (underlyingCollateralIn * oracle.price * 1 ether) /
            _peggedTokenPrice$(peggedTokenBalance_, underlyingCollateral_, oracle.price);
        _mintPeggedToken(wrappedCollateralIn, peggedOut, receiver);

        // update our records
        $.peggedTokenBalance = peggedTokenBalance_ + peggedOut;
        $.underlyingCollateral = underlyingCollateral_ + underlyingCollateralIn;
    }

    // @inheritdoc IMinter
    function freeRedeemPeggedToken(
        uint256 peggedIn,
        address receiver
    ) external override nonReentrant onlyRoles(ZERO_FEE_ROLE) returns (uint256 wrappedCollateralOut) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        uint256 underlyingCollateral_ = $.underlyingCollateral;
        peggedIn = Token.allOf(_msgSender(), PEGGED_TOKEN, peggedIn);
        peggedIn = _redeemable(PEGGED_TOKEN, peggedIn, peggedTokenBalance_);

        OracleData memory oracle = _fetchMax($.priceOracle);
        uint256 underlyingCollateralOut = (peggedIn *
            _peggedTokenPrice$(peggedTokenBalance_, underlyingCollateral_, oracle.price)) / (oracle.price * 1 ether);
        wrappedCollateralOut = _wrappedValueOf(underlyingCollateralOut, oracle.rate);

        // burn pegged tokens and send the collateral to the receiver
        _redeemPeggedToken(peggedIn, wrappedCollateralOut, receiver);

        // update our records
        $.peggedTokenBalance = peggedTokenBalance_ - peggedIn;
        $.underlyingCollateral = underlyingCollateral_ - underlyingCollateralOut;
    }

    /// @inheritdoc IMinter
    function freeSwapPeggedForLeveraged(
        uint256 peggedIn,
        address receiver
    ) external override nonReentrant onlyRoles(ZERO_FEE_ROLE) returns (uint256 leveragedOut) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;

        peggedIn = Token.allOf(_msgSender(), PEGGED_TOKEN, peggedIn);
        peggedIn = _redeemable(PEGGED_TOKEN, peggedIn, peggedTokenBalance_);

        OracleData memory oracle = _fetchMid($.priceOracle);

        leveragedOut = _leveragedTokensForPegged(
            peggedIn,
            _leveragedTokenBalance(),
            peggedTokenBalance_,
            $.underlyingCollateral,
            oracle.price
        );

        // burn pegged tokens and send the collateral
        _swapPeggedForLeveraged(peggedIn, leveragedOut, receiver);

        // update our records (collateral doesn't change)
        $.peggedTokenBalance = peggedTokenBalance_ - peggedIn;
    }

    // @inheritdoc IMinter
    function freeMintLeveragedToken(
        uint256 wrappedCollateralIn,
        address receiver
    ) external override onlyRoles(ZERO_FEE_ROLE) nonReentrant returns (uint256 leveragedOut) {
        MinterStorage storage $ = _getMinterStorage();
        // how much collateral to use
        wrappedCollateralIn = Token.allOf(_msgSender(), WRAPPED_COLLATERAL_TOKEN, wrappedCollateralIn);
        OracleData memory oracle = _fetchMid($.priceOracle);
        uint256 underlyingCollateralIn = _underlyingValueOf(wrappedCollateralIn, oracle.rate);
        // mint the tokens to the receiver
        leveragedOut = _leveragedTokensForCollateral(
            underlyingCollateralIn,
            _leveragedTokenBalance(),
            $.peggedTokenBalance,
            $.underlyingCollateral,
            oracle.price
        );

        _mintLeveragedToken(wrappedCollateralIn, leveragedOut, receiver);

        // update our records
        $.underlyingCollateral += underlyingCollateralIn;
    }

    // @inheritdoc IMinter
    function freeRedeemLeveragedToken(
        uint256 leveragedIn,
        address receiver
    ) external override onlyRoles(ZERO_FEE_ROLE) returns (uint256 collateralOut) {
        MinterStorage storage $ = _getMinterStorage();
        // how much collateral to use
        leveragedIn = Token.allOf(_msgSender(), LEVERAGED_TOKEN, leveragedIn);

        uint256 leveragedTokenBalance_ = _leveragedTokenBalance();
        leveragedIn = _redeemable(LEVERAGED_TOKEN, leveragedIn, leveragedTokenBalance_);

        OracleData memory oracle = _fetchMin($.priceOracle);

        // TODO: add check for depegged here as we'll remove it from below
        uint256 underlyingCollateralOut = _underlyingCollateralForLeveragedTokens(
            leveragedIn,
            leveragedTokenBalance_,
            $.peggedTokenBalance,
            $.underlyingCollateral,
            oracle.price
        );
        collateralOut = _wrappedValueOf(underlyingCollateralOut, oracle.rate);

        _redeemLeveragedToken(leveragedIn, collateralOut, receiver);

        // update our records
        $.underlyingCollateral -= underlyingCollateralOut;
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

    // Price Oracle
    // ------------

    function _underlyingValueOf(uint256 wrapped, uint256 rate) internal pure returns (uint256 value) {
        value = (wrapped * rate) / 1 ether;
    }

    function _wrappedValueOf(uint256 underlying, uint256 rate) internal pure returns (uint256 value) {
        value = (underlying * 1 ether) / rate;
    }

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

    /// @notice Perform the transfers and event emissions for redeeming pegged tokens
    /// Fees and discounts transfers and event emissions are not handled here.
    /// @dev no checks for zeros values are performed.
    /// @param peggedIn The amount of pegged tokens to be taken from the sender.
    /// @param wrappedCollateralOut The amount of collateral to be transferred to the `receiver`.
    /// @param receiver The address of the receiver.

    function _redeemPeggedToken(uint256 peggedIn, uint256 wrappedCollateralOut, address receiver) private {
        // tell the world
        emit RedeemPeggedToken(_msgSender(), receiver, peggedIn, wrappedCollateralOut);
        // burn the tokens from the sender
        // if (burnInterfaceId == type(IBurnable).interfaceId) {
        // get the tokens here first
        IERC20(PEGGED_TOKEN).safeTransferFrom(_msgSender(), address(this), peggedIn);
        IBurnable(PEGGED_TOKEN).burn(peggedIn);
        // } else if (burnInterfaceId == type(IBurnable2Arg).interfaceId) {
        //     IBurnable2Arg(PEGGED_TOKEN).burn(_msgSender(), peggedIn);
        // } else if (burnInterfaceId == type(IBurnableFrom).interfaceId) {
        //     IBurnableFrom(PEGGED_TOKEN).burnFrom(_msgSender(), peggedIn);
        // } else {
        //     revert UnsupportedBurnInterface(pegged_.burnInterfaceId);
        // }
        // return the collateral
        IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer(receiver, wrappedCollateralOut);
    }

    /// @notice Perform the transfers and event emissions for redeeming pegged tokens for leveraged tokens
    /// Fees and discounts transfers and event emissions are not handled here.
    /// @dev no checks for zeros values are performed.
    /// @param peggedIn The amount of pegged tokens to be taken from the sender.
    /// @param leveragedOut The amount of leveraged to be transferred to the `receiver`.
    /// @param receiver The address of the receiver.

    function _swapPeggedForLeveraged(uint256 peggedIn, uint256 leveragedOut, address receiver) private {
        // tell the world
        emit SwapPeggedForLeveraged(_msgSender(), receiver, peggedIn, leveragedOut);
        // burn the tokens from the sender - get them first then burn them
        IERC20(PEGGED_TOKEN).safeTransferFrom(_msgSender(), address(this), peggedIn);
        // wake-disable-next-line reentrancy // all callers to this function have nonReentrant guard
        IBurnable(PEGGED_TOKEN).burn(peggedIn);
        // mint the tokens to the receiver
        // wake-disable-next-line reentrancy
        IMintable(LEVERAGED_TOKEN).mint(receiver, leveragedOut);
    }

    /// @notice Perform the transfers and event emissions for minting leveraged tokens
    /// Fees and discounts transfers and event emissions are not handled here.
    /// @dev no checks for zeros values are performed.
    /// @param wrappedCollateralIn The amount of collateral to be taken from the sender.
    /// @param leveragedOut The amount of leveraged to be transferred to the `receiver`.
    /// @param receiver The address of the receiver.

    function _mintLeveragedToken(uint256 wrappedCollateralIn, uint256 leveragedOut, address receiver) private {
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

    /// @notice Perform a dry run of a mint pegged to calculate the various transfers of tokens.
    /// Fees, discounts and disallows relating to the different incentiveRatios values are calculated as sum, weighted
    /// in proportion, in collateral space, to the amount spent within each collateral ratio boundary.
    /// It essentially performs a definite integral of the fee function.
    /// @param config_ The collateral ratio boundaries and the incentive ratios within each boundary,
    /// for minting pegged tokens.
    /// @return fee The pro-rated fee.
    /// @param underlyingCollateralIn The proposed amount of collateral being posted in exchange for pegged tokens.
    /// @param underlyingCollateral_ The amount of collateral held. This is used to calculate collateral ratios.
    /// @param price The value of a collateral token in terms of the pegged token.
    /// @param peggedTokenBalance_ The amount of pegged tokens issued. This is used to calculate collateral ratios.
    /// @return peggedMinted the amount of pegged tokens minted (i.e after fees and discounts)
    /// @return maxCollateralIn the amount of collateral that is allowed, according to the config

    function _mintPeggedAdjustments(
        ConfigIncentiveLib.ActionIncentive memory config_,
        uint256 underlyingCollateralIn,
        uint256 underlyingCollateral_,
        uint256 price,
        uint256 peggedTokenBalance_
    ) private pure returns (uint256 fee, uint256 peggedMinted, uint256 maxCollateralIn) {
        // we cannot calculate collateral ratio when there are no pegged tokens as it's infinite i.e. (/0)
        if (peggedTokenBalance_ == 0) revert ActionPaused();

        // find the band and it's lower bound where the current collateral ratio is
        // (note we treat the disallow band as any other here, except that it is the terminal band)
        uint band = _findBand(config_, underlyingCollateral_, price, peggedTokenBalance_, false); // solhint-disable-line explicit-types
        fee = 0;
        peggedMinted = 0;
        maxCollateralIn = 0;
        // simulate minting until we run out of collateral, adding the fee & collateral as we go
        while (true) {
            uint256 bandFeeRatio = uint256(ConfigIncentiveLib._incentiveRatio(config_, band)); // no discounts for this action
            if (bandFeeRatio == 1 ether) {
                // fee ratio of 100% means the action is disallowed, and in the lowest band
                break;
            }
            uint256 collateralInBand; // includes the fee
            uint256 bandLowerBound = ConfigIncentiveLib._collateralRatioLowerBounds(config_, band);
            if (bandLowerBound < 1 ether) {
                // This band is the depegged band - exactly one (or a disallow) is guaranteed to be there when the config is added
                // if we check for _depegged then the phi calc below results in an underflow as band lower bound is 0
                // all the requested collateral can be consumed
                collateralInBand = underlyingCollateralIn;
            } else {
                uint256 phi = (bandLowerBound * (1 ether - bandFeeRatio)) +
                    (bandFeeRatio * 1 ether) -
                    (1 ether * 1 ether);
                collateralInBand =
                    ((underlyingCollateral_ * 1 ether * 1 ether) / phi) -
                    (((bandLowerBound * peggedTokenBalance_) * 1 ether * 1 ether) / (price * phi));

                collateralInBand = Math.min(underlyingCollateralIn, collateralInBand);
            }
            uint256 bandFee = (collateralInBand * bandFeeRatio) / 1 ether;
            maxCollateralIn += collateralInBand;
            fee += bandFee;
            underlyingCollateralIn -= collateralInBand;
            uint256 collateralAddedInBand = collateralInBand - bandFee;
            uint256 peggedMintedInBand = (collateralAddedInBand * price * 1 ether) /
                _peggedTokenPrice$(peggedTokenBalance_, underlyingCollateral_, price);

            peggedMinted += peggedMintedInBand;

            // slither-disable-next-line incorrect-equality
            if (underlyingCollateralIn == 0 || band == 0) {
                // we have run out of collateral for the simulation
                // or we are in the lowest band, so no more, so exit
                break;
            }
            // still some collateral left and we're allowed to mint, so simulate
            underlyingCollateral_ += collateralAddedInBand;
            peggedTokenBalance_ += peggedMintedInBand;
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
    /// @param underlyingCollateral_ The amount of collateral held.
    /// @param price The value in pegged of each collateral token.
    /// @param peggedTokenBalance_ The balance of pegged tokens minted.
    /// @param reserveWrappedCapacity$ The current balance of the reserve pool (scaled to 1e36).
    /// @return fee$ the fee charged in collateral tokens.
    /// @return discount$ the discount given in collateral tokens.
    /// @return peggedRedeemed the collateral returnable from 'peggedIn' pegged tokens. This has the fee deducted.
    /// @return collateralReturned$ the collateral returned to the receiver in exchange for the 'peggedRedeemed'

    function _redeemPeggedAdjustments(
        ConfigIncentiveLib.ActionIncentive memory config_,
        uint256 peggedIn,
        uint256 underlyingCollateral_,
        uint256 price,
        uint256 peggedTokenBalance_,
        uint256 reserveWrappedCapacity$
    ) private pure returns (uint256 fee$, uint256 discount$, uint256 peggedRedeemed, uint256 collateralReturned$) {
        // we cannot calculate collateral ratio when there are no pegged tokens as it's infinite i.e. (/0)
        if (peggedTokenBalance_ == 0) revert ActionPaused();

        uint band = _findBand(config_, underlyingCollateral_, price, peggedTokenBalance_, true); // solhint-disable-line explicit-types
        // simulate redeeming until we run out of pegged tokens, adding the fee & bonus as we go
        // We do this band at a time, pro-rating the resulting fee according to how much collateral was needed in
        // each band entered. We use collateral to pro-rate, rather than collateral ratio which would be simpler, because
        // we multiply the resulting ratios by the collateral for the final fee
        fee$ = 0;
        discount$ = 0;
        peggedRedeemed = 0;
        collateralReturned$ = 0;
        while (true) {
            uint256 collateralInBand$;
            {
                uint256 peggedInBand;
                if (band == ConfigIncentiveLib._collateralRatioBandCount(config_) - 1) {
                    // the last band goes on forever and there must be more than 1 band
                    peggedInBand = peggedIn;
                    collateralInBand$ = (peggedInBand * 1 ether * 1 ether) / price;
                } else {
                    uint256 bandUpperBound = ConfigIncentiveLib._collateralRatioUpperBounds(config_, band);
                    if (bandUpperBound < 1 ether) {
                        // given the price of the pegged is a proportionate share of the collateral and leveraged tokens are worthless
                        // we redeem all of it (at the depegged rate) in this band, at the rate for the band
                        peggedInBand = peggedIn;
                        // this applies to the collateral too
                        collateralInBand$ = (peggedIn * underlyingCollateral_ * 1 ether) / peggedTokenBalance_;
                    } else {
                        peggedInBand = _redeemPeggedForCollateralRatio(
                            bandUpperBound,
                            underlyingCollateral_,
                            price,
                            peggedTokenBalance_
                        );
                        // can't have more pegged in the band that there is peggedIn left
                        peggedInBand = Math.min(peggedIn, peggedInBand);
                        collateralInBand$ = (peggedInBand * 1 ether * 1 ether) / price;
                    }
                }
                peggedIn -= peggedInBand;
                peggedRedeemed += peggedInBand;
                peggedTokenBalance_ -= peggedInBand;
                collateralReturned$ += collateralInBand$;
            }
            {
                // we now switch to calculations in collateral
                int256 bandFeeDiscount$ = (int256(collateralInBand$) *
                    ConfigIncentiveLib._incentiveRatio(config_, band)) / 1 ether;

                // tally the weighted fee ratios
                if (bandFeeDiscount$ < 0) {
                    // tally the discounts
                    uint256 bandDiscount$;
                    if (uint256(-bandFeeDiscount$) <= reserveWrappedCapacity$) {
                        bandDiscount$ = uint256(-bandFeeDiscount$);
                        reserveWrappedCapacity$ -= uint256(-bandFeeDiscount$);
                    } else {
                        // although we don't get the full amount of collateral from the reserve pool, we are happy
                        // because that extra collateral isn't used in the collateral balance it doesn't affect the
                        // simulation, only the collateral returned
                        bandDiscount$ = reserveWrappedCapacity$;
                        reserveWrappedCapacity$ = 0;
                    }
                    discount$ += bandDiscount$;
                    collateralReturned$ += bandDiscount$;
                } else {
                    // tally the fees
                    fee$ += uint256(bandFeeDiscount$);
                    collateralReturned$ -= uint256(bandFeeDiscount$);
                }
            }
            if (peggedIn == 0) {
                // no pegged tokens left to simulate redeeming them
                break;
            }
            // still some pegged tokens left and we're allowed to redeem
            underlyingCollateral_ -= (collateralInBand$ / 1 ether);
            band++;
        }
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
    /// @param underlyingCollateralIn The given amount of collateral tokens, assumed to be > 0.
    /// @param balanceOf The amount of collateral, pegged and leveraged tokens managed.
    /// @param price The value in pegged of each collateral token.
    /// @param reservePoolBalance_ The current balance of the reserve pool.
    /// @return fee the fee charged in collateral tokens.
    /// @return discount the discount given in collateral tokens.
    /// @return leveragedMinted The amount of leveraged tokens minted.

    function _mintLeveragedAdjustments(
        ConfigIncentiveLib.ActionIncentive memory config_,
        uint256 underlyingCollateralIn,
        Balances memory balanceOf,
        uint256 price,
        uint256 reservePoolBalance_
    ) private pure returns (uint256 fee, uint256 discount, uint256 leveragedMinted) {
        // we cannot calculate our collateral ratio scale when there are no pegged tokens as it's infinite i.e. (/0)
        // slither-disable-next-line incorrect-equality
        if (balanceOf.pegged == 0) revert ActionPaused();
        fee = 0;
        discount = 0;
        leveragedMinted = 0;
        {
            (uint256 collateralValue$, uint256 peggedValue$) = _tokenValues$(
                balanceOf.pegged,
                balanceOf.collateral,
                price
            );
            // leveraged tokens have no value (we haven't quite depegged, though)
            if (collateralValue$ <= peggedValue$) return (fee, discount, leveragedMinted);
        }
        // simulate minting leveaged tokens from current collateral ratio upwards,
        // applying the incentive at the correct ratio as we go.
        // We do this band at a time, pro-rating the resulting fee according to how much collateral was needed in
        // each band entered. We use collateral to pro-rate, rather than collateral ratio which would be simpler, because
        // we multiply the resulting ratios by the collateral for the final fee
        uint band = _findBand(config_, balanceOf.collateral, price, balanceOf.pegged, true); // solhint-disable-line explicit-types

        // simulate minting until we run out of collateral, adding the fee & bonus as we go
        while (true) {
            int256 bandIncentiveRatio = ConfigIncentiveLib._incentiveRatio(config_, band);
            uint256 collateralInBand;
            if (band == ConfigIncentiveLib._collateralRatioBandCount(config_) - 1) {
                // the last band has no upper bound and there are at least 2 bands
                collateralInBand = underlyingCollateralIn;
            } else {
                // the collateral needed to be deposited to reach the upper bound of the band taking fees into account
                // The fee is deducted because it goes to the fee receiver
                // The discount is added because it ends up in the collateral balance and more leveraged tokens go to the receiver
                // note that 1 - bandIncentiveRatio must always be positive, which it is as:
                //   * fees < 1 ether. if is was = 1 ether then this would be a disallow band.
                //   * discount are removed
                collateralInBand =
                    ((ConfigIncentiveLib._collateralRatioUpperBounds(config_, band) *
                        balanceOf.pegged -
                        balanceOf.collateral *
                        price) * 1 ether) /
                    (price * (1 ether - uint256(SignedMath.max(0, bandIncentiveRatio))));
                // can't have more collateral in the band that there is collateralIn left
                collateralInBand = Math.min(underlyingCollateralIn, collateralInBand);
            }
            underlyingCollateralIn -= collateralInBand; // includes the fee at this point
            {
                int256 bandFeeDiscount = (int256(collateralInBand) * bandIncentiveRatio) / 1 ether;
                if (bandFeeDiscount >= 0) {
                    // tally the weighted fee ratios
                    fee += uint256(bandFeeDiscount);
                    collateralInBand -= uint256(bandFeeDiscount);
                } else {
                    // we can't net out fee and reserve pool access, because minting leveraged dollar-by-dollar must give the
                    // same result as minting leveraged for the full amount in terms of fees, etc. I.e it needs to be the definite integral
                    // tally the discounts
                    if (uint256(-bandFeeDiscount) <= reservePoolBalance_) {
                        discount += uint256(-bandFeeDiscount);
                        collateralInBand += uint256(-bandFeeDiscount);
                        reservePoolBalance_ -= uint256(-bandFeeDiscount); // it's negative, btw
                    } else {
                        discount += reservePoolBalance_;
                        collateralInBand += reservePoolBalance_;
                        reservePoolBalance_ = 0;
                    }
                }
            }
            {
                uint256 leveragedInBand = _leveragedTokensForCollateral(
                    collateralInBand, // the fee is already subtracted and discount already added
                    balanceOf.leveraged,
                    balanceOf.pegged,
                    balanceOf.collateral,
                    price
                );
                leveragedMinted += leveragedInBand;
                balanceOf.leveraged += leveragedInBand;
                balanceOf.collateral += collateralInBand;
            }

            // slither-disable-next-line incorrect-equality
            if (underlyingCollateralIn == 0) {
                // we have run out of collateral for the simulation
                // collateralTokenBalance_ += collateralInBand - bandFee + extraCollateralInBand;
                break;
            }
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
    /// @param underlyingCollateral_ The amount of collateral held.
    /// @param price The value in pegged of each collateral token.
    /// @param peggedTokenBalance_ The balance of pegged tokens managed.
    /// @param leveragedTokenBalance_ The current balance of the reserve pool.
    /// @return fee the fee charged in collateral tokens.
    /// @return leveragedRedeemed the leveraged tokens to be burned.
    /// @return collateralOut the collateral returned to the receiver in exchange for the `leveragedRedeemed`

    function _redeemLeveragedAdjustments(
        ConfigIncentiveLib.ActionIncentive memory config_,
        uint256 leveragedIn,
        uint256 underlyingCollateral_,
        uint256 price,
        uint256 peggedTokenBalance_,
        uint256 leveragedTokenBalance_
    ) private pure returns (uint256 fee, uint256 leveragedRedeemed, uint256 collateralOut) {
        // we cannot calculate collateral ratio when there are no pegged tokens as it's infinite i.e. (/0)
        if (peggedTokenBalance_ == 0 || _isDepegged(underlyingCollateral_, price, peggedTokenBalance_))
            revert ActionPaused();
        // we can't meaningfully do anything with leveraged tokens as their value is zero
        // and we an do this once, here, and not in the loop below, because redeeming leveraged tokens, will never cause a re-peg.

        fee = 0;
        leveragedRedeemed = 0;
        collateralOut = 0;
        {
            (uint256 collateralValue$, uint256 peggedValue$) = _tokenValues$(
                peggedTokenBalance_,
                underlyingCollateral_,
                price
            );
            // leveraged tokens have no value (we haven't quite depegged, though)
            if (collateralValue$ <= peggedValue$) return (fee, leveragedRedeemed, collateralOut);
        }

        uint256 underlyingCollateralIn = _underlyingCollateralForLeveragedTokens(
            leveragedIn,
            leveragedTokenBalance_,
            peggedTokenBalance_,
            underlyingCollateral_,
            price
        );
        // find the band and it's lower bound where the current collateral ratio is
        // (note we treat the disallow band as any other here, except that it is the terminal band)
        uint band = _findBand(config_, underlyingCollateral_, price, peggedTokenBalance_, false); // solhint-disable-line explicit-types
        // simulate redeeming until we run out of leveraged tokens, adding the fee as we go

        uint256 collateralTokenBalance_ = underlyingCollateral_;
        while (true) {
            int256 bandFeeRatio = ConfigIncentiveLib._incentiveRatio(config_, band); // no discounts for this action
            if (bandFeeRatio == 1 ether) {
                // fee ratio of 100% means the action is disallowed, and in the lowest band
                break;
            }
            uint256 bandLowerBound = ConfigIncentiveLib._collateralRatioLowerBounds(config_, band);
            // slither-disable-next-line divide-before-multiply
            uint256 collateralInBand = (collateralTokenBalance_ * price - bandLowerBound * peggedTokenBalance_) / price;
            collateralInBand = Math.min(underlyingCollateralIn, collateralInBand);
            // slither-disable-next-line divide-before-multiply
            uint256 bandFee = (collateralInBand * uint256(bandFeeRatio)) / 1 ether;
            collateralOut += collateralInBand - bandFee;
            fee += bandFee;
            underlyingCollateralIn -= collateralInBand;
            // slither-disable-next-line incorrect-equality
            if (underlyingCollateralIn == 0 || band == 0) {
                // we have run out of collateral
                // or we are now in the lowest band, so exit
                break;
            }
            // still some collateral left and we're allowed to mint or redeem, so simulate
            collateralTokenBalance_ += collateralInBand;
            band--;
        }
        leveragedRedeemed = _leveragedTokensForCollateral(
            collateralOut + fee,
            leveragedTokenBalance_,
            peggedTokenBalance_,
            underlyingCollateral_,
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
                if (collateralRatio_ < bandUpperBound) break;
            } else {
                if (collateralRatio_ <= bandUpperBound) break;
            }
        }
    }

    // other calculations
    // ------------------

    // the price of a leveraged token in terms of the pegged token's underlying
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

    /// @dev pegged value must not be greater than collateral value, i.e. it's depegged

    function _leveragedTokensForCollateral(
        uint256 underlyingCollateralIn,
        uint256 leveragedTokenBalance_,
        uint256 peggedTokenBalance_,
        uint256 underlyingCollateral_,
        uint256 price
    ) private pure returns (uint256 leveragedTokens) {
        (uint256 collateralValue$, uint256 peggedValue$) = _tokenValues$(
            peggedTokenBalance_,
            underlyingCollateral_,
            price
        );
        // TODO: check what happens when the leverage price tracks the collateral rather than pegged
        uint256 leveragedPrice_ = (leveragedTokenBalance_ > 0)
            ? (collateralValue$ - peggedValue$) / leveragedTokenBalance_
            : 1 ether; // TODO: this initial value is set in two places
        leveragedTokens =
            ((underlyingCollateral_ + underlyingCollateralIn) *
                price -
                peggedValue$ -
                leveragedTokenBalance_ *
                leveragedPrice_) /
            leveragedPrice_;
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
            leveragedTokens = peggedIn; // TODO: the third place initial price of 1 ether is assumed
        }
    }

    /// @notice Returns the amount of collateral equivalent to the given amount of leveraged tokens.
    /// @param forLeveraged The given amount of leveraged tokens.
    /// @param leveragedTokenBalance_ The total supply of leveraged tokens, required to be > 0.
    /// @param peggedTokenBalance_ The amount of pegged tokens managed.
    /// @param collateralTokenBalance_ The amount of collateral managed.
    /// @param collateralPrice The price of collateral in terms of pegged token underlying.
    /// @return collateral The amount of collateral `forLeveraged` leveraged tokens are worth.

    // TODO: whereever there is a collateral balance and price passed, pass the product instead?
    function _underlyingCollateralForLeveragedTokens(
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
        // TODO: remove the slither disable
        // slither-disable-next-line unused-return
        (uint256 minPrice, uint256 maxPrice, uint256 minRate, uint256 maxRate) = IWrappedPriceOracle(priceOracle_)
            .latestAnswer();
        return OracleData((minPrice + maxPrice) / 2, (minRate + maxRate) / 2); // TODO: this should be rounded
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
