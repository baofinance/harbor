// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Bao Minter
/// @author rootminus0x1 based on (albeit significantly modified) Aladdin's FX system
/// @notice Provides an interface for minting and redeeming pegged and leveraged tokens, some with fees, others without.
/// <br>
/// For the fee'd fuctions equivalent "dry run" functions are available that could allow a user to know what
/// fees, discounts, etc. are expected (modulo slippage). This id designed for a user interface to use.
/// <br>
/// Configuration functions are available such as for allowing setting of:
/// <ul>
/// <li>the fee/discount/disallow configuration
/// <li>the collateral ratio that rebalancing and harvesting can start
/// <li>the price oracle and rate (for wrapped) of the collateral
/// <li>the fee receiver and discount provider (reserve pool)
/// </ul>
/// Various queries are provided such as:
/// <ul>
/// <li>the net asset values of the tokens,
/// <li>leverage ratio of the leveraged tokens
/// <li>collateral ratio of the system
/// </ul>
interface IMinter {
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
        // points at which specific activity commences
        uint256 rebalanceCollateralRatioUpperBound; // the upper collateral ratio at which rebalancing begins
        uint256 harvestCollateralRatioLowerBound; // above this harvesting of collateral can begin.
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

    /// @notice Emitted when someone redeem collateral token with peggedToken or leveragedToken.
    /// @param sender The address of peggedToken and leveragedToken owner.
    /// @param receiver The address of receiver for collateral token.
    /// @param peggedTokenBurned The amount of peggedToken burned.
    /// @param collateralOut The amount of collateral token redeemed.
    event RedeemPeggedToken(
        address indexed sender,
        address indexed receiver,
        uint256 peggedTokenBurned,
        uint256 collateralOut
    );

