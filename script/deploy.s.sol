// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import "forge-std/Script.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import { Options } from "openzeppelin-foundry-upgrades/Options.sol";

import "src/minter/LeveragedToken_v1.sol";

contract Deployed {
    address internal constant BAOMULTISIG = 0xFC69e0a5823E2AfCBEb8a35d33588360F1496a00;
    address internal constant wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant BaoUSD = 0x7945b0A6674b175695e5d1D08aE1e6F13744Abb0;
}
// deploy the leveraged token
// run by yarn script script/deploy.s.sol:DeployLeveraged --sig "run(string memory pegged, string memory collateral)" "BaoUSD" "wstETH" --verify
contract DeployLeveraged is Script, Deployed {
    function run(string memory pegged, string memory collateral) external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        string memory symbol = string.concat(pegged, "-", collateral);
        string memory name = string.concat("BaoMinter ", pegged, "-", collateral);

        LeveragedToken_v1 leveragedToken = LeveragedToken_v1(
            Upgrades.deployUUPSProxy(
                "LeveragedToken_v1.sol",
                abi.encodeCall(LeveragedToken_v1.initialize, (BAOMULTISIG, name, symbol))
            )
        );
        console.log('deployed Leveraged Token (%s "%s")', symbol, name);
        console.log("  proxy deployed at %s", address(leveragedToken));
        console.log("  implementation at %s", Upgrades.getImplementationAddress(address(leveragedToken)));

        vm.stopBroadcast();
    }
}

// upgrade the leveraged token
// $ yarn script script/deploy.s.sol:UpgradeLeveraged --rpc-url $MAINNET_RPC_URL --verify
contract UpgradeLeveraged is Script, Deployed {
    function run() external {
        // sepolia proxy is: 0x48fD4A32A7Df9F747e0a3C7d7085761C1242B210
        // 1.implementation: 0x84bCF7815A9C29E1f69Fb75055F68D50EFAdD5e7
        address proxy = 0x48fD4A32A7Df9F747e0a3C7d7085761C1242B210; // TODO: make it a parameter
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        Options memory opts;
        opts.referenceContract = "LeveragedToken_v1a.sol:LeveragedToken_v1"; // the letter after the version indicates a pre-version 1

        console.log("upgrading Leveraged Token (proxy at %s)", proxy);
        console.log("old implementation at %s", Upgrades.getImplementationAddress(proxy));

        Upgrades.upgradeProxy(
            proxy,
            "LeveragedToken_v1.sol", // always a non alpha number (it may be the last)
            "", // no initialization (i.e. no storage changes)
            opts,
            BAOMULTISIG
        );

        console.log("upgraded Leveraged Token (proxy at %s)", proxy);
        console.log("  new implementation at %s", Upgrades.getImplementationAddress(proxy));

        vm.stopBroadcast();
    }
}

contract DeployReservePool is Script, Deployed {}

contract DeployMinterFeeTokenDistributer is Script, Deployed {}

contract DeployRebalancePool is Script, Deployed {}

contract DeployMinter is Script, Deployed {}
