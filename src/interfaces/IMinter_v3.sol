// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

/// @notice Minter v3
/// @author rootminus0x1 based on (albeit significantly modified) Aladdin's FX system
/// @notice Provides an interface for minting and redeeming pegged and leveraged tokens, some with fees, others without.
///
/// For the fee'd fuctions equivalent "dry run" functions are available that could allow a user to know what
/// fees, discounts, etc. are expected (modulo slippage). This id designed for a user interface to use.
///
/// Configuration functions are available such as for allowing setting of:
/// * the fee/discount/disallow configuration
/// * the collateral ratio that rebalancing can start
/// * the price oracle and rate (for wrapped) of the collateral
/// * the fee receiver and discount provider (reserve pool)
///
/// Various queries are provided such as:
/// * the net asset values of the tokens,
/// * leverage ratio of the leveraged tokens
/// * collateral ratio of the system

/// differences to interface IMinter:
/// * fee-capped minting
/// * absolute-amount fee queries in pegged space (removal of uncapped queries, can make the same call passing "0,0")
// solhint-disable-next-line contract-name-capwords
interface IMinter_v3 {
    /*//////////////////////////////////////////////////////////////
                           DATA STRUCTURES
    //////////////////////////////////////////////////////////////*/

    struct IncentiveConfig {
        // note: incentive ratios have one more entry than the band bounds do
        // the boundaries of the collateral ratio where the incentive ratios apply
        // must be strictly increasing at the precision of 18 decimals
        uint256[] collateralRatioBandUpperBounds;
        // incentive ratios for the above bands , interval (-1 ether, 1 ether]
        // positive = fee ratio, negative for discount, == 1 ether disallow
        // any 1 ether values must be at index 0
        // no negative values are allowed in the highest band
        int256[] incentiveRatios;
    }
    struct Config {
        // bonus/fees
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

    /// @notice Emitted when there's been a slashing event and Zhenglong responds by calling reset.
    event Reset(uint256 oldCollateral, uint256 newCollateral);

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

    /// @dev Thrown when the oracle price is invalid.
    error InvalidOraclePrice();
    /// @dev Thrown when the oracle price is zero.
    error ZeroOraclePrice();
    /// @dev Thrown when the oracle wrapped-to-underlying rate is zero. A rate of zero is a units conversion, not an
    /// economic state, so it can only mean the oracle is faulty.
    error ZeroOracleRate();

    // @inderitdoc Token
    /// @dev thrown when zero collateral is passed in or -1 is passed in and the balance is zero
    error ZeroInputBalance(address token);
    error RequestedBonusNotGiven(uint256 requested, uint256 available);

    /// @dev Thrown when collateral is passed but minting is prevented for some other reason.
    error MintZeroAmount(address mintingToken);
    /// @dev Thrown when collateral is passed but minting is reduced below the miniumum requested.
    error MintInsufficientAmount(address mintingToken, uint256 actual, uint256 miniumum);
    /// @dev Thrown when pegged or leveraged is passed but redeeming is prevented for some other reason.
    error ReturnZeroAmount(address returningToken);
    /// @dev Thrown when pegged or leveraged is passed but redeeming is reduced below the miniumum requested.
    error ReturnInsufficientAmount(address returningToken, uint256 actual, uint256 miniumum);
    error NoRedeemableTokens(address redeemingToken);
    error InsufficientRedeemableTokens(address redeemingToken, uint256 available, uint256 requested);

    /// @dev thrown if a ratio doesn't make sense in some context
    error InvalidRatio();
    error TooManyCollateralRatioBounds(string config, uint count, uint max); // solhint-disable-line explicit-types
    error InvalidCollateralRatioBoundValue(string config, uint256 value, uint index, string reason); // solhint-disable-line explicit-types
    error CollateralRatioBoundValueNotIncreasing(
        string config,
        uint256 shouldBeLessOrEqual,
        uint index, // solhint-disable-line explicit-types
        uint256 shouldBeGreaterOrEqual
    );
    error TooManyIncentiveRatios(string config, uint count, uint max); // solhint-disable-line explicit-types
    error TooFewIncentiveRatios(string config, uint count, uint min); // solhint-disable-line explicit-types
    error InvalidIncentiveRatioValue(string config, uint index, int256 shouldBeMinusOnetoOne, string reason); // solhint-disable-line explicit-types
    error IncentiveRatioTooPrecise(string config, int256 value);
    error CollateralRatioBoundsIncentivesLengthsMismatch(string config, uint256 oneLess, uint256 oneMore);
    error CollateralRatioBoundTooPrecise(string config, uint256 value);
    error NoDepegBoundaryOrDisallow(string config);

    /// @notice Thrown when the burn interface does not match one known by this contract
    error UnsupportedBurnInterface(bytes4 interfaceId);

