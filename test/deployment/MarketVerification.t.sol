// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {BaoTest} from "@bao-test/BaoTest.sol";
import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {Token} from "@bao/Token.sol";
import {Minter_v3} from "@harbor/minter/Minter_v3.sol";
import {StabilityPoolManager_v2} from "@harbor/minter/StabilityPoolManager_v2.sol";
import {StabilityPool_v3} from "@harbor/minter/StabilityPool_v3.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {ConfigMarket_BTC_stETH_mainnet} from "@harbor-script/config/markets/ConfigMarket_BTC_stETH_mainnet.sol";
import {ethMintersConfig} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {MarketAddresses} from "@harbor-script/src/MarketAddresses.sol";
import {MarketVerification} from "@harbor-script/src/MarketVerification.sol";

import {HarborDeployRun} from "@harbor-test/HarborDeployRun.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

/// @dev The deploy's market check, held so a test can call it.
contract MarketVerificationRun is MarketVerification {
    constructor() {
        _setSaltPrefix("verification");
    }

    function verify(
        Config_MinterMarket config,
        MarketAddresses memory addresses,
        address minter,
        address collateralPool,
        address leveragedPool,
        address manager
    ) external view {
        verifyMarket(config, addresses, minter, collateralPool, leveragedPool, manager);
    }
}

/// @dev A run whose stability pools are built, by the deploy's own function, naming the leveraged token as their asset.
contract PoolOfLeveragedDeployRun is HarborDeployRun {
    constructor(
        address owner_,
        address treasury_,
        string memory saltPrefix_,
        string memory network_
    ) HarborDeployRun(owner_, treasury_, saltPrefix_, network_, HarborDeployRun.Cut.Whole) {}

    function deployStabilityPoolImplementation(
        DeploymentTypes.State memory stateData,
        string memory key,
        StabilityPoolType poolType,
        Config_MinterMarket marketConfig,
        MarketAddresses memory addresses
    ) internal override returns (address impl) {
        MarketAddresses memory misnamed = abi.decode(abi.encode(addresses), (MarketAddresses));
        misnamed.pegged = addresses.leveraged;
        impl = super.deployStabilityPoolImplementation(stateData, key, poolType, marketConfig, misnamed);
    }
}

