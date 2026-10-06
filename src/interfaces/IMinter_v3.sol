// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

import {IToken} from "@bao/interfaces/IToken.sol";

/// @notice Minter v3
/// @author rootminus0x1 based on (albeit significantly modified) Aladdin's FX system
/// @notice Provides an interface for minting and redeeming pegged and leveraged tokens, some with fees, others without.
///
/// For the fee'd fuctions equivalent "dry run" functions are available that could allow a user to know what
/// fees, subsidies, etc. are expected (modulo slippage). This id designed for a user interface to use.
///
/// Configuration functions are available such as for allowing setting of:
/// * the fee/subsidy/disallow configuration
/// * the collateral ratio that rebalancing can start
/// * the price oracle and rate (for wrapped) of the collateral
/// * the fee receiver and subsidy provider (reserve pool)
///
/// Various queries are provided such as:
/// * the net asset values of the tokens,
/// * leverage ratio of the leveraged tokens
/// * collateral ratio of the system

/// differences to interface IMinter:
/// * fee-capped minting
/// * absolute-amount fee queries in pegged space (removal of uncapped queries, can make the same call passing "0,0")
// solhint-disable-next-line contract-name-capwords
interface IMinter_v3 is IToken {
    /*//////////////////////////////////////////////////////////////
                           DATA STRUCTURES
    //////////////////////////////////////////////////////////////*/

    struct IncentiveConfig {
        // note: incentive ratios have one more entry than the band bounds do
        // the boundaries of the collateral ratio where the incentive ratios apply
        // must be strictly increasing at the precision of 18 decimals
        uint256[] collateralRatioBandUpperBounds;
        // incentive ratios for the above bands , interval (-1 ether, 1 ether]
        // positive = fee ratio, negative for subsidy, == 1 ether disallow
        // any 1 ether values must be at index 0
        // no negative values are allowed in the highest band
        int256[] incentiveRatios;
    }
    struct Config {
        // fees/subsidies
        IncentiveConfig mintPeggedIncentiveConfig;
        IncentiveConfig redeemPeggedIncentiveConfig;
        // leverage tokens have their own intrinsic value in that they increase in leverage the lower the collateral
        // ratio, so there is a convenient intrinsic incentive to mint at low collateral ratios
        IncentiveConfig mintLeveragedIncentiveConfig;
        IncentiveConfig redeemLeveragedIncentiveConfig;
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when peggedToken is minted.
    /// @param sender The address of collateral token owner.
    /// @param receiver The address of receiver for peggedToken or leveragedToken.
    /// @param collateralIn The amount of collateral token deposited.
    /// @param peggedOut The amount of peggedToken minted.
    event MintPeggedToken(address indexed sender, address indexed receiver, uint256 collateralIn, uint256 peggedOut);

    /// @notice Emitted when leveragedToken is minted.
    /// @param sender The address of collateral token owner.
    /// @param receiver The address of receiver for peggedToken or leveragedToken.
    /// @param collateralIn The amount of collateral token deposited.
    /// @param leveragedOut The amount of leveragedToken minted.
    event MintLeveragedToken(
        address indexed sender,
        address indexed receiver,
        uint256 collateralIn,
        uint256 leveragedOut
    );

    /// @notice Emitted when someone redeems a peggedToken .
    /// @param sender The address of peggedToken owner.
    /// @param receiver The address of receiver for collateral and leveraged token.
    /// @param peggedTokenBurned The amount of peggedToken burned.
    /// @param collateralOut The amount of collateral token redeemed.
    /// @param leveragedOut The amount of leveraged token redeemed
    event RedeemPeggedToken(
        address indexed sender,
        address indexed receiver,
        uint256 peggedTokenBurned,
        uint256 collateralOut,
        uint256 leveragedOut
    );

    /// @notice Emitted when someone redeem collateral token with peggedToken or leveragedToken.
    /// @param sender The address of peggedToken and leveragedToken owner.
    /// @param receiver The address of receiver for collateral token.
    /// @param leveragedTokenBurned The amount of leveragedToken burned.
    /// @param collateralOut The amount of collateral token redeemed.
    event RedeemLeveragedToken(
        address indexed sender,
        address indexed receiver,
        uint256 leveragedTokenBurned,
        uint256 collateralOut
    );

    /// @notice Emitted when collateral is given to the protocol as backing rather than as yield.
    /// @param donor The address that supplied the collateral.
    /// @param wrappedAmount The wrapped collateral supplied.
    /// @param collateralAdded The collateral tokens it was worth, and by which the backing rose.
    /// @param backing The recorded backing after the donation.
    event DonateWrappedCollateral(
        address indexed donor,
        uint256 wrappedAmount,
        uint256 collateralAdded,
        uint256 backing
    );

    /// @notice Emitted when the recorded backing is written down to the collateral actually held.
    /// @param previousBacking The recorded backing before the write-down.
    /// @param recognisedBacking The collateral held, converted at the min rate, which the record becomes.
    event RecogniseImpairment(uint256 previousBacking, uint256 recognisedBacking);

