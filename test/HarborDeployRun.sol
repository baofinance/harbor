// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoFactoryTestLib} from "@bao-test/BaoFactoryTestLib.sol";
import {HarborDeployStack} from "@harbor-script/src/HarborDeployStack.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";

/// @notice One Harbor deployment run: who owns it, where its fees go, its salt namespace and its network.
/// @dev An INSTANCE is a run. That is the whole idea, and it is what makes both use sites work without a
///      special case:
///
///      **Composition** — `new HarborDeployRun(owner, treasury, "prefix", "mainnet")` — for a test needing
///      MORE THAN ONE independent deployment: two pegs, or two minter markets whose salt namespaces must not
///      collide. Each instance carries its own `FactoryDeployer` state, so each is a separate run, exactly as
///      they are in production.
///
///      **Inheritance** — `contract SomeSetUp is BaoTest, HarborDeployRun` — for a test needing one.
///
///      This is deliberately NOT a `BaoTest`, and nothing here is test-specific. Composition is why: `new` on
///      a `BaoTest` would instantiate a whole test contract per run, and it would constrain linearisation for
///      setups that already inherit other test bases. `HarborDeployStack` itself must never inherit test code
///      at all — it is production deploy logic.
///
///      The four constructor values are IDENTITY: what this run IS, fixed before it starts and constant
///      throughout. None of them is a per-call choice, so none of them belongs in a deploy signature.
///      Because they are inputs rather than invented here, two composed runs cannot accidentally share an
///      owner, a fee receiver, or a salt namespace — which is precisely what a multi-run test must avoid.
contract HarborDeployRun is HarborDeployStack {
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
    /// @dev The public face of `deployHarborForPeg`, which is `internal`. A COMPOSED run is driven from
    ///      OUTSIDE — construct it, then tell it to deploy — and an internal function cannot be reached that
    ///      way, so without this a composed instance could be built but never used. Under inheritance the
    ///      internal function is reachable directly and this is simply the same call by another name.
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

    /// @notice Deploy the singleton BaoFactory if needed and register THIS contract as a factory operator.
    /// @dev Idempotent, and must be called by whoever will run the deploy: `BaoFactoryTestLib.ensureBaoFactory`
    ///      is `internal`, so it inlines and `address(this)` is this run under composition, or the test itself
    ///      under inheritance. Each registers itself, which is why a composed run can call `factory.deploy` on
    ///      its own account.
    ///
    ///      Call it AFTER selecting a fork: a fork switch resets the operator registration.
    function ensureFactory() public returns (address factory) {
        return BaoFactoryTestLib.ensureBaoFactory();
    }
}
