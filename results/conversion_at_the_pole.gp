datafile = "conversion_at_the_pole.csv"
set datafile separator comma
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,760 background rgb 'gray90'; set output 'conversion_at_the_pole.png'" conversion_at_the_pole.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,7 background rgb 'gray90'; set output 'conversion_at_the_pole.pdf'" conversion_at_the_pole.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 780 620 background rgb "gray90" }

# What one anchor token buys, in the last wei of collateral price above the peg.
#
# The x axis is the collateral price measured up from PARITY - the price at which the anchor claim exactly
# exhausts the collateral and the residual the sail is a claim on is zero. It is an integer count of wei
# because that is the real granularity of the thing: one wei of price moves the residual by the entire
# collateral balance, so a market cannot sit closer to the pole than one collateral balance away. The
# collateral ratio is useless as an axis here - it reads 1.000050002500125101 unchanged over the first six
# orders of magnitude of this graph, while the rate below moves by a factor of a million.
#
# TWO THINGS ARE DRAWN and they answer different questions.
#
# The rate is what one anchor token is given. At one wei above parity it is a SEXTILLION sail tokens, and
# it halves with every doubling of the offset - which is the `1/residual` in the pricing, confirmed rather
# than assumed. Nothing in the contract stops it; the only reason it is finite at all is that the price
# below it cannot be finer.
#
# The supply multiple is what that does to everyone already holding sail. One anchor token converted at
# one wei above parity multiplies the whole sail supply by fifty quadrillion, and the multiple is still
# above two at a collateral ratio of 1.00009. A holder is not underpaid at any point on this graph - the
# conversion is fair throughout - they are simply diluted out of existence by the next conversion.
#
# The vertical line is where the REPORTED sail price stops being zero. Below it the protocol issues sail
# against a price that rounds to zero in every external report, which is the exact condition
# MIN_REPORTABLE_ANCHOR_PRICE_E36 refuses to mint the anchor in. The sail has no such rule, and the band
# is nine doublings wide.

set grid xtics ytics
set colorsequence default
set logscale x
set logscale y
set xrange [0.5:1e18]
set yrange [0.5:2e21]
set format x "10^{%T}"
set format y "10^{%T}"
set xlabel "collateral price above parity (wei)"
set ylabel "tokens"
set key bottom left

# The smallest price the protocol can report is one wei of an 18-decimal number, and the first sample at
# or above it is the 1024-wei offset; everything left of this line is issued at a reported price of zero.
set arrow 1 from 1024, graph 0 to 1024, graph 1 nohead dashtype 2 linewidth 2 linecolor rgb "red"
set label 1 "reported sail price is 0 left of here" at 700, 2e10 right rotate by 90 textcolor "red"

# A conversion that leaves the sail supply where it found it.
set arrow 2 from graph 0, first 1 to graph 1, first 1 nohead dashtype 3 linecolor rgb "gray30"

# $1 = price offset in wei, $5 = sail issued for one anchor token, $6 = sail supply multiple
plot \
     datafile using 1:5 with linespoints linewidth 2 linetype 1 pointtype 7 \
         title "sail issued for one anchor token", \
     datafile using 1:6 with linespoints linewidth 2 linetype 7 pointtype 9 \
         title "sail supply multiple after that one conversion"
