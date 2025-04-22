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

import {IMinter} from "@interfaces/IMinter.sol";
// import { IBaoOwnableRoles } from "@bao/interfaces/IBaoOwnableRoles.sol";
import {IRebalancePool} from "@interfaces/IRebalancePool.sol";
import {RebalancePool_v1} from "src/minter/RebalancePool_v1.sol";
import {LeveragedToken_v1} from "src/minter/LeveragedToken_v1.sol";
import {IRebalancePool} from "@interfaces/IRebalancePool.sol";

import {Token} from "@bao/Token.sol";
import {IPriceOracle} from "@interfaces/IPriceOracle.sol";

import {Deployed} from "@bao/Deployed.sol";
import {MockPriceOracle} from "test/mock/MockPriceOracle.sol";
import {IBaoUSD} from "test/IBaoUSD.sol";
import "test/Useful.sol";
import {TestRebalancePoolSetUp} from "test/RebalancePool.t.sol";

import "test/clog.sol";

contract TestLiquidator is TestRebalancePoolSetUp {
    function test_storage() public pure {}
}
