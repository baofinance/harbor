datafile = "liquidate.csv"
set datafile separator comma
set key autotitle columnheader noenhanced below title " "
set terminal svg enhanced size 600 400 background rgb "gray90"
#set terminal pngcairo size 500 300
set autoscale
set xlabel "Collateral Ratio (driven by collateral price)"
set xrange [0:1.6]

set ylabel "Collateral Ratio after a liquidate"
depeg = 1
set arrow from depeg, graph 0 to depeg, graph 1 nohead linetype 1 dashtype 2 linecolor"red"
set label "  de-peg" at depeg, 0.2 left textcolor "red"

set colorsequence default
plot \
     datafile using ($1):($2) axes x1y1 with lines linewidth 1 linetype 2, \
     datafile using ($1):($3) axes x1y1 with lines linewidth 1 linetype 4, \
     datafile using ($1):($1) axes x1y1 with lines linewidth 1 dashtype 2 linetype 1