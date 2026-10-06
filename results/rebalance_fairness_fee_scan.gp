datafile = "rebalance_fairness_fee_scan.csv"
set datafile separator comma
# Written by hand; `test_withdrawalFeeScan` in test/deployment/RebalanceFairnessScan.t.sol writes only
# the CSV, which this finds by the matching basename.
#
# WHAT A WITHDRAWAL FEE DOES TO THE GAP between someone who sat through a rebalance and someone who
# withdrew before it and came back afterwards. The fee is charged on Bob's and Dave's withdrawn haETH
# and burned rather than redistributed, which is the conservative choice - handing it to the remaining
# depositors would close the gap faster than this shows.
#
# Income gap = (returner_weekly_$ - stayer_weekly_$) / returner_weekly_$ * 100, so 0 is fair.
#
# The design case is a 10% price drop at 25% leveraged, which liquidates 37.5%. The first two figures
# mirror DESIGN_PRICE_DROP and DESIGN_LEVERAGED_PCT in that test and the third is what they produce; change
# either constant and the captions below go stale, because nothing checks them.
#
# CSV columns: 1=Fee_pct, 2=LiquidFrac_pct,
#   3=Alice_coll_weekly_$, 4=Bob_coll_weekly_$, 5=Coll_gap_pct,
#   6=Charlie_lev_weekly_$, 7=Dave_lev_weekly_$, 8=Lev_gap_pct
#
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'rebalance_fairness_fee_scan.png'" rebalance_fairness_fee_scan.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'rebalance_fairness_fee_scan.pdf'" rebalance_fairness_fee_scan.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 1400 500 background rgb "gray90" }

set bmargin 7
set key below spacing 1.3
set grid

set multiplot layout 1,2 title 'rebalance_fairness_fee_scan.gp - design case (10% drop, 37.5% liquidation)' noenhanced

# --------------------------------------------- how far the fee closes the stayer/returner income gap
set xlabel 'Withdrawal fee (%)'
set ylabel 'Income gap (%)'
set title 'Stayer vs returner: income gap'
set xrange [0:*]
set yrange [*:*]
plot \
     datafile using 1:5 with linespoints linewidth 2 title 'Collateral StabilityPool gap', \
     datafile using 1:8 with linespoints linewidth 2 title 'Leveraged StabilityPool gap', \
     0 with lines dashtype 2 linecolor rgb 'gray50' title 'fair (0%)'

# ------------------------------------------------- the four positions the gap above is measured from
set title 'Weekly $ income vs withdrawal fee'
set ylabel 'Weekly income ($)'
set yrange [0:*]
plot \
     datafile using 1:3 with linespoints linewidth 2 title 'Alice (Collateral stayer)', \
     datafile using 1:4 with linespoints linewidth 2 title 'Bob (Collateral returner)', \
     datafile using 1:6 with linespoints linewidth 2 title 'Charlie (Leveraged stayer)', \
     datafile using 1:7 with linespoints linewidth 2 title 'Dave (Leveraged returner)'

unset multiplot
