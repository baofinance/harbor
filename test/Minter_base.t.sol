// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {BaoTest} from "@bao-test/BaoTest.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IHarborOwnable} from "@bao/interfaces/IHarborOwnable.sol";
import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";
import {ITokenHolder} from "@bao/interfaces/ITokenHolder.sol";

import {Minter_v3} from "@harbor/minter/Minter_v3.sol";
import {ConfigIncentiveLib} from "@harbor/minter/library/ConfigIncentiveLib.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {Token} from "@bao/Token.sol";
import {IMintable} from "@bao/interfaces/IMintable.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";

import {Deployed} from "@bao/Deployed.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {IBaoUSD} from "@harbor-test/IBaoUSD.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {Array} from "@bao-test/utils/Array.sol";

import {ConfigFile} from "@harbor-test/Config.sol";
import {MarketActions} from "@harbor-test/harness/MarketActions.sol";
import {HarborDeployRun} from "@harbor-test/HarborDeployRun.sol";
import {MarketDeployRun} from "@harbor-test/harness/MarketDeployRun.sol";
import {TestMinterMarketConfig} from "@harbor-test/config/TestMinterMarketConfig.sol";
import {IMintableRole} from "@bao/interfaces/IMintableRole.sol";
import {IBurnableRole} from "@bao/interfaces/IBurnableRole.sol";
import {IReservePool} from "@harbor/interfaces/IReservePool.sol";

