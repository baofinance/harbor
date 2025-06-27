// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IVotingEscrow} from "src/interfaces/IVotingEscrow.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {console2 as console} from "forge-std/console2.sol";

import {VotingEscrow_v1} from "src/reward/voting-escrow/VotingEscrow_v1.sol";

import {MockERC20} from "test/mock/MockERC20.sol";

import {VotingEscrowAbstractTest} from "test/reward/VotingEscrow.t.sol";

contract VotingEscrowTest is VotingEscrowAbstractTest {
    constructor() VotingEscrowAbstractTest(false) {}
}
