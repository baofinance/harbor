// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import { UnsafeUpgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol"; // only used for implementation address change
import { Options } from "openzeppelin-foundry-upgrades/Options.sol";

import "src/minter/LeveragedToken_v1.sol";
import "src/minter/ReservePool_v1.sol";
import "src/minter/TokenDistributor_v1.sol";
import { Minter_v1 } from "src/minter/Minter_v1.sol";
import { IMinter } from "src/minter/IMinter.sol";
import "test/deployed.sol";
import { Array } from "test/Array.sol";

// functions are called in this sequence
// 1) Deploy*
//      - deploys the proxy and the first implementation
//      - you should save the file being deployed into the src_deployed/<network e.g. sepolia> directory.
//          - If it's a test deployment (e.g. on Sepolia) then the filename should have a letter appended,
//            e.g. X_v1.sol -> X_v1a.sol
//          - this indicates that it is an alpha version in preparation for the v1 release
//          - If it's a production deployment then the filename doesn't change.
//            Any further development happens in a new file e.g. X_v2.sol
//      - prints the address of the proxy (and the implementation for your information, but it's not used later)
//      - the proxy address is used in the "Upgrade*" step below
// 2, 4, 6, ...) PrepareUpgrade
//      - checks various things to be sure the deployment of the new implementation is safe
//      - deploys the safe new implementation (but doesn't make the proxy point to it as this is a multisig operation)
//      - prints the address of the implementation which is used in the "Upgrade*" step below
// 3, 5, 7, ...) Upgrade*
//      - updates the proxy with the new implementation and runs a function to convert the data
//      - this is in the form of a transaction list for the multisig
// Note: before running the commands to get your .env file into the environment do:
// $ set -a
// $ source .env
// $ set +a

/// @notice A list of named addresses
contract Network is Script {
    string network;
    mapping(string => mapping(string => address)) private networkNamedAddresses;

    function setAddress(string memory name, address mainnet, address sepolia) private {
        networkNamedAddresses["mainnet"][name] = mainnet;
        networkNamedAddresses["sepolia"][name] = sepolia;
    }

    constructor() {
        network = vm.envString("NETWORK");
        vm.createSelectFork(network);
        setAddress("owner", deployed.BAOMULTISIG, vm.envAddress("PUBLIC_KEY"));
        setAddress("BaoUSD-wstETH", address(0), deployedSepolia.BaoUSDxwstETH);
        setAddress("ReservePool", address(0), deployedSepolia.ReservePool);
        setAddress("FeeDistributor", address(0), deployedSepolia.FeeDistributor);
        setAddress("BaoUSD", deployed.BaoUSD, address(0));
        setAddress("wstETH", deployed.wstETH, address(0));
    }

    function addr(string memory name) internal view returns (address addr_) {
        addr_ = networkNamedAddresses[network][name];
        vm.assertFalse(addr_ == address(0));
    }
}

///////////////////////////////////////////////////////////////////////////
// deploy the contract for the first time
// This should only be called once!
// owner is either BAOMULTISIG or your wallet address associated with the private key

///////////////////////////////////////////////////////////////////////////
// LeveragedToken
// --------------
// $ NETWORK=<mainnet or sepolia> yarn script script/deploy.s.sol:DeployLeveraged --sig "run(string memory pegged, string memory collateral)" "BaoUSD" "wstETH" --broadcast --verify
// log:
// 1.sepolia, runDev
//   proxy = 0x48fD4A32A7Df9F747e0a3C7d7085761C1242B210
//   implementation (v1a) = 0x84bCF7815A9C29E1f69Fb75055F68D50EFAdD5e7
//   owner=BAOMULTISIG so can't upgrade :/
// 2.sepolia, runDev
//   proxy = 0x26C6effF04F8c77E13F1A465C648056B80A8aE9a
//   implementation (v1b) = 0xc14e210b71c20de3fa539cbdcc2af92378036bdd
// 3.sepolia, run
//   proxy=0x6dcbc4a48A53E0b5cAEAB31FE7cB9f55462Fd590
//   implementation (v1c) = 0xF6Bb247eA922417a82e4FCE2513b9AFE9cF11E44

