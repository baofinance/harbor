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

import "src/minter/lib/Config_v1.sol";
import "src/minter/LeveragedToken_v1.sol";
import "src/minter/ReservePool_v1.sol";
import "src/minter/TokenDistributor_v1.sol";
import "src/minter/Minter_v1.sol";
import "src/interfaces/IMinter.sol";
import "src/minter/StabilityPool_v1.sol";
import "src/minter/Genesis_v1.sol";
import "test/Array.sol";
import "test/Useful.sol";
import {IBaoUSD} from "test/IBaoUSD.sol";

import {ConfigFile} from "test/Config.sol";

import {DeployState} from "./DeployState.sol";

// TODO: update this
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

// Deploylib
// has two functions per contract to be deployed:
// * function deploy<contract>(<minimal parameters for deployment, e.g. owner>)
//   this deploys the contract
// * function postDeploy<contract>Transactions(<additional parameters to complete deployment>)
//   this performs all the actions required to set up and integrate the contract with other contracts
// The postDeploy* functions serve two main purposes:
// * they can reduce the size of the initialisation code needed for the contract. This is a problem for upgradeable contracts
//   where the "constructor" code remains deployed and uses up an amount of the allowed 24kb for a contract. The contructor code
//   for non-upgradeable contracts is run once and so is not actually deployed.
// * if two contracts hold each other's address then the postDeploy* function allows that to happen.
//
contract DeployLib is Network {
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
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

    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // ReservePool
    function deployReservePool(address owner) internal returns (address reservePool_) {
        reservePool_ = Upgrades.deployUUPSProxy("ReservePool_v1.sol", abi.encodeCall(ReservePool_v1.initialize, owner));
    }

    function postDeployReservePoolTransactions(address reservePool, address owner, address minter) internal {
        IBaoRoles(reservePool).grantRoles(minter, IReservePool(reservePool).REQUESTER_ROLE());
        IBaoOwnable(reservePool).transferOwnership(owner);
    }

    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // TokenDistributor
    function deployTokenDistributor(address owner, string memory name) internal returns (address tokenDistributor_) {
        tokenDistributor_ = Upgrades.deployUUPSProxy(
            "TokenDistributor_v1.sol",
            abi.encodeCall(TokenDistributor_v1.initialize, (owner, name))
        );
    }

    function postDeployTokenDistributorTransactions(address tokenDistributor, address owner) internal {
        IBaoOwnable(tokenDistributor).transferOwnership(owner);
    }

    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Minter
    // TODO: move a lot of this initialisation to the postDeploy function
    function deployMinter(
        address owner,
        address collateralToken,
        address peggedToken,
        address leveragedToken
    ) internal returns (address minter_) {
        // Deploy Config_v1 library - we do it here because it's only used by Minter to reduce it's size
        address configLib = vm.deployCode("Config_v1.sol:Config_v1");
        console2.log("Deployed Config_v1 at: %s", configLib);

        // Link the Config_v1 library
        vm.setEnv("DAPP_LIBRARIES", string.concat("Config_v1:", Strings.toHexString(uint160(configLib))));

        // constructor args
        Options memory opts;
        opts.constructorData = abi.encode(collateralToken, peggedToken, leveragedToken);

        // deploy Minter, with opts
        minter_ = Upgrades.deployUUPSProxy("Minter_v1.sol", abi.encodeCall(Minter_v1.initialize, owner), opts);
    }

    function postDeployMinterTransactions(address minter, address owner) internal {
        IBaoOwnable(minter).transferOwnership(owner);
    }

    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // StabilityPool
    function deployStabilityPool(
        address owner,
        address minter_,
        address liquidationToken
    ) internal returns (address stabilityPool_) {
        Options memory opts;
        opts.constructorData = abi.encode(minter_, liquidationToken);
        stabilityPool_ = Upgrades.deployUUPSProxy(
            "StabilityPool_v1.sol",
            abi.encodeCall(StabilityPool_v1.initialize, (owner))
        );
        //console2.log("StabilityPool(%s) = %s", IERC20Metadata(liquidationToken).symbol(), stabilityPool_);
    }

    function postDeployStabilityPoolTransactions(address stabilityPool_, address owner, address minter) internal {
        IBaoRoles(minter).grantRoles(stabilityPool_, IMinter(minter).ZERO_FEE_ROLE());
        IBaoOwnable(stabilityPool_).transferOwnership(owner);
    }

    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Genesis
    function deployGenesis(address owner, address minter_) internal returns (address genesis) {
        genesis = Upgrades.deployUUPSProxy("Genesis_v1.sol", abi.encodeCall(Genesis_v1.initialize, (owner, minter_)));
    }

    function postDeployGenesisTransactions(address genesis, address owner, address minter) internal {
        IBaoRoles(minter).grantRoles(genesis, IMinter(minter).ZERO_FEE_ROLE());
        IBaoOwnable(genesis).transferOwnership(owner);
    }

    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Liquidator
}

