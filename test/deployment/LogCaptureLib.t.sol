// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {LogCaptureLib} from "@harbor-script/holders/LogCaptureLib.sol";

/// @notice LogCaptureLib reads a capture written by `capture-logs` - the block range it scanned, and each contract's
///         logs. The capture read is of the BTC::stETH exploit's block, kept in the repository: a capture over a past
///         range never changes. The expected values are the exploit transaction's receipt, read from the chain.
contract LogCaptureLibTest is Test {
    string internal constant CAPTURE = "test/fixtures/logs-26204584-26204584";
    bytes32 internal constant EXPLOIT = 0xb8701591c0fa3ee44a9f42379d167261f70e0532f7c0cea6fcda26ef999df3db;

    /// @dev External, so a revert in the library is a revert of a call the test can expect.
    function captureRange(string memory directory) external view returns (uint256, uint256) {
        return LogCaptureLib.captureRange(directory);
    }

    /// @dev External, so a revert in the library is a revert of a call the test can expect. Not `logs`: forge-std's
    ///      `Test` declares an event of that name.
    function readLogs(
        string memory directory,
        string memory salt
    ) external view returns (LogCaptureLib.CapturedLog[] memory) {
        return LogCaptureLib.logs(directory, salt);
    }

    /// @notice The range is the manifest's `from-block:` and `to-block:`, whether or not the directory ends in a slash.
    function test_captureRange_isTheManifestsRange() public view {
        (uint256 fromBlock, uint256 toBlock) = this.captureRange(CAPTURE);
        assertEq(fromBlock, 26_204_584, "from, without a slash");
        assertEq(toBlock, 26_204_584, "to, without a slash");
        (fromBlock, toBlock) = this.captureRange(
            "doc/incidents/2026-10-16-rebalance-dilution/logs-26204584-26248724/"
        );
        assertEq(fromBlock, 26_204_584, "from, with a slash");
        assertEq(toBlock, 26_248_724, "to, with a slash");
    }

    /// @notice A directory without a manifest is not a capture, and the read fails naming the manifest it looked for.
    function test_captureRange_revertsWithoutAManifest() public {
        vm.expectRevert(bytes("no capture manifest at test/fixtures/manifest.txt - run capture-logs"));
        this.captureRange("test/fixtures");
    }

    /// @notice A contract's logs are every log line of its file, in order, with every field - for a contract that
    ///         emitted none, one and many logs in the range.
    function test_logs_readsEveryLog() public view {
        assertEq(this.readLogs(CAPTURE, "EUR::stETH::minter").length, 0, "a contract with no logs in the block");

        LogCaptureLib.CapturedLog[] memory one = this.readLogs(CAPTURE, "BTC::stETH::stabilityPoolManager");
        assertEq(one.length, 1, "a contract with one log in the block: the manager's rebalance");
        assertEq(one[0].blockNumber, 26_204_584, "its block");
        assertEq(one[0].logIndex, 235, "its log index");
        assertEq(one[0].timestamp, 1_792_147_547, "its block's time");
        assertEq(one[0].transactionHash, EXPLOIT, "its transaction");
        assertEq(one[0].emitter, 0x5e9Bcaa1EDfD665c09a9e6693B447581d61A85A1, "its emitter, the manager");
        assertEq(one[0].topics.length, 1, "one topic");
        assertEq(one[0].topics[0], IStabilityPoolManager.Rebalanced.selector, "the event is Rebalanced");
        assertEq(
            one[0].data,
            hex"0000000000000000000000000000000000000000000000001591c769108df920000000000000000000000000000000000000000000000000128d8e2750e01d1e0000000000000000000000000000000000000000000000019d4b72eaf655c2a2",
            "its data"
        );

        LogCaptureLib.CapturedLog[] memory many = this.readLogs(CAPTURE, "BTC::stETH::stabilityPoolLeveraged");
        uint16[9] memory logIndices = [56, 58, 222, 234, 236, 238, 255, 256, 259];
        uint8[9] memory topicCounts = [3, 2, 1, 1, 2, 4, 3, 2, 2];
        assertEq(many.length, 9, "a contract with nine logs in the block");
        for (uint256 i = 0; i < many.length; ++i) {
            assertEq(many[i].logIndex, logIndices[i], "each log, in log order");
            assertEq(many[i].topics.length, topicCounts[i], "each log's topics, one to four");
        }
    }

    /// @notice A contract the capture has no file for fails, naming the file, rather than reading as no logs.
    function test_logs_revertsForAMissingFile() public {
        vm.expectRevert(bytes(string.concat("the capture has no log file ", CAPTURE, "/BTC::stETH::minter.txt")));
        this.readLogs(CAPTURE, "BTC::stETH::minter");
    }
}
