datafile = "minter_overflow_boundary.csv"
set datafile separator comma
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'minter_overflow_boundary.png'" minter_overflow_boundary.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'minter_overflow_boundary.pdf'" minter_overflow_boundary.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 760 820 background rgb "gray90" }

# How much sail a market can carry before an operation stops working - not returns a wrong answer, stops
# working. The products below multiply a token supply by a price in plain checked arithmetic, so past the
# boundary the call reverts and the operation is simply no longer offered.
#
# Six of the ten external ways in and out of the minter are absent from both panels because they never
# reached a boundary: neither anchor mint, the anchor redeem, the free anchor mint, the free anchor redeem
# for collateral, and - the surprise - the FREE sail mint, none of which overflowed at a sail supply of
# 2^200. Only the four drawn are sensitive to the sail supply at all.
#
# The UPPER panel is the finding. Every market carries more sail than anchor - a sail token is a claim on
# the residual, so there are many of them and each is worth little - and the horizontal line marks equal
# counts. At the envelope's cheapest peg the ANCHOR-TO-SAIL CONVERSION, which is the leg every rebalance
# calls, stops working at a thousandth of that: a market at that corner cannot be rebalanced at all. The
# three other sail paths stop at nine times the anchor supply, which an ordinary market also exceeds.
#
# The LOWER panel is why, and shows the conversion is a different kind of limit from the other three. The
# three follow `2^256 / price` exactly, so their ceiling is a property of the MARKET. The conversion
# follows `2^256 / anchor converted` - its product is the conversion's own input times the sail supply -
# so its ceiling is a property of the TRANSACTION, and the line drawn is for the largest conversion
# possible, the whole anchor supply at once. A rebalance taking a hundredth of the supply has a hundred
# times the headroom, and no headroom at all is reportable from the market's state alone.
#
# Both panels are logarithmic on both axes, over 24 orders of magnitude of peg and 46 of supply, because
# that is the range the declared envelope covers and every one of these quantities is a product.

two256 = 1.1579208923731619542357098500869e77

set grid xtics ytics
set colorsequence default
set lmargin at screen 0.13
set rmargin at screen 0.96

set multiplot title "minter_overflow_boundary.gp" noenhanced

# ─────────────── what a market may carry, against the peg it is written on
set tmargin at screen 0.93
set bmargin at screen 0.64

set logscale x
set logscale y
# Margin either side of the swept range, so neither end of the data sits against the frame.
set xrange [1e-14:1e14]
set xlabel "peg price in dollars"
set format x "10^{%T}"
set yrange [1e-5:1e46]
set ylabel "sail tokens per anchor token the operation survives"
set format y "10^{%T}"
set key at screen 0.5, screen 0.555 center top horizontal maxcols 2 spacing 1.2

# A market with as much sail as anchor. Every market this protocol runs sits above this line, so a
# ceiling below it is a market that cannot operate rather than one with room to grow.
set arrow 1 from graph 0, first 1 to graph 1, first 1 nohead dashtype 2 linecolor rgb "red"
set label 1 "one sail token per anchor token" at graph 0.30, first 0.03 left textcolor "red"

# $1 = peg price, $2 = anchor supply in wei, $8/$9/$12/$14 = the ceilings in wei
plot \
     datafile using 1:($9/$2) with linespoints linewidth 2 linetype 1 pointtype 7 title "redeem sail", \
     datafile using 1:($14/$2) with linespoints linewidth 2 linetype 2 pointtype 6 title "free redeem sail", \
     datafile using 1:($8/$2) with linespoints linewidth 2 linetype 3 pointtype 5 title "mint sail", \
     datafile using 1:($12/$2) with linespoints linewidth 3 linetype 7 pointtype 9 title "convert anchor to sail"

# ─────────────── the products themselves, against the price that appears in them
set tmargin at screen 0.45
set bmargin at screen 0.21

unset arrow 1
unset label 1
set xrange [1e-8:1e20]
set xlabel "oracle collateral price (collateral tokens priced in pegged)"
set yrange [1e35:1e62]
set ylabel "sail supply the operation survives (wei)"
set key at screen 0.5, screen 0.135 center top horizontal maxcols 3 spacing 1.2

# The two ceilings the three market-limited paths actually obey, drawn as the arithmetic rather than as
# the measurement: the price times the supply must fit in a word, and so must the supply times 1e18. The
# second is flat because no price appears in it, which is why the lines level off at a cheap collateral.
plot \
     two256/(x*1e18) with lines dashtype 2 linewidth 1 linecolor rgb "gray30" title "2^{256} / price", \
     two256/1e18 with lines dashtype 3 linewidth 1 linecolor rgb "gray30" title "2^{256} / 10^{18}", \
     datafile using 3:9 with linespoints linewidth 2 linetype 1 pointtype 7 title "redeem sail", \
     datafile using 3:14 with linespoints linewidth 2 linetype 2 pointtype 6 title "free redeem sail", \
     datafile using 3:8 with linespoints linewidth 2 linetype 3 pointtype 5 title "mint sail", \
     datafile using 3:12 with linespoints linewidth 3 linetype 7 pointtype 9 title "convert anchor to sail"

unset multiplot
