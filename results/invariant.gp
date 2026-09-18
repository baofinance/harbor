datafile = "invariant.csv"
set datafile separator comma
set key autotitle columnheader noenhanced below title " "
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'invariant.png'" invariant.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'invariant.pdf'" invariant.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 600 600 background rgb "gray90" }
#set terminal pngcairo size 500 300
set autoscale
set xlabel "Collateral Ratio (driven by collateral price)"
set xrange [0.4:1.6]

set ylabel "Pegged NAV / Leveraged NAV"
set yrange [-1:21]
set ytics nomirror

set y2label "Collateral NAV / Leverage Ratio"
set y2range [-1:1700]
set y2tics 500
max_value = 20000

depeg = 1
set arrow from depeg, graph 0 to depeg, graph 1 nohead linetype 1 dashtype 2 linecolor"red"
set label "de-peg  " at depeg, 2 right textcolor "red"

set colorsequence default
# $1 = Collateral Ratio,
# $2 = Leveraged Ratio,
# $3 = Pegged NAV,
# $4 = Leveraged NAV,
# $5 = Collateral NAV
plot \
     datafile using ($1):($3) axes x1y1 with lines linewidth 1 linetype 2, \
     datafile using ($1):($4) axes x1y1 with lines linewidth 1 linetype 4, \
     datafile using ($1):($2) axes x1y2 with lines linewidth 1 linetype 1 title "> Leverage Ratio", \
     datafile using ($1):($5) axes x1y2 with lines linewidth 1 linetype 6, \
     datafile using ($1):($2) axes x1y1 with lines linewidth 1 dashtype 2 linetype 1 title "< Leverage Ratio"
