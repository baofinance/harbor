// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "@bao-test/deployment/BaoDeploymentTest.sol";
import {HarborDeploymentBase} from "script/bao-basedeployment/HarborDeploymentBase.sol";
import {DeploymentState} from "script/bao-basedeployment/DeploymentState.sol";
import {DeploymentTypes} from "script/bao-basedeployment/DeploymentTypes.sol";
import {Config_MinterMarket} from "script/config/ConfigBase.sol";
import {Config_Market_ETH_fxUSD} from "script/config/markets/Config_Market_ETH_fxUSD.sol";
import {Config_Market_BTC_fxUSD} from "script/config/markets/Config_Market_BTC_fxUSD.sol";
import {Config_Market_BTC_stETH} from "script/config/markets/Config_Market_BTC_stETH.sol";
import {BaoFactoryDeployment} from "@bao-factory/BaoFactoryDeployment.sol";

/// @notice Test harness for Harbor deployment.
contract HarborDeploymentHarness is HarborDeploymentBase {
    using DeploymentState for DeploymentTypes.State;

    string private constant PREFIX = "results/";

    // Expose internal functions for testing (public but with _ prefix to avoid Forge treating them as tests)
    function _startDeploymentWrapper(
        string memory network,
        string memory saltPrefix,
        bool useLocal
    ) public returns (DeploymentTypes.State memory state) {
        address baoFactory = BaoFactoryDeployment.predictBaoFactoryAddress();
        state = DeploymentState.load(network, saltPrefix, useLocal, PREFIX);
        state.baoFactory = baoFactory;
        return state;
    }

    function _deployMinterMarketWrapper(
        DeploymentTypes.State memory state,
        Config_MinterMarket config
    ) public view returns (DeploymentTypes.State memory) {
        return deployMinterMarket(state, config);
    }

    function _finishDeploymentWrapper(DeploymentTypes.State memory state) public {
        DeploymentState.save(state, PREFIX);
    }
}

contract HarborDeploymentTest is BaoDeploymentTest {
    HarborDeploymentHarness private deployer;

    function setUp() public override {
        deployer = new HarborDeploymentHarness();
    }

    function test_deployMultipleMarkets() public {
        string memory systemSalt = "harbor_v1";
        // Define markets to deploy
        Config_MinterMarket[] memory markets = new Config_MinterMarket[](3);
        markets[0] = new Config_Market_ETH_fxUSD();
        markets[1] = new Config_Market_BTC_fxUSD();
        markets[2] = new Config_Market_BTC_stETH();

        // Start deployment session
        DeploymentTypes.State memory state = deployer._startDeploymentWrapper("mainnet", systemSalt, true);

        // Deploy each market
        for (uint256 i = 0; i < markets.length; i++) {
            state = deployer._deployMinterMarketWrapper(state, markets[i]);
        }

        // Finish and save state
        deployer._finishDeploymentWrapper(state);

        // Verify state file was created (in results/deployments/, not project root)
        string memory expectedPath = string.concat(
            vm.projectRoot(),
            "/results/deployments/local/mainnet/harbor_v1.state.json"
        );
        assertTrue(vm.exists(expectedPath));
    }

    function test_deploymentPattern() public {
        string memory systemSalt = "test_pattern";
        // This demonstrates the intended usage pattern for deployment scripts:
        // 1. Script inherits from HarborDeploymentBase
        // 2. Script lists configs to deploy
        // 3. Script calls startDeployment(), loops deployMinterMarket(), calls finishDeployment()

        Config_MinterMarket config = new Config_Market_ETH_fxUSD();

        DeploymentTypes.State memory state = deployer._startDeploymentWrapper("mainnet", systemSalt, true);
        state = deployer._deployMinterMarketWrapper(state, config);
        deployer._finishDeploymentWrapper(state);
    }
}
