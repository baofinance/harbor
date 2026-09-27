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
        //                                             slot
        // Collateral escrowed PER LEVERAGED TOKEN, at 1e18, so that the leveraged claim cannot fall to
        // nothing however little of the collateral the pegged token's claim leaves behind. The escrow
        // itself is this times the supply, and is NOT part of `underlyingCollateral`: the collateral
        // ratio, the pegged token's claim and its price are computed from that account alone and are
        // unaffected by anything here. The leveraged claim is the residual of that account PLUS the escrow.
        //
        // Held per token rather than as a balance so that the escrow FOLLOWS the supply instead of being
        // moved alongside it. A mint, a redeem and a conversion all leave it untouched, so the collateral
        // escrowed per token cannot drift: the same supply always gives the same escrow, whatever path
        // reached it. Set once by the first mint into an empty supply, and moved afterwards only by a
        // recognised impairment.
        uint256 escrowPerLeveragedToken; //              256
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
        return _recordedBacking($);
    }

    /// @inheritdoc IMinter_v3
    function collateralAccounts() external view override returns (uint256 backing, uint256 leveragedCollateralEscrow) {
        MinterStorage storage $ = _getMinterStorage();
        (backing, leveragedCollateralEscrow) = _recordedAccounts($);
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
        collateralRatio_ = MinterValuationLib.collateralRatio(_recordedBacking($), price, $.peggedTokenBalance);
    }

    /// @inheritdoc IMinter_v3
    function leverageRatio() external view override returns (uint256 ratio) {
        MinterStorage storage $ = _getMinterStorage();

        uint256 price = _fetchMidPrice($.priceOracle);
        (uint256 backing, uint256 escrow) = _recordedAccounts($);
        ratio = MinterValuationLib.leverageRatio($.peggedTokenBalance, backing, escrow, price);
    }

    /// @inheritdoc IMinter_v3
    function leveragedTokenPrice() external view override returns (uint256 nav) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 price = _fetchMidPrice($.priceOracle);
        (uint256 backing, uint256 escrow) = _recordedAccounts($);
        (uint256 collateralValueE36, uint256 peggedValueE36) = MinterValuationLib.tokenValuesE36(
            $.peggedTokenBalance,
            backing,
            price
        );
        nav =
            _leveragedTokenPriceE36(collateralValueE36, peggedValueE36, escrow, price, _leveragedTokenBalance()) /
            1 ether;
    }

    function _leveragedTokenPriceE36(
        uint256 collateralValueE36,
        uint256 peggedValueE36,
        uint256 leveragedCollateralEscrow_,
        uint256 collateralPrice,
        uint256 leveragedTokenBalance_
    ) internal pure returns (uint256 navE36) {
        if (leveragedTokenBalance_ == 0) {
            navE36 = 1e36;
        } else {
            // by definition the leveraged token value is its claim: what the pegged token leaves of the main
            // account, plus the collateral escrowed for the leveraged token
            navE36 = Math.mulDiv(
                MinterValuationLib.leveragedClaimE36(
                    collateralValueE36,
                    peggedValueE36,
                    leveragedCollateralEscrow_,
                    collateralPrice
                ),
                1e18,
                leveragedTokenBalance_
            );
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
                _recordedBacking($),
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
        MinterStorage storage $ = _getMinterStorage();
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        uint256 price = _fetchMaxPrice($.priceOracle);
        // Scoped so the escrow is off the stack before the split's ten arguments arrive.
        uint256 collateralTokenBalance_;
        uint256 escrowedPerPegged;
        {
            uint256 escrow;
            (collateralTokenBalance_, escrow) = _recordedAccounts($);
            escrowedPerPegged = _escrowedPerPegged(collateralTokenBalance_, escrow, peggedTokenBalance_, price);
        }
        (peggedForCollateral, peggedForLeveraged) = RebalanceSizing_v1.split(
            targetCollateralRatio,
            MinterValuationLib.collateralRatio(collateralTokenBalance_, price, peggedTokenBalance_),
            maxCollateralPegged,
            maxLeveragedPegged,
            holdingCollateral,
            holdingLeveraged,
            peggedTokenBalance_,
            collateralTokenBalance_,
            price,
            escrowedPerPegged
        );
    }

    /// @notice The collateral a conversion moves into the escrow for each pegged token it converts, at 1e18.
    /// @dev The conversion issues `a x peggedPrice / leveragedPrice` tokens and escrows the same proportion of the
    /// escrow that those are of the supply, so the move per pegged token is
    ///
    ///     escrow x peggedPrice / claim
    ///
    /// with the claim being the residual plus the escrow - the supply cancels out of it entirely, which is what
    /// keeps this a constant of the pre-burn state rather than something that moves as the conversion proceeds.
    ///
    /// Never more than `C/n`, so the conversion it sizes cannot lower the collateral ratio. That is a property of
    /// the expression rather than a bound imposed on it: above the peg the claim exceeds the escrow by the
    /// residual and the two are strictly apart, and at or below the peg the residual is gone and they are equal
    /// to the wei. Capping here as well would put a floor under the sizing that the conversion does not apply,
    /// and the two would then disagree at exactly the collateral ratio the rebalance is reaching for.
    /// ESCROW RULE, PART 5 OF 5. The sizing's half of `_conversionEscrowMove`: that one decides what a
    /// conversion MOVES, this one tells the rebalance's split how much each pegged token will drag out of
    /// the backing, so it can solve for the burn that lands on the target. The two must agree. Override one
    /// without the other and the split solves an equation the conversion does not satisfy - measured, a rule
    /// that moved nothing while this still promised a drag liquidated the entire pool at every collateral
    /// ratio below the peg, and reported ratios in the thousands.
    function _escrowedPerPegged(
        uint256 collateralTokenBalance_,
        uint256 escrow,
        uint256 peggedTokenBalance_,
        uint256 price
    ) internal view virtual returns (uint256 perPegged) {
        if (peggedTokenBalance_ == 0) {
            return 0;
        }
        (uint256 collateralValueE36, uint256 peggedValueE36) = MinterValuationLib.tokenValuesE36(
            peggedTokenBalance_,
            collateralTokenBalance_,
            price
        );
        if (_leveragedTokenBalance() == 0) {
            // The conversion is opening the leveraged side, so it escrows a share of the collateral it converts
            // rather than a proportion of an escrow that does not exist yet. Sizing off the CURRENT escrow here
            // would report no move at all and leave the target short by the whole of what the conversion is
            // about to set aside.
            perPegged = Math.mulDiv(
                MinterValuationLib.peggedTokenPriceE36(peggedTokenBalance_, collateralTokenBalance_, price),
                MinterValuationLib.LEVERAGED_ESCROW_RATIO,
                price * 1 ether
            );
        } else {
            uint256 claimE36 = MinterValuationLib.leveragedClaimE36(collateralValueE36, peggedValueE36, escrow, price);
            if (claimE36 == 0) {
                return 0;
            }
            perPegged = Math.mulDiv(escrow, 1 ether * 1 ether, claimE36);
        }
    }

    // incentive ratios
    // ----------------

    // solhint-disable-next-line explicit-types
    function _lookupIncentiveRatio(uint action) internal view returns (int256 incentiveRatio) {
        MinterStorage storage $ = _getMinterStorage();
        uint256 price = _fetchMidPrice($.priceOracle);
        uint256 collateralTokenBalance_ = _recordedBacking($);
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
                _collateralRatioData($, price, rate, $.peggedTokenBalance, _leveragedTokenBalance()),
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
                _collateralRatioData($, price, rate, peggedTokenBalance_, _leveragedTokenBalance()),
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
                _collateralRatioData($, price, rate, $.peggedTokenBalance, _leveragedTokenBalance()),
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
            _collateralRatioData($, price, rate, $.peggedTokenBalance, leveragedTokenBalance_)
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
        // The surplus is what the holding exceeds BOTH accounts by. The escrow sits in the same token and is
        // already spoken for, so leaving it out of the comparison would report it as yield - and a harvest would
        // carry the leveraged token's floor away as a gain, which is the one thing the floor cannot survive.
        (uint256 backing, uint256 escrow) = _recordedAccounts($);
        uint256 value = Math.mulDiv(backing + escrow, 1 ether, rate);
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
        (uint256 recognised, uint256 recognisedEscrow) = _accountsAsHeld(
            backing,
            _escrow($),
            _fetchMinRate($.priceOracle)
        );
        if (recognised >= backing) {
            revert NothingToRecognise(backing);
        }
        $.underlyingCollateral = recognised;
        // An impairment devalues the wrapped collateral the whole contract holds, so the escrow is worth less by
        // it too. Writing only the backing down would leave the escrow claiming collateral the impairment
        // destroyed - and two records that between them claim more than is held is the same defect whichever of
        // them is overstated. It only bites once the holding is below the escrow ITSELF, because the escrow is
        // taken out of the holding first and is the last thing an impairment reaches.
        //
        // This is the only thing other than a first mint that moves the collateral escrowed per token, and the
        // write is per token because the record is: floored, so what the supply derives never exceeds what is
        // recognised here. With no supply there is nothing to divide by and nothing standing on the figure, so
        // it is left for the next mint into an empty supply to set afresh.
        uint256 leveragedTokenBalance_ = _leveragedTokenBalance();
        if (leveragedTokenBalance_ > 0) {
            $.escrowPerLeveragedToken = Math.mulDiv(
                recognisedEscrow,
                MinterValuationLib.ESCROW_PER_TOKEN_SCALE,
                leveragedTokenBalance_
            );
        }

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
        _requireRecordsAreCovered($);
        (uint256 price, uint256 rate) = _fetchMid($.priceOracle);

        wrappedCollateralIn = Token.allOf(_msgSender(), WRAPPED_COLLATERAL_TOKEN, wrappedCollateralIn);

        uint256 peggedTokenBalance_ = $.peggedTokenBalance;

        uint256 wrappedFee;
        uint256 underlyingCollateralAdded;
        (wrappedFee, peggedOut, wrappedCollateralUsed, underlyingCollateralAdded) = MinterAdjustments_v1
            .mintPeggedAdjustments(
                $.incentiveConfig[Config_v2.MINT_PEGGED],
                wrappedCollateralIn,
                _collateralRatioData($, price, rate, peggedTokenBalance_, _leveragedTokenBalance()),
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
        _requireRecordsAreCovered($);
        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        peggedIn = Token.allOf(_msgSender(), PEGGED_TOKEN, peggedIn);
        peggedIn = _redeemable(PEGGED_TOKEN, peggedIn, peggedTokenBalance_);
        (uint256 price, uint256 rate) = _fetchMax($.priceOracle);

        address reservePool_ = $.reservePool;

        uint256 wrappedFee;
        uint256 wrappedDiscount;
        uint256 underlyingCollateralRemoved;
        // slither-disable-next-line unused-return the pegged price is only reported by the dry run
        (wrappedFee, wrappedDiscount, wrappedCollateralOut, underlyingCollateralRemoved, ) = MinterAdjustments_v1
            .redeemPeggedAdjustments(
                $.incentiveConfig[Config_v2.REDEEM_PEGGED],
                peggedIn,
                _collateralRatioData($, price, rate, peggedTokenBalance_, _leveragedTokenBalance()),
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
        _requireRecordsAreCovered($);
        wrappedCollateralIn = Token.allOf(_msgSender(), WRAPPED_COLLATERAL_TOKEN, wrappedCollateralIn);

        MinterValuationLib.CollateralRatioData memory crData;
        {
            (uint256 price, uint256 rate) = _fetchMid($.priceOracle);
            _requireLeveragedIssuable(_recordedBacking($), price, $.peggedTokenBalance);
            crData = _collateralRatioData($, price, rate, $.peggedTokenBalance, _leveragedTokenBalance());
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
        // update our records: the escrow follows the supply the mint has already raised, so nothing writes it.
        // What the deposit must do is hand over that much collateral, and add only the rest to the backing.
        $.underlyingCollateral +=
            underlyingCollateralAdded -
            _escrowTakenByAMint($, crData.leveragedTokenBalance, leveragedOut, underlyingCollateralAdded);
    }

    /// @inheritdoc IMinter_v3
    function redeemLeveragedToken(
        uint256 leveragedIn,
        address receiver,
        uint256 minWrappedCollateralOut
    ) external override nonReentrant returns (uint256 wrappedCollateralOut) {
        MinterStorage storage $ = _getMinterStorage();
        _requireRecordsAreCovered($);
        leveragedIn = Token.allOf(_msgSender(), LEVERAGED_TOKEN, leveragedIn);

        uint256 leveragedTokenBalance_ = _leveragedTokenBalance();
        leveragedIn = _redeemable(LEVERAGED_TOKEN, leveragedIn, leveragedTokenBalance_);
        (uint256 price, uint256 rate) = _fetchMin($.priceOracle);

        uint256 wrappedFee;
        uint256 underlyingCollateralOut;
        (wrappedFee, leveragedIn, wrappedCollateralOut, underlyingCollateralOut) = MinterAdjustments_v1
            .redeemLeveragedAdjustments(
                $.incentiveConfig[Config_v2.REDEEM_LEVERAGED],
                leveragedIn,
                _collateralRatioData($, price, rate, $.peggedTokenBalance, leveragedTokenBalance_)
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

        // update our records: the escrow follows the supply the redemption has already lowered, so nothing
        // writes it. What is left is to pay the holder that much out of the escrow, and only the rest out of
        // the backing.
        $.underlyingCollateral -=
            underlyingCollateralOut -
            _escrowReleasedByARedeem($, leveragedTokenBalance_, leveragedIn, underlyingCollateralOut);
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
        _requireRecordsAreCovered($);
        (uint256 price, uint256 rate) = _fetchMid($.priceOracle);
        uint256 underlyingCollateralInE36 = wrappedCollateralIn * rate;

        uint256 peggedTokenBalance_ = $.peggedTokenBalance;
        uint256 underlyingCollateral_ = _recordedBacking($);
        // A depegged pegged token is issued at its depressed price, which yields more tokens per unit of collateral -
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
            _requireRecordsAreCovered($);
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
            uint256 underlyingCollateral_ = _recordedBacking($);

            uint256 underlyingCollateralOutE36;
            (wrappedCollateralOut, leveragedOut, underlyingCollateralOutE36) = _freeRedeemAmounts(
                peggedForCollateral,
                peggedForLeveraged,
                peggedTokenBalance_,
                underlyingCollateral_,
                price,
                rate
            );

            // Each leg burns pegged tokens, so neither may take them without handing something back. A leg
            // that yields nothing has priced the pegged token at nothing, and burning against that price
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
                // The rule's own refusal FIRST. Below its floor a rule declines to sell leverage at all, and
                // that is the reason to give whether or not the amount also happens to round to nothing - a
                // zero-price market below the peg would otherwise report a rounding refusal in place of the
                // rule's, and a reader could not tell which of the two had spoken. Judged on the SNAPSHOT the
                // amounts were priced against: the collateral leg above has already debited the record while
                // the pegged it burned is written only after both legs, so the record here describes a market
                // that never existed.
                _requireLeveragedIssuable(underlyingCollateral_, price, peggedTokenBalance_);
                // slither-disable-next-line incorrect-equality
                if (leveragedOut == 0) {
                    revert ReturnZeroAmount(LEVERAGED_TOKEN);
                }

                $.underlyingCollateral -= _conversionEscrowMove(
                    $,
                    peggedForLeveraged,
                    leveragedOut,
                    peggedTokenBalance_,
                    underlyingCollateral_,
                    price
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
            _recordedBacking($),
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
                _leveragedTokenBalance(),
                _escrow(_getMinterStorage())
            );
    }

    // @inheritdoc IMinter
    function freeMintLeveragedToken(
        uint256 wrappedCollateralIn,
        address receiver
    ) external override onlyOwnerOrRoles(ZERO_FEE_ROLE) nonReentrant returns (uint256 leveragedOut) {
        MinterStorage storage $ = _getMinterStorage();
        _requireRecordsAreCovered($);
        // how much collateral to use
        (uint256 price, uint256 rate) = _fetchMid($.priceOracle);
        _requireLeveragedIssuable(_recordedBacking($), price, $.peggedTokenBalance);

        (uint256 collateralValueE36, uint256 peggedValueE36) = MinterValuationLib.tokenValuesE36(
            $.peggedTokenBalance,
            _recordedBacking($),
            price
        );
        uint256 underlyingCollateralInE36 = wrappedCollateralIn * rate;
        uint256 leveragedTokenBalance_ = _leveragedTokenBalance();
        // The leveraged token is a claim on the residual plus the escrow, so there must be a claim for a mint to
        // buy into. Left at zero, `_mintLeveragedToken` turns the caller away by name - matching the fee-paying
        // path, whose adjustments return zero in the same state.
        if (leveragedTokenBalance_ > 0) {
            // An issued leveraged token with nothing behind it is worth nothing, and nothing is not a price.
            uint256 leveragedPriceE36 = _leveragedTokenPriceE36(
                collateralValueE36,
                peggedValueE36,
                _escrow($),
                price,
                leveragedTokenBalance_
            );
            if (leveragedPriceE36 > 0) {
                leveragedOut = (underlyingCollateralInE36 * price) / leveragedPriceE36;
            }
        } else {
            // The first leveraged token issued takes the residual this deposit itself creates, so it is the balance
            // AFTER the deposit that must cover the pegged claim - which is why the test is not the one above. The
            // claim is taken unclamped: `tokenValuesE36` caps it at the collateral value, and the shortfall is the
            // point here.
            uint256 postDepositValueE36 = collateralValueE36 + Math.mulDiv(underlyingCollateralInE36, price, 1e18);
            uint256 peggedClaimE36 = $.peggedTokenBalance * 1e18;
            if (postDepositValueE36 > peggedClaimE36) {
                leveragedOut = (postDepositValueE36 - peggedClaimE36) / 1e18;
            }
        }

        // mint the tokens to the receiver
        _mintLeveragedToken(wrappedCollateralIn, leveragedOut, receiver);

        // update our records: the escrow follows the supply the mint has already raised, so nothing writes it.
        // What the deposit must do is hand over that much collateral, and add only the rest to the backing.
        uint256 underlyingCollateralIn = underlyingCollateralInE36 / 1e18;
        $.underlyingCollateral +=
            underlyingCollateralIn -
            _escrowTakenByAMint($, leveragedTokenBalance_, leveragedOut, underlyingCollateralIn);
    }

    // @inheritdoc IMinter
    function freeRedeemLeveragedToken(
        uint256 leveragedIn,
        address receiver
    ) external override onlyOwnerOrRoles(ZERO_FEE_ROLE) nonReentrant returns (uint256 collateralOut) {
        MinterStorage storage $ = _getMinterStorage();
        _requireRecordsAreCovered($);

        uint256 leveragedTokenBalance_ = _leveragedTokenBalance();
        leveragedIn = _redeemable(LEVERAGED_TOKEN, leveragedIn, leveragedTokenBalance_);

        (uint256 price, uint256 rate) = _fetchMin($.priceOracle);

        // Scoped so the two valuations are off the stack before the redemption's own locals arrive.
        uint256 claimE36;
        {
            (uint256 backing_, uint256 escrow_) = _recordedAccounts($);
            (uint256 collateralValueE36, uint256 peggedValueE36) = MinterValuationLib.tokenValuesE36(
                $.peggedTokenBalance,
                backing_,
                price
            );
            claimE36 = MinterValuationLib.leveragedClaimE36(collateralValueE36, peggedValueE36, escrow_, price);
        }
        if (claimE36 == 0) {
            collateralOut = 0;
        } else {
            uint256 underlyingCollateralOutE36;
            if (leveragedTokenBalance_ == 0) {
                underlyingCollateralOutE36 = leveragedIn * price;
            } else {
                underlyingCollateralOutE36 = Math.mulDiv(
                    leveragedIn * 1 ether,
                    claimE36,
                    price * leveragedTokenBalance_
                );
            }
            collateralOut = underlyingCollateralOutE36 / rate;

            _redeemLeveragedToken(leveragedIn, collateralOut, receiver);

            // update our records: the escrow follows the supply the redemption has already lowered, so nothing
            // writes it. What is left is to pay the holder that much out of the escrow, and only the rest out
            // of the backing.
            uint256 underlyingCollateralOut = underlyingCollateralOutE36 / 1 ether;
            $.underlyingCollateral -=
                underlyingCollateralOut -
                _escrowReleasedByARedeem($, leveragedTokenBalance_, leveragedIn, underlyingCollateralOut);
        }
    }

    ///////////////////////
    // Private functions //
    ///////////////////////

    /// @notice How much collateral a conversion moves from the account backing the pegged token into the escrow.
    /// @dev A conversion issues leveraged tokens without any collateral arriving, so the escrow that follows the
    /// new supply is MOVED out of the backing rather than taken from a deposit. That costs the conversion
    /// nothing: the leveraged claim is the residual PLUS the escrow, so shifting between the two leaves their
    /// sum alone, and with it the price and the rate this conversion was quoted at.
    ///
    /// It escrows as a mint would, and against the collateral the converted pegged would have redeemed for at
    /// the price the collateral leg settles at, because the two routes have to agree: redeeming that pegged and
    /// minting leveraged with the proceeds is open to anyone, and would escrow exactly that. That figure only
    /// decides anything where this conversion is opening the leveraged side of the market; after that the
    /// collateral escrowed per token is already set, and the move is that figure times the tokens issued.
    ///
    /// The move cannot lower the collateral ratio, so it needs no bound to say so. Writing `C` for the backing,
    /// `n` for the pegged supply and `a` for the pegged converted, the ratio is unharmed exactly while
    /// `move <= C x a / n`. The escrow's share of the claim is at most all of it, and the pegged redeems for at
    /// most its share of the backing, so the move is at most `a x C / n` by construction.
    ///
    /// @dev Its own function because the conversion's frame cannot hold these locals: inline, the compiler runs
    /// out of stack. Called once, for that reason and no other.
    function _conversionEscrowMove(
        MinterStorage storage $,
        uint256 peggedForLeveraged,
        uint256 leveragedOut,
        uint256 peggedTokenBalance_,
        uint256 underlyingCollateral_,
        uint256 price
    ) internal virtual returns (uint256) {
        return
            _escrowTakenByAMint(
                $,
                _leveragedTokenBalance(),
                leveragedOut,
                Math.mulDiv(
                    peggedForLeveraged,
                    MinterValuationLib.peggedTokenPriceE36(peggedTokenBalance_, underlyingCollateral_, price),
                    price
                ) / 1 ether
            );
    }

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

    /// @notice The recorded backing, as recorded.
    /// @dev It is NOT compared against the wrapped collateral the contract holds. Doing so would decide, on
    /// every read, that a fall in the wrapped-to-collateral rate is a real loss - and that is a judgement, not a
    /// reading. A market may be collateralised by an asset whose value falls and recovers as a matter of course,
    /// and only `recogniseImpairment` is entitled to say which has happened. Making the same judgement silently
    /// here as well put it in two places with two different permanences.
    function _recordedBacking(MinterStorage storage $) private view returns (uint256 backing) {
        backing = $.underlyingCollateral;
    }

    /// @notice The state a valuation is computed against, with both collateral accounts recognised together.
    /// @dev The ONLY way this struct is built. Its two collateral fields have to be floored against the same
    /// holding or they can between them account for more collateral than exists, and the adjustments library
    /// then values a claim against cover that is not there. Constructing it field by field at each call site is
    /// what allowed a raw escrow record to be paired with a recognised backing; there is now no site where that
    /// is possible.
    ///
    /// Do not be tempted to reach for a disallow band to make such a mispricing unreachable. The bands are
    /// per-market configuration and a market may carry none at all, so they bound what a PARTICULAR deployment
    /// permits and never what the arithmetic can produce.
    function _collateralRatioData(
        MinterStorage storage $,
        uint256 price,
        uint256 rate,
        uint256 peggedTokenBalance_,
        uint256 leveragedTokenBalance_
    ) private view returns (MinterValuationLib.CollateralRatioData memory cr) {
        (cr.underlyingCollateral, cr.leveragedCollateralEscrow) = _recordedAccounts($);
        cr.price = price;
        cr.rate = rate;
        cr.peggedTokenBalance = peggedTokenBalance_;
        cr.leveragedTokenBalance = leveragedTokenBalance_;
    }

    /// @notice Both collateral accounts as RECORDED: the backing the pegged token has a claim on, and the
    ///         collateral escrowed for the leveraged token.
    /// @dev Returned together because everything valuing the leveraged token's claim needs both - the claim is
    /// the residual of the backing PLUS the escrow - and taking them from one read keeps them talking about the
    /// same moment.
    ///
    /// Neither is compared against what the contract holds. See `_recordedBacking`: deciding that a fallen rate
    /// is a real loss belongs to `recogniseImpairment` and to nothing else.
    function _recordedAccounts(MinterStorage storage $) private view returns (uint256 backing, uint256 escrow) {
        backing = $.underlyingCollateral;
        escrow = _escrow($);
    }

    /// @notice Refuses to act while the two collateral records claim more collateral than the holding stands up.
    /// @dev Every path that CHANGES the records passes through here; nothing that only reports does. A view that
    /// marked itself down would be deciding, on every read, that a fallen rate is a real loss - the judgement
    /// `recogniseImpairment` exists to make and the reason `_recordedBacking` reports what is recorded. So the
    /// prices and ratios keep answering from the records, deliberately, and what protects the protocol is that
    /// nothing can act on them until someone has said whether the shortfall is real.
    ///
    /// The MIN rate is not merely the conservative edge here, it is forced. `recogniseImpairment` measures at
    /// the min rate and refuses when the records are not overstated, so reading the same edge makes this
    /// condition and that one the SAME condition: this reverts exactly when recognition would succeed, and
    /// never when recognition would refuse. Any other edge admits a market that is halted and cannot be
    /// unhalted, or one that is recognisable while it goes on trading against records nobody has stood behind.
    ///
    /// A harvest needs no call to this: it pays out only what the holding exceeds BOTH records by, so an
    /// overstatement leaves it reporting nothing. A donation needs none either, though for a different reason -
    /// it credits the record with exactly what the holding gains, so it can neither widen the shortfall nor
    /// close it, and a halted market stays halted however much is donated to it.
    function _requireRecordsAreCovered(MinterStorage storage $) private view {
        (uint256 backing, uint256 escrow) = _recordedAccounts($);
        uint256 recorded = backing + escrow;
        uint256 held = MinterValuationLib.wrappedAsCollateral(
            IERC20(WRAPPED_COLLATERAL_TOKEN).balanceOf(address(this)),
            _fetchMinRate($.priceOracle)
        );
        if (recorded > held) {
            revert UnrecognisedImpairment(recorded, held);
        }
    }

    /// @notice The collateral a mint hands to the escrow rather than to the backing, setting the per-token
    ///         figure first where this mint is opening the leveraged side of the market.
    /// @dev The escrow itself needs no write - it is the per-token figure times a supply this mint has already
    /// raised. All that is left is to take that much out of the deposit, so the two accounts sum to what arrived.
    ///
    /// Where there is no supply yet there is no per-token figure either, and this deposit sets it: a share of
    /// what it brings, spread over the tokens it issues. That is the ONLY moment the ratio is read, and the only
    /// moment this figure moves other than a recognised impairment. It is set BEFORE the escrow is computed so
    /// the two agree to the wei; deriving the escrow first and the figure from it would leave them a rounding
    /// apart, and the backing would take the difference.
    ///
    /// What the mint hands over is the DIFFERENCE the escrow function takes across the mint, not that function
    /// applied to the tokens minted. The escrow is `floor(e x supply)`, so a mint raises it by
    /// `floor(e x supplyAfter) - floor(e x supplyBefore)` - which is not `floor(e x minted)`, because a mint can
    /// carry a fraction the last one left behind over a whole number. Taking the difference makes the two
    /// records agree to the wei however the market got here: the moves telescope, so the collateral handed to
    /// the escrow over any run of mints is exactly the escrow those mints created.
    ///
    /// Rounding the product instead - either way - is what a separately-rounded figure costs, and both
    /// directions are wrong. Floored, the escrow claims a wei the backing still holds, once per mint and always
    /// in the same direction, until two records claim more collateral than ever arrived: what the impairment
    /// guard halts a market for. Ceiled, the backing overpays instead, which splitting a mint into pieces turns
    /// into a gain for the splitter - a wei of collateral is thousands of leveraged tokens where the leveraged
    /// token is cheap, which is exactly where it would be exploited.
    function _escrowTakenByAMint(
        MinterStorage storage $,
        uint256 leveragedTokenBalanceBefore,
        uint256 leveragedOut,
        uint256 underlyingCollateralIn
    ) internal virtual returns (uint256) {
        if (leveragedTokenBalanceBefore == 0 && leveragedOut > 0) {
            // The `1 ether` is the RATIO's own scale; the escrow's is not 1e18, and `_escrowAt` holds it.
            $.escrowPerLeveragedToken = Math.mulDiv(
                Math.mulDiv(underlyingCollateralIn, MinterValuationLib.LEVERAGED_ESCROW_RATIO, 1 ether),
                MinterValuationLib.ESCROW_PER_TOKEN_SCALE,
                leveragedOut
            );
        }
        uint256 escrowPerLeveragedToken_ = $.escrowPerLeveragedToken;
        uint256 escrowIn = _escrowAt(escrowPerLeveragedToken_, leveragedTokenBalanceBefore + leveragedOut) -
            _escrowAt(escrowPerLeveragedToken_, leveragedTokenBalanceBefore);
        return (escrowIn > underlyingCollateralIn) ? underlyingCollateralIn : escrowIn;
    }

    /// @notice The collateral a redemption pays out of the escrow rather than out of the backing.
    /// @dev The mirror of `_escrowTakenByAMint`, and writes nothing for the same reason: the escrow is the
    /// per-token figure times a supply the redemption has already lowered, so all that is left is to take that
    /// much of the payout off the escrow and only the rest off the backing. It is the DIFFERENCE the escrow
    /// function takes across the redemption, for the reason the mint takes a difference rather than a product.
    ///
    /// The redemption is paid out of a claim worth at least the escrow's share of it, so the share can exceed
    /// what is leaving only through rounding at the pole - where the residual is gone and the claim IS the
    /// escrow. Capped there so the backing is never asked for collateral it is not being handed.
    function _escrowReleasedByARedeem(
        MinterStorage storage $,
        uint256 leveragedTokenBalanceBefore,
        uint256 leveragedIn,
        uint256 underlyingCollateralOut
    ) internal view virtual returns (uint256) {
        uint256 escrowPerLeveragedToken_ = $.escrowPerLeveragedToken;
        uint256 escrowOut = _escrowAt(escrowPerLeveragedToken_, leveragedTokenBalanceBefore) -
            _escrowAt(escrowPerLeveragedToken_, leveragedTokenBalanceBefore - leveragedIn);
        return (escrowOut > underlyingCollateralOut) ? underlyingCollateralOut : escrowOut;
    }

    /// @notice The collateral standing behind a leveraged supply, at the stored per-token figure.
    /// @dev The one place that knows the escrow's scale, which is NOT the 1e18 used everywhere else: the figure is
    /// stored at `MinterValuationLib.ESCROW_PER_TOKEN_SCALE`, derived so that the ratio and the scale together
    /// carry the escrow to the declared precision at the dearest collateral supported.
    ///
    /// Floored, and always applied as a DIFFERENCE of two supplies by the callers rather than to a movement
    /// directly - so the moves telescope, and a mint split into pieces cannot escrow less than the same mint made
    /// whole.
    function _escrowAt(
        uint256 escrowPerLeveragedToken_,
        uint256 leveragedTokenBalance_
    ) internal pure returns (uint256) {
        return Math.mulDiv(escrowPerLeveragedToken_, leveragedTokenBalance_, MinterValuationLib.ESCROW_PER_TOKEN_SCALE);
    }

    /// @notice May leveraged be issued into the market as it stands? Reverts if not.
    /// @dev Called at EVERY point leveraged is minted - both retail mints and the conversion - before the
    /// tokens exist. Does nothing by default: this contract bounds leverage by its escrow, not by refusal. A
    /// rule that bounds it by refusing instead - declining to sell leverage above a maximum rather than
    /// selling a capped count - overrides this one function and throws `LeverageAboveCap`.
    ///
    /// THE STATE IS PASSED, NOT READ FROM STORAGE, and it is the state the caller priced its amounts against:
    /// the recorded backing, the price, and the pegged supply as they stood before the trade. A caller may have
    /// applied part of its trade to the record by the time it reaches the conversion - the redeem settles its
    /// collateral leg first - and a rule reading storage there would judge a market that never existed. The
    /// rule sees exactly what the pricing saw, whatever the caller has since written.
    ///
    /// It is a hook rather than a check in each caller because the three issuance sites must agree: a floor
    /// applied to the conversion and not to the retail mint is exactly the unevenness the deployed cap has,
    /// measured as the pool paid 0.204 where the hand route was paid 1.000. One function, three callers, no
    /// route left out.
    ///
    /// The parameters, in order: the recorded backing the issuance is priced against, the collateral price it
    /// is priced at, and the pegged supply it is priced against. Unnamed here because the base ignores them.
    // solhint-disable-next-line no-empty-blocks
    function _requireLeveragedIssuable(uint256, uint256, uint256) internal view virtual {}

    /// @notice The collateral escrowed for the leveraged token: the per-token figure times the supply.
    /// @dev Computed rather than stored, so it cannot drift from the supply it is meant to track. Nothing moves
    /// it: a mint, a redeem and a conversion change the supply and the escrow follows, which is what makes the
    /// collateral escrowed per token a constant of the market rather than an artefact of who traded recently.
    ///
    /// ESCROW RULE, PART 1 OF 5. Five functions together decide what the escrow is, when collateral moves
    /// into or out of it, and what the rebalance expects those moves to cost - this one derives the amount,
    /// `_escrowTakenByAMint`, `_escrowReleasedByARedeem` and `_conversionEscrowMove` decide the movements,
    /// and `_escrowedPerPegged` tells the rebalance's split what a conversion will drag. They are `virtual`
    /// so the rule can be stated in one place and varied as a unit: the alternatives differ in exactly these
    /// five and in nothing else, which is what makes two of them comparable.
    ///
    /// **A rule that overrides some and not others is wrong, and both halves of that have been measured.**
    /// Remove a movement while the derivation still multiplies a per-token figure by the supply, and issuing
    /// tokens inflates the escrow with nothing behind it - the records came to claim 20.199 against 20.000
    /// held, which is the condition every updating call is halted for. Remove a movement while
    /// `_escrowedPerPegged` still promises the drag, and the rebalance solves for a burn the conversion does
    /// not deliver - it liquidated the entire pool at every collateral ratio below the peg.
    ///
    /// Whatever a rule does, it must leave the two records summing to no more than the holding, because that
    /// is the condition every updating call is checked against.
    function _escrow(MinterStorage storage $) internal view virtual returns (uint256) {
        return _escrowAt($.escrowPerLeveragedToken, _leveragedTokenBalance());
    }

    /// @notice What the two records would be if the collateral standing behind them were taken as the truth.
    /// @dev The recognition itself, and used by `recogniseImpairment` alone. The records are collateral-token
    /// quantities while the contract holds the wrapped token, so a fall in the rate leaves them claiming more
    /// collateral than the holding converts to; this is what they become when that fall is judged real.
    ///
    /// Both records fall by the SAME FRACTION, because they are two claims on one pool of wrapped tokens and
    /// an impairment devalues every token in it. The escrow is not a segregated pile of coins that could keep
    /// its value while the backing's lost theirs; it is a number describing a claim on the same holding.
    ///
    /// Paying the escrow first would make it senior to the pegged token - backwards from every other statement
    /// the design makes, and total at the extreme: once the holding falls below the escrow, escrow-first hands
    /// it the entire remainder and writes the pegged token's backing to nothing. It would also make the whole
    /// distressed range unmeasurable, every collateral ratio there reporting zero.
    ///
    /// The floor therefore falls with the collateral it is made of, which is the same reasoning that
    /// denominates `LEVERAGED_ESCROW_RATIO` in collateral: a floor promised through a crash would have to GROW
    /// exactly when the collateral it is funded from was worth less, and nothing could fund that.
    ///
    /// Both products are FLOORED, so the two together can only come in under the holding, never over it. That
    /// direction is what the impairment guard rests on: records summing above the holding would leave a market
    /// halted that this very call is supposed to unhalt.
    ///
    /// The min rate decides: the conservative edge writes the records down hardest, so the band's width is never
    /// spent claiming cover that may not be there.
    /// @param underlyingCollateral_ The recorded backing.
    /// @param leveragedCollateralEscrow_ The recorded escrow.
    /// @param minRate The min wrapped-to-collateral rate.
    function _accountsAsHeld(
        uint256 underlyingCollateral_,
        uint256 leveragedCollateralEscrow_,
        uint256 minRate
    ) private view returns (uint256 backing, uint256 escrow) {
        uint256 held = MinterValuationLib.wrappedAsCollateral(
            IERC20(WRAPPED_COLLATERAL_TOKEN).balanceOf(address(this)),
            minRate
        );
        uint256 recorded = underlyingCollateral_ + leveragedCollateralEscrow_;
        // Covered, so nothing is written down - and the early return is also what keeps the division below
        // from meeting a zero denominator, records of nothing being covered by any holding at all.
        if (recorded <= held) {
            return (underlyingCollateral_, leveragedCollateralEscrow_);
        }
        backing = Math.mulDiv(underlyingCollateral_, held, recorded);
        escrow = Math.mulDiv(leveragedCollateralEscrow_, held, recorded);
    }

    /// @notice Returns the amount of leveraged tokens being managed
    function _leveragedTokenBalance() internal view returns (uint256) {
        return IERC20(LEVERAGED_TOKEN).totalSupply();
    }

    // fetching collateral price in terms of the pegged tokens
    // -------------------------------------------------------

    /// @notice Reads the oracle.
    /// @dev The readings are not checked here, because the oracle does not hand out a zero. Its feed refuses a
    /// reading that is stale, negative or zero, and its rate libraries refuse a rate at or below zero or outside
    /// the band configured for it, so it either answers with positive numbers or reverts by name. Checking again
    /// would restate a guarantee the source already gives, in a contract with little room to spare.
    ///
    /// That holds for every collateral, a leveraged token included. Such a token used to be able to reach zero -
    /// at a collateral ratio of one the residual is gone and the claim with it - and the aggregator pricing it
    /// documented that zero as a value rather than a fault. The collateral escrowed for it has since put a floor
    /// under the price, so no product this protocol issues is worth nothing while any of it exists, and a zero
    /// from anywhere is a broken source rather than a market state.
    function _latestAnswer(
        address priceOracle_
    ) private view returns (uint256 minPrice, uint256 maxPrice, uint256 minRate, uint256 maxRate) {
        (minPrice, maxPrice, minRate, maxRate) = IWrappedPriceOracle(priceOracle_).latestAnswer();
    }

    /// @notice Returns the mid collateral price and the mid wrapped-to-underlying rate.
    /// @dev The oracle reports each value as a band; the mid is the rounded average of the band's two edges. Both
    /// readings are validated, since every caller of this variant consumes both.
    function _fetchMid(address priceOracle_) private view returns (uint256 price, uint256 rate) {
        (uint256 minPrice, uint256 maxPrice, uint256 minRate, uint256 maxRate) = _latestAnswer(priceOracle_);
        price = MinterValuationLib.round(minPrice + maxPrice, 2);
        rate = MinterValuationLib.round(minRate + maxRate, 2);
    }

    /// @notice Returns the low edge of the collateral price band and of the rate band.
    /// @dev Paired with `_fetchMax`: each flow reads whichever edge is the conservative one for its own direction,
    /// so the band's width is never spent in the user's favour. Both readings are validated, since every caller of
    /// this variant consumes both.
    function _fetchMin(address priceOracle_) private view returns (uint256 price, uint256 rate) {
        // slither-disable-next-line unused-return
        (price, , rate, ) = _latestAnswer(priceOracle_);
    }

    /// @notice Returns the high edge of the collateral price band and of the rate band.
    /// @dev The counterpart to `_fetchMin`, chosen by the same rule. Both readings are validated, since every caller
    /// of this variant consumes both.
    function _fetchMax(address priceOracle_) private view returns (uint256 price, uint256 rate) {
        // slither-disable-next-line unused-return
        (, price, , rate) = _latestAnswer(priceOracle_);
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
        (, , rate, ) = _latestAnswer(priceOracle_);
    }

    /// @notice Returns the mid price for the collateral token, for callers that do not consume the rate.
    /// @dev Checks the price readings only - the mirror of `_fetchMinRate`. A reading the caller never looks at
    /// cannot invalidate its answer, so a faulty rate must not stop a purely price-based view from reporting.
    function _fetchMidPrice(address priceOracle_) private view returns (uint256 price) {
        // slither-disable-next-line unused-return
        (uint256 minPrice, uint256 maxPrice, , ) = _latestAnswer(priceOracle_);
        price = MinterValuationLib.round(minPrice + maxPrice, 2);
    }

    /// @notice Returns the high edge of the collateral price band, for callers that do not consume the rate.
    /// @dev Checks the price readings only, as `_fetchMidPrice` does.
    function _fetchMaxPrice(address priceOracle_) private view returns (uint256 price) {
        // slither-disable-next-line unused-return
        (, price, , ) = _latestAnswer(priceOracle_);
    }

    // Harvesting support
    // -------------------------------------------------------
    /// @notice function used to control access to the sweep function for extracting harvestable amounts
    function _checkSweeper() internal view override(TokenHolder_v2) {
        _checkOwnerOrRoles(HARVESTER_ROLE);
    }
}
