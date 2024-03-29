// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.25;

interface IMinter {
    /****************************
     * Data Structures          *
     ****************************/

    struct MinterTokens {
        address peggedToken;
        address leveragedToken;
        address collateralToken;
    }

    struct MintPeggedTokenConfig {
        // TODO: check that the below are packed
        uint64 criticalCollateralRatio;
        uint64 defaultFeeRatio;
        uint64 maximumFeeRatio;
    }

    struct RedeemPeggedTokenConfig {
        uint64 criticalCollateralRatio;
        uint64 defaultFeeRatio;
        uint64 bonusRatio;
    }

    struct MintLeveragedTokenConfig {
        uint64 criticalCollateralRatio;
        uint64 defaultFeeRatio;
        uint64 bonusRatio;
    }

    struct RedeemLeveragedTokenConfig {
        uint64 criticalCollateralRatio;
        uint64 defaultFeeRatio;
        uint64 maximumFeeRatio;
    }

    /****************************
     * Events                   *
     ****************************/

    /// @notice Emitted when pToken is minted.
    /// @param owner The address of collateral token owner.
    /// @param recipient The address of receiver for pToken or lToken.
    /// @param collateralTokenIn The amount of collateral token deposited.
    /// @param pTokenOut The amount of pToken minted.
    /// @param mintFee The amount of mint fee charged in terms of collateral token.
    event MintPeggedToken(
        address indexed owner,
        address indexed recipient,
        uint256 collateralTokenIn,
        uint256 pTokenOut,
        uint256 mintFee
    );

    /// @notice Emitted when lToken is minted.
    /// @param owner The address of collateral token owner.
    /// @param recipient The address of receiver for pToken or lToken.
    /// @param collateralTokenIn The amount of collateral token deposited.
    /// @param lTokenOut The amount of lToken minted.
    /// @param bonus The amount of collateral token as bonus.
    /// @param mintFee The amount of mint fee charged.
    event MintLeveragedToken(
        address indexed owner,
        address indexed recipient,
        uint256 collateralTokenIn,
        uint256 lTokenOut,
        uint256 bonus,
        uint256 mintFee
    );

    /// @notice Emitted when someone redeem collateral token with pToken or lToken.
    /// @param owner The address of pToken and lToken owner.
    /// @param recipient The address of receiver for collateral token.
    /// @param pTokenBurned The amount of pToken burned.
    /// @param collateralTokenOut The amount of collateral token redeemed.
    /// @param bonus The amount of collateral token as bonus.
    /// @param redeemFee The amount of redeem fee charged.
    event RedeemPeggedToken(
        address indexed owner,
        address indexed recipient,
        uint256 pTokenBurned,
        uint256 collateralTokenOut,
        uint256 bonus,
        uint256 redeemFee
    );

    /// @notice Emitted when someone redeem collateral token with pToken or lToken.
    /// @param owner The address of pToken and lToken owner.
    /// @param recipient The address of receiver for collateral token.
    /// @param lTokenBurned The amount of lToken burned.
    /// @param collateralTokenOut The amount of collateral token redeemed.
    /// @param redeemFee The amount of redeem fee charged.
    event RedeemLeveragedToken(
        address indexed owner,
        address indexed recipient,
        uint256 lTokenBurned,
        uint256 collateralTokenOut,
        uint256 redeemFee
    );

    /// @notice Emitted when the fee config for minting pegged tokens is updated.
    /// @param config The new mint config.
    event UpdateMintPeggedTokenConfig(MintPeggedTokenConfig config);

    /// @notice Emitted when the fee ratio for minting xToken is updated.
    /// @param config The new mint config.
    event UpdateMintLeveragedTokenConfig(MintLeveragedTokenConfig config);

    /// @notice Emitted when the fee ratio for redeeming fToken is updated.
    /// @param config The new redeem config.
    event UpdateRedeemPeggedTokenConfig(RedeemPeggedTokenConfig config);

    /// @notice Emitted when the fee ratio for redeeming xToken is updated.
    /// @param config The new redeem config.
    event UpdateRedeemLeveragedTokenConfig(RedeemLeveragedTokenConfig config);

    /// @notice Emitted when the platform contract is updated.
    /// @param oldPlatform The address of previous platform contract.
    /// @param newPlatform The address of current platform contract.
    event UpdatePlatform(address indexed oldPlatform, address indexed newPlatform);

