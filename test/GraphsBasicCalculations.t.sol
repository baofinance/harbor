// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

import {TestStabilityPool2SetUp} from "@harbor-test/TestStabilityPool2SetUp.sol";
import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";

contract TestGraphsBasicCalculations is TestStabilityPool2SetUp, GraphTestBase {
    // TODO: collateral ratio
    // TODO: leveraged Ratio
    // TODO: pegged price on depeg
    // under scenrios of
    // price change
    // redeem all pegged
    // redeem all leveraged
    // price drops and we redeem all pegged
    // price drops and we redeem all leveraged
    uint256 iterations = 400;

    function setUp() public virtual override {
        super.setUp();
        deal(address(wrappedCollateralToken), address(this), 1000 ether);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);
        vm.prank(owner());
        IHarborRoles(minter).grantRoles(address(this), zeroFeeRole);
        assertEq(0, IERC20(wrappedCollateralToken).balanceOf(reservePool), "reserve pool should be empty");
    }

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    function openFile(string memory name) internal returns (string memory file) {
        file = openFile(
            string.concat("basicCalculations-", name),
            sa(
                "Collateral",
                "Collateral Price",
                "Pegged",
                "PeggedTokenPrice",
                "Leveraged",
                "LeveragedTokenPrice",
                "Invariant",
                "CollateralRatio",
                "LeveragedRatio",
                "CommandStatus"
            )
        );
    }

    function writeOneLine(string memory file) internal {
        writeOneLine(file, 0);
    }

    // The views are read directly: none of them reverts at any state these scenarios reach - the oracle is never
    // asked for a zero price - so a revert is an error and fails the test. Each value is converted with SafeCast, so
    // one too large for a signed column reverts rather than wrapping into a plausible number.

    function safeCollateral() internal view returns (int256) {
        return SafeCast.toInt256(IMinter(minter).collateralTokenBalance());
    }

    function safePrice() internal view returns (int256) {
        (uint256 uprice, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        return SafeCast.toInt256(uprice);
    }

    function safePegged() internal view returns (int256) {
        return SafeCast.toInt256(IMinter(minter).peggedTokenBalance());
    }

    function safePeggedTokenPrice() internal view returns (int256) {
        return SafeCast.toInt256(IMinter(minter).peggedTokenPrice());
    }

    function safeLeveraged() internal view returns (int256) {
        return SafeCast.toInt256(IMinter(minter).leveragedTokenBalance());
    }

    function safeLeveragedTokenPrice() internal view returns (int256) {
        return SafeCast.toInt256(IMinter(minter).leveragedTokenPrice());
    }

    function safeCollateralRatio() internal view returns (int256) {
        return SafeCast.toInt256(IMinter(minter).collateralRatio());
    }

    /// @dev With no residual the minter reports the maximum - a claim of nothing rather than a leverage - so that
    ///      point is a break in the line, not a number.
    function safeLeverageRatio() internal view returns (int256) {
        uint256 leverageRatio_ = IMinter(minter).leverageRatio();
        return leverageRatio_ == type(uint256).max ? NaN : SafeCast.toInt256(leverageRatio_);
    }

    function safeInvariant() internal view returns (int256) {
        int256 collateralValue = safeCollateral() * safePrice();
        int256 peggedValue = safePegged() * safePeggedTokenPrice();
        int256 leveragedValue = safeLeveraged() * safeLeveragedTokenPrice();
        return (collateralValue - peggedValue - leveragedValue) / 1 ether;
    }

    function writeOneLine(string memory file, int256 commandStatus) internal {
        writeLine(
            file,
            ia(
                safeCollateral(),
                safePrice(),
                safePegged(),
                safePeggedTokenPrice(),
                safeLeveraged(),
                safeLeveragedTokenPrice(),
                safeInvariant(),
                safeCollateralRatio(),
                safeLeverageRatio(),
                commandStatus
            )
        );
    }

    function test_priceChange() public {
        // add collateral, peggged and leveraged
        uint midway = 2000;
        // at a price mid-way between the value rang below
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(midway * 1 ether);
        setUp_collateral(10 ether, 10 ether, address(this));

        string memory file = openFile("priceChange");

        // don't start at a zero price as it reverts
        for (uint256 price = 10; price <= midway * 2; price += 10) {
            MockWrappedPriceOracle(priceOracle).setLatestAnswer(price * 1 ether);
            writeOneLine(file);
        }

        vm.closeFile(file);
    }

    function test_mintPegged() public {
        // at a price mid-way between the value rang below
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2000 * 1 ether);

        string memory file = openFile("mintPegged");

        for (uint256 i = 0; i <= iterations; i++) {
            writeOneLine(file);
            setUp_collateral(1e17, 0, address(this)); // 0.1 worth of collateral = 200 pegged
        }

        vm.closeFile(file);
    }

    function test_mintPegged_initialCollateral() public {
        // at a price mid-way between the value rang below
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2000 * 1 ether);
        setUp_collateral(10 ether, 10 ether, address(this));

        string memory file = openFile("mintPegged-initialCollateral");

        for (uint256 i = 0; i <= iterations; i++) {
            writeOneLine(file);
            setUp_collateral(1e17, 0, address(this)); // 0.1 worth of collateral = 200 pegged
        }

        vm.closeFile(file);
    }

    function test_redeemPegged() public {
        // at a price mid-way between the value rang below
        uint256 price = 2000;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price * 1 ether);
        setUp_collateral(40 ether, 40 ether, address(this));

        string memory file = openFile("redeemPegged");

        // The pegged supply is a whole number of redemptions, so none is ever refused: a revert fails the test.
        for (uint256 i = 0; i <= iterations; i++) {
            writeOneLine(file);
            if (IMinter(minter).peggedTokenBalance() > 0) {
                IMinter(minter).freeRedeemPeggedToken(price * 1 ether, 0, address(this));
            }
        }

        vm.closeFile(file);
    }

    function test_mintLeveraged_initialCollateral() public {
        // at a price mid-way between the value rang below
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2000 * 1 ether);
        setUp_collateral(10 ether, 10 ether, address(this));

        string memory file = openFile("mintLeveraged-initialCollateral");

        for (uint256 i = 0; i <= iterations; i++) {
            setUp_collateral(0, 1e17, address(this)); // 0.1 worth of collateral = 200 pegged
            writeOneLine(file);
        }

        vm.closeFile(file);
    }

    function test_redeemLeveraged() public {
        // at a price mid-way between the value rang below
        uint256 price = 2000;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price * 1 ether);
        setUp_collateral(40 ether, 40 ether, address(this));

        string memory file = openFile("redeemLeveraged");

        // The leveraged supply is a whole number of redemptions, so none is ever refused: a revert fails the test.
        for (uint256 i = 0; i <= iterations; i++) {
            writeOneLine(file);
            if (IMinter(minter).leveragedTokenBalance() > 0) {
                IMinter(minter).freeRedeemLeveragedToken(price * 1 ether, address(this));
            }
        }

        vm.closeFile(file);
    }
}
