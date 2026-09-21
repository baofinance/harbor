// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {Minter_v3} from "@harbor/minter/Minter_v3.sol";
import {MinterValuationLib} from "@harbor/minter/library/MinterValuationLib.sol";

import {TestConversionBoundReleaseSetUp} from "@harbor-test/TestConversionBoundReleaseSetUp.sol";

/// @notice Finds every place that assumes the anchor is worth exactly one.
///
/// The rounded knee makes the anchor worth slightly less than one in a band ABOVE the peg. Today that
/// band does not exist - the anchor is worth one everywhere at or above a collateral ratio of one, and
/// worth less only below it - so code that assumes one can be correct today and wrong under the proposal
/// without anyone having written anything new.
///
/// The test for it is sharper than reading the code. Above the knee the two rules divide the collateral's
/// value IDENTICALLY, to the wei, because the smooth minimum is exactly the minimum once the arms are far
/// enough apart. So above the knee every operation must return exactly what it returns today, byte for
/// byte - and anything that does not is reading the anchor's price somewhere it should not, or reading it
/// in a way that only works when it is one.
///
/// Below the knee they differ by design, and that difference is the proposal rather than a fault.
///
/// This is not hypothetical: the conversion override written for this work had precisely that bug. It
/// valued the anchor at one and paid 111 sail per anchor token below the peg against a cap of 100,
/// because the arithmetic it was copied from bakes an anchor price of one into a multiply by `1 ether`.
/// That form is safe in the base ONLY because the base refuses wherever the anchor is worth less.
contract TestMinterRoundedKneeLeaks is TestConversionBoundReleaseSetUp {
    uint256 private constant DELTA = 0.01 ether;

    /// @dev How far apart the two arms must be before the knee is exactly their minimum. Read from the
    ///      contract's own share rather than restated, so this test cannot drift from the rule it measures.
    uint256 private constant SMOOTHING = (DELTA * MinterValuationLib.SAIL_CLAIM_ROUNDING_SHARE) / 1 ether;

    address private roundedImplementation;

    /// @dev The production bands disallow most fee-paying operations near the peg, and a refusal under
    ///      BOTH rules compares equal - so swept under them this test would quietly stop exercising the
    ///      band arithmetic that is the whole reason for it.
    function setUpConfig() internal virtual override {
        setUp_config_likelyNoDisallow();
    }

    function setUp() public virtual override {
        super.setUp();
        roundedImplementation = address(
            new Minter_v3(address(wrappedCollateralToken), address(peggedToken), address(leveragedToken), DELTA)
        );
    }

    /// @dev Every way in and out, plus every view the two rules could disagree on. Offered amounts small
    ///      enough that nothing is refused for want of balance or headroom, since a refusal on both sides
    ///      would compare equal and hide a difference rather than show one.
    function _surface() private view returns (bytes[] memory calls, string[] memory names) {
        address me = address(this);
        uint256 anchor = IERC20(peggedToken).balanceOf(me) / 1000;
        uint256 sail = IERC20(leveragedToken).balanceOf(me) / 1000;
        uint256 collateral = IERC20(wrappedCollateralToken).balanceOf(me) / 1000;

        calls = new bytes[](12);
        names = new string[](12);
        calls[0] = abi.encodeWithSignature("peggedTokenPrice()");
        names[0] = "peggedTokenPrice";
        calls[1] = abi.encodeWithSignature("leveragedTokenPrice()");
        names[1] = "leveragedTokenPrice";
        calls[2] = abi.encodeWithSignature("collateralRatio()");
        names[2] = "collateralRatio";
        calls[3] = abi.encodeWithSignature("leverageRatio()");
        names[3] = "leverageRatio";
        calls[4] = abi.encodeWithSignature("mintPeggedToken(uint256,address,uint256)", collateral, me, 0);
        names[4] = "mintPeggedToken";
        calls[5] = abi.encodeWithSignature("redeemPeggedToken(uint256,address,uint256)", anchor, me, 0);
        names[5] = "redeemPeggedToken";
        calls[6] = abi.encodeWithSignature("mintLeveragedToken(uint256,address,uint256)", collateral, me, 0);
        names[6] = "mintLeveragedToken";
        calls[7] = abi.encodeWithSignature("redeemLeveragedToken(uint256,address,uint256)", sail, me, 0);
        names[7] = "redeemLeveragedToken";
        calls[8] = abi.encodeWithSignature("freeMintPeggedToken(uint256,address)", collateral, me);
        names[8] = "freeMintPeggedToken";
        calls[9] = abi.encodeWithSignature("freeRedeemPeggedToken(uint256,uint256,address)", anchor, 0, me);
        names[9] = "freeRedeemPeggedToken, collateral leg";
        calls[10] = abi.encodeWithSignature("freeRedeemPeggedToken(uint256,uint256,address)", 0, anchor, me);
        names[10] = "freeRedeemPeggedToken, sail leg";
        calls[11] = abi.encodeWithSignature("freeRedeemLeveragedToken(uint256,address)", sail, me);
        names[11] = "freeRedeemLeveragedToken";
    }

    /// @dev What one call returns, with the market put back afterwards either way.
    function _resultOf(bytes memory callData) private returns (bool succeeded, bytes memory returned) {
        uint256 snapshot = vm.snapshotState();
        // solhint-disable-next-line avoid-low-level-calls
        (succeeded, returned) = minter.call(callData);
        vm.revertToStateAndDelete(snapshot);
    }

    /// @dev The whole surface under whichever rule is installed.
    function _resultsAt(uint256 collateralRatio) private returns (bytes[] memory results, bool[] memory ok) {
        setCollateralRatio(collateralRatio);
        (bytes[] memory calls, ) = _surface();
        results = new bytes[](calls.length);
        ok = new bool[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            (ok[i], results[i]) = _resultOf(calls[i]);
        }
    }

    /// @notice Above the knee the proposal changes NOTHING - every call returns exactly what it does
    /// today. Anywhere it does not is code reading the anchor's price in a way that only works when the
    /// anchor is worth one.
    function test_aboveTheKneeNothingChanges() public {
        // Clear of the rounding: the arms meet at `1/(1-delta)` and the rounding ends `k` beyond that.
        uint256 knee = Math.mulDiv(1 ether, 1 ether, 1 ether - DELTA);
        uint256 clear = knee + Math.mulDiv(SMOOTHING, 1 ether, 1 ether - DELTA) + 1;
        uint256[5] memory ratios = [clear, 1.05 ether, 1.15 ether, 1.30 ether, 2 ether];

        // Counted in memory, NOT in storage: the snapshot below is reverted at the end of every ratio,
        // and a storage counter would be rolled back with it and always read zero at the assertion.
        uint256 leaks;
        (, string[] memory names) = _surface();
        for (uint256 r = 0; r < ratios.length; r++) {
            uint256 outer = vm.snapshotState();

            (bytes[] memory current, bool[] memory currentOk) = _resultsAt(ratios[r]);

            uint256 inner = vm.snapshotState();
            installContractAt(minter, roundedImplementation);
            (bytes[] memory proposed, bool[] memory proposedOk) = _resultsAt(ratios[r]);
            vm.revertToStateAndDelete(inner);

            // Collected and reported together rather than asserted one at a time: the first difference
            // is rarely the only one, and a list of every place the assumption leaks is the deliverable.
            for (uint256 i = 0; i < current.length; i++) {
                if (keccak256(proposed[i]) != keccak256(current[i]) || proposedOk[i] != currentOk[i]) {
                    leaks++;
                    emit log_named_string(
                        string.concat("LEAK at collateral ratio ", vm.toString(ratios[r])),
                        names[i]
                    );
                }
            }

            vm.revertToStateAndDelete(outer);
        }
        assertEq(leaks, 0, "operations differ above the knee, where the two valuations are identical");
    }

    /// @notice Below the knee the two DO differ - otherwise the test above would be measuring nothing.
    ///
    /// Without this a mistake that made the proposal identical everywhere, such as failing to install it
    /// at all, would pass the comparison above and prove the opposite of what it claims.
    function test_belowTheKneeSomethingChanges() public {
        (, string[] memory names) = _surface();

        (bytes[] memory current, ) = _resultsAt(1 ether);
        uint256 snapshot = vm.snapshotState();
        installContractAt(minter, roundedImplementation);
        (bytes[] memory proposed, ) = _resultsAt(1 ether);
        vm.revertToStateAndDelete(snapshot);

        uint256 differing;
        for (uint256 i = 0; i < current.length; i++) {
            if (keccak256(proposed[i]) != keccak256(current[i])) {
                differing++;
                emit log_named_string("differs at the peg", names[i]);
            }
        }
        assertGt(differing, 0, "the proposal must change something at the peg, or nothing was installed");
    }

    /// @notice A rule installed on the MINTER ALONE does not reach the fee-paying paths - pinned here
    /// because it decides where the rule has to live, and because it shows up as an ABSENCE of change,
    /// which no ordinary comparison would flag.
    ///
    /// `MinterAdjustments_v1` divides the collateral's value itself, at six separate sites, and it is an
    /// external library reached by delegatecall - so it cannot call back into anything the minter
    /// overrides. Every fee-paying mint and redeem therefore keeps using the OLD division while the
    /// prices and the free conversion use the new one. A market like that would quote the anchor at 0.99
    /// and pay out a fee-paying redeem at 1.00.
    ///
    /// The conclusion is not that the subclass is wrong - it measures the prices and the conversion
    /// faithfully, which is what it was built for - but that the rule cannot ship as an override on
    /// `Minter_v3`. It belongs in `MinterValuationLib.tokenValuesE36`, which is the one function that
    /// performs the division and is compiled into BOTH the contract and the external library, so every
    /// consumer picks it up with no seam at all.
    function test_aRuleOnTheMinterAloneDoesNotReachTheFeePayingPaths() public {
        (bytes[] memory calls, string[] memory names) = _surface();

        (bytes[] memory current, ) = _resultsAt(1 ether);
        uint256 snapshot = vm.snapshotState();
        installContractAt(minter, roundedImplementation);
        (bytes[] memory proposed, ) = _resultsAt(1 ether);
        vm.revertToStateAndDelete(snapshot);

        // The four fee-paying entry points, which price the anchor and so MUST move once its price moves.
        uint256[4] memory feePaying = [uint256(4), 5, 6, 7];
        for (uint256 i = 0; i < feePaying.length; i++) {
            uint256 at = feePaying[i];
            assertEq(
                keccak256(proposed[at]),
                keccak256(current[at]),
                string.concat(names[at], " changed - the library can now see the rule, so this pin is stale")
            );
        }
        assertEq(calls.length, names.length, "every call must be named");
    }
}
