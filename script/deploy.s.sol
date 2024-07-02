// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import "forge-std/Script.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import { UnsafeUpgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol"; // only used for implementation address change
import { Options } from "openzeppelin-foundry-upgrades/Options.sol";

import "src/minter/LeveragedToken_v1.sol";
import "src/minter/ReservePool_v1.sol";
import "src/minter/TokenDistributor_v1.sol";
import "src/minter/Minter_v1.sol";

// functions are called in this sequence
// 1) Deploy*
//      - deploys the proxy and the first implementation
//      - you should save the file being deployed into the src/deployed directory.
//          - If it's a test deployment (e.g. on Sepolia) then the filename should have a letter appended, e.g. X_v1.sol -> X_v1a.sol
//          - this indicates that it is an alpha version in preparation for the v1 release
//          - If it's a production deployment then the filename doesn't change. Any further develeopment happens in a new file e.g. X_v2.sol
//      - prints the address of the proxy (and the implementation for your information, but it's not used later)
//      - the proxy address is used in the "Upgrade*" step below
// 2, 4, 6, ...) PrepareUpgrade
//      - checks various things to be sure the deployment of the new implementation is safe
//      - deploys the safe new implementation (but doesn't make the proxy point to it as this is a multisig operation)
//      - prints the address of the implementation which is used in the "Upgrade*" step below
// 3, 5, 7, ...) Upgrade*
//      - updates the proxy with the new implementation and runs a function to convert the data
//      - this is in the form of a transaction list for the multisig

contract Deployed {
    address internal constant BAOMULTISIG = 0xFC69e0a5823E2AfCBEb8a35d33588360F1496a00;
    address internal constant wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant BaoUSD = 0x7945b0A6674b175695e5d1D08aE1e6F13744Abb0;
}

///////////////////////////////////////////////////////////////////////////
// deploy the contract for the first time
// This should only be called once!
// owner is either BAOMULTISIG or your wallet address associated with the private key

///////////////////////////////////////////////////////////////////////////
// LeveragedToken
// --------------
// $ yarn script script/deploy.s.sol:DeployLeveraged --rpc-url $MAINNET_RPC_URL --sig "run*(string memory pegged, string memory collateral)" "BaoUSD" "wstETH" --broadcast --verify
// log:
// 1.sepolia, runDev
//   proxy = 0x48fD4A32A7Df9F747e0a3C7d7085761C1242B210
//   implementation (v1a) = 0x84bCF7815A9C29E1f69Fb75055F68D50EFAdD5e7
//   owner=BAOMULTISIG so can't upgrade :/
// 2.sepolia, runDev
//   proxy = 0x26C6effF04F8c77E13F1A465C648056B80A8aE9a
//   implementation (v1) = 0xc14e210b71c20de3fa539cbdcc2af92378036bdd

contract DeployLeveraged is Script, Deployed {
    function runProd(string memory pegged, string memory collateral) external {
        run(BAOMULTISIG, pegged, collateral);
    }

    function runDev(string memory pegged, string memory collateral) external {
        run(vm.envAddress("PUBLIC_KEY"), pegged, collateral);
    }

    function run(address owner, string memory pegged, string memory collateral) private {
        string memory symbol = string.concat(pegged, "-", collateral);
        string memory name = string.concat("BaoMinter ", pegged, "-", collateral);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        Upgrades.deployUUPSProxy(
            "LeveragedToken_v1.sol",
            abi.encodeCall(LeveragedToken_v1.initialize, (owner, name, symbol))
        );

        vm.stopBroadcast();
    }
}

///////////////////////////////////////////////////////////////////////////
// ReservePool
// -----------
// $ yarn script script/deploy.s.sol:DeployReservePool --rpc-url $MAINNET_RPC_URL --sig "run*()" --broadcast --verify
// log:
// 1.sepolia, runDev
//   proxy = 0x82dcC46336e06F4921EfC46ee6A177456012C59A
//   implementation (v1a) = 0x82dcC46336e06F4921EfC46ee6A177456012C59A

