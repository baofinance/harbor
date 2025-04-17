// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Stem} from "../../src/common/Stem.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Mock contracts for testing
import {MockImplementation} from "../mocks/MockImplementation.sol";
import {MockImplementationWithState} from "../mocks/MockImplementationWithState.sol";
import {MockImplementationWithImmutables} from "../mocks/MockImplementationWithImmutables.sol";

contract StemTest is Test {
    Stem public stemImplementation;
    address public proxyAdmin = address(1);
    address public user = address(2);
    address public emergencyOwner = address(3);

    function setUp() public {
        // Deploy the Stem implementation
        stemImplementation = new Stem();
    }

    // --- SCENARIO 1: INITIAL DEPLOYMENT TESTS ---

    function testInitialDeployment() public {
        // 1. Deploy proxy with Stem implementation
        bytes memory initData = abi.encodeWithSelector(
            Stem.initialize.selector,
            proxyAdmin // Initial owner is the deployment script/admin
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(stemImplementation), initData);
        Stem stemProxy = Stem(address(proxy));

        // Verify initialization
        assertEq(stemProxy.owner(), proxyAdmin);

        // 2. Deploy the actual implementation we want to use
        MockImplementation actualImplementation = new MockImplementation();

        // 3. Upgrade from Stem to actual implementation
        vm.prank(proxyAdmin);
        stemProxy.upgradeTo(address(actualImplementation));

        // 4. Initialize the actual implementation
        MockImplementation implementation = MockImplementation(address(proxy));
        vm.prank(proxyAdmin);
        implementation.initialize(42);

        // Verify actual implementation works
        assertEq(implementation.value(), 42);
        assertEq(implementation.owner(), proxyAdmin); // Ownership carries over
    }

    function testCannotReinitializeImplementation() public {
        vm.expectRevert();
        stemImplementation.initialize(address(this));
    }

    function testNonOwnerCannotUpgrade() public {
        // Deploy proxy with Stem
        bytes memory initData = abi.encodeWithSelector(Stem.initialize.selector, proxyAdmin);
        ERC1967Proxy proxy = new ERC1967Proxy(address(stemImplementation), initData);
        Stem stemProxy = Stem(address(proxy));

        // Deploy new implementation
        MockImplementation newImplementation = new MockImplementation();

        // Non-owner cannot upgrade
        vm.prank(user);
        vm.expectRevert("BaoOwnable: caller is not the owner");
        stemProxy.upgradeTo(address(newImplementation));
    }

    // --- SCENARIO 2: EMERGENCY PAUSE TESTS (SAME OWNER) ---

    function testEmergencyPauseSameOwner() public {
        // 1. Start with a running implementation
        MockImplementationWithState actualImplementation = new MockImplementationWithState();
        bytes memory initData = abi.encodeWithSelector(
            MockImplementationWithState.initialize.selector,
            proxyAdmin, // Owner
            100 // Initial value
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(actualImplementation), initData);
        MockImplementationWithState implementation = MockImplementationWithState(address(proxy));

        // System is up and running
        assertEq(implementation.value(), 100);

        // Increase value (normal operation)
        vm.prank(proxyAdmin);
        implementation.incrementValue();
        assertEq(implementation.value(), 101);

        // 2. Emergency! Upgrade to Stem to pause functionality
        vm.prank(proxyAdmin);
        implementation.upgradeTo(address(stemImplementation));

        // 3. Now the proxy points to Stem - verify we can't call the original functions
        vm.expectRevert(); // Any function call should revert
        implementation.incrementValue();

        // 4. Deploy fixed implementation
        MockImplementationWithState fixedImplementation = new MockImplementationWithState();

        // 5. Upgrade back from Stem to fixed implementation
        vm.prank(proxyAdmin);
        Stem(address(proxy)).upgradeTo(address(fixedImplementation));

        // 6. State is preserved after upgrade
        assertEq(implementation.value(), 101);
    }

    // --- SCENARIO 3: EMERGENCY PAUSE TESTS (DIFFERENT OWNER) ---

    function testEmergencyPauseDifferentOwner() public {
        // 1. Start with a running implementation
        MockImplementationWithState actualImplementation = new MockImplementationWithState();
        bytes memory initData = abi.encodeWithSelector(
            MockImplementationWithState.initialize.selector,
            proxyAdmin, // Owner
            100 // Initial value
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(actualImplementation), initData);
        MockImplementationWithState implementation = MockImplementationWithState(address(proxy));

        // Original owner is proxyAdmin
        assertEq(implementation.owner(), proxyAdmin);

        // 2. EMERGENCY! Original owner (proxyAdmin) is compromised!
        // Deploy new Stem and upgrade to it with new secure owner
        Stem newStem = new Stem();

        vm.prank(proxyAdmin); // Last action of the compromised owner
        implementation.upgradeTo(address(newStem));

        // Initialize Stem with a new secure owner
        bytes memory reinitData = abi.encodeWithSelector(Stem.initialize.selector, emergencyOwner);

        // This would generally be done through a specialized emergency upgrade mechanism
        // or a fallback admin, but for testing we just call it directly
        (bool success, ) = address(proxy).call(reinitData);
        require(success, "Reinitialization failed");

        // 3. Verify ownership changed
        assertEq(Stem(address(proxy)).owner(), emergencyOwner);

        // 4. Original compromised owner can't perform upgrades anymore
        vm.prank(proxyAdmin);
        vm.expectRevert("BaoOwnable: caller is not the owner");
        Stem(address(proxy)).upgradeTo(address(0x123));

        // 5. New emergency owner can upgrade to fixed implementation
        MockImplementationWithState fixedImplementation = new MockImplementationWithState();

        vm.prank(emergencyOwner);
        Stem(address(proxy)).upgradeTo(address(fixedImplementation));

        // 6. State is preserved, but ownership is now the emergency owner
        assertEq(implementation.value(), 100);

        // 7. Emergency owner can transfer ownership back to the original owner (if desired)
        vm.prank(emergencyOwner);
        implementation.transferOwnership(proxyAdmin);

        // Ownership is transferred
        assertEq(implementation.owner(), proxyAdmin);
    }

    // --- ADDITIONAL SCENARIOS WITH IMMUTABLES AND STATE CHANGES ---

    function testUpgradeWithImmutables() public {
        // 1. Start with Stem proxy
        bytes memory initData = abi.encodeWithSelector(Stem.initialize.selector, proxyAdmin);
        ERC1967Proxy proxy = new ERC1967Proxy(address(stemImplementation), initData);
        Stem stemProxy = Stem(address(proxy));

        // 2. Upgrade to implementation with immutables
        MockImplementationWithImmutables immutableImpl = new MockImplementationWithImmutables(999);

        vm.prank(proxyAdmin);
        stemProxy.upgradeTo(address(immutableImpl));

        // 3. Verify immutable values are preserved
        MockImplementationWithImmutables proxiedImpl = MockImplementationWithImmutables(address(proxy));
        assertEq(proxiedImpl.immutableValue(), 999);

        // 4. Initialize state variables
        vm.prank(proxyAdmin);
        proxiedImpl.initialize(123);

        // 5. Verify both immutable and state values work
        assertEq(proxiedImpl.immutableValue(), 999); // Immutable from implementation
        assertEq(proxiedImpl.stateValue(), 123); // State from proxy storage
    }

    function testComplexStateTransfer() public {
        // 1. Deploy starter implementation and initialize
        MockImplementationWithState initialImpl = new MockImplementationWithState();
        bytes memory initData = abi.encodeWithSelector(
            MockImplementationWithState.initialize.selector,
            proxyAdmin,
            100 // Initial value
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(initialImpl), initData);
        MockImplementationWithState proxiedImpl = MockImplementationWithState(address(proxy));

        // 2. Make state changes
        vm.prank(proxyAdmin);
        proxiedImpl.incrementValue();
        assertEq(proxiedImpl.value(), 101);

        // 3. Pause by upgrading to Stem
        vm.prank(proxyAdmin);
        proxiedImpl.upgradeTo(address(stemImplementation));

        // 4. Deploy enhanced implementation
        MockImplementation enhancedImpl = new MockImplementation();

        // 5. Upgrade from Stem to enhanced implementation
        vm.prank(proxyAdmin);
        Stem(address(proxy)).upgradeTo(address(enhancedImpl));

        // 6. Initialize the new implementation
        // Note: This would typically revert if the initializer had already been called
        // For testing, we assume this MockImplementation allows reinitialization
        vm.prank(proxyAdmin);
        MockImplementation(address(proxy)).initialize(999);

        // 7. Verify enhanced functionality works with expected value
        assertEq(MockImplementation(address(proxy)).value(), 999);
    }
}
