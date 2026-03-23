// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBurnable} from "@bao/interfaces/IBurnable.sol";
import {IBurnableFrom} from "@bao/interfaces/IBurnableFrom.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {DecrementalFloatingPoint} from "../math/DecrementalFloatingPoint.sol";

/// @title Post-Rebalance Remediation for StabilityPool_v2
/// @notice One-shot upgrade that corrects the reward integral inflated by the
/// Minter v1 over-minting bug, burns excess sailETH from the pool and from the
/// Claimer's wallet, restoring all holders to their v2-correct state.
///
/// See doc/remediation-ETH-fxUSD-SPL.md for full context.
///
/// Lifecycle:
///   1. Pause:       upgrade proxy to BaoPauser_v1
///   2. Remediate:   upgrade proxy to this contract, calling remediate()
///   3. Restore:     upgrade proxy back to StabilityPool_v2
// solhint-disable-next-line contract-name-capwords
contract PostRebalanceRemediationForStabilityPool_v2 is UUPSUpgradeable {
    using DecrementalFloatingPoint for uint128;

    // ── Distribution totals from V2ReplaySimulation ─────────────────────────
    // Total sailETH that entered the SPL via notifyLiquidation.
    // V1: SPL balance after last rebalance + tokens claimed by Claimer between rebalances
    //   = 9,018,421,479,602,093,456 (steps[6].splLevBal)
    //   + 52,963,888,575,928,980 (steps[1].splLevBal - steps[3].splLevBal)
    uint256 private constant V1_DISTRIBUTED = 9071385368178022436;
    // V2: SPL final balance + all sailETH claimed from SPL (Claimer + Exiter)
    //   = 151,557,802,561,965,107 (v2_correct_state.csv: SPL levBalance)
    //   + 876,808,384,680,618 (v2_correct_state.csv: Claimer hs Claimed)
    //   + 3,932,007,809,370,405 (v2_correct_state.csv: Exiter hs Claimed)
    uint256 private constant V2_DISTRIBUTED = 156366618756016130;

    // ── Claimer excess ──────────────────────────────────────────────────────
    // Claimer: 0xb9ab9578a34a05c86124c399735fdE44dEc80E7F
    // v1 held: 374,304,151,449,162,791 (v1_replay.csv: hs Held)
    // v2 held: 322,217,071,257,914,429 (v2_correct_state.csv: hs Held)
    // excess = v1 - v2
    address private constant CLAIMER = 0xb9ab9578a34a05c86124c399735fdE44dEc80E7F;
    uint256 private constant CLAIMER_EXCESS = 52087080191248362;

    // ── Immutables ──────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable LIQUIDATION_TOKEN;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address private immutable _OWNER;

    // ── Storage layout (mirrors StabilityPool_v2 + Accumulator_v2) ──────────

    struct TokenBalance {
        uint128 product;
        uint104 amount;
        uint40 updatedAt;
    }

    struct StabilityPoolStorage {
        TokenBalance totalAssetSupply;
    }

    bytes32 private constant _STABILITYPOOL_STORAGE =
        0xcb62d703974340239a82baeadff6ad7af3673eb85d9779bde2587fc9e0e3e400;

    function _getStabilityPoolStorage() private pure returns (StabilityPoolStorage storage $) {
        assembly { $.slot := _STABILITYPOOL_STORAGE }
    }

    struct AccumulatorStorage {
        mapping(address => address) rewardReceiver;
        mapping(address => mapping(uint8 => uint256)) tokenToExponentToIntegral;
    }

    bytes32 private constant _ACCUMULATOR_STORAGE =
        0x47ddc56aaabfe9761e2e64ce86720771c5fd1fd7ef0605da74e07d71de0e7900;

    function _getAccumulatorStorage() private pure returns (AccumulatorStorage storage $) {
        assembly { $.slot := _ACCUMULATOR_STORAGE }
    }

    // ── Errors ──────────────────────────────────────────────────────────────

    error NotOwner();
    error NothingToRemediate();

    // ── Constructor ─────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address liquidationToken_, address owner_) {
        _disableInitializers();
        LIQUIDATION_TOKEN = liquidationToken_;
        _OWNER = owner_;
    }

    // ── UUPS ────────────────────────────────────────────────────────────────

    function owner() public view returns (address) { return _OWNER; }

    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != _OWNER) revert NotOwner();
    }

    // ── Remediation ─────────────────────────────────────────────────────────

    /// @notice Execute the full remediation. Called via upgradeToAndCall.
    /// Requires BURNER_ROLE on the sailETH token (granted in the Safe batch).
    function remediate() external {
        if (msg.sender != _OWNER) revert NotOwner();

        // 1. Get current product exponent
        StabilityPoolStorage storage sp = _getStabilityPoolStorage();
        uint8 exp = sp.totalAssetSupply.product.exponent();

        // 2. Read and correct the integral
        AccumulatorStorage storage acc = _getAccumulatorStorage();
        uint256 currentIntegral = acc.tokenToExponentToIntegral[LIQUIDATION_TOKEN][exp];
        if (currentIntegral == 0) revert NothingToRemediate();

        uint256 correctedIntegral = currentIntegral * V2_DISTRIBUTED / V1_DISTRIBUTED;
        acc.tokenToExponentToIntegral[LIQUIDATION_TOKEN][exp] = correctedIntegral;

        // 3. Burn excess from pool
        uint256 poolBalance = IERC20(LIQUIDATION_TOKEN).balanceOf(address(this));
        uint256 tokensToKeep = poolBalance * correctedIntegral / currentIntegral;
        uint256 poolExcess = poolBalance - tokensToKeep;
        if (poolExcess > 0) {
            IBurnable(LIQUIDATION_TOKEN).burn(poolExcess);
        }

        // 4. Burn excess from Claimer's wallet
        if (CLAIMER_EXCESS > 0) {
            IBurnableFrom(LIQUIDATION_TOKEN).burnFrom(CLAIMER, CLAIMER_EXCESS);
        }
    }
}
