// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";

import {MinterSupplyRelativeBound} from "@harbor-test/mocks/MinterSupplyRelativeBound.sol";
import {TestGraphsLiquidateAllLeveraged} from "@harbor-test/GraphsLiquidate.t.sol";

/// @notice The liquidation sweep that the flat rate of 20 was chosen from, re-run under the candidate
/// conversion rule so the two can be read against each other.
///
/// The flat rate was set at 20 after these graphs showed how much sail a rebalance was minting with no
/// bound at all. That was a reaction to a QUANTITY, answered with a cap on a RATE, and the two are not
/// the same thing - which is most of why the rate turned out to suit only one market. The candidate caps
/// the quantity directly: one conversion may issue at most `gamma` of the sail already outstanding.
///
/// Four rules over one sweep, all writing the same columns:
///
/// | file | rule |
/// |---|---|
/// | `liquidate_to_all_leveraged` | the flat rate of 20, as shipped |
/// | `liquidate_to_all_leveraged_unbounded` | no bound at all - what the original graphs showed |
/// | `liquidate_to_all_leveraged_gamma_1` | the candidate at `gamma` = 1 |
/// | `liquidate_to_all_leveraged_gamma_025` | the candidate at `gamma` = 0.25 |
///
/// The leveraged pool holds all of the anchor here, so every rebalance converts as much as it can. That
/// is the variant the choice of 20 was made on, and the one where a conversion rule shows most.
abstract contract TestGraphsLiquidateCandidateBase is TestGraphsLiquidateAllLeveraged {
    function gamma() internal pure virtual returns (uint256);

    /// @dev Substitutes the candidate rule. Everything the deploy does otherwise - address resolution,
    ///      the proxy, the recording - is the base's, so only the conversion differs from the sweep this
    ///      is compared against.
    function deployMinterImplementation(
        DeploymentTypes.State memory stateData,
        string memory key,
        address wrappedCollateral,
        address peggedToken_,
        address leveragedToken_
    ) internal override returns (address impl) {
        _reportContract(key);
        impl = address(new MinterSupplyRelativeBound(wrappedCollateral, peggedToken_, leveragedToken_));
        _reportImplementation(impl);
        _recordImplementation(
            stateData,
            key,
            "@harbor-test/mocks/MinterSupplyRelativeBound.sol",
            "MinterSupplyRelativeBound",
            impl
        );
    }

    function setUp() public virtual override {
        super.setUp();
        MinterSupplyRelativeBound(minter).setGamma(gamma());
    }
}

/// @notice No bound at all - the sweep as it looked before a cap was chosen.
contract TestGraphsLiquidateAllLeveragedUnbounded is TestGraphsLiquidateCandidateBase {
    /// @dev So far above any conversion the market can make that the cap never binds, which is the
    ///      unbounded rule without needing a second contract to express it.
    function gamma() internal pure override returns (uint256) {
        return type(uint128).max;
    }

    function context() internal pure override returns (string memory) {
        return "_all_leveraged_unbounded";
    }
}

/// @notice The candidate at the value doc section 9 proposed: one conversion may double the sail supply.
contract TestGraphsLiquidateAllLeveragedGamma1 is TestGraphsLiquidateCandidateBase {
    function gamma() internal pure override returns (uint256) {
        return 1 ether;
    }

    function context() internal pure override returns (string memory) {
        return "_all_leveraged_gamma_1";
    }
}

/// @notice The candidate at the value the gamma sweep recommends: one conversion may add a quarter.
contract TestGraphsLiquidateAllLeveragedGamma025 is TestGraphsLiquidateCandidateBase {
    function gamma() internal pure override returns (uint256) {
        return 0.25 ether;
    }

    function context() internal pure override returns (string memory) {
        return "_all_leveraged_gamma_025";
    }
}
