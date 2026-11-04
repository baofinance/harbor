// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {LibString} from "@solady/utils/LibString.sol";

/// @notice A pauser implementation bao-base has deployed: its contract type - `BaoPauser_v1`, `HarborPauser_v1` - and its
///         address. A proxy upgraded to a pauser is paused: every call to it reverts `Paused` until it is upgraded again.
struct Pauser {
    string contractType;
    address implementation;
}

/// @notice bao-base's deployment state for `network` records no pauser of this contract type.
error PauserNotDeployed(string network, string contractType);

/// @notice The pausers bao-base has deployed on `network`: every implementation its deployment state,
///         `lib/bao-base/deployments/<network>/state.json`, records under a contract type naming a pauser and its version,
///         `<name>Pauser_v<n>`. The state is written by bao-base's deploys, so a pauser is listed here from the deploy that
///         made it, and nothing here names an address.
/// @dev Read from the file directly: `JsonParser.parseStateJson` requires the salt prefix and the proxy of each
///      implementation, which a deploy of implementations alone never writes.
function pausers(string memory network) view returns (Pauser[] memory list) {
    Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    string memory json = vm.readFile(string.concat("lib/bao-base/deployments/", network, "/state.json"));
    string[] memory implementations = vm.parseJsonKeys(json, ".implementations");
    Pauser[] memory found = new Pauser[](implementations.length);
    uint256 count;
    for (uint256 i = 0; i < implementations.length; ++i) {
        string memory contractType = stdJson.readString(
            json,
            string.concat(".implementations['", implementations[i], "'].contractType")
        );
        if (LibString.indexOf(contractType, "Pauser_v") != LibString.NOT_FOUND) {
            found[count++] = Pauser(contractType, vm.parseAddress(implementations[i]));
        }
    }
    list = new Pauser[](count);
    for (uint256 i = 0; i < count; ++i) {
        list[i] = found[i];
    }
}

/// @notice The pauser of contract type `contractType` deployed on `network`, by address.
function pauserNamed(string memory network, string memory contractType) view returns (address) {
    Pauser[] memory list = pausers(network);
    for (uint256 i = 0; i < list.length; ++i) {
        if (LibString.eq(list[i].contractType, contractType)) {
            return list[i].implementation;
        }
    }
    revert PauserNotDeployed(network, contractType);
}