    /// @notice Emitted whenever the config is updated.
    event UpdateConfig(Config newConfig);

    /// @notice Emitted when the fee receiving contract is updated.
    /// @param oldFeeReceiver The address of previous fee receiving contract.
    /// @param newFeeReceiver The address of the new (current) fee receiving contract.
    event UpdateFeeReceiver(address indexed oldFeeReceiver, address indexed newFeeReceiver);

    /// @notice Emitted when the platform contract is updated.
    /// @param oldReservePool The address of previous reserve pool contract.
    /// @param newReservePool The address of new (current) reserve pool contract.
    event UpdateReservePool(address indexed oldReservePool, address indexed newReservePool);

    /// @notice Emitted when the price oracle contract is updated.
    /// @param oldPriceOracle The address of previous price oracle contract.
    /// @param newPriceOracle The address of current price oracle contract.
    event UpdatePriceOracle(address indexed oldPriceOracle, address indexed newPriceOracle);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error RequestedSubsidyNotGiven(uint256 requested, uint256 available);

    /// @dev Thrown when collateral is passed but minting is prevented for some other reason.
    error MintZeroAmount(address mintingToken);
    /// @dev Thrown when collateral is passed but minting is reduced below the minimum requested.
    error MintInsufficientAmount(address mintingToken, uint256 actual, uint256 minimum);
    /// @dev Thrown when pegged or leveraged is passed but redeeming is prevented for some other reason.
    error ReturnZeroAmount(address returningToken);
    /// @dev Thrown when pegged or leveraged is passed but redeeming is reduced below the minimum requested.
    error ReturnInsufficientAmount(address returningToken, uint256 actual, uint256 minimum);
    error NoRedeemableTokens(address redeemingToken);

    /// @dev Thrown when recognising an impairment would change nothing, the record not exceeding the holding.
    error NothingToRecognise(uint256 backing);

    /// @dev Thrown when an operation would act on a collateral record that claims more than the holding stands up,
    /// the difference not having been recognised. Reports what is recorded and what is held, both in collateral
    /// tokens at the conservative rate, and says nothing about why they differ - whether the shortfall is a
    /// permanent loss or a dip that will reverse is the judgement `recogniseImpairment` exists to make, and that
    /// call, or the rate recovering, is what clears this.
    error UnrecognisedImpairment(uint256 recorded, uint256 held);

    /// @dev Thrown where the market's collateral ratio, judged against the min CR `MINIMUM_COLLATERAL_RATIO`, does not
    /// allow a mint. A leveraged mint from below it would sell leverage above the cap (`beta = CR/(CR-1)`, so a cap
    /// `K` is a min CR of `K/(K-1)`); a retail pegged mint from at or below it could only take the market further
    /// below; a zero-fee leveraged mint may not leave the market below it. Reports the ratio judged - before the
    /// trade for the retail mints and the conversion, after it for the zero-fee leveraged mint - and the minimum,
    /// so a caller turned away knows by how much.
    error BelowMinimumCollateralRatio(uint256 collateralRatio, uint256 minimumCollateralRatio);

    /// @dev Thrown when a pegged token is worth nothing - no collateral stands behind an outstanding supply - so an
    /// operation priced against that value has no answer.
    error ZeroPeggedTokenPrice();

    error InvalidCollateralRatioBoundValue(string config, uint256 value, uint index, string reason); // solhint-disable-line explicit-types
    error CollateralRatioBoundValueNotIncreasing(
        string config,
        uint256 bound,
        uint index, // solhint-disable-line explicit-types
        uint256 previousBound
    );
    error TooManyIncentiveRatios(string config, uint count, uint max); // solhint-disable-line explicit-types
    error TooFewIncentiveRatios(string config, uint count, uint min); // solhint-disable-line explicit-types
    error InvalidIncentiveRatioValue(string config, uint index, int256 value, string reason); // solhint-disable-line explicit-types
    error IncentiveRatioTooPrecise(string config, int256 value);
    error CollateralRatioBoundsIncentivesLengthsMismatch(string config, uint256 boundCount, uint256 ratioCount);
    error CollateralRatioBoundTooPrecise(string config, uint256 value);
    error NoDepegBoundaryOrDisallow(string config);

