datafile = "reward.csv"
set datafile separator comma

set key autotitle columnheader noenhanced below title " "
set terminal svg enhanced size 600 400 background rgb "gray90"
# set terminal pdf background rgb "gray90"
# set output "reward.pdf"
set autoscale
set xlabel "Time (days)"
set xrange [0:13]
set xtics 1

set yrange [-0.1:3.1]
# set ytics nomirror
# set y2tics 50000

# set ylabel "Collateral Ratio / Collateral token balance"
# set y2label "Pegged/Leveraged token balance"
deposit = 1
set arrow from deposit, graph 0 to deposit, graph 1 nohead linetype 1 dashtype 2 linecolor"blue"
set label "  depositReward(1)" at deposit, 2.5 left textcolor "blue"
deposit = 8
set arrow from deposit, graph 0 to deposit, graph 1 nohead linetype 1 dashtype 2 linecolor"blue"
set label "  end period" at deposit, 2.5 left textcolor "blue"
deposit = 4
set arrow from deposit, graph 0 to deposit, graph 1 nohead linetype 1 dashtype 2 linecolor"black"
set label "  depositReward(2)" at deposit, 2.3 left textcolor "black"
deposit = 11
set arrow from deposit, graph 0 to deposit, graph 1 nohead linetype 1 dashtype 2 linecolor"black"
set label "  end period" at deposit, 2.3 left textcolor "black"

set colorsequence default
plot \
     datafile using ($1):($2) axes x1y1 with lines linewidth 2 linetype 2 dashtype 2, \
     datafile using ($1):($3) axes x1y1 with lines linewidth 1 linetype 4

unset output