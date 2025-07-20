datafile = "reward_claimThroughFullRebalance.csv"
set datafile separator comma

set key autotitle columnheader noenhanced below title " "
set terminal svg enhanced size 650 500 background rgb "gray90"
# set terminal pdf background rgb "gray90"
# set output "reward.pdf"
set autoscale
set xlabel "Time (days)"
set xrange [0:13]
set xtics 1

set ylabel "STEAM amount"
set yrange [-0.2:1.8]
set ytics nomirror

set y2label "Collateral amount"
set y2range [-0.008:0.072]
set y2tics

depositReward = 1
set arrow from depositReward, graph 0 to depositReward, graph 1 nohead linetype 1 dashtype 2 linecolor"blue"
set label "< depositReward(1)" at depositReward, 1.65 left textcolor "blue"
depositReward = 8
set arrow from depositReward, graph 0 to depositReward, graph 1 nohead linetype 1 dashtype 2 linecolor"blue"
set label "< end period" at depositReward, 1.65 left textcolor "blue"
rebalance = 3
set arrow from rebalance, graph 0 to rebalance, graph 1 nohead linetype 1 dashtype 2 linecolor"black"
set label "< rebalance 100%" at rebalance, 1.55 left textcolor "black"
depositInPool = 5
set arrow from depositInPool, graph 0 to depositInPool, graph 1 nohead linetype 1 dashtype 2 linecolor"black"
set label "< deposit x2" at depositInPool, 1.45 left textcolor "black"
rebalance = 7
set arrow from rebalance, graph 0 to rebalance, graph 1 nohead linetype 1 dashtype 2 linecolor"black"
set label "< rebalance 100%" at rebalance, 1.35 left textcolor "black"

set colorsequence default
plot \
     datafile using ($1):($2) axes x1y1 with lines linewidth 1 linetype 1, \
     datafile using ($1):($4) axes x1y1 with lines linewidth 2 linetype 1 dashtype 2, \
     datafile using ($1):($6) axes x1y1 with lines linewidth 2 linetype 1 dashtype 3, \
     datafile using ($1):($3) axes x1y2 with lines linewidth 2 linetype 2, \
     datafile using ($1):($5) axes x1y2 with lines linewidth 2 linetype 2 dashtype 2, \
     datafile using ($1):($7) axes x1y2 with lines linewidth 2 linetype 2 dashtype 3, \
     datafile using ($1):($8) axes x1y1 with lines linewidth 2 linetype 8

unset output