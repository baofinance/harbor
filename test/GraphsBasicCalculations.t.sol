// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "src/interfaces/IMinter.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";

import "test/Useful.sol";
import {TestStabilityPool2SetUp} from "test/TestStabilityPool2SetUp.sol";
import {TestGraphs} from "test/Graphs.t.sol";

contract TestGraphsBasicCalculations is TestStabilityPool2SetUp, TestGraphs {
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
        vm.prank(owner);
        IBaoRoles(minter).grantRoles(address(this), zeroFeeRole);
        assertEq(0, IERC20(wrappedCollateralToken).balanceOf(reservePool), "reserve pool should be empty");
    }

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    function redeem(
        uint256 amountOfPegged,
        uint256 amoutOfLeveraged,
        address recipient
    ) internal returns (uint256 collateralForPegged, uint256 collateralForLeveraged) {
        // recipient must have the amount of tokens being redeemed
        if (amountOfPegged > 0) {
            (collateralForPegged, ) = IMinter(minter).freeRedeemPeggedToken(amountOfPegged, 0, recipient);
        }
        if (amoutOfLeveraged > 0) {
            collateralForLeveraged = IMinter(minter).freeMintLeveragedToken(amoutOfLeveraged, recipient);
        }
    }

    function openFile(string memory name) internal returns (string memory file) {
        file = openFile(
            string.concat("basicCalculations-", name),
            sa(
                "Collateral",
                "Price",
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

    function safeCollateral() internal view returns (int256 collateral_) {
        try IMinter(minter).collateralTokenBalance() returns (uint256 c) {
            collateral_ = int256(c);
        } catch {
            collateral_ = NaN;
        }
    }

    function safePrice() internal view returns (int256) {
        (uint256 uprice, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        return int256(uprice);
    }

    function safePegged() internal view returns (int256 pegged_) {
        try IMinter(minter).peggedTokenBalance() returns (uint256 p) {
            pegged_ = int256(p);
        } catch {
            pegged_ = NaN;
        }
    }

    function safePeggedTokenPrice() internal view returns (int256 peggedTokenPrice_) {
        try IMinter(minter).peggedTokenPrice() returns (uint256 p) {
            peggedTokenPrice_ = int256(p);
        } catch {
            peggedTokenPrice_ = NaN;
        }
    }

    function safeLeveraged() internal view returns (int256 leveraged_) {
        try IMinter(minter).leveragedTokenBalance() returns (uint256 l) {
            leveraged_ = int256(l);
        } catch {
            leveraged_ = NaN;
        }
    }

    function safeLeveragedTokenPrice() internal view returns (int256 leveragedTokenPrice_) {
        try IMinter(minter).leveragedTokenPrice() returns (uint256 l) {
            leveragedTokenPrice_ = int256(l);
        } catch {
            leveragedTokenPrice_ = NaN;
        }
    }

    function safeCollateralRatio() internal view returns (int256 collateralRatio_) {
        try IMinter(minter).collateralRatio() returns (uint256 cr) {
            collateralRatio_ = int256(cr);
        } catch {
            collateralRatio_ = NaN;
        }
    }

    function safeLeverageRatio() internal view returns (int256 leverageRatio_) {
        try IMinter(minter).leverageRatio() returns (uint256 lr) {
            leverageRatio_ = int256(lr);
        } catch {
            leverageRatio_ = NaN;
        }
    }

    function safeInvariant() internal view returns (int256) {
        int256 collateral = safeCollateral();
        int256 price = safePrice();
        int256 pegged = safePegged();
        int256 peggedTokenPrice = safePeggedTokenPrice();
        int256 leveraged = safeLeveraged();
        int256 leveragedTokenPrice = safeLeveragedTokenPrice();
        if (
            collateral == NaN ||
            price == NaN ||
            pegged == NaN ||
            peggedTokenPrice == NaN ||
            leveraged == NaN ||
            leveragedTokenPrice == NaN
        ) {
            return NaN;
        }
        return (collateral * price - pegged * peggedTokenPrice - leveraged * leveragedTokenPrice) / 1 ether;
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

        for (uint256 price = 0; price <= midway * 2; price += 10) {
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

        int256 commandStatus = 0; // 0 = success
        for (uint256 i = 0; i <= iterations; i++) {
            writeOneLine(file, commandStatus);
            if (IMinter(minter).peggedTokenBalance() > 0) {
                try IMinter(minter).freeRedeemPeggedToken(price * 1 ether, 0, address(this)) {
                    commandStatus = 0; // 0 = success
                } catch {
                    // unexpected revert
                    commandStatus = NaN;
                }
            } else {
                // expected revert
                commandStatus = 0;
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

        int256 commandStatus = 0; // 0 = success
        for (uint256 i = 0; i <= iterations; i++) {
            writeOneLine(file, commandStatus);
            if (IMinter(minter).leveragedTokenBalance() > 0) {
                try IMinter(minter).freeRedeemLeveragedToken(price * 1 ether, address(this)) {
                    commandStatus = 0; // 0 = success
                } catch {
                    // unexpected revert
                    commandStatus = NaN;
                }
            } else {
                // expected revert
                commandStatus = 0;
            }
        }

        vm.closeFile(file);
    }
}