/// @notice The deploy's check that a market's minter, pools and manager name its tokens and each other as its
///         addresses do, and that its tokens answer as ERC-20s - standing in for the checks their constructors no
///         longer make, and checking what those could not: that each token is the market's.
contract MarketVerificationTest is Test {
    /// @dev The index of each field of `MarketAddresses` that a contract names, for `_with` and `_field`.
    uint8 private constant _MINTER = 0;
    uint8 private constant _COLLATERAL_POOL = 1;
    uint8 private constant _LEVERAGED_POOL = 2;
    uint8 private constant _PEGGED = 4;
    uint8 private constant _LEVERAGED = 5;
    uint8 private constant _WRAPPED_COLLATERAL = 6;

    MarketVerificationRun private run;
    Config_MinterMarket private config;
    MarketAddresses private market;

    function setUp() public {
        run = new MarketVerificationRun();
        config = new ConfigMarket_BTC_stETH_mainnet();
        market = MarketAddresses({
            minter: makeAddr("minter"),
            collateralPool: makeAddr("collateralPool"),
            leveragedPool: makeAddr("leveragedPool"),
            manager: makeAddr("manager"),
            pegged: address(new MockERC20("pegged", "P", 18)),
            leveraged: address(new MockERC20("leveraged", "L", 18)),
            wrappedCollateral: address(new MockERC20("wrapped collateral", "W", 18)),
            oracle: makeAddr("oracle")
        });
    }

    /// A market whose minter, pools and manager are each built from its addresses, with tokens that answer as ERC-20s,
    /// passes.
    function test_verifyMarket_acceptsAMarketBuiltFromItsAddresses() public {
        MarketAddresses memory addresses = market;
        address minter = _minter(addresses);
        address collateralPool = _pool(addresses);
        address leveragedPool = _pool(addresses);
        address manager = _manager(addresses);

        run.verify(config, addresses, minter, collateralPool, leveragedPool, manager);
    }

    /// Every address a contract of the market names is checked: a minter, pool or manager built with any one of them
    /// other than the market's is refused, naming the contract and the address, the market's and the one it names.
    function test_verifyMarket_refusesEachAddressNamedWrongly() public {
        address wrong = address(new MockERC20("wrong", "X", 18));
        string[4] memory names = [
            run.minterKey(config),
            run.stabilityPoolKey(config, HarborDeployer.StabilityPoolType.Collateral),
            run.stabilityPoolKey(config, HarborDeployer.StabilityPoolType.Leveraged),
            run.stabilityPoolManagerKey(config)
        ];
        // which contract is built with the wrong address (0 minter, 1 collateral pool, 2 leveraged pool, 3 manager),
        // which of its addresses, and how the refusal names it
        uint8[13] memory builtWrong = [uint8(0), 0, 0, 1, 1, 2, 2, 3, 3, 3, 3, 3, 3];
        uint8[13] memory field = [
            _WRAPPED_COLLATERAL,
            _PEGGED,
            _LEVERAGED,
            _MINTER,
            _PEGGED,
            _MINTER,
            _PEGGED,
            _MINTER,
            _WRAPPED_COLLATERAL,
            _PEGGED,
            _LEVERAGED,
            _COLLATERAL_POOL,
            _LEVERAGED_POOL
        ];
        string[13] memory named = [
            " wrapped collateral",
            " pegged token",
            " leveraged token",
            " minter",
            " asset",
            " minter",
            " asset",
            " minter",
            " wrapped collateral",
            " pegged token",
            " leveraged token",
            " collateral pool",
            " leveraged pool"
        ];

        MarketAddresses memory addresses = market;
        for (uint256 c = 0; c < builtWrong.length; ++c) {
            bytes memory refusal = abi.encodeWithSelector(
                MarketVerification.MarketAddressMismatch.selector,
                string.concat(names[builtWrong[c]], named[c]),
                _field(addresses, field[c]),
                wrong
            );
            MarketAddresses memory wrongOne = _with(addresses, field[c], wrong);
            _expectRefusal(
                addresses,
                builtWrong[c] == 0 ? wrongOne : addresses,
                builtWrong[c] == 1 ? wrongOne : addresses,
                builtWrong[c] == 2 ? wrongOne : addresses,
                builtWrong[c] == 3 ? wrongOne : addresses,
                refusal
            );
        }
    }

    /// Each of the market's three tokens is checked to answer as an ERC-20, even where every contract names it as the
    /// market's: an address with no code is refused as no contract, and a contract without the ERC-20 functions as no
    /// ERC-20, each naming the address.
    function test_verifyMarket_refusesATokenThatIsNotAnERC20() public {
        address noCode = makeAddr("noCode");
        address notAnERC20 = address(new MockWrappedPriceOracle());
        uint8[3] memory tokens = [_WRAPPED_COLLATERAL, _PEGGED, _LEVERAGED];

        MarketAddresses memory addresses = market;
        for (uint256 t = 0; t < tokens.length; ++t) {
            MarketAddresses memory withNoCode = _with(addresses, tokens[t], noCode);
            _expectRefusal(
                withNoCode,
                withNoCode,
                withNoCode,
                withNoCode,
                withNoCode,
                abi.encodeWithSelector(Token.NotContractAddress.selector, noCode)
            );
            MarketAddresses memory withNotAnERC20 = _with(addresses, tokens[t], notAnERC20);
            _expectRefusal(
                withNotAnERC20,
                withNotAnERC20,
                withNotAnERC20,
                withNotAnERC20,
                withNotAnERC20,
                abi.encodeWithSelector(Token.NotERC20Token.selector, notAnERC20)
            );
        }
    }

    /// @dev Build the minter, the two pools and the manager, each from its own addresses, and expect checking them
    ///      against `addresses` to revert with `refusal`.
    function _expectRefusal(
        MarketAddresses memory addresses,
        MarketAddresses memory forMinter,
        MarketAddresses memory forCollateralPool,
        MarketAddresses memory forLeveragedPool,
        MarketAddresses memory forManager,
        bytes memory refusal
    ) private {
        address minter = _minter(forMinter);
        address collateralPool = _pool(forCollateralPool);
        address leveragedPool = _pool(forLeveragedPool);
        address manager = _manager(forManager);
        vm.expectRevert(refusal);
        run.verify(config, addresses, minter, collateralPool, leveragedPool, manager);
    }

    function _minter(MarketAddresses memory addresses) private returns (address) {
        return address(new Minter_v3(addresses.wrappedCollateral, addresses.pegged, addresses.leveraged));
    }

    function _pool(MarketAddresses memory addresses) private returns (address) {
        return address(new StabilityPool_v3(addresses.minter, addresses.pegged, 3600, 90000, 1 ether, "Pool", "P"));
    }

    function _manager(MarketAddresses memory addresses) private returns (address) {
        return
            address(
                new StabilityPoolManager_v2(
                    addresses.minter,
                    addresses.wrappedCollateral,
                    addresses.pegged,
                    addresses.leveraged,
                    addresses.collateralPool,
                    addresses.leveragedPool
                )
            );
    }

    /// @dev A copy of `addresses` with the field at index `field` set to `value`.
    function _with(
        MarketAddresses memory addresses,
        uint8 field,
        address value
    ) private pure returns (MarketAddresses memory copy) {
        copy = abi.decode(abi.encode(addresses), (MarketAddresses));
        if (field == _MINTER) {
            copy.minter = value;
        } else if (field == _COLLATERAL_POOL) {
            copy.collateralPool = value;
        } else if (field == _LEVERAGED_POOL) {
            copy.leveragedPool = value;
        } else if (field == _PEGGED) {
            copy.pegged = value;
        } else if (field == _LEVERAGED) {
            copy.leveraged = value;
        } else if (field == _WRAPPED_COLLATERAL) {
            copy.wrappedCollateral = value;
        } else {
            revert("_with: no such field");
        }
    }

    /// @dev The field of `addresses` at index `field`.
    function _field(MarketAddresses memory addresses, uint8 field) private pure returns (address) {
        if (field == _MINTER) {
            return addresses.minter;
        }
        if (field == _COLLATERAL_POOL) {
            return addresses.collateralPool;
        }
        if (field == _LEVERAGED_POOL) {
            return addresses.leveragedPool;
        }
        if (field == _PEGGED) {
            return addresses.pegged;
        }
        if (field == _LEVERAGED) {
            return addresses.leveraged;
        }
        if (field == _WRAPPED_COLLATERAL) {
            return addresses.wrappedCollateral;
        }
        revert("_field: no such field");
    }
}

