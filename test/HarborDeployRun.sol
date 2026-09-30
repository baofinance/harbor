// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";

import {BaoFactoryTestLib} from "@bao-test/BaoFactoryTestLib.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {HarborDeployStack} from "@harbor-script/src/HarborDeployStack.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {MarketAddresses} from "@harbor-test/harness/MarketAddresses.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

/// @notice One Harbor deployment run: who owns it, where its fees go, its salt namespace and its network.
/// @dev An INSTANCE is a run, and a test HOLDS one — `new HarborDeployRun(owner, treasury, "prefix", "mainnet")`,
///      or a subclass that fixes the identity and states what it deploys (`MarketDeployRun`) — and drives it
///      from outside: construct it, then tell it to deploy. Two things follow from the run being an object
///      rather than a base of the test contract:
///
///      **Independent deployments.** A test needing MORE THAN ONE — two pegs, or two minter markets whose salt
///      namespaces must not collide — holds two. Each carries its own `FactoryDeployer` state, so each is a
///      separate run, exactly as they are in production.
///
///      **Compiled once.** The deploy framework is a large body of code. Inherited, it is compiled into every
///      test contract that inherits it and the optimizer processes each copy; held, it is compiled into the
///      run alone, and a test contract carries only its tests and the run's creation code.
///
///      This is deliberately NOT a `BaoTest`: `new` on a `BaoTest` would instantiate a whole test contract per
///      run. The deploy it runs is production logic, and `HarborDeployStack` itself must never inherit test code
///      at all. What this adds for tests is what they need once it has run: the addresses of a market it built,
///      and a settable mock in place of the one dependency it does not deploy, the price oracle.
///
///      The four constructor values are IDENTITY: what this run IS, fixed before it starts and constant
///      throughout. None of them is a per-call choice, so none of them belongs in a deploy signature.
///      Because they are inputs rather than invented here, two runs cannot accidentally share an owner, a fee
///      receiver, or a salt namespace — which is precisely what a multi-run test must avoid.
contract HarborDeployRun is HarborDeployStack {
    // The well-known forge cheatcode address, referenced directly: this is not a test contract.
    Vm private constant _vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    /// @dev Who owns every proxy this run deploys, and who its `onlyOwner` calls must come from once the run
    ///      has handed ownership over. Production returns the Harbor multisig; a test names its own so it can
    ///      prank as it.
    address private immutable _owner;

    /// @dev Where this run's deployments send fees. Distinct from `_owner` by construction — production
    ///      returns the same address for both, which would leave a test measuring one balance for two
    ///      purposes: fees arriving, and the owner's own holdings.
    address private immutable _treasury;

    /// @dev Strings cannot be immutable, so these are set once in the constructor and never written again.
    string private _saltPrefix;
    string private _network;

    constructor(address owner_, address treasury_, string memory saltPrefix_, string memory network_) {
        _owner = owner_;
        _treasury = treasury_;
        _saltPrefix = saltPrefix_;
        _network = network_;
    }

    function owner() public view override returns (address) {
        return _owner;
    }

    function treasury() public view override returns (address) {
        return _treasury;
    }

    /// @dev Overrides `FactoryDeployer`'s accessor, which is `virtual` for exactly this. Answering from
    ///      constructor state means every address prediction resolves before any deploy call has run, so a
    ///      test can take a predicted address the moment it has an instance.
    function saltPrefix() public view override returns (string memory) {
        return _saltPrefix;
    }

    /// @dev The counterpart of `saltPrefix()`, which lives in `FactoryDeployer`. This one has no base to
    ///      override yet because `network` is still a deploy-call parameter there.
    function network() public view returns (string memory) {
        return _network;
    }

    /// @notice Run this deployment: the peg's pegged token if asked for, then each market named.
    /// @dev The public face of `deployHarborForPeg`, which is `internal`. A run is driven from OUTSIDE —
    ///      construct it, then tell it to deploy — and an internal function cannot be reached that way, so
    ///      without this an instance could be built but never used.
    ///
    ///      Identity is not a parameter here: the salt prefix and network came from the constructor, so the
    ///      only inputs are what this particular run deploys.
    function deploy(
        ConfigPeg peg,
        Config_MinterMarket[] memory allMarkets,
        bool deployPeg,
        Config_MinterMarket[] memory marketsToDeploy
    ) public {
        deployHarborForPeg(saltPrefix(), peg, allMarkets, network(), deployPeg, marketsToDeploy);
    }

    /// @notice Deploy the singleton BaoFactory if needed and register THIS run as a factory operator.
    /// @dev Idempotent, and called by the run itself, which is what will call `factory.deploy`:
    ///      `BaoFactoryTestLib.ensureBaoFactory` is `internal`, so it inlines and `address(this)` is this run.
    ///
    ///      Call it AFTER selecting a fork: a fork switch resets the operator registration.
    function ensureFactory() public returns (address factory) {
        return BaoFactoryTestLib.ensureBaoFactory();
    }

    /// @notice The market's minter holds no code: this run has not deployed it.
    error MinterNotDeployed(address minter);

    /// @notice The market's minter reads its price from an address other than the one this run predicts for its
    ///         oracle.
    error MinterReadsAnotherOracle(address minter, address wired, address predicted);

    /// @notice The addresses of `config`'s market as this run deployed it.
    /// @dev The minter, the two pools, the manager and the oracle are found by this run's own resolvers - where the
    ///      deploy put them, and where it wired the minter to find its price. The three tokens are read from the
    ///      deployed minter, since those are the ones the market uses. Refuses a market this run has not deployed.
    function marketAddresses(Config_MinterMarket config) public returns (MarketAddresses memory addresses) {
        addresses.minter = _deployedMinter(config);
        addresses.collateralPool = stabilityPoolAddress(config, StabilityPoolType.Collateral);
        addresses.leveragedPool = stabilityPoolAddress(config, StabilityPoolType.Leveraged);
        addresses.manager = stabilityPoolManagerAddress(config);
        addresses.pegged = IMinter(addresses.minter).PEGGED_TOKEN();
        addresses.leveraged = IMinter(addresses.minter).LEVERAGED_TOKEN();
        addresses.wrappedCollateral = IMinter(addresses.minter).WRAPPED_COLLATERAL_TOKEN();
        addresses.oracle = wrappedPriceOracleAddress(config);
    }

    /// @notice Put a settable mock price oracle where this run wired `config`'s minter to read its price, and return
    ///         its address.
    /// @dev The price oracle is the one dependency a run does not deploy - production deploys it separately - and the
    ///      deploy wires the minter to its predicted address while that address is still codeless. So this is called
    ///      AFTER the deploy, and checks it: the minter must be deployed, and must read exactly the predicted address,
    ///      or a mock put there would never be read.
    ///
    ///      `vm.etch` copies code, not storage, so the mock would arrive answering zeros and an empty quote name, its
    ///      constructor never having run. Its state is restored from a mock constructed here, so the two cannot drift.
    function installMockPriceOracle(Config_MinterMarket config) public returns (address oracle) {
        address minter = _deployedMinter(config);
        oracle = wrappedPriceOracleAddress(config);
        address wired = IMinter(minter).priceOracle();
        if (wired != oracle) {
            revert MinterReadsAnotherOracle(minter, wired, oracle);
        }

        MockWrappedPriceOracle template = new MockWrappedPriceOracle();
        _vm.etch(oracle, address(template).code);
        (uint256 minPrice, uint256 maxPrice, uint256 minRate, uint256 maxRate) = template.latestAnswer();
        MockWrappedPriceOracle(oracle).setLatestAnswer(minPrice, maxPrice, minRate, maxRate);
        MockWrappedPriceOracle(oracle).setQuoteName(template.quoteName());
    }

    /// @dev `config`'s minter, refused if this run has not deployed it.
    function _deployedMinter(Config_MinterMarket config) private returns (address minter) {
        minter = minterAddress(config);
        if (minter.code.length == 0) {
            revert MinterNotDeployed(minter);
        }
    }
}
