fair = "rebalance_supply_trajectory.csv"
bounded = "rebalance_supply_trajectory_bounded.csv"
set datafile separator comma
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'rebalance_supply_trajectory.png'" rebalance_supply_trajectory.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'rebalance_supply_trajectory.pdf'" rebalance_supply_trajectory.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 700 700 background rgb "gray90" }

# WHAT REPEATED REBALANCES DO TO A MARKET, and whether the bound's error works itself out.
#
# Two runs of the same market, same rebalance threshold, same forty cycles, differing only in how far the
# collateral ratio is allowed to fall before the keeper fires. One stops short of the band where the
# conversion bound engages; the other reaches inside it. Depositors return between cycles in both, so
# neither run is limited by empty pools.
#
# The upper panel is the finding. Where the bound never engages the conversion is fair to the wei, every
# cycle, forty times over - the flat line at one, which is also what says this measurement is sound.
# Where the bound engages, the conversion pays four tenths of fair on the first cycle, a fifteenth on the
# second, and a hundredth by the fifth: the error does not settle down, it COMPOUNDS. Each bounded
# conversion mints sail, which raises the fair rate, which leaves the fixed ceiling a smaller fraction
# of it, which makes the next conversion worse. There is no level it converges to short of zero.
#
# The lower panel is the market being restructured underneath that - anchor converted into sail, cycle
# after cycle. Read it with the runs' difference in mind and NOT as an effect of the bound: a market that
# falls to 1.02 needs a far bigger correction to climb back to the threshold than one that falls to 1.20,
# so it converts more anchor per cycle whatever rate it converts at. The quantity that isolates the bound
# is the one above, which compares what a conversion pays against what is fair in the very state that
# conversion happens in.

set xrange [0:41]
set xlabel "rebalance"
set grid xtics ytics
set colorsequence default
set lmargin at screen 0.15
set rmargin at screen 0.96

set multiplot title "rebalance_supply_trajectory.gp" noenhanced

# ------------------------------------------ what each cycle's conversion pays, against what would be fair
set tmargin at screen 0.93
set bmargin at screen 0.56

set logscale y
set yrange [0.00005:3]
set ylabel "applied over fair conversion rate"
set ytics ("1" 1, "0.1" 0.1, "0.01" 0.01, "0.001" 0.001, "0.0001" 0.0001)
unset xlabel
set format x ""
set key bottom left reverse Left noenhanced

set arrow 1 from graph 0, first 1 to graph 1, first 1 nohead dashtype 2 linecolor rgb "gray40"

# $1 = rebalance, $2 = sail supply, $3 = sail price, $4 = applied over fair, $5 = ratio after, $6 = anchor
plot \
     fair using ($1):($4) with linespoints linewidth 2 pointtype 7 pointsize 0.5 linetype 2 \
         title "dip to 1.20 - the bound never engages", \
     bounded using ($1):($4) with linespoints linewidth 2 pointtype 7 pointsize 0.5 linetype 7 \
         title "dip to 1.02 - every conversion at the bound"

# ------------------------------------------------------------- the market being converted out from under
set tmargin at screen 0.54
set bmargin at screen 0.27

set yrange [1:2000000000]
set ylabel "tokens outstanding"
set ytics ("1" 1, "1k" 1000, "1M" 1000000, "1bn" 1000000000)
set xlabel "rebalance"
set format x "% h"
set key at screen 0.5, screen 0.185 center top horizontal maxcols 2 reverse Left noenhanced
unset arrow 1

plot \
     fair using ($1):($2) with lines linewidth 2 linetype 2 title "sail, dip to 1.20", \
     fair using ($1):($6) with lines linewidth 2 dashtype 2 linetype 2 title "anchor, dip to 1.20", \
     bounded using ($1):($2) with lines linewidth 2 linetype 7 title "sail, dip to 1.02", \
     bounded using ($1):($6) with lines linewidth 2 dashtype 2 linetype 7 title "anchor, dip to 1.02"

unset multiplot
