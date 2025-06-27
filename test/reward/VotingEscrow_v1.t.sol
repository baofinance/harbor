// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IVotingEscrow} from "src/interfaces/IVotingEscrow.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {console2 as console} from "forge-std/console2.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";

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

// Mock upgraded contract for testing
contract MockVotingEscrowUpgrade is VotingEscrow_v1 {
    constructor(address token_) VotingEscrow_v1(token_) {}

    function version() external pure override returns (string memory) {
        return "2.0.0";
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

    // Test upgrade functionality - only available in Solidity version
    function test_authorizeUpgrade_onlyOwner() public {
        // Deploy a mock upgrade implementation
        MockVotingEscrowUpgrade newImpl = new MockVotingEscrowUpgrade(address(governanceToken));

        vm.prank(admin);
        UUPSUpgradeable(votingEscrow).upgradeToAndCall(address(newImpl), "");

        // Verify the upgrade worked by checking the version
        assertEq(IVotingEscrow(votingEscrow).version(), "2.0.0");
    }

    function test_revertWhen_nonOwnerCallsUpgrade() public {
        MockVotingEscrowUpgrade newImpl = new MockVotingEscrowUpgrade(address(governanceToken));

        vm.expectRevert();
        vm.prank(user1);
        UUPSUpgradeable(votingEscrow).upgradeToAndCall(address(newImpl), "");
    }

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

    // Test smart contract restriction branches (lines 169-171)
    function test_smartContractWithoutRole() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        vm.prank(smartContract);
        MockERC20(governanceToken).approve(votingEscrow, amount);

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        vm.prank(smartContract, user1); // tx.origin = smartContract
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);
    }

    function test_smartContractWithRole() public {
        // Grant role to smart contract
        vm.prank(admin);
        IBaoRoles(votingEscrow).grantRoles(smartContract, 1); // SMART_CONTRACT_MANAGER_ROLE = 1

        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        vm.prank(smartContract);
        MockERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(smartContract, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        assertGt(IVotingEscrow(votingEscrow).balanceOf(smartContract), 0);
    }
}
