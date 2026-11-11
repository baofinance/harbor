datafile = "rebalance_binding_limits.csv"
set datafile separator comma
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'rebalance_binding_limits.png'" rebalance_binding_limits.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'rebalance_binding_limits.pdf'" rebalance_binding_limits.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 700 700 background rgb "gray90" }

# WHAT STOPS A REBALANCE SHORT, against the anchor the stability pools hold, in a market below the floor.
#
# A rebalance asks the minter how much anchor it must give up to bring the collateral ratio back to the
# threshold, and three things can make it give up less: a pool may only be taken down to its minimum
# supply (maxAssetLoss), its reward accounting can only absorb so much at once (maxLiquidationReward),
# and neither pool can hand over anchor it does not hold.
#
# Every point starts from the same collateral ratio, 1.004: four tenths of the way from the peg to the
# floor of 100/99 = 1.0101, where the market sells no leverage. So each rebalance first takes both pools'
# anchor by the collateral route towards the floor, and converts towards the threshold only from the floor.
#
# The upper panel is which limit binds. What the pools are allowed to lose is proportional to what they
# hold, a straight line of slope 1, and up to pools of 58% of the anchor outstanding the rebalance takes
# exactly that: the pools' headroom binds. The flat line is the minter's ask for both legs from the start,
# 656k. The rebalance cannot follow it below the floor, where it takes the collateral route instead, and
# that route needs more anchor: at 58% it takes 1.17M and still stops short of the floor. Only pools of
# 88% reach the floor, and that rebalance converts the rest of the way to the threshold.
# maxLiquidationReward never binds anywhere on this sweep - it is not drawn because it never decided
# anything.
#
# The lower panel is where each rebalance leaves the market. The shaded band is below the floor, where the
# market sells no leverage: a rebalance that ends there leaves the next one starting by the collateral
# route as well. Pools too small to lift the market to the floor leave it there.

set logscale x
set xrange [0.0015:1.2]
set xtics ("0.2%%" 0.002, "1%%" 0.01, "5%%" 0.05, "10%%" 0.1, "50%%" 0.5, "100%%" 1)
set grid xtics ytics
set colorsequence default
set lmargin at screen 0.15
set rmargin at screen 0.96

set multiplot title "rebalance_binding_limits.gp" noenhanced

# --------------------------------------------------------------- which limit decides how much is taken
set tmargin at screen 0.93
set bmargin at screen 0.57

set logscale y
set yrange [3000:3000000]
set ylabel "anchor (tokens)"
set ytics ("10k" 10000, "100k" 100000, "656k" 655892, "1M" 1000000)
unset xlabel
# The lower panel carries the labels for the shared axis; an explicit tic list ignores `set format`, so
# the same positions are repeated here without them.
set xtics ("" 0.002, "" 0.01, "" 0.05, "" 0.1, "" 0.5, "" 1)
set key bottom right reverse Left noenhanced

# $1 = pool anchor per anchor outstanding, $2 = ask, $3 = allowed to lose, $4 = taken, $5 = ratio after
plot \
     datafile using ($1):($2) with lines linewidth 2 linetype 2 \
         title "the minter's ask for both legs, from the start", \
     datafile using ($1):($3) with lines linewidth 2 linetype 4 \
         title "the pools are allowed to lose", \
     datafile using ($1):($4) with points pointtype 7 pointsize 0.7 linetype 7 \
         title "actually taken"

# ------------------------------------------------------- and whether that is enough to leave the band
set tmargin at screen 0.55
set bmargin at screen 0.28

unset logscale y
set yrange [1:1.3]
set ylabel "collateral ratio after the rebalance"
set ytics 0.05
set xlabel "stability pool anchor holdings, as a share of the anchor outstanding"
set xtics ("0.2%%" 0.002, "1%%" 0.01, "5%%" 0.05, "10%%" 0.1, "50%%" 0.5, "100%%" 1)
set key at screen 0.5, screen 0.19 center top horizontal maxcols 2 reverse Left noenhanced

# Below the floor, 100/99, the market sells no leverage, so a rebalance that ends in here leaves the next one
# starting by the collateral route too.
set object 1 rectangle from graph 0, first 1 to graph 1, first 100.0 / 99.0 \
    fillcolor rgb "#d08770" fillstyle solid 0.18 noborder behind
set label 1 "below the floor: no leverage is sold" at graph 0.45, first 1.022 left textcolor rgb "gray20"
set arrow 1 from graph 0, first 1.25 to graph 1, first 1.25 nohead dashtype 2 linecolor rgb "gray40"
set label 2 "rebalance threshold" at graph 0.03, first 1.265 left textcolor rgb "gray30"

plot \
     datafile using ($1):($5) with linespoints linewidth 2 pointtype 7 pointsize 0.7 linetype 7 \
         title "reached", \
     100.0 / 99.0 with lines linewidth 2 dashtype 2 linetype 8 \
         title "the floor"

unset multiplot
