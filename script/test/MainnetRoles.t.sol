// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {HarborFactoryDeployer} from "@harbor/../script/src/HarborFactoryDeployer.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IMinter} from "src/interfaces/IMinter.sol";

/// @notice Verify that all deployed StabilityPoolManagers have the expected
/// roles on their minters. This catches missing role grants in deploy scripts.
/// @dev Run against any fork:
///   forge test --mp script/test/MainnetRoles.t.sol --fork-url mainnet -vv
///   forge test --mp script/test/MainnetRoles.t.sol --fork-url local -vv
contract MainnetRoles is Test, HarborFactoryDeployer {
    struct Market {
        string peg;
        string collateral;
    }

    Market[] markets;

    function setUp() public {
        // Use --fork-url to select the target (mainnet, local anvil, etc.)
        // Only create a fork if one isn't already active (i.e. no --fork-url was passed)
        if (block.chainid != 1) {
            vm.createSelectFork(vm.rpcUrl("mainnet"));
        }

        _setSaltPrefix("harbor_v1");

        markets.push(Market("BTC", "fxUSD"));
        markets.push(Market("BTC", "stETH"));
        markets.push(Market("ETH", "fxUSD"));
        markets.push(Market("EUR", "fxUSD"));
        markets.push(Market("EUR", "stETH"));
        markets.push(Market("GOLD", "fxUSD"));
        markets.push(Market("GOLD", "stETH"));
        markets.push(Market("MCAP", "fxUSD"));
        markets.push(Market("MCAP", "stETH"));
        markets.push(Market("SILVER", "fxUSD"));
        markets.push(Market("SILVER", "stETH"));
    }

    function test_allSPMs_haveZeroFeeRole() public view {
        for (uint256 i = 0; i < markets.length; i++) {
            string memory marketKey = string.concat(markets[i].peg, "::", markets[i].collateral);
            address minter = _predictAddressFromFullSalt(_saltString(marketKey, "minter"));
            address spm = _predictAddressFromFullSalt(_saltString(marketKey, "stabilityPoolManager"));

            uint256 zeroFeeRole = IMinter(minter).ZERO_FEE_ROLE();
            assertTrue(
                IBaoRoles(minter).hasAllRoles(spm, zeroFeeRole),
                string.concat(marketKey, "::stabilityPoolManager missing ZERO_FEE_ROLE on minter")
            );
        }
    }

    function test_allSPMs_haveHarvesterRole() public view {
        for (uint256 i = 0; i < markets.length; i++) {
            string memory marketKey = string.concat(markets[i].peg, "::", markets[i].collateral);
            address minter = _predictAddressFromFullSalt(_saltString(marketKey, "minter"));
            address spm = _predictAddressFromFullSalt(_saltString(marketKey, "stabilityPoolManager"));

            uint256 harvesterRole = IMinter(minter).HARVESTER_ROLE();
            assertTrue(
                IBaoRoles(minter).hasAllRoles(spm, harvesterRole),
                string.concat(marketKey, "::stabilityPoolManager missing HARVESTER_ROLE on minter")
            );
        }
    }

    function test_allGenesis_haveZeroFeeRole() public view {
        for (uint256 i = 0; i < markets.length; i++) {
            string memory marketKey = string.concat(markets[i].peg, "::", markets[i].collateral);
            address minter = _predictAddressFromFullSalt(_saltString(marketKey, "minter"));
            address genesis = _predictAddressFromFullSalt(_saltString(marketKey, "genesis"));

            uint256 zeroFeeRole = IMinter(minter).ZERO_FEE_ROLE();
            assertTrue(
                IBaoRoles(minter).hasAllRoles(genesis, zeroFeeRole),
                string.concat(marketKey, "::genesis missing ZERO_FEE_ROLE on minter")
            );
        }
    }
}
