// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";

import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";

/// @title StateFileAddressConsistency
/// @notice Every address recorded in the mainnet deployment state file is the address its salt actually derives to.
///
///         Two independent sources name the same contracts and nothing else compares them:
///           - the STATE FILE (`deployments/mainnet/harbor_v1.state.json`), which humans read and migration batches are
///             written against;
///           - the SALT DERIVATION, `BaoFactory.predictAddress(keccak256(saltString))`, which is what the deploy
///             scripts - and every script that resolves a dependency by predicted address - actually use.
///         They are generated from the same salts, so they agree while nothing has gone wrong; a hand-edited entry, a
///         renamed key, a contract deployed under a different prefix, or a stale record shows up as a mismatch here and
///         nowhere else. A migration batch built off a drifted state file would target the wrong address.
///
///         Checks BOTH directions of the record: that the stored `salt` is the one the key implies, and that the stored
///         `address` is what that salt derives to. Covers every proxy entry, not just the stability pools.
///
///         Read-only. Needs MAINNET_RPC_URL (the derivation is an on-chain call to the factory).
contract StateFileAddressConsistency is Test, HarborDeployer {
    string internal constant STATE_FILE = "deployments/mainnet/harbor_v1.state.json";
    /// @dev Any block at which the factory exists serves; pinned to the migration pre-flight's block so both are served
    ///      from the same fork cache.
    uint256 internal constant FORK_BLOCK = 25272609;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK);
        _setSaltPrefix("harbor_v1");
    }

    function test_everyRecordedProxyAddressMatchesItsSaltDerivation() public {
        string memory state = vm.readFile(STATE_FILE);

        // The prefix is recorded too - if it disagreed with the one set above, every derivation below would be wrong in
        // the same way, so check it before trusting any of them.
        assertEq(
            vm.parseJsonString(state, ".saltPrefix"),
            "harbor_v1",
            "state file salt prefix is not the one this check derives with"
        );

        string[] memory keys = vm.parseJsonKeys(state, ".proxies");
        for (uint256 i = 0; i < keys.length; i++) {
            // The record's own salt must be the one its key implies: `<prefix>::<key>`.
            assertEq(
                vm.parseJsonString(state, string.concat(".proxies['", keys[i], "'].salt")),
                _saltString(keys[i]),
                string.concat("recorded salt is not the salt its key implies: ", keys[i])
            );
            // ...and the recorded address must be what that salt derives to through the factory.
            assertEq(
                vm.parseJsonAddress(state, string.concat(".proxies['", keys[i], "'].address")),
                _predictAddress(keys[i]),
                string.concat("recorded address is not the CREATE3 address its salt derives to: ", keys[i])
            );
        }

        console.log("state file: %d proxy records agree with their salt derivation", keys.length);
        // A parse that silently yielded no keys would make every assertion above vacuous.
        assertGt(keys.length, 0, "no proxy records read from the state file - parse or path wrong");
    }
}
