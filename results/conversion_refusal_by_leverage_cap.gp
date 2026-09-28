datafile = "conversion_refusal_by_leverage_cap.csv"
set datafile separator comma
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'conversion_refusal_by_leverage_cap.png'" conversion_refusal_by_leverage_cap.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'conversion_refusal_by_leverage_cap.pdf'" conversion_refusal_by_leverage_cap.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 780 800 background rgb "gray90" }

# Which leverage cap a market can afford, given the collateral ratio it rebalances up to.
#
# A cap refuses the anchor-to-sail conversion at and below `K/(K-1)`, and a rebalance restores UP to its
# threshold. So a cap whose boundary sits ABOVE a market's threshold refuses that conversion across the
# market's whole rebalancing range, and its leveraged stability pool is never drawn on at all. Each
# market's threshold is therefore a hard floor under its cap.
#
# Both axes are distances rather than levels - the cap's boundary as its distance ABOVE THE PEG, which is
# `1/(K-1)`, so the relation is a straight line of slope -1 over three orders of magnitude and the
# thresholds sit on the same scale as the thing they constrain. A market is safe where the measured line
# passes BELOW its dashed line.
#
# The four dashed lines are the production volatility tiers, and they do not admit one shared answer. The
# 1.30 market is content with anything above 4.4; the 1.05 market needs more than 21, which the cap of 20
# in the contract today does not clear. Whatever single number is chosen either strands the tight markets
# or is far looser than the loose ones need.
#
# The LOWER panel is what a larger cap costs, and it is the reason not to simply pick a very large one.
# The sail supply growth admitted by one anchor token converted at the boundary rises in proportion to
# the cap - the boundary creeps towards the peg and the quantity minted there rises with it.

set grid xtics ytics
set colorsequence default
set lmargin at screen 0.13
set rmargin at screen 0.96

set multiplot title "conversion_refusal_by_leverage_cap.gp" noenhanced

# ─────────────── how far above the peg each cap refuses
set tmargin at screen 0.94
set bmargin at screen 0.56

set logscale x
set logscale y
set xrange [1:1000]
set yrange [0.0008:8]
set format x "10^{%T}"
set xlabel "leverage ratio cap"
set ylabel "refuses up to this far above the peg"
set ytics ("0.001" 0.001, "0.01" 0.01, "0.05" 0.05, "0.1" 0.1, "0.3" 0.3, "1" 1, "5" 5)
unset key

# The production volatility tiers, as the distance their threshold sits above the peg. A market is safe
# where the measured line is BELOW its own dashed line.
set arrow 1 from graph 0, first 0.30 to graph 1, first 0.30 nohead dashtype 2 linecolor rgb "dark-green"
set label 1 "1.30 market: needs K > 4.3" at 1.3, 0.36 left textcolor "dark-green"
set arrow 2 from graph 0, first 0.25 to graph 1, first 0.25 nohead dashtype 2 linecolor rgb "dark-green"
set arrow 3 from graph 0, first 0.15 to graph 1, first 0.15 nohead dashtype 2 linecolor rgb "dark-orange"
set label 3 "1.15 market: needs K > 7.7" at 1.3, 0.175 left textcolor "dark-orange"
set arrow 4 from graph 0, first 0.05 to graph 1, first 0.05 nohead dashtype 2 linecolor rgb "red"
set label 4 "1.05 market: needs K > 21" at 1.3, 0.058 left textcolor "red"

# The cap the contract carries today, which clears three of the four tiers and not the fourth.
set arrow 5 from 20, graph 0 to 20, graph 1 nohead dashtype 4 linewidth 2 linecolor rgb "black"
set label 5 "K = 20 today" at 22, 3 left textcolor "black"

# $1 = the cap, $2 = the measured refusal ratio
plot datafile using 1:($2 - 1) with linespoints linewidth 3 linetype 7 pointtype 7 \
         title "measured refusal boundary"

# ─────────────── what a larger cap admits at that boundary
set tmargin at screen 0.44
set bmargin at screen 0.10

unset logscale y
unset arrow 1
unset arrow 2
unset arrow 3
unset arrow 4
unset label 1
unset label 3
unset label 4
set format y "%.3f"
set yrange [0.999:1.04]
set ytics 0.01
set xlabel "leverage ratio cap"
set ylabel "sail supply multiple at the boundary"
set label 5 "K = 20 today" at 22, 1.032 left textcolor "black"

set arrow 6 from graph 0, first 1 to graph 1, first 1 nohead dashtype 2 linecolor rgb "red"

plot datafile using 1:3 with linespoints linewidth 3 linetype 2 pointtype 7 \
         title "one anchor token converted at the boundary"

unset multiplot
