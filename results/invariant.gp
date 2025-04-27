datafile = "invariant.csv"
set datafile separator comma
set key autotitle columnheader noenhanced below title " "
set terminal svg enhanced size 600 400 background rgb "gray90"
#set terminal pngcairo size 500 300
set autoscale
set xlabel "Collateral Ratio (driven by collateral price)"
set xrange [0.7:1.6]

set ylabel "Pegged NAV / Leveraged NAV"
set yrange [-1:10]
set ytics nomirror

set y2label "Collateral NAV / Leverage Ratio"
set y2range [-1:1700]
set y2tics 500
max_value = 20000

depeg = 1
set arrow from depeg, graph 0 to depeg, graph 1 nohead linetype 1 dashtype 2 linecolor"red"
set label "de-peg  " at depeg, 2 right textcolor "red"

set colorsequence default
# $1 = Collateral Ratio,
# $2 = Leveraged Ratio,
# $3 = Pegged NAV,
# $4 = Leveraged NAV,
# $5 = Collateral NAV
plot \
     datafile using ($1):($3) axes x1y1 with lines linewidth 1 linetype 2, \
     datafile using ($1):($4) axes x1y1 with lines linewidth 1 linetype 4, \
     datafile using ($1):(($2 > max_value) ? max_value : $2) axes x1y2 with lines linewidth 1 linetype 1 title "> Leverage Ratio", \
     datafile using ($1):($5) axes x1y2 with lines linewidth 1 linetype 6, \
     datafile using ($1):(($2 > 10) ? 10 : $2) axes x1y1 with lines linewidth 1 dashtype 2 linetype 1 title "< Leverage Ratio"