///////////////////////////////////////////////////////////////////////////
// deploy the contract for the first time, only be called once per network
///////////////////////////////////////////////////////////////////////////

///////////////////////////////////////////////////////////////////////////
// Deploy
// ------
// set RESUME false or unset for first iteration
// $ RESUME=true NETWORK=<e.g. mainnet> yarn script script/deploy.s.sol:Deploy --force --ffi --broadcast --verify

contract Deploy is DeployLib, DeployState, Array, ConfigFile {
    function run() public {
        vm.startBroadcast(privateKey);
        setStateFile(network);
        if (vm.envOr("RESUME", false)) {
            setStep(step() + 1);
            console2.log("Resuming deployment at step=%s", step());
        } else {
            setStep(1);
            console2.log("Starting deployment at step=%s", step());
        }

        if (step() == 1) {
            logAddr("owner", Deployed.BAOMULTISIG);
            // TODO: add the new Pegged Token here, and make minter a minter of it
            logAddr("peggedToken", Deployed.BaoUSD);
            logAddr("leveragedToken", DeployLib.deployLeveragedToken(Deployed.BAOMULTISIG, "BaoUSD", "wstETH"));
            //                                  --------------------
            logAddr("collateralToken", Deployed.wstETH);

            address priceOracle = Deployed.PriceOracle_wstETHUSD;
            logAddr("priceOracle", priceOracle);
            // TODO: how do we do claiming of distributed fees
            address feeReceiver = DeployLib.deployTokenDistributor(Deployed.BAOMULTISIG, "FeeDistributor");
            //                              ----------------------
            logAddr("feeReceiver", feeReceiver);
            address reservePool = DeployLib.deployReservePool(Deployed.BAOMULTISIG);
            //                              -----------------

            logAddr("reservePool", reservePool);

            int disallow = 10000; // code in config for a disallowed action at that collateral ratio
            IMinter.Config memory config;
            config.rebalanceCollateralRatioUpperBound = _percentToEther(130);
            config.mintPeggedIncentiveConfig = ic(ua(131, 140), ia(disallow, 100, 50));
            config.mintLeveragedIncentiveConfig = ic(ua(110, 120, 145), ia(-50, 0, 20, 70));
            config.redeemPeggedIncentiveConfig = ic(ua(105, 115, 150), ia(-75, -25, 60, 80));
            config.redeemLeveragedIncentiveConfig = ic(ua(105, 135), ia(disallow, 150, 120));

            writeConfig(config, network);

            address minter = DeployLib.deployMinter(
                //                     ------------
                Deployed.BAOMULTISIG,
                addr("collateralToken"),
                addr("peggedToken"),
                addr("leveragedToken")
            );
            logAddr("minter", minter);

            // call the post deploy functions
            IMinter(minter).updatePriceOracle(addr("priceOracle"));
            IMinter(minter).updateFeeReceiver(addr("feeReceiver"));
            IMinter(minter).updateReservePool(addr("reservePool"));
            IMinter(minter).updateConfig(config);
            IBaoRoles(minter).grantRoles(Deployed.BAOMULTISIG, IMinter(minter).ZERO_FEE_ROLE());

            DeployLib.postDeployLeveragedTokenTransactions(addr("leveragedToken"), Deployed.BAOMULTISIG, minter);
            DeployLib.postDeployTokenDistributorTransactions(feeReceiver, Deployed.BAOMULTISIG);
            DeployLib.postDeployReservePoolTransactions(reservePool, Deployed.BAOMULTISIG, minter);
        } else if (step() == 2) {
            address stabilityPoolCollateral = DeployLib.deployStabilityPool(
                //                                      -------------------
                Deployed.BAOMULTISIG,
                addr("minter"),
                addr("collateralToken")
            );
            logAddr("stabilityPoolCollateral", stabilityPoolCollateral);

            address stabilityPoolLeveraged = DeployLib.deployStabilityPool(
                //                                      -------------------
                Deployed.BAOMULTISIG,
                addr("minter"),
                addr("leveragedToken")
            );
            logAddr("stabilityPoolLeveraged", stabilityPoolLeveraged);

            address genesis = DeployLib.deployGenesis(
                //                      ------------
                Deployed.BAOMULTISIG,
                addr("minter")
            );
            logAddr("genesis", genesis);

            DeployLib.postDeployStabilityPoolTransactions(
                stabilityPoolCollateral,
                Deployed.BAOMULTISIG,
                addr("minter")
            );

            DeployLib.postDeployStabilityPoolTransactions(stabilityPoolLeveraged, Deployed.BAOMULTISIG, addr("minter"));
            DeployLib.postDeployGenesisTransactions(genesis, Deployed.BAOMULTISIG, addr("minter"));
            DeployLib.postDeployMinterTransactions(addr("minter"), Deployed.BAOMULTISIG);
        } else {
            console2.log("too many steps");
        }
        vm.stopBroadcast();
    }

    function logAddr(string memory name, address addr) private {
        setAddr(name, addr);
        console2.log("%s = %s", name, addr);
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
        setStateFile(network);

        address minter = addr("minter");
        address operator = Deployed.BAOMULTISIG; // TODO: IBaoUSD(Deployed.BaoUSD).operator();

        // For local networks, you can impersonate
        if (keccak256(abi.encodePacked(network)) == keccak256(abi.encodePacked("local"))) {
            // vm.deal(operator, 100 ether);
            console2.log("BaoUSD operator=%s", operator);
            console2.log("BaoUSD operator ETH balance=%s", Useful.toStringScaled(operator.balance, 18));
            vm.startBroadcast(operator); // Use your own key
            // vm.prank(operator); // Impersonate multisig for this call
            // it's me, hi, I'm the problem, it's me
            // add minter as a minter to BaoUSD
            IBaoUSD(Deployed.BaoUSD).addMinter(minter);
            vm.stopBroadcast();
        } else {
            // For real networks, just generate the transaction data
            // console2.log("Transaction to submit to multisig:");
            // console2.log("Target: %s", address(Deployed.BaoUSD));
            // console2.log("calldata: %s", abi.encodeCall(IBaoUSD.addMinter, (minter)));
        }
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

contract DeployReservePool is DeployLib {
    function run() public {
        vm.startBroadcast(privateKey);
        DeployLib.deployReservePool(Deployed.BAOMULTISIG);
        vm.stopBroadcast();
    }
}

///////////////////////////////////////////////////////////////////////////
// TokenDistributor
// ---------------
contract DeployTokenDistributor is DeployLib {
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
contract UpgradeUpgradeFeeDistributor is DeployLib {
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
contract PrepareUpgrade is DeployLib {
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
