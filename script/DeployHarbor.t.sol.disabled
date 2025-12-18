// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {HarborDeploymentJson} from "@harbor-script/deployment/HarborDeploymentJson.sol";

/**
 * @title DeployHarborTest
 * @notice Post-deployment verification tests using HarborDeploymentJson
 * @dev Run against a live deployment:
 *      forge test --fork-url <RPC_URL> --match-contract DeployHarborTest
 *
 * Environment variables:
 *   DEPLOYMENT_NETWORK - Network name (e.g., "anvil", "mainnet:1")
 *   DEPLOYMENT_SALT    - System salt string used during deployment
 *
 * Example:
 *   DEPLOYMENT_NETWORK=anvil DEPLOYMENT_SALT=DeployPegged \
 *     forge test --fork-url http://localhost:8545 --match-contract DeployHarborTest -vv
 */
contract DeployHarborTest is Test {
    // ERC1967 implementation slot
    bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    HarborDeploymentJson public deployment;

    function setUp() public {
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        string memory salt = vm.envString("DEPLOYMENT_SALT");

        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK env var required");
        require(bytes(salt).length > 0, "DEPLOYMENT_SALT env var required");

        deployment = new HarborDeploymentJson();

        // Load the latest deployment log for the given network/salt
        deployment.loadLatest(network, salt);

        console.log("=== Deployment Verification ===");
        console.log("Network:", network);
        console.log("Salt:", salt);
    }

    function test_verify() public view {
        deployment.verify();
    }

    // ============================================================================
    // Verification Helper Functions
    // ============================================================================

    /// @notice Check that an address has deployed code
    function assertHasCode(address target, string memory label) internal view {
        uint256 codeSize = target.code.length;
        assertGt(codeSize, 0, string.concat(label, " has no code"));
        console.log(string.concat(label, " code size:"), codeSize);
    }

    /// @notice Check that a proxy has an implementation set in ERC1967 slot
    function assertProxyImplementationSet(address proxy, string memory label) internal view {
        bytes32 implSlot = vm.load(proxy, IMPLEMENTATION_SLOT);
        address implementation = address(uint160(uint256(implSlot)));

        assertNotEq(implementation, address(0), string.concat(label, " implementation not set"));
        assertGt(implementation.code.length, 0, string.concat(label, " implementation has no code"));
        console.log(string.concat(label, " implementation:"), implementation);
    }

    /// @notice Get the implementation address from a proxy's ERC1967 slot
    function getProxyImplementation(address proxy) internal view returns (address) {
        bytes32 implSlot = vm.load(proxy, IMPLEMENTATION_SLOT);
        return address(uint160(uint256(implSlot)));
    }

    /// @notice Check that an Ownable contract has the expected owner
    function assertOwner(address target, address expectedOwner, string memory label) internal view {
        address actualOwner = Ownable(target).owner();
        assertEq(actualOwner, expectedOwner, string.concat(label, " owner mismatch"));
        console.log(string.concat(label, " owner:"), actualOwner);
    }

    /// @notice Check ERC20 token metadata
    function assertTokenMetadata(
        address token,
        string memory expectedName,
        string memory expectedSymbol,
        uint8 expectedDecimals,
        string memory label
    ) internal view {
        IERC20Metadata t = IERC20Metadata(token);

        assertEq(keccak256(bytes(t.name())), keccak256(bytes(expectedName)), string.concat(label, " name mismatch"));
        assertEq(
            keccak256(bytes(t.symbol())),
            keccak256(bytes(expectedSymbol)),
            string.concat(label, " symbol mismatch")
        );
        assertEq(t.decimals(), expectedDecimals, string.concat(label, " decimals mismatch"));

        console.log(string.concat(label, ":"), t.name(), t.symbol());
    }

    /// @notice Check that token has non-empty name and symbol
    function assertTokenMetadataPresent(address token, string memory label) internal view {
        IERC20Metadata t = IERC20Metadata(token);

        assertGt(bytes(t.name()).length, 0, string.concat(label, " name is empty"));
        assertGt(bytes(t.symbol()).length, 0, string.concat(label, " symbol is empty"));

        console.log(string.concat(label, ":"), t.name(), t.symbol(), t.decimals());
    }

    /// @notice Call a view function and check it doesn't revert
    function assertCallSucceeds(address target, bytes memory data, string memory label) internal view {
        (bool success, ) = target.staticcall(data);
        assertTrue(success, string.concat(label, " call failed"));
    }
}
