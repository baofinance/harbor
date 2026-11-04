set title "sp-ledger-gap-linearity.gp" noenhanced
datafile = "sp-ledger-gap-linearity.csv"
set datafile separator comma
set key autotitle columnheader noenhanced below title " "
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'sp-ledger-gap-linearity.png'" sp-ledger-gap-linearity.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'sp-ledger-gap-linearity.pdf'" sp-ledger-gap-linearity.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 700 600 background rgb "gray90" }

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