    /*//////////////////////////////////////////////////////////////
                         PUBLIC READ FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice returns the role needed to access the zero fee functions (free*)
    // solhint-disable-next-line func-name-mixedcase
    function ZERO_FEE_ROLE() external view returns (uint256);

    /// @notice returns the role needed to access the harvesting function
    // solhint-disable-next-line func-name-mixedcase
    function HARVESTER_ROLE() external view returns (uint256);

    /// @notice returns the role that, with the owner and the zero-fee role, may donate wrapped collateral as backing
    // solhint-disable-next-line func-name-mixedcase
    function DONOR_ROLE() external view returns (uint256);

    /// @notice Return the address of the collateral token
    // solhint-disable-next-line func-name-mixedcase
    function WRAPPED_COLLATERAL_TOKEN() external view returns (address);

    /// @notice Return the address of the pegged token.
    // solhint-disable-next-line func-name-mixedcase
    function PEGGED_TOKEN() external view returns (address);

    /// @notice Return the address of the leveraged token.
    // solhint-disable-next-line func-name-mixedcase
    function LEVERAGED_TOKEN() external view returns (address);

    /// @notice Return the current config.
    function config() external view returns (Config memory);

    /// @notice Return the current collateral ratio of the system (18 decimals).
    /// This is the raw ratio of (collateral value) / (pegged token balance) without any flooring.
    /// When the system is depegged (ratio < 1), this function will return the actual value below 1.
    ///
    /// Special cases:
    /// - If both collateral and pegged tokens are zero: Returns 1 ether (to avoid discontinuity when first minting)
    /// - If pegged tokens are zero but collateral exists: Returns 1 ether * 1 ether, encoding +infinity
    /// - A zero collateral price gives a ratio of zero. A conforming oracle reverts rather than answer when it
    ///   cannot price, so a zero it returns is the price, and the ratio reports it as such.
    ///
    /// This value is used for critical system operations like rebalancing, especially in depegged scenarios.
    /// For the real market value of the pegged token, see peggedTokenPrice() instead.
    function collateralRatio() external view returns (uint256);

    /// @notice The leverage of the leveraged token at the ratio the market stands at, 1e18-scaled: how many
    ///         percent the token moves for one percent of the collateral. A leveraged token is a claim on the
    ///         residual, so this is `CR / (CR - 1)` - reported as it is, uncapped, since a holder's leverage
    ///         rises as the collateral falls and that is what the token is for. `type(uint256).max` where the
    ///         residual is gone, encoding a claim of nothing. What is bounded is the leverage SOLD - see
    ///         `MAX_LEVERAGE_RATIO`.
    function leverageRatio() external view returns (uint256);

    /// @notice The most leverage this market will sell, 1e18-scaled. A cap on the leverage of every leveraged
    ///         token at the moment it is minted, applied by minting none below `MINIMUM_COLLATERAL_RATIO`: the
    ///         retail mint, the conversion a rebalance performs and the zero-fee mint all revert where the market
    ///         stands below it. The one mint judged on the market it leaves instead is the zero-fee mint of a
    ///         market's first leveraged tokens, where no leveraged holder exists: that is how a genesis opens a
    ///         market, and it reverts where it would leave the market below the min CR.
    function MAX_LEVERAGE_RATIO() external view returns (uint256); // solhint-disable-line func-name-mixedcase

    /// @notice The min CR: `K / (K - 1)` for `K = MAX_LEVERAGE_RATIO`, rounded up to its 1e18 scale - the lowest
    ///         collateral ratio at which the residual's sensitivity to the collateral price is no more than the
    ///         cap. Since that sensitivity is `CR / (CR - 1)`, `beta <= K` if and only if `CR >= K / (K - 1)`, so
    ///         minting no leveraged below this collateral ratio bounds the leverage of every token ever sold
    ///         without capping a count or moving any collateral. Below it the market is closed to retail mints of
    ///         pegged as well, which would lower the ratio further: a retail pegged mint reverts at or below it and
    ///         is cut where it would cross it, whatever the incentive config allows. A market with no collateral
    ///         and no pegged reads a collateral ratio of exactly one, so no retail mint can open it.
    function MINIMUM_COLLATERAL_RATIO() external view returns (uint256); // solhint-disable-line func-name-mixedcase

    /// @notice Whether a retail leveraged mint, or a rebalance's conversion, is served at the ratio the market
    ///         stands at: true at or above `MINIMUM_COLLATERAL_RATIO` and false below it, whether or not any
    ///         leveraged token exists yet. Where it is false those calls revert `BelowMinimumCollateralRatio`;
    ///         this is the same judgement as a view, for a caller that would rather not ask by trying. It is the
    ///         zero-fee leveraged mint's judgement too wherever leveraged tokens exist. Where none exist that mint
    ///         is judged on the market it leaves instead, so it may be served where this is false.
    function leveragedMintable() external view returns (bool);

    /// @notice Return the price of a leveraged token in terms of the pegged token's underlying (18 decimals).
    /// The leveraged token holds the residual: the collateral value left once every pegged token is covered.
    ///
    /// Zero is a real answer, and a common one. The pegged claim is capped at the collateral value, so the residual
    /// is exactly zero at any collateral ratio at or below 1 - an ordinary depeg, not an extreme one - and stays
    /// zero just above 1 while the residual per leveraged token is under a wei. A consumer valuing a holding from
    /// this getter values it at nothing there, which is what the holding is worth.
    ///
    /// Unavailability arrives out of band, as a revert, and that guarantee belongs to the price oracle rather than
    /// to the Minter: `latestAnswer()` hands over four numbers and no metadata, so the Minter cannot tell a stale
    /// reading from a fresh one, and a conforming oracle reverts rather than answer when it cannot price. The Minter
    /// passes on what the oracle returns, a zero price included, without judging it.
    ///
    /// So a zero here means "worth nothing", never "cannot tell", and the two must not be conflated by anything
    /// reading it.
    ///
    /// With no leveraged tokens outstanding the price is 1 ether by definition.
    function leveragedTokenPrice() external view returns (uint256);

    /// @notice Return the price of a pegged token in terms of the pegged token's underlying (18 decimals).
    /// this should normally be 1 ether but if the token depegs then this number will be this token's share of the
    /// collateral - exactly min(1 ether, collateralRatio()).
    ///
    /// Zero is a real answer here too, but a far rarer one than for the leveraged token. A depeg gives a fractional
    /// price: at a collateral ratio of 0.98 this reports 0.98. Zero needs the ratio to underflow 18 decimal places,
    /// meaning the collateral behind the outstanding supply is worth essentially nothing against it. A consumer
    /// summing this into a total values that holding at nothing, so one that must not do so silently should treat
    /// zero as a halt condition rather than a valuation.
    ///
    /// The same split holds as for leveragedTokenPrice(): a conforming oracle reverts rather than answer when it
    /// cannot price, and the Minter passes on whatever it returns.
    ///
    /// With no pegged tokens outstanding the price is 1 ether by definition, without reading the oracle at all.
    function peggedTokenPrice() external view returns (uint256);

    /// @notice The pegged to redeem for collateral and for leveraged to reach `targetCollateralRatio`, with the split
    ///         already fitted to each pool's solvency headroom. Redeeming `peggedForCollateral` for wrapped collateral
    ///         AND `peggedForLeveraged` for leveraged tokens moves the collateral ratio to the target - or, if both
    ///         pools' headrooms are exhausted, as close as the stability pools can. A pool whose proportional share
    ///         exceeds its headroom is capped there and the shortfall slides along the target-ratio line into the
    ///         co-pool's leg (each leg still redeemed for its own token). The unconstrained `redeemPeggedForCollateralRatio`
    ///         is this with no caps and no holdings (returning the two line intercepts).
    /// @param targetCollateralRatio The collateral ratio to reach (1e18-scaled).
    /// @param maxCollateralPegged The most pegged the collateral pool may give up (its `maxAssetLoss` headroom).
    /// @param maxLeveragedPegged The most pegged the leveraged pool may give up (its `maxAssetLoss` headroom).
    /// @param holdingCollateral The collateral pool's supply - its deposits, never the pegged it holds - weighting its
    ///        share of the unconstrained split.
    /// @param holdingLeveraged The leveraged pool's supply - its deposits, never the pegged it holds - weighting its
    ///        share of the unconstrained split.
    /// @return peggedForCollateral The pegged to redeem for wrapped collateral (<= maxCollateralPegged).
    /// @return peggedForLeveraged The pegged to redeem for leveraged tokens (<= maxLeveragedPegged).
    function redeemPeggedForCollateralRatio(
        uint256 targetCollateralRatio,
        uint256 maxCollateralPegged,
        uint256 maxLeveragedPegged,
        uint256 holdingCollateral,
        uint256 holdingLeveraged
    ) external view returns (uint256 peggedForCollateral, uint256 peggedForLeveraged);

    /// @notice Returns the address of the price oracle contract
    function priceOracle() external view returns (address);

    /// @notice Returns the address of the reserve pool contract that provides the collateral for subsidies
    function reservePool() external view returns (address);

    /// @notice Returns the address of the fee receiver contract
    function feeReceiver() external view returns (address);

    /// @notice Returns the totalAmount of pegged tokens minted, and not redeemed, by the minter
    function peggedTokenBalance() external view returns (uint256);

    /// @notice Returns the totalAmount of leveraged tokens minted, and not redeemed, by the minter
    /// This number is the same as the totelSupply of the leveraged token
    function leveragedTokenBalance() external view returns (uint256);

    /// @notice Returns the totalAmount of collateral tokens received in exchange for pegged and leveraged tokens
    /// (18 decimals)
    function collateralTokenBalance() external view returns (uint256);

    /// @notice Returns the current instantaneous incentive ratio for minting pegged tokens (18 decimals).
    /// A positive number is a fee ratio; a negative number indicates a subsidy.
    function mintPeggedTokenIncentiveRatio() external view returns (int256 incentiveRatio);

    /// @notice Returns the current instantaneous incentive ratio for redeeming pegged tokens (18 decimals).
    /// A positive number is a fee ratio; a negative number indicates a subsidy.
    function redeemPeggedTokenIncentiveRatio() external view returns (int256 incentiveRatio);

    /// @notice Returns the current instantaneous incentive ratio for minting leveraged tokens (18 decimals).
    /// A positive number is a fee ratio; a negative number indicates a subsidy.
    function mintLeveragedTokenIncentiveRatio() external view returns (int256 incentiveRatio);

    /// @notice Returns the current instantaneous incentive ratio for redeeming leveraged tokens (18 decimals).
    /// A positive number is a fee ratio; a negative number indicates a subsidy.
    function redeemLeveragedTokenIncentiveRatio() external view returns (int256 incentiveRatio);

    /// @notice Returns values that will be used if an actual `mintPeggedToken` function call is made.
    /// This function is useful to give a user an indication of the actual transfers that would occur if the function
    /// was to be called.
    ///
    /// ┌──────┐                         ┌────────┐                      ┌──────────┐
    /// │ user │ ─── collateralTaken ──► │ minter │ ─────── fee ───────► │ fee      │
    /// │      │ ◀════ peggedMinted ════ │        │ (only +ve, i.e. fee) │ receiver │
    /// └──────┘                         └────────┘                      └──────────┘
    ///                                       │
    ///                       collateral held += collateralTaken - fee
    ///
    /// @param collateralIn The amount of wrapped collateral to be exchanged for pegged tokens.
    /// @return incentiveRatio the effective incentive ratio for `collateralIn` collateral tokens. A positive number is
    /// a fee ratio; a negative number indicates a subsidy.
    /// @return fee The amount deducted from `collateralIn` as a fee.
    /// @return collateralTaken The amount of collateral used in the exchange.
    /// This is usually the same as `collateralIn`, but a mint is cut where the collateral ratio would cross
    /// `MINIMUM_COLLATERAL_RATIO`, or reach a band the configuration disallows minting in. None is taken where the
    /// market stands at or below `MINIMUM_COLLATERAL_RATIO`, or from an offer too small to buy a whole pegged token -
    /// both of which the call reverts for: the fee is then zero and the incentive ratio the band's.
    /// @return peggedMinted The amount of pegged tokens that would be minted, given the 'collateralTaken' value and 'fee'.
    /// @return price The price of collateral in terms of pegged tokens used in the calculations.
    /// @return rate The conversion rate from underlying collateral to wrapped collateral.
    function mintPeggedTokenDryRun(
        uint256 collateralIn
    )
        external
        view
        returns (
            int256 incentiveRatio,
            uint256 fee,
            uint256 collateralTaken,
            uint256 peggedMinted,
            uint256 price,
            uint256 rate
        );

    /// @notice Returns values that will be used if an actual `redeemPeggedToken` function call is made.
    ///                                                                 ┌──────────────┐
    /// ┌──────┐                           ┌────────┐               ┌─► │ fee receiver │
    /// │ user │ ════ peggedRedeemed ════▶ │ minter │ ───── fee ────┘   └──────────────┘
    /// │      │ ◄── collateralReturned ── │        │ ◄── subsidy ──┐   ┌──────────────┐
    /// └──────┘  (including any subsidy)  └────────┘               └── │ reserve pool │
    ///                                         │                       └──────────────┘
    ///            collateral held -= collateral value of peggedRedeemed - fee
    ///
    /// @param peggedIn The amount of pegged token to be redeemed.
    /// @return incentiveRatio the effective incentive ratio for `peggedIn` pegged tokens.  A positive number is a fee
    /// ratio; a negative number indicates a subsidy. This is the theoretic value.
    /// @return fee The amount deducted in wrapped collateral from 'peggedIn' as a fee.
    /// @return subsidy The amount in wrapped collateral added to 'collateralReturned' taken from the reserve pool.
    /// This takes into account the possibility the reserve pool may be exhausted by this action.
    /// @return peggedRedeemed The amount of pegged tokens that would be redeemed.
    /// @return wrappedCollateralReturned The amount of collateral returned to the caller including from the reserve pool (if a subsidy has been configured)
    /// @return price is the price of collateral in terms of pegged tokens used in the calculations.
    /// @return rate The conversion rate from underlying collateral to wrapped collateral.
    function redeemPeggedTokenDryRun(
        uint256 peggedIn
    )
        external
        view
        returns (
            int256 incentiveRatio,
            uint256 fee,
            uint256 subsidy,
            uint256 peggedRedeemed,
            uint256 wrappedCollateralReturned,
            uint256 price,
            uint256 rate
        );

    /// @notice Returns values that will be used if an actual `mintLeveragedToken` function call is made.
    /// Where the call would revert `BelowMinimumCollateralRatio` - below `MINIMUM_COLLATERAL_RATIO`, see
    /// `leveragedMintable` - it reports that nothing would be minted: every amount zero, and the incentive ratio of
    /// the band the market sits in, as it reports wherever nothing would be used.
    /// @param collateralIn The amount of collateral to be exchanged for leveraged tokens.
    /// @return incentiveRatio the effective incentive ratio for `collateralIn` collateral tokens. A positive number is
    /// a fee ratio; a negative number indicates a subsidy.
    /// @return fee The amount deducted from 'collateralIn' as a fee.
    /// @return subsidy The amount in wrapped collateral added to 'leverageMinted' taken from the reserve pool.
    /// This takes into account the possibility the reserve pool may be exhausted by this action.
    /// @return collateralUsed The amount of collateral used in the exchange.
    /// @return leveragedMinted The amount of leveraged tokens that would be minted. This takes into account the subsidy applied.

    function mintLeveragedTokenDryRun(
        uint256 collateralIn
    )
        external
        view
        returns (
            int256 incentiveRatio,
            uint256 fee,
            uint256 subsidy,
            uint256 collateralUsed,
            uint256 leveragedMinted,
            uint256 price,
            uint256 rate
        );

    /// @notice Returns values that will be used if an actual `redeemLeveragedToken` function call is made.
    /// @param leveragedIn The amount of pegged token to be redeemed.
    /// @return incentiveRatio the effective incentive ratio for `leveragedIn` pegged tokens.  A positive number is a
    /// fee ratio; a negative number indicates a subsidy.
    /// @return fee The amount deducted from the returned collateral as a fee.
    /// @return leveragedRedeemed The amount of leveraged tokens that would be redeemed.
    /// This could be limited (some or all redeeming being disallowed) by configuration
    /// @return collateralReturned The amount of collateral returned from the reserve pool and passed to the caller.
    /// @return price is the price of collateral in terms of pegged tokens used in the calculations.
    /// @return rate The conversion rate from underlying collateral to wrapped collateral.
    function redeemLeveragedTokenDryRun(
        uint256 leveragedIn
    )
        external
        view
        returns (
            int256 incentiveRatio,
            uint256 fee,
            uint256 leveragedRedeemed,
            uint256 collateralReturned,
            uint256 price,
            uint256 rate
        );

    /// @notice Returns value accrued, and thus harvestable, by holding wrapped collateral tokens as opposed to underlying
    /// @dev The holding's surplus over the recorded backing, valued at the min rate. The wrapped the record needs is
    /// rounded up, so sweeping all of this leaves the holding still covering the record: a harvest can never leave the
    /// market halted by `UnrecognisedImpairment`.
    /// @return wrappedAmount the amount of wrapped collateral that can be distributed as rewards.
    function harvestable() external view returns (uint256 wrappedAmount);

    /// @notice The recorded backing and what the holding converts to, the two figures every updating call compares.
    /// @dev The market is impaired, and every updating call reverts `UnrecognisedImpairment`, exactly when
    /// `recorded > held`; that lasts until the rate recovers or `recogniseImpairment` writes the record down.
    /// The holding is valued at the min rate, the one recognition uses, so this reports an impairment exactly
    /// when recognition would succeed.
    ///
    /// The mirror of `harvestable`: that is the holding's surplus over the record, in wrapped tokens; this exposes
    /// its shortfall under it, in collateral tokens. The two are never both non-zero, and both are zero when the
    /// holding exactly covers the record.
    /// @return recorded The recorded backing, in collateral tokens.
    /// @return held The wrapped collateral held, converted to collateral tokens at the min rate.
    function impairment() external view returns (uint256 recorded, uint256 held);

    /*//////////////////////////////////////////////////////////////
                        PUBLIC UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Mint some pegged tokens in exchange for collateral tokens.
    /// @dev Reverts `BelowMinimumCollateralRatio` where the market stands at or below `MINIMUM_COLLATERAL_RATIO`,
    /// and takes only as much of the offer as brings the collateral ratio down to it - or to a band the
    /// configuration disallows minting in, if that is higher - leaving the rest with the caller.
    /// @param collateralIn The amount of wrapped value of collateral token supplied.
    /// @param receiver The address of receiver for peggedToken.
    /// @param minPeggedOut The minimum amount of peggedToken should be received. 0 means no check is made.
    /// @return peggedOut The amount of peggedToken should be received.
    function mintPeggedToken(
        uint256 collateralIn,
        address receiver,
        uint256 minPeggedOut
    ) external returns (uint256 peggedOut);