    /// @notice Emitted when the  reserve pool contract is updated.
    /// @param oldReservePool The address of previous reserve pool contract.
    /// @param newReservePool The address of current reserve pool contract.
    event UpdateReservePool(address indexed oldReservePool, address indexed newReservePool);

    /****************************
     * Errors                   *
     ****************************/

    /// @dev Thrown when the oracle price is invalid.
    error InvalidOraclePrice();

    /// @dev Thrown when the oracle price is zero.
    error ZeroOraclePrice();

    /// @dev thrown when zero collateral is passed in or -1 is passed in and the balance is zero
    error ZeroBalance();

    /// @dev thrown if a ratio doesn't make sense in some context
    error InvalidRatio();

    error InsufficientOutput(address mintingToken);

    /// @dev Thrown when mint with zero amount base token.
    error MintZeroAmount();

    /****************************
     * Public View Functions    *
     ****************************/

    /// @notice Return the address of the collateral (collateral) token
    function collateralToken() external view returns (address);

    /// @notice Return the address of the pegged token.
    function peggedToken() external view returns (address);

    /// @notice Return the address of the leveraged token.
    function leveragedToken() external view returns (address);

    /// @notice Return the current collateral ratio of the pToken to the collateral token, multipled by 1e18.
    function collateralRatio() external view returns (uint256);

    function priceOracle() external view returns (address);

    //function rateProvider() external view returns (address);

    // @notice Returns the totalAmount of tokens minted and not redeemed by the minter
    function peggedTokenBalance() external view returns (uint256);

    function mintPeggedTokenFeeRatio(uint256 collateralIn) external view returns (uint256 fees);

    /****************************
     * Public Mutated Functions *
     ****************************/

    /// @notice Mint some fToken with some collateral token.
    /// @param collateralIn The amount of wrapped value of collateral token supplied, use `uint256(-1)` to supply all collateral token.
    /// @param recipient The address of receiver for fToken.
    /// @param minFTokenMinted The minimum amount of fToken should be received.
    /// @return fTokenMinted The amount of fToken should be received.
    function mintPeggedToken(
        uint256 collateralIn,
        address recipient,
        uint256 minFTokenMinted
    ) external returns (uint256 fTokenMinted);

    /// @notice Mint some lToken with some collateral token.
    /// @param collateralIn The amount of wrapped value of collateral token supplied, use `uint256(-1)` to supply all collateral token.
    /// @param recipient The address of receiver for lToken.
    /// @param minXTokenMinted The minimum amount of lToken should be received.
    /// @return lTokenMinted The amount of lToken should be received.
    /// @return bonus The amount of wrapped value of collateral token as bonus.
    function mintLeveragedToken(
        uint256 collateralIn,
        address recipient,
        uint256 minXTokenMinted
    ) external returns (uint256 lTokenMinted, uint256 bonus);

    /// @notice Redeem collateral token with fToken.
    /// @param fTokenIn the amount of fToken to redeem, use `uint256(-1)` to redeem all fToken.
    /// @param recipient The address of receiver for collateral token.
    /// @param minCollateralOut The minimum amount of wrapped value of collateral token should be received.
    /// @return collateralOut The amount of wrapped value of collateral token should be received.
    /// @return bonus The amount of wrapped value of collateral token as bonus.
    function redeemPeggedToken(
        uint256 fTokenIn,
        address recipient,
        uint256 minCollateralOut
    ) external returns (uint256 collateralOut, uint256 bonus);

    /// @notice Redeem collateral token with lToken.
    /// @param lTokenIn the amount of lToken to redeem, use `uint256(-1)` to redeem all lToken.
    /// @param recipient The address of receiver for collateral token.
    /// @param minCollateralOut The minimum amount of wrapped value of collateral token should be received.
    /// @return collateralOut The amount of wrapped value of collateral token should be received.
    function redeemLeveragedToken(
        uint256 lTokenIn,
        address recipient,
        uint256 minCollateralOut
    ) external returns (uint256 collateralOut);
}

interface IMinterTreasury {
    /****************************
     * Public Mutated Functions *
     ****************************/

    function freeMintPeggedToken(uint256 collateralIn, address recipient) external returns (uint256 peggedTokenOut);
}
