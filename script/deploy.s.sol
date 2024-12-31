// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "forge-std/StdJson.sol";

import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol"; // only used for implementation address change
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

import "@bao/Deployed.sol";
import {IBurnable} from "@bao/interfaces/IBurnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import "src/minter/LeveragedToken_v1.sol";
import "src/minter/ReservePool_v1.sol";
import "src/minter/TokenDistributor_v1.sol";
import "src/minter/Minter_v1.sol";
import "src/minter/IMinter.sol";
import "src/minter/RebalancePool_v1.sol";
import "src/minter/Genesis_v1.sol";
import "test/Array.sol";
import "test/Useful.sol";
import {IBaoUSD} from "test/IBaoUSD.sol";

import {ConfigFile} from "test/Config.sol";

import {DeployState} from "./DeployState.sol";

// functions are called in this sequence
// 1) Deploy*
//      - deploys the proxy and the first implementation
//      - you should save the file being Deployed into the src_Deployed/<network e.g. sepolia> directory.
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

library DeployLib {
    // Leveraged Token
    function deployLeveragedToken(
        address owner,
        string memory pegged,
        string memory collateral
    ) internal returns (address leveragedToken_) {
        string memory symbol = string.concat(pegged, "-", collateral);
        string memory name = string.concat("BaoMinter ", pegged, "-", collateral);

        leveragedToken_ = Upgrades.deployUUPSProxy(
            "LeveragedToken_v1.sol",
            abi.encodeCall(LeveragedToken_v1.initialize, (owner, name, symbol))
        );
    }

    function postDeployLeveragedTokenTransactions(address leveragedToken, address owner, address minter) internal {
        IBaoRoles(leveragedToken).grantRoles(minter, ILeveragedToken(leveragedToken).MINTER_ROLE());
        IBaoOwnable(leveragedToken).transferOwnership(owner);
    }

    // ReservePool
    function deployReservePool(address owner) internal returns (address reservePool_) {
        reservePool_ = Upgrades.deployUUPSProxy("ReservePool_v1.sol", abi.encodeCall(ReservePool_v1.initialize, owner));
    }

    function postDeployReservePoolTransactions(address reservePool, address owner, address minter) internal {
        IBaoRoles(reservePool).grantRoles(minter, IReservePool(reservePool).REQUESTER_ROLE());
        IBaoOwnable(reservePool).transferOwnership(owner);
    }

    // TokenDistributor
    function deployTokenDistributor(address owner, string memory name) internal returns (address tokenDistributor_) {
        tokenDistributor_ = Upgrades.deployUUPSProxy(
            "TokenDistributor_v1.sol",
            abi.encodeCall(TokenDistributor_v1.initialize, (owner, name))
        );
    }

    // Minter
    function deployMinter(
        address owner,
        Minter_v1.BalanceTokens memory tokens,
        address priceOracle,
        address feeReceiver,
        address reservePool_,
        IMinter.Config memory config
    ) internal returns (address minter_) {
        minter_ = Upgrades.deployUUPSProxy(
            "Minter_v1.sol",
            abi.encodeCall(
                Minter_v1.initialize,
                (owner, tokens, type(IBurnable).interfaceId, priceOracle, feeReceiver, reservePool_, config)
            )
        );
    }

    // RebalancePool
    function deployRebalancePool(
        address owner,
        address minter_,
        address liquidationToken
    ) internal returns (address rebalancePool_) {
        rebalancePool_ = Upgrades.deployUUPSProxy(
            "RebalancePool_v1.sol",
            abi.encodeCall(RebalancePool_v1.initialize, (owner, minter_, liquidationToken))
        );
        //console2.log("RebalancePool(%s) = %s", IERC20Metadata(liquidationToken).symbol(), rebalancePool_);
    }

    // Genesis
    function deployGenesis(address owner, address minter_) internal returns (address genesis) {
        genesis = Upgrades.deployUUPSProxy("Genesis_v1.sol", abi.encodeCall(Genesis_v1.initialize, (owner, minter_)));
    }

    // Liquidator
}