    /// @notice Mint pegged tokens whose fee, taken as a ratio of the collateral actually USED, stays
    /// within maxFeeRatio. Takes only as much of the offer as that allows: the amount offered does not
    /// buy a proportional fee budget to spend on a smaller amount at a steeper rate. Returns (0, 0)
    /// gracefully when even the cheapest band on offer costs more than the cap, or the market stands at
    /// or below `MINIMUM_COLLATERAL_RATIO` - unless minPeggedOut was given, which that zero cannot meet,
    /// so it reverts MintInsufficientAmount like any other path.
    /// @param collateralIn The amount of wrapped collateral to post.
    /// @param receiver The address to receive minted pegged tokens.
    /// @param minPeggedOut Minimum acceptable pegged output. 0 means no check.
    /// @param maxFeeRatio Maximum fee as a ratio of the collateral used (18 decimals). e.g. 0.05 ether = 5%.
    /// `type(uint256).max` is no cap at all: the call is then the three-argument mint, and reverts wherever that
    /// reverts rather than returning (0, 0).
    /// @return peggedOut The amount of pegged tokens minted.
    /// @return collateralUsed The amount of wrapped collateral actually consumed (collateral added + fee).
    function mintPeggedToken(
        uint256 collateralIn,
        address receiver,
        uint256 minPeggedOut,
        uint256 maxFeeRatio
    ) external returns (uint256 peggedOut, uint256 collateralUsed);

