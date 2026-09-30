// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";

import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

/// @notice Installing a mock at the address a separate deployment is predicted at - for the deployment suites that
/// stand their markets up through a deploy run of their own. What a test does to a market once it stands is
/// `MarketActions`, an object the test holds.
abstract contract HarborTestActions {
    // the well-known forge/hevm cheatcode address: address(uint160(uint256(keccak256("hevm cheat code")))). Referenced
    // directly (not inherited from a Test base) so this stays a pure mixin.
    Vm private constant _vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    /// @notice Put `implementation`'s runtime code at `target`, so calls to `target` run it.
    /// @dev The way to stand a mock in for a dependency this repo does not deploy but references by its predicted
    /// CREATE3 address. Install at the address the deploy's own resolver returns, so a key change moves the deploy
    /// and the mock together. Copies CODE, not storage: the implementation's constructor and field initialisers do
    /// NOT apply, so configure the installed mock through its setters afterwards.
    function installContractAt(address target, address implementation) internal {
        _vm.etch(target, implementation.code);
    }

    /// @notice Install a settable mock price oracle at `oracleAddress`, and return it for configuring.
    /// @param oracleAddress The market's oracle address, from the deploy's own `wrappedPriceOracleAddress` resolver.
    /// @dev Call AFTER the deploy. The price oracle is a separate deployment (harbor-price-aggregators), and the
    /// deploy wires the minter to its predicted address while that address is still codeless — exactly as production
    /// does. Installing beforehand would hide that path; installing after still beats the first read, because the
    /// deploy only ever stores the address, never calls it.
    function installMockPriceOracle(address oracleAddress) internal returns (address) {
        installContractAt(oracleAddress, address(new MockWrappedPriceOracle()));
        return oracleAddress;
    }
}
