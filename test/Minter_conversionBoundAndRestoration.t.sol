// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";

import {HarborTestActions} from "@harbor-test/HarborTestActions.sol";
import {MinterSupplyRelativeBound} from "@harbor-test/mocks/MinterSupplyRelativeBound.sol";
import {TestStabilityPoolManagerSetUp} from "@harbor-test/StabilityPoolManager.t.sol";

/// @notice What the conversion bound does to a rebalance, and what it does not.
///
/// A rebalance restores the collateral ratio by BURNING anchor. The sail handed back for it is a
/// separate quantity, decided by the conversion rule, and the burn happens whatever that rule says - the
/// minter subtracts the whole redeemed amount from the anchor supply before the rule has any bearing on
/// what comes back. So the ratio a rebalance reaches cannot depend on the bound, and the bound cannot
/// prevent a rebalance doing its job.
///
/// That is worth pinning because the opposite is an easy thing to assume, and assuming it leads
/// somewhere wrong: to deriving the bound's value from the rebalance threshold, as though a tighter
/// bound might leave a market stranded below it. It cannot. What a tighter bound changes is only how
/// much sail the stability pool is paid for the anchor it gave up.
contract TestMinterConversionBoundAndRestoration is TestStabilityPoolManagerSetUp, HarborTestActions {
    /// @dev Deep inside the band where any of these rules is engaged.
    uint256 private constant DISTRESSED = 1.002 ether;

    function deployMinterImplementation(
        DeploymentTypes.State memory stateData,
        string memory key,
        address wrappedCollateral,
        address peggedToken_,
        address leveragedToken_,
        uint256 sailClaimFloorShare
    ) internal override returns (address impl) {
        // The candidate is a cap on the QUANTITY one conversion issues, laid over an unchanged division of
        // the collateral - so a market whose config asks for a floor under the sail's claim would be
        // measuring two rules at once. Asserted rather than assumed, because the substitution below drops
        // the value on the floor and nothing else would say so.
        assertEq(sailClaimFloorShare, 0, "this candidate is only meaningful against an unfloored valuation");
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

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    function setUp() public virtual override {
        super.setUp();
        setUp_collateral(1000 ether, 1000 ether, address(this));
        deal(address(wrappedCollateralToken), address(this), 100_000 ether);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);
        vm.prank(owner());
        IHarborRoles(minter).grantRoles(address(this), zeroFeeRole);

        // Most of the anchor in the pools, so that what is being measured is the conversion rule rather
        // than the pools running out of headroom.
        uint256 perPool = (IMinter(minter).peggedTokenBalance() * 2) / 5;
        IStabilityPool(stabilityPoolCollateral).deposit(perPool, address(this), 0);
        IStabilityPool(stabilityPoolLeveraged).deposit(perPool, address(this), 0);
    }

    /// @dev Rebalance out of the same distressed ratio under `gamma`, reporting where the market ended up
    ///      and how much sail the leveraged pool was given for it.
    function _rebalanceUnder(uint256 gamma) private returns (uint256 ratioReached, uint256 sailPaid) {
        uint256 snapshot = vm.snapshotState();
        MinterSupplyRelativeBound(minter).setGamma(gamma);
        setCollateralRatioByPrice(minter, priceOracle, DISTRESSED);

        uint256 sailBefore = IERC20(leveragedToken).balanceOf(stabilityPoolLeveraged);
        IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, 0);

        ratioReached = IMinter(minter).collateralRatio();
        sailPaid = IERC20(leveragedToken).balanceOf(stabilityPoolLeveraged) - sailBefore;
        vm.revertToStateAndDelete(snapshot);
    }

    /// The collateral ratio a rebalance reaches is the same however tightly the conversion is bounded,
    /// because the anchor is burned either way. A bound two hundred and fifty-six times tighter pays the
    /// pool a fraction of the sail and leaves the market in exactly the same place.
    function test_theRatioRestoredDoesNotDependOnTheConversionBound() public {
        uint256 threshold = IStabilityPoolManager(stabilityPoolManager).rebalanceThreshold();

        (uint256 looseRatio, uint256 looseSail) = _rebalanceUnder(16 ether);
        (uint256 tightRatio, uint256 tightSail) = _rebalanceUnder(0.0625 ether);

        assertEq(looseRatio, tightRatio, "the ratio reached is the same under either bound");
        assertApproxEqAbs(looseRatio, threshold, 0.0005 ether, "and it is the threshold, under both");

        assertGt(looseSail, tightSail * 10, "while what the pool is paid differs by an order of magnitude");
    }

    /// The same, across the configured thresholds: none of them makes the bound a limit on restoration.
    function test_noThresholdMakesTheBoundLimitRestoration() public {
        uint256[4] memory thresholds = [uint256(1.05 ether), 1.1 ether, 1.25 ether, 1.3 ether];

        for (uint256 i = 0; i < thresholds.length; i++) {
            vm.prank(owner());
            IStabilityPoolManager(stabilityPoolManager).updateRebalanceThreshold(thresholds[i]);

            (uint256 looseRatio, ) = _rebalanceUnder(16 ether);
            (uint256 tightRatio, ) = _rebalanceUnder(0.0625 ether);

            assertEq(looseRatio, tightRatio, "the ratio reached does not depend on the bound");
            assertApproxEqAbs(tightRatio, thresholds[i], 0.0005 ether, "and the threshold is reached");
        }
    }
}
