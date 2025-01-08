// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {stdJson} from "forge-std/StdJson.sol";
// import { console2 } from "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";

abstract contract DeployState is Test {
    using stdJson for string;
    string filename;

    function setStateFile(string memory network) internal {
        filename = string.concat("./log/deploy-", network, ".log");
    }

    function step() internal view returns (uint step_) {
        step_ = vm.parseJsonUint(vm.readFile(filename), ".step"); // jq style path
    }

    function setStep(uint step_) internal {
        if (step_ == 1) {
            vm.writeJson('{ "step": 1, "addresses": { } }', filename);
        } else {
            // this logic to copy the existing addresses is a workaround for a bug in foundry
            string memory file = vm.readFile(filename);
            string[] memory contracts = vm.parseJsonKeys(file, ".addresses");
            address[] memory addresses = new address[](contracts.length);
            for (uint i = 0; i < contracts.length; i++) {
                addresses[i] = addr(contracts[i]);
            }
            vm.writeJson(Strings.toString(step_), filename, ".step");
            for (uint i = 0; i < contracts.length; i++) {
                setAddr(contracts[i], addresses[i]);
            }
        }
    }

    function addr(string memory name) internal view returns (address addr_) {
        addr_ = vm.parseJsonAddress(vm.readFile(filename), string.concat(".addresses.", name)); // jq style path
        vm.assertNotEq(addr_, address(0), string.concat("zero address for ", name));
        // console2.log("addr(%s)->%s", name, addr_);
    }

    function setAddr(string memory name, address addr_) internal {
        // console2.log("setAddr(%s, %s)", name, addr_);
        vm.assertNotEq(addr_, address(0), string.concat("zero address for ", name));
        /*
                string memory addresses = vm.serializeAddress("", name, addr_);

        string memory file = vm.readFile(filename);
        string[] memory contracts = vm.parseJsonKeys(file, ".addresses");
        for (uint i = 0; i < contracts.length; i++) {
            addresses = vm.serializeAddress(addresses, contracts[i], addr(contracts[i]));
        }

        vm.writeJson(addresses, filename, ".addresses");
        */
        vm.writeJson(vm.serializeAddress("", name, addr_), filename, ".addresses");
    }
}
