// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {TokenHolder, ITokenHolder} from "@bao/TokenHolder.sol";

import {IMinter} from "src/interfaces/IMinter.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager} from "src/interfaces/IStabilityPoolManager.sol";
import {StabilityPoolManager_v1} from "src/minter/StabilityPoolManager_v1.sol";

import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";
import {TestStabilityPoolManagerSetUp} from "test/StabilityPoolManager_v1.t.sol";

import "test/Useful.sol";

contract EverythingTest is TestStabilityPoolManagerSetUp {
    bool immutable isDepegged;

    constructor(bool isDepegged_) {
        isDepegged = isDepegged_;
    }

    function setUp() public virtual override {
        super.setUp();
        setUp_collateral(100 ether, 40 ether); // CR = 140%
    }

    function test_collateralRatio() public view {
        uint256 collateralRatio = IMinter(minter).collateralRatio();
        assertEq(collateralRatio, isDepegged ? 0.7 ether : 1.4 ether, "collateralRatio wrong");
    }

    function test_leverageRatio() public view {
        uint256 leverageRatio = IMinter(minter).leverageRatio();
        assertEq(
            leverageRatio,
            isDepegged ? 20 ether /* the cap */ : 3.499999999999999991 ether,
            "leverageRatio wrong"
        );
    }

    /*
    /// @notice Return the price of a leveraged token in terms of the pegged token's underlying (18 decimals).
    function leveragedTokenPrice() external view returns (uint256);

    /// @notice Return the price of a pegged token in terms of the pegged token's underlying (18 decimals).
    /// this should normally be 1 ether but if the token depegs then this number will be this token's share of the
    /// collateral.
    function peggedTokenPrice() external view returns (uint256);

    /// @notice Return the leveraged tokens that are the same value are the given collateral token (at the current
    /// collateral ratio).
    function leveragedTokensForCollateral(uint256 forWrappedCollateral) external view returns (uint256 leveragedTokens);

    /// @notice Returns the amount of Pegged tokens that need to be redeemed to achieve a given target collateral ratio
    /// This is based on the fact that redeeming pegged tokens has a upward pressure on collateral ratio
    /// If, however, there are no leveraged tokens then no amount of redemption can change the collateral ratio.
    /// In the case of no leveraged tokens we return the total supply minted by this minter
    /// @param targetCollateralRatio The collateral ratio that we aim to meet by the returned pegged tokens redeemed.
    /// Must be greater than 1 ether
    /// @return peggedTokens The number of pegged tokens that need to be redeemed to achieve the `targetCollateralRatio`
    /// given the current collateral ratio
    function redeemPeggedForCollateralRatio(uint256 targetCollateralRatio) external view returns (uint256 peggedTokens);

    /// @notice Returns the number of pegged tokens needed to be swapped for leveraged tokens to
    /// achieve the `targetCollateralRatio`
    /// @param targetCollateralRatio The target collateral ratio
    /// @return peggedTokens The number of pegged tokens needed to be swapped to achieve the given
    /// `targetCollateralRatio`
    function swapPeggedForLeveragedForCollateralRatio(
        uint256 targetCollateralRatio
    ) external view returns (uint256 peggedTokens);

    function wrappedCollateralForCollateralRatio(
        uint256 targetCollateralRatio
    ) external view returns (uint256 wrappedCollateral);

    /// @notice Returns the amount of collateral tokens 'forLeveragedTokens' will buy in the absence of fees and
    /// discounts
    /// @param forLeveragedTokens The amount of leveraged tokens
    /// @return collateral The amount of collateral tokens equivalent to `forLeveragedTokens` wrapped collateral
    function collateralForLeverageTokens(uint256 forLeveragedTokens) external view returns (uint256 collateral);

    /// @notice Returns the address of the price oracle contract
    function priceOracle() external view returns (address);

    /// @notice Returns the address of the reserve pool contract that provides the collateral for discounts
    function reservePool() external view returns (address);

    /// @notice Returns the address of the fee receiver contract
    function feeReceiver() external view returns (address);

    /// @notice Returns the totalAmount of pegged tokens minted, and not redeemed, by the minter
    function peggedTokenBalance() external view returns (uint256);

    /// @notice Returns the totalAmount of leveraged tokens minted, and not redeemed, by the minter
    /// This number is the same as the totelSupply of the leveraged token
    function leveragedTokenBalance() external view returns (uint256);

    /// @notice Returns the totalAmount of collateral tokens received in exchange for pegged and leveraged tokens
    /// (18 decimals)
    function collateralTokenBalance() external view returns (uint256);

    /// @notice Returns the current instantaneous incentive ratio for minting pegged tokens (18 decimals).
    /// A positive number is a fee ratio; a negative number indicates a discount.
    function mintPeggedTokenIncentiveRatio() external view returns (int256 incentiveRatio);

    /// @notice Returns the current instantaneous incentive ratio for redeeming pegged tokens (18 decimals).
    /// A positive number is a fee ratio; a negative number indicates a discount.
    function redeemPeggedTokenIncentiveRatio() external view returns (int256 incentiveRatio);

    /// @notice Returns the current instantaneous incentive ratio for minting leveraged tokens (18 decimals).
    /// A positive number is a fee ratio; a negative number indicates a discount.
    function mintLeveragedTokenIncentiveRatio() external view returns (int256 incentiveRatio);

    /// @notice Returns the current instantaneous incentive ratio for redeeming leveraged tokens (18 decimals).
    /// A positive number is a fee ratio; a negative number indicates a discount.
    function redeemLeveragedTokenIncentiveRatio() external view returns (int256 incentiveRatio);

*/
}

contract DepeggedTest is EverythingTest {
    constructor() EverythingTest(true) {}

    function setUp() public virtual override {
        super.setUp();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(1000 ether); // half the default price
    }
}

contract NotDepeggedTest is EverythingTest {
    constructor() EverythingTest(false) {}
}
