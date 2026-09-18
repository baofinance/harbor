datafile = "rebalance_conversion_fairness.csv"
set datafile separator comma
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'rebalance_conversion_fairness.png'" rebalance_conversion_fairness.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'rebalance_conversion_fairness.pdf'" rebalance_conversion_fairness.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 700 760 background rgb "gray90" }

# What an anchor-to-sail conversion returns per unit of anchor given up, for five conversion sizes.
# One is a fair conversion. Below one the converter hands value to the sail already outstanding; above
# one it takes value from it.
#
# The five lines are the finding: at a given collateral ratio they disagree by a factor of eight, so
# what the bound costs is not a property of the collateral ratio alone - it depends as much on how large the
# conversion is. A conversion small enough not to move the price gets the full mispricing; one giving up
# several times the residual dilutes itself almost back to fair. Below about a tenth of the residual the
# three smallest sizes lie on top of one another, so there is a size below which this stops mattering.
#
# TWO PANELS, because the two halves of the story do not share a scale in either direction.
#
# The UPPER panel is where the bound underpays, which runs over more than a decade of value and more
# than two decades of collateral ratio, so both of its axes are logarithmic. Its x is the distance above
# the peg, which is the variable these quantities are actually functions of: the residual the sail is a
# claim on is proportional to it, and so is the fair conversion rate.
#
# The LOWER panel is the band where the bound OVERPAYS. It is four thousandths of a collateral ratio wide - under
# one percent of the upper panel's axis, where it is a spike - and never exceeds five percent of value,
# which is a rounding error on the upper panel's scale. It gets its own linear axes at its own scale,
# and is the graph's real subject: the bound's over-issue is what dilutes existing sail holders.
# Compressing one axis to fit both would change each line's visual gradient by the compression factor,
# making a bend in the data indistinguishable from a bend in the axis - two honest panels instead.

set grid xtics ytics
set colorsequence default
set lmargin at screen 0.13
set rmargin at screen 0.96

set multiplot

# --------------------------------------------- where the bound underpays: two decades, so logarithmic
set tmargin at screen 0.97
set bmargin at screen 0.62

set logscale x
set logscale y
# Margin either side of the data - the first sample is 0.002 above the peg, the last 0.6 - so neither
# end of what is being shown sits against the frame.
set xrange [0.0015:0.75]
set xlabel "collateral ratio, by log distance above the peg"
set xtics ("1.002" 0.002, "1.005" 0.005, "1.01" 0.01, "1.02" 0.02, "1.05" 0.05, \
           "1.1" 0.1, "1.2" 0.2, "1.6" 0.6)
set yrange [0.03:1.3]
set ylabel "value returned per anchor given up"
set ytics ("0.04" 0.04, "0.1" 0.1, "0.2" 0.2, "0.5" 0.5, "1" 1)
unset key

# A fair conversion returns exactly what it gave up.
set arrow 1 from graph 0, first 1 to graph 1, first 1 nohead dashtype 2 linecolor rgb "red"
set label 1 "fair" at graph 0.02, first 1.09 left textcolor "red"

# The largest sizes stop where the market runs out of anchor to convert: giving up every anchor token in
# existence is 1/(collateral ratio - 1) of the residual, so ten times the residual is impossible above a collateral ratio of
# 1.1 and that line ends there rather than being drawn as something.
# $1 = collateral ratio, $2..$6 = value per anchor at each conversion size, smallest first
plot \
     datafile using ($1-1):($2) with lines linewidth 2 linetype 1, \
     datafile using ($1-1):($3) with lines linewidth 2 linetype 2, \
     datafile using ($1-1):($4) with lines linewidth 2 linetype 3, \
     datafile using ($1-1):($5) with lines linewidth 2 linetype 4, \
     datafile using ($1-1):($6) with lines linewidth 2 linetype 7

# --------------------- where the bound overpays: four thousandths of a collateral ratio, own scale
set tmargin at screen 0.48
set bmargin at screen 0.27

unset logscale x
unset logscale y
unset arrow 1
unset label 1
set xrange [1.047:1.0545]
set xlabel "collateral ratio (detail: the band where the bound overpays)"
set xtics 0.002 format "% .3f"
set yrange [-7:6]
set ytics 2
set ylabel "excess over fair (%)"
set arrow 2 from graph 0, first 0 to graph 1, first 0 nohead dashtype 2 linecolor rgb "red"
set key at screen 0.5, screen 0.175 center top horizontal maxcols 2 autotitle columnheader noenhanced

plot \
     datafile using ($1):(($2-1)*100) with lines linewidth 2 linetype 1, \
     datafile using ($1):(($3-1)*100) with lines linewidth 2 linetype 2, \
     datafile using ($1):(($4-1)*100) with lines linewidth 2 linetype 3, \
     datafile using ($1):(($5-1)*100) with lines linewidth 2 linetype 4, \
     datafile using ($1):(($6-1)*100) with lines linewidth 2 linetype 7

unset multiplot