/// @dev The deploy framework is HELD, not inherited: `deployRun` is the one contract that carries it, compiled
///      once, and each test contract built on this base carries only its tests. See `MinterDeployRun`.
contract TestMinterSetUp is BaoTest, Array, ConfigFile {
    /// @dev Who owns every proxy the run deploys, and where its fees go: this test's identities, handed to the
    ///      run so the test can prank as them. Two addresses, so a balance measures one thing.
    address private immutable _owner;
    address private immutable _treasury;

    constructor() {
        _owner = makeAddr("owner");
        _treasury = makeAddr("feeReceiver");
    }

    function owner() public view returns (address) {
        return _owner;
    }

    function treasury() public view returns (address) {
        return _treasury;
    }

    /// @dev The deploy run this suite drives. Created once the fork is selected, which would otherwise discard it.
    MarketDeployRun internal deployRun;

    /// @dev The run a suite wants: the minter alone here. A setup that needs more of the market, or a mock behind
    ///      its pools, returns another run - one choice, made once, in place of overriding the deploy's steps.
    function newDeployRun() internal virtual returns (MarketDeployRun) {
        return new MarketDeployRun(owner(), treasury(), HarborDeployRun.Cut.Minter, new TestMinterMarketConfig());
    }

    /// @dev What a test does to the market the run stood up - see `MarketActions`. Made in `setUpContract`, once the
    ///      minter and its mock oracle exist, so every suite on this base acts on its market through the one object.
    MarketActions internal marketActions;

    address minter;
    IMinter.Config config;
    bool isConfigSet = false;
    int constant disallow = 10000;

    address peggedToken;
    address wrappedCollateralToken;
    address collateralToken;

    address leveragedToken;
    address reservePool;
    address priceOracle;

    address feeReceiver;
    address zeroFee;

    /// @dev The market this suite deploys: a production configuration with only the incentive config made
    ///      settable, so each test's choice reaches the minter by the deploy's own path.
    TestMinterMarketConfig internal marketConfig;

    uint256 zeroFeeRole;
    uint256 minterRole;
    uint256 burnerRole;
    uint256 requesterRole;

    function _mintPegged(address receiver, uint256 amount) internal {
        // the pegged token may or may not have an operator; a staticcall that succeeds says it does
        // slither-disable-next-line low-level-calls
        (bool hasOperator, ) = peggedToken.staticcall(abi.encodeWithSelector(IBaoUSD.operator.selector));
        if (hasOperator) {
            vm.startPrank(IBaoUSD(peggedToken).operator());
            IMintable(peggedToken).mint(receiver, amount);
            vm.stopPrank();
        } else {
            // if the pegged token does not have an operator, we mint it directly
            vm.startPrank(owner());
            IMintable(peggedToken).mint(receiver, amount);
            vm.stopPrank();
        }
        vm.label(peggedToken, "peggedToken");
    }

    function _percentToEther(uint amount) internal pure returns (uint256) {
        return (amount * 1 ether) / 100;
    }

    function _etherToBasisPoint(int256 amount) internal pure returns (int) {
        return (amount * 10000) / 1 ether;
    }

    function _basisPointToEther(int amount) private pure returns (int256) {
        return (amount * 1 ether) / 10000;
    }

    /// @dev The number of adjacent incentive bands whose fee/subsidy rate differs — i.e. how many distinct
    ///      fee "steps" an operation's collateral-ratio path can straddle. A flat config returns 0, so the
    ///      operation is exactly path-independent (splitting it changes nothing but per-step rounding). Each
    ///      transition admits a bounded, magnitude-scaled divergence between doing an operation in one call
    ///      versus many, because the fee is recomputed per band as the collateral ratio moves during the op.
    function _bandTransitions(int256[] memory incentiveRatios) internal pure returns (uint256 transitions) {
        for (uint256 i = 1; i < incentiveRatios.length; i++) {
            if (incentiveRatios[i] != incentiveRatios[i - 1]) {
                transitions++;
            }
        }
    }

    function ic(
        uint[] memory upToPercent,
        int[] memory amountBasisPoints
    ) internal pure returns (IMinter.IncentiveConfig memory band) {
        band.collateralRatioBandUpperBounds = new uint256[](upToPercent.length);
        for (uint i = 0; i < upToPercent.length; i++) {
            band.collateralRatioBandUpperBounds[i] = _percentToEther(upToPercent[i]);
        }
        band.incentiveRatios = new int256[](amountBasisPoints.length);
        for (uint i = 0; i < amountBasisPoints.length; i++) {
            band.incentiveRatios[i] = _basisPointToEther(amountBasisPoints[i]);
        }
    }

    function setUp_config_flatWide() internal {
        setUp_config(
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(50, 50, 50, 50, 50, 50, 50, 50)),
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(80, 80, 80, 80, 80, 80, 80, 80)),
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(70, 70, 70, 70, 70, 70, 70, 70)),
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(120, 120, 120, 120, 120, 120, 120, 120))
        );
    }

    /// @dev Redeeming pegged and minting leveraged are subsidised at one flat rate in every band up to the widest bound
    ///      the storage holds, and free above it, where no subsidy may run: a walk that stays below that bound sees a
    ///      single rate across six close crossings.
    function setUp_config_flatSubsidyWide() internal {
        IMinter.IncentiveConfig memory redeemPegged = ic(
            ua(100, 110, 120, 130, 140, 150, 160),
            ia(-80, -80, -80, -80, -80, -80, -80, 0)
        );
        redeemPegged.collateralRatioBandUpperBounds[6] = ConfigIncentiveLib.MAX_COLLATERAL_RATIO_BOUND;
        IMinter.IncentiveConfig memory mintLeveraged = ic(
            ua(100, 110, 120, 130, 140, 150, 160),
            ia(-70, -70, -70, -70, -70, -70, -70, 0)
        );
        mintLeveraged.collateralRatioBandUpperBounds[6] = ConfigIncentiveLib.MAX_COLLATERAL_RATIO_BOUND;
        setUp_config(
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(50, 50, 50, 50, 50, 50, 50, 50)),
            redeemPegged,
            mintLeveraged,
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(120, 120, 120, 120, 120, 120, 120, 120))
        );
    }

    function setUp_config_flatDisallowSubsidyWide() internal {
        setUp_config(
            ic(ua(110, 120, 130, 140, 150, 160), ia(disallow, 50, 50, 50, 50, 50, 50)),
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(-80, -80, -80, -80, -80, -80, -80, 0)),
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(-70, -70, -70, -70, -70, -70, -70, 0)),
            ic(ua(110, 120, 130, 140, 150, 160), ia(disallow, 120, 120, 120, 120, 120, 120))
        );
    }

    function setUp_config_directionalWide() internal {
        setUp_config(
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(120, 110, 100, 90, 80, 70, 60, 50)), // mint pegged
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(50, 60, 70, 80, 90, 100, 110, 120)), // redeem pegged
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(50, 60, 70, 80, 90, 100, 110, 120)), // mint leveraged
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(120, 110, 100, 90, 80, 70, 60, 50)) // redeem leveraged
        );
    }

    function setUp_config_feeIsCR() internal {
        setUp_config(
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(90, 100, 110, 120, 130, 140, 150, 160)), // mint pegged
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(90, 100, 110, 120, 130, 140, 150, 160)), // redeem pegged
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(90, 100, 110, 120, 130, 140, 150, 160)), // mint leveraged
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(90, 100, 110, 120, 130, 140, 150, 160)) // redeem leveraged
        );
    }

    function setUp_config_reverseDirectionalWide() internal {
        setUp_config(
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(50, 60, 70, 80, 90, 100, 110, 120)), // mint pegged
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(120, 110, 100, 90, 80, 70, 60, 50)), // redeem pegged
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(120, 110, 100, 90, 80, 70, 60, 50)), // mint leveraged
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(50, 60, 70, 80, 90, 100, 110, 120)) // redeem leveraged
        );
    }

    function setUp_config_directionalDisallowSubsidyWide() internal {
        setUp_config(
            ic(ua(110, 120, 130, 140, 150, 160), ia(disallow, 110, 100, 90, 80, 70, 60)),
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(-120, -110, -100, -90, -80, -70, -60, 0)),
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(-120, -110, -100, -90, -80, -70, -60, 0)),
            ic(ua(110, 120, 130, 140, 150, 160), ia(disallow, 110, 100, 90, 80, 70, 60))
        );
    }

    function setUp_config_reverseDirectionalDisallowSubsidyWide() internal {
        setUp_config(
            ic(ua(110, 120, 130, 140, 150, 160), ia(disallow, 60, 70, 80, 90, 100, 110)),
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(-50, -60, -70, -80, -90, -100, -110, 0)),
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(-50, -60, -70, -80, -90, -100, -110, 0)),
            ic(ua(110, 120, 130, 140, 150, 160), ia(disallow, 60, 70, 80, 90, 100, 110))
        );
    }

    function setUp_config_free() internal {
        setUp_config(ic(ua(100), ia(0, 0)), ic(ua(100), ia(0, 0)), ic(ua(100), ia(0, 0)), ic(ua(100), ia(0, 0)));
        writeConfig(config, "free");
    }

    function setUp_config_flat() internal {
        setUp_config(
            ic(ua(100), ia(50, 50)),
            ic(ua(100), ia(80, 80)),
            ic(ua(100), ia(70, 70)),
            ic(ua(100), ia(120, 120))
        );
        writeConfig(config, "flat");
    }

    function setUp_config_basicWithDisallow() internal {
        setUp_config(
            ic(ua(131), ia(disallow, 50)),
            ic(ua(100), ia(80, 80)),
            ic(ua(100), ia(70, 70)),
            ic(ua(110), ia(disallow, 120))
        );
        writeConfig(config, "basicWithDisallow");
    }

    function setUp_config_likely() internal {
        setUp_config(
            ic(ua(130, 140), ia(disallow, 100, 50)), // mint pegged
            ic(ua(100, 105, 115, 150), ia(-75, -75, -25, 60, 80)), // redeem pegged
            ic(ua(100, 110, 120, 145), ia(-50, -50, 0, 20, 70)), // mint leveraged
            ic(ua(105, 135), ia(disallow, 150, 120)) // redeem leveraged
        );
        writeConfig(config, "likely");
    }

    function setUp_config_likelyNoDisallow() internal {
        setUp_config(
            ic(ua(100, 140), ia(100, 100, 50)), // mint pegged
            ic(ua(100, 105, 115, 150), ia(-75, -75, -25, 60, 80)), // redeem pegged
            ic(ua(100, 110, 120, 145), ia(-50, -50, 0, 20, 70)), // mint leveraged
            ic(ua(100, 135), ia(150, 150, 120)) // redeem leveraged
        );
        writeConfig(config, "likelyNoDisallow");
    }

    function setUp_config(IMinter.Config memory config_) internal {
        config = config_;
        isConfigSet = true;
    }

    function setUp_config(
        IMinter.IncentiveConfig memory mintPegged,
        IMinter.IncentiveConfig memory redeemPegged,
        IMinter.IncentiveConfig memory mintLeveraged,
        IMinter.IncentiveConfig memory redeemLeveraged
    ) public {
        config.mintPeggedIncentiveConfig = mintPegged;
        config.mintLeveragedIncentiveConfig = mintLeveraged;
        config.redeemPeggedIncentiveConfig = redeemPegged;
        config.redeemLeveragedIncentiveConfig = redeemLeveraged;
        isConfigSet = true;
    }

    function _assertEqIncentiveConfig(
        IMinter.IncentiveConfig memory actual,
        IMinter.IncentiveConfig memory expected,
        string memory name
    ) internal pure {
        assertEq(
            actual.collateralRatioBandUpperBounds.length,
            expected.collateralRatioBandUpperBounds.length,
            string.concat(name, " collateralRatioBandUpperBounds.length differ")
        );
        for (uint i = 0; i < actual.collateralRatioBandUpperBounds.length; i++) {
            assertEq(
                actual.collateralRatioBandUpperBounds[i],
                expected.collateralRatioBandUpperBounds[i],
                string.concat(name, " collateralRatioBandUpperBounds[", LibString.toString(i), "] differ")
            );
        }
        assertEq(actual.incentiveRatios.length, expected.incentiveRatios.length, "incentiveRatios.length differ ");
        for (uint i = 0; i < actual.incentiveRatios.length; i++) {
            assertEq(
                actual.incentiveRatios[i],
                expected.incentiveRatios[i],
                string.concat(name, " incentiveRatios[", LibString.toString(i), "] differ")
            );
        }
    }

    function _assertEqConfig(IMinter.Config memory actual, IMinter.Config memory expected) internal pure {
        _assertEqIncentiveConfig(actual.mintPeggedIncentiveConfig, expected.mintPeggedIncentiveConfig, "mint pegged");
        _assertEqIncentiveConfig(
            actual.mintLeveragedIncentiveConfig,
            expected.mintLeveragedIncentiveConfig,
            "mint leveraged"
        );
        _assertEqIncentiveConfig(
            actual.redeemPeggedIncentiveConfig,
            expected.redeemPeggedIncentiveConfig,
            "redeem pegged"
        );
        _assertEqIncentiveConfig(
            actual.redeemLeveragedIncentiveConfig,
            expected.redeemLeveragedIncentiveConfig,
            "redeem leveraged"
        );
    }
    function setUpConfig() internal virtual {
        setUp_config(
            ic(ua(131, 140), ia(disallow, 100, 50)),
            ic(ua(100, 110, 120, 140), ia(-50, -50, 0, 60, 80)),
            ic(ua(100, 110, 120, 140), ia(-50, -50, 0, 20, 70)),
            ic(ua(110, 140), ia(disallow, 150, 120))
        );
        writeConfig(config, "default-int");
    }

    function setUpFork() internal virtual {
        forkMainnet();

        feeReceiver = treasury();

        // After the fork is selected: a fork selected afterwards would discard the run, as it would the factory
        // operator registration the run makes when it deploys.
        deployRun = newDeployRun();
        marketConfig = deployRun.marketConfig();
        wrappedCollateralToken = marketConfig.wrappedCollateralToken();
        collateralToken = marketConfig.collateralToken();
    }

    function setUpContract() internal virtual {
        // The incentive config the suite chose reaches the minter through the market config, so the deploy
        // applies it by the same path it applies production's - rather than the suite configuring the minter
        // afterwards, which would exercise none of the deploy.
        if (isConfigSet) {
            marketConfig.setMinterConfig(config);
        }

        deployRun.deployMinterMarket();

        minter = deployRun.minterAddress(marketConfig);
        peggedToken = deployRun.peggedTokenAddress(marketConfig);
        leveragedToken = deployRun.leveragedTokenAddress(marketConfig);
        reservePool = deployRun.reservePoolAddress(marketConfig);

        // The price oracle is a separate deployment the minter only knows by predicted address. The run puts the
        // mock there AFTER the deploy, so the deploy is exercised against a codeless reference exactly as in
        // production, and restores the state `vm.etch` does not copy.
        priceOracle = deployRun.installMockPriceOracle(marketConfig);
        vm.label(priceOracle, "priceOracle");

        marketActions = new MarketActions(minter);

        minterRole = IMintableRole(leveragedToken).MINTER_ROLE();
        burnerRole = IBurnableRole(leveragedToken).BURNER_ROLE();
        requesterRole = IReservePool(reservePool).REQUESTER_ROLE();
        zeroFeeRole = IMinter(minter).ZERO_FEE_ROLE();

        zeroFee = makeAddr("zeroFee");
        vm.startPrank(owner());
        IBaoRoles(minter).grantRoles(zeroFee, zeroFeeRole);
        // The suite mints pegged tokens directly to set up positions. The deploy grants MINTER only to the
        // minter, which is correct for production, so the test's own minting rights are granted here.
        IBaoRoles(peggedToken).grantRoles(owner(), IMintableRole(peggedToken).MINTER_ROLE());
        vm.stopPrank();

        // free* is onlyOwnerOrRoles, so the owner is authorised without ZERO_FEE_ROLE. Guard that no setup path
        // grants the role to the owner - a grant-to-owner would hide the owner path behind the role path in tests.
        assertFalse(
            IBaoRoles(minter).hasAnyRole(IBaoOwnable(minter).owner(), IMinter(minter).ZERO_FEE_ROLE()),
            "owner must not hold ZERO_FEE_ROLE"
        );
    }

    function setUp() public virtual {
        setUpFork();
        deal(address(Deployed.wstETH), address(this), 20 ether);
        setUpConfig();
        setUpContract();
    }

    /// @dev A caught revert must be the minter's leverage-cap refusal of the market as it stands: below
    ///      `MINIMUM_COLLATERAL_RATIO` no route sells leverage. Asserted whole - the ratio the minter judged is the one
    ///      `collateralRatio()` reports, since both price at the mid and a refused call leaves the market as it was -
    ///      so a graph draws a gap for exactly that refusal, and any other revert fails the test instead.
    function _requireLeverageCapRefusal(bytes memory reason) internal view {
        assertEq(
            reason,
            abi.encodeWithSelector(
                IMinter_v3.BelowMinimumCollateralRatio.selector,
                IMinter_v3(minter).collateralRatio(),
                IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO()
            ),
            "the only refusal drawn as a gap is the leverage cap's"
        );
    }

    function setUp_collateral(
        uint256 collateralForPegged,
        uint256 collateralForLeveraged
    ) internal returns (uint256 peggedTokens, uint256 leveragedTokens) {
        return setUp_collateral(collateralForPegged, collateralForLeveraged, zeroFee);
    }

    function setUp_collateral(
        uint256 collateralForPegged,
        uint256 collateralForLeveraged,
        address recipient
    ) internal returns (uint256 peggedTokens, uint256 leveragedTokens) {
        // put some collateral into the minter to bootstrap it
        // get collateral & allowance
        uint256 totalAmount = collateralForPegged + collateralForLeveraged;
        deal(wrappedCollateralToken, zeroFee, totalAmount + 10 ether);
        assertGe(IERC20(wrappedCollateralToken).balanceOf(zeroFee), totalAmount + 10 ether, "zeroFee has collateral");

        assertTrue(
            IBaoRoles(minter).hasAnyRole(zeroFee, IMinter(minter).ZERO_FEE_ROLE()),
            "zeroFee should have zero fee role"
        );
        vm.startPrank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, totalAmount);
        // Leveraged first: a zero-fee leveraged mint is judged on the market it leaves, which with no pegged yet is
        // a ratio of infinity, and the zero-fee pegged mint after it is not judged - so any ratio can be set up,
        // the min CR included and below. Minted in either order the amounts are the same: with no pegged claim the
        // first leveraged tokens are a token per unit of collateral value, and a pegged mint at or above the peg
        // leaves the residual as it found it.
        if (collateralForLeveraged > 0) {
            leveragedTokens = IMinter(minter).freeMintLeveragedToken(collateralForLeveraged, recipient);
        }
        if (collateralForPegged > 0) {
            peggedTokens = IMinter(minter).freeMintPeggedToken(collateralForPegged, recipient);
        }
        vm.stopPrank();
    }
}

