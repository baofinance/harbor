datafile = "sp-ledger-gap-miscredit.csv"
set datafile separator comma
set key noenhanced below title " "
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'sp-ledger-gap-miscredit.png'" sp-ledger-gap-miscredit.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'sp-ledger-gap-miscredit.pdf'" sp-ledger-gap-miscredit.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 700 600 background rgb "gray90" }

# Reward conservation across a gap: what was injected against what the books credited, for a stream
# over a positive gap and for one after the gap has been absorbed. Two cases rather than a curve, so
# they are bars labelled by the phase in column 1.
set style data histograms
set style histogram clustered gap 2
set style fill solid 0.7 border -1
set boxwidth 0.9
set grid ytics

set xlabel "phase"
set ylabel "wei"
set logscale y
set format y "10^{%L}"

# The mis-credit is the quantity of interest and is floor-level - a few wei against an injection of
# 5e21 - so a log axis is the only way to show both on one plot.
set colorsequence default
plot \
     datafile using ($3):xtic(1) linetype 1 title "injected", \
     datafile using ($4) linetype 2 title "credited", \
     datafile using ($5) linetype 4 title "mis-credit"
