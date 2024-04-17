// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface IMinter {
    /****************************
     * Data Structures          *
     ****************************/

    struct BalanceTokens {
        address peggedToken;
        address leveragedToken;
        address collateralToken;
    }

    /*
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
    // TODO: separate each config for mint/redeem pegged/leveraged
    // because: we may want to increase mint pegged fees before reducing redeem leveraged, etc.
    // need to also minimise storage accesses
    struct CollateralRatioBoundsConfig {
        uint256 bonusCollateralRatioUpperBound;
        uint256 rebalanceCollateralRatioUpperBound;
        uint256 dangerCollateralRatioUpperBound;
        uint256 normalCollateralRatioUpperBound;
    }
    struct FeeConfigForAction {
        uint256 bonusFeeRatio;
        uint256 rebalanceFeeRatio;
        uint256 dangerFeeRatio;
        uint256 normalFeeRatio;
        uint256 safeFeeRatio;
    }

    struct FeeConfig {
        FeeConfigForAction mintPeggedToken;
        FeeConfigForAction redeemPeggedToken;
        FeeConfigForAction mintLeveragedToken;
        FeeConfigForAction redeemLeveragedToken;
    }

    struct BonusConfig {
        address bonusToken; // must be owned by the Minter, and if it is the collateral token then only those above the collateral depsited, so need to track this
        // bonus can also be an xtoken? then these must be minted and given to the Minter
        uint256 mintLeveragedBonusRatio;
        uint256 redeemPeggedBonusRatio;
    }

    struct PauseConfig {
        uint256 mintPeggedToken;
        uint256 redeemPeggedToken;
        uint256 mintLeveragedToken;
        uint256 redeemLeveragedToken;
    }

    /****************************
     * Events                   *
     ****************************/

    /// @notice Emitted when peggedToken is minted.
    /// @param sender The address of collateral token owner.
    /// @param recipient The address of receiver for peggedToken or leveragedToken.
    /// @param collateralTokenIn The amount of collateral token deposited.
    /// @param peggedTokenOut The amount of peggedToken minted.
    /// @param mintFee The amount of mint fee charged in terms of collateral token.
    event MintPeggedToken(
        address indexed sender,
        address indexed recipient,
        uint256 collateralTokenIn,
        uint256 peggedTokenOut,
        uint256 mintFee
    );

    /// @notice Emitted when leveragedToken is minted.
    /// @param sender The address of collateral token owner.
    /// @param recipient The address of receiver for peggedToken or leveragedToken.
    /// @param collateralTokenIn The amount of collateral token deposited.
    /// @param leveragedTokenOut The amount of leveragedToken minted.
    /// @param bonus The amount of collateral token as bonus.
    /// @param mintFee The amount of mint fee charged.
    event MintLeveragedToken(
        address indexed sender,
        address indexed recipient,
        uint256 collateralTokenIn,
        uint256 leveragedTokenOut,
        uint256 mintFee,
        uint256 bonus
    );

    /// @notice Emitted when someone redeem collateral token with peggedToken or leveragedToken.
    /// @param sender The address of peggedToken and leveragedToken owner.
    /// @param recipient The address of receiver for collateral token.
    /// @param peggedTokenBurned The amount of peggedToken burned.
    /// @param collateralTokenOut The amount of collateral token redeemed.
    /// @param bonus The amount of collateral token as bonus.
    /// @param redeemFee The amount of redeem fee charged.
    event RedeemPeggedToken(
        address indexed sender,
        address indexed recipient,
        uint256 peggedTokenBurned,
        uint256 collateralTokenOut,
        uint256 bonus,
        uint256 redeemFee
    );

    /// @notice Emitted when someone redeem collateral token with peggedToken or leveragedToken.
    /// @param sender The address of peggedToken and leveragedToken owner.
    /// @param recipient The address of receiver for collateral token.
    /// @param lTokenBurned The amount of leveragedToken burned.
    /// @param collateralTokenOut The amount of collateral token redeemed.
    /// @param redeemFee The amount of redeem fee charged.
    event RedeemLeveragedToken(
        address indexed sender,
        address indexed recipient,
        uint256 lTokenBurned,
        uint256 collateralTokenOut,
        uint256 redeemFee
    );

    event UpdateCollateralRatioConfig(CollateralRatioBoundsConfig config);
    event UpdateFeeConfig(FeeConfig config);
    event UpdateBonusConfig(BonusConfig config);

    /// @notice Emitted when the platform contract is updated.
    /// @param oldFeeReceiver The address of previous platform contract.
    /// @param newFeeReceiver The address of current platform contract.
    event UpdateFeeReceiver(address indexed oldFeeReceiver, address indexed newFeeReceiver);

    /// @notice Emitted when the price oracle contract is updated.
    /// @param oldPriceOracle The address of previous price oracle contract.
    /// @param newPriceOracle The address of current price oracle contract.
    event UpdatePriceOracle(address indexed oldPriceOracle, address indexed newPriceOracle);

    /*
    /// @notice Emitted when the  reserve pool contract is updated.
    /// @param oldReservePool The address of previous reserve pool contract.
    /// @param newReservePool The address of current reserve pool contract.
    event UpdateReservePool(address indexed oldReservePool, address indexed newReservePool);
    */

    /****************************
     * Errors                   *
     ****************************/

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

    /// @dev thrown if a ratio doesn't make sense in some context
    error InvalidRatio();

    error InvalidCollateralRatioConfig(uint256 shouldBeLessOrEqual, uint256 shouldBeGreaterOrEqual);
    error InvalidFeeConfig();
    error InvalidBonusConfig();

    /****************************
     * Public View Functions    *
     ****************************/

    /// @notice Return the address of the collateral (collateral) token
    function collateralToken() external view returns (address);

    /// @notice Return the address of the pegged token.
    function peggedToken() external view returns (address);

    /// @notice Return the address of the leveraged token.
    function leveragedToken() external view returns (address);

    /// @notice Return the current collateral ratio of the peggedToken to the collateral token, multipled by 1e18.
    function collateralRatio() external view returns (uint256);

    function leveragedTokenNAV() external view returns (uint256);
    function leverageTokensForCollateral(uint256 forCollateral) external view returns (uint256);

    function priceOracle() external view returns (address);

    function feeReceiver() external view returns (address);

    // @notice Returns the totalAmount of tokens minted and not redeemed by the minter
    function peggedTokenBalance() external view returns (uint256);
    function leveragedTokenBalance() external view returns (uint256);
    function collateralTokenBalance() external view returns (uint256);

    function mintPeggedTokenFeeRatio(uint256 additionalCollateral) external view returns (uint256 fees);

    function redeemPeggedTokenFeeRatio() external view returns (uint256 fees);

    function mintLeveragedTokenFeeRatio() external view returns (uint256 fees);

    function redeemLeveragedTokenFeeRatio(uint256 reductionOfcollateral) external view returns (uint256 fees);

    /****************************
     * Public Mutated Functions *
     ****************************/

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
    /// @return bonus The amount of wrapped value of collateral token as bonus.
    function mintLeveragedToken(
        uint256 collateralIn,
        address recipient,
        uint256 minLeveragedTokenOut
    ) external returns (uint256 leveragedTokenOut, uint256 bonus);

    /// @notice Redeem collateral token with peggedToken.
    /// @param peggedTokenIn the amount of peggedToken to redeem, use `uint256(-1)` to redeem all peggedToken.
    /// @param recipient The address of receiver for collateral token.
    /// @param minCollateralOut The minimum amount of wrapped value of collateral token should be received. 0 means no check is made.
    /// @return collateralOut The amount of wrapped value of collateral token should be received.
    /// @return bonus The amount of wrapped value of collateral token as bonus.
    function redeemPeggedToken(
        uint256 peggedTokenIn,
        address recipient,
        uint256 minCollateralOut
    ) external returns (uint256 collateralOut, uint256 bonus);

    /// @notice Redeem collateral token with leveragedToken.
    /// @param lTokenIn the amount of leveragedToken to redeem, use `uint256(-1)` to redeem all leveragedToken.
    /// @param recipient The address of receiver for collateral token.
    /// @param minCollateralOut The minimum amount of wrapped value of collateral token should be received. 0 means no check is made.
    /// @return collateralOut The amount of wrapped value of collateral token should be received.
    function redeemLeveragedToken(
        uint256 lTokenIn,
        address recipient,
        uint256 minCollateralOut
    ) external returns (uint256 collateralOut);

    function updateCollateralRatioConfig(CollateralRatioBoundsConfig calldata collateralRatioConfig_) external;

    function updateFeeConfig(FeeConfig calldata feeConfig_) external;

    function updateBonusConfig(BonusConfig calldata bonusConfig_) external;
}

interface IMinterTreasury {
    /****************************
     * Public Mutated Functions *
     ****************************/

    function freeMintPeggedToken(uint256 collateralIn, address recipient) external returns (uint256 peggedTokenOut);
    function freeMintLeveragedToken(
        uint256 collateralIn,
        address recipient
    ) external returns (uint256 leveragedTokenOut);
}
