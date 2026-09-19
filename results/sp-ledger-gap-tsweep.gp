set title "sp-ledger-gap-tsweep.gp" noenhanced
datafile = "sp-ledger-gap-tsweep.csv"
set datafile separator comma
set key noenhanced below title " "
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'sp-ledger-gap-tsweep.png'" sp-ledger-gap-tsweep.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'sp-ledger-gap-tsweep.pdf'" sp-ledger-gap-tsweep.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 700 600 background rgb "gray90" }

# Gap against baseline supply under the two loss patterns: one maximum-headroom loss, and many small
# losses (error-queue churn). The pattern is a text column, so each series is filtered out of the one
# file rather than living in its own column.
#
# The gap is drawn as a fraction of the bound it must stay within, not as an absolute, for two
# reasons: the sweep's claim is exactly that the fraction never exceeds 1, and a maximum-headroom loss
# produces a gap of precisely zero at every supply - which a logarithmic absolute axis cannot draw at
# all, and which would leave that series silently missing.
set logscale x
set format x "10^{%L}"
set grid
set yrange [0:1.2]

set xlabel "baseline supply t (wei)"
set ylabel "gap as a fraction of its bound"

set y2label "bound (wei)"
set logscale y2
set format y2 "10^{%L}"
set ytics nomirror
set y2tics

maxLoss = "< awk -F, 'NR>1 && $2==\"maxLoss\"' sp-ledger-gap-tsweep.csv"
manySmall = "< awk -F, 'NR>1 && $2==\"manySmall\"' sp-ledger-gap-tsweep.csv"

set arrow from graph 0, first 1 to graph 1, first 1 nohead linetype 1 dashtype 2 linecolor "red"
set label "  bound" at graph 0.01, first 1.06 left textcolor "red"

set colorsequence default
plot \
     maxLoss using ($1):($3/$4) axes x1y1 with linespoints linewidth 2 pointtype 7 linetype 1 \
        title "gap / bound, one maximum loss", \
     manySmall using ($1):($3/$4) axes x1y1 with linespoints linewidth 2 pointtype 5 linetype 2 \
        title "gap / bound, many small losses", \
     maxLoss using ($1):($4) axes x1y2 with lines linewidth 1 dashtype 3 linetype 4 \
        title "bound magnitude (right axis)"
