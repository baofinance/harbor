// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {RevertReason} from "@harbor-test/RevertReason.sol";
import {TestStabilityPool2SetUp} from "@harbor-test/TestStabilityPool2SetUp.sol";

/// @notice Where the minter's arithmetic stops working, found by calling it rather than by deriving it.
///
/// Several products inside the minter multiply a token supply by a price in 256 bits, in plain checked
/// arithmetic, before any `mulDiv` can widen the intermediate. Because the arithmetic is checked, the
/// failure is a REVERT and not a wrong number, which makes this a question about AVAILABILITY: past the
/// boundary the operation simply stops being offered, and a sail holder cannot redeem.
///
/// The price in those products is the ORACLE COLLATERAL price - what one collateral token is worth in
/// pegged tokens - and not the anchor price. The anchor price is `min(1, collateral ratio)` and never
/// exceeds one, so were it the multiplier these products would be bounded by the supply alone. The oracle
/// price is a ratio of two market prices, a market's collateral in dollars over its peg in dollars, and a
/// cheap peg paired with an expensive collateral makes it very large indeed. So the ceiling is not a
/// supply figure but a relationship between the supply and the price.
///
/// EVERY EXTERNAL WAY IN AND OUT IS PROBED - fee-paying and free, both tokens, and the pegged redeem's two
/// legs separately because they are different arithmetic. A search confined to the rebalance would have
/// reached one of these products and reported an envelope the user paths do not have.
///
/// ONLY AN ARITHMETIC PANIC MARKS THE BOUNDARY. The minter declines calls constantly and for good reasons
/// - a zero output, a disallow band, a balance, a fee cap - and a search that counted a refusal as the
/// edge would report a far smaller envelope than the real one. That distinction is what makes a negative
/// result here worth anything, so it is guarded from the other side too: `test_everyEntryPointWorksAtAn
/// OrdinaryMarket` requires every probe to SUCCEED at a nominal market, which is what catches a mistyped
/// signature, a missing approval or an ungranted role before it can masquerade as a narrow envelope.
///
/// The sail supply is set by writing the token's supply directly rather than by minting it. The two are
/// different questions: how much sail the minter's own arithmetic can carry, and how much sail a market
/// can be made to mint. Minting to reach a supply would conflate them and stop the search at whichever
/// came first - and the answer would be the mint's, because sail is minted against a residual that a
/// large supply has already thinned. The conversion this whole investigation is about mints sail with no
/// collateral behind it at all, so a supply reached without minting is not a hypothetical.
contract TestMinterOverflowBoundary is GraphTestBase, TestStabilityPool2SetUp, RevertReason {
    /// @dev The declared envelope's largest pool, in dollars, 1e18-scaled - the same figure the stability
    ///      pool's envelope carries, because it is the same market being sized.
    uint256 private constant MAX_POOL_VALUE_USD = 1e10 ether;

    /// @dev The declared envelope's dearest collateral, in dollars. Paired with the cheapest peg below it
    ///      gives the largest oracle price the envelope admits.
    uint256 private constant MAX_COLLATERAL_USD = 1e6 ether;

    /// @dev The wrapped-to-underlying rate held at one throughout. It is an axis of the envelope in its
    ///      own right and not of this measurement: it multiplies the collateral, which these products are
    ///      the least sensitive to, and letting it move would confound the two.
    uint256 private constant WRAP_RATE = 1 ether;

    /// @dev The collateral ratio every row is measured at - the proportions a market is deployed at, with
    ///      the sail buffer carrying a third of the collateral's value. Held the same across the peg sweep
    ///      so the rows differ in the peg alone.
    uint256 private constant BUILD_COLLATERAL_RATIO = 2 ether;

    /// @dev The peg prices swept, in dollars, 1e18-scaled: the envelope's declared range from a
    ///      hyperinflated unit at a millionth of a cent to an appreciated one worth a trillion dollars,
    ///      two orders of magnitude apart. The oracle price and the anchor token count both scale with
    ///      this, in opposite directions - a cheaper peg means more anchor tokens each worth less, and a
    ///      collateral token worth more of them.
    function _pegPrices() private pure returns (uint256[] memory prices) {
        prices = new uint256[](13);
        prices[0] = 1e-12 ether;
        prices[1] = 1e-10 ether;
        prices[2] = 1e-8 ether;
        prices[3] = 1e-6 ether;
        prices[4] = 1e-4 ether;
        prices[5] = 1e-2 ether;
        prices[6] = 1 ether;
        prices[7] = 1e2 ether;
        prices[8] = 1e4 ether;
        prices[9] = 1e6 ether;
        prices[10] = 1e8 ether;
        prices[11] = 1e10 ether;
        prices[12] = 1e12 ether;
    }

    /// @dev The top of the sail-supply ladder, as a power of two. 2^200 is about 1.6e60 - far past any
    ///      supply the envelope's own dollar figures reach, so a column that never overflows below it has
    ///      genuinely not been shown a boundary rather than merely not been pushed far enough.
    uint256 private constant TOP_RUNG = 200;

    string private file;

    /// @dev The production volatility configs refuse an anchor mint below a collateral ratio of about
    ///      1.31. That band table is policy and this measurement is about arithmetic, so a market stood up
    ///      under it would be one long gap where the probes were refused rather than answered.
    function setUpConfig() internal virtual override {
        setUp_config_likelyNoDisallow();
    }

    function setUp() public virtual override {
        super.setUp();
        // A deployment tranche small enough that the pool each row grows to is the envelope's and not
        // this one's: the envelope's smallest pool in TOKENS is at its dearest peg, where a fixed dollar
        // value is the fewest of them, and a tranche left at a realistic size would exceed it.
        setUp_collateral(1e-8 ether, 1e-8 ether, address(this));
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
        vm.startPrank(owner());
        IHarborRoles(minter).grantRoles(address(this), zeroFeeRole);
        vm.stopPrank();

        file = openFile(
            "minter_overflow_boundary",
            sa(
                "peg price in dollars",
                "anchor supply (wei)",
                "oracle collateral price",
                "collateral ratio",
                "sail supply the search reached (wei)",
                "mintAnchor",
                "mintAnchorWithFeeCap",
                "redeemAnchor",
                "mintSail",
                "redeemSail",
                "freeMintAnchor",
                "freeRedeemAnchorForCollateral",
                "freeRedeemAnchorForSail",
                "freeMintSail",
                "freeRedeemSail"
            )
        );
    }

    /// @dev Every external way in and out of the minter, each offered the largest input its caller could
    ///      legitimately make. For a redeem that is the caller's whole holding, which here is the whole
    ///      supply - the corner where one holder owns everything, the same corner the stability pool's
    ///      envelope pins with a single depositor. For a mint it is collateral matching what already backs
    ///      the market, a deposit that doubles it. Read fresh at each probe, because the market being
    ///      probed is a different one at every rung.
    ///
    ///      Encoded by signature rather than by `abi.encodeCall` because two of these are overloads of one
    ///      name, which a typed encoding cannot name apart. The cost of that is a mistyped signature
    ///      reading as a refusal, which is exactly what the nominal-market test forbids.
    function _entryPointCalls() private view returns (bytes[] memory calls) {
        address me = address(this);
        uint256 collateralIn = IERC20(wrappedCollateralToken).balanceOf(minter);
        uint256 anchorIn = IERC20(peggedToken).balanceOf(me);
        uint256 sailIn = IERC20(leveragedToken).balanceOf(me);

        calls = new bytes[](10);
        calls[0] = abi.encodeWithSignature("mintPeggedToken(uint256,address,uint256)", collateralIn, me, 0);
        // The fee cap opened to 100%, so this differs from the plain mint above only in the band walk it
        // takes to honour a cap - which is the arithmetic being probed - and never in being refused one.
        calls[1] = abi.encodeWithSignature(
            "mintPeggedToken(uint256,address,uint256,uint256)",
            collateralIn,
            me,
            0,
            1 ether
        );
        calls[2] = abi.encodeWithSignature("redeemPeggedToken(uint256,address,uint256)", anchorIn, me, 0);
        calls[3] = abi.encodeWithSignature("mintLeveragedToken(uint256,address,uint256)", collateralIn, me, 0);
        calls[4] = abi.encodeWithSignature("redeemLeveragedToken(uint256,address,uint256)", sailIn, me, 0);
        calls[5] = abi.encodeWithSignature("freeMintPeggedToken(uint256,address)", collateralIn, me);
        calls[6] = abi.encodeWithSignature("freeRedeemPeggedToken(uint256,uint256,address)", anchorIn, 0, me);
        // The conversion leg: anchor given up for sail, which is what a rebalance calls and what the
        // bound this whole investigation is about sits inside.
        calls[7] = abi.encodeWithSignature("freeRedeemPeggedToken(uint256,uint256,address)", 0, anchorIn, me);
        calls[8] = abi.encodeWithSignature("freeMintLeveragedToken(uint256,address)", collateralIn, me);
        calls[9] = abi.encodeWithSignature("freeRedeemLeveragedToken(uint256,address)", sailIn, me);
    }

    /// @dev Make one external call and say how it ended, leaving no trace of it behind.
    function _probe(bytes memory callData) private returns (bool overflowed, string memory reason) {
        uint256 snapshot = vm.snapshotState();
        // solhint-disable-next-line avoid-low-level-calls
        (bool succeeded, bytes memory returned) = minter.call(callData);
        vm.revertToStateAndDelete(snapshot);
        if (succeeded) {
            return (false, "ok");
        }
        return (_isPanic(returned, PANIC_ARITHMETIC_OVERFLOW), _revertReason(returned));
    }

    /// @dev Give the market backing until it reports `targetRatio`, taking nothing in return. Permissionless
    ///      and, unlike a sail mint, possible at any collateral ratio: sail is a claim on the residual, so
    ///      a market with none to sell cannot mint any, which is exactly the market that needs raising.
    ///
    ///      The wrapped-to-underlying rate is held at one throughout, so the wrapped collateral this gives
    ///      and the underlying the record counts are the same number.
    function _donateToCollateralRatio(uint256 targetRatio) private {
        (uint256 oraclePrice, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        uint256 needed = Math.mulDiv(targetRatio, IMinter(minter).peggedTokenBalance(), oraclePrice);
        uint256 held = IMinter(minter).collateralTokenBalance();
        if (needed > held) {
            IMinter_v3(minter).donateWrappedCollateral(needed - held);
        }
    }

    /// @dev Stand up a market holding the envelope's largest pool at `pegPriceUSD`, and report the anchor
    ///      supply it reached. The anchor count and the oracle price both follow from the peg: a pool of a
    ///      fixed dollar value is more tokens when each is worth less, and a collateral token is worth more
    ///      of them.
    ///
    ///      The price is moved before the market is grown, which leaves the tranche the deployment minted
    ///      either far over- or far under-collateralised - eighteen orders of magnitude of price have to go
    ///      somewhere. So the backing is restored by donation first, which an anchor mint needs (it mints
    ///      at `min(1, collateral ratio)`, so minting into an insolvent market mints a multiple of what was
    ///      asked for), and again afterwards, because minting anchor against its own backing pulls the
    ///      collateral ratio towards one.
    function _buildMarketAtPeg(uint256 pegPriceUSD) private returns (uint256 anchorSupply) {
        uint256 oraclePrice = Math.mulDiv(MAX_COLLATERAL_USD, 1 ether, pegPriceUSD);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(oraclePrice, WRAP_RATE);
        deal(address(wrappedCollateralToken), address(this), type(uint128).max);

        _donateToCollateralRatio(BUILD_COLLATERAL_RATIO);
        uint256 target = Math.mulDiv(MAX_POOL_VALUE_USD, 1 ether, pegPriceUSD);
        uint256 held = IMinter(minter).peggedTokenBalance();
        if (target > held) {
            // The collateral that mints the shortfall, where one wrapped token is worth `oraclePrice`
            // times the rate in pegged, and the anchor it buys is priced at one.
            IMinter_v3(minter).freeMintPeggedToken(
                Math.mulDiv(target - held, 1 ether * 1 ether, oraclePrice * WRAP_RATE),
                address(this)
            );
        }
        _donateToCollateralRatio(BUILD_COLLATERAL_RATIO);

        anchorSupply = IMinter(minter).peggedTokenBalance();
        assertApproxEqRel(
            IMinter(minter).collateralRatio(),
            BUILD_COLLATERAL_RATIO,
            0.001 ether,
            "every row must measure the same market shape, or the rows are not comparable"
        );
    }

    /// @dev The largest sail supply each entry point survives, walking a power-of-two ladder and probing
    ///      every entry point at every rung. A ladder rather than a bisection per entry point: it needs no
    ///      assumption that the outcome is monotone in the supply, it answers all ten in one pass, and its
    ///      resolution - a factor of two - is a fixed small distance on the logarithmic axis this is drawn
    ///      on. `NaN` where a column was never shown a boundary, which gnuplot leaves as a gap rather than
    ///      drawing a zero that would read as a measurement.
    function _sailSupplyCeilings() private returns (int256[] memory ceilings) {
        bytes[] memory probeCalls = _entryPointCalls();
        ceilings = new int256[](probeCalls.length);
        for (uint256 i = 0; i < ceilings.length; i++) {
            ceilings[i] = NaN;
        }

        uint256 remaining = ceilings.length;
        for (uint256 rung = 0; rung <= TOP_RUNG && remaining > 0; rung++) {
            uint256 sailSupply = uint256(1) << rung;
            uint256 snapshot = vm.snapshotState();
            deal(address(leveragedToken), address(this), sailSupply, true);

            probeCalls = _entryPointCalls();
            for (uint256 i = 0; i < probeCalls.length; i++) {
                if (ceilings[i] != NaN) {
                    continue; // this one has already been shown its boundary
                }
                (bool overflowed, ) = _probe(probeCalls[i]);
                if (overflowed) {
                    // The rung below is the last that held; at the bottom rung nothing held.
                    ceilings[i] = rung == 0 ? int256(0) : int256(uint256(1) << (rung - 1));
                    remaining--;
                }
            }

            vm.revertToStateAndDelete(snapshot);
        }
    }

    /// @notice A market holding as much sail as anchor can convert anchor into sail.
    ///
    /// That market shape is unremarkable - a sail token is a claim on the residual, so a market normally
    /// carries many more sail than anchor, and one sail per anchor is at the thin end of ordinary. Every
    /// other operation on sail survives it with eight-fold room to spare at the same market.
    ///
    /// The conversion has no business being the exception, because its arithmetic carries no term the
    /// others lack: the collateral value it divides by is the same collateral value its rate is built
    /// from, so the two cancel. What it multiplies by instead is the leverage ratio, which is where the
    /// cancellation is lost and a product of the anchor being converted with the whole sail supply is
    /// formed in its place.
    ///
    /// Measured at the envelope's cheapest peg, where the anchor count and the collateral price are both
    /// at their largest - which is one corner, not two, because a pool of a fixed dollar value is more
    /// tokens exactly when each collateral token is worth more of them.
    function test_aMarketWithAsMuchSailAsAnchorCanConvert() public {
        uint256 anchorSupply = _buildMarketAtPeg(1e-12 ether);
        deal(address(leveragedToken), address(this), anchorSupply, true);

        (bool overflowed, string memory reason) = _probe(
            abi.encodeWithSignature(
                "freeRedeemPeggedToken(uint256,uint256,address)",
                0,
                IERC20(peggedToken).balanceOf(address(this)),
                address(this)
            )
        );
        assertFalse(overflowed, "converting anchor to sail overflowed at a market holding one sail per anchor");
        assertEq(reason, "ok", "the conversion must be available, not merely free of overflow");
    }

    /// @notice Every external way in and out of the minter works at an ordinary market. Nothing below is
    /// worth reading without this: a search that reports where calls stop working can only be trusted if
    /// the calls were working to begin with, and a mistyped signature, an ungranted role or a missing
    /// approval would otherwise come back as a boundary at the very first rung.
    function test_everyEntryPointWorksAtAnOrdinaryMarket() public {
        deal(address(wrappedCollateralToken), address(this), 1000 ether);
        bytes[] memory probeCalls = _entryPointCalls();
        for (uint256 i = 0; i < probeCalls.length; i++) {
            (bool overflowed, string memory reason) = _probe(probeCalls[i]);
            assertFalse(overflowed, string.concat("entry point ", vm.toString(i), " overflowed at an ordinary market"));
            assertEq(reason, "ok", string.concat("entry point ", vm.toString(i), " was refused at an ordinary market"));
        }
    }

    /// @notice The sail supply each entry point stops working at, across the envelope's declared range of
    /// peg prices. The peg decides both the anchor count and the oracle price, so this is the boundary in
    /// the one variable a director does not choose - the relationship between the supplies and the price
    /// that a market arrives at rather than declares.
    function test_whereTheArithmeticStops() public {
        uint256[] memory pegPrices = _pegPrices();
        uint8[] memory decimals = new uint8[](15);
        decimals[0] = 18; // peg price in dollars
        decimals[1] = 0; // anchor supply, a count of wei
        decimals[2] = 18; // oracle collateral price
        decimals[3] = 18; // collateral ratio
        for (uint256 i = 4; i < decimals.length; i++) {
            decimals[i] = 0; // the search's reach and the ceilings, all counts of wei
        }

        for (uint256 p = 0; p < pegPrices.length; p++) {
            uint256 snapshot = vm.snapshotState();

            uint256 anchorSupply = _buildMarketAtPeg(pegPrices[p]);
            (uint256 oraclePrice, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
            int256[] memory ceilings = _sailSupplyCeilings();

            int256[] memory row = new int256[](15);
            row[0] = int256(pegPrices[p]);
            row[1] = int256(anchorSupply);
            row[2] = int256(oraclePrice);
            row[3] = int256(IMinter(minter).collateralRatio());
            // How far the ladder climbed, so a column with no boundary in it can be drawn as the bound it
            // actually is - the search looked this far and found nothing - rather than as a blank that
            // reads the same as a broken plot.
            row[4] = int256(uint256(1) << TOP_RUNG);
            for (uint256 i = 0; i < ceilings.length; i++) {
                row[5 + i] = ceilings[i];
            }
            writeLine(file, row, decimals);

            vm.revertToStateAndDelete(snapshot);
        }
        vm.closeFile(file);
    }
}
