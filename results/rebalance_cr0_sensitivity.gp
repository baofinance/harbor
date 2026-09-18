datafile = "rebalance_cr0_sensitivity.csv"
set datafile separator comma
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'rebalance_cr0_sensitivity.png'" rebalance_cr0_sensitivity.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'rebalance_cr0_sensitivity.pdf'" rebalance_cr0_sensitivity.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 700 700 background rgb "gray90" }

# WHETHER ONE BOUND CAN SERVE MARKETS OPENED AT DIFFERENT COLLATERAL RATIOS. It cannot, and the upper
# panel is the whole argument in two lines.
#
# The bound is a ceiling on the conversion rate, so it ought to engage where the FAIR conversion rate
# reaches that ceiling. Where it actually engages is where the reported leverage ratio reaches the cap -
# a collateral ratio of 20/19, fixed by the cap and by nothing else, which is the flat line. Where it
# OUGHT to engage depends on how many sail tokens the market carries, which is what its opening ratio
# decided: that is the sloped line, and it moves across two decades.
#
# The two meet at one opening ratio, a little over 2.05. That market gets the bound the specification
# describes. Every other market gets a band between the two lines in which the conversion is bounded but
# not fair, and the further from 2.05 it opened the wider that band is.
#
# The lower panel is what it costs in that band: the applied conversion rate over the fair one at the
# moment the bound lets go. Above one the bound engaged too early and over-issues sail, taking value from
# existing sail holders - fifty-fold for a market opened at 1.02. Below one it engaged too late and
# under-issues, taking value from the pool instead. The same constant, in opposite directions, with
# nothing in between but a single opening ratio that no protocol rule holds a market at.
#
# BOTH AXES MEASURE DISTANCE ABOVE THE PEG, logarithmically, because that is what these quantities are
# functions of - the residual a market carries is proportional to it. On those axes each relationship is
# the straight line it actually is, and the slopes are readable as the powers they are.

set logscale x
set xrange [0.015:6]
set xlabel "collateral ratio the market opened at"
set xtics ("1.02" 0.02, "1.05" 0.05, "1.1" 0.1, "1.3" 0.3, "2" 1, "3" 2, "6" 5)
set grid xtics ytics
set colorsequence default
set lmargin at screen 0.16
set rmargin at screen 0.96

# Where the two lines above cross: the one opening ratio the bound is right for.
crossing = 1.0526

set multiplot

# ------------------------------------------------ where the bound engages, and where it ought to engage
set tmargin at screen 0.97
set bmargin at screen 0.56

set logscale y
set yrange [0.0006:0.4]
set ylabel "collateral ratio at which it engages"
set ytics ("1.001" 0.001, "1.005" 0.005, "1.01" 0.01, "1.05" 0.05, "1.1" 0.1, "1.25" 0.25)
unset xlabel
set xtics ("" 0.02, "" 0.05, "" 0.1, "" 0.3, "" 1, "" 2, "" 5)
set key top left reverse Left noenhanced

set arrow 1 from first crossing, graph 0 to first crossing, graph 1 nohead dashtype 2 linecolor rgb "gray40"
set label 1 "the one market\nthis bound suits" at graph 0.74, graph 0.30 left textcolor rgb "gray30"

# $1 = opening collateral ratio, $2 = where it engages, $3 = where it should, $4 = worst over-issue
plot \
     datafile using ($1-1):($2-1) with lines linewidth 2 linetype 7 \
         title "where the bound engages (the reported leverage ratio reaches the cap)", \
     datafile using ($1-1):($3-1) with lines linewidth 2 linetype 2 \
         title "where it ought to (the fair conversion rate reaches the cap)"

# ------------------------------------------------------------ and what the gap between them costs there
set tmargin at screen 0.54
set bmargin at screen 0.27

set yrange [0.15:100]
set ylabel "applied over fair conversion rate\nwhere the bound lets go"
set ytics ("0.2" 0.2, "1" 1, "5" 5, "20" 20, "50" 50)
set xlabel "collateral ratio the market opened at"
set xtics ("1.02" 0.02, "1.05" 0.05, "1.1" 0.1, "1.3" 0.3, "2" 1, "3" 2, "6" 5)
set key at screen 0.5, screen 0.185 center top horizontal maxcols 2 reverse Left noenhanced
unset label 1

set arrow 2 from graph 0, first 1 to graph 1, first 1 nohead dashtype 2 linecolor rgb "red"
set label 2 "over-issues: value taken from sail holders" at graph 0.04, first 20 left textcolor rgb "gray20"
set label 3 "under-issues: value taken from the pool" at graph 0.40, first 0.25 left textcolor rgb "gray20"

plot \
     datafile using ($1-1):($4) with lines linewidth 2 linetype 4 \
         title "what the conversion actually pays, over what is fair", \
     1 with lines linewidth 2 dashtype 2 linetype 8 \
         title "fair"

unset multiplot
