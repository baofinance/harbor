datafile = "fees.csv"
datafile1 = "fees1.csv"
set datafile separator comma
set key autotitle columnheader noenhanced
set terminal svg enhanced size 600 400 background rgb "gray90"
set autoscale
set colorsequence default
plot datafile using ($2):($3) with lines linewidth 2 linetype 1, \
     datafile1 using ($2):($3) with points pointtype 1 linetype 2