    /// @notice Emitted when someone redeem collateral token with peggedToken or leveragedToken.
    /// @param sender The address of peggedToken and leveragedToken owner.
    /// @param receiver The address of receiver for collateral token.
    /// @param peggedTokenBurned The amount of peggedToken burned.
    /// @param leveragedOut The amount of collateral token redeemed.
    event SwapPeggedForLeveraged(
        address indexed sender,
        address indexed receiver,
        uint256 peggedTokenBurned,
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

    event UpdateConfig(Config config);

    /// @notice Emitted when the platform contract is updated.
    /// @param oldFeeReceiver The address of previous platform contract.
    /// @param newFeeReceiver The address of the new (current) platform contract.
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

    // @inderitdoc Token
    /// @dev thrown when zero collateral is passed in or -1 is passed in and the balance is zero
    error ZeroInputBalance(address token);

    /// @dev Thrown when collateral is passed but minting is prevented for some other reason.
    error MintZeroAmount(address mintingToken);
    /// @dev Thrown when collateral is passed but minting is reduced below the miniumum requested.
    error MintInsufficientAmount(address mintingToken, uint256 miniumum, uint256 actual);
    /// @dev Thrown when pegged or leveraged is passed but redeeming is prevented for some other reason.
    error ReturnZeroAmount(address returningToken);
    /// @dev Thrown when pegged or leveraged is passed but redeeming is reduced below the miniumum requested.
    error ReturnInsufficientAmount(address returningToken, uint256 miniumum, uint256 actual);
    error NoRedeemableTokens(address redeemingToken);

    /// @dev thrown if a ratio doesn't make sense in some context
    error InvalidRatio();
    // TODO: make these expected, actual.
    error TooManyCollateralRatioBounds(uint count, uint max); // solhint-disable-line explicit-types
    error InvalidCollateralRatioBoundValue(uint256 value, uint index); // solhint-disable-line explicit-types
    error CollateralRatioBoundValueNotIncreasing(
        uint256 shouldBeLessOrEqual,
        uint index, // solhint-disable-line explicit-types
        uint256 shouldBeGreaterOrEqual
    );
    error TooManyIncentiveRatios(uint count, uint max); // solhint-disable-line explicit-types
    error TooFewIncentiveRatios(uint count, uint min); // solhint-disable-line explicit-types
    error InvalidIncentiveRatioValue(int256 shouldBeMinusOnetoOne);
    error IncentiveRatioTooPrecise(int256 value);
    error CollateralRatioBoundsIncentivesLengthsMismatch(uint256 oneLess, uint256 oneMore);
    error CollateralRatioBoundTooPrecise(uint256 value);

    /// @notice Thrown when the burn interface does not match one known by this contract
    error UnsupportedBurnInterface(bytes4 interfaceId);

    /// @dev thrown when an action is paused, for example if the protocol is not initialised
    error ActionPaused();

    /*//////////////////////////////////////////////////////////////
                         PUBLIC READ FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // @notice returns the role needed to access the zero fee functions (free*)
    // solhint-disable-next-line func-name-mixedcase
    function ZERO_FEE_ROLE() external view returns (uint256);

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

    /// @notice Return the current collateral ratio of the peggedToken to the collateral token (18 decimals).
    /// This function isn't technically correct if the pegged token depegs, when the collateral ratio is 1.
    /// As that is not very useful and also makes the funtion piecewise, the number returned is the collateral ratio
    /// assuming the assuming the pegged token price is exactly 1 (i.e. not depegged).
    /// if there are no pegged tokens, `uint256(-1)` is returned.
    function collateralRatio() external view returns (uint256);

    /// @notice Return the upper bound of the collateral ratio when  the rebalance pools allow liquidation
    function rebalanceCollateralRatio() external view returns (uint256);

    /// @notice Return the current leveraged ratio of the leveragedToken (18 decimals).
    function leverageRatio() external view returns (uint256);

    /// @notice Return the price of a leveraged token in terms of the pegged token's underlying (18 decimals).
    function leveragedTokenPrice() external view returns (uint256);

    /// @notice Return the price of a pegged token in terms of the pegged token's underlying (18 decimals).
    /// this should normally be 1 ether but if the token depegs then this number will be this token's share of the
    /// collateral.
    function peggedTokenPrice() external view returns (uint256);

    /// @notice Return the leveraged tokens that are the same value are the given collateral token (at the current
    /// collateral ratio).
    function leverageTokensForCollateral(uint256 forCollateral) external view returns (uint256 collateral);

    /// @notice Returns the amount of Pegged tokens that need to be redeemed to achieve a given target collateral ratio
    /// This is based on the fact that redeeming pegged tokens has a upward pressure on collateral ratio
    /// If, however, there are no leveraged tokens then no amount of redemption can change the collateral ratio.
    /// In the case of no leveraged tokens we return the total supply minted by this minter
    /// @param targetCollateralRatio The collateral ratio that we aim to meet by the returned pegged tokens redeemed.
    /// @return peggedTokens The number of pegged tokens that need to be redeemed to achieve the `targetCollateralRatio`
    /// given the current collateral ratio
    function redeemPeggedForCollateralRatio(uint256 targetCollateralRatio) external view returns (uint256 peggedTokens);

    /// @notice Returns the number of pegged tokens needed to be swapped for leveraged tokens to
    /// achieve the `targetCollateralRatio`
    /// @param targetCollateralRatio The target collateral ratio
    /// @return peggedTokens The number of pegged tokens needed to be swapped to achieve the given
    /// `targetCollateralRatio`
    function swapPeggedForLeveragedForCollateralRatio(
        uint256 targetCollateralRatio
    ) external view returns (uint256 peggedTokens);

    /// @notice Returns the amount of collateral tokens 'forLeveragedTokens' will buy in the absence of fees and
    /// discounts
    /// @param forLeveragedTokens The amount of leveraged tokens
    /// @return collateral The amount of collateral tokens equivalent to `forLeveragedTokens`
    function collateralForLeverageTokens(uint256 forLeveragedTokens) external view returns (uint256 collateral);

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
    /// @param collateralIn The amount of collateral to be exchanged for pegged tokens.
    /// @return incentiveRatio the effective incentive ratio for `collateralIn` collateral tokens. A positive number is
    /// a fee ratio; a negative number indicates a discount.
    /// @return collateralUsed The amount of collateral used in the exchange.
    /// This is usually the same as `collateralIn` but at certain collateral ratio levels minting pegged tokens may be
    /// disallowed by configuration.
    /// @return peggedMinted The amount of pegged tokens that would be minted.
    /// @return fee The amount deducted from `collateralIn` as a fee.
    /// @return reserveCollateralUsed The amount deducted from the reserve pool as a discount.
    /// @return price The price of collateral in terms of pegged tokens used in the calculations.
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
        );

    /// @notice Returns values that will be used if an actual `redeemPeggedToken` function call is made.
    /// @param peggedIn The amount of pegged token to be redeemed.
    /// @return incentiveRatio the effective incentive ratio for `peggedIn` pegged tokens.  A positive number is a fee
    /// ratio; a negative number indicates a discount.
    /// @return peggedRedeemed The amount of pegged tokens that would be redeemed.
    /// @return collateralReturned The amount of collateral returned from the reserve pool and passed to the caller.
    /// @return fee The amount deducted from the returned collateral as a fee.
    /// @return reserveCollateralUsed The amount deducted from the reserve pool a a discount.
    /// @return price is the price of collateral in terms of pegged tokens used in the calculations.
    function redeemPeggedTokenDryRun(
        uint256 peggedIn
    )
        external
        view
        returns (
            int256 incentiveRatio,
            uint256 peggedRedeemed,
            uint256 collateralReturned,
            uint256 fee,
            uint256 reserveCollateralUsed,
            uint256 price
        );

    /// @notice Returns values that will be used if an actual `mintLeveragedToken` function call is made.
    /// @param collateralIn The amount of collateral to be exchanged for leveraged tokens.
    /// @return incentiveRatio the effective incentive ratio for `collateralIn` collateral tokens. A positive number is
    /// a fee ratio; a negative number indicates a discount.
    /// @return collateralUsed The amount of collateral used in the exchange.
    /// This is usually the same as `collateralIn` but at certain collateral ratio levels minting pegged tokens may be
    /// disallowed by configuration.
    /// @return leveragedMinted The amount of leveraged tokens that would be minted.
    /// @return fee The amount deducted from `collateralIn` as a fee.
    /// @return reserveCollateralUsed The amount deducted from the reserve pool as a discount.
    /// @return price is the price of collateral used in terms of pegged tokens used in the calculations.
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
        );

    /// @notice Returns values that will be used if an actual `redeemLeveragedToken` function call is made.
    /// @param leveragedIn The amount of pegged token to be redeemed.
    /// @return incentiveRatio the effective incentive ratio for `leveragedIn` pegged tokens.  A positive number is a
    /// fee ratio; a negative number indicates a discount.
    /// @return leveragedRedeemed The amount of leveraged tokens that would be redeemed.
    /// @return collateralReturned The amount of collateral returned from the reserve pool and passed to the caller.
    /// @return fee The amount deducted from the returned collateral as a fee.
    /// @return reserveCollateralUsed The amount deducted from the reserve pool a a discount.
    /// @return price is the price of collateral in terms of pegged tokens used in the calculations.
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
        );

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

    /// @notice Redeem some pegged tokens for collateral tokens.
    /// @param peggedIn the amount of peggedToken to redeem, use `uint256(-1)` to redeem all peggedToken.
    /// @param receiver The address of receiver for collateral token.
    /// @return collateralOut The amount of collateral tokens received.
    function freeRedeemPeggedToken(uint256 peggedIn, address receiver) external returns (uint256 collateralOut);

    /// @notice Redeem some pegged tokens for collateral tokens.
    /// @param peggedIn the amount of peggedToken to redeem, use `uint256(-1)` to redeem all peggedToken.
    /// @param receiver The address of receiver for collateral token.
    /// @return leveragedOut The amount of leveraged tokens received.
    function freeSwapPeggedForLeveraged(uint256 peggedIn, address receiver) external returns (uint256 leveragedOut);

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
}