contract TestMinterInit is TestMinterSetUp {
    using SafeERC20 for IERC20;
    address impl;

    function setUpConfig() internal virtual override {}

    function setUp() public override {
        super.setUp();
        impl = address(new Minter_v3(wrappedCollateralToken, peggedToken, leveragedToken));
    }

    /// Ownership initialisation names the deployer explicitly rather than taking it from msg.sender, and the
    /// address named as pending owner is the one the deployer can hand ownership to.
    function test_initExplicitDeployerOwner() public {
        address deployerOwner = makeAddr("deployerOwner");
        assertNotEq(
            deployerOwner,
            address(this),
            "deployer owner must differ from the caller for this to discriminate"
        );

        address proxy = UnsafeUpgrades.deployUUPSProxy(
            impl,
            abi.encodeCall(Minter_v3.initialize, (deployerOwner, owner()))
        );

        // the owner is the address passed in, not whoever made the initializing call
        assertEq(IHarborOwnable(proxy).owner(), deployerOwner, "deployer owner is set from the argument");

        // the pending owner named at initialisation is the one the deployer can complete the transfer to
        vm.startPrank(deployerOwner);
        IHarborOwnable(proxy).transferOwnership(owner());
        vm.stopPrank();
        assertEq(IHarborOwnable(proxy).owner(), owner(), "pending owner receives ownership");
    }

    /// A fresh proxy's four schedules are each two free bands split at the peg, so a minter nobody has configured
    /// yet charges and subsidises nothing.
    function test_config_afterInitialisation_isTwoFreeBandsSplitAtThePeg() public {
        address proxy = UnsafeUpgrades.deployUUPSProxy(
            impl,
            abi.encodeCall(Minter_v3.initialize, (address(this), owner()))
        );
        IMinter.Config memory expected;
        expected.mintPeggedIncentiveConfig = ic(ua(100), ia(0, 0));
        expected.redeemPeggedIncentiveConfig = ic(ua(100), ia(0, 0));
        expected.mintLeveragedIncentiveConfig = ic(ua(100), ia(0, 0));
        expected.redeemLeveragedIncentiveConfig = ic(ua(100), ia(0, 0));
        _assertEqConfig(IMinter(proxy).config(), expected);
    }

    /// The implementation behind the proxies can never be initialised itself, so nobody can own it.
    function test_implementation_cannotBeInitialised() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Minter_v3(impl).initialize(address(this), owner());
    }

    /// Only the owner upgrades the minter: a stranger and a holder of the zero-fee role are refused, and the owner's
    /// upgrade to a new implementation keeps the config, both token balances and the collateral record.
    function test_upgrade_isRefusedToAnyoneButTheOwner() public {
        setUp_collateral(3 ether, 1 ether);
        IMinter.Config memory configBefore = IMinter(minter).config();
        uint256 peggedBefore = IMinter(minter).peggedTokenBalance();
        uint256 leveragedBefore = IMinter(minter).leveragedTokenBalance();
        uint256 collateralBefore = IMinter(minter).collateralTokenBalance();

        address[2] memory refused = [makeAddr("stranger"), zeroFee];
        for (uint256 i = 0; i < refused.length; i++) {
            vm.startPrank(refused[i]);
            vm.expectRevert(IHarborOwnable.Unauthorized.selector);
            UUPSUpgradeable(minter).upgradeToAndCall(impl, "");
            vm.stopPrank();
        }

        vm.startPrank(owner());
        vm.expectEmit(minter);
        emit IERC1967.Upgraded(impl);
        UUPSUpgradeable(minter).upgradeToAndCall(impl, "");
        vm.stopPrank();

        _assertEqConfig(IMinter(minter).config(), configBefore);
        assertEq(IMinter(minter).peggedTokenBalance(), peggedBefore, "pegged balance kept");
        assertEq(IMinter(minter).leveragedTokenBalance(), leveragedBefore, "leveraged balance kept");
        assertEq(IMinter(minter).collateralTokenBalance(), collateralBefore, "collateral record kept");
    }

    /// The minter reports each interface it implements - its own, the token holder's, ownership, roles and ERC-165
    /// itself - and not the id ERC-165 reserves as invalid.
    function test_supportsInterface_reportsEachInterfaceItImplements() public view {
        assertTrue(IERC165(minter).supportsInterface(type(IMinter_v3).interfaceId), "IMinter_v3");
        assertTrue(IERC165(minter).supportsInterface(type(ITokenHolder).interfaceId), "ITokenHolder");
        assertTrue(IERC165(minter).supportsInterface(type(IHarborOwnable).interfaceId), "IHarborOwnable");
        assertTrue(IERC165(minter).supportsInterface(type(IHarborRoles).interfaceId), "IHarborRoles");
        assertTrue(IERC165(minter).supportsInterface(type(IERC165).interfaceId), "IERC165");
        assertFalse(IERC165(minter).supportsInterface(0xffffffff), "the invalid id");
    }

    function test_notERC20() public {
        new Minter_v3(wrappedCollateralToken, peggedToken, leveragedToken);

        // zero address
        vm.expectRevert(abi.encodeWithSelector(Token.ZeroAddress.selector));
        new Minter_v3(address(0), peggedToken, leveragedToken);

        vm.expectRevert(abi.encodeWithSelector(Token.ZeroAddress.selector));
        new Minter_v3(Deployed.wstETH, address(0), leveragedToken);

        vm.expectRevert(abi.encodeWithSelector(Token.ZeroAddress.selector));
        new Minter_v3(Deployed.wstETH, peggedToken, address(0));

        // not a contract - an address chosen for having no code, rather than an actor that happens to lack
        // it. Asserted, because on a fork "has no code" is a fact about the chain at that block: this used
        // to be `owner()`, whose address carries an EIP-7702 delegation on mainnet at recent blocks, so the
        // constructor reached its NotERC20Token branch instead and the failure said nothing about why.
        address notAContract = makeAddr("notAContract");
        assertEq(notAContract.code.length, 0, "the address must have no code for this to test what it says");

        vm.expectRevert(abi.encodeWithSelector(Token.NotContractAddress.selector, notAContract));
        new Minter_v3(notAContract, peggedToken, leveragedToken);

        vm.expectRevert(abi.encodeWithSelector(Token.NotContractAddress.selector, notAContract));
        new Minter_v3(Deployed.wstETH, notAContract, leveragedToken);

        vm.expectRevert(abi.encodeWithSelector(Token.NotContractAddress.selector, notAContract));
        new Minter_v3(Deployed.wstETH, peggedToken, notAContract);

        // contract but not ERC20
        vm.expectRevert(abi.encodeWithSelector(Token.NotERC20Token.selector, priceOracle));
        new Minter_v3(priceOracle, peggedToken, leveragedToken);

        vm.expectRevert(abi.encodeWithSelector(Token.NotERC20Token.selector, priceOracle));
        new Minter_v3(Deployed.wstETH, priceOracle, leveragedToken);

        vm.expectRevert(abi.encodeWithSelector(Token.NotERC20Token.selector, priceOracle));
        new Minter_v3(Deployed.wstETH, peggedToken, priceOracle);
    }

    function test_initEventsImplementation() public {
        vm.expectEmit();
        emit Initializable.Initialized(type(uint64).max); // from the logic contract constructor
        address(new Minter_v3(Deployed.wstETH, peggedToken, address(leveragedToken)));
    }

    function test_initEvents() public {
        vm.expectEmit();
        emit IERC1967.Upgraded(impl);
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(0), address(this));
        vm.expectEmit();
        emit Initializable.Initialized(1); // from the proxy delegate call

        UnsafeUpgrades.deployUUPSProxy(impl, abi.encodeCall(Minter_v3.initialize, (address(this), owner())));
    }

    function test_init() public {
        // expect a revert if initialize called twice
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Minter_v3(minter).initialize(address(this), owner());

        // The deploy applied the market's config, which is how a minter gets one in production. Changing it
        // afterwards is a separate operation with its own tests - and its own production script.
        _assertEqConfig(IMinter(minter).config(), marketConfig.minterConfig());

        // no pegged tokens: the ratio reports 1 rather than dividing by zero
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "the collateral ratio of an empty market is 1");
    }
}

