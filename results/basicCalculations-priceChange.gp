datafile = "basicCalculations-priceChange.csv"
set datafile separator comma
set key autotitle columnheader noenhanced below title " "
set terminal svg enhanced size 600 400 background rgb "gray90"
#set terminal pngcairo size 500 300
set autoscale
set xlabel "Collateral Price"
set xrange [0:4000]

set ylabel "Price / Invariant / CollateralRatio"
set yrange [-1:6]
set ytics nomirror

# set y2label "LeverageRatio"
# set y2range [-20:120]
# set y2tics 20

set colorsequence default
# $4 y1 pegged price
# $6 y1 leveraged price
# $7 y1 invariant
# $8 y1 collateral ratio
# $9 y2 leverage ratio
plot \
    datafile using ($2):($4) axes x1y1 with lines linewidth 2 linetype 2, \
    datafile using ($2):($6) axes x1y1 with lines linewidth 2 linetype 4, \
    datafile using ($2):($7) axes x1y1 with lines linewidth 2 linetype 6, \
    datafile using ($2):($8) axes x1y1 with lines linewidth 3 linetype 8 dashtype 2, \
    datafile using ($2):($9) axes x1y1 with lines linewidth 2 linetype 4 dashtype 2
