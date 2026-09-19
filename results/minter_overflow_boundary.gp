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
# SEVEN of the ten external ways in and out of the minter reach no boundary at all, and so have no line
# on either panel: both anchor mints, the anchor redeem, the free anchor mint, the free anchor redeem for
# collateral, the free sail mint, and the ANCHOR-TO-SAIL CONVERSION. The grey line is how far the search
# looked, and an absent line means the operation was still working there - a bound, not a blank.
#
# The conversion is the one worth saying out loud, because it is the leg every rebalance calls and it
# touches the sail supply at every step. It is unbounded here because of HOW it is priced: against the
# residual the sail is a claim on, which leaves the supply inside a widened intermediate. Pricing it
# instead against the leverage ratio would carry a collateral value that cancels against the divisor, and
# pay for the detour by multiplying the anchor being converted by the whole sail supply first - a product
# that leaves 256 bits at supplies a market can really hold.
#
# The three that remain are the sail mint and the two sail redeems. The UPPER panel is what they cost.
# Every market carries more sail than anchor - a sail token is a claim on the residual, so there are many
# of them and each is worth little - and the red line marks equal counts. At the envelope's cheapest peg
# these three stop at nine times the anchor supply, which an ordinary market also exceeds.
#
# The LOWER panel is why: they follow `2^256 / price` until the price is cheap enough that the
# price-free `2^256 / 10^18` binds instead, which is the floor the lines level off at. Both are products
# of two pieces of market STATE, so the ceiling is a property of the market and can be declared.
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

# $1 = peg price, $2 = anchor supply in wei, $5 = how far the ladder climbed, $9/$10/$15 = ceilings in wei
plot \
     datafile using 1:($5/$2) with lines linewidth 2 dashtype 2 linecolor rgb "gray40" \
         title "as far as the search looked", \
     datafile using 1:($10/$2) with linespoints linewidth 2 linetype 1 pointtype 7 title "redeem sail", \
     datafile using 1:($15/$2) with linespoints linewidth 2 linetype 2 pointtype 6 title "free redeem sail", \
     datafile using 1:($9/$2) with linespoints linewidth 2 linetype 3 pointtype 5 title "mint sail"

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
     two256/(x*1e18) with lines dashtype 4 linewidth 1 linecolor rgb "gray10" title "2^{256} / price", \
     two256/1e18 with lines dashtype 3 linewidth 1 linecolor rgb "gray10" title "2^{256} / 10^{18}", \
     datafile using 3:5 with lines linewidth 2 dashtype 2 linecolor rgb "gray40" \
         title "as far as the search looked", \
     datafile using 3:10 with linespoints linewidth 2 linetype 1 pointtype 7 title "redeem sail", \
     datafile using 3:15 with linespoints linewidth 2 linetype 2 pointtype 6 title "free redeem sail", \
     datafile using 3:9 with linespoints linewidth 2 linetype 3 pointtype 5 title "mint sail"

unset multiplot
