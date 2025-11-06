// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/**
 * @title HarborKeys
 * @notice Canonical registry keys for Harbor contracts and parameters
 * @dev String constants replace enum indirection to simplify integrations
 */
library HarborKeys {
    // =========================================================================
    // Contract Keys
    // =========================================================================

    string internal constant ADMIN = "admin";
    string internal constant FEE_RECEIVER = "feeReceiver";
    string internal constant TREASURY = "treasury";
    string internal constant WRAPPED_COLLATERAL = "wrappedCollateral";
    string internal constant PEGGED = "pegged";
    string internal constant LEVERAGED = "leveraged";
    string internal constant ORACLE = "oracle";
    string internal constant MINTER = "minter";
    string internal constant RESERVE_POOL = "reservePool";
    string internal constant STABILITY_POOL_MANAGER = "stabilityPoolManager";
    string internal constant STABILITY_POOL_COLLATERAL = "stabilityPoolCollateral";
    string internal constant STABILITY_POOL_LEVERAGED = "stabilityPoolLeveraged";
    string internal constant GENESIS = "genesis";
    string internal constant REWARD_MANAGER = "rewardManager";
    string internal constant REWARD_DEPOSITOR = "rewardDepositor";
    string internal constant REBALANCER = "rebalancer";

    // Test-only contract keys (Used by unit tests & foundry fixtures)
    string internal constant TEST_PROXY1 = "testProxy1";
    string internal constant TEST_PROXY2 = "testProxy2";
    string internal constant TEST_PROXY3 = "testProxy3";

    // =========================================================================
    // Parameter Keys
    // =========================================================================

    string internal constant PEGGED_NAME = "peggedName";
    string internal constant PEGGED_SYMBOL = "peggedSymbol";
    string internal constant PEGGED_DECIMALS = "peggedDecimals";
    string internal constant LEVERAGED_NAME = "leveragedName";
    string internal constant LEVERAGED_SYMBOL = "leveragedSymbol";
    string internal constant LEVERAGED_DECIMALS = "leveragedDecimals";
    string internal constant COLLATERAL_DECIMALS = "collateralDecimals";

    string internal constant FEE_RECEIVER_NAME = "feeReceiverName";

    string internal constant STABILITY_POOL_EARLY_WITHDRAWAL_FEE = "stabilityPoolEarlyWithdrawalFee";
    string internal constant STABILITY_POOL_MIN_DEPOSIT = "stabilityPoolMinDeposit";

    string internal constant INITIAL_EXCHANGE_RATE = "initialExchangeRate";
    string internal constant FEE_PERCENTAGE = "feePercentage";

    // =========================================================================
    // Helper Views
    // =========================================================================

    /**
     * @notice Identifies contract keys expected to be deployed behind proxies
     * @return proxyable Array of contract keys
     */
    function proxyableContracts() internal pure returns (string[] memory proxyable) {
        proxyable = new string[](10);
        proxyable[0] = FEE_RECEIVER;
        proxyable[1] = WRAPPED_COLLATERAL;
        proxyable[2] = PEGGED;
        proxyable[3] = LEVERAGED;
        proxyable[4] = RESERVE_POOL;
        proxyable[5] = MINTER;
        proxyable[6] = STABILITY_POOL_MANAGER;
        proxyable[7] = STABILITY_POOL_COLLATERAL;
        proxyable[8] = STABILITY_POOL_LEVERAGED;
        proxyable[9] = GENESIS;
    }
}
