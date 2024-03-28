datafile = "fees.csv"
set datafile separator comma
set key autotitle columnheader noenhanced
set terminal svg enhanced size 600 400 background rgb "gray90"
set autoscale
set colorsequence default
plot datafile using ($2):($3) with lines linetype 2