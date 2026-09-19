set title "liquidate_all_collateral.gp" noenhanced
datafile = "liquidate_all_collateral.csv"
set datafile separator comma
set key autotitle columnheader noenhanced below title " "
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'liquidate_all_collateral.png'" liquidate_all_collateral.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'liquidate_all_collateral.pdf'" liquidate_all_collateral.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 700 600 background rgb "gray90" }
#set terminal pngcairo size 500 300
set autoscale
set xlabel "Collateral Ratio (driven by collateral price)"
set xrange [0:1.6]
set y2range [0:25000]

set ytics nomirror
set y2tics 5000

set ylabel "Collateral Ratio / Leveraged price"
set y2label "Pegged token balance"
depeg = 1
set arrow from depeg, graph 0 to depeg, graph 1 nohead linetype 1 dashtype 2 linecolor"red"
set label "  de-peg" at depeg, 0.2 left textcolor "red"

set colorsequence default
plot \
     datafile using ($1):($2) axes x1y1 with lines linewidth 1 linetype 1 dashtype 2, \
     datafile using ($1):($3) axes x1y1 with lines linewidth 1 linetype 1, \
     datafile using ($1):($4) axes x1y2 with lines linewidth 1 linetype 2 dashtype 2, \
     datafile using ($1):($5) axes x1y2 with lines linewidth 1 linetype 2 dashtype 3, \
     datafile using ($1):($10) axes x1y1 with lines linewidth 2 linetype 7 dashtype 2, \
     datafile using ($1):($11) axes x1y1 with lines linewidth 2 linetype 7
