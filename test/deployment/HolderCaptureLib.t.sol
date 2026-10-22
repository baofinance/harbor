// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {HolderCaptureLib} from "@harbor-script/holders/HolderCaptureLib.sol";

/// @notice HolderCaptureLib reads a capture written by `capture-holders` - the block it scanned to, and each pool's or
///         token's holder list - and judges a stability pool's ledger gap. The capture read is an incident's, kept in
///         the repository: a capture at a past block never changes.
contract HolderCaptureLibTest is Test {
    string internal constant CAPTURE = "doc/incidents/2026-10-16-rebalance-dilution/holders-26204584";

    /// @dev External, so a revert in the library is a revert of a call the test can expect.
    function captureBlock(string memory directory) external view returns (uint256) {
        return HolderCaptureLib.captureBlock(directory);
    }

    /// @dev External, so a revert in the library is a revert of a call the test can expect.
    function holders(string memory directory, string memory salt) external view returns (address[] memory) {
        return HolderCaptureLib.holders(directory, salt);
    }

    /// @notice The block is the manifest's `to-block:`, whether or not the directory ends in a slash.
    function test_captureBlock_isTheManifestsBlock() public view {
        assertEq(this.captureBlock(CAPTURE), 26_204_584, "without a slash");
        assertEq(this.captureBlock(string.concat(CAPTURE, "/")), 26_204_584, "with a slash");
    }

    /// @notice A directory without a manifest is not a capture, and the read fails naming the manifest it looked for.
    function test_captureBlock_revertsWithoutAManifest() public {
        vm.expectRevert(
            bytes(
                "no capture manifest at doc/incidents/2026-10-16-rebalance-dilution/manifest.txt - run capture-holders"
            )
        );
        this.captureBlock("doc/incidents/2026-10-16-rebalance-dilution");
    }

    /// @notice A holder list is every address line of the file, in order, and no comment line - for a list of none,
    ///         one and many accounts.
    function test_holders_readsEveryAccount() public view {
        assertEq(this.holders(CAPTURE, "GOLD::stETH::stabilityPoolCollateral").length, 0, "a pool no one entered");

        address[] memory one = this.holders(CAPTURE, "GOLD::fxUSD::stabilityPoolCollateral");
        assertEq(one.length, 1, "a pool one account entered");
        assertEq(one[0], 0x1a9152528AEFbcD9E5df4E0770f4F510e7056913, "its one depositor");

        address[] memory many = this.holders(CAPTURE, "BTC::stETH::stabilityPoolLeveraged");
        assertEq(many.length, 12, "a pool twelve accounts entered");
        assertEq(many[0], 0x0e4d5032c0B076cB132a10347d940BfBB8354869, "the first depositor in the file");
        assertEq(many[11], 0xDc9CDd31BC0F598e6B2c8302312B40852F636E60, "the last depositor in the file");
    }

    /// @notice A pool or token the capture has no file for fails, naming the file, rather than reading as no holders.
    function test_holders_revertsForAMissingFile() public {
        vm.expectRevert(bytes(string.concat("the capture has no holder file ", CAPTURE, "/BTC::stETH::minter.txt")));
        this.holders(CAPTURE, "BTC::stETH::minter");
    }

    /// @notice A gap within `MAX_GAP_PARTS_PER_BILLION` of the supply, either side of zero, is rounding. At or beyond
    ///         it, a positive gap is an incomplete list and a negative one an excess: the holders hold more than the
    ///         pool records.
    function test_classify() public pure {
        uint256 supply = 1 ether;
        // The smallest gap the rule calls more than rounding: exactly the bound's share of this supply.
        int256 bound = int256((supply * HolderCaptureLib.MAX_GAP_PARTS_PER_BILLION) / 1e9);
        uint256 rounding = uint256(HolderCaptureLib.Gap.Rounding);
        uint256 incomplete = uint256(HolderCaptureLib.Gap.Incomplete);
        uint256 excess = uint256(HolderCaptureLib.Gap.Excess);

        assertEq(_class(0, supply), rounding, "zero");
        assertEq(_class(-1, supply), rounding, "one wei below zero");
        assertEq(_class(bound - 1, supply), rounding, "a wei inside the bound above zero");
        assertEq(_class(1 - bound, supply), rounding, "a wei inside the bound below zero");
        assertEq(_class(bound, supply), incomplete, "at the bound above zero");
        assertEq(_class(-bound, supply), excess, "at the bound below zero");
        assertEq(_class(int256(supply), supply), incomplete, "the whole supply unheld");
        assertEq(_class(-2 * int256(supply), supply), excess, "twice the supply held beyond it");
        assertEq(_class(0, 0), rounding, "an empty pool");
        assertEq(_class(-1, 0), excess, "a wei held in a pool that records none");
    }

    function _class(int256 gap, uint256 supply) internal pure returns (uint256) {
        return uint256(HolderCaptureLib.classify(gap, supply));
    }
}
