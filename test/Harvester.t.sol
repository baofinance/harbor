pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {TestMinterSetUp} from "test/Minter_base.t.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";

import {IMinter} from "src/interfaces/IMinter.sol";
import {Harvester_v1, IHarvester, IBounty} from "src/minter/Harvester_v1.sol";

contract Test_HarvesterSetup is TestMinterSetUp {
    address harvester;
    address harvestReceiver;
    address bountyReceiver;
    address treasury;

    function setUp() public virtual override {
        super.setUp();

        setUp_collateral(10 ether, 10 ether);
        harvestReceiver = vm.createWallet("harvestReceiver").addr;
        bountyReceiver = vm.createWallet("bountyReceiver").addr;
        treasury = vm.createWallet("treasury").addr;

        address[] memory receivers = new address[](1);
        receivers[0] = harvestReceiver;
        harvester = address(
            Harvester_v1(
                UnsafeUpgrades.deployUUPSProxy(
                    address(new Harvester_v1(minter, receivers, treasury)), //"Harvester_v1.sol",
                    abi.encodeCall(Harvester_v1.initialize, (owner))
                )
            )
        );
        IBaoOwnable(harvester).transferOwnership(owner);
    }
}

contract Test_HarvesterAccess is Test_HarvesterSetup {
    function test_access() public {
        (, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        assertEq(rate, 1 ether, "start with rate of 1");

        IHarvester(harvester).harvest(harvestReceiver, 0);

        // add 10 more wrapped collateral
        deal(IMinter(minter).WRAPPED_COLLATERAL_TOKEN(), owner, 10 ether);
        IERC20(IMinter(minter).WRAPPED_COLLATERAL_TOKEN()).transfer(minter, 10 ether);

        assertEq(IMinter(minter).harvestable(), 10 ether, "added collateral is harvestable");

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IHarvester(harvester).harvest(harvestReceiver, 0);
    }
}

contract Test_HarvesterBasics is Test_HarvesterSetup {
    function setUp() public virtual override {
        super.setUp();
        uint256 harvesterRole = IMinter(minter).HARVESTER_ROLE();
        vm.prank(IBaoOwnable(minter).owner());
        IBaoRoles(minter).grantRoles(harvester, harvesterRole);
    }

    function test_harvester0() public {
        assertEq(IERC20(IMinter(minter).WRAPPED_COLLATERAL_TOKEN()).balanceOf(harvestReceiver), 0);
        assertEq(IMinter(minter).harvestable(), 0, "nothing harvestable");
        // a zero harvest silently doesn't happen
        IHarvester(harvester).harvest(harvestReceiver, 0);
        assertEq(IERC20(IMinter(minter).WRAPPED_COLLATERAL_TOKEN()).balanceOf(harvestReceiver), 0);
    }

    function test_harvester10() public {
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        // 10% harvestable
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, (rate * 110) / 100); // 10% increase
        // collateral = 20 ether, wrapped now is worth 20 ether * 110 / 100
        // difference = 20 ether - 20 ether * 100 / 110
        uint256 harvestable = 20 ether - uint256(100 * 20 ether) / 110;
        assertEq(IMinter(minter).harvestable(), harvestable, "10% harvestable");

        // now do the harvest, simple absolute bounty
        uint256 bounty = 1e17;
        vm.prank(owner);
        IBounty(harvester).setBounty(bounty, 0, false); // fixed bounty

        // test minimum functionality
        assertEq(IERC20(IMinter(minter).WRAPPED_COLLATERAL_TOKEN()).balanceOf(harvestReceiver), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IHarvester.InsufficientBounty.selector,
                IHarvester(harvester).BOUNTY_TOKEN(),
                bounty,
                2 ether
            )
        );
        IHarvester(harvester).harvest(harvestReceiver, 2 ether);

        // now do a real harvest
        uint256 collateralRatio = IMinter(minter).collateralRatio();
        assertEq(IERC20(IMinter(minter).WRAPPED_COLLATERAL_TOKEN()).balanceOf(harvestReceiver), 0);
        assertEq(IERC20(IMinter(minter).WRAPPED_COLLATERAL_TOKEN()).balanceOf(bountyReceiver), 0);
        IHarvester(harvester).harvest(bountyReceiver, 0);
        assertEq(IMinter(minter).collateralRatio(), collateralRatio, "collateral ratio should be unchanged");
        assertEq(IERC20(IMinter(minter).WRAPPED_COLLATERAL_TOKEN()).balanceOf(harvestReceiver), harvestable - bounty);
        assertEq(IERC20(IMinter(minter).WRAPPED_COLLATERAL_TOKEN()).balanceOf(bountyReceiver), bounty);
    }

    function test_harvesterPercent() public {
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, (rate * 110) / 100); // 10% increase
        uint256 harvestable = IMinter(minter).harvestable();

        // now do the harvest, simple absolute bounty
        uint256 bounty = (harvestable * 1e17) / 1 ether;
        vm.prank(owner);
        IBounty(harvester).setBounty(0, 1e17 /* 10% */, false); // 10% bounty

        IHarvester(harvester).harvest(bountyReceiver, 0);
        assertEq(IERC20(IMinter(minter).WRAPPED_COLLATERAL_TOKEN()).balanceOf(harvestReceiver), harvestable - bounty);
        assertEq(IERC20(IMinter(minter).WRAPPED_COLLATERAL_TOKEN()).balanceOf(bountyReceiver), bounty);
    }

    function test_harvesterhigherRatio() public {
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, (rate * 110) / 100); // 10% increase
        uint256 harvestable = IMinter(minter).harvestable();

        uint256 bounty = (harvestable * 5e17) / 1 ether;
        vm.prank(owner);
        IBounty(harvester).setBounty(1e17, 5e17 /* 50% */, false);
        assertGt(bounty, 1e17, "ratio is greater");

        IHarvester(harvester).harvest(bountyReceiver, 0);
        assertEq(IERC20(IMinter(minter).WRAPPED_COLLATERAL_TOKEN()).balanceOf(harvestReceiver), harvestable - bounty);
        assertEq(IERC20(IMinter(minter).WRAPPED_COLLATERAL_TOKEN()).balanceOf(bountyReceiver), bounty);
    }

    function test_harvesterhigherAmount() public {
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, (rate * 110) / 100); // 10% increase
        uint256 harvestable = IMinter(minter).harvestable();

        uint256 bounty = 5e17;
        vm.prank(owner);
        IBounty(harvester).setBounty(5e17, 1e16 /* 1% */, false);
        assertGt(bounty, (harvestable * 5e16) / 1 ether, "amount is greater");

        IHarvester(harvester).harvest(bountyReceiver, 0);
        assertEq(IERC20(IMinter(minter).WRAPPED_COLLATERAL_TOKEN()).balanceOf(harvestReceiver), harvestable - bounty);
        assertEq(IERC20(IMinter(minter).WRAPPED_COLLATERAL_TOKEN()).balanceOf(bountyReceiver), bounty);
    }

    function test_harvesterlowertRatio() public {
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, (rate * 110) / 100); // 10% increase
        uint256 harvestable = IMinter(minter).harvestable();

        uint256 bounty = 1e17;
        vm.prank(owner);
        IBounty(harvester).setBounty(1e17, 5e17 /* 50% */, true);
        assertLt(bounty, (harvestable * 5e17) / 1 ether, "amount is less");

        IHarvester(harvester).harvest(bountyReceiver, 0);
        assertEq(IERC20(IMinter(minter).WRAPPED_COLLATERAL_TOKEN()).balanceOf(harvestReceiver), harvestable - bounty);
        assertEq(IERC20(IMinter(minter).WRAPPED_COLLATERAL_TOKEN()).balanceOf(bountyReceiver), bounty);
    }

    function test_harvesterlowerAmount() public {
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, (rate * 110) / 100); // 10% increase
        uint256 harvestable = IMinter(minter).harvestable();

        uint256 bounty = (harvestable * 1e16) / 1 ether;
        vm.prank(owner);
        IBounty(harvester).setBounty(5e17, 1e16 /* 1% */, true);
        assertLt(bounty, 5e17, "ratio is less");

        IHarvester(harvester).harvest(bountyReceiver, 0);
        assertEq(IERC20(IMinter(minter).WRAPPED_COLLATERAL_TOKEN()).balanceOf(harvestReceiver), harvestable - bounty);
        assertEq(IERC20(IMinter(minter).WRAPPED_COLLATERAL_TOKEN()).balanceOf(bountyReceiver), bounty);
    }

    function test_harvester_10() public {
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        // don't tell me there's no such thing as negative interest rates. Yes, we're preparerd!
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, (rate * 100) / 110); // 10% decrease
        // collateral = 20 ether, wrapped now is worth 20 ether * 100 / 110
        // difference = 20 ether - 20 ether * 110 / 100, which is negative, so 0
        assertEq(IMinter(minter).harvestable(), 0, "10% harvestable");
    }
}