/// @notice A fresh deploy runs the market check once the market's contracts exist: a market whose pools were built
///         naming another token as their asset is refused, naming the pool, the market's pegged token and the token
///         the pool names.
/// @dev Forked, because the run deploys through the mainnet BaoFactory.
contract MarketVerificationDeployTest is BaoTest {
    function test_aDeployWhosePoolNamesAnotherTokenIsRefused() public {
        forkMainnetWithBaoFactory();
        PoolOfLeveragedDeployRun deployRun = new PoolOfLeveragedDeployRun(
            makeAddr("verificationRunOwner"),
            makeAddr("verificationRunTreasury"),
            "verification",
            "mainnet"
        );
        deployRun.ensureFactory();
        (ConfigPeg peg, Config_MinterMarket[] memory configs) = ethMintersConfig();
        Config_MinterMarket[] memory toDeploy = new Config_MinterMarket[](1);
        toDeploy[0] = configs[0];
        string memory pool = deployRun.stabilityPoolKey(toDeploy[0], HarborDeployer.StabilityPoolType.Collateral);
        address pegged = deployRun.peggedTokenAddress(toDeploy[0]);
        address leveraged = deployRun.leveragedTokenAddress(toDeploy[0]);

        vm.expectRevert(
            abi.encodeWithSelector(
                MarketVerification.MarketAddressMismatch.selector,
                string.concat(pool, " asset"),
                pegged,
                leveraged
            )
        );
        deployRun.deploy(peg, configs, true, toDeploy);
    }
}
