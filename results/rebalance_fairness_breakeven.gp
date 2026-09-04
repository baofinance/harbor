datafile = "rebalance_fairness_breakeven.csv"
set datafile separator comma
set key noenhanced below title " "
set terminal svg enhanced size 700 600 background rgb "gray90"

# The withdrawal fee at which a depositor who leaves and returns ends level with one who stayed, for
# each stability pool. Two cases rather than a curve, so they are bars labelled by pool in column 1.
# Both break-evens are far below a basis point, which is the finding: almost any fee closes the gap.
set style data histograms
set style histogram clustered gap 2
set style fill solid 0.7 border -1
set boxwidth 0.6
set grid ytics
set autoscale

set xlabel "stability pool"
set ylabel "break-even withdrawal fee (%)"

set colorsequence default
plot \
     datafile using ($2):xtic(1) linetype 1 title "break-even fee (%)"
