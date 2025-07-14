datafile = "liquidate_parameters.csv"
set datafile separator comma
set key autotitle columnheader noenhanced below title " "
set terminal svg enhanced size 600 500 background rgb "gray90"

set autoscale
set xlabel "Collateral Ratio (driven by collateral price)"
set xrange [0:1.6]
set yrange [0:30000]

set ylabel "pegged tokens to liquidate"
depeg = 1
set arrow from depeg, graph 0 to depeg, graph 1 nohead linetype 1 dashtype 2 linecolor "red"
set label "  de-peg" at depeg, 0.2 left textcolor "red"

set colorsequence default
plot \
     datafile using ($1):($2) axes x1y1 with lines linewidth 1 linetype 2, \
     datafile using ($1):($3) axes x1y1 with lines linewidth 1 linetype 2 dashtype 3, \
     datafile using ($1):($4) axes x1y1 with lines linewidth 1 linetype 8, \
     datafile using ($1):($5) axes x1y1 with lines linewidth 1 linetype 8 dashtype 3, \
     datafile using ($1):($6) axes x1y1 with lines linewidth 1 linetype 4, \
     datafile using ($1):($7) axes x1y1 with lines linewidth 1 linetype 4 dashtype 3
