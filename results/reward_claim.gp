datafile = "reward_claim.csv"
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
set yrange [-0.2:3.8]
set ytics nomirror

set y2label "distribution rate * 1e6 (/s)"
set y2range [-1:7]
set y2tics

deposit = 1
set arrow from deposit, graph 0 to deposit, graph 1 nohead linetype 1 dashtype 2 linecolor"blue"
set label "< depositReward(1)" at deposit, 3.5 left textcolor "blue"
deposit = 8
set arrow from deposit, graph 0 to deposit, graph 1 nohead linetype 1 dashtype 2 linecolor"blue"
set label "< end period" at deposit, 3.5 left textcolor "blue"
deposit = 4
set arrow from deposit, graph 0 to deposit, graph 1 nohead linetype 1 dashtype 2 linecolor"black"
set label "< depositReward(2)" at deposit, 3.3 left textcolor "black"
deposit = 11
set arrow from deposit, graph 0 to deposit, graph 1 nohead linetype 1 dashtype 2 linecolor"black"
set label "< end period" at deposit, 3.3 left textcolor "black"

set colorsequence default
plot \
     datafile using ($1):($2) axes x1y1 with lines linewidth 1 linetype 1, \
     datafile using ($1):($3) axes x1y1 with lines linewidth 2 linetype 2 dashtype 2, \
     datafile using ($1):($4) axes x1y1 with lines linewidth 1 linetype 4, \
     datafile using ($1):($5) axes x1y1 with lines linewidth 1 linetype 6, \
     datafile using ($1):($6) axes x1y2 with lines linewidth 1 linetype 8, \
     datafile using ($1):($7) axes x1y1 with lines linewidth 2 linetype 8 dashtype 2

unset output