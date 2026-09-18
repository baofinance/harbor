datafile = "rebalance_fairness_timeline.csv"
set datafile separator comma
# Written by hand; `test_timelineWithCompounding` in test/deployment/RebalanceFairnessScan.t.sol
# writes only the CSV, which this finds by the matching basename.
#
# THE SAME FOUR POSITIONS FOLLOWED WEEK BY WEEK rather than reduced to a single income figure, so the
# gap can be seen opening rather than inferred from one number. Each week: Eve mints leveraged to
# recover the collateral ratio, the Minter harvests, then Alice and Charlie compound - claim their
# wrappedCollateral, freeMint haXXX with it, re-deposit. Charlie's hsXXX rebalance reward is left
# unclaimed throughout, so it shows up as claimable rather than as position.
#
# Two runs are overlaid: no fee, and a 10% fee on Bob's and Dave's withdrawal. The 10% is a literal
# here and in the captions; it is not read from the CSV, so a different fee pair in the test leaves
# these stale.
#
# The x-range runs to TOTAL_WEEKS in that test.
#
# CSV columns: 1=Fee_pct, 2=Week, 3=Alice_haXXX_eq, 4=Bob_haXXX_eq,
#   5=Charlie_haXXX_eq, 6=Dave_haXXX_eq
#
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'rebalance_fairness_timeline.png'" rebalance_fairness_timeline.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'rebalance_fairness_timeline.pdf'" rebalance_fairness_timeline.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 1400 500 background rgb "gray90" }

set bmargin 7
set key below spacing 1.3
set grid

set multiplot layout 1,2 title 'haXXX-Equivalent Position Over Time (weekly compound)'

# The fee column selects which run a row belongs to; 1/0 is gnuplot's undefined value, so a row from
# the other run contributes no point and the two lines stay separate.
set xlabel 'Week'
set ylabel 'haXXX-equivalent'
set title 'Collateral StabilityPool: Alice (stayer) vs Bob (returner)'
set xrange [0:12]
set yrange [*:*]
plot \
     datafile using 2:($1 == 0 ? $3 : 1/0) with linespoints linewidth 2 title 'Alice (no fee)', \
     datafile using 2:($1 == 0 ? $4 : 1/0) with linespoints linewidth 2 title 'Bob (no fee)', \
     datafile using 2:($1 == 10 ? $3 : 1/0) with linespoints linewidth 2 dashtype 2 \
         title 'Alice (10% fee)', \
     datafile using 2:($1 == 10 ? $4 : 1/0) with linespoints linewidth 2 dashtype 2 \
         title 'Bob (10% fee)'

set title 'Leveraged StabilityPool: Charlie (stayer) vs Dave (returner)'
plot \
     datafile using 2:($1 == 0 ? $5 : 1/0) with linespoints linewidth 2 title 'Charlie (no fee)', \
     datafile using 2:($1 == 0 ? $6 : 1/0) with linespoints linewidth 2 title 'Dave (no fee)', \
     datafile using 2:($1 == 10 ? $5 : 1/0) with linespoints linewidth 2 dashtype 2 \
         title 'Charlie (10% fee)', \
     datafile using 2:($1 == 10 ? $6 : 1/0) with linespoints linewidth 2 dashtype 2 \
         title 'Dave (10% fee)'

unset multiplot
