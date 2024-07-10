// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface IMinter {
    /********************************
     * Data Structures              *
     ********************************/

    struct BalanceTokens {
        address peggedToken;
        address leveragedToken;
        address collateralToken;
    }

    /* TODO: rewrite this (or remove it)
     * fees, rebalance and bonuses
     * say, collateral value falls, and continues to fall, the sequence of stability measures is:
     *   1) at CR = danger,
     *       * fees for minting pegged and redeeming leveraged go up, discouraging users from
     *         making CR drop more
     *       * fees for redeeming pegged and minting leveraged go down encouraging users to make CR go up
     *   2) at CR = rebalance,
     *       * at this point fees are 100% and 0% respectively and rebalance starts.
     *         On each liquidate call, rebalance pools burn pegged in exchange for something (collateral or
     *         leveraged tokens) restoring CR to rebalance level
     *   3) once rebalance pools are exhausted,
     *       * bonuses start for redeeming pegged and minting leveraged, encouraging users to make CR go up.
     *         Bonuses are governed by the reserve pool
     *
     *   * defaultMintPeggedTokenFeeRatio: the fee when collateral ratio after a mint is above criticalCollateralRatio
     *   * defaultRedeemLeveragedTokenFeeRatio: the fee when collateral ratio after the redeem is above criticalCollateralRatio
     *   * dangerCollateralRatio: when the fee for
     *       * minting Pegged tokens starts to increase from the default
     *       * redeeming Leveraged tokens starts to decrease from the default
     *   * rebalanceCollateralRatio: when:
     *       * the fee minting Pegged tokens and redeeming Leveraged tokens reaches 100%, effectively pausing it.
     *       * redeeming Pegged tokens and minting Leveraged tokens adopts a lower level, the
     *       * the rebalance pools come into action and respond to liquidate requests
     *     this should be below the criticalCollateralRatio
     *
     *   rebalance pools are liquidated to maintain the rebalanceCollateralRatio
     *   when the rebalance pools are exhausted then bonuses are paid from the reserve pool
     *
     */

    // collateral ratio:
    //  safe, e.g. 135%, fees are static, at the "safe" values for minting and redeeming pegged and leveraged tokens
    //  danger, e.g. 130%, fees start to increase at this point reaching 100% at rebalance
    //  rebalance, e.g. 125%, here fees are 100% so an effective pause. This should be mentioned, or a pause instituted,
    //              in the UI so that customers don't get stung, non-web users have to look after themselves
    //  bonus, when rebalance pools are exhausted and CR < rebalance
    // because: we may want to increase mint pegged fees before reducing redeem leveraged, etc.
    // need to also minimise storage accesses

    /*
     * fees are charged at a rate that would be the same if the action was performed one dollar at a time
     * i.e. the fee is a definite integral of the piecewise function below
     * this results in the correct incentive for users to be nudged in the direction that results in
     * stability of the protocol
     *
     * mint pegged and redeem leveraged fees/bonus
     * -------------------------------------------
     *                         bonus CR                            danger
     *                         v        rebalance fee ratio        v
     *                         .-----------------------------------.
     *                         |                                    \
     *                         |                                     \         normal fee
     *                         |                                      `----------------------
     *                         |                                      ^
     *                         |                                      normal
     * 0-----------------------+-------------------------------------------------------------
     *                         |
     *    - bonus ratio        |
     * ------------------------'
     *
     *
     *
     */
    // TODO: add getter functions for Incentive config
    // TODO: add getter functions for the other 4 config items
    // TODO: and test them
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
        uint256 harvestCollateralRatioUpperBound; // above this harvesting of collateral can begin // TODO: implement this
        // bonus/fees
        IncentiveConfig mintPeggedIncentiveConfig;
        // leverage tokens have their own intrinsic value in that they increase in leverage the lower the collateral ratio
        // so there is a convenient intrinsic incentive to mint at low collateral ratios
        IncentiveConfig mintLeveragedIncentiveConfig;
        IncentiveConfig redeemPeggedIncentiveConfig;
        IncentiveConfig redeemLeveragedIncentiveConfig;
    }

    /********************************
     * Events                       *
     ********************************/

    /// @notice Emitted when peggedToken is minted.
    /// @param sender The address of collateral token owner.
    /// @param recipient The address of receiver for peggedToken or leveragedToken.
    /// @param collateralTokenIn The amount of collateral token deposited.
    /// @param peggedTokenOut The amount of peggedToken minted.
    event MintPeggedToken(
        address indexed sender,
        address indexed recipient,
        uint256 collateralTokenIn,
        uint256 peggedTokenOut
    );

    /// @notice Emitted when leveragedToken is minted.
    /// @param sender The address of collateral token owner.
    /// @param recipient The address of receiver for peggedToken or leveragedToken.
    /// @param collateralTokenIn The amount of collateral token deposited.
    /// @param leveragedTokenOut The amount of leveragedToken minted.
    event MintLeveragedToken(
        address indexed sender,
        address indexed recipient,
        uint256 collateralTokenIn,
        uint256 leveragedTokenOut
    );

    /// @notice Emitted when someone redeem collateral token with peggedToken or leveragedToken.
    /// @param sender The address of peggedToken and leveragedToken owner.
    /// @param recipient The address of receiver for collateral token.
    /// @param peggedTokenBurned The amount of peggedToken burned.
    /// @param collateralTokenOut The amount of collateral token redeemed.
    event RedeemPeggedToken(
        address indexed sender,
        address indexed recipient,
        uint256 peggedTokenBurned,
        uint256 collateralTokenOut
    );

    /// @notice Emitted when someone redeem collateral token with peggedToken or leveragedToken.
    /// @param sender The address of peggedToken and leveragedToken owner.
    /// @param recipient The address of receiver for collateral token.
    /// @param leveragedTokenBurned The amount of leveragedToken burned.
    /// @param collateralTokenOut The amount of collateral token redeemed.
    event RedeemLeveragedToken(
        address indexed sender,
        address indexed recipient,
        uint256 leveragedTokenBurned,
        uint256 collateralTokenOut
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

    /********************************
     * Errors                       *
     ********************************/

    /// @dev Thrown when the oracle price is invalid.
    error InvalidOraclePrice();

    /// @dev Thrown when the oracle price is zero.
    error ZeroOraclePrice();

    /// @dev thrown when zero collateral is passed in or -1 is passed in and the balance is zero
    error ZeroInputBalance(address token);
    /// @dev Thrown when collateral is passed but mint is prevented for some other reason.
    error MintZeroAmount(address mintingToken);
    /// @dev Thrown when collateral is passed but mint is reduced below the miniumum requested.
    error MintInsufficientAmount(address mintingToken, uint256 miniumum, uint256 actual);
    error ReturnInsufficientAmount(address returningToken, uint256 miniumum, uint256 actual);
    error NoRedeemableTokens(address redeemingToken);

    /// @dev thrown if a ratio doesn't make sense in some context
    error InvalidRatio();

    error TooManyCollateralRatioBounds(uint count);
    error InvalidCollateralRatioBoundValue(uint256 shouldBeLessOrEqual, uint256 shouldBeGreaterOrEqual);
    error TooManyIncentiveRatios(uint count);
    error InvalidIncentiveRatioValue(int256 shouldBeMinusOnetoOne);
    error CollateralRatioBoundsIncentivesLengthsMismatch(uint256 oneLess, uint256 oneMore);

    /// @dev thrown when an action is paused, for example if the protocol is not initialised
    error ActionPaused();

    /********************************
     * Public View Functions        *
     ********************************/

    /// @notice Return the address of the collateral token
    function collateralToken() external view returns (address);

    /// @notice Return the address of the pegged token.
    function peggedToken() external view returns (address);

    /// @notice Return the address of the leveraged token.
    function leveragedToken() external view returns (address);

    /// @notice Return the current config.
    function config() external view returns (Config memory);

    /// @notice Return the current collateral ratio of the peggedToken to the collateral token (18 decimals).
    function collateralRatio() external view returns (uint256);

    function leverageRatio() external view returns (uint256);

    /// @notice Return the price of a leveraged token in terms of the pegged token's underlying
    function leveragedTokenPrice() external view returns (uint256);
    function leverageTokensForCollateral(uint256 forCollateral) external view returns (uint256 collateral);
    /// @notice Return the amount of collateral tokens 'forLeveragedTokens' will buy in the absence of fees and discounts
    function collateralForLeverageTokens(uint256 forLeveragedTokens) external view returns (uint256 leveragedTokens);
    function priceOracle() external view returns (address);

    function feeReceiver() external view returns (address);

    // @notice Returns the totalAmount of tokens minted and not redeemed by the minter
    function peggedTokenBalance() external view returns (uint256);
    function leveragedTokenBalance() external view returns (uint256);
    function collateralTokenBalance() external view returns (uint256);

    function mintPeggedTokenIncentiveRatio(
        uint256 additionalCollateral
    ) external view returns (int256 incentiveRatio, uint256 maxCollateral);

    function redeemPeggedTokenIncentiveRatio(uint256 peggedIn) external view returns (int256 incentiveRatio);

    function mintLeveragedTokenIncentiveRatio(uint256 collateralIn) external view returns (int256 incentiveRatio);

    function redeemLeveragedTokenIncentiveRatio(
        uint256 leveragedIn
    ) external view returns (int256 incentiveRatio, uint256 maxLeveragedTokens);

    /********************************
     * Public Mutator Functions     *
     ********************************/

    /// @notice Mint some peggedToken with some collateral token.
    /// @param collateralIn The amount of wrapped value of collateral token supplied, use `uint256(-1)` to supply all collateral token.
    /// @param recipient The address of receiver for peggedToken.
    /// @param minPeggedTokenOut The minimum amount of peggedToken should be received. 0 means no check is made.
    /// @return peggedTokenOut The amount of peggedToken should be received.
    function mintPeggedToken(
        uint256 collateralIn,
        address recipient,
        uint256 minPeggedTokenOut
    ) external returns (uint256 peggedTokenOut);

    /// @notice Mint some leveragedToken with some collateral token.
    /// @param collateralIn The amount of wrapped value of collateral token supplied, use `uint256(-1)` to supply all collateral token.
    /// @param recipient The address of receiver for leveragedToken.
    /// @param minLeveragedTokenOut The minimum amount of leveragedToken should be received. 0 means no check is made.
    /// @return leveragedTokenOut The amount of leveragedToken should be received.
    function mintLeveragedToken(
        uint256 collateralIn,
        address recipient,
        uint256 minLeveragedTokenOut
    ) external returns (uint256 leveragedTokenOut);

    /// @notice Redeem collateral token with peggedToken.
    /// @param peggedTokenIn the amount of peggedToken to redeem, use `uint256(-1)` to redeem all peggedToken.
    /// @param recipient The address of receiver for collateral token.
    /// @param minCollateralOut The minimum amount of wrapped value of collateral token should be received. 0 means no check is made.
    /// @return collateralOut The amount of wrapped value of collateral token should be received.
    function redeemPeggedToken(
        uint256 peggedTokenIn,
        address recipient,
        uint256 minCollateralOut
    ) external returns (uint256 collateralOut);

    /// @notice Redeem collateral token with leveragedToken.
    /// @param leveragedTokenIn the amount of leveragedToken to redeem, use `uint256(-1)` to redeem all leveragedToken.
    /// @param recipient The address of receiver for collateral token.
    /// @param minCollateralOut The minimum amount of wrapped value of collateral token should be received. 0 means no check is made.
    /// @return collateralOut The amount of wrapped value of collateral token should be received.
    function redeemLeveragedToken(
        uint256 leveragedTokenIn,
        address recipient,
        uint256 minCollateralOut
    ) external returns (uint256 collateralOut);

    function updateConfig(Config calldata config) external;

    function updateFeeReceiver(address feeReceiver_) external;
    function updateReservePool(address reservePool_) external;
}

interface IMinterTreasury {
    /********************************
     * Public Mutator Functions     *
     ********************************/

    function freeMintPeggedToken(uint256 collateralIn, address recipient) external returns (uint256 peggedOut);
    function freeRedeemPeggedToken(uint256 peggedIn, address recipient) external returns (uint256 collateralOut);
    function freeMintLeveragedToken(uint256 collateralIn, address recipient) external returns (uint256 leveragedOut);
    function freeRedeemLeveragedToken(uint256 leveragedIn, address recipient) external returns (uint256 collateralOut);
}
