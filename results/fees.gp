datafile = "fees.csv"
#datafile1 = "fees.good.csv"
set datafile separator comma
set key autotitle columnheader noenhanced below
set terminal svg enhanced size 500 300 background rgb "gray90"
#set terminal pngcairo size 500 300
set autoscale
set yrange [-0.02:0.02]

set colorsequence default
plot datafile using ($2):($3) with lines linewidth 2 dashtype 2 linetype 1, \
     datafile using ($2):($4) with lines linewidth 2 dashtype 2 linetype 2, \
     datafile using ($2):($5) with lines linewidth 1 linetype 4, \
     datafile using ($2):($6) with lines linewidth 1 linetype 6
#     datafile1 using ($2):($3) with points pointtype 1 linetype 2