contract DeployLeveraged is Network {
    function run(string memory pegged, string memory collateral) public {
        string memory symbol = string.concat(pegged, "-", collateral);
        string memory name = string.concat("BaoMinter ", pegged, "-", collateral);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        address leveragedToken = Upgrades.deployUUPSProxy(
            "LeveragedToken_v1.sol",
            abi.encodeCall(LeveragedToken_v1.initialize, (addr("owner"), name, symbol))
        );
        console2.log("LeveragedToken=%s", leveragedToken);

        vm.stopBroadcast();
    }
}
/*
// upgrade the leveraged proxy to point to a given implementation
// $ NETWORK=<mainnet or sepolia> yarn script script/deploy.s.sol:UpgradeLeveraged "run(address proxy, address implementation)" "<address from Deploy*>" "<address from prepareUpgrade*" --broadcast
// for running in prod leave off the --broadcast and look into the log file for the transactions
contract UpgradeLeveraged is Script {
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
*/
///////////////////////////////////////////////////////////////////////////
// ReservePool
// -----------
// $ NETWORK=<mainnet or sepolia> yarn script script/deploy.s.sol:DeployReservePool --broadcast --verify
// log:
// 1.sepolia, runDev
//   proxy = 0x82dcC46336e06F4921EfC46ee6A177456012C59A
//   implementation (v1a) = 0x82dcC46336e06F4921EfC46ee6A177456012C59A

contract DeployReservePool is Network {
    function run() public {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        Upgrades.deployUUPSProxy("ReservePool_v1.sol", abi.encodeCall(ReservePool_v1.initialize, addr("owner")));

        vm.stopBroadcast();
    }
}

///////////////////////////////////////////////////////////////////////////
// TokenDistributor
// ---------------
// $ NETWORK=<mainnet or sepolia> yarn script script/deploy.s.sol:DeployTokenDistributor --sig "run*(string memory name)" "FeeDistributor" --broadcast --verify
// log:
// 1.sepolia, runDev
//   proxy = 0xEd659E305FA62C29122A87FAF1c5e4400ED98444
//   implementation (v1a) = 0x4d63e2a2F1C185F1e2a1D5f32671bcC0e1387981
//   something went wrong with the proxy setup on sepolia - they wont accept it is a proxy
// 2.sepolia, runDev("FeeDistributor")
//   proxy = 0xc418E7cDEBC11F50AE018046B25784F8749f63e8
//   implementation (v1b) = 0x0D36A802171548fDFaA61c0146aC30a9166336E3

contract DeployTokenDistributor is Network {
    function run(string memory name) internal {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        Upgrades.deployUUPSProxy(
            "TokenDistributor_v1.sol",
            abi.encodeCall(TokenDistributor_v1.initialize, (addr("owner"), name))
        );

        vm.stopBroadcast();
    }
}

///////////////////////////////////////////////////////////////////////////
// FeeDistributor
// ---------------
// $ NETWORK=<mainnet or sepolia> yarn script script/deploy.s.sol:DeployFeeDistributor --broadcast --verify
// log:
// 1.sepolia, runDev
//   proxy = 0xEd659E305FA62C29122A87FAF1c5e4400ED98444
//   implementation (v1a) = 0x4d63e2a2F1C185F1e2a1D5f32671bcC0e1387981
//   something went wrong with the proxy setup on sepolia - they wont accept it is a proxy
// 2.sepolia, runDev("FeeDistributor")
//   proxy = 0xc418E7cDEBC11F50AE018046B25784F8749f63e8
//   implementation (v1b) = 0x0D36A802171548fDFaA61c0146aC30a9166336E3

contract DeployFeeDistributor is DeployTokenDistributor {
    function run() public {
        super.run("FeeDistributor");
    }
}

