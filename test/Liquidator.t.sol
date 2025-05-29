// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMinter} from "src/interfaces/IMinter.sol";
// import { IBaoOwnableRoles } from "@bao/interfaces/IBaoOwnableRoles.sol";
import {IStabilityPool} from "src/interfaces/IRebalancePool.sol";
import {StabilityPool_v1} from "src/minter/RebalancePool_v1.sol";
import {LeveragedToken_v1} from "src/minter/LeveragedToken_v1.sol";
import {IStabilityPool} from "src/interfaces/IRebalancePool.sol";

import {Token} from "@bao/Token.sol";
import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";

import {Deployed} from "@bao/Deployed.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";
import {IBaoUSD} from "test/IBaoUSD.sol";
import "test/Useful.sol";
import {TestStabilityPoolSetUp} from "test/RebalancePool.t.sol";

import "test/clog.sol";

contract TestLiquidator is TestStabilityPoolSetUp {
    function test_storage() public pure {}
}
