// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {VmSafe} from "forge-std/Vm.sol";
import {LibString} from "@solady/utils/LibString.sol";

/// @title HolderCaptureLib - reads a capture written by `capture-holders` beside it, and judges a stability pool's
///        ledger gap against it.
/// @notice A capture is a directory holding `manifest.txt`, whose `to-block:` line is the block the scan ran to, and
///         one file per stability pool and token, named by its salt (`BTC::stETH::stabilityPoolLeveraged.txt`,
///         `BTC::pegged.txt`): `#` comment lines, then one address per line.
library HolderCaptureLib {
    using LibString for string;

    VmSafe private constant vm = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Where `capture-holders` writes when not told otherwise.
    string internal constant DEFAULT_DIRECTORY = "tmp/holders/";

    /// @dev A ledger gap at or beyond this fraction of the pool's supply, in parts per billion, either side of zero, is
    ///      not rounding. Rounding gaps measure about 0 parts per billion - a pool's loss arithmetic moves its supply and
    ///      its holders' balances apart by wei - and an incomplete list about 9e8, so this cleanly separates them.
    uint256 internal constant MAX_GAP_PARTS_PER_BILLION = 1_000_000; // 0.1% of supply

    /// @notice What a stability pool's ledger gap - its recorded supply less what its captured holders hold - says.
    ///         The StabilityPool_v3 upgrade seeds the gap with its sign, so only its size matters: within rounding it is
    ///         the pool's own, and beyond it the holders found do not match the pool's books.
    enum Gap {
        /// @dev Within `MAX_GAP_PARTS_PER_BILLION` of the supply, either side of zero.
        Rounding,
        /// @dev At or beyond `MAX_GAP_PARTS_PER_BILLION` of the supply below zero: the holders found hold more than the
        ///      pool records. A missing holder only shrinks their total, so this is never an incomplete list.
        Excess,
        /// @dev At or beyond `MAX_GAP_PARTS_PER_BILLION` of the supply above zero: the holder list misses depositors.
        Incomplete
    }

    /// @notice The block the capture in `directory` scanned to, from its manifest.
    function captureBlock(string memory directory) internal view returns (uint256) {
        string memory manifest = string.concat(_withSlash(directory), "manifest.txt");
        require(vm.isFile(manifest), string.concat("no capture manifest at ", manifest, " - run capture-holders"));
        string[] memory lines = vm.split(vm.readFile(manifest), "\n");
        for (uint256 i = 0; i < lines.length; ++i) {
            if (lines[i].startsWith("to-block: ")) {
                return vm.parseUint(lines[i].slice(10));
            }
        }
        revert(string.concat("capture manifest has no `to-block:` line: ", manifest));
    }

    /// @notice Every account the capture in `directory` lists for the pool or token whose salt is `salt`.
    function holders(string memory directory, string memory salt) internal view returns (address[] memory accounts) {
        string memory file = string.concat(_withSlash(directory), salt, ".txt");
        require(vm.isFile(file), string.concat("the capture has no holder file ", file));
        string[] memory lines = vm.split(vm.readFile(file), "\n");
        uint256 count;
        for (uint256 i = 0; i < lines.length; ++i) {
            if (_isAccount(lines[i])) {
                ++count;
            }
        }
        accounts = new address[](count);
        count = 0;
        for (uint256 i = 0; i < lines.length; ++i) {
            if (_isAccount(lines[i])) {
                accounts[count++] = vm.parseAddress(lines[i]);
            }
        }
    }

    /// @notice What a pool's ledger `gap` says, against its recorded `supply`.
    function classify(int256 gap, uint256 supply) internal pure returns (Gap) {
        uint256 size = gap < 0 ? uint256(-gap) : uint256(gap);
        if (size == 0 || (supply != 0 && (size * 1e9) / supply < MAX_GAP_PARTS_PER_BILLION)) {
            return Gap.Rounding;
        }
        return gap > 0 ? Gap.Incomplete : Gap.Excess;
    }

    function _withSlash(string memory directory) private pure returns (string memory) {
        return directory.endsWith("/") ? directory : string.concat(directory, "/");
    }

    /// @dev Every line of a holder file that is neither empty nor a `#` comment is an account.
    function _isAccount(string memory line) private pure returns (bool) {
        return bytes(line).length > 0 && !line.startsWith("#");
    }
}
