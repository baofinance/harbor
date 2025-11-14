// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";
import {HarborDeploymentFoundry} from "@harbor-script/deployment/HarborDeploymentFoundry.sol";
import {PeggedTokenDeployer} from "@harbor-script/deployment/deployers/PeggedTokenDeployer.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title DeployPeggedToken
 * @notice Simple script to deploy and test a pegged token on local Anvil
 * @dev Usage:
 *   1. Start Anvil: anvil
 *   2. Deploy: forge script script/DeployPeggedToken.s.sol --rpc-url http://localhost:8545 --broadcast
 *   3. Verify: forge script script/DeployPeggedToken.s.sol --rpc-url http://localhost:8545 --sig "verify()"
 */
contract DeployPeggedToken is Script {
    HarborDeploymentFoundry public harbor;
    address public deployedToken;

    // Default Anvil account (first account with known private key)
    address constant ANVIL_DEFAULT = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    function run() public {
        console.log("=== Deploying Pegged Token to Anvil ===");
        console.log("Deployer:", msg.sender);

        vm.startBroadcast();

        // 1. Create deployment harness
        harbor = new HarborDeploymentFoundry();
        console.log("Harbor deployment harness created");

        // 2. Deploy BaoDeployer infrastructure
        harbor.deployBaoDeployer();
        console.log("BaoDeployer infrastructure deployed");

        // 3. Start deployment session
        string memory config = string.concat(
            '{"schemaVersion":1,"version":"v1.0.0","owner":"',
            vm.toString(ANVIL_DEFAULT),
            '","pegged":{"name":"Bao USD","symbol":"baoUSD","registryKey":"pegged"}',
            ',"collateral":{"registryKey":"wrappedCollateral"}}'
        );
        harbor.start(config, "anvil-local");
        console.log("Deployment session started");

        // 4. Deploy pegged token with explicit parameters
        deployedToken = PeggedTokenDeployer.deploy(
            harbor,
            ANVIL_DEFAULT, // admin
            "Bao USD", // name
            "baoUSD" // symbol
        );

        console.log("\n=== Deployment Complete ===");
        console.log("Pegged Token:", deployedToken);
        console.log("Name:", IERC20Metadata(deployedToken).name());
        console.log("Symbol:", IERC20Metadata(deployedToken).symbol());
        console.log("Decimals:", IERC20Metadata(deployedToken).decimals());

        // 5. Finish deployment (transfers ownership, saves registry)
        harbor.finish();

        vm.stopBroadcast();

        console.log("\nDeployment registry saved to: results/anvil-local/");
    }

    /**
     * @notice Verify the deployed token
     * @dev Run after deployment: forge script script/DeployPeggedToken.s.sol --rpc-url http://localhost:8545 --sig "verify()"
     */
    function verify() public view {
        // Read the saved deployment to get token address
        console.log("=== Verifying Deployed Token ===");

        // For now, you need to pass the token address manually
        // In a real scenario, we'd read from the saved JSON
        address token = vm.envAddress("PEGGED_TOKEN");

        console.log("Token address:", token);
        console.log("Name:", IERC20Metadata(token).name());
        console.log("Symbol:", IERC20Metadata(token).symbol());
        console.log("Decimals:", IERC20Metadata(token).decimals());

        // Verify expected values
        require(keccak256(bytes(IERC20Metadata(token).name())) == keccak256(bytes("Bao USD")), "Name mismatch");
        require(keccak256(bytes(IERC20Metadata(token).symbol())) == keccak256(bytes("baoUSD")), "Symbol mismatch");
        require(IERC20Metadata(token).decimals() == 18, "Decimals mismatch");

        console.log("All checks passed!");
    }
}
