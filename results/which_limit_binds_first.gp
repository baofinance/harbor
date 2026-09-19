set title "which_limit_binds_first.gp" noenhanced
datafile = "which_limit_binds_first.csv"
set datafile separator comma
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'which_limit_binds_first.png'" which_limit_binds_first.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'which_limit_binds_first.pdf'" which_limit_binds_first.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 700 620 background rgb "gray90" }

# WHICH LIMIT ACTUALLY BINDS, all four in sail, at one distressed collateral ratio, against the size of
# the stability pools.
#
# `maxLiquidationReward` and a supply-relative conversion bound limit the same quantity - the sail handed
# to the leveraged pool in one event - so they can be compared directly, and the document's position
# rests on the comparison: section 9 says not to rely on the conversion bound to limit issuance, because
# `maxLiquidationReward` already bounds what the pool's accounting can absorb.
#
# It does, and by a margin that makes it irrelevant. It sits THIRTEEN TO SIXTEEN ORDERS OF MAGNITUDE
# above what a
# fair conversion asks for, because it is the reward integral's field width rather than a chosen number -
# a guard against arithmetic overflowing, not against a market issuing too much. A quantity that large
# cannot be the economic limit on anything.
#
# So if issuance per event is to be limited at all, the conversion bound is the only instrument there is,
# and the note not to rely on it leaves nothing else to rely on. Both candidate values of a
# supply-relative bound bind hard on the same rebalance - thirty times below the ask at 0.25, eight times
# at 1 - which is the scale at which a limit is a limit.
#
# The consequence for the bound's shape is the point of the graph. A bound that binds while paying for
# only part of what it takes is unfair by construction, and this shows the bound does bind. The two can
# only both hold - a limit on issuance AND an exchange that returns what it took - if the bound reduces
# the anchor taken alongside the sail paid, leaving the remainder for the next rebalance.
#
# The vertical axis spans nineteen orders of magnitude, and the four lines on it seventeen. That is not a
# presentational choice; it is the finding.

set logscale x
set xrange [0.0015:1.2]
set xlabel "stability pool anchor holdings, as a share of the anchor outstanding"
set xtics ("0.2%%" 0.002, "1%%" 0.01, "5%%" 0.05, "10%%" 0.1, "50%%" 0.5, "100%%" 1)
set logscale y
set yrange [100000:1e24]
set ylabel "sail"
set ytics ("500k" 500000, "2M" 2000000, "15M" 15333333, "1e20" 1e20, "1e23" 1e23)
set grid xtics ytics
set key at graph 0.98, graph 0.40 right reverse Left noenhanced
set colorsequence default

# $1 = pool share, $2 = fair wants, $3 = maxLiquidationReward, $4 = bound at 0.25, $5 = bound at 1
plot \
     datafile using ($1):($3) with linespoints linewidth 2 pointtype 7 pointsize 0.6 linetype 8 \
         title "maxLiquidationReward - the pool's reward ceiling", \
     datafile using ($1):($2) with lines linewidth 3 linetype 2 \
         title "what a fair conversion asks for", \
     datafile using ($1):($5) with lines linewidth 2 linetype 7 \
         title "a supply-relative bound at 1", \
     datafile using ($1):($4) with lines linewidth 2 linetype 4 \
         title "a supply-relative bound at 0.25"
