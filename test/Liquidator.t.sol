// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { UnsafeUpgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IERC1967 } from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IMinter } from "src/minter/IMinter.sol";
import { IOwnableRoles } from "@bao/interfaces/IOwnableRoles.sol";
import { IRebalancePool } from "src/minter/IRebalancePool.sol";
import { RebalancePool_v1 } from "src/minter/RebalancePool_v1.sol";
import { LeveragedToken_v1 } from "src/minter/LeveragedToken_v1.sol";
import { IRebalancePool } from "src/minter/IRebalancePool.sol";

import { Token } from "@bao/Token.sol";
import { IPriceOracle } from "src/price/IPriceOracle.sol";

import { deployed } from "test/deployed.sol";
import { MockPriceOracle } from "test/MockPriceOracle.sol";
import { IBaoUSD } from "test/IBaoUSD.sol";
import "test/Useful.sol";
import { TestRebalancePoolSetUp } from "test/RebalancePool.t.sol";

import "test/clog.sol";

contract TestLiquidator is TestRebalancePoolSetUp {
    function test_storage() public pure {
        console2.logBytes32(
            keccak256(abi.encode(uint256(keccak256("bao.storage.Liquidator")) - 1)) & ~bytes32(uint256(0xff))
        );
    }
}
