// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "@bao-test/deployment/BaoDeploymentTest.sol";
import {BaoFactoryBytecode} from "@bao-factory/BaoFactoryBytecode.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {DeployPeggedBase} from "script/bao-basedeployment/DeployPeggedBase.sol";
import {DeploymentState} from "script/bao-basedeployment/DeploymentState.sol";
import {DeploymentTypes} from "script/bao-basedeployment/DeploymentTypes.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice In-memory DeploymentState: reuse base logic, skip file IO.
contract MockDeploymentState is DeploymentState {
    function load(
        string memory network,
        string memory saltPrefix,
        bool useLocal
    ) external pure override returns (DeploymentTypes.State memory state) {
        state.network = network;
        state.saltPrefix = saltPrefix;
        state.useLocal = useLocal;
        return state;
    }

    function save(DeploymentTypes.State memory) external pure override {}
}

/// @notice Test harness for pegged token deployment.
contract TestDeployPeggedHarness is DeployPeggedBase {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function _createStateStore() internal override returns (DeploymentState) {
        return DeploymentState(address(new MockDeploymentState()));
    }

    function baoFactory() public pure override returns (address) {
        return BaoFactoryBytecode.PREDICTED_PROXY;
    }

    // Expose for testing
    function deployAllPeggedTokensWrapper(string memory systemSalt, string memory network, bool useLocal) external {
        deployAllPeggedTokens(systemSalt, network, useLocal);
    }
}

contract DeployPeggedTest is BaoDeploymentTest {
    TestDeployPeggedHarness private harness;
    address private baoFactory;

    function setUp() public override {
        super.setUp();
        baoFactory = _baoFactory;

        // Create test harness after factory is ready
        harness = new TestDeployPeggedHarness();

        // Allow harness to deploy via factory
        vm.prank(IBaoFactory(baoFactory).owner());
        IBaoFactory(baoFactory).setOperator(address(harness), 365 days);
    }

    function test_deployAllPeggedTokens() public {
        string memory systemSalt = "test_pegged";
        string memory network = "mainnet";

        // Deploy all pegged tokens
        harness.deployAllPeggedTokensWrapper(systemSalt, network, true);
        address[4] memory peggedTokens = _predictPeggedTokens(systemSalt);

        // Verify 4 pegged tokens were deployed
        for (uint256 i = 0; i < peggedTokens.length; i++) {
            assertTrue(peggedTokens[i] != address(0), "Token address should not be zero");
        }

        // Verify each pegged token via ABI
        _verifyPeggedTokenViaABI(peggedTokens[0], "Harbor anchored ETH", "haETH");
        _verifyPeggedTokenViaABI(peggedTokens[1], "Harbor anchored BTC", "haBTC");
        _verifyPeggedTokenViaABI(peggedTokens[2], "Harbor anchored GOLD", "haGOLD");
        _verifyPeggedTokenViaABI(peggedTokens[3], "Harbor anchored EUR", "haEUR");
    }

    function _predictPeggedTokens(string memory systemSalt) internal view returns (address[4] memory tokens) {
        tokens[0] = IBaoFactory(baoFactory).predictAddress(keccak256(abi.encodePacked(systemSalt, "::", "ETH")));
        tokens[1] = IBaoFactory(baoFactory).predictAddress(keccak256(abi.encodePacked(systemSalt, "::", "BTC")));
        tokens[2] = IBaoFactory(baoFactory).predictAddress(keccak256(abi.encodePacked(systemSalt, "::", "GOLD")));
        tokens[3] = IBaoFactory(baoFactory).predictAddress(keccak256(abi.encodePacked(systemSalt, "::", "EUR")));
    }

    /// @notice Verify a pegged token via ABI calls.
    function _verifyPeggedTokenViaABI(
        address tokenAddr,
        string memory expectedName,
        string memory expectedSymbol
    ) private view {
        MintableBurnableERC20_v1 token = MintableBurnableERC20_v1(tokenAddr);
        assertEq(token.name(), expectedName, "Wrong name");
        assertEq(token.symbol(), expectedSymbol, "Wrong symbol");
        assertEq(token.decimals(), 18, "Wrong decimals");
    }
}
