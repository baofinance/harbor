datafile = "fees.csv"
datafile1 = "fees1.csv"
set datafile separator comma
set key autotitle columnheader noenhanced below title " "
set terminal svg enhanced size 600 600 background rgb "gray90"
#set terminal pngcairo size 500 300
set autoscale
set xlabel "Collateral Ratio (driven by collateral price)"
set xrange [0.6:1.6]
set yrange [-0.01:.02]
max_value = 0.0195 # make it NaN for the lines to disappear

depeg = 1
set arrow from depeg, graph 0 to depeg, graph 1 nohead linetype 1 dashtype 2 linecolor"red"
# set label "  de-peg" at depeg, 0 left textcolor "red"

set colorsequence default
plot datafile using ($2):($3 < 1 ? $3 : max_value) with lines linewidth 1 linetype 1, \
     datafile using ($2):($4 < 1 ? $4 : max_value) with lines linewidth 1 linetype 2, \
     datafile using ($2):($5 < 1 ? $5 : max_value) with lines linewidth 1 linetype 4, \
     datafile using ($2):($6 < 1 ? $6 : max_value) with lines linewidth 1 linetype 6, \
     datafile1 using ($2):($3 < 1 ? $3 : max_value) with lines linewidth 2 dashtype 3 linetype 1, \
     datafile1 using ($2):($4 < 1 ? $4 : max_value) with lines linewidth 2 dashtype 3 linetype 2, \
     datafile1 using ($2):($5 < 1 ? $5 : max_value) with lines linewidth 2 dashtype 3 linetype 4, \
     datafile1 using ($2):($6 < 1 ? $6 : max_value) with lines linewidth 2 dashtype 3 linetype 6


#     datafile1 using ($2):($3) with points pointtype 1 linetype 2