contract DeployReservePool is Script, Deployed {
    function runProd() external {
        run(BAOMULTISIG);
    }

    function runDev() external {
        run(vm.envAddress("PUBLIC_KEY"));
    }

    function run(address owner) private {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        Upgrades.deployUUPSProxy("ReservePool_v1.sol", abi.encodeCall(ReservePool_v1.initialize, owner));

        vm.stopBroadcast();
    }
}

///////////////////////////////////////////////////////////////////////////
// TokenDistributor
// ---------------
// $ yarn script script/deploy.s.sol:DeployTokenDistributor --rpc-url $MAINNET_RPC_URL --sig "run*()" --broadcast --verify
// log:
// 1.sepolia, runDev
//   proxy = 0xEd659E305FA62C29122A87FAF1c5e4400ED98444
//   implementation (v1a) = 0x4d63e2a2F1C185F1e2a1D5f32671bcC0e1387981
//   something went wrong with the proxy setup on sepolia - they wont accept it is a proxy

contract DeployTokenDistributor is Script, Deployed {
    function runProd() external {
        run(BAOMULTISIG);
    }

    function runDev() external {
        run(vm.envAddress("PUBLIC_KEY"));
    }

    function run(address owner) private {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        Upgrades.deployUUPSProxy("TokenDistributor_v1.sol", abi.encodeCall(TokenDistributor_v1.initialize, owner));

        vm.stopBroadcast();
    }
}

///////////////////////////////////////////////////////////////////////////
// Minter
// ------
// $ yarn script script/deploy.s.sol:DeployMinter --rpc-url $MAINNET_RPC_URL --sig "run*()" --broadcast --verify
// log:
// 1.sepolia, runDev
//   proxy =
//   implementation (v1a) =

contract DeployMinter is Script, Deployed {
    function runProd() external {
        run(BAOMULTISIG);
    }

    function runDev() external {
        run(vm.envAddress("PUBLIC_KEY"));
    }

    function run(address owner) private {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // Upgrades.deployUUPSProxy("Minter_v1.sol", abi.encodeCall(Minter_v1.initialize, owner));

        vm.stopBroadcast();
    }
}

///////////////////////////////////////////////////////////////////////////
// deploy am upgrade implementation - prepared for the upgrade transaction
// this is a general function - can be used with any contract - just needs its name to check the files, storage etc.
// $ yarn script script/deploy.s.sol:PrepareUpgrade --rpc-url $MAINNET_RPC_URL --sig "run(string memory contractBase, string memory oldVersion, string memory newVersion)" "<e.g. LeveragedToken>" "<e.g. v1a>" "<e.g. v1>" --broadcast --slow --verify
contract PrepareUpgrade is Script, Deployed {
    function run(string memory contractBase, string memory oldVersion, string memory newVersion) external {
        // check the upgrade from files,and deploy
        Options memory opts;
        opts.referenceContract = string.concat(contractBase, "_", oldVersion, ".sol:", contractBase, "_", newVersion);
        console.log("referenceContract=%s", opts.referenceContract);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        address newImplementation = Upgrades.prepareUpgrade(string.concat(contractBase, "_", newVersion, ".sol"), opts);
        console.log("new %s implementation: %s", contractBase, newImplementation);

        vm.stopBroadcast();
    }
}

// upgrade the leveraged proxy to point to a given implementation
// $ yarn script script/deploy.s.sol:UpgradeLeveraged --rpc-url $MAINNET_RPC_URL "runDev(address proxy, address implementation)" "<address from Deploy*>" "<address from prepareUpgrade*" --broadcast
// for running in prod leave off the --broadcast and look into the log file for the transactions
contract UpgradeLeveraged is Script, Deployed {
    function runDev(address proxy, address implementation) external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // all we are doing here is changing the proxy's implememtation pointer
        // and calling a reinitialize function
        UnsafeUpgrades.upgradeProxy(
            proxy,
            implementation,
            "" // no reinitialization (i.e. no storage changes)
        );

        vm.stopBroadcast();
    }
}

contract DeployRebalancePool is Script, Deployed {}

contract DeployGenesis is Script, Deployed {}
