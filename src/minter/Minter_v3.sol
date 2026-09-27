// SPDX-License-Identifier: MIT
// coding standards by https://www.rareskills.io/post/solidity-style-guide
// and https://docs.soliditylang.org/en/latest/style-guide.html
pragma solidity 0.8.30;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Token} from "@bao/Token.sol";
import {TokenHolder_v2, ITokenHolder} from "@bao/TokenHolder_v2.sol";

import {HarborOwnableRoles} from "@bao/HarborOwnableRoles.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

// different ERC20 mint/burn interfaces
import {IMintable} from "@bao/interfaces/IMintable.sol";
import {IBurnableFrom} from "@bao/interfaces/IBurnableFrom.sol";

import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {IReservePool} from "@harbor/interfaces/IReservePool.sol";

import {ConfigIncentiveLib} from "@harbor/minter/library/ConfigIncentiveLib.sol";
import {Config_v2} from "@harbor/minter/library/Config_v2.sol";
import {MinterAdjustments_v1} from "@harbor/minter/library/MinterAdjustments_v1.sol";
import {MinterValuationLib} from "@harbor/minter/library/MinterValuationLib.sol";
import {RebalanceSizing_v1} from "@harbor/minter/library/RebalanceSizing_v1.sol";

/// @title Harbor Minter
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
    HarborOwnableRoles,
    TokenHolder_v2,
    IMinter_v3
{
    using SafeERC20 for IERC20;

    ///////////////
    // Constants //
    ///////////////

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

    /// @inheritdoc IMinter_v3
    /// @dev `K = 20` puts the floor at `K/(K-1)` = 1.0526, which is where the count cap of `Minter_v2` was
    /// measured to let go: the same number, seen from the other side. That cap bounded the COUNT a conversion
    /// issued and left the retail route unbounded; this one refuses, on every route, so no token is ever sold
    /// carrying more than `K`.
    uint256 public constant override MAX_LEVERAGE_RATIO = 20 ether;

    /// @inheritdoc IMinter_v3
    /// @dev Derived from the cap by integer division, which floors it as `Math.mulDiv` would - the one place
    /// the two figures are related, so they cannot disagree.
    uint256 public constant override MINIMUM_COLLATERAL_RATIO =
        (MAX_LEVERAGE_RATIO * 1 ether) / (MAX_LEVERAGE_RATIO - 1 ether);

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

    /// @param deployerOwner_ The initial owner, used by the deploy script to configure the contract.
    /// @param pendingOwner_ The address the deployer hands ownership to, within an hour of initialisation.
    function initialize(address deployerOwner_, address pendingOwner_) external initializer {
        // initialise all the state variables
        _initializeOwner(deployerOwner_, pendingOwner_);
        __Context_init();
        MinterStorage storage $ = _getMinterStorage();
        $.peggedTokenBalance = 0;
        $.underlyingCollateral = 0;

        // initialise the config to something that works
        Config_v2.defaultIncentive($.incentiveConfig);
    }
    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// https://forum.openzeppelin.com/t/what-does-disableinitializers-function-mean/28730
    /// @custom:oz-upgrades-unsafe-allow constructor
    // slither-disable-next-line missing-zero-check // sanityCheckERC20Token is called
    constructor(address collateralToken_, address peggedToken_, address leveragedToken_) {
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
    }

    /// @notice The check that allow this contract to be upgraded:
    /// In UUPS proxies the implementation is responsible for upgrading itself
    /// only owners can upgrade this contract.
    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    /// @notice Returns true if a given interface is supported.
    /// @dev See {IERC165-supportsInterface}.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(IMinter_v3).interfaceId ||
            interfaceId == type(ITokenHolder).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ///////////////////////////
    // Public View Functions //
    ///////////////////////////

    /// @inheritdoc IMinter_v3
    function priceOracle() external view override returns (address) {
        MinterStorage storage $ = _getMinterStorage();
        return $.priceOracle;
    }

    /// @inheritdoc IMinter_v3
    function feeReceiver() external view override returns (address) {
        MinterStorage storage $ = _getMinterStorage();
        return $.feeReceiver;
    }

    /// @inheritdoc IMinter_v3
    function reservePool() external view returns (address) {
        MinterStorage storage $ = _getMinterStorage();
        return $.reservePool;
    }

    /// @inheritdoc IMinter_v3
    function peggedTokenBalance() external view override returns (uint256) {
        MinterStorage storage $ = _getMinterStorage();
        return $.peggedTokenBalance;
    }

    /// @inheritdoc IMinter_v3
    function leveragedTokenBalance() external view override returns (uint256) {
        return _leveragedTokenBalance();
    }

    /// @inheritdoc IMinter_v3
    function collateralTokenBalance() external view override returns (uint256) {
        MinterStorage storage $ = _getMinterStorage();
        return _effectiveBacking($);
    }

    /// @inheritdoc IMinter_v3
    function config() external view returns (Config memory config_) {
        MinterStorage storage $ = _getMinterStorage();
        config_ = Config_v2.copyIncentivesBack($.incentiveConfig);
    }

    /// @inheritdoc IMinter_v3
    function collateralRatio() external view override returns (uint256 collateralRatio_) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 price = _fetchMidPrice($.priceOracle);
        collateralRatio_ = MinterValuationLib.collateralRatio(_effectiveBacking($), price, $.peggedTokenBalance);
    }

    /// @inheritdoc IMinter_v3
    function leverageRatio() external view override returns (uint256 ratio) {
        MinterStorage storage $ = _getMinterStorage();

        uint256 price = _fetchMidPrice($.priceOracle);
        ratio = MinterValuationLib.leverageRatio($.peggedTokenBalance, _effectiveBacking($), price);
    }

    /// @inheritdoc IMinter_v3
    function leveragedIssuable() external view override returns (bool issuable) {
        MinterStorage storage $ = _getMinterStorage();
        (issuable, ) = _leveragedIssuable(_effectiveBacking($), _fetchMidPrice($.priceOracle), $.peggedTokenBalance);
    }

    /// @notice Whether leverage may be sold against a pre-trade state, and the collateral ratio it was judged at.
    /// @dev THE RULE, in one place. A leveraged token is a claim on the residual, whose sensitivity to the
    /// collateral price is `CR/(CR-1)`, so a cap `K` on the leverage sold is a floor `K/(K-1)` on the ratio at
    /// which any is sold. Judged against the state the caller priced its amounts from - its own snapshot, never
    /// storage the caller may have part-updated - so the refusal and the pricing see the same market, and the
    /// ratio is computed exactly as `collateralRatio()` computes it.
    ///
    /// NOT APPLIED TO THE FIRST LEVERAGED TOKEN. A market is founded by minting pegged, which puts the ratio at
    /// exactly one, and then leveraged; judged against that state the founding mint is always refused. On an
    /// empty supply there is nothing the cap protects - no existing price to diverge, no existing holder to
    /// dilute - and the deposit creates the residual it buys. Every later issuance is judged against a state
    /// that includes it.
    function _leveragedIssuable(
        uint256 backing,
        uint256 price,
        uint256 peggedTokenBalance_
    ) private view returns (bool issuable, uint256 collateralRatio_) {
        collateralRatio_ = MinterValuationLib.collateralRatio(backing, price, peggedTokenBalance_);
        issuable = _leveragedTokenBalance() == 0 || collateralRatio_ >= MINIMUM_COLLATERAL_RATIO;
    }

    /// @dev The refusal, at every point leveraged is issued - both retail mints and the conversion - before the
    /// amounts are computed, so a zero-price market reports the rule's own reason rather than a rounding one.
    /// Reverts with the ratio it judged and the floor it wanted, so a caller turned away knows by how much.
    function _requireLeveragedIssuable(uint256 backing, uint256 price, uint256 peggedTokenBalance_) private view {
        (bool issuable, uint256 collateralRatio_) = _leveragedIssuable(backing, price, peggedTokenBalance_);
        if (!issuable) {
            revert LeverageAboveCap(collateralRatio_, MINIMUM_COLLATERAL_RATIO);
        }
    }

    /// @inheritdoc IMinter_v3
    function leveragedTokenPrice() external view override returns (uint256 nav) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 price = _fetchMidPrice($.priceOracle);
        (uint256 collateralValueE36, uint256 peggedValueE36) = MinterValuationLib.tokenValuesE36(
            $.peggedTokenBalance,
            _effectiveBacking($),
            price
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

    /// @inheritdoc IMinter_v3
    function peggedTokenPrice() external view override returns (uint256 nav) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        if (peggedTokenBalance_ == 0) {
            nav = 1 ether;
        } else {
            uint256 price = _fetchMidPrice($.priceOracle);
            // slither-disable-next-line unused-return only the pegged value is needed here
            (, uint256 peggedValueE36) = MinterValuationLib.tokenValuesE36(
                peggedTokenBalance_,
                _effectiveBacking($),
                price
            );
            nav = peggedValueE36 / peggedTokenBalance_;
        }
    }

    /// @inheritdoc IMinter_v3
    function redeemPeggedForCollateralRatio(
        uint256 targetCollateralRatio,
        uint256 maxCollateralPegged,
        uint256 maxLeveragedPegged,
        uint256 holdingCollateral,
        uint256 holdingLeveraged
    ) external view returns (uint256 peggedForCollateral, uint256 peggedForLeveraged) {
        // Resolve this contract's own state and oracle here, and leave the arithmetic to the library: it holds no
        // storage of its own, so there is nothing to keep in step between the two.
        //
        // Priced at the MIDDLE of the band, the price `collateralRatio()` and `leveragedIssuable()` report at: the
        // target is a ratio as those measure it, and a trade sized at any other price lands somewhere else by that
        // measure. The redemption itself pays out at the band's high edge, which leaves more collateral behind than
        // the middle would, so the trade can only land further past the target, never short of it.
        MinterStorage storage $ = _getMinterStorage();
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        uint256 price = _fetchMidPrice($.priceOracle);
        uint256 collateralTokenBalance_ = _effectiveBacking($);
        (peggedForCollateral, peggedForLeveraged) = RebalanceSizing_v1.split(
            targetCollateralRatio,
            MinterValuationLib.collateralRatio(collateralTokenBalance_, price, peggedTokenBalance_),
            maxCollateralPegged,
            maxLeveragedPegged,
            holdingCollateral,
            holdingLeveraged,
            peggedTokenBalance_,
            collateralTokenBalance_,
            price
        );
    }

    // incentive ratios
    // ----------------

    // solhint-disable-next-line explicit-types
    function _lookupIncentiveRatio(uint action) internal view returns (int256 incentiveRatio) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 price = _fetchMidPrice($.priceOracle);
        uint256 collateralTokenBalance_ = _effectiveBacking($);
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;

        ConfigIncentiveLib.ActionIncentive memory config_ = $.incentiveConfig[action];
        // solhint-disable-next-line explicit-types
        uint band = MinterValuationLib.findBand(config_, collateralTokenBalance_, price, peggedTokenBalance_, false);
        incentiveRatio = ConfigIncentiveLib._incentiveRatio(config_, band);
    }

    /// @inheritdoc IMinter_v3
    function mintPeggedTokenIncentiveRatio() external view override returns (int256 incentiveRatio) {
        incentiveRatio = _lookupIncentiveRatio(Config_v2.MINT_PEGGED);
    }

    /// @inheritdoc IMinter_v3
    function redeemPeggedTokenIncentiveRatio() external view override returns (int256 incentiveRatio) {
        incentiveRatio = _lookupIncentiveRatio(Config_v2.REDEEM_PEGGED);
    }

    /// @inheritdoc IMinter_v3
    function mintLeveragedTokenIncentiveRatio() external view override returns (int256 incentiveRatio) {
        incentiveRatio = _lookupIncentiveRatio(Config_v2.MINT_LEVERAGED);
    }

    /// @inheritdoc IMinter_v3
    function redeemLeveragedTokenIncentiveRatio() external view override returns (int256 incentiveRatio) {
        incentiveRatio = _lookupIncentiveRatio(Config_v2.REDEEM_LEVERAGED);
    }

    // dry run functions
    // here we simulate a mint or redeem taking into account who is making the call for balance.
    // we don't take into account the allowance the Minter contract has for the msgSender because
    // most user interfaces, where the dry run functions are expected to be called will leave changing
    // allowance until the actual mint or redeem function is called.
    // in other words we don't require all conditions to be met for the dry run to succeed if those conditions
    // require gas to be spent on a transaction.

    /// @inheritdoc IMinter_v3
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

    /// @notice Dry run of a capped mint: the outcome when the fee, as a ratio of the collateral USED,
    /// is held within maxFeeRatio. With an offer larger than the market can absorb at that price this
    /// reports the capacity to mint at it — the collateral taken is bounded by the price, not by the
    /// size of the offer.
    /// @param wrappedCollateralIn The proposed amount of wrapped collateral.
    /// @param maxFeeRatio The maximum fee as a ratio of the collateral used (18 decimals). e.g. 0.05 ether = 5%.
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
        (price, rate) = _fetchMid($.priceOracle);
        uint256 underlyingCollateralAdded;
        (wrappedFee, peggedMinted, wrappedCollateralUsed, underlyingCollateralAdded) = MinterAdjustments_v1
            .mintPeggedAdjustments(
                $.incentiveConfig[Config_v2.MINT_PEGGED],
                wrappedCollateralIn,
                MinterValuationLib.CollateralRatioData(
                    _effectiveBacking($),
                    price,
                    rate,
                    $.peggedTokenBalance,
                    _leveragedTokenBalance()
                ),
                maxFeeRatio
            );
        // slither-disable-next-line incorrect-equality
        incentiveRatio = wrappedCollateralUsed == 0
            ? _lookupIncentiveRatio(Config_v2.MINT_PEGGED)
            : int256(Math.mulDiv(wrappedFee, 1 ether, wrappedCollateralUsed));
    }

    /// @inheritdoc IMinter_v3
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
        (price, rate) = _fetchMid($.priceOracle);
        peggedRedeemed = peggedIn;
        uint256 peggedPriceE36;
        // slither-disable-next-line unused-return a dry run does not touch the backing record
        (wrappedFee, wrappedDiscount, wrappedCollateralReturned, , peggedPriceE36) = MinterAdjustments_v1
            .redeemPeggedAdjustments(
                $.incentiveConfig[Config_v2.REDEEM_PEGGED],
                peggedIn,
                MinterValuationLib.CollateralRatioData(
                    _effectiveBacking($),
                    price,
                    rate,
                    peggedTokenBalance_,
                    _leveragedTokenBalance()
                ),
                IERC20(WRAPPED_COLLATERAL_TOKEN).balanceOf($.reservePool)
            );
        // slither-disable-next-line incorrect-equality
        if (peggedRedeemed == 0) {
            incentiveRatio = _lookupIncentiveRatio(Config_v2.REDEEM_PEGGED);
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

    /// @inheritdoc IMinter_v3
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
        (price, rate) = _fetchMid($.priceOracle);

        // slither-disable-next-line unused-return a dry run does not touch the backing record
        (wrappedFee, wrappedDiscount, leveragedMinted, wrappedCollateralUsed, ) = MinterAdjustments_v1
            .mintLeveragedAdjustments(
                $.incentiveConfig[Config_v2.MINT_LEVERAGED],
                wrappedCollateralIn,
                MinterValuationLib.CollateralRatioData(
                    _effectiveBacking($),
                    price,
                    rate,
                    $.peggedTokenBalance,
                    _leveragedTokenBalance()
                ),
                IERC20(WRAPPED_COLLATERAL_TOKEN).balanceOf($.reservePool)
            );
        // slither-disable-next-line incorrect-equality
        if (wrappedCollateralUsed == 0) {
            incentiveRatio = _lookupIncentiveRatio(Config_v2.MINT_LEVERAGED);
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

    /// @inheritdoc IMinter_v3
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
        (price, rate) = _fetchMid($.priceOracle);

        // slither-disable-next-line unused-return a dry run does not touch the backing record
        (wrappedFee, leveragedRedeemed, wrappedCollateralReturned, ) = MinterAdjustments_v1.redeemLeveragedAdjustments(
            $.incentiveConfig[Config_v2.REDEEM_LEVERAGED],
            leveragedIn,
            MinterValuationLib.CollateralRatioData(
                _effectiveBacking($),
                price,
                rate,
                $.peggedTokenBalance,
                leveragedTokenBalance_
            )
        );
        // slither-disable-next-line incorrect-equality
        incentiveRatio = wrappedCollateralReturned == 0
            ? _lookupIncentiveRatio(Config_v2.REDEEM_LEVERAGED)
            : int256(Math.mulDiv(wrappedFee, 1 ether, wrappedCollateralReturned + wrappedFee));
    }

    /// @inheritdoc IMinter_v3
    function harvestable() external view returns (uint256 wrappedAmount) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 rate = _fetchMinRate($.priceOracle);
        uint256 balance = IERC20(WRAPPED_COLLATERAL_TOKEN).balanceOf(address(this));
        uint256 value = Math.mulDiv(_effectiveBacking($.underlyingCollateral, rate), 1 ether, rate);
        wrappedAmount = (balance > value) ? balance - value : 0;
    }

    //////////////////////////////
    // Public Mutator Functions //
    //////////////////////////////

    /// @inheritdoc IMinter_v3
    function donateWrappedCollateral(uint256 wrappedAmount) external nonReentrant {
        if (wrappedAmount == 0) {
            revert ZeroInputBalance(WRAPPED_COLLATERAL_TOKEN);
        }
        MinterStorage storage $ = _getMinterStorage();

        IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransferFrom(_msgSender(), address(this), wrappedAmount);

        // The collateral is valued at the min rate for the same reason the record is: the conservative edge
        // never credits more backing than the donation stands up.
        uint256 collateralAdded = MinterValuationLib.wrappedAsCollateral(wrappedAmount, _fetchMinRate($.priceOracle));
        uint256 backing = $.underlyingCollateral + collateralAdded;
        $.underlyingCollateral = backing;

        emit DonateWrappedCollateral(_msgSender(), wrappedAmount, collateralAdded, backing);
    }

    /// @inheritdoc IMinter_v3
    function recogniseImpairment() external onlyOwner {
        MinterStorage storage $ = _getMinterStorage();
        uint256 backing = $.underlyingCollateral;
        uint256 recognised = _effectiveBacking($);
        if (recognised >= backing) {
            revert NothingToRecognise(backing);
        }
        $.underlyingCollateral = recognised;

        emit RecogniseImpairment(backing, recognised);
    }

    /// @inheritdoc IMinter_v3
    function updateConfig(Config calldata config_) external override onlyOwner {
        // or is this handled by the fact that the CR for discount is much lower than the rebalance CR
        emit UpdateConfig(config_); // the code below may alter the config so emit it soon
        MinterStorage storage $ = _getMinterStorage();
        // incentive config
        Config_v2.checkAndCopyIncentives(config_, $.incentiveConfig);
    }

    // Price/Rate Oracle
    // -----------------
    /// @inheritdoc IMinter_v3
    /// @dev Refuses the zero address. Every price read calls this address, so a zero here disables minting and
    ///      redeeming — but only as a side effect of a call into a codeless address failing to decode, which is an
    ///      accident of the ABI rather than a decision. Rejecting it at the setter puts the failure where the
    ///      mistake is made instead of inside a later mint.
    function updatePriceOracle(address priceOracle_) external onlyOwner {
        Token.ensureNonZeroAddress(priceOracle_);
        MinterStorage storage $ = _getMinterStorage();
        address old = $.priceOracle;
        $.priceOracle = priceOracle_;
        emit UpdatePriceOracle(old, priceOracle_);
    }

    // Fee Receiver
    // ------------
    /// @inheritdoc IMinter_v3
    function updateFeeReceiver(address feeReceiver_) external override onlyOwner {
        Token.ensureNonZeroAddress(feeReceiver_);
        MinterStorage storage $ = _getMinterStorage();
        address old = $.feeReceiver;
        $.feeReceiver = feeReceiver_;
        emit UpdateFeeReceiver(old, feeReceiver_);
    }

    // ReservePool
    // -----------
    /// @inheritdoc IMinter_v3
    function updateReservePool(address reservePool_) external override onlyOwner {
        Token.ensureNonZeroAddress(reservePool_);
        MinterStorage storage $ = _getMinterStorage();
        address old = $.reservePool;
        $.reservePool = reservePool_;
        emit UpdateReservePool(old, reservePool_);
    }

    // minting/redeeming pegged/leveraged tokens
    // -----------------------------------------

    /// @inheritdoc IMinter_v3
    function mintPeggedToken(
        uint256 wrappedCollateralIn,
        address receiver,
        uint256 minPeggedOut
    ) external override returns (uint256 peggedOut) {
        (peggedOut, ) = _mintPeggedTokenCapped(wrappedCollateralIn, receiver, minPeggedOut, type(uint256).max);
    }

    /// @inheritdoc IMinter_v3
    function mintPeggedToken(
        uint256 wrappedCollateralIn,
        address receiver,
        uint256 minPeggedOut,
        uint256 maxFeeRatio
    ) external returns (uint256 peggedOut, uint256 wrappedCollateralUsed) {
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
    ) internal nonReentrant returns (uint256 peggedOut, uint256 wrappedCollateralUsed) {
        MinterStorage storage $ = _getMinterStorage();
        (uint256 price, uint256 rate) = _fetchMid($.priceOracle);

        wrappedCollateralIn = Token.allOf(_msgSender(), WRAPPED_COLLATERAL_TOKEN, wrappedCollateralIn);

        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        uint256 underlyingCollateral_ = _effectiveBacking($);

        uint256 wrappedFee;
        uint256 underlyingCollateralAdded;
        (wrappedFee, peggedOut, wrappedCollateralUsed, underlyingCollateralAdded) = MinterAdjustments_v1
            .mintPeggedAdjustments(
                $.incentiveConfig[Config_v2.MINT_PEGGED],
                wrappedCollateralIn,
                MinterValuationLib.CollateralRatioData(
                    underlyingCollateral_,
                    price,
                    rate,
                    peggedTokenBalance_,
                    _leveragedTokenBalance()
                ),
                maxFeeRatio
            );

        // The pegged tokens minted are floored, so a mint too small to buy a whole one yields nothing.
        // Taking its collateral and fee anyway would charge the caller for nothing, so both the "nothing
        // can be taken" and the "nothing would be produced" cases stop here — as they do for redeeming
        // pegged, minting leveraged and redeeming leveraged.
        // slither-disable-next-line incorrect-equality
        if (wrappedCollateralUsed == 0 || peggedOut == 0) {
            if (maxFeeRatio == type(uint256).max) {
                // Two distinct facts, so two distinct errors: the config forbids minting at this
                // collateral ratio, or it allows it but the offer is too small to yield a whole token.
                // slither-disable-next-line incorrect-equality
                if (wrappedCollateralUsed == 0) {
                    revert MintZeroAmount(PEGGED_TOKEN);
                }
                revert ReturnZeroAmount(PEGGED_TOKEN);
            }
            // Capped: nothing is consumed on this path, so (0, 0) is the honest report - but only to a caller
            // that asked for no minimum. One that named a minimum is owed the same answer here as on every
            // other path, so fall through to the check below, which a zero output can only fail.
            if (minPeggedOut == 0) {
                return (0, 0);
            }
        }

        if (peggedOut < minPeggedOut) {
            revert MintInsufficientAmount(PEGGED_TOKEN, peggedOut, minPeggedOut);
        }

        // _mintPeggedToken pulls only wrappedCollateralUsed from sender via safeTransferFrom
        _mintPeggedToken(wrappedCollateralUsed, peggedOut, receiver);

        if (wrappedFee > 0) {
            IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer($.feeReceiver, wrappedFee);
        }

        $.underlyingCollateral += underlyingCollateralAdded;
        $.peggedTokenBalance = peggedTokenBalance_ + peggedOut;
    }

    /// @inheritdoc IMinter_v3

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
        (uint256 price, uint256 rate) = _fetchMax($.priceOracle);

        uint256 underlyingCollateral_ = _effectiveBacking($);
        address reservePool_ = $.reservePool;

        uint256 wrappedFee;
        uint256 wrappedDiscount;
        uint256 underlyingCollateralRemoved;
        // slither-disable-next-line unused-return the pegged price is only reported by the dry run
        (wrappedFee, wrappedDiscount, wrappedCollateralOut, underlyingCollateralRemoved, ) = MinterAdjustments_v1
            .redeemPeggedAdjustments(
                $.incentiveConfig[Config_v2.REDEEM_PEGGED],
                peggedIn,
                MinterValuationLib.CollateralRatioData(
                    underlyingCollateral_,
                    price,
                    rate,
                    peggedTokenBalance_,
                    _leveragedTokenBalance()
                ),
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
        emit RedeemPeggedToken(_msgSender(), receiver, peggedIn, wrappedCollateralOut, 0);
        IBurnableFrom(PEGGED_TOKEN).burnFrom(_msgSender(), peggedIn);
        IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer(receiver, wrappedCollateralOut);

        // update our records
        $.peggedTokenBalance = peggedTokenBalance_ - peggedIn;
        $.underlyingCollateral -= underlyingCollateralRemoved;
    }

    /// @inheritdoc IMinter_v3
    function mintLeveragedToken(
        uint256 wrappedCollateralIn,
        address receiver,
        uint256 minLeveragedOut
    ) external override nonReentrant returns (uint256 leveragedOut) {
        MinterStorage storage $ = _getMinterStorage();
        wrappedCollateralIn = Token.allOf(_msgSender(), WRAPPED_COLLATERAL_TOKEN, wrappedCollateralIn);

        MinterValuationLib.CollateralRatioData memory crData;
        {
            (uint256 price, uint256 rate) = _fetchMid($.priceOracle);
            uint256 backing = _effectiveBacking($);
            _requireLeveragedIssuable(backing, price, $.peggedTokenBalance);
            crData = MinterValuationLib.CollateralRatioData(
                backing,
                price,
                rate,
                $.peggedTokenBalance,
                _leveragedTokenBalance()
            );
        }
        uint256 wrappedFee;
        uint256 wrappedDiscount;
        uint256 underlyingCollateralAdded;
        address reservePool_ = $.reservePool;

        (
            wrappedFee,
            wrappedDiscount,
            leveragedOut,
            wrappedCollateralIn,
            underlyingCollateralAdded
        ) = MinterAdjustments_v1.mintLeveragedAdjustments(
                $.incentiveConfig[Config_v2.MINT_LEVERAGED],
                wrappedCollateralIn,
                crData,
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
        $.underlyingCollateral += underlyingCollateralAdded;
    }

    /// @inheritdoc IMinter_v3
    function redeemLeveragedToken(
        uint256 leveragedIn,
        address receiver,
        uint256 minWrappedCollateralOut
    ) external override nonReentrant returns (uint256 wrappedCollateralOut) {
        MinterStorage storage $ = _getMinterStorage();
        leveragedIn = Token.allOf(_msgSender(), LEVERAGED_TOKEN, leveragedIn);

        uint256 leveragedTokenBalance_ = _leveragedTokenBalance();
        leveragedIn = _redeemable(LEVERAGED_TOKEN, leveragedIn, leveragedTokenBalance_);
        (uint256 price, uint256 rate) = _fetchMin($.priceOracle);

        uint256 underlyingCollateral_ = _effectiveBacking($.underlyingCollateral, rate);

        uint256 wrappedFee;
        uint256 underlyingCollateralOut;
        (wrappedFee, leveragedIn, wrappedCollateralOut, underlyingCollateralOut) = MinterAdjustments_v1
            .redeemLeveragedAdjustments(
                $.incentiveConfig[Config_v2.REDEEM_LEVERAGED],
                leveragedIn,
                MinterValuationLib.CollateralRatioData(
                    underlyingCollateral_,
                    price,
                    rate,
                    $.peggedTokenBalance,
                    leveragedTokenBalance_
                )
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
        $.underlyingCollateral -= underlyingCollateralOut;
    }

    //////////////////////////////////
    // Restricted Mutator Functions //
    //////////////////////////////////

    // fee-free minting/redeeming pegged/leveraged tokens
    // --------------------------------------------------

    /// @inheritdoc IMinter_v3
    function freeMintPeggedToken(
        uint256 wrappedCollateralIn,
        address receiver
    ) external override onlyOwnerOrRoles(ZERO_FEE_ROLE) nonReentrant returns (uint256 peggedOut) {
        MinterStorage storage $ = _getMinterStorage();
        (uint256 price, uint256 rate) = _fetchMid($.priceOracle);
        uint256 underlyingCollateralInE36 = wrappedCollateralIn * rate;

        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        uint256 underlyingCollateral_ = _effectiveBacking($);
        // A depegged pegged is issued at its depressed price, which yields more tokens per unit of collateral -
        // but only while that price is one the protocol can report. Below the reportable floor it rounds to zero
        // everywhere outside this contract, so the mint would issue against a figure no consumer can see, in
        // unbounded quantity. Say so, rather than dividing by it. The fee-paying mint refuses on the same
        // threshold, taken from the same constant, so the two cannot drift apart.
        uint256 peggedPriceE36 = MinterValuationLib.peggedTokenPriceE36(
            peggedTokenBalance_,
            underlyingCollateral_,
            price
        );
        if (peggedPriceE36 < MinterValuationLib.MIN_REPORTABLE_PEGGED_PRICE_E36) {
            revert ZeroPeggedTokenPrice();
        }
        peggedOut = Math.mulDiv(underlyingCollateralInE36, price, peggedPriceE36);

        // transfer and mint
        _mintPeggedToken(wrappedCollateralIn, peggedOut, receiver);

        // update our records
        $.peggedTokenBalance = peggedTokenBalance_ + peggedOut;
        $.underlyingCollateral += underlyingCollateralInE36 / 1 ether;
    }

    // @inheritdoc IMinter
    function freeRedeemPeggedToken(
        uint256 peggedForCollateral,
        uint256 peggedForLeveraged,
        address receiver
    )
        external
        onlyOwnerOrRoles(ZERO_FEE_ROLE)
        nonReentrant
        returns (uint256 wrappedCollateralOut, uint256 leveragedOut)
    {
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

            (uint256 price, uint256 rate) = _fetchMax($.priceOracle);

            // Snapshot original state so both paths price against the same pre-burn balances,
            // consistent with how redeemPeggedForCollateralRatio computed the amounts.
            uint256 underlyingCollateral_ = _effectiveBacking($);

            // The rule's own refusal FIRST, judged on that snapshot before either leg has moved anything:
            // below its floor the market sells no leverage on any route, and that is the reason to give
            // whether or not the amount would also round to nothing.
            if (peggedForLeveraged > 0) {
                _requireLeveragedIssuable(underlyingCollateral_, price, peggedTokenBalance_);
            }

            uint256 underlyingCollateralOutE36;
            (wrappedCollateralOut, leveragedOut, underlyingCollateralOutE36) = _freeRedeemAmounts(
                peggedForCollateral,
                peggedForLeveraged,
                peggedTokenBalance_,
                underlyingCollateral_,
                price,
                rate
            );

            // Each leg burns pegged, so neither may take it without handing something back. A leg
            // that yields nothing has priced the pegged at nothing, and burning against that price
            // destroys the redeemer's claim outright rather than settling it - which on this path
            // means a rebalance consuming the stability pool's deposit and returning it nothing.
            // The fee-paying redeem already refuses on the same condition, by the same name.
            if (peggedForCollateral > 0) {
                // slither-disable-next-line incorrect-equality
                if (wrappedCollateralOut == 0) {
                    revert ReturnZeroAmount(WRAPPED_COLLATERAL_TOKEN);
                }
                // return the collateral
                IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer(receiver, wrappedCollateralOut);
                $.underlyingCollateral -= underlyingCollateralOutE36 / 1 ether;
            }

            if (peggedForLeveraged > 0) {
                // slither-disable-next-line incorrect-equality
                if (leveragedOut == 0) {
                    revert ReturnZeroAmount(LEVERAGED_TOKEN);
                }
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

            // burn the tokens from the sender
            IBurnableFrom(PEGGED_TOKEN).burnFrom(_msgSender(), peggedForCollateral + peggedForLeveraged);
            // update our records
            $.peggedTokenBalance = peggedTokenBalance_ - (peggedForCollateral + peggedForLeveraged);
        }
    }

    /// @inheritdoc IMinter_v3
    function freeRedeemDryRun(
        uint256 peggedForCollateral,
        uint256 peggedForLeveraged
    ) external view override returns (uint256 wrappedCollateralOut, uint256 leveragedOut) {
        MinterStorage storage $ = _getMinterStorage();
        (uint256 price, uint256 rate) = _fetchMax($.priceOracle);
        // slither-disable-next-line unused-return a dry run does not touch the backing record
        (wrappedCollateralOut, leveragedOut, ) = _freeRedeemAmounts(
            peggedForCollateral,
            peggedForLeveraged,
            $.peggedTokenBalance,
            _effectiveBacking($),
            price,
            rate
        );
    }

    /// @notice What a free redeem hands back for a given pre-burn state: collateral for the leg redeemed
    ///         against the backing, and leveraged tokens for the leg converted into the residual.
    /// @dev The single place the exchange's arithmetic is reached from, so the call and the dry run
    ///      cannot price a redeem differently, and so the rule can be substituted whole rather than at
    ///      each site. The leveraged supply is read here rather than passed in, because both callers
    ///      read the same one.
    /// @dev Assigned to the named returns rather than forwarded with `return libraryCall(...)`. The two
    ///      are the same to the compiler, but the forwarding form reads to Slither as a dropped return
    ///      value - it does not follow a tuple back out of a call into an external library. Silencing
    ///      that would also silence a genuine dropped value here later, so the shape avoids it instead.
    function _freeRedeemAmounts(
        uint256 peggedForCollateral,
        uint256 peggedForLeveraged,
        uint256 peggedTokenBalance_,
        uint256 underlyingCollateral_,
        uint256 price,
        uint256 rate
    )
        internal
        view
        virtual
        returns (uint256 wrappedCollateralOut, uint256 leveragedOut, uint256 underlyingCollateralOutE36)
    {
        (wrappedCollateralOut, leveragedOut, underlyingCollateralOutE36) = MinterAdjustments_v1
            .freeRedeemPeggedTokenAmounts(
                peggedForCollateral,
                peggedForLeveraged,
                peggedTokenBalance_,
                underlyingCollateral_,
                price,
                rate,
                _leveragedTokenBalance()
            );
    }

    // @inheritdoc IMinter
    function freeMintLeveragedToken(
        uint256 wrappedCollateralIn,
        address receiver
    ) external override onlyOwnerOrRoles(ZERO_FEE_ROLE) nonReentrant returns (uint256 leveragedOut) {
        MinterStorage storage $ = _getMinterStorage();
        // how much collateral to use
        (uint256 price, uint256 rate) = _fetchMid($.priceOracle);
        uint256 backing = _effectiveBacking($);
        _requireLeveragedIssuable(backing, price, $.peggedTokenBalance);

        (uint256 collateralValueE36, uint256 peggedValueE36) = MinterValuationLib.tokenValuesE36(
            $.peggedTokenBalance,
            backing,
            price
        );
        uint256 underlyingCollateralInE36 = wrappedCollateralIn * rate;
        uint256 leveragedTokenBalance_ = _leveragedTokenBalance();
        // Leveraged is the residual claim, so there must be a residual for a mint to buy into. Left at zero,
        // `_mintLeveragedToken` turns the caller away by name - matching the fee-paying path, whose adjustments
        // return zero in the same state.
        if (leveragedTokenBalance_ > 0) {
            // An issued leveraged token with no residual behind it is worth nothing, and nothing is not a price.
            uint256 leveragedPriceE36 = _leveragedTokenPriceE36(
                collateralValueE36,
                peggedValueE36,
                leveragedTokenBalance_
            );
            if (leveragedPriceE36 > 0) {
                leveragedOut = (underlyingCollateralInE36 * price) / leveragedPriceE36;
            }
        } else {
            // The first leveraged issued takes the residual this deposit itself creates, so it is the balance AFTER the
            // deposit that must cover the pegged claim - which is why the test is not the one above. The claim is
            // taken unclamped: `tokenValuesE36` caps it at the collateral value, and the shortfall is the point here.
            uint256 postDepositValueE36 = collateralValueE36 + Math.mulDiv(underlyingCollateralInE36, price, 1e18);
            uint256 peggedClaimE36 = $.peggedTokenBalance * 1e18;
            if (postDepositValueE36 > peggedClaimE36) {
                leveragedOut = (postDepositValueE36 - peggedClaimE36) / 1e18;
            }
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
    ) external override onlyOwnerOrRoles(ZERO_FEE_ROLE) nonReentrant returns (uint256 collateralOut) {
        MinterStorage storage $ = _getMinterStorage();

        uint256 leveragedTokenBalance_ = _leveragedTokenBalance();
        leveragedIn = _redeemable(LEVERAGED_TOKEN, leveragedIn, leveragedTokenBalance_);

        (uint256 price, uint256 rate) = _fetchMin($.priceOracle);

        (uint256 collateralValueE36, uint256 peggedValueE36) = MinterValuationLib.tokenValuesE36(
            $.peggedTokenBalance,
            _effectiveBacking($.underlyingCollateral, rate),
            price
        );
        if (collateralValueE36 <= peggedValueE36) {
            collateralOut = 0;
        } else {
            uint256 underlyingCollateralOutE36;
            if (leveragedTokenBalance_ == 0) {
                underlyingCollateralOutE36 = leveragedIn * price;
            } else {
                underlyingCollateralOutE36 = Math.mulDiv(
                    leveragedIn * 1 ether,
                    collateralValueE36 - peggedValueE36,
                    price * leveragedTokenBalance_
                );
            }
            collateralOut = underlyingCollateralOutE36 / rate;

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
    function _getMinterStorage() private pure returns (MinterStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _MINTER_STORAGE
        }
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
        amountOut = _redeemableQuiet(amountIn, tokenBalance_);
        // slither-disable-next-line incorrect-equality
        if (amountOut == 0) {
            revert NoRedeemableTokens(token_);
        }
    }

    function _redeemableQuiet(uint256 amountIn, uint256 tokenBalance_) private pure returns (uint256 amountOut) {
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

    /// @notice The recorded backing, recognised against the collateral actually standing behind it.
    /// @dev The record is a collateral-token quantity, but what the contract holds is the wrapped token. An
    /// impairment of the collateral lowers the wrapped-to-collateral rate, so the record comes to claim more
    /// collateral than the holding converts to, and everything priced from it favours whoever leaves first: the
    /// junior claim escapes the band that stops it being paid out of the senior claim's backing, the senior claim
    /// redeems at face value on short cover, and the rebalance that would resolve it reads a ratio too high to
    /// fire. Taking the lower of the two can never overstate.
    ///
    /// The min rate decides, as it does for `harvestable`: the conservative edge writes the record down hardest,
    /// so the band's width is never spent claiming cover that may not be there.
    function _effectiveBacking(MinterStorage storage $) private view returns (uint256 backing) {
        backing = _effectiveBacking($.underlyingCollateral, _fetchMinRate($.priceOracle));
    }

    /// @notice The recognised backing, for a caller holding the record and the min rate already.
    /// @dev The min rate is the one that decides, whichever edge the operation itself prices at: the conservative
    /// edge writes the record down hardest, so the band's width is never spent claiming cover that may not be
    /// there. An operation must not substitute its own rate for it — valuing the backing at the max rate during an
    /// pegged redemption would report more cover than is held and pay out against it.
    /// @param underlyingCollateral_ The recorded backing.
    /// @param minRate The min wrapped-to-collateral rate.
    function _effectiveBacking(uint256 underlyingCollateral_, uint256 minRate) private view returns (uint256 backing) {
        backing = underlyingCollateral_;
        uint256 held = MinterValuationLib.wrappedAsCollateral(
            IERC20(WRAPPED_COLLATERAL_TOKEN).balanceOf(address(this)),
            minRate
        );
        if (held < backing) {
            backing = held;
        }
    }

    /// @notice Returns the amount of leveraged tokens being managed
    function _leveragedTokenBalance() internal view returns (uint256) {
        return IERC20(LEVERAGED_TOKEN).totalSupply();
    }

    // fetching collateral price in terms of the pegged tokens
    // -------------------------------------------------------

    /// @notice Reads the oracle, rejecting a zero reading that the caller would go on to consume.
    /// @dev Neither zero is an economic state: a collateral asset worth nothing and a wrapped-to-underlying
    /// conversion of zero can only mean the oracle is faulty. Left through, they are indistinguishable from real
    /// extremes that drive automated action - a zero price reports the collateral ratio as 0, i.e. wholly
    /// undercollateralised. The oracle cannot supply this guarantee itself: its underlying feed check rejects only
    /// prices strictly below zero, and the wrapped rate is passed through unvalidated.
    ///
    /// The RAW readings are checked, not each caller's result. `_fetchMid` averages min and max, so an oracle
    /// reporting a zero min against a doubled max rounds to a healthy-looking mid and would slip past a check
    /// applied afterwards, while `_fetchMin` hands back a hard zero from that same reading.
    ///
    /// Each reading is checked only when the caller consumes it, which the flags declare. A view that reads the
    /// price and never the rate must not be stopped by a faulty rate, nor the reverse: refusing to answer a question
    /// whose inputs are all sound would be a fault of its own.
    function _latestAnswer(
        address priceOracle_,
        bool checkPrice,
        bool checkRate
    ) private view returns (uint256 minPrice, uint256 maxPrice, uint256 minRate, uint256 maxRate) {
        (minPrice, maxPrice, minRate, maxRate) = IWrappedPriceOracle(priceOracle_).latestAnswer();
        if (checkPrice && (minPrice == 0 || maxPrice == 0)) {
            revert ZeroOraclePrice();
        }
        if (checkRate && (minRate == 0 || maxRate == 0)) {
            revert ZeroOracleRate();
        }
    }

    /// @notice Returns the mid collateral price and the mid wrapped-to-underlying rate.
    /// @dev The oracle reports each value as a band; the mid is the rounded average of the band's two edges. Both
    /// readings are validated, since every caller of this variant consumes both.
    function _fetchMid(address priceOracle_) private view returns (uint256 price, uint256 rate) {
        (uint256 minPrice, uint256 maxPrice, uint256 minRate, uint256 maxRate) = _latestAnswer(
            priceOracle_,
            true,
            true
        );
        price = MinterValuationLib.round(minPrice + maxPrice, 2);
        rate = MinterValuationLib.round(minRate + maxRate, 2);
    }

    /// @notice Returns the low edge of the collateral price band and of the rate band.
    /// @dev Paired with `_fetchMax`: each flow reads whichever edge is the conservative one for its own direction,
    /// so the band's width is never spent in the user's favour. Both readings are validated, since every caller of
    /// this variant consumes both.
    function _fetchMin(address priceOracle_) private view returns (uint256 price, uint256 rate) {
        // slither-disable-next-line unused-return
        (price, , rate, ) = _latestAnswer(priceOracle_, true, true);
    }

    /// @notice Returns the high edge of the collateral price band and of the rate band.
    /// @dev The counterpart to `_fetchMin`, chosen by the same rule. Both readings are validated, since every caller
    /// of this variant consumes both.
    function _fetchMax(address priceOracle_) private view returns (uint256 price, uint256 rate) {
        // slither-disable-next-line unused-return
        (, price, , rate) = _latestAnswer(priceOracle_, true, true);
    }

    /// @notice Returns the min wrapped-to-underlying rate, for callers that do not consume the price.
    /// @dev The min is the conservative side: `harvestable` divides the recorded collateral by it and `reset`
    /// multiplies the held collateral by it, so the low reading under-reports what may be swept and writes the
    /// recorded collateral down hardest. This follows the per-direction choice made elsewhere - `_fetchMax` for
    /// pegged redeems, `_fetchMin` for leveraged ones.
    ///
    /// Only the rate is checked. A caller that never looks at the price must not be stopped by a faulty one; the
    /// rate is a units conversion and stands on its own. Both rate readings are checked even though one is returned,
    /// as for `_fetchMin` and `_fetchMax`: a zero on either side is a faulty oracle whichever side is used.
    function _fetchMinRate(address priceOracle_) private view returns (uint256 rate) {
        // slither-disable-next-line unused-return
        (, , rate, ) = _latestAnswer(priceOracle_, false, true);
    }

    /// @notice Returns the mid price for the collateral token, for callers that do not consume the rate.
    /// @dev Checks the price readings only - the mirror of `_fetchMinRate`. A reading the caller never looks at
    /// cannot invalidate its answer, so a faulty rate must not stop a purely price-based view from reporting.
    function _fetchMidPrice(address priceOracle_) private view returns (uint256 price) {
        // slither-disable-next-line unused-return
        (uint256 minPrice, uint256 maxPrice, , ) = _latestAnswer(priceOracle_, true, false);
        price = MinterValuationLib.round(minPrice + maxPrice, 2);
    }

    /// @notice Returns the high edge of the collateral price band, for callers that do not consume the rate.
    /// @dev Checks the price readings only, as `_fetchMidPrice` does.
    function _fetchMaxPrice(address priceOracle_) private view returns (uint256 price) {
        // slither-disable-next-line unused-return
        (, price, , ) = _latestAnswer(priceOracle_, true, false);
    }

    // Harvesting support
    // -------------------------------------------------------
    /// @notice function used to control access to the sweep function for extracting harvestable amounts
    function _checkSweeper() internal view override(TokenHolder_v2) {
        _checkOwnerOrRoles(HARVESTER_ROLE);
    }
}
