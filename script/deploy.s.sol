// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import "forge-std/Script.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import "src/minter/LeveragedToken_v1.sol";

contract Deployed {
    address internal constant BAOMULTISIG = 0xFC69e0a5823E2AfCBEb8a35d33588360F1496a00;
    address internal constant wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant BaoUSD = 0x7945b0A6674b175695e5d1D08aE1e6F13744Abb0;
}
// deploy the leveraged token
// run by yarn script script/deploy.s.sol:DeployLeveraged --sig "run(string memory pegged, string memory collateral)" "BaoUSD" "wstETH"
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

        console.log('Leveraged token %s "%s" deployed at %s', symbol, name, address(leveragedToken));

        vm.stopBroadcast();
    }
}

contract DeployReservePool is Script, Deployed {}

contract DeployFeeSplitter is Script, Deployed {}

contract DeployRebalancePool is Script, Deployed {}

contract DeployMinter is Script, Deployed {}
