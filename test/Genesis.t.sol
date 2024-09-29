// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

//import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import { UnsafeUpgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IERC1967 } from "@openzeppelin/contracts/interfaces/IERC1967.sol";

import { IOwnable } from "src/interfaces/IOwnable.sol";
import { Minter_v1 } from "src/minter/Minter_v1.sol";
import { LeveragedToken_v1 } from "src/minter/LeveragedToken_v1.sol";
import { ReservePool_v1 } from "src/minter/ReservePool_v1.sol";
import { IMinter } from "src/minter/IMinter.sol";

import { Genesis_v1 } from "src/minter/Genesis_v1.sol";

import { MockPriceOracle } from "test/MockPriceOracle.sol";
import { deployed } from "test/deployed.sol";
import { Array } from "test/Array.sol";

contract Test_GenesisBase is Test, Array {
    Genesis_v1 genesis;

    address owner;

    address leveragedToken;
    address reservePool;
    MockPriceOracle priceOracle;
    address minter;

    address feeReceiver;
    address user1;
    address user2;

    /*
    function recipientAddresses() private returns (address[] memory result) {
        result = new address[](recipients.length);
        for (uint i = 0; i < recipients.length; i++) {
            result[i] = recipients[i].addr;
        }
    }
    */

    function setUpContract() public virtual {
        leveragedToken = UnsafeUpgrades.deployUUPSProxy(
            address(new LeveragedToken_v1()), // "LeveragedToken_v1.sol",
            abi.encodeCall(LeveragedToken_v1.initialize, (owner, "Leveraged Token", "BaoUSDLwstETH"))
        );

        reservePool = UnsafeUpgrades.deployUUPSProxy(
            address(new ReservePool_v1()), //"ReservePool_v1.sol",
            abi.encodeCall(ReservePool_v1.initialize, (owner))
        );

        IMinter.IncentiveConfig memory percent1 = IMinter.IncentiveConfig(ua(), ia(1 ether / 100));
        IMinter.Config memory config = IMinter.Config(
            130 ether / 100,
            200 ether / 100,
            percent1,
            percent1,
            percent1,
            percent1
        );

        minter = UnsafeUpgrades.deployUUPSProxy(
            address(new Minter_v1()), // "Minter_v1.sol",
            abi.encodeCall(
                Minter_v1.initialize,
                (
                    owner,
                    IMinter.BalanceTokens(deployed.BaoUSD, address(leveragedToken), deployed.wstETH),
                    address(priceOracle),
                    feeReceiver,
                    reservePool,
                    config
                )
            )
        );

        genesis = Genesis_v1(
            UnsafeUpgrades.deployUUPSProxy(
                address(new Genesis_v1()), //"Genesis_v1.sol",
                abi.encodeCall(Genesis_v1.initialize, (owner, address(minter)))
            )
        );
    }

    function setUp() public virtual {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 19210000);

        owner = vm.createWallet("owner").addr;

        setUpContract();
    }

    function test_initEvents() public {
        vm.expectEmit(false, false, false, true);
        emit Initializable.Initialized(type(uint64).max); // from the logic contract constructor
        vm.expectEmit(false, false, false, false);
        emit IERC1967.Upgraded(address(0)); // TODO:  we don't know the address right now
        vm.expectEmit(true, true, true, false);
        emit IOwnable.OwnershipTransferred(address(0), owner);
        vm.expectEmit(false, false, false, true);
        emit Initializable.Initialized(1); // from the proxy delegate call
        setUpContract();
    }

    function test_init() public {
        // expect a revert if initialize called twice
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        genesis.initialize(address(this), minter);

        // check the data has been set up correctly
        assertEq(genesis.owner(), owner, "wrong owner");
    }
}
