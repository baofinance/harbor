// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";
import {HarborMinterDeploymentJsonScript} from "@harbor-script/deployment/HarborMinterDeploymentJsonScript.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title DeployPeggedToken
 * @notice Simple script to deploy and test a pegged token on local Anvil
 * @dev Usage:
 *   1. Start Anvil: anvil
 *   2. Deploy: forge script script/DeployPeggedToken.s.sol --rpc-url http://localhost:8545 --broadcast
 *   3. Verify: forge script script/DeployPeggedToken.s.sol --rpc-url http://localhost:8545 --sig "verify()"
 */
contract DeployPegged is HarborMinterDeploymentJsonScript {
    // Anvil default accounts - account 0 is the deployer/operator
    uint256 constant PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address constant ANVIL_ACCOUNT_0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    function run() public {
        console.log("=== Deploying Pegged Token to Anvil ===");
        console.log("Deployer:", msg.sender);

        string memory network = "anvil";
        string memory salt = "DeployPegged";

        // Set private key for broadcasts
        start(network, salt, "");

        // 4. Deploy pegged token using registry parameters populated from config
        _deployPegged();

        console.log("\n=== Deployment Complete ===");
        console.log("Pegged Token:", _get(PEGGED));
        console.log("Name:", IERC20Metadata(_get(PEGGED)).name());
        console.log("Symbol:", IERC20Metadata(_get(PEGGED)).symbol());
        console.log("Decimals:", IERC20Metadata(_get(PEGGED)).decimals());

        // 5. Finish deployment (transfers ownership, saves registry)
        finish();

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