    /// @notice Redeem some pegged tokens for collateral tokens.
    /// @param peggedIn the amount of peggedToken to redeem.
    /// @param receiver The address of receiver for collateral token.
    /// @param minCollateralOut The minimum amount of wrapped value of collateral token should be received. 0 means no
    /// check is made.
    /// @return collateralOut The amount of wrapped value of collateral token should be received.
    function redeemPeggedToken(
        uint256 peggedIn,
        address receiver,
        uint256 minCollateralOut
    ) external returns (uint256 collateralOut);

    /// @notice Mint some leveraged tokens in exchange for collateral tokens.
    /// @param collateralIn The amount of wrapped value of collateral token supplied.
    /// @param receiver The address of receiver for leveragedToken.
    /// @param minLeveragedOut The minimum amount of leveragedToken should be received. 0 means no check is made.
    /// @return leveragedOut The amount of leveragedToken should be received.
    function mintLeveragedToken(
        uint256 collateralIn,
        address receiver,
        uint256 minLeveragedOut
    ) external returns (uint256 leveragedOut);

    /// @notice Redeem some leveraged tokens for collateral tokens.
    /// @param leveragedIn the amount of leveragedToken to redeem.
    /// @param receiver The address of receiver for collateral token.
    /// @param minCollateralOut The minimum amount of wrapped value of collateral token should be received. 0 means no
    /// check is made.
    /// @return collateralOut The amount of wrapped value of collateral token should be received.
    function redeemLeveragedToken(
        uint256 leveragedIn,
        address receiver,
        uint256 minCollateralOut
    ) external returns (uint256 collateralOut);

