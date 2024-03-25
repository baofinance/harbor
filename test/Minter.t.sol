// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.25;

import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { Minter_v1 } from "src/minter/Minter_v1.sol";
//import { IMinter } from "src/IMinter.sol";
import { deployed } from "./deployed.sol";
import { MockPriceOracle } from "./MockPriceOracle.sol";
import { MockRateProvider } from "./MockRateProvider.sol";

import { LeveragedToken_v1 } from "src/minter/LeveragedToken_v1.sol";

contract Test_Minter is Test {
    Minter_v1 minter;
    LeveragedToken_v1 lToken;
    MockPriceOracle priceOracle;
    MockRateProvider rateProvider;

    function deployLeveragedToken() private returns (LeveragedToken_v1) {
        return
            LeveragedToken_v1(
                Upgrades.deployUUPSProxy(
                    "LeveragedToken_v1.sol",
                    abi.encodeCall(LeveragedToken_v1.initialize, (address(this), "Leveraged Token", "BaoL"))
                )
            );
    }

    function setUp() public {
        //lToken = deployLeveragedToken();
        priceOracle = new MockPriceOracle();
        rateProvider = new MockRateProvider();

        //deal(address(deployed.wstETH), address(this), 20 ether);

        // minter = Minter_v1(
        //     Upgrades.deployUUPSProxy(
        //         "Minter_v1.sol",
        //         abi.encodeCall(
        //             Minter_v1.initialize,
        //             (
        //                 address(this),
        //                 deployed.BaoUSD,
        //                 address(lToken),
        //                 deployed.wstETH,
        //                 address(priceOracle),
        //                 address(rateProvider),
        //                 10 ether,
        //                 1 ether / 2
        //             )
        //         )
        //     )
        // );
    }

    function test_initEvents() public {
        vm.expectEmit(false, false, false, true);
        emit Initializable.Initialized(type(uint64).max); // from the logic contract constructor
        vm.expectEmit(false, false, false, true);
        emit Initializable.Initialized(1); // from the proxy delegate call

        Upgrades.deployUUPSProxy(
            "Minter_v1.sol",
            abi.encodeCall(
                Minter_v1.initialize,
                (
                    address(this),
                    deployed.BaoUSD,
                    address(lToken),
                    deployed.wstETH,
                    address(priceOracle),
                    address(rateProvider),
                    1 ether,
                    1 ether / 2
                )
            )
        );
    }

    function test_init() public {
        bytes32 id = keccak256(abi.encode(uint256(keccak256("bao.storage.Minter")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(id, 0x92e73fe9557052b4a0b810a38eb7ef595ff750f166ca39d63b3f4c74937fef00);

        // expect a revert if initialize called twice
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        minter.initialize(
            address(0),
            address(0),
            address(0),
            address(0),
            address(0),
            address(0),
            10 ether,
            1 ether / 2
        );

        assertEq(minter.collateralToken(), deployed.wstETH);
        assertEq(minter.peggedToken(), deployed.BaoUSD);
        assertEq(minter.leveragedToken(), address(lToken));
    }

    // function testFuzz_SetNumber(uint256 x) public {
    //     counter.setNumber(x);
    //     assertEq(counter.number(), x);
    //}
}