    /*//////////////////////////////////////////////////////////////
                         PUBLIC READ FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice returns the role needed to access the zero fee functions (free*)
    // solhint-disable-next-line func-name-mixedcase
    function ZERO_FEE_ROLE() external view returns (uint256);

    /// @notice returns the role needed to access the harvesting function
    // solhint-disable-next-line func-name-mixedcase
    function HARVESTER_ROLE() external view returns (uint256);

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
    /// - If pegged tokens are zero but collateral exists: Returns a very large number (1 ether * 1 ether * 1 ether)
    /// - If collateral price is zero: Returns 1 ether * 1 ether
    ///
    /// This value is used for critical system operations like rebalancing, especially in depegged scenarios.
    /// For the real market value of the pegged token, see peggedTokenPrice() instead.
    function collateralRatio() external view returns (uint256);

    /// @notice Return the current leveraged ratio of the leveragedToken (18 decimals).
    function leverageRatio() external view returns (uint256);

    /// @notice Return the price of a leveraged token in terms of the pegged token's underlying (18 decimals).
    function leveragedTokenPrice() external view returns (uint256);

    /// @notice Return the price of a pegged token in terms of the pegged token's underlying (18 decimals).
    /// this should normally be 1 ether but if the token depegs then this number will be this token's share of the
    /// collateral.
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
    /// @param holdingCollateral The collateral pool's pegged holdings - weights its share of the unconstrained split.
    /// @param holdingLeveraged The leveraged pool's pegged holdings - weights its share of the unconstrained split.
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

    /// @notice Returns the address of the reserve pool contract that provides the collateral for discounts
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
    /// A positive number is a fee ratio; a negative number indicates a discount.
    function mintPeggedTokenIncentiveRatio() external view returns (int256 incentiveRatio);

    /// @notice Returns the current instantaneous incentive ratio for redeeming pegged tokens (18 decimals).
    /// A positive number is a fee ratio; a negative number indicates a discount.
    function redeemPeggedTokenIncentiveRatio() external view returns (int256 incentiveRatio);

    /// @notice Returns the current instantaneous incentive ratio for minting leveraged tokens (18 decimals).
    /// A positive number is a fee ratio; a negative number indicates a discount.
    function mintLeveragedTokenIncentiveRatio() external view returns (int256 incentiveRatio);

    /// @notice Returns the current instantaneous incentive ratio for redeeming leveraged tokens (18 decimals).
    /// A positive number is a fee ratio; a negative number indicates a discount.
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
    /// a fee ratio; a negative number indicates a discount.
    /// @return fee The amount deducted from `collateralIn` as a fee.
    /// @return collateralTaken The amount of collateral used in the exchange.
    /// This is usually the same as `collateralIn` but at certain collateral ratio levels minting pegged tokens may be
    /// disallowed by configuration.
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
    /// │      │ ◄── collateralReturned ── │        │ ◄── discount ─┐   ┌──────────────┐
    /// └──────┘  (including any discount) └────────┘               └── │ reserve pool │
    ///                                         │                       └──────────────┘
    ///            collateral held -= collateral value of peggedRedeemed - fee
    ///
    /// @param peggedIn The amount of pegged token to be redeemed.
    /// @return incentiveRatio the effective incentive ratio for `peggedIn` pegged tokens.  A positive number is a fee
    /// ratio; a negative number indicates a discount. This is the theoretic value.
    /// @return fee The amount deducted in wrapped collateral from 'peggedIn' as a fee.
    /// @return discount The amount in wrapped collateral added to 'collateralReturned' taken from the reserve pool.
    /// This takes into account the possibility the reserve pool may be exhausted by this action.
    /// @return peggedRedeemed The amount of pegged tokens that would be redeemed.
    /// @return wrappedCollateralReturned The amount of collateral returned to the caller including from the reserve pool (if a discount has been configured)
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
            uint256 discount,
            uint256 peggedRedeemed,
            uint256 wrappedCollateralReturned,
            uint256 price,
            uint256 rate
        );

    /// @notice Returns values that will be used if an actual `mintLeveragedToken` function call is made.
    /// @param collateralIn The amount of collateral to be exchanged for leveraged tokens.
    /// @return incentiveRatio the effective incentive ratio for `collateralIn` collateral tokens. A positive number is
    /// a fee ratio; a negative number indicates a discount.
    /// @return fee The amount deducted from 'collateralIn' as a fee.
    /// @return discount The amount in wrapped collateral added to 'leverageMinted' taken from the reserve pool.
    /// This takes into account the possibility the reserve pool may be exhausted by this action.
    /// @return collateralUsed The amount of collateral used in the exchange.
    /// @return leveragedMinted The amount of leveraged tokens that would be minted. This takes into account the discount applied.

    function mintLeveragedTokenDryRun(
        uint256 collateralIn
    )
        external
        view
        returns (
            int256 incentiveRatio,
            uint256 fee,
            uint256 discount,
            uint256 collateralUsed,
            uint256 leveragedMinted,
            uint256 price,
            uint256 rate
        );

    /// @notice Returns values that will be used if an actual `redeemLeveragedToken` function call is made.
    /// @param leveragedIn The amount of pegged token to be redeemed.
    /// @return incentiveRatio the effective incentive ratio for `leveragedIn` pegged tokens.  A positive number is a
    /// fee ratio; a negative number indicates a discount.
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
    /// @return wrappedAmount the amount of wrapped collateral that can be distributed as rewards.
    function harvestable() external view returns (uint256 wrappedAmount);

    /*//////////////////////////////////////////////////////////////
                        PUBLIC UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Mint some pegged tokens in exchange for collateral tokens.
    /// @param collateralIn The amount of wrapped value of collateral token supplied, use `uint256(-1)` to supply all
    /// collateral token.
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
    /// gracefully when even the cheapest band on offer costs more than the cap - unless minPeggedOut
    /// was given, which that zero cannot meet, so it reverts MintInsufficientAmount like any other path.
    /// @param collateralIn The amount of wrapped collateral to post. Use type(uint256).max for all.
    /// @param receiver The address to receive minted pegged tokens.
    /// @param minPeggedOut Minimum acceptable pegged output. 0 means no check.
    /// @param maxFeeRatio Maximum fee as a ratio of the collateral used (18 decimals). e.g. 0.05 ether = 5%.
    /// @return peggedOut The amount of pegged tokens minted.
    /// @return collateralUsed The amount of wrapped collateral actually consumed (collateral added + fee).
    function mintPeggedToken(
        uint256 collateralIn,
        address receiver,
        uint256 minPeggedOut,
        uint256 maxFeeRatio
    ) external returns (uint256 peggedOut, uint256 collateralUsed);