contract Network is Script {
    uint256 public privateKey;
    address public publicKey;
    string public network;

    constructor() {
        network = vm.envString("NETWORK");
        if (keccak256(abi.encodePacked(network)) == keccak256(abi.encodePacked("local:test"))) {
            console2.log("using the first default wallet for deploying");
            privateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
            publicKey = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
            network = "local";
        } else {
            privateKey = vm.envUint("PRIVATE_KEY");
            publicKey = vm.addr(privateKey);
        }
        vm.createSelectFork(network);
        console2.log("deployer ETH balance=%s", Useful.toStringScaled(publicKey.balance, 18));
    }

    modifier deployer() {
        vm.startBroadcast(privateKey);
        _;
        vm.stopBroadcast();
    }
}

///////////////////////////////////////////////////////////////////////////
// deploy the contract for the first time, only be called once per network
///////////////////////////////////////////////////////////////////////////

///////////////////////////////////////////////////////////////////////////
// Deploy
// ------
// set RESUME false or unset for first iteration
// $ RESUME=true NETWORK=<e.g. mainnet> yarn script script/deploy.s.sol:Deploy --force --ffi --broadcast --verify

contract Deploy is Network, DeployState, Array, ConfigFile {
    function run() public {
        begin();

        if (step() == 1) {
            logAddr("owner", Deployed.BAOMULTISIG);
            logAddr("peggedToken", Deployed.BaoUSD);
            logAddr("leveragedToken", DeployLib.deployLeveragedToken(publicKey, "BaoUSD", "wstETH"));
            logAddr("collateralToken", Deployed.wstETH);

            Minter_v1.BalanceTokens memory tokens;
            tokens.peggedToken = addr("peggedToken");
            tokens.leveragedToken = addr("leveragedToken");
            tokens.collateralToken = addr("collateralToken");

            address priceOracle = Deployed.PriceOracle_wstETHUSD;
            logAddr("priceOracle", priceOracle);
            // TODO: how do we do claiming of distributed fees
            address feeReceiver = DeployLib.deployTokenDistributor(Deployed.BAOMULTISIG, "FeeDistributor");
            logAddr("feeReceiver", feeReceiver);
            address reservePool = DeployLib.deployReservePool(publicKey);
            logAddr("reservePool", reservePool);

            int disallow = 10000; // code in config for a disallowed action at that collateral ratio
            IMinter.Config memory config;
            config.rebalanceCollateralRatioUpperBound = _percentToEther(130);
            config.harvestCollateralRatioLowerBound = _percentToEther(250);
            config.mintPeggedIncentiveConfig = ic(ua(131, 140), ia(disallow, 100, 50));
            config.mintLeveragedIncentiveConfig = ic(ua(110, 120, 145), ia(-50, 0, 20, 70));
            config.redeemPeggedIncentiveConfig = ic(ua(105, 115, 150), ia(-75, -25, 60, 80));
            config.redeemLeveragedIncentiveConfig = ic(ua(105, 135), ia(disallow, 150, 120));

            writeConfig(network, config);

            address minter = DeployLib.deployMinter(
                Deployed.BAOMULTISIG,
                tokens,
                addr("priceOracle"),
                addr("feeReceiver"),
                addr("reservePool"),
                config
            );
            logAddr("minter", minter);

            DeployLib.postDeployLeveragedTokenTransactions(tokens.leveragedToken, Deployed.BAOMULTISIG, minter);
            DeployLib.postDeployReservePoolTransactions(reservePool, Deployed.BAOMULTISIG, minter);
        } else if (step() == 2) {
            logAddr(
                "rebalancePoolCollateral",
                DeployLib.deployRebalancePool(Deployed.BAOMULTISIG, addr("minter"), addr("collateralToken"))
            );
            logAddr(
                "rebalancePoolLeveraged",
                DeployLib.deployRebalancePool(Deployed.BAOMULTISIG, addr("minter"), addr("leveragedToken"))
            );
            logAddr("genesis", DeployLib.deployGenesis(Deployed.BAOMULTISIG, addr("minter")));
        } else {
            console2.log("too many steps");
        }
        end();
    }

    // string jsonObject;

    function begin() private {
        vm.startBroadcast(privateKey);
        setStateFile(network);
        if (vm.envOr("RESUME", false)) {
            setStep(step() + 1);
            console2.log("Resuming deployment at step=%s", step());
        } else {
            setStep(1);
            console2.log("Starting deployment at step=%s", step());
        }
        // jsonObject = "";
    }

    function logAddr(string memory name, address addr) private {
        //jsonObject = vm.serializeAddress("addresses", name, addr);
        setAddr(name, addr);
        console2.log("%s = %s", name, addr);
    }

    function end() private {
        vm.stopBroadcast();
    }

    function _percentToEther(uint amount) private pure returns (uint256) {
        return (amount * 1 ether) / 100;
    }
    // TODO: import this from test
    function _etherToBasisPoint(int amount) private pure returns (int256) {
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
}

contract Transactions is Network, DeployState {
    function run() public {
        vm.startBroadcast(privateKey);

        // it's me, hi, I'm the problem, it's me
        // add minter as a minter to BaoUSD
        IBaoUSD(Deployed.BaoUSD).addMinter(addr("minter"));

        vm.stopBroadcast();
    }
}

///////////////////////////////////////////////////////////////////////////
// LeveragedToken
// --------------
// upgrade the leveraged proxy to point to a given implementation
// $ NETWORK=<mainnet or sepolia> yarn script script/deploy.s.sol:UpgradeLeveraged "run(address proxy, address implementation)" "<address from Deploy*>" "<address from prepareUpgrade*" --broadcast
// for running in prod leave off the --broadcast and look into the log file for the transactions
contract UpgradeLeveraged is Network {
    function runDev(address proxy, address implementation) external {
        vm.startBroadcast(privateKey);

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
// ReservePool
// -----------
// $ NETWORK=<mainnet or sepolia> yarn script script/deploy.s.sol:DeployReservePool --broadcast --verify

contract DeployReservePool is Network {
    function run() public {
        vm.startBroadcast(privateKey);
        DeployLib.deployReservePool(Deployed.BAOMULTISIG);
        vm.stopBroadcast();
    }
}

///////////////////////////////////////////////////////////////////////////
// TokenDistributor
// ---------------
contract DeployTokenDistributor is Network {
    function run(string memory name) internal {
        vm.startBroadcast(privateKey);
        DeployLib.deployTokenDistributor(Deployed.BAOMULTISIG, name);
        vm.stopBroadcast();
    }
}

///////////////////////////////////////////////////////////////////////////
// FeeDistributor
// ---------------
// $ NETWORK=<mainnet or sepolia> yarn script script/deploy.s.sol:DeployFeeDistributor --broadcast --verify
contract DeployFeeDistributor is DeployTokenDistributor {
    function run() public {
        super.run("FeeDistributor");
    }
}

// upgrade the TokenDistributor proxy to point to a given implementation
// $ yarn script script/deploy.s.sol:UpgradeTokenDistributor --rpc-url $<e.g.MAINNET or SEPOLIA>_RPC_URL "run(address proxy, address implementation)" "<address from Deploy*>" "<address from prepareUpgrade*" --broadcast
// for running in prod leave off the --broadcast and look into the log file for the transactions
contract UpgradeUpgradeFeeDistributor is Network {
    function run(address proxy, address implementation) external {
        vm.startBroadcast(privateKey);
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
// deploy am upgrade implementation - prepared for the upgrade transaction
// this is a general function - can be used with any contract - just needs its name to check the files, storage etc.
// $ yarn script script/deploy.s.sol:PrepareUpgrade --rpc-url $<e.g.MAINNET or SEPOLIA>_RPC_URL --sig "run(string memory contractBase, string memory oldVersion, string memory newVersion)" "<e.g. LeveragedToken>" "<e.g. v1a>" "<e.g. v1>" --broadcast --slow --verify
contract PrepareUpgrade is Network {
    function run(string memory contractBase, string memory oldVersion, string memory newVersion) external {
        // check the upgrade from files,and deploy
        Options memory opts;
        opts.referenceContract = string.concat(contractBase, "_", oldVersion, ".sol:", contractBase, "_", newVersion);
        console.log("referenceContract=%s", opts.referenceContract);

        vm.startBroadcast(privateKey);

        address newImplementation = Upgrades.prepareUpgrade(string.concat(contractBase, "_", newVersion, ".sol"), opts);
        console2.log("new %s implementation: %s", contractBase, newImplementation);

        vm.stopBroadcast();
    }
}
