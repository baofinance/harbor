// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoFactoryTestLib} from "@bao-test/BaoFactoryTestLib.sol";
import {HarborDeployStack} from "@harbor-script/src/HarborDeployStack.sol";

/// @notice The Harbor deploy stack, ready for a test to drive — by inheriting it OR by holding one.
/// @dev Both are first-class, and the difference matters:
///
///      **Inheritance** — `contract SomeSetUp is BaoTest, HarborDeployStackForTests` — for a test that needs
///      one deployment. The setup calls the deploy layers directly.
///
///      **Composition** — `new HarborDeployStackForTests(owner, treasury)` — for a test that needs MORE THAN
///      ONE independent deployment: two pegs, or two minter markets whose salt namespaces must not collide.
///      Each instance carries its own `FactoryDeployer` state, so each is a separate deploy run, as they are
///      in production.
///
///      This is deliberately NOT a `BaoTest`. Composition is why: `new` on a `BaoTest` would instantiate a
///      whole test contract per deployment, and it would constrain linearisation for setups that already
///      inherit other test bases (`TokenHolderTestBase`, `UUPSOwnableTestBase`, and so on). `HarborDeployStack`
///      itself must never inherit test code at all — it is production deploy logic.
///
///      Because it is not a `BaoTest` there is no `makeAddr` here, and that is the point: the actors are
///      INPUTS, fixed at construction. A harness that invented its own would hand two composed instances the
///      same owner and fee receiver, which is precisely what a multi-deployment test must not have.
contract HarborDeployStackForTests is HarborDeployStack {
    /// @dev The deploy's owner: who owns every proxy this instance deploys, and who its `onlyOwner` calls must
    ///      come from. Production returns the Harbor multisig; a test names its own so it can prank as it.
    address private immutable _owner;

    /// @dev Where this instance's deployments send fees. Distinct from `_owner` by construction — production
    ///      returns the same address for both, which would leave a test measuring one balance for two
    ///      purposes: fees arriving, and the owner's own holdings.
    address private immutable _treasury;

    constructor(address owner_, address treasury_) {
        _owner = owner_;
        _treasury = treasury_;
    }

    function owner() public view override returns (address) {
        return _owner;
    }

    function treasury() public view override returns (address) {
        return _treasury;
    }

    /// @notice Deploy the singleton BaoFactory if needed and register THIS contract as a factory operator.
    /// @dev Idempotent, and must be called by whoever will run the deploy: `BaoFactoryTestLib.ensureBaoFactory`
    ///      is `internal`, so it inlines and `address(this)` is this harness under composition, or the test
    ///      itself under inheritance. Each registers itself, which is why a composed harness can call
    ///      `factory.deploy` on its own account.
    ///
    ///      Call it AFTER selecting a fork: a fork switch resets the operator registration.
    function ensureFactory() public returns (address factory) {
        return BaoFactoryTestLib.ensureBaoFactory();
    }
}
