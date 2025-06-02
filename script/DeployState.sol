// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";

abstract contract DeployState is Test {
    using stdJson for string;
    string filename;

    function setStateFile(string memory network, string memory chain, string memory script) internal {
        filename = string.concat("./deploy/", network, "-", chain, "-", script, "_latest.log");
    }

    function addr(string memory name) internal view returns (address addr_) {
        addr_ = vm.parseJsonAddress(vm.readFile(filename), string.concat(".", name, ".address")); // jq style path
        vm.assertNotEq(addr_, address(0), string.concat("zero address for ", name));
        console2.log("addr(%s)->%s", name, addr_);
    }
}
