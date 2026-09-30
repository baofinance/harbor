// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeployedMarket} from "@harbor-test/harness/DeployedMarket.sol";
import {LocalMarket} from "@harbor-test/harness/LocalMarket.sol";
import {LocalMarketConfig} from "@harbor-test/config/LocalMarketConfig.sol";
import {MarketDeployRun} from "@harbor-test/harness/MarketDeployRun.sol";
import {V3Rule} from "@harbor-test/harness/MarketRule.sol";
import {MockStabilityPoolMarketDeployRun} from "@harbor-test/harness/MockStabilityPoolMarketDeployRun.sol";

// The provenance record a market writes beside its data says which contract answers at each of its addresses
// and which one sits behind it. It NAMES them, so the record changes when what a market is built from changes
// and at no other time: not when a test moves an address, and not when a build compiles the same source to
// different bytecode. Code this tree did not build - what was on chain at the pinned block - has no name here
// and is recorded as its address, which the block pins.
//
// One test to a contract: each stands its own market up and writes its own file.

contract LocalMarketProvenanceTest is LocalMarket {
    /// A market built by this tree's deploy chain is recorded by contract name throughout, and the wrapped
    /// collateral - the one address in it this tree did not build - as that address.
    function test_aLocalMarketsRecordNamesTheContractBehindEveryProxy() public {
        string memory runName = string.concat(marketLabel(), "_provenanceTest");
        standUpMarket(0.4 ether, 0.4 ether, runName);

        string memory expected = string.concat("lineage,", reader.lineage(), ",\n");
        expected = string.concat(expected, "contract,code at the address,implementation\n");
        expected = string.concat(expected, "minter,BaoERC1967Proxy,Minter_v3\n");
        expected = string.concat(expected, "manager,BaoERC1967Proxy,StabilityPoolManager_v2\n");
        expected = string.concat(expected, "collateralPool,BaoERC1967Proxy,StabilityPool_v3\n");
        expected = string.concat(expected, "leveragedPool,BaoERC1967Proxy,StabilityPool_v3\n");
        expected = string.concat(expected, "pegged,BaoERC1967Proxy,MintableBurnableERC20_v2\n");
        expected = string.concat(expected, "leveraged,BaoERC1967Proxy,MintableBurnableERC20_v2\n");
        expected = string.concat(
            expected,
            "wrappedCollateral,",
            vm.toString(market.wrappedCollateral),
            ",(not-a-proxy)\n"
        );
        expected = string.concat(expected, "oracle,MockWrappedPriceOracle,(not-a-proxy)\n");

        assertEq(
            vm.readFile(string.concat("results/provenance", runName, ".csv")),
            expected,
            "the record names what the deploy chain built"
        );
    }
}

contract MockPoolMarketProvenanceTest is LocalMarket {
    function newDeployRun() internal override returns (MarketDeployRun) {
        return
            new MockStabilityPoolMarketDeployRun(
                owner(),
                treasury(),
                MarketDeployRun.Scope.Market,
                new LocalMarketConfig()
            );
    }

    /// A mock standing in for a contract it inherits from is recorded as the mock. The two differ by a handful
    /// of accessors, and a record that called both by the real contract's name would hide the substitution it
    /// exists to show.
    function test_aMockIsNamedAsTheMockNotAsTheContractItInherits() public {
        string memory runName = string.concat(marketLabel(), "_provenanceTest_mockPools");
        standUpMarket(0.4 ether, 0.4 ether, runName);

        string memory expected = string.concat("lineage,", reader.lineage(), ",\n");
        expected = string.concat(expected, "contract,code at the address,implementation\n");
        expected = string.concat(expected, "minter,BaoERC1967Proxy,Minter_v3\n");
        expected = string.concat(expected, "manager,BaoERC1967Proxy,StabilityPoolManager_v2\n");
        expected = string.concat(expected, "collateralPool,BaoERC1967Proxy,MockStabilityPool\n");
        expected = string.concat(expected, "leveragedPool,BaoERC1967Proxy,MockStabilityPool\n");
        expected = string.concat(expected, "pegged,BaoERC1967Proxy,MintableBurnableERC20_v2\n");
        expected = string.concat(expected, "leveraged,BaoERC1967Proxy,MintableBurnableERC20_v2\n");
        expected = string.concat(
            expected,
            "wrappedCollateral,",
            vm.toString(market.wrappedCollateral),
            ",(not-a-proxy)\n"
        );
        expected = string.concat(expected, "oracle,MockWrappedPriceOracle,(not-a-proxy)\n");

        assertEq(
            vm.readFile(string.concat("results/provenance", runName, ".csv")),
            expected,
            "the pools are recorded as the mock that answers for them"
        );
    }
}

contract UpgradedDeployedMarketProvenanceTest is DeployedMarket {
    constructor() {
        useRule(new V3Rule());
    }

    /// On the deployed market with this tree's upgrade behind it, the record separates what the chain holds
    /// from what was built here: a deployed proxy is its address, an implementation built here is its name, an
    /// implementation left as deployed is its address, and the oracle is the mock etched over a deployed proxy
    /// whose implementation pointer it left in place.
    function test_aDeployedMarketsRecordSeparatesChainCodeFromBuiltCode() public {
        string memory runName = string.concat(marketLabel(), overrideLabel(), "_provenanceTest");
        standUpMarket(0.4 ether, 0.4 ether, runName);

        string memory expected = string.concat("lineage,", reader.lineage(), ",\n");
        expected = string.concat(expected, "contract,code at the address,implementation\n");
        expected = string.concat(expected, "minter,", vm.toString(market.minter), ",Minter_v3\n");
        expected = string.concat(expected, "manager,ERC1967Proxy,StabilityPoolManager_v2\n");
        expected = string.concat(
            expected,
            "collateralPool,",
            vm.toString(market.collateralPool),
            ",StabilityPool_v3\n"
        );
        expected = string.concat(expected, "leveragedPool,", vm.toString(market.leveragedPool), ",StabilityPool_v3\n");
        // The three implementations below are the chain's own at the pinned block: the upgrade leaves both
        // tokens alone, and neither the wrapped collateral nor the oracle is this market's to upgrade.
        expected = string.concat(
            expected,
            "pegged,",
            vm.toString(market.pegged),
            ",",
            vm.toString(0x5C7606b5De7c130982b9841D9b4B9C107d394bC7),
            "\n"
        );
        expected = string.concat(
            expected,
            "leveraged,",
            vm.toString(market.leveraged),
            ",",
            vm.toString(0x8e56A7c8047D5E995386875B9E23cFfEa56169d8),
            "\n"
        );
        expected = string.concat(
            expected,
            "wrappedCollateral,",
            vm.toString(market.wrappedCollateral),
            ",",
            vm.toString(0xE4031e271809d20074E4bef1caeEfEc5f710e8A6),
            "\n"
        );
        expected = string.concat(
            expected,
            "oracle,MockWrappedPriceOracle,",
            vm.toString(0x63d961913cd855f5f8C8cA7cDC22771abA3326FE),
            "\n"
        );

        assertEq(
            vm.readFile(string.concat("results/provenance", runName, ".csv")),
            expected,
            "chain code is recorded by address and built code by name"
        );
    }
}
