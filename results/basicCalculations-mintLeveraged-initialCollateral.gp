set title "basicCalculations-mintLeveraged-initialCollateral.gp" noenhanced
datafile = "basicCalculations-mintLeveraged-initialCollateral.csv"
set datafile separator comma
set key autotitle columnheader noenhanced below title " "
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'basicCalculations-mintLeveraged-initialCollateral.png'" basicCalculations-mintLeveraged-initialCollateral.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'basicCalculations-mintLeveraged-initialCollateral.pdf'" basicCalculations-mintLeveraged-initialCollateral.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 600 400 background rgb "gray90" }
#set terminal pngcairo size 500 300
set autoscale
set xlabel "Collateral Tokens"
set xrange [0:80]

set ylabel "Price / Invariant / CollateralRatio"
set yrange [-1:7]
set ytics nomirror

set y2label "Leveraged Tokens"
set y2range [-1000:100000]
set y2tics nomirror

set colorsequence default
# $4 y1 pegged price
# $6 y1 leveraged price
# $7 y1 invariant
# $8 y1 collateral ratio
# $9 y2 leverage ratio
plot \
    datafile using ($1):($5) axes x1y2 with lines linewidth 2 linetype 2, \
    datafile using ($1):($6) axes x1y1 with lines linewidth 1 linetype 4, \
    datafile using ($1):($7) axes x1y1 with lines linewidth 2 linetype 6, \
    datafile using ($1):($8) axes x1y1 with lines linewidth 3 linetype 8 dashtype 2, \
    datafile using ($1):($9) axes x1y1 with lines linewidth 3 linetype 4 dashtype 2
