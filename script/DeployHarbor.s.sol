// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";
import {HarborDeploymentFoundry} from "@harbor-script/deployment/HarborDeploymentFoundry.sol";

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
 *   - ADMIN_ADDRESS: Admin address for ownership
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
contract DeployHarbor is Script {
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
        console.log("Admin:", baomultisig);
        console.log("Treasury:", treasuryAddress);

        // Create HarborDeployment contract BEFORE broadcast (script-only, not deployed on-chain)
        HarborDeploymentFoundry harbor = new HarborDeploymentFoundry();

        // Configure with production addresses (script-side setup)
        console.log("\n--- Configuring deployment (script-side) ---");
        vm.startBroadcast(deployerKey);

        // Now broadcast the actual Harbor contract deployments
        console.log("\n--- Deploying contracts on-chain ---");
        harbor.useAdmin(baomultisig);
        harbor.useCollateralToken(collateralToken);

        // Handle pegged token - use existing or will deploy
        if (peggedToken != address(0)) {
            harbor.usePeggedToken(peggedToken);
            console.log("Using existing pegged token:", peggedToken);
        } else {
            console.log("Pegged token will be deployed");
        }

        harbor.useOracle(oracleAddress);
        harbor.useTreasury(treasuryAddress);
        harbor.useRewardManager(rewardManager);
        harbor.useRewardDepositor(rewardDepositor);
        harbor.useRebalancer(rebalancer);

        // Deploy everything
        console.log("\n--- Deploying all contracts ---");
        harbor.finish();

        vm.stopBroadcast();

        // Save deployment
        console.log("\n--- Saving deployment ---");
        // string memory filename = string.concat("harbor-", vm.toString(block.chainid), ".json");
        // string memory filepath = string.concat("results/deployments/", filename);
        // TODO: how are we going to handle chainid's v meaningful names
        harbor.start(baomultisig, "eek", "v1.0.0", "Bao.Harbor");

        // Print summary
        console.log("\n=== Deployment Summary ===");
        console.log("Admin:", harbor.getAdmin());
        console.log("Fee Receiver:", harbor.getFeeReceiver());
        console.log("Treasury:", harbor.getTreasury());
        console.log("Wrapped Collateral:", harbor.getCollateralToken());
        console.log("Pegged:", harbor.getPeggedToken());
        console.log("Leveraged:", harbor.getLeveragedToken());
        console.log("Oracle:", harbor.getOracle());
        console.log("Reserve Pool:", harbor.getReservePool());
        console.log("Minter:", harbor.getMinter());
        console.log("Stability Pool (Collateral):", harbor.getStabilityPoolCollateral());
        console.log("Stability Pool (Leveraged):", harbor.getStabilityPoolLeveraged());
        console.log("Stability Pool Manager:", harbor.getStabilityPoolManager());
        console.log("Genesis:", harbor.getGenesis());
        console.log("Reward Manager:", harbor.getRewardManager());
        console.log("Reward Depositor:", harbor.getRewardDepositor());
        console.log("Rebalancer:", harbor.getRebalancer());

        console.log("\n=== Deployment Complete ===");
    }
}