// upgrade the TokenDistributor proxy to point to a given implementation
// $ yarn script script/deploy.s.sol:UpgradeTokenDistributor --rpc-url $<e.g.MAINNET or SEPOLIA>_RPC_URL "runDev(address proxy, address implementation)" "<address from Deploy*>" "<address from prepareUpgrade*" --broadcast
// for running in prod leave off the --broadcast and look into the log file for the transactions
contract UpgradeUpgradeFeeDistributor is Script {
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

///////////////////////////////////////////////////////////////////////////
// Minter
// ------
// $ NETWORK=<mainnet or sepolia> yarn script script/deploy.s.sol:DeployMinter --broadcast --verify
// log:
// 1.sepolia, runDev
//   proxy =
//   implementation (v1a) =

contract DeployMinter is Network, Array {
    function _percentToEther(uint amount) private pure returns (uint256) {
        return (amount * 1 ether) / 100;
    }

    function _etherToBasisPoint(int256 amount) private pure returns (int) {
        return (amount * 10000) / 1 ether;
    }

    function _basisPointToEther(int amount) private pure returns (int256) {
        return (amount * 1 ether) / 10000;
    }
    function ic(
        uint[] memory upToPercent,
        int[] memory amountBasisPoints
    ) internal pure returns (IMinter.IncentiveConfig memory band) {
        band.collateralRatioBandUpperBounds = new uint256[](upToPercent.length);
        for (uint i = 0; i < upToPercent.length; i++) {
            band.collateralRatioBandUpperBounds[i] = _percentToEther(upToPercent[i]);
        }
        band.incentiveRatios = new int256[](amountBasisPoints.length);
        for (uint i = 0; i < amountBasisPoints.length; i++) {
            band.incentiveRatios[i] = _basisPointToEther(amountBasisPoints[i]);
        }
    }

    function run() public {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        Minter_v1.BalanceTokens memory tokens;
        tokens.peggedToken = addr("BaoUSD");
        tokens.leveragedToken = addr("BaoUSD-wstETH");
        tokens.collateralToken = addr("wstETH");

        int disallow = 10000;
        IMinter.Config memory config;
        config.rebalanceCollateralRatioUpperBound = _percentToEther(130);
        config.mintPeggedIncentiveConfig = ic(ua(130, 140), ia(disallow, 100, 50));
        config.mintLeveragedIncentiveConfig = ic(ua(110, 120, 145), ia(-50, 0, 20, 70));
        config.redeemPeggedIncentiveConfig = ic(ua(105, 115, 150), ia(-75, -25, 60, 80));
        config.redeemLeveragedIncentiveConfig = ic(ua(105, 135), ia(disallow, 150, 120));

        Upgrades.deployUUPSProxy(
            "Minter_v1.sol",
            abi.encodeCall(
                Minter_v1.initialize,
                (addr("owner"), tokens, addr("wstETH-USD"), addr("FeeDistributor"), addr("ReservePool"), config)
            )
        );

        vm.stopBroadcast();
    }
}

contract DeployRebalancePool is Script {}

contract DeployGenesis is Script {}

///////////////////////////////////////////////////////////////////////////
// deploy am upgrade implementation - prepared for the upgrade transaction
// this is a general function - can be used with any contract - just needs its name to check the files, storage etc.
// $ yarn script script/deploy.s.sol:PrepareUpgrade --rpc-url $<e.g.MAINNET or SEPOLIA>_RPC_URL --sig "run(string memory contractBase, string memory oldVersion, string memory newVersion)" "<e.g. LeveragedToken>" "<e.g. v1a>" "<e.g. v1>" --broadcast --slow --verify
contract PrepareUpgrade is Script {
    function run(string memory contractBase, string memory oldVersion, string memory newVersion) external {
        // check the upgrade from files,and deploy
        Options memory opts;
        opts.referenceContract = string.concat(contractBase, "_", oldVersion, ".sol:", contractBase, "_", newVersion);
        console.log("referenceContract=%s", opts.referenceContract);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        address newImplementation = Upgrades.prepareUpgrade(string.concat(contractBase, "_", newVersion, ".sol"), opts);
        console2.log("new %s implementation: %s", contractBase, newImplementation);

        vm.stopBroadcast();
    }
}