contract TestMinterBasics is TestMinterSetUp {
    using SafeERC20 for IERC20;

    address user;

    function setUp() public virtual override(TestMinterSetUp) {
        super.setUp();
        user = makeAddr("user");
    }

    function _checkConfig(
        IMinter.IncentiveConfig memory mintPegged,
        IMinter.IncentiveConfig memory redeemPegged,
        IMinter.IncentiveConfig memory mintLeveraged,
        IMinter.IncentiveConfig memory redeemLeveraged
    ) private {
        setUp_config(mintPegged, redeemPegged, mintLeveraged, redeemLeveraged);

        vm.startPrank(owner());
        IMinter(minter).updateConfig(config);
        vm.stopPrank();
        IMinter.Config memory readConfig = IMinter(minter).config();
        _assertEqConfig(readConfig, config);
    }

    function test_init() public view {
        assertEq(IBaoOwnable(minter).owner(), owner());
        assertEq(IMinter(minter).WRAPPED_COLLATERAL_TOKEN(), Deployed.wstETH);
        assertEq(IMinter(minter).PEGGED_TOKEN(), peggedToken);
        assertEq(IMinter(minter).LEVERAGED_TOKEN(), address(leveragedToken));
        assertEq(IMinter(minter).priceOracle(), address(priceOracle));
        assertEq(IMinter(minter).feeReceiver(), feeReceiver);
        assertEq(IMinter(minter).reservePool(), reservePool);
        assertEq(IMinter(minter).peggedTokenBalance(), 0);
        assertEq(IMinter(minter).leveragedTokenBalance(), 0);
        assertEq(IMinter(minter).collateralTokenBalance(), 0);
        assertEq(IMinter(minter).collateralRatio(), 1 ether);
        // No residual: the leveraged claim is nothing, which the report encodes as the maximum.
        assertEq(IMinter(minter).leverageRatio(), type(uint256).max);
        assertEq(IMinter(minter).leveragedTokenPrice(), 1 ether);
        assertEq(IMinter(minter).peggedTokenPrice(), 1 ether);
    }

    /// A market that has minted nothing has nothing to redeem, and reads a collateral ratio of exactly one - under the
    /// min CR - so retail mints of pegged and of leveraged both revert there, whatever the incentive config allows.
    function test_firstMintRedeem1() public {
        setUp_config_feeIsCR();
        vm.startPrank(owner());
        IMinter(minter).updateConfig(config);
        vm.stopPrank();

        assertEq(IMinter(minter).peggedTokenBalance(), 0, "no pegged");
        assertEq(IMinter(minter).leveragedTokenBalance(), 0, "no leveraged");

        // make sure we have it all
        deal(wrappedCollateralToken, address(this), 10 ether);
        deal(peggedToken, address(this), 10 ether);
        deal(leveragedToken, address(this), 10 ether);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, peggedToken));
        IMinter(minter).redeemPeggedToken(1 ether, user, 0);

        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, leveragedToken));
        IMinter(minter).redeemLeveragedToken(1 ether, user, 0);

        assertEq(IMinter(minter).collateralRatio(), 1 ether, "an empty market reads exactly one");
        bytes memory belowMinimum = abi.encodeWithSelector(
            IMinter_v3.BelowMinimumCollateralRatio.selector,
            1 ether,
            IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO()
        );
        vm.expectRevert(belowMinimum);
        IMinter(minter).mintPeggedToken(1 ether, user, 0);
        vm.expectRevert(belowMinimum);
        IMinter(minter).mintLeveragedToken(1 ether, user, 0);
    }

    /// Minted pegged alone by the zero-fee route, a market sits exactly at the peg: a retail leveraged mint reverts
    /// there, and a zero-fee one is served where its deposit lifts the market to the min CR - a wei short reverts
    /// naming the ratio it would leave - its tokens then holding the whole residual after the deposit.
    function test_firstMintRedeem2() public {
        setUp_config_feeIsCR();
        vm.startPrank(owner());
        IMinter(minter).updateConfig(config);
        vm.stopPrank();
        setUp_collateral(1 ether, 0);
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "pegged alone reads exactly one");
        uint256 minimum = IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO();

        deal(wrappedCollateralToken, address(this), 10 ether);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.BelowMinimumCollateralRatio.selector, 1 ether, minimum));
        IMinter(minter).mintLeveragedToken(1 ether, user, 0);

        // the zero-fee mint credits at the low rate - one here, so a wei of wrapped is a wei of collateral - and is
        // judged at the middle price; it prices the tokens at the high price
        (uint256 minPrice, uint256 maxPrice, uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        assertEq(rate, 1 ether, "precondition: a wei of wrapped is a wei of collateral");
        uint256 midPrice = (minPrice + maxPrice + 1) / 2;
        uint256 backing = IMinter(minter).collateralTokenBalance();
        uint256 pegged = IMinter(minter).peggedTokenBalance();
        uint256 lift = Math.mulDiv(minimum, pegged, midPrice, Math.Rounding.Ceil) - backing;
        deal(wrappedCollateralToken, zeroFee, lift);
        bytes memory wouldLeave = abi.encodeWithSelector(
            IMinter_v3.BelowMinimumCollateralRatio.selector,
            Math.mulDiv(backing + lift - 1, midPrice, pegged),
            minimum
        );
        vm.startPrank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, lift);
        vm.expectRevert(wouldLeave);
        IMinter(minter).freeMintLeveragedToken(lift - 1, user);
        uint256 minted = IMinter(minter).freeMintLeveragedToken(lift, user);
        vm.stopPrank();

        assertEq(
            minted,
            Math.mulDiv(IMinter(minter).collateralTokenBalance(), maxPrice, 1 ether) -
                IMinter(minter).peggedTokenBalance(),
            "the first leveraged tokens hold the whole residual after the deposit"
        );
        assertEq(IMinter(minter).collateralRatio(), minimum, "the market is left exactly at the min CR");
    }

    /// At the peg and below it a retail pegged mint reverts at the min CR, though the incentive config allows it. The
    /// zero-fee pegged mint is not judged: below the peg it mints at the depressed pegged price, leaving the price a
    /// pegged token redeems at unchanged, and the record equal to the holding.
    function test_depegBoundary() public {
        // simple config that has a fee and a subsidy
        _checkConfig(
            ic(ua(100), ia(150, 50)), // mint pegged 50 basis points = 0.5 %
            ic(ua(100, 300), ia(-100, -100, 0)), // redeem pegged
            ic(ua(100, 300), ia(-50, -50, 0)), // mint leveraged
            ic(ua(100), ia(100, 100)) // redeem leveraged
        );

        (uint256 startPrice, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(1 ether, 0);
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            IERC20(address(Deployed.wstETH)).balanceOf(minter),
            "collaterals balance after freeMint"
        );
        IERC20(peggedToken).approve(minter, type(uint256).max);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        deal(wrappedCollateralToken, reservePool, 1 ether);

        // At the peg and below it a retail pegged mint reverts at the min CR, though the incentive config allows it.
        uint256 minimum = IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO();
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "CR is 1");
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.BelowMinimumCollateralRatio.selector, 1 ether, minimum));
        IMinter(minter).mintPeggedToken(3 ether, address(this), 0);

        MockWrappedPriceOracle(priceOracle).setLatestAnswer((startPrice * 9) / 10);
        (uint256 lowerPrice, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        assertLt(lowerPrice, startPrice);

        uint256 peggedNav = IMinter(minter).peggedTokenPrice();
        assertLt(peggedNav, 1 ether);
        uint256 ratio = IMinter(minter).collateralRatio();
        assertLt(ratio, 1 ether, "CR is < 1");
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.BelowMinimumCollateralRatio.selector, ratio, minimum));
        IMinter(minter).mintPeggedToken(2 ether, address(this), 0);

        // The zero-fee pegged mint is not judged: below the peg it mints at the depressed pegged price - each
        // collateral token buying the pegged that one already backs - so the price a pegged token redeems at is
        // unchanged.
        uint256 peggedBefore = IMinter(minter).peggedTokenBalance();
        deal(wrappedCollateralToken, zeroFee, 2 ether);
        vm.startPrank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, 2 ether);
        uint256 secondMinted = IMinter(minter).freeMintPeggedToken(2 ether, address(this));
        vm.stopPrank();
        //-----------------------------------------------------
        assertEq(secondMinted, 2 * peggedBefore, "two collateral buy what two already back");
        assertEq(IMinter(minter).peggedTokenPrice(), peggedNav, "pegged NAV hasn't changed");
        assertEq(IMinter(minter).collateralTokenBalance(), 3 ether, "collaterals should be 3");
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            IERC20(address(Deployed.wstETH)).balanceOf(minter),
            "collaterals balance after depegged mint"
        );
    }

    function test_connections() public {
        // simple config that has a fee and a subsidy
        _checkConfig(
            ic(ua(100), ia(50, 50)), // mint pegged 50 basis points = 0.5 %
            ic(ua(100, 300), ia(-100, -100, 0)), // redeem pegged: the redeem below stays under 3
            ic(ua(100, 300), ia(-50, -50, 0)), // mint leveraged
            ic(ua(100), ia(100, 100)) // redeem leveraged
        );
        // need collateral to start the process
        setUp_collateral(1 ether, 1 ether, address(this));
        (uint256 rawPrice, , uint256 rawRate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        uint256 startPeggedOrLeveraged = (rawRate * rawPrice) / 1 ether;
        assertEq(IMinter(minter).peggedTokenBalance(), startPeggedOrLeveraged, "setup_collateral works - pegged");
        assertEq(IMinter(minter).leveragedTokenBalance(), startPeggedOrLeveraged, "setup_collateral works - leveraged");
        assertEq(IMinter(minter).collateralTokenBalance(), 2 ether, "setup_collateral works - leveraged");

        IERC20(peggedToken).approve(minter, type(uint256).max);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        deal(wrappedCollateralToken, reservePool, 1 ether);

        // price
        (
            int256 incentiveRatio,
            uint256 fee,
            uint256 collateralTaken,
            uint256 peggedMinted,
            uint256 price,
            uint256 rate
        ) = IMinter(minter).mintPeggedTokenDryRun(1 ether);
        assertEq(price, rawPrice, "stETH price");
        assertEq(rate, rawRate, "stETH/wstETH rate");
        assertEq(
            peggedMinted,
            (uint256(1 ether - fee) * (price * rate)) / (1 ether * 1 ether),
            "pegged minted is the collateral net of the fee, at the price"
        );
        assertEq(collateralTaken, 1 ether, "all the collateral is used");
        assertEq(
            uint256(incentiveRatio),
            uint256(config.mintPeggedIncentiveConfig.incentiveRatios[0]), // 5e15
            "the incentive ratio should match the config"
        );
        assertEq(
            fee,
            uint256(config.mintPeggedIncentiveConfig.incentiveRatios[0]), // 5e15
            "the fee should match the config for unit collateral"
        );

        // feeReceiver
        assertEq(IERC20(wrappedCollateralToken).balanceOf(feeReceiver), 0);
        uint256 startCollateral = IERC20(wrappedCollateralToken).balanceOf(address(this));
        uint256 minted = IMinter(minter).mintPeggedToken(1 ether, address(this), 0);
        // --------------------------------------------------------------------------
        assertEq(fee, (1 ether * 5) / 1000);
        assertEq(IERC20(wrappedCollateralToken).balanceOf(feeReceiver), (1 ether * 5) / 1000);
        assertEq(IMinter(minter).peggedTokenBalance(), price + (price * 995) / 1000, "correct amount minted, 2");
        assertEq(minted, peggedMinted, "amount minted is the same as predicted");
        assertEq(IERC20(wrappedCollateralToken).balanceOf(address(this)), startCollateral - 1 ether);

        // reserve pool - same as above but with a subsidy, not a fee
        (, uint256 redeemFee, uint256 subsidy, uint256 peggedRedeemed, uint256 collateralReturned, , ) = IMinter(minter)
            .redeemPeggedTokenDryRun(price);
        assertEq(
            int256(redeemFee) - int256(subsidy),
            config.redeemPeggedIncentiveConfig.incentiveRatios[0],
            "dryRun feeOrSubsidy"
        );
        assertEq(collateralReturned, 1 ether + subsidy - redeemFee, "dryRun collateralReturned");
        assertEq(peggedRedeemed, price, "dryRun peggedRedeemed");

        assertEq(IERC20(wrappedCollateralToken).balanceOf(reservePool), 1 ether);
        uint256 returned = IMinter(minter).redeemPeggedToken(price, address(this), 0);
        // --------------------------------------------------------------------------
        assertEq(peggedRedeemed, price, "Pegged redeemed");
        assertEq(
            int256(redeemFee) - int256(subsidy),
            config.redeemPeggedIncentiveConfig.incentiveRatios[0],
            "feeOrSubsidy"
        );
        assertEq(IERC20(wrappedCollateralToken).balanceOf(feeReceiver), (1 ether * 5) / 1000, "feeReceiver as before");
        assertEq(IMinter(minter).peggedTokenBalance(), (price * 995) / 1000, "pegged balance as before - redeemed");
        assertEq(returned, collateralReturned, "amount returned is the same as predicted");
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(address(this)),
            startCollateral + collateralReturned - 1 ether
        );

        // tokens
        assertEq(IMinter(minter).PEGGED_TOKEN(), peggedToken);
        assertEq(IMinter(minter).WRAPPED_COLLATERAL_TOKEN(), Deployed.wstETH);
    }

    function test_ratios() public {
        // initial values
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "initial collateral ratio");
        // No residual yet: a claim of nothing, reported as the maximum.
        assertEq(IMinter(minter).leverageRatio(), type(uint256).max, "initial leverage ratio");
        assertEq(IMinter(minter).peggedTokenPrice(), 1 ether, "initial pegged token price");
        assertEq(IMinter(minter).leveragedTokenPrice(), 1 ether, "initial leveraged token price");
        assertEq(IMinter(minter).peggedTokenBalance(), 0, "initial pegged token balance");
        assertEq(IMinter(minter).leveragedTokenBalance(), 0, "initial leveraged token balance");
        assertEq(IMinter(minter).collateralTokenBalance(), 0, "initial collateral token balance");

        // add collateral from minting pegged
        (uint256 peggedMinted, uint256 leveragedMinted) = setUp_collateral(10 ether, 0);
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "post pegged mint collateral ratio");
        // Pegged alone puts the ratio at exactly one: still no residual, still a claim of nothing.
        assertEq(IMinter(minter).leverageRatio(), type(uint256).max, "post pegged mint leverage ratio");
        assertEq(IMinter(minter).peggedTokenPrice(), 1 ether, "post pegged mint pegged token price");
        assertEq(IMinter(minter).leveragedTokenPrice(), 1 ether, "post pegged mint leveraged token price");
        assertEq(IMinter(minter).peggedTokenBalance(), peggedMinted, "post pegged mint pegged token balance"); // minted some pegged
        assertEq(IMinter(minter).leveragedTokenBalance(), 0, "post pegged mint leveraged token balance");
        assertEq(IMinter(minter).collateralTokenBalance(), 10 ether, "post pegged mint collateral token balance"); // updated collateral balance

        // add collateral from minting pegged
        (, leveragedMinted) = setUp_collateral(0, 10 ether);
        assertEq(IMinter(minter).collateralRatio(), 2 ether, "post leveraged mint collateral ratio");
        assertEq(IMinter(minter).leverageRatio(), 2 ether, "post leveraged mint leverage ratio"); // highest value
        assertEq(IMinter(minter).peggedTokenPrice(), 1 ether, "post leveraged mint pegged token price");
        assertEq(IMinter(minter).leveragedTokenPrice(), 1 ether, "post leveraged mint leveraged token price");
        assertEq(IMinter(minter).peggedTokenBalance(), peggedMinted, "post leveraged mint pegged token balance"); // minted some pegged
        assertEq(
            IMinter(minter).leveragedTokenBalance(),
            leveragedMinted,
            "post leveraged mint leveraged token balance"
        ); // minted some leveraged
        assertEq(IMinter(minter).collateralTokenBalance(), 20 ether, "post leveraged mint collateral token balance"); // updated collateral balance
    }
}
