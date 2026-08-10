// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {BaoTest} from "@bao-test/BaoTest.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IHarborOwnable} from "@bao/interfaces/IHarborOwnable.sol";

import {Minter_v3} from "@harbor/minter/Minter_v3.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {Token} from "@bao/Token.sol";
import {IMintable} from "@bao/interfaces/IMintable.sol";
import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";

import {Deployed} from "@bao/Deployed.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {IBaoUSD} from "@harbor-test/IBaoUSD.sol";
import "@harbor-test/Useful.sol";
import {Array} from "@harbor-test/Array.sol";

import {ConfigFile} from "@harbor-test/Config.sol";
import {HarborDeployRun} from "@harbor-test/HarborDeployRun.sol";
import {TestMinterMarketConfig} from "@harbor-test/config/TestMinterMarketConfig.sol";
import {ConfigPeg, ConfigPeg_BTC} from "@harbor-script/config/pegs/ConfigPeg_BTC.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {IMintableRole} from "@bao/interfaces/IMintableRole.sol";
import {IBurnableRole} from "@bao/interfaces/IBurnableRole.sol";
import {IReservePool} from "@harbor/interfaces/IReservePool.sol";

contract TestMinterSetUp is BaoTest, Clog, Array, ConfigFile, HarborDeployRun {
    constructor() HarborDeployRun(makeAddr("owner"), makeAddr("feeReceiver"), "minter_test", "mainnet") {}

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
        if (Token.hasNonMutatingParameterlessFunction(peggedToken, "operator")) {
            vm.prank(IBaoUSD(peggedToken).operator());
            IMintable(peggedToken).mint(receiver, amount);
        } else {
            // if the pegged token does not have an operator, we mint it directly
            vm.prank(owner());
            IMintable(peggedToken).mint(receiver, amount);
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

    /// @dev The number of adjacent incentive bands whose fee/discount rate differs — i.e. how many distinct
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

    function setUp_config_flatDiscountWide() internal {
        setUp_config(
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(50, 50, 50, 50, 50, 50, 50, 50)),
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(-80, -80, -80, -80, -80, -80, -80, -80)),
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(-70, -70, -70, -70, -70, -70, -70, -70)),
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(120, 120, 120, 120, 120, 120, 120, 120))
        );
    }

    function setUp_config_flatDisallowDiscountWide() internal {
        setUp_config(
            ic(ua(110, 120, 130, 140, 150, 160), ia(disallow, 50, 50, 50, 50, 50, 50)),
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(-80, -80, -80, -80, -80, -80, -80, -80)),
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(-70, -70, -70, -70, -70, -70, -70, -70)),
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

    function setUp_config_directionalDisallowDiscountWide() internal {
        setUp_config(
            ic(ua(110, 120, 130, 140, 150, 160), ia(disallow, 110, 100, 90, 80, 70, 60)),
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(-120, -110, -100, -90, -80, -70, -60, -50)),
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(-120, -110, -100, -90, -80, -70, -60, -50)),
            ic(ua(110, 120, 130, 140, 150, 160), ia(disallow, 110, 100, 90, 80, 70, 60))
        );
    }

    function setUp_config_reverseDirectionalDisallowDiscountWide() internal {
        setUp_config(
            ic(ua(110, 120, 130, 140, 150, 160), ia(disallow, 60, 70, 80, 90, 100, 110)),
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(-50, -60, -70, -80, -90, -100, -110, -120)),
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(-50, -60, -70, -80, -90, -100, -110, -120)),
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
                string.concat(name, " collateralRatioBandUpperBounds[", Useful.toString(i), "] differ")
            );
        }
        assertEq(actual.incentiveRatios.length, expected.incentiveRatios.length, "incentiveRatios.length differ ");
        for (uint i = 0; i < actual.incentiveRatios.length; i++) {
            assertEq(
                actual.incentiveRatios[i],
                expected.incentiveRatios[i],
                string.concat(name, " incentiveRatios[", Useful.toString(i), "] differ")
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

    /// @dev Phase 2 of the deploy run, stopping after the minter. The stability pools, manager and genesis
    ///      above it are neither deployed nor paid for, because nothing in this suite touches them.
    ///      `deployPeg` is ignored: the minter cannot be built without its peg's token.
    function _deployAndConfigure(
        DeploymentTypes.State memory state,
        ConfigPeg peg,
        Config_MinterMarket[] memory allMarkets,
        bool,
        Config_MinterMarket[] memory marketsToDeploy
    ) internal virtual override {
        deployPeggedTokenWithRoles(state, peg, allMarkets);

        _deployLeveragedTokenWithRoles(state, marketsToDeploy[0]);
        deployReservePool(state, marketsToDeploy[0]);
        deployMinter(state, marketsToDeploy[0]);
    }

    function setUpFork() internal virtual {
        forkMainnet();

        feeReceiver = treasury();

        marketConfig = new TestMinterMarketConfig();
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

        Config_MinterMarket[] memory markets = new Config_MinterMarket[](1);
        markets[0] = marketConfig;

        address factory = ensureFactory();
        vm.startPrank(IBaoFactory(factory).owner());
        IBaoFactory(factory).setOperator(address(this), 365 days);
        vm.stopPrank();

        deploy(new ConfigPeg_BTC(), markets, true, markets);

        minter = minterAddress(marketConfig);
        peggedToken = peggedTokenAddress(marketConfig);
        leveragedToken = leveragedTokenAddress(marketConfig);
        reservePool = reservePoolAddress(marketConfig);

        // The price oracle is a separate deployment the minter only knows by predicted address. Etch the mock
        // AFTER the deploy, so the deploy is exercised against a codeless reference exactly as in production,
        // then restore the state `vm.etch` does not copy.
        priceOracle = wrappedPriceOracleAddress(marketConfig);
        MockWrappedPriceOracle template = new MockWrappedPriceOracle();
        vm.etch(priceOracle, address(template).code);
        // `vm.etch` copies code but not storage, so the etched oracle arrives with every field zeroed and its
        // constructor never runs. Seed it FROM the constructed template rather than restating the mock's
        // starting values here, so the two cannot drift apart.
        (uint256 minPrice, uint256 maxPrice, uint256 minRate, uint256 maxRate) = template.latestAnswer();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(minPrice, maxPrice, minRate, maxRate);
        MockWrappedPriceOracle(priceOracle).setQuoteName(template.quoteName());
        vm.label(priceOracle, "priceOracle");

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
        if (collateralForPegged > 0) {
            peggedTokens = IMinter(minter).freeMintPeggedToken(collateralForPegged, recipient);
        }
        if (collateralForLeveraged > 0) {
            leveragedTokens = IMinter(minter).freeMintLeveragedToken(collateralForLeveraged, recipient);
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

    // TODO: do this test for all contracts
    // TODO: do test for initialize calls
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

        UnsafeUpgrades.deployUUPSProxy(
            impl, // "Minter_v3.sol",
            abi.encodeCall(Minter_v3.initialize, (address(this), owner()))
        );
    }

    function test_init() public {
        // expect a revert if initialize called twice
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Minter_v3(minter).initialize(address(this), owner());

        // The deploy applied the market's config, which is how a minter gets one in production. Changing it
        // afterwards is a separate operation with its own tests - and its own production script.
        _assertEqConfig(IMinter(minter).config(), marketConfig.minterConfig());

        // also add checks for leveraged price, etc - all the view functions

        // no pegged tokens so divide by zero
        assertEq(
            IMinter(minter).collateralRatio(),
            1 ether, // 1 when nothing has happened
            "very high collateral ratios capped at maxuint256"
        );
    }
}

contract TestMinterBasics is TestMinterSetUp {
    using SafeERC20 for IERC20;

    address user;

    function setUp() public virtual override(TestMinterSetUp) {
        super.setUp();
        user = makeAddr("user");
    }

    function test_introspection() public view {
        assertTrue(
            Minter_v3(minter).supportsInterface(type(IMinter).interfaceId) ||
                Minter_v3(minter).supportsInterface(type(IMinter_v3).interfaceId),
            "should support IMinter"
        );
        assertFalse(Minter_v3(minter).supportsInterface(bytes4(0)), "doesn't support 0");
    }

    function _checkConfig(
        IMinter.IncentiveConfig memory mintPegged,
        IMinter.IncentiveConfig memory redeemPegged,
        IMinter.IncentiveConfig memory mintLeveraged,
        IMinter.IncentiveConfig memory redeemLeveraged,
        bytes memory revertSelector
    ) private {
        setUp_config(mintPegged, redeemPegged, mintLeveraged, redeemLeveraged);

        if (revertSelector.length != 0) vm.expectRevert(revertSelector);
        vm.prank(owner());
        IMinter(minter).updateConfig(config);
        IMinter.Config memory readConfig = IMinter(minter).config();
        _assertEqConfig(readConfig, config);
    }

    // TODO: check other functions:
    // free mint/redeem of leveraged/pegged
    // swap
    // mint/redeem of leveraged/pegged
    // collateral ratio, leveraged ratio, prices
    // all should be independent of the whether it is a mock or actual being called
    // mocks are: priceOracle, feeReceiver, baousd & wstETH

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
        assertEq(IMinter(minter).leverageRatio(), 20 ether); // 20 is the cap.
        assertEq(IMinter(minter).leveragedTokenPrice(), 1 ether);
        assertEq(IMinter(minter).peggedTokenPrice(), 1 ether);
    }

    function test_firstMintRedeem1() public {
        setUp_config_feeIsCR();
        vm.prank(owner());
        IMinter(minter).updateConfig(config);
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();

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

        IMinter(minter).mintPeggedToken(1 ether, user, 0);
        assertEq(IMinter(minter).peggedTokenBalance(), ((1 ether - 0.01 ether) * price) / 1e18, "pegged minted");

        // even though there are pegged tokens, leveraged tokens are worthless
        vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, leveragedToken));
        IMinter(minter).mintLeveragedToken(1 ether, user, 0);

        // shift the price a tad to make them have some value, also only mint a toaty amount of leveraged
        // if we minted 1 ether that would shift CR from 1 to 2 passing all the bands
        price = (price * 1000) / 999;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price);
        IMinter(minter).mintLeveragedToken(0.001 ether, user, 0);
        assertApprox(IMinter(minter).leveragedTokenBalance(), 4 ether, 0, 0.1 ether, "leveraged minted");
    }

    function test_firstMintRedeem2() public {
        setUp_config_feeIsCR();
        vm.prank(owner());
        IMinter(minter).updateConfig(config);

        assertEq(IMinter(minter).peggedTokenBalance(), 0, "no pegged");
        assertEq(IMinter(minter).leveragedTokenBalance(), 0, "no leveraged");

        // make sure we have it all
        deal(wrappedCollateralToken, address(this), 10 ether);
        deal(peggedToken, address(this), 10 ether);
        deal(leveragedToken, address(this), 10 ether);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);

        // at this point leveraged tokens are worthless, so we don't retuen any
        vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, leveragedToken));
        IMinter(minter).mintLeveragedToken(1 ether, user, 0);
        // assertEq(IMinter(minter).leveragedTokenBalance(), ((1 ether - 0.01 ether) * price) / 1e18, "leveraged minted");
    }

    // TODO: test that if the config is set up for no fees or discounts then free mint/redeem = normal mint/redeem

    function test_depegBoundary() public {
        // simple config that has a fee and a discount
        _checkConfig(
            ic(ua(100), ia(150, 50)), // mint pegged 50 basis points = 0.5 %
            ic(ua(100), ia(-100, -100)), // redeem pegged
            ic(ua(100), ia(-50, -50)), // mint leveraged
            ic(ua(100), ia(100, 100)), // redeem leveraged
            ""
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

        // mint some then redeem it
        uint256 depeggedCollateral = 1 ether - uint256(config.mintPeggedIncentiveConfig.incentiveRatios[0]);
        uint256 collateral = 1 ether - uint256(config.mintPeggedIncentiveConfig.incentiveRatios[1]);

        assertEq(IMinter(minter).collateralRatio(), 1 ether, "CR is 1");
        uint256 firstMinted = IMinter(minter).mintPeggedToken(3 ether, address(this), 0);
        //--------------------------------------------------
        assertEq(IERC20(peggedToken).balanceOf(address(this)), firstMinted, "returned equals actual");
        assertEq(firstMinted, (collateral * 3 * startPrice) / 1 ether, "fee not correct");
        assertEq(IMinter(minter).collateralTokenBalance(), 1 ether + collateral * 3, "collaterals should be 4");
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            IERC20(address(Deployed.wstETH)).balanceOf(minter),
            "collaterals balance after mint"
        );

        // IMinter(minter).redeemPeggedToken(2 * price, address(this), 0);
        // assertEq(
        //     IMinter(minter).collateralTokenBalance(),
        //     IERC20(address(Deployed.wstETH)).balanceOf(minter),
        //     "collaterals balance after redeem"
        // );

        MockWrappedPriceOracle(priceOracle).setLatestAnswer((startPrice * 9) / 10);
        (uint256 lowerPrice, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        assertLt(lowerPrice, startPrice);

        uint256 peggedNav = IMinter(minter).peggedTokenPrice();
        assertLt(peggedNav, 1 ether);
        assertLt(IMinter(minter).collateralRatio(), 1 ether, "CR is < 1");
        uint256 secondMinted = IMinter(minter).mintPeggedToken(2 ether, address(this), 0);
        //-----------------------------------------------------
        assertEq(
            IERC20(peggedToken).balanceOf(address(this)),
            firstMinted + secondMinted,
            "returned equals actual after depegged mint"
        );
        assertEq(IMinter(minter).peggedTokenPrice(), peggedNav, "pegged NAV hasn't changed");
        // assertEq(secondMinted, (depeggedCollateral * 2 * lowerPrice) / 1 ether, "fee not correct after depegged mint");
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            1 ether + collateral * 3 + depeggedCollateral * 2,
            "collaterals should be 6"
        );
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            IERC20(address(Deployed.wstETH)).balanceOf(minter),
            "collaterals balance after depegged mint"
        );
    }

    function test_connections() public {
        // simple config that has a fee and a discount
        _checkConfig(
            ic(ua(100), ia(50, 50)), // mint pegged 50 basis points = 0.5 %
            ic(ua(100), ia(-100, -100)), // redeem pegged
            ic(ua(100), ia(-50, -50)), // mint leveraged
            ic(ua(100), ia(100, 100)), // redeem leveraged
            ""
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
        assertEq(rate, rate, "stETH/wstETH rate");
        assertEq(
            peggedMinted,
            (uint256(1 ether - fee) * (price * rate)) / (1 ether * 1 ether),
            "TODO: correct amount minted, should take fee into acount"
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

        // reserve pool - same as above but with a discount, not a fee
        (, uint256 redeemFee, uint256 discount, uint256 peggedRedeemed, uint256 collateralReturned, , ) = IMinter(
            minter
        ).redeemPeggedTokenDryRun(price);
        assertEq(
            int256(redeemFee) - int256(discount),
            config.redeemPeggedIncentiveConfig.incentiveRatios[0],
            "dryRun feeOrDiscount"
        );
        assertEq(collateralReturned, 1 ether + discount - redeemFee, "dryRun collateralReturned");
        assertEq(peggedRedeemed, price, "dryRun peggedRedeemed");

        assertEq(IERC20(wrappedCollateralToken).balanceOf(reservePool), 1 ether);
        uint256 returned = IMinter(minter).redeemPeggedToken(price, address(this), 0);
        // --------------------------------------------------------------------------
        assertEq(peggedRedeemed, price, "Pegged redeemed");
        assertEq(
            int256(redeemFee) - int256(discount),
            config.redeemPeggedIncentiveConfig.incentiveRatios[0],
            "feeOrDiscount"
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

        // TODO: rebalance pool
    }

    function test_incentiveRatios() private view {
        // TODO: add these back in when collateral ratio function is fixed
        int256 instantaneousIr = IMinter(minter).mintPeggedTokenIncentiveRatio();
        (int256 ir, , , , , ) = IMinter(minter).mintPeggedTokenDryRun(0);
        assertEq(instantaneousIr, ir, "mint pegged ir");
    }

    function test_freeMint() public {
        setUp_collateral(10 ether, 10 ether);
        assertEq(IMinter(minter).collateralRatio(), 2 ether, "collateral ratio");
        assertEq(IMinter(minter).peggedTokenPrice(), 1 ether, "pegged token price");
        // TODO: do the actual mint
    }

    function test_mint() public {
        // TODO: compare the dry run with the actual
    }

    function test_ratios() public {
        // initial values
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "initial collateral ratio");
        assertEq(IMinter(minter).leverageRatio(), 20 ether, "initial leverage ratio"); // highest value
        assertEq(IMinter(minter).peggedTokenPrice(), 1 ether, "initial pegged token price");
        assertEq(IMinter(minter).leveragedTokenPrice(), 1 ether, "initial leveraged token price");
        assertEq(IMinter(minter).peggedTokenBalance(), 0, "initial pegged token balance");
        assertEq(IMinter(minter).leveragedTokenBalance(), 0, "initial leveraged token balance");
        assertEq(IMinter(minter).collateralTokenBalance(), 0, "initial collateral token balance");

        // add collateral from minting pegged
        (uint256 peggedMinted, uint256 leveragedMinted) = setUp_collateral(10 ether, 0);
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "post pegged mint collateral ratio");
        assertEq(IMinter(minter).leverageRatio(), 20 ether, "post pegged mint leverage ratio"); // highest value
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

    function test_config() public {
        int256 incentivePrecision = 10 ** 9;

        // TODO: read config from files - same for deploy script

        IMinter.Config memory readConfig = IMinter(minter).config();
        _assertEqConfig(readConfig, config); // check the default setup
        // do a null update to make sure the update config function works
        _checkConfig(
            ic(ua(131, 140), ia(disallow, 100, 50)),
            ic(ua(100, 110, 120, 140), ia(-50, -50, 0, 20, 70)),
            ic(ua(100, 110, 120, 140), ia(-50, -50, 0, 60, 80)),
            ic(ua(110, 140), ia(disallow, 150, 120)),
            ""
        ); //1
        // now test for other conditions

        // depeg already added
        _checkConfig(
            ic(ua(100, 131, 140), ia(200, 150, 100, 50)),
            ic(ua(100, 140), ia(0, 20, 70)),
            ic(ua(100), ia(60, 80)),
            // no bounds
            ic(ua(100), ia(120, 120)),
            ""
        ); //2

        _checkConfig(
            ic(ua(131, 140), ia(disallow, 100, 50)),
            ic(ua(100, 110, 120, 140), ia(-50, -50, 0, 20, 70)),
            // max bands
            ic(ua(100, 110, 120, 140, 150, 160), ia(-50, -50, 0, 60, 80, 90, 100)),
            // min bands
            ic(ua(), ia(disallow)),
            ""
        ); //3

        // mismatched length, too many bands
        config.mintPeggedIncentiveConfig = ic(ua(), ia(disallow, 100));
        vm.expectRevert(
            abi.encodeWithSelector(IMinter.CollateralRatioBoundsIncentivesLengthsMismatch.selector, "mint pegged", 0, 2)
        );
        vm.prank(owner());
        IMinter(minter).updateConfig(config); //4

        // mismatched length, too many bands
        config.mintPeggedIncentiveConfig = ic(ua(100), ia(100));
        vm.expectRevert(
            abi.encodeWithSelector(IMinter.CollateralRatioBoundsIncentivesLengthsMismatch.selector, "mint pegged", 1, 1)
        );
        vm.prank(owner());
        IMinter(minter).updateConfig(config); //5

        // depegged not first
        config.mintPeggedIncentiveConfig = ic(
            ua(90, 100, 131, 140, 150, 160, 170),
            ia(disallow, 100, 50, 100, 200, 300, 400, 500)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.InvalidCollateralRatioBoundValue.selector,
                "mint pegged",
                9 ether / 10,
                0,
                "first boundary must be >= 1"
            )
        );
        vm.prank(owner());
        IMinter(minter).updateConfig(config); //6

        config.mintPeggedIncentiveConfig = ic(
            ua(100, 101, 131, 140, 150, 160, 170),
            ia(disallow, 100, 50, 100, 200, 300, 400, 500)
        );
        vm.prank(owner());
        IMinter(minter).updateConfig(config); //7

        // more than max number
        config.mintPeggedIncentiveConfig = ic(
            ua(100, 102, 131, 140, 150, 160, 170, 180),
            ia(disallow, 100, 50, 100, 200, 300, 400, 500, 600)
        );
        vm.expectRevert(abi.encodeWithSelector(IMinter.TooManyIncentiveRatios.selector, "mint pegged", 9, 8));
        vm.prank(owner());
        IMinter(minter).updateConfig(config); //8

        // more than max with no depeg band, we allow one less unless it's a disallow
        config.mintPeggedIncentiveConfig = ic(
            ua(101, 102, 131, 140, 150, 160, 170),
            ia(disallow, 100, 50, 100, 200, 300, 400, 500)
        );
        vm.prank(owner());
        IMinter(minter).updateConfig(config); //9

        // numerical precision
        config.mintPeggedIncentiveConfig = ic(ua(100, 130), ia(100, 50, 10));
        config.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds[1] = 130 * 10 ** 16 + 1;
        vm.expectRevert(
            abi.encodeWithSelector(IMinter.CollateralRatioBoundTooPrecise.selector, "mint pegged", 130 * 10 ** 16 + 1)
        );
        vm.prank(owner());
        IMinter(minter).updateConfig(config); //10

        config.mintPeggedIncentiveConfig = ic(ua(100, 130), ia(100, 50, 10));
        config.mintPeggedIncentiveConfig.incentiveRatios[1] = 50 * 10 ** 16 + 1;
        vm.expectRevert(
            abi.encodeWithSelector(IMinter.IncentiveRatioTooPrecise.selector, "mint pegged", 50 * 10 ** 16 + 1)
        );
        vm.prank(owner());
        IMinter(minter).updateConfig(config); //11

        // less than min length
        config.mintPeggedIncentiveConfig = ic(ua(), ia());
        vm.expectRevert(abi.encodeWithSelector(IMinter.TooFewIncentiveRatios.selector, "mint pegged", 0, 1));
        vm.prank(owner());
        IMinter(minter).updateConfig(config); //12

        // check the collateral ratio bounds are are checked for strictly increasing
        // all
        config.mintPeggedIncentiveConfig = ic(ua(200, 200), ia(disallow, 2, 3));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.CollateralRatioBoundValueNotIncreasing.selector,
                "mint pegged",
                2 ether,
                1,
                2 ether
            )
        );
        vm.prank(owner());
        IMinter(minter).updateConfig(config); //13
        // middle
        config.mintPeggedIncentiveConfig = ic(ua(100, 200, 200, 300), ia(5, 4, 3, 2, 1));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.CollateralRatioBoundValueNotIncreasing.selector,
                "mint pegged",
                2 ether,
                2,
                2 ether
            )
        );
        vm.prank(owner());
        IMinter(minter).updateConfig(config); //14
        // start
        config.mintPeggedIncentiveConfig = ic(ua(200, 200, 300, 400), ia(disallow, 2, 3, 4, 5));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.CollateralRatioBoundValueNotIncreasing.selector,
                "mint pegged",
                2 ether,
                1,
                2 ether
            )
        );
        vm.prank(owner());
        IMinter(minter).updateConfig(config); // 15
        // end
        config.mintPeggedIncentiveConfig = ic(ua(100, 200, 300, 300), ia(5, 4, 3, 2, 1));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.CollateralRatioBoundValueNotIncreasing.selector,
                "mint pegged",
                3 ether,
                3,
                3 ether
            )
        );
        vm.prank(owner());
        IMinter(minter).updateConfig(config); //16
        // < not <=
        config.mintPeggedIncentiveConfig = ic(ua(300, 200, 300, 300), ia(disallow, 5, 4, 4, 3));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.CollateralRatioBoundValueNotIncreasing.selector,
                "mint pegged",
                2 ether,
                1,
                3 ether
            )
        );
        vm.prank(owner());
        IMinter(minter).updateConfig(config); //17

        // set up the incentive configs for precise testing of values
        config.mintPeggedIncentiveConfig = ic(ua(100), ia(0, 0));
        config.redeemPeggedIncentiveConfig = ic(ua(100), ia(0, 0));
        config.mintLeveragedIncentiveConfig = ic(ua(100), ia(0, 0));
        config.redeemLeveragedIncentiveConfig = ic(ua(100), ia(0, 0));

        // check the incentive ratios are in the range for the action
        // max - mint pegged = 1 ether
        // > max
        config.mintPeggedIncentiveConfig.incentiveRatios[0] = 1 ether + incentivePrecision;
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.InvalidIncentiveRatioValue.selector,
                "mint pegged",
                0,
                1 ether + incentivePrecision,
                "must be in [0, 1]"
            )
        );
        vm.prank(owner());
        IMinter(minter).updateConfig(config); //18
        // = max
        config.mintPeggedIncentiveConfig.incentiveRatios[0] = 1 ether;
        vm.prank(owner());
        IMinter(minter).updateConfig(config); //19

        // max - mint leveraged = 1 ether -1
        // > max
        config.mintLeveragedIncentiveConfig.incentiveRatios[1] = 1 ether;
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.InvalidIncentiveRatioValue.selector,
                "mint leveraged",
                1,
                1 ether,
                "must be in (-1, 1)"
            )
        );
        vm.prank(owner());
        IMinter(minter).updateConfig(config); //20
        // = max
        config.mintLeveragedIncentiveConfig.incentiveRatios[1] = 1 ether - incentivePrecision;
        vm.prank(owner());
        IMinter(minter).updateConfig(config); //21

        // min - mint pegged = 0
        // < min
        config.mintPeggedIncentiveConfig.incentiveRatios[1] = -incentivePrecision;
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.InvalidIncentiveRatioValue.selector,
                "mint pegged",
                1,
                -incentivePrecision,
                "must be in [0, 1]"
            )
        );
        vm.prank(owner());
        IMinter(minter).updateConfig(config); //22
        // = min
        config.mintPeggedIncentiveConfig.incentiveRatios[1] = 0;
        vm.prank(owner());
        IMinter(minter).updateConfig(config); //23

        // min - mint leveraged = - 1 ether
        // < min
        config.mintLeveragedIncentiveConfig.incentiveRatios[1] = -1 ether;
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.InvalidIncentiveRatioValue.selector,
                "mint leveraged",
                1,
                -1 ether,
                "must be in (-1, 1)"
            )
        );
        vm.prank(owner());
        IMinter(minter).updateConfig(config); //24
        // = min
        config.mintLeveragedIncentiveConfig.incentiveRatios[0] = -1 ether + incentivePrecision;
        config.mintLeveragedIncentiveConfig.incentiveRatios[1] = 0;
        vm.prank(owner());
        IMinter(minter).updateConfig(config); //25

        // two disallow bands
        config.mintPeggedIncentiveConfig = ic(ua(120), ia(disallow, disallow));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.InvalidIncentiveRatioValue.selector,
                "mint pegged",
                1,
                1 ether,
                "disallow (1) must be at index 0"
            )
        );
        vm.prank(owner());
        IMinter(minter).updateConfig(config); //26

        // disallow not in first band
        config.mintPeggedIncentiveConfig = ic(ua(100, 120), ia(100, disallow, 200));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.InvalidIncentiveRatioValue.selector,
                "mint pegged",
                1,
                1 ether,
                "disallow (1) must be at index 0"
            )
        );
        vm.prank(owner());
        IMinter(minter).updateConfig(config); //27

        /*
        config.mintPeggedIncentiveConfig.incentiveRatios[0] = -1;
        vm.expectRevert(
            abi.encodeWithSelector(IMinter.InvalidIncentiveRatioValue.selector, )
        );
        vm.prank(owner);
        IMinter(minter).updateConfig(config);
        */
        //                 revert InvalidIncentiveRatioValue(currentUpperBound, prevUpperBound);  one

        //                 revert InvalidIncentiveRatioValue(currentUpperBound, prevUpperBound);  start

        //                 revert InvalidIncentiveRatioValue(currentUpperBound, prevUpperBound);  middle

        //                 revert InvalidIncentiveRatioValue(currentUpperBound, prevUpperBound);  end

        //                 max

        //                 revert InvalidIncentiveRatioValue();  max +1

        //                 min

        //                 revert InvalidIncentiveRatioValue();  min -1
    }

    // function testFuzz_SetNumber(uint256 x) public {
    //     counter.setNumber(x);
    //     assertEq(counter.number(), x);
    //}
}
