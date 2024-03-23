// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.25;

import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { Minter_v1 } from "src/Minter_v1.sol";

import { deployed } from "./deployed.sol";

contract LeveragedToken {}

contract Test_MinterInitialisation is Test {
    //Minter_v1 minter;
    LeveragedToken lToken;

    function setUp() public {
        //minter = new Minter_v1();
        lToken = new LeveragedToken();
    }

    function test_tokens() public {
        bytes32 id = keccak256(abi.encode(uint256(keccak256("bao.storage.Minter")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(id, 0x92e73fe9557052b4a0b810a38eb7ef595ff750f166ca39d63b3f4c74937fef00);

        //vm.expectEmit(true, true, false, false);
        address proxy = Upgrades.deployUUPSProxy(
            "Minter_v1.sol",
            abi.encodeCall(Minter_v1.initialize, (address(this), deployed.wstETH, deployed.BaoUSD, address(lToken)))
        );

        // The event we expect
        // emit Initialized(address(this), address(1337), 1337);

        Minter_v1 minter = Minter_v1(proxy);
        assertEq(minter.collateralToken(), deployed.wstETH);
        assertEq(minter.peggedToken(), deployed.BaoUSD);
        assertEq(minter.leveragedToken(), address(lToken));

        // expect a revert if initialize called twice
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        minter.initialize(address(0), address(0), address(0), address(0));
    }
}

contract Test_Minter is Test {
    Minter_v1 minter;
    LeveragedToken lToken;

    function setUp() public {
        address proxy = Upgrades.deployUUPSProxy(
            "Minter_v1.sol",
            abi.encodeCall(Minter_v1.initialize, (address(this), deployed.wstETH, deployed.BaoUSD, address(lToken)))
        );
        minter = Minter_v1(proxy);
        lToken = new LeveragedToken();
    }
}
