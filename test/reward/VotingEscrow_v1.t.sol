// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IVotingEscrow} from "src/interfaces/IVotingEscrow.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {console2 as console} from "forge-std/console2.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

import {VotingEscrow_v1} from "src/reward/voting-escrow/VotingEscrow_v1.sol";

import {MockERC20} from "test/mock/MockERC20.sol";

import {VotingEscrowAbstractTest} from "test/reward/VotingEscrow.t.sol";
import {VotingEscrowAbstract100Test} from "test/reward/VotingEscrow100.t.sol";
import {VotingEscrowTestSetUp} from "test/reward/VotingEscrow.t.sol";

// shared with vyper implementation tests
contract VotingEscrowTest is VotingEscrowAbstractTest {
    constructor() VotingEscrowAbstractTest(false) {}
}

contract VotingEscrow100Test is VotingEscrowAbstract100Test {
    constructor() VotingEscrowAbstract100Test(false) {}
}

contract MockVotingEscrow_v1 is VotingEscrow_v1 {
    constructor(address _token) VotingEscrow_v1(_token) {}

    // expose internal function for testing
    function find_block_epoch(uint256 blockNumber, uint256 maxEpoch) external view returns (uint256) {
        return _findBlockEpoch(blockNumber, maxEpoch);
    }
}

// specific to solidity implementation
contract VotingEscrow_v1Test is VotingEscrowTestSetUp {
    constructor() VotingEscrowTestSetUp(false) {}

    function setUp() public override {
        super.setUp();
        // overwrite the votingEscrow with a new instance of MockVotingEscrow_v1
        votingEscrow = UnsafeUpgrades.deployUUPSProxy(
            address(new MockVotingEscrow_v1(governanceToken)),
            // "Zhenglong Voting Escrow", "veSTEAM", "1"
            abi.encodeCall(VotingEscrow_v1.initialize, (admin, "Voting Escrow STEAM", "veSTEAM", "1.0.0"))
        );
        IBaoOwnable(votingEscrow).transferOwnership(admin);
    }

    // function testUpgradeToVotingEscrow_v1() public {
    //     address votingEscrowV1 = address(new VotingEscrow_v1(governanceToken));
    //     votingEscrow.upgradeToUnsafe(votingEscrowV1);
    //     assertEq(address(votingEscrow), votingEscrowV1);
    // }

    function test_FindBlockEpoch() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 52 * WEEK; // 1 year

        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount - 1, unlockTime);

        uint256 blockNumBefore = block.number;
        uint256 epochBefore = MockVotingEscrow_v1(votingEscrow).find_block_epoch(blockNumBefore, 100);

        vm.warp(block.timestamp + 10 * WEEK);
        vm.roll(block.number + 100);

        // Trigger a checkpoint to write to history
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_amount(1);

        uint256 blockNumAfter = block.number;
        uint256 epochAfter = MockVotingEscrow_v1(votingEscrow).find_block_epoch(blockNumAfter, 100);

        assertTrue(epochAfter >= epochBefore, "Epoch found should be greater or equal");
    }
}
