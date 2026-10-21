// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";

import {V3Rule} from "@harbor-test/harness/MarketRule.sol";
import {
    OpenWindowWithdrawer,
    RebalanceDilutionAttacker,
    RebalanceDilutionFork
} from "@harbor-test/deployment/RebalanceDilutionFork.sol";

/// @notice The market as deployed: Minter_v2, StabilityPool_v2, StabilityPoolManager_v1.
contract RebalanceDilutionAsDeployedTest is RebalanceDilutionFork {
    // The replay reproduces the incident: the exploit pays its sender exactly what it paid on chain, and its
    // rebalance converts the leveraged pool's pegged tokens at the capped 20 leveraged per pegged.
    function test_replay_reproducesTheIncident() public {
        uint256 leveragedPriceBefore = IMinter(market.minter).leveragedTokenPrice();
        vm.recordLogs();

        int256 senderGain = _replay();

        assertEq(senderGain, int256(EXPLOIT_PROCEEDS), "the exploit's payout");
        uint256 peggedConverted;
        uint256 leveragedMinted;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == market.leveragedPool && logs[i].topics[0] == IStabilityPool.Liquidated.selector) {
                (, peggedConverted, , ) = abi.decode(logs[i].data, (address, uint256, address, uint256));
            }
            if (
                logs[i].emitter == market.minter &&
                logs[i].topics[0] == IMinter.RedeemPeggedToken.selector &&
                logs[i].topics[1] == bytes32(uint256(uint160(market.manager)))
            ) {
                (, , leveragedMinted) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
        }
        assertGt(peggedConverted, 0, "the rebalance drew on the leveraged pool");
        assertEq(leveragedMinted, LEVERAGE_RATIO_CAP * peggedConverted, "the capped conversion");
        uint256 leveragedPriceAfter = IMinter(market.minter).leveragedTokenPrice();
        console2.log("leveraged price before", leveragedPriceBefore);
        console2.log("leveraged price after ", leveragedPriceAfter);
        assertLt(leveragedPriceAfter * 10, leveragedPriceBefore, "the leveraged holders lost over 90%");
    }

    // The rebuilt attack reproduces the exploit on the market as deployed: it reaches the capped conversion, the
    // leveraged holders are diluted, and the attacker gains.
    function test_attack_dilutesLeveragedHolders() public {
        address attacker = address(new RebalanceDilutionAttacker(market));

        Outcome memory outcome = _runAttack(attacker, attacker);

        assertTrue(outcome.rebalance.rebalanced, "rebalanced");
        assertEq(
            outcome.rebalance.leveragedMinted,
            LEVERAGE_RATIO_CAP * outcome.rebalance.peggedConverted,
            "the capped conversion"
        );
        assertLt(outcome.leveragedPriceAfter, outcome.leveragedPriceBefore, "the leveraged holders are diluted");
        assertGt(outcome.attackerGain, 0, "the attacker gains");
    }
}

/// @notice The pending upgrade: the minter to Minter_v3, with the manager and both pools moved with it.
/// @dev The exploit's own transaction is not replayed here. It calls the manager the upgrade replaces, and that
///      manager cannot call Minter_v3 at all, so the replay would fail on the selector whatever the conversion did.
contract RebalanceDilutionMinterV3Test is RebalanceDilutionFork {
    constructor() {
        useRule(new V3Rule());
    }

    function setUp() public override {
        super.setUp();
        _upgradeToMinterV3();
    }

    // The rebuilt attack still reaches the collateral ratio the exploit reached and still rebalances, but the
    // conversion is at the fair rate: the leveraged holders are not diluted and the attacker loses.
    function test_attack_convertsAtTheFairRate() public {
        address attacker = address(new RebalanceDilutionAttacker(market));

        Outcome memory outcome = _runAttack(attacker, attacker);

        assertLe(
            outcome.rebalance.collateralRatio,
            Math.mulDiv(1 ether, LEVERAGE_RATIO_CAP, LEVERAGE_RATIO_CAP - 1),
            "the collateral ratio where Minter_v2's cap engages was reached"
        );
        _assertConvertedAtTheFairRate(outcome);
        assertLt(outcome.attackerGain, 0, "the attacker loses");
    }
}

/// @notice Minter_v2 with leveraged redemptions refused below a collateral ratio of 1.10.
contract RebalanceDilutionRedemptionFloorTest is RebalanceDilutionFork {
    function setUp() public override {
        super.setUp();
        _refuseLeveragedRedemptionBelow(REDEMPTION_FLOOR);
    }

    // The exploit's own transaction no longer pays its sender.
    function test_replay_paysNothing() public {
        assertLe(_replay(), 0, "the exploit's payout");
    }

    // The rebuilt attack cannot take the collateral ratio below the floor, so its rebalance converts at the fair
    // rate: the leveraged holders are not diluted and the attacker loses.
    function test_attack_stopsAtTheFloor() public {
        address attacker = address(new RebalanceDilutionAttacker(market));

        Outcome memory outcome = _runAttack(attacker, attacker);

        assertGe(outcome.rebalance.collateralRatio, REDEMPTION_FLOOR, "the floor held");
        _assertConvertedAtTheFairRate(outcome);
        assertLt(outcome.attackerGain, 0, "the attacker loses");
    }
}

/// @notice The market as deployed, with the leveraged pool's early-withdrawal fee at 5% instead of 1%.
contract RebalanceDilutionWithdrawalFeeTest is RebalanceDilutionFork {
    function setUp() public override {
        super.setUp();
        _setEarlyWithdrawalFee(EARLY_WITHDRAWAL_FEE);
    }

    // The exploit's own transaction no longer pays its sender.
    function test_replay_paysNothing() public {
        assertLe(_replay(), 0, "the exploit's payout");
    }

    // The rebuilt attack, withdrawing in the open, pays the fee and loses.
    function test_attack_withdrawingInTheOpen_paysTheFee() public {
        address attacker = address(new RebalanceDilutionAttacker(market));

        Outcome memory outcome = _runAttack(attacker, attacker);

        assertTrue(outcome.rebalance.rebalanced, "rebalanced");
        assertLt(outcome.attackerGain, 0, "the attacker loses");
    }

    // The rebuilt attack, depositing for an account whose withdrawal window is open, pays no fee: the leveraged
    // holders are diluted and the attacker gains as if the fee were not there.
    function test_attack_throughAnOpenWindow_avoidsTheFee() public {
        address pool = market.leveragedPool;
        address attacker = address(new RebalanceDilutionAttacker(market));
        address withdrawer = address(new OpenWindowWithdrawer(pool));
        _openWithdrawalWindow(withdrawer);
        uint256 feeAddressPegged = IERC20(market.pegged).balanceOf(IStabilityPool(pool).getFeeAddress());

        Outcome memory outcome = _runAttack(attacker, withdrawer);

        assertEq(
            IERC20(market.pegged).balanceOf(IStabilityPool(pool).getFeeAddress()),
            feeAddressPegged,
            "no early-withdrawal fee"
        );
        assertEq(
            outcome.rebalance.leveragedMinted,
            LEVERAGE_RATIO_CAP * outcome.rebalance.peggedConverted,
            "the capped conversion"
        );
        assertLt(outcome.leveragedPriceAfter, outcome.leveragedPriceBefore, "the leveraged holders are diluted");
        assertGt(outcome.attackerGain, 0, "the attacker gains");
    }
}
