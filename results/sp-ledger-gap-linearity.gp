datafile = "sp-ledger-gap-linearity.csv"
set datafile separator comma
set key autotitle columnheader noenhanced below title " "
set terminal svg enhanced size 700 600 background rgb "gray90"

# Whether the gap accumulates with the number of balance-store events. The per-event term is at most
# one wei, so a drift that grows with events would show as a rising line; a drift that does not is the
# self-correcting loss term instead.
set autoscale
set grid

set xlabel "balance store events"
set ylabel "gap drift from start (wei)"

set colorsequence default
plot \
     datafile using ($1):($2) with linespoints linewidth 2 pointtype 7 linetype 1
