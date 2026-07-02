// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";

import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {TestStabilityPoolSetUp} from "@harbor-test/StabilityPool.t.sol";

/// @notice Width tests for the StabilityPool balance accounting. TokenBalance.amount must record
/// every in-envelope amount exactly and revert (never silently truncate) beyond the field. The
/// first four pin that behaviour at the boundaries — before the uint104→uint128 + SafeCast fix
/// each was red for its own reason (silent truncation at 2^104-scale; Panic(0x11) on the checked
/// += as supply crosses 2^104; a beyond-uint128 deposit succeeding truncated; the real
/// mint→deposit path mis-recording); with the fix in place they pass and guard against regression.
/// The last sizes the WIDTH the declared price × amount envelope actually requires.
contract StabilityPoolWidthTest is TestStabilityPoolSetUp {
    address internal pool;

    function setUp() public override {
        super.setUp();
        pool = stabilityPoolCollateral;
    }

    /// @dev Deposit `amount` of pegged for `actor` (deal + approve + deposit as the actor).
    function _deposit(address actor, uint256 amount) internal {
        deal(peggedToken, actor, amount);
        vm.startPrank(actor);
        IERC20(peggedToken).approve(pool, amount);
        IStabilityPool(pool).deposit(amount, actor, 0);
        vm.stopPrank();
    }

    /// @notice A deposit that fits the widened uint128 field is recorded exactly. 2^104 + 1e18 is
    /// inside the protocol's amount envelope (the real mint path reaches ~3.4e33), so it must be
    /// credited in full. Today the raw uint104 cast keeps only the low bits: the pool pulls the
    /// full amount via safeTransferFrom but credits 1e18 — silent loss of the entire 2^104 part.
    function test_deposit_uint104ScaleRecordedExactly() public {
        address actor = makeAddr("widthActor");
        uint256 amount = 2 ** 104 + 1 ether;
        _deposit(actor, amount);
        assertEq(IERC20(pool).balanceOf(actor), amount, "deposit must be credited exactly");
        assertEq(IERC20(pool).totalSupply(), amount, "total supply must record the deposit exactly");
    }

    /// @notice Legitimate deposits accumulating past 2^104 must both succeed — the availability
    /// half of the width defect. Each deposit individually fits uint104, so no cast truncates;
    /// instead the checked += on the uint104 total reverts Panic(0x11) on the second deposit,
    /// bricking deposits for everyone once the pool is ~2e31 full. Red today for that reason, and
    /// still red if SafeCast alone were added at 104 bits — only the uint128 widening fixes it.
    function test_deposit_supplyAccumulationCrossesUint104() public {
        address first = makeAddr("widthFirst");
        address second = makeAddr("widthSecond");
        uint256 half = 15e30; // 1.5e31: fits uint104 alone, crosses 2^104 = ~2.03e31 combined
        _deposit(first, half);
        _deposit(second, half);
        assertEq(IERC20(pool).totalSupply(), 2 * half, "accumulated supply must record exactly");
    }

    /// @notice Beyond the widened field there is no legal recording, so the deposit must REVERT —
    /// never truncate. 2^128 is a multiple of 2^104, so today the raw cast truncates it away
    /// cleanly and the deposit SUCCEEDS crediting only the 1e18 remainder (which is why the
    /// expected revert is missing today). Green when the write path uses SafeCast.toUint128.
    function test_deposit_beyondUint128Reverts() public {
        address actor = makeAddr("widthHuge");
        uint256 amount = 2 ** 128 + 1 ether;
        deal(peggedToken, actor, amount);
        vm.startPrank(actor);
        IERC20(peggedToken).approve(pool, amount);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, amount));
        IStabilityPool(pool).deposit(amount, actor, 0);
        vm.stopPrank();
    }

    /// @notice The REAL mint->deposit path records exactly across the amount envelope: for each
    /// wrapped-amount decade the minter (zero-fee bootstrap path, fixture oracle price) mints the
    /// pegged that the StabilityPool then receives — whatever the minter emits must fit the pool's
    /// balance field exactly. Today this goes red at the decades where minted pegged exceeds
    /// 2^104 (~2.03e31): depending on the truncated remainder the deposit either records the
    /// wrong balance or reverts below the pool minimum — both are the width defect surfacing.
    /// Rows are logged before the assertion so a red run still emits the sizing grid.
    function test_envelope_mintToDepositRecordedExactly() public {
        string memory csv = "./results/sp-width-envelope.csv";
        vm.writeFile(csv, "wrapped,mintedPegged,fitsUint104\n");

        uint256[6] memory wrappedAmounts = [uint256(1e16), 1e18, 1e21, 1e24, 1e27, 1e30];
        for (uint256 k = 0; k < wrappedAmounts.length; k++) {
            uint256 snap = vm.snapshotState();
            address actor = makeAddr("widthEnvelope");
            (uint256 minted, ) = setUp_collateral(wrappedAmounts[k], 0, actor);

            string memory row = string.concat(vm.toString(wrappedAmounts[k]), ",", vm.toString(minted));
            row = string.concat(row, ",", minted <= type(uint104).max ? "yes" : "NO");
            vm.writeLine(csv, row);
            console2.log("wrapped", wrappedAmounts[k]);
            console2.log("  minted pegged", minted);

            vm.startPrank(actor);
            IERC20(peggedToken).approve(pool, minted);
            IStabilityPool(pool).deposit(minted, actor, 0);
            vm.stopPrank();
            assertEq(
                IERC20(pool).balanceOf(actor),
                minted,
                "everything the minter emits must be recorded exactly by the pool"
            );
            vm.revertToState(snap);
        }
    }

    /// @dev External so the caller can try/catch a minter-side revert at an extreme corner.
    /// Sets the oracle underlying price (keeping the fixture rate), then free-mints `collateral`
    /// via the real minter and returns the pegged emitted.
    function mintAt(uint256 price, uint256 rate, uint256 collateral, address actor) external returns (uint256 minted) {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
        (minted, ) = setUp_collateral(collateral, 0, actor);
    }

    /// @notice Sizes the balance-field WIDTH the protocol envelope requires: pegged minted scales
    /// as collateral·price/1e18, so the amount an SP can hold is set jointly by the collateral
    /// amount AND the underlying price (collateral value in pegged units) — the axis the minter's
    /// own fee-range sweep fixes per config and does not vary. This sweeps oracle price (USD/BTC
    /// through BTC/USD and beyond) × collateral decades through the real free-mint path and records
    /// max minted, flagging where it crosses uint104 (2.03e31) and uint128 (3.4e38). The result is
    /// the data behind the uint128-vs-uint256 decision: it shows for which (price, collateral) the
    /// field must exceed each width, and whether any realistic pairing does. A minter-side revert
    /// at a corner is recorded as "revert" — that state produces no SP balance, so it needs no
    /// width. Sizing only: nothing is deposited, so the SP field is never exercised here.
    function test_envelope_priceAxis_maxMinted() public {
        string memory csv = "./results/sp-width-price-axis.csv";
        vm.writeFile(csv, "price,collateral,mintedPegged,widthNeeded\n");

        (uint256 basePrice, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        console2.log("fixture base price", basePrice);

        // price = collateral value in pegged units (1e18-scaled): 1e13 ~ USD priced in BTC
        // (0.00001), 1e18 = 1:1, ~2e21 = fixture wstETH/USD, 1e23 ~ BTC/USD, 1e26+ = micro-unit peg.
        uint256[7] memory prices = [uint256(1e13), 1e16, 1e18, 1e21, 1e24, 1e27, 1e30];
        // collateral wei: 1e18 = 1 token .. 1e30 = 1e12 tokens (far beyond any real collateral supply).
        uint256[5] memory collaterals = [uint256(1e18), 1e21, 1e24, 1e27, 1e30];

        uint256 maxMinted = 0;
        uint256 maxRealisticMinted = 0;
        for (uint256 i = 0; i < prices.length; i++) {
            for (uint256 j = 0; j < collaterals.length; j++) {
                uint256 snap = vm.snapshotState();
                address actor = makeAddr("priceAxisActor");
                string memory width;
                uint256 minted;
                try this.mintAt(prices[i], rate, collaterals[j], actor) returns (uint256 m) {
                    minted = m;
                    if (minted <= type(uint104).max) {
                        width = "uint104";
                    } else if (minted <= type(uint128).max) {
                        width = "uint128";
                    } else {
                        width = "uint256";
                    }
                    if (minted > maxMinted) {
                        maxMinted = minted;
                    }
                    // "realistic": collateral <= 1e25 wei (~1e7 tokens, above stETH supply already)
                    // and price within [1e15, 1e24] (0.001 .. 1e6 pegged per collateral unit).
                    if (
                        collaterals[j] <= 1e25 && prices[i] >= 1e15 && prices[i] <= 1e24 && minted > maxRealisticMinted
                    ) {
                        maxRealisticMinted = minted;
                    }
                } catch {
                    width = "revert";
                    minted = 0;
                }
                string memory row = string.concat(vm.toString(prices[i]), ",", vm.toString(collaterals[j]));
                row = string.concat(row, ",", vm.toString(minted), ",", width);
                vm.writeLine(csv, row);
                vm.revertToState(snap);
            }
        }

        console2.log("max minted pegged across envelope", maxMinted);
        console2.log("  fits uint128 (3.4e38)?", maxMinted <= type(uint128).max ? 1 : 0);
        console2.log("max minted across REALISTIC pairings", maxRealisticMinted);
        console2.log("  fits uint128 (3.4e38)?", maxRealisticMinted <= type(uint128).max ? 1 : 0);
        console2.log("  fits uint104 (2.03e31)?", maxRealisticMinted <= type(uint104).max ? 1 : 0);
    }
}
