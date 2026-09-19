datafile = "rebalance_fairness_scan.csv"
set datafile separator comma
# Written by hand; `test_fairnessGapScan` in test/deployment/RebalanceFairnessScan.t.sol writes only
# the CSV, which this finds by the matching basename.
#
# THE GAP BETWEEN SITTING THROUGH A REBALANCE AND DODGING IT, swept across price drop and leveraged
# fraction. Income gap = (returner_weekly_$ - stayer_weekly_$) / returner_weekly_$ * 100, where
# weekly_$ = (totalDollars_after_2_weeks - totalDollars_before) / 2. That captures harvest income plus
# the wrappedCollateral appreciation on unclaimed rebalance rewards.
#
# A 0% gap means the stayer earns what the returner does, which is fair. A 37.5% gap at 37.5%
# liquidation means the stayer earns 37.5% less per week for having stayed.
#
# CSV columns: 1=PriceDrop_pct, 2=Lev_pct, 3=LiquidFrac_pct,
#   4=Alice_coll_weekly_$, 5=Bob_coll_weekly_$, 6=Coll_gap_pct,
#   7=Charlie_lev_weekly_$, 8=Dave_lev_weekly_$, 9=Lev_gap_pct
#
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'rebalance_fairness_scan.png'" rebalance_fairness_scan.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'rebalance_fairness_scan.pdf'" rebalance_fairness_scan.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 1400 500 background rgb "gray90" }

set bmargin 7
set key below spacing 1.3
set grid

set multiplot layout 1,2 title 'rebalance_fairness_scan.gp - Scenario B (dodge attack)' noenhanced

# ------- every scanned point, because the gap turns on liquidation fraction alone, not on leveraged %
set xlabel 'Liquidation fraction (%)'
set ylabel 'Income gap (%)'
set title 'Stayer vs returner: $ income gap'
set xrange [0:100]
set yrange [0:100]
plot \
     datafile using 3:6 with points pointtype 7 pointsize 1.2 title 'Collateral StabilityPool gap', \
     datafile using 3:9 with points pointtype 5 pointsize 1.2 title 'Leveraged StabilityPool gap'

# ------------------- one slice of that sweep, at the 25% leveraged the fee scan uses as its design
# case. 1/0 is gnuplot's undefined value, so rows at any other leveraged fraction are dropped.
set title 'Weekly $ income (leveraged=25%, APR=10%)'
set ylabel 'Weekly income ($)'
set xrange [0:100]
set yrange [0:*]
plot \
     datafile using 3:($2 == 25 ? $4 : 1/0) with linespoints title 'Alice (Collateral stayer)', \
     datafile using 3:($2 == 25 ? $5 : 1/0) with linespoints title 'Bob (Collateral returner)', \
     datafile using 3:($2 == 25 ? $7 : 1/0) with linespoints title 'Charlie (Leveraged stayer)', \
     datafile using 3:($2 == 25 ? $8 : 1/0) with linespoints title 'Dave (Leveraged returner)'

unset multiplot
