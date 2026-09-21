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

    /// @notice Above the knee the proposal changes nothing that the VALUATION decides - every call
    /// returns exactly what it does today. Anywhere it does not is code reading the anchor's price in a
    /// way that only works when the anchor is worth one.
    ///
    /// `leverageRatio` is the one exception, and it is named here rather than dropped from the surface
    /// because reporting an absence is the whole value of this test and a silently shortened surface is
    /// how that value is lost. It is not a pure function of the valuation: it also applies a CEILING, and
    /// the ceiling is one over the floor under the sail's claim. So wherever the fixed ceiling of twenty
    /// used to bind, the view reported twenty for a market that stood at seventy-one, and now reports
    /// seventy-one. The prices at those same ratios are identical to the wei, which is what says the
    /// difference is the ceiling and not the division.
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
                    // The reported leverage ratio carries the ceiling as well as the division, and the
                    // ceiling moves with the floor by design. Counted separately so that it still has to
                    // be EXPLAINED - a difference here is only permissible where the old fixed ceiling was
                    // binding, which the assertion below checks rather than assumes.
                    if (keccak256(bytes(names[i])) == keccak256(bytes("leverageRatio"))) {
                        assertEq(
                            abi.decode(current[i], (uint256)),
                            MinterValuationLib.LEVERAGE_RATIO_CAP,
                            "the leverage ratio may only differ where the old fixed ceiling was binding"
                        );
                        continue;
                    }
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

    /// @notice The rule reaches the FEE-PAYING paths, not only the prices and the free conversion.
    ///
    /// This is the test that decides where the rule may live, and it guards against a failure that shows
    /// up as an ABSENCE of change, which no ordinary comparison would flag. `MinterAdjustments_v1`
    /// divides the collateral's value itself, at six separate sites, and it is an external library
    /// reached by delegatecall - so it cannot call back into anything the minter overrides. A rule
    /// installed as an override on `Minter_v3` therefore leaves every fee-paying mint and redeem on the
    /// OLD division while the prices and the free conversion use the new one. That market would quote the
    /// anchor at 0.99 and pay out a fee-paying redeem at 1.00, and nothing would say so.
    ///
    /// Which is why the rule lives in `MinterValuationLib`: the one function that performs the division,
    /// compiled into BOTH the contract and the external library, so every consumer picks it up with no
    /// seam at all. Asserting the four fee-paying entry points MOVE is what holds it there - put the rule
    /// back behind a seam the external library cannot see and this goes red.
    ///
    /// Measured just INSIDE the band rather than at the peg itself, because the fee-paying leveraged
    /// redeem is refused at exactly one for a reason that has nothing to do with the valuation: its band
    /// floor is one, redeeming lowers the ratio, so standing on the floor the band has no room and the
    /// walk breaks out at the next band down. Refused under both rules compares equal, which would read
    /// as the rule failing to reach it. The band walk is indexed by the collateral ratio with the anchor
    /// taken at par, which the floor deliberately does not change - so moving off the floor is the whole
    /// of the fix.
    function test_theRuleReachesTheFeePayingPaths() public {
        // Inside the band and below where the rounding begins, so the anchor's price moves by the shift
        // alone and every call has room to complete.
        uint256 insideTheBand = 1.005 ether;
        (bytes[] memory calls, string[] memory names) = _surface();

        (bytes[] memory current, ) = _resultsAt(insideTheBand);
        uint256 snapshot = vm.snapshotState();
        installContractAt(minter, roundedImplementation);
        (bytes[] memory proposed, ) = _resultsAt(insideTheBand);
        vm.revertToStateAndDelete(snapshot);

        // The four fee-paying entry points, which price the anchor and so must move once its price moves.
        uint256[4] memory feePaying = [uint256(4), 5, 6, 7];
        for (uint256 i = 0; i < feePaying.length; i++) {
            uint256 at = feePaying[i];
            assertNotEq(
                keccak256(proposed[at]),
                keccak256(current[at]),
                string.concat(names[at], " did not move - the external library cannot see the rule")
            );
        }
        assertEq(calls.length, names.length, "every call must be named");
    }
}
