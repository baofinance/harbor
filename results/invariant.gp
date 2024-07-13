datafile = "invariant.csv"
set datafile separator comma
set key autotitle columnheader noenhanced below
set terminal svg enhanced size 500 300 background rgb "gray90"
#set terminal pngcairo size 500 300
set autoscale
set ylabel "Pegged NAV / Leveraged NAV"
set yrange [-1:2]
set ytics nomirror

set y2label "Collateral NAV / Leverage Ratio"
set y2range [-1:1700]
set y2tics 500
max_value = 20000

set colorsequence default
plot \
     datafile using ($1):($3) axes x1y1 with lines linewidth 1 linetype 2, \
     datafile using ($1):($4) axes x1y1 with lines linewidth 1 linetype 4, \
     datafile using ($1):(($2 > max_value) ? max_value : $2) axes x1y2 with lines linewidth 1 linetype 1, \
     datafile using ($1):($5) axes x1y2 with lines linewidth 1 linetype 6
