datafile = "liquidate_partial_both62.csv"
datafileto = "liquidate_to_partial_both62.csv"
set datafile separator comma

set key autotitle columnheader noenhanced below title " "
set terminal svg enhanced size 700 600 background rgb "gray90"
# set terminal pdf background rgb "gray90"
# set output "liquidate_to_partial_both.pdf"
set autoscale
set xlabel "Collateral Ratio (driven by collateral price)"
set xrange [0:1.6]
set yrange [0:25]
set y2range [0:100000]

set ytics nomirror
set y2tics 50000

set ylabel "Collateral Ratio / Collateral token balance"
set y2label "Pegged/Leveraged token balance"
depeg = 1
set arrow from depeg, graph 0 to depeg, graph 1 nohead linetype 1 dashtype 2 linecolor"red"
set label "  de-peg" at depeg, 0.2 left textcolor "red"

set colorsequence default
plot \
     datafile using ($1):($2) axes x1y1 with lines linewidth 1 linetype 1 dashtype 2, \
     datafile using ($1):($3) axes x1y1 with lines linewidth 1 linetype 1, \
     datafile using ($1):($5) axes x1y2 with lines linewidth 1 linetype 8 dashtype 3, \
     datafile using ($1):($7) axes x1y2 with lines linewidth 1 linetype 4 dashtype 3, \
     datafile using ($1):($9) axes x1y2 with lines linewidth 1 linetype 6 dashtype 3, \
     datafileto using ($1):($3) axes x1y1 with lines linewidth 1 linetype 4, \
     datafileto using ($1):($5) axes x1y2 with lines linewidth 1 linetype 6, \
     datafileto using ($1):($7) axes x1y1 with lines linewidth 1 linetype 8, \
     datafileto using ($1):($2) axes x1y1 with lines linewidth 3 linetype 8 dashtype 4, \
     datafileto using ($1):($4) axes x1y2 with lines linewidth 3 linetype 4 dashtype 4

    #  datafile using ($1):($4) axes x1y2 with lines linewidth 1 linetype 8 dashtype 2, \
    #  datafile using ($1):($6) axes x1y2 with lines linewidth 1 linetype 4 dashtype 2, \
    #  datafile using ($1):($8) axes x1y2 with lines linewidth 1 linetype 6 dashtype 2, \

unset output