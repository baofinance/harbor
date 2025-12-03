// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";
// import {HarborDeploymentFoundry} from "@harbor-script/deployment/HarborDeploymentFoundry.sol";

/**
 * @title DeployHarbor
 * @notice Deploy complete Harbor system with real tokens and oracle
 * @dev Uses the unified finishDeployment() pattern:
 *      1. Load environment variables
 *      2. Configure with production addresses
 *      3. Call finishDeployment() to deploy everything
 *      4. Save deployment to JSON
 *
 * Environment variables required:
 *   - PRIVATE_KEY: Deployer private key
 *   - COLLATERAL_TOKEN: Address of wrapped collateral (e.g., wstETH)
 *   - PEGGED_TOKEN: Address of pegged token (e.g., baoUSD) or 0x0 to deploy
 *   - ORACLE_ADDRESS: Address of price oracle
 *   - TREASURY: Treasury address (optional, defaults to admin)
 *   - REWARD_MANAGER: Reward manager address
 *   - REWARD_DEPOSITOR: Reward depositor address
 *   - REBALANCER: Rebalancer address
 *
 * Usage:
 *   forge script script/DeployHarbor.s.sol \
 *     --rpc-url <rpc> \
 *     --broadcast \
 *     --verify
 */
/* contract DeployHarbor is Script {
    function run() public {
        // Load environment variables
        // TODO: this should be loaded from a single json file
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address collateralToken = vm.envAddress("COLLATERAL_TOKEN");
        address peggedToken = vm.envOr("PEGGED_TOKEN", address(0)); // Optional - deploy if 0x0
        address oracleAddress = vm.envAddress("ORACLE_ADDRESS");
        address baomultisig = vm.envAddress("MULTISIG");
        address treasuryAddress = vm.envOr("TREASURY", baomultisig);
        address rewardManager = vm.envAddress("REWARD_MANAGER");
        address rewardDepositor = vm.envAddress("REWARD_DEPOSITOR");
        address rebalancer = vm.envAddress("REBALANCER");

        console.log("\n=== Deploying Harbor System ===");
        console.log("Network:", block.chainid);
        console.log("Deployer:", vm.addr(deployerKey));
        console.log("Owner:", baomultisig);
        console.log("Treasury:", treasuryAddress);

        // Create HarborDeployment contract BEFORE broadcast (script-only, not deployed on-chain)
        // HarborDeploymentFoundry harbor = new HarborDeploymentFoundry();

        // Build config from environment variables
        console.log("\n--- Building config from environment ---");
        string memory config = string.concat(
            '{"schemaVersion":1,"version":"v1.0.0","owner":"',
            vm.toString(baomultisig),
            '","treasury":"',
            vm.toString(treasuryAddress),
            '","collateral":{"address":"',
            vm.toString(collateralToken),
            '"}'
        );
        if (peggedToken != address(0)) {
            config = string.concat(config, ',"pegged":{"address":"', vm.toString(peggedToken), '"}');
        }
        config = string.concat(config, "}");

        // Configure with production addresses (script-side setup)
        console.log("\n--- Starting deployment ---");
        vm.startBroadcast(deployerKey);

        string memory network = string.concat("mainnet:", vm.toString(block.chainid));
        harbor.start(config, network);

        // Now broadcast the actual Harbor contract deployments
        console.log("\n--- Configuring contracts on-chain ---");
        harbor.useCollateralToken(collateralToken);

        // Handle pegged token - use existing or will deploy
        if (peggedToken != address(0)) {
            harbor.usePeggedToken(peggedToken);
            console.log("Using existing pegged token:", peggedToken);
        } else {
            console.log("Pegged token will be deployed");
        }

        harbor.useOracle(oracleAddress);
        harbor.useRewardManager(rewardManager);
        harbor.useRewardDepositor(rewardDepositor);
        harbor.useRebalancer(rebalancer);

        // Deploy everything
        console.log("\n--- Deploying all contracts ---");
        harbor.finish();

        vm.stopBroadcast();

        // Save deployment
        console.log("\n--- Saving deployment ---");

        // Print summary
        console.log("\n=== Deployment Summary ===");
        console.log("Owner:", harbor.get(HarborKeys.OWNER));
        console.log("Fee Receiver:", harbor.get(HarborKeys.FEE_RECEIVER));
        console.log("Treasury:", harbor.get(HarborKeys.TREASURY));
        console.log("Wrapped Collateral:", harbor.get(HarborKeys.WRAPPED_COLLATERAL));
        console.log("Pegged:", harbor.get(HarborKeys.PEGGED));
        console.log("Leveraged:", harbor.get(HarborKeys.LEVERAGED));
        console.log("Oracle:", harbor.get(HarborKeys.ORACLE));
        console.log("Reserve Pool:", harbor.get(HarborKeys.RESERVE_POOL));
        console.log("Minter:", harbor.get(HarborKeys.MINTER));
        console.log("Stability Pool (Collateral):", harbor.get(HarborKeys.STABILITY_POOL_COLLATERAL));
        console.log("Stability Pool (Leveraged):", harbor.get(HarborKeys.STABILITY_POOL_LEVERAGED));
        console.log("Stability Pool Manager:", harbor.get(HarborKeys.STABILITY_POOL_MANAGER));
        console.log("Genesis:", harbor.get(HarborKeys.GENESIS));
        console.log("Reward Manager:", harbor.get(HarborKeys.REWARD_MANAGER));
        console.log("Reward Depositor:", harbor.get(HarborKeys.REWARD_DEPOSITOR));
        console.log("Rebalancer:", harbor.get(HarborKeys.REBALANCER));

        console.log("\n=== Deployment Complete ===");
    }
}
 */