    /*//////////////////////////////////////////////////////////////
                      PROTECTED UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Give wrapped collateral to the protocol as backing, raising the collateral ratio.
    /// @dev For the owner, the zero-fee role and the donor role. The caller supplies the collateral in the same call
    /// and receives nothing, but giving is still a power: it moves the collateral ratio, and with it every rule
    /// judged on that ratio - a market with no collateral and no pegged reads a ratio of one, where it is closed to
    /// retail mints, and a single wei given would lift that to infinity. A donation cannot reach collateral already
    /// held — the surplus of the holding over the recorded backing is the harvestable yield, which belongs to the
    /// stability pools, and a donation adds only itself.
    ///
    /// This is the one way to contribute collateral as *cover*. Transferring wrapped collateral to this contract
    /// instead leaves the record untouched, so it becomes harvestable yield for the stability pools and moves
    /// neither the collateral ratio nor either token's price.
    /// @param wrappedAmount The wrapped collateral to give. Must be non-zero.
    function donateWrappedCollateral(uint256 wrappedAmount) external;

    /// @notice Write the recorded backing down to the collateral actually held, recognising an impairment as
    /// permanent.
    /// @dev One-directional: it can only lower the record. Raising it requires collateral to arrive, which is
    /// `donateWrappedCollateral`.
    ///
    /// While the record stands above the holding the market is halted: every price, ratio and fee band reports the
    /// record, and every updating call reverts `UnrecognisedImpairment`. This ends the halt by making the record
    /// true, and from then on everything is priced from what is held. It also ends the harvest's suspension: with
    /// the record above the holding there is no surplus, so `harvestable` is zero; written down, later yield is a
    /// surplus again and reaches the stability pools.
    ///
    /// Owner-gated because it is a judgement, not a reading. A fall in the rate does not say whether the loss is
    /// permanent: a market may be collateralised by an asset whose value falls and recovers as a matter of course,
    /// and writing the record down automatically would make every such fall permanent at the leveraged holders'
    /// expense. Nothing on-chain distinguishes the two cases.
    ///
    /// Reverts when the record does not exceed the holding, so a call that would do nothing fails visibly rather
    /// than succeeding silently.
    function recogniseImpairment() external;

    /// @notice Updates the config to the given config
    /// @param config_ The new config
    function updateConfig(Config calldata config_) external;

    /// @notice Updates the fee receiver to the given address
    /// @param feeReceiver_ The new fee receiver
    function updateFeeReceiver(address feeReceiver_) external;

    /// @notice Updates the reserve pool to the given address
    /// @param reservePool_ The new reserve pool
    function updateReservePool(address reservePool_) external;

    /// @notice Updates the price oracle to the given address
    /// @param priceOracle_ The new price oracle. Reverts on the zero address.
    function updatePriceOracle(address priceOracle_) external;

    /// @notice Mint some pegged tokens in exchange for collateral tokens.
    /// @dev Reverts `ReturnZeroAmount` for a deposit too small to buy a whole pegged token, taking none of it.
    /// @param collateralIn The amount of wrapped value of collateral token supplied.
    /// @param receiver The address of receiver for peggedToken.
    /// @return peggedOut The amount of pegged tokens received.
    function freeMintPeggedToken(uint256 collateralIn, address receiver) external returns (uint256 peggedOut);

    /// @notice Redeem some pegged tokens for collateral tokens and leveraged tokens.
    /// @dev Redeems at most the pegged this minter minted, as `redeemPeggedToken` does: where the two legs ask for
    /// more, both are cut in proportion to exactly that - the collateral leg rounded down and the conversion leg the
    /// rest - and the caller keeps the pegged not redeemed. Where it minted none, reverts `NoRedeemableTokens`.
    /// @param peggedForCollateral the amount of peggedToken to redeem for collateral.
    /// @param peggedForLeveraged the amount of peggedToken to redeem for leveraged tokens.
    /// @param receiver The address of receiver for collateral token.
    /// @return wrappedCollateralOut The amount of collateral tokens received.
    /// @return leveragedOut The amount of leveraged tokens received.
    function freeRedeemPeggedToken(
        uint256 peggedForCollateral,
        uint256 peggedForLeveraged,
        address receiver
    ) external returns (uint256 wrappedCollateralOut, uint256 leveragedOut);

    /// @notice Mint some leveraged tokens in exchange for collateral tokens.
    /// @param collateralIn The amount of wrapped value of collateral token supplied.
    /// @param receiver The address of receiver for leveraged Tokens.
    /// @return leveragedOut The amount of leveraged tokens received.
    function freeMintLeveragedToken(uint256 collateralIn, address receiver) external returns (uint256 leveragedOut);

    /// @notice Redeem some leveraged tokens for collateral tokens.
    /// @dev Reverts `ReturnZeroAmount` wherever the redemption would pay nothing - the residual gone, or the offer's
    /// share of it too small to pay a wrapped wei - burning nothing and debiting nothing.
    /// @param leveragedIn the amount of leveragedToken to redeem.
    /// @param receiver The address of receiver for collateral token.
    /// @return collateralOut The amount of collateral tokens received.
    function freeRedeemLeveragedToken(uint256 leveragedIn, address receiver) external returns (uint256 collateralOut);

    /// @notice Dry run of a capped mint: the outcome when the fee, as a ratio of the collateral USED,
    /// is held within maxFeeRatio. With an offer larger than the market can absorb at that price this
    /// reports the capacity to mint at it — the collateral taken is bounded by the price, not by the
    /// size of the offer. An offer too small to buy a whole pegged token takes nothing, as the capped
    /// call reports: no collateral, no fee, and the band's incentive ratio.
    /// @param collateralIn The proposed amount of wrapped collateral.
    /// @param maxFeeRatio The maximum fee as a ratio of the collateral used (18 decimals). e.g. 0.05 ether = 5%.
    function mintPeggedTokenDryRun(
        uint256 collateralIn,
        uint256 maxFeeRatio
    )
        external
        view
        returns (
            int256 incentiveRatio,
            uint256 fee,
            uint256 collateralTaken,
            uint256 peggedMinted,
            uint256 price,
            uint256 rate
        );

    /// @notice Dry run of `freeRedeemPeggedToken`: the wrapped collateral and leveraged tokens a zero-fee pegged
    ///         redeem would yield for the given pegged split, priced against current oracle state - without moving
    ///         tokens or writing state. Intended for contract-to-contract callers (the StabilityPoolManager's
    ///         rebalance) that must know the redeemed proceeds before acting, e.g. to bound a pool's liquidation
    ///         reward to what its reward accounting can absorb.
    ///         The legs are cut as the call cuts them, at most to the pegged this minter minted.
    ///         Where the call would revert - a conversion asked for below `MINIMUM_COLLATERAL_RATIO`, which the
    ///         call reverts `BelowMinimumCollateralRatio` for together with any collateral leg beside it, or a
    ///         redemption from a minter that minted none - both legs report zero. A redeem with no conversion is not
    ///         judged.
    /// @param peggedForCollateral The pegged amount redeemed for wrapped collateral.
    /// @param peggedForLeveraged The pegged amount redeemed for leveraged tokens.
    /// @return wrappedCollateralOut The wrapped collateral that `peggedForCollateral` would return.
    /// @return leveragedOut The leveraged tokens that `peggedForLeveraged` would return.
    function freeRedeemDryRun(
        uint256 peggedForCollateral,
        uint256 peggedForLeveraged
    ) external view returns (uint256 wrappedCollateralOut, uint256 leveragedOut);
}
