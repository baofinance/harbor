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

# WHAT STOPS A REBALANCE SHORT, against the anchor the stability pools hold.
#
# A rebalance asks the minter how much anchor it must give up to bring the collateral ratio back to the
# threshold, and three things can make it give up less: a pool may only be taken down to its minimum
# supply (maxAssetLoss), its reward accounting can only absorb so much at once (maxLiquidationReward),
# and neither pool can hand over anchor it does not hold.
#
# The upper panel is which of them binds. What the threshold asks for does not depend on the pools at all
# - it is a property of how far the market has fallen - so it is flat. What the pools are allowed to lose
# is proportional to what they hold, so it is a straight line of slope 1. What is actually taken is the
# lower of the two, exactly: the pools' headroom binds while they are small, the market's own need binds
# once they are large, and the kink between them is the only place either line matters.
# maxLiquidationReward never binds anywhere on this sweep - it is not drawn because it never decided
# anything.
#
# The lower panel is what that means, and it is why this graph exists. It is about a DIFFERENT bound: the
# conversion bound over-issues while the leverage ratio is at its cap, which is at and below a collateral
# ratio of 20/19. A rebalance that reaches the threshold lifts the market far clear of that. A rebalance
# that runs out of pool does not - and the shaded region is where the market is left still inside the
# band, so the next rebalance converts at the bound as well, and the one after that.
#
# So "is the conversion bound ever the binding one in practice" is answered here rather than by anything
# about the bound itself: it is binding exactly while the pools are too small to escape the band.
#
# Every point starts from the same distressed collateral ratio of 1.02 - inside the band, leverage ratio
# about 51 - so each is one attempt at that escape, with only the pools' size differing.

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
set ytics ("10k" 10000, "100k" 100000, "613k" 613333, "1M" 1000000)
unset xlabel
# The lower panel carries the labels for the shared axis; an explicit tic list ignores `set format`, so
# the same positions are repeated here without them.
set xtics ("" 0.002, "" 0.01, "" 0.05, "" 0.1, "" 0.5, "" 1)
set key bottom right reverse Left noenhanced

# $1 = pool anchor per anchor outstanding, $2 = ask, $3 = allowed to lose, $4 = taken, $5 = ratio after
plot \
     datafile using ($1):($2) with lines linewidth 2 linetype 2 \
         title "needed to reach the threshold", \
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

# The conversion bound is engaged at and below 20/19, so a rebalance that ends in here leaves the market
# converting at the bound next time too.
set object 1 rectangle from graph 0, first 1 to graph 1, first 20.0 / 19.0 \
    fillcolor rgb "#d08770" fillstyle solid 0.18 noborder behind
set label 1 "the conversion bound is engaged in here" at graph 0.45, first 1.022 left textcolor rgb "gray20"
set arrow 1 from graph 0, first 1.25 to graph 1, first 1.25 nohead dashtype 2 linecolor rgb "gray40"
set label 2 "rebalance threshold" at graph 0.03, first 1.265 left textcolor rgb "gray30"

plot \
     datafile using ($1):($5) with linespoints linewidth 2 pointtype 7 pointsize 0.7 linetype 7 \
         title "reached", \
     20.0 / 19.0 with lines linewidth 2 dashtype 2 linetype 8 \
         title "the edge of the band"

unset multiplot
