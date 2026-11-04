set title "anchor_mint_divergence.gp" noenhanced
byprice = "anchor_mint_divergence.csv"
byrate = "anchor_mint_divergence_by_rate.csv"
bybacking = "anchor_mint_divergence_by_backing.csv"
set datafile separator comma
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'anchor_mint_divergence.png'" anchor_mint_divergence.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'anchor_mint_divergence.pdf'" anchor_mint_divergence.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 700 700 background rgb "gray90" }

# The anchor is priced at min(1, collateral ratio) and the mint divides by that price, so a unit of
# collateral value buys 1/(collateral ratio) of anchor and that grows without bound as the collateral
# ratio falls. It is the same shape as the sail conversion's 1/(collateral ratio - 1), at the other
# singularity - which is why one bound can be chosen for both.
#
# THE THREE SWEEPS REACH THE SAME COLLATERAL RATIOS BY DIFFERENT ROUTES, and that is the graph's point. A
# collateral ratio can fall because the underlying collateral is worth less, because the
# wrapped-to-underlying rate has fallen, or because the collateral is no longer held at all.
#
# The mispricing per unit of value does not care which: all three sweeps produce the same
# 1/(collateral ratio) line, so only one is drawn.
#
# The SUPPLY MULTIPLIER does care, and this is the finding. A fall in the underlying price or in the
# wrapped-to-underlying rate reduces what a
# depositor's own collateral is worth by exactly the factor it reduces the backing by, so the anchor a
# deposit buys is unchanged and the supply grows by the same 5% at every collateral ratio. Collateral
# that is GONE does not reduce what the depositor holds, so the same deposit buys the whole depleted
# market: a fiftyfold supply increase at a collateral ratio of 0.002, and unbounded below it.
#
# So a bound keyed on the collateral ratio alone would refuse the mint in all three cases when only the
# third is dangerous. Both axes are logarithmic: these are 1/x relationships, which a log-log axis draws
# as straight lines, and their slopes are then readable as the powers they are.
#
# The shipped anchor floor - refuse below the price the protocol can report - engages at a collateral ratio of
# 1e-18, fifteen orders of magnitude to the left of this axis. What is drawn here is the approach to it.

set logscale x
set logscale y
set xrange [0.0015:2]
set xlabel "collateral ratio"
set xtics ("0.002" 0.002, "0.01" 0.01, "0.1" 0.1, "0.5" 0.5, "1" 1, "1.6" 1.6)
set yrange [0.8:700]
set ylabel "multiple (anchor per unit of value; supply after over supply before)"
set ytics ("1" 1, "2" 2, "5" 5, "10" 10, "50" 50, "100" 100, "500" 500)
set grid xtics ytics
# Below the plot: the two flat lines sit where a key inside it would have to go, and they are the ones
# that most need identifying.
set key below title " " maxcols 1 reverse Left noenhanced

# A deposit that buys anchor worth what it gave up, and a supply that does not grow.
set arrow from graph 0, first 1 to graph 1, first 1 nohead dashtype 2 linecolor rgb "gray40"

set colorsequence default
# $1 = collateral ratio, $2 = anchor price, $3 = anchor per unit of collateral value, $4 = multiplier
plot \
     byprice using ($1):($3) with lines linewidth 2 linetype 2 \
         title "anchor minted per unit of collateral value (all three sweeps)", \
     bybacking using ($1):($4) with lines linewidth 2 linetype 7 \
         title "supply multiplier - collateral no longer held", \
     byrate using ($1):($4) with lines linewidth 2 linetype 4 \
         title "supply multiplier - wrapped-to-underlying rate fallen", \
     byprice using ($1):($4) with lines linewidth 2 dashtype 2 linetype 1 \
         title "supply multiplier - underlying collateral repriced"
