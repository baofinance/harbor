// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

//import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IMinter } from "src/minter/IMinter.sol";
import { deployed } from "test/deployed.sol";
import { IPriceOracle } from "src/price/IPriceOracle.sol";
import { MockPriceOracle } from "test/MockPriceOracle.sol";

import "test/Useful.sol";
import { TestMinterFeeSetup } from "test/Minter_fees.t.sol";

contract TestMinterMint is TestMinterFeeSetup {
    using SafeERC20 for IERC20;

    Vm.Wallet system;
    Vm.Wallet sender;
    Vm.Wallet receiver;

    function setUpConfig() public override {
        setUpConfig(
            130,
            250,
            ic(ua(131), ia(disallow, 50)),
            ic(ua(), ia(70)),
            ic(ua(), ia(80)),
            ic(ua(110), ia(disallow, 120))
        );
    }

    function setUp() public virtual override {
        super.setUp();
        system = vm.createWallet("system");
        sender = vm.createWallet("sender");
        receiver = vm.createWallet("receiver");
        setUp_permissions();
    }
}