    /// @notice Redeem some pegged tokens for collateral tokens.
    /// @param peggedIn the amount of peggedToken to redeem, use `uint256(-1)` to redeem all peggedToken.
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
    /// @param collateralIn The amount of wrapped value of collateral token supplied, use `uint256(-1)` to supply all
    /// collateral token.
    /// @param receiver The address of receiver for leveragedToken.
    /// @param minLeveragedOut The minimum amount of leveragedToken should be received. 0 means no check is made.
    /// @return leveragedOut The amount of leveragedToken should be received.
    function mintLeveragedToken(
        uint256 collateralIn,
        address receiver,
        uint256 minLeveragedOut
    ) external returns (uint256 leveragedOut);

    /// @notice Redeem some leveraged tokens for collateral tokens.
    /// @param leveragedIn the amount of leveragedToken to redeem, use `uint256(-1)` to redeem all leveragedToken.
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

    /// @notice Resets the underlying collateral count to equal the value of the held wrapped collateral
    /// This is anticipation of a slashing event for the wrapped collateral which could
    /// leave the whole system with overvalued collateral which would prevent a rebalancing
    function reset() external;

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
    /// @param priceOracle_ The new price oracle
    function updatePriceOracle(address priceOracle_) external;

    /// @notice Mint some pegged tokens in exchange for collateral tokens.
    /// @param collateralIn The amount of wrapped value of collateral token supplied, use `uint256(-1)` to supply all
    /// collateral token.
    /// @param receiver The address of receiver for peggedToken.
    /// @return peggedOut The amount of pegged tokens received.
    function freeMintPeggedToken(uint256 collateralIn, address receiver) external returns (uint256 peggedOut);

    /// @notice Redeem some pegged tokens for collateral tokens and leveraged tokens.
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
    /// @param collateralIn The amount of wrapped value of collateral token supplied, use `uint256(-1)` to supply all
    /// collateral token.
    /// @param receiver The address of receiver for leveraged Tokens.
    /// @return leveragedOut The amount of leveraged tokens received.
    function freeMintLeveragedToken(uint256 collateralIn, address receiver) external returns (uint256 leveragedOut);

    /// @notice Redeem some leveraged tokens for collateral tokens.
    /// @param leveragedIn the amount of leveragedToken to redeem, use `uint256(-1)` to redeem all leveragedToken.
    /// @param receiver The address of receiver for collateral token.
    /// @return collateralOut The amount of collateral tokens received.
    function freeRedeemLeveragedToken(uint256 leveragedIn, address receiver) external returns (uint256 collateralOut);

    /// @notice Dry run of a capped mint: the outcome when the fee, as a ratio of the collateral USED,
    /// is held within maxFeeRatio. With an offer larger than the market can absorb at that price this
    /// reports the capacity to mint at it — the collateral taken is bounded by the price, not by the
    /// size of the offer.
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
    /// @param peggedForCollateral The pegged amount redeemed for wrapped collateral.
    /// @param peggedForLeveraged The pegged amount redeemed for leveraged tokens.
    /// @return wrappedCollateralOut The wrapped collateral that `peggedForCollateral` would return.
    /// @return leveragedOut The leveraged tokens that `peggedForLeveraged` would return.
    function freeRedeemDryRun(
        uint256 peggedForCollateral,
        uint256 peggedForLeveraged
    ) external view returns (uint256 wrappedCollateralOut, uint256 leveragedOut);
}
