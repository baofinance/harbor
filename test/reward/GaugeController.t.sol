// SPDX-License-Identifier: MIT
pragma solidity >=0.8.21 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {IGaugeController} from "src/interfaces/IGaugeController.sol";

contract GaugeControllerTest is Test {
    IGaugeController public controller;
    address public gauge1;
    address public gauge2;
    address public admin;

    function setUp() public {
        // Deploy the Gauge Controller and add a gauge type
        controller = IGaugeController(vm.deployCode("GaugeController.vy", abi.encode(address(0xDEAD), address(0x1234))));
        controller.add_type("Liquidity", 1);
        gauge1 = makeAddr("gauge1");
        gauge2 = makeAddr("gauge2");
        admin = address(this);
    }

    function testAddGaugeAndType() public {
        controller.add_gauge(gauge1, 0, 1);
        assertEq(controller.gauge_types(gauge1), 0);
    }

    function testGaugeRelativeWeightDefault() public {
        controller.add_gauge(gauge1, 0, 1);
        uint256 weight = controller.gauge_relative_weight(gauge1, block.timestamp);
        assertEq(weight, 1e18, "Should return full weight by default");
    }

    function testMultipleGaugeTypes() public {
        controller.add_gauge(gauge1, 0, 1);
        controller.add_gauge(gauge2, 1, 2);

        assertEq(controller.gauge_types(gauge1), 0);
        assertEq(controller.gauge_types(gauge2), 1);
    }

    function testNonAdminCannotAddGauge() public {
        address nonAdmin = makeAddr("nonAdmin");
        vm.expectRevert();
        vm.prank(nonAdmin);
        controller.add_gauge(gauge1, 0, 1);
    }
}
