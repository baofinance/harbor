// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {Deploy_EUR_Minter} from "@harbor-script/src/Deploy_EUR_Minter.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

/// @title Common deployment setup for EUR market tests.
/// @dev Deploys EUR peg with two collaterals (fxUSD, stETH), each with collateral + leveraged SPs and ACs.
///      Forks mainnet at a pinned block, deploys all market infrastructure via production scripts,
///      grants test contract free-mint and reward-depositor roles, sets mock oracles to price=rate=1.
abstract contract DeployEURSetUp is BaoTest, Deploy_EUR_Minter {
    // ── EUR::fxUSD market ──────────────────────────────────────────────
    address minterFxUSD;
    address spCollFxUSD;
    address spLevFxUSD;
    address spmFxUSD;
    address acCollFxUSD;
    address acLevFxUSD;

    // ── EUR::stETH market ──────────────────────────────────────────────
    address minterStETH;
    address spCollStETH;
    address spLevStETH;
    address spmStETH;
    address acCollStETH;
    address acLevStETH;

    // ── Shared ─────────────────────────────────────────────────────────
    address pegged; // haEUR - shared across markets
    address wrappedCollateralFxUSD;
    address wrappedCollateralStETH;

    MockWrappedPriceOracle mockOracleFxUSD;
    MockWrappedPriceOracle mockOracleStETH;

    function _shouldPersistState() internal pure override returns (bool) {
        return false;
    }

    function setUp() public virtual {
        address factory = _ensureBaoFactory();
        vm.createSelectFork(vm.rpcUrl("mainnet"), 24699497);

        vm.prank(IBaoFactory(factory).owner());
        IBaoFactory(factory).setOperator(address(this), 365 days);

        (ConfigPeg peg_, Config_MinterMarket[] memory mktConfigs) = createEURMintersConfig();

        deployHarborForPeg("test_eur", peg_, mktConfigs, "mainnet", true, mktConfigs);

        _setSaltPrefix("test_eur");

        // EUR::fxUSD
        string memory mkFx = "EUR::fxUSD";
        minterFxUSD = _predictAddress(_key(mkFx, "minter"));
        spCollFxUSD = _predictAddress(_key(mkFx, "stabilityPoolCollateral"));
        spLevFxUSD = _predictAddress(_key(mkFx, "stabilityPoolLeveraged"));
        spmFxUSD = _predictAddress(_key(mkFx, "stabilityPoolManager"));
        acCollFxUSD = _predictAddress(_key(mkFx, "autoCompounderCollateral"));
        acLevFxUSD = _predictAddress(_key(mkFx, "autoCompounderLeveraged"));
        wrappedCollateralFxUSD = IMinter(minterFxUSD).WRAPPED_COLLATERAL_TOKEN();

        // EUR::stETH
        string memory mkSt = "EUR::stETH";
        minterStETH = _predictAddress(_key(mkSt, "minter"));
        spCollStETH = _predictAddress(_key(mkSt, "stabilityPoolCollateral"));
        spLevStETH = _predictAddress(_key(mkSt, "stabilityPoolLeveraged"));
        spmStETH = _predictAddress(_key(mkSt, "stabilityPoolManager"));
        acCollStETH = _predictAddress(_key(mkSt, "autoCompounderCollateral"));
        acLevStETH = _predictAddress(_key(mkSt, "autoCompounderLeveraged"));
        wrappedCollateralStETH = IMinter(minterStETH).WRAPPED_COLLATERAL_TOKEN();

        // Shared pegged token
        pegged = _predictAddress(_key("EUR", "pegged"));

        // Mock oracles (price=1, rate=1 for simple accounting)
        mockOracleFxUSD = new MockWrappedPriceOracle();
        mockOracleFxUSD.setLatestAnswer(1 ether, 1 ether);
        mockOracleStETH = new MockWrappedPriceOracle();
        mockOracleStETH.setLatestAnswer(1 ether, 1 ether);

        vm.startPrank(HARBOR_MULTISIG);
        IMinter(minterFxUSD).updatePriceOracle(address(mockOracleFxUSD));
        IMinter(minterStETH).updatePriceOracle(address(mockOracleStETH));
        // Grant free mint role for test helpers
        IBaoRoles(minterFxUSD).grantRoles(address(this), IMinter(minterFxUSD).ZERO_FEE_ROLE());
        IBaoRoles(minterStETH).grantRoles(address(this), IMinter(minterStETH).ZERO_FEE_ROLE());
        // Grant reward depositor role on collateral SPs
        IBaoRoles(spCollFxUSD).grantRoles(
            address(this),
            IMultipleRewardDistributor(spCollFxUSD).REWARD_DEPOSITOR_ROLE()
        );
        IBaoRoles(spCollStETH).grantRoles(
            address(this),
            IMultipleRewardDistributor(spCollStETH).REWARD_DEPOSITOR_ROLE()
        );
        vm.stopPrank();
    }

    // ── Helpers ────────────────────────────────────────────────────────

    function _mintPegged(
        address minter_,
        address to,
        uint256 collateralAmount
    ) internal returns (uint256 peggedMinted) {
        address wCol = IMinter(minter_).WRAPPED_COLLATERAL_TOKEN();
        deal(wCol, address(this), collateralAmount);
        IERC20(wCol).approve(minter_, collateralAmount);
        peggedMinted = IMinter(minter_).freeMintPeggedToken(collateralAmount, to);
    }

    function _mintLeveraged(
        address minter_,
        address to,
        uint256 collateralAmount
    ) internal returns (uint256 leveragedMinted) {
        address wCol = IMinter(minter_).WRAPPED_COLLATERAL_TOKEN();
        deal(wCol, address(this), collateralAmount);
        IERC20(wCol).approve(minter_, collateralAmount);
        leveragedMinted = IMinter(minter_).freeMintLeveragedToken(collateralAmount, to);
    }

    /// @dev Set up a market with a healthy collateral ratio.
    ///      Mints pegged tokens (into SP) and leveraged tokens to achieve target CR.
    ///      CR = total_collateral_value / pegged_supply. Leveraged adds collateral without adding pegged.
    ///      With price=1, rate=1: CR = (peggedCollateral + leveragedCollateral) / peggedSupply
    function _setupHealthyMarket(
        address minter_,
        address sp,
        address user,
        uint256 peggedCollateral,
        uint256 leveragedCollateral
    ) internal {
        _mintAndDepositToSP(minter_, sp, user, peggedCollateral);
        if (leveragedCollateral > 0) {
            _mintLeveraged(minter_, user, leveragedCollateral);
        }
    }

    function _mintAndDepositToSP(address minter_, address sp, address user, uint256 amount) internal {
        uint256 peggedMinted = _mintPegged(minter_, user, amount);
        vm.startPrank(user);
        IERC20(pegged).approve(sp, peggedMinted);
        IStabilityPool(sp).deposit(peggedMinted, user, 0);
        vm.stopPrank();
    }

    function _depositReward(address sp, address wCol, address rewardAlias, uint256 amount) internal {
        deal(wCol, address(this), amount);
        IERC20(wCol).approve(sp, amount);
        IMultipleRewardDistributor(sp).depositReward(rewardAlias, amount);
    }
}
