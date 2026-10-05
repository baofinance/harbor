// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {Deployed} from "@bao/Deployed.sol";
import {ITokenHolder} from "@bao/interfaces/ITokenHolder.sol";
import {IHarborOwnable} from "@bao/interfaces/IHarborOwnable.sol";
import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";
import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

contract TestMinterHarvestSetUp is TestMinterSetUp {
    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    function setUp() public virtual override {
        super.setUp();
    }
}

contract TestMinterHarvest is TestMinterHarvestSetUp {
    address harvester;
    address harvestReceiver;

    function setUp() public virtual override(TestMinterHarvestSetUp) {
        super.setUp();
        harvestReceiver = makeAddr("harvestReceiver");
        harvester = makeAddr("harvester");
        uint256 harvesterRole = IMinter(minter).HARVESTER_ROLE();
        vm.startPrank(owner());
        IHarborRoles(minter).grantRoles(harvester, harvesterRole);
        vm.stopPrank();
        deal(address(Deployed.wstETH), harvester, 100 ether);
        vm.startPrank(harvester);
        IERC20(Deployed.wstETH).approve(minter, type(uint256).max);
        vm.stopPrank();
    }

    /// Only the owner or a harvester sweeps: a stranger and a holder of the zero-fee role are refused, and the
    /// owner's and the harvester's sweeps each go through and are announced.
    function test_sweep_isRefusedToAnyoneButTheOwnerOrAHarvester() public {
        address stray = address(new MockERC20("stray", "STRAY", 18));
        MockERC20(stray).mint(minter, 2 ether);

        address[2] memory refused = [makeAddr("stranger"), zeroFee];
        for (uint256 i = 0; i < refused.length; i++) {
            vm.startPrank(refused[i]);
            vm.expectRevert(IHarborOwnable.Unauthorized.selector);
            ITokenHolder(minter).sweep(stray, 1 ether, harvestReceiver);
            vm.stopPrank();
        }

        address[2] memory allowed = [owner(), harvester];
        for (uint256 i = 0; i < allowed.length; i++) {
            vm.startPrank(allowed[i]);
            vm.expectEmit(minter);
            emit ITokenHolder.Swept(stray, 1 ether, harvestReceiver);
            ITokenHolder(minter).sweep(stray, 1 ether, harvestReceiver);
            vm.stopPrank();
        }
        assertEq(IERC20(stray).balanceOf(harvestReceiver), 2 ether, "both sweeps delivered");
    }

    function test_harvestInit() public {
        assertEq(IMinter(minter).harvestable(), 0, "hasvestable is zero at the start");
        setUp_collateral(50 ether, 50 ether); // 100 collateral

        address collateralToken = IMinter(minter).WRAPPED_COLLATERAL_TOKEN();
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            IERC20(collateralToken).balanceOf(minter),
            "collaterals match"
        );
        assertEq(IMinter(minter).harvestable(), 0, "hasvestable is zero with new collateral");
    }

    function test_harvestPriceChange(uint256 startPrice, uint256 startRate) public {
        // Each of the fixture's 50-token mints must be worth a wei, or it mints nothing: 50e18 x rate x price / 1e36
        // >= 1 needs rate x price >= 2e16, which floors of 2e8 each meet twice over
        startPrice = bound(startPrice, 2e8, 10000 ether);
        startRate = bound(startRate, 2e8, 5 ether);

        MockWrappedPriceOracle(priceOracle).setLatestAnswer(startPrice, startRate);
        setUp_collateral(50 ether, 50 ether); // 100 collateral
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        // price changes
        for (uint256 p = 0; p < price * 2; p += 100 ether) {
            MockWrappedPriceOracle(priceOracle).setLatestAnswer(p, rate);

            assertEq(
                IMinter(minter).harvestable(),
                0,
                string.concat(
                    "harvestable is the same as with price=",
                    Strings.toString(p),
                    ", rate=",
                    Strings.toString(rate)
                )
            );
        }
    }

    function test_harvestRateChange(uint256 startPrice, uint256 startRate) public {
        // Each of the fixture's 50-token mints must be worth a wei, or it mints nothing: 50e18 x rate x price / 1e36
        // >= 1 needs rate x price >= 2e16, which floors of 2e8 each meet twice over
        startPrice = bound(startPrice, 2e8, 10000 ether);
        startRate = bound(startRate, 2e8, 5 ether);

        MockWrappedPriceOracle(priceOracle).setLatestAnswer(startPrice, startRate);
        {
            (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
            assertEq(price, startPrice, "price is set correctly");
            assertEq(rate, startRate, "rate is set correctly");
        }

        setUp_collateral(50 ether, 50 ether); // 100 collateral
        uint256 collateral = IMinter(minter).collateralTokenBalance();
        uint256 wrappedCollateral = IERC20(IMinter(minter).WRAPPED_COLLATERAL_TOKEN()).balanceOf(minter);
        assertEq(
            collateral,
            (wrappedCollateral * startRate) / 1e18,
            "collateral and wrapped collateral match after setUp_collateral"
        );

        // Then rate change
        // the sweep starts at the smallest non-zero rate: the oracle never quotes a zero rate, and `harvestable`
        // divides by the rate it is given
        for (uint256 r = 1; r < startRate * 2; r += 1e16) {
            MockWrappedPriceOracle(priceOracle).setLatestAnswer(startPrice, r);
            // The surplus over the wrapped the record needs, that need rounded UP: what a harvest leaves behind must
            // still cover the record once converted back at the rate, and that conversion rounds down.
            uint256 expectedHarvestable = 0;
            if (r > startRate) {
                uint256 heldValue = wrappedCollateral;
                uint256 accountingValue = Math.ceilDiv(collateral * 1e18, r);
                expectedHarvestable = heldValue > accountingValue ? heldValue - accountingValue : 0;
            }
            assertEq(
                IMinter(minter).harvestable(),
                expectedHarvestable,
                string.concat(
                    "harvestable is correct with price=",
                    Strings.toString(startPrice),
                    ", rate=",
                    Strings.toString(r)
                )
            );
        }
    }

    function test_harvestVariableRateChange(uint256 startPrice, uint256 startRate) public {
        startPrice = bound(startPrice, 0, 10000 ether);
        startRate = bound(startRate, 0, 5 ether);

        setUp_collateral(50 ether, 50 ether); // 100 collateral
        uint256 collateral = IMinter(minter).collateralTokenBalance();
        address wrappedCollateralToken = IMinter(minter).WRAPPED_COLLATERAL_TOKEN();

        // the sweep starts at the smallest non-zero rate: the oracle never quotes a zero rate, and `harvestable`
        // divides by the rate it is given
        for (uint256 r = 1; r < startRate * 2; r += 1e16) {
            MockWrappedPriceOracle(priceOracle).setLatestAnswer(startPrice, r);
            uint256 wrappedCollateral = IERC20(wrappedCollateralToken).balanceOf(minter);

            // The surplus over the wrapped the record needs, that need rounded UP, as above.
            uint256 expectedHarvestable = 0;
            uint256 accountingValue = Math.ceilDiv(collateral * 1e18, r);
            if (wrappedCollateral > accountingValue) {
                expectedHarvestable = wrappedCollateral - accountingValue;
            }
            assertEq(
                IMinter(minter).harvestable(),
                expectedHarvestable,
                string.concat(
                    "harvestable is correct with price=",
                    Strings.toString(startPrice),
                    ", rate=",
                    Strings.toString(r)
                )
            );

            if (expectedHarvestable > 0) {
                // Harvest
                uint256 beforeHarvestReceiver = IERC20(wrappedCollateralToken).balanceOf(harvestReceiver);
                uint256 beforeMinter = IERC20(wrappedCollateralToken).balanceOf(minter);
                vm.startPrank(harvester);
                ITokenHolder(minter).sweep(wrappedCollateralToken, expectedHarvestable, harvestReceiver);
                vm.stopPrank();
                assertEq(
                    IERC20(wrappedCollateralToken).balanceOf(harvestReceiver),
                    beforeHarvestReceiver + expectedHarvestable,
                    "harvested amount matches"
                );
                assertEq(
                    IERC20(wrappedCollateralToken).balanceOf(minter),
                    beforeMinter - expectedHarvestable,
                    "minter balance matches"
                );
            }
        }
    }
}
