datafile = "liquidate_parameters.csv"
set datafile separator comma
set key autotitle columnheader noenhanced below title " "
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'liquidate_parameters.png'" liquidate_parameters.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'liquidate_parameters.pdf'" liquidate_parameters.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 600 500 background rgb "gray90" }

set autoscale
set xlabel "Collateral Ratio (driven by collateral price)"
set xrange [0:1.6]
set yrange [0:30000]

set ylabel "pegged tokens to liquidate"
depeg = 1
set arrow from depeg, graph 0 to depeg, graph 1 nohead linetype 1 dashtype 2 linecolor "red"
set label "  de-peg" at depeg, 0.2 left textcolor "red"

set colorsequence default
plot \
     datafile using ($1):($2) axes x1y1 with lines linewidth 1 linetype 2, \
     datafile using ($1):($3) axes x1y1 with lines linewidth 1 linetype 2 dashtype 3, \
     datafile using ($1):($4) axes x1y1 with lines linewidth 1 linetype 8, \
     datafile using ($1):($5) axes x1y1 with lines linewidth 1 linetype 8 dashtype 3, \
     datafile using ($1):($6) axes x1y1 with lines linewidth 1 linetype 4, \
     datafile using ($1):($7) axes x1y1 with lines linewidth 1 linetype 4 dashtype 3
