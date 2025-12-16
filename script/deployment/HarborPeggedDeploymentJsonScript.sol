// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

import {DeploymentBase} from "@bao-script/deployment/DeploymentBase.sol";
import {DeploymentDataMemory} from "@bao-script/deployment/DeploymentDataMemory.sol";
import {DeploymentJson} from "@bao-script/deployment/DeploymentJson.sol";
import {HarborDeploymentJsonScript} from "./HarborDeploymentJsonScript.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";
import {ReservePool_v1} from "@harbor/minter/ReservePool_v1.sol";
import {TokenDistributor_v1} from "@harbor/minter/TokenDistributor_v1.sol";
import {MockWrappedPriceOracle} from "test/mocks/MockWrappedPriceOracle.sol";
import {Minter_v1} from "@harbor/minter/Minter_v1.sol";
import {StabilityPool_v1} from "@harbor/minter/StabilityPool_v1.sol";
import {StabilityPoolManager_v1} from "@harbor/minter/StabilityPoolManager_v1.sol";
import {Genesis_v1} from "@harbor/minter/Genesis_v1.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";

contract HarborPeggedDeploymentJsonScript is HarborDeploymentJsonScript {
    using LibString for string;
    using LibString for address;

    string public constant PEGGED_NAME = "contracts.pegged.name";
    string public constant PEGGED_SYMBOL = "contracts.pegged.symbol";

    constructor() {
        addProxy(PEGGED);
        addRoles(PEGGED, sa("MINTER_ROLE", "BURNER_ROLE"));
        addStringKey(PEGGED_NAME);
        addStringKey(PEGGED_SYMBOL);

        addProxy(MINTER);
    }

    function start(
        string memory network,
        string memory systemSaltString,
        string memory startPoint
    ) public virtual override {
        super.start(network, systemSaltString, startPoint);
    }

    // ============================================================================
    // Pegged
    // ============================================================================

    function _deployPegged(string[] memory collaterals) public {
        // address proxyAddress = predictAddress(PEGGED, PEGGED_SALT_STRING);
        // // TODO: move this into DeploymentBase
        // if (proxyAddress.code.length != 0) {
        //     require(
        //         keccak256(proxyAddress.code) == keccak256(type(ERC1967Proxy).runtimeCode),
        //         "not a ERC1967 proxy at PEGGED address"
        //     );
        //     console2.log("Pegged address already has a proxy deployed; skipping deployment.");
        //     console2.log("MINTER_ROLE and BURNER_ROLE needs to be set via multisig.");
        //     _setMintableBurnableERC20Info(PEGGED, proxyAddress);
        //     console2.log(
        //         string.concat(
        //             proxyAddress.toHexStringChecksummed(),
        //             ".grantRoles(",
        //             predictAddress(MINTER, SYSTEM_SALT_STRING).toHexStringChecksummed(),
        //             ",",
        //             LibString.toString(_getRoleValue(PEGGED, "MINTER_ROLE") | _getRoleValue(PEGGED, "BURNER_ROLE")),
        //             ")"
        //         )
        //     );
        // } else {
        console2.log("Deploying Pegged...");

        // Derive symbol and name from deployment config
        string memory ticker = _getString(PEGGED_TICKER);
        _setString(PEGGED_SYMBOL, string.concat("ha", ticker.upper()));
        _setString(PEGGED_NAME, string.concat("Harbor anchored ", ticker));

        console2.log("pegged symbol: '%s'", _getString(PEGGED_SYMBOL));
        console2.log("pegged name: '%s'", _getString(PEGGED_NAME));

        // Deploy implementation
        MintableBurnableERC20_v1 impl = new MintableBurnableERC20_v1();

        // Deploy and register proxy
        bytes memory initData = abi.encodeCall(
            MintableBurnableERC20_v1.initialize,
            (_getAddress(OWNER), _getString(PEGGED_NAME), _getString(PEGGED_SYMBOL))
        );

        deployProxy(
            PEGGED,
            PEGGED_SALT_STRING,
            address(impl),
            initData,
            type(MintableBurnableERC20_v1).name,
            type(MintableBurnableERC20_v1).creationCode,
            _getAddress(SESSION_DEPLOYER)
        );
        // declare the roles
        MintableBurnableERC20_v1 proxy = MintableBurnableERC20_v1(_get(PEGGED));
        _setRole(PEGGED, "MINTER_ROLE", proxy.MINTER_ROLE());
        _setRole(PEGGED, "BURNER_ROLE", proxy.BURNER_ROLE());

        // set the roles on the minter
        for (uint c = 0; c < collaterals.length; ++c) {
            address minter = predictAddress(MINTER, PEGGED_SALT_STRING, collaterals[c]);
            console2.log("minter = %s", minter);
            proxy.grantRoles(minter, _getRoleValue(PEGGED, "MINTER_ROLE") | _getRoleValue(PEGGED, "BURNER_ROLE"));
            // TODO: fix this
            // _setGrantee(minter.toHexStringChecksummed(), PEGGED, "MINTER_ROLE");
            // _setGrantee(minter.toHexStringChecksummed(), PEGGED, "BURNER_ROLE");
        }
        // }
        _save();
    }

    function _smokePegged() public view {
        console2.log("Smoke testing Pegged...");
        MintableBurnableERC20_v1 proxy = MintableBurnableERC20_v1(_get(PEGGED));
        _expect(proxy.owner(), OWNER);
        _expect(proxy.symbol(), PEGGED_SYMBOL);
        _expect(proxy.name(), PEGGED_NAME);

        _expectRoleValue(proxy.MINTER_ROLE(), PEGGED, "MINTER_ROLE");
        _expectRoleValue(proxy.BURNER_ROLE(), PEGGED, "BURNER_ROLE");
    }
}
