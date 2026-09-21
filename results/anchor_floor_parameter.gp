datafile = "anchor_floor_parameter.csv"
set datafile separator comma
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'anchor_floor_parameter.png'" anchor_floor_parameter.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'anchor_floor_parameter.pdf'" anchor_floor_parameter.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 780 820 background rgb "gray90" }

# One dial, and what turning it does - for the story a holder needs to be told rather than for the
# protocol's own bookkeeping.
#
# `delta` is the share of the collateral the anchor may never claim, and which the sail therefore always
# may. Everything below follows from that one number, and every figure was MEASURED by building the rule
# at that `delta`, installing it over a market, and reading it.
#
# The UPPER panel is what it costs an anchor holder, and there are only two costs. The anchor's worst
# value is exactly `delta` below one, and it is only ever that at the peg itself. The band is how far
# above the peg the anchor is worth anything less than one at all - about 1.4 times `delta`, being the
# shift plus the rounding. OUTSIDE THAT BAND NOTHING CHANGES, which is the part to say loudest: every
# collateral ratio a market is normally run at, and every rebalance threshold in production, is outside
# it, where the anchor is worth exactly one and every operation returns exactly what it returns today.
#
# The LOWER panel is what it buys. The ceiling is the most levered a sail position can be. The other line
# is the one that matters for the concern the floor exists to answer: what ONE conversion of a hundredth
# of the anchor outstanding does to the whole sail supply, at the peg, where the floor is doing all of
# the work. Without a floor that number is unbounded - the same conversion multiplies the supply by
# fifty quadrillion a single wei of price above parity.
#
# The two panels pull against each other and that is the decision. A narrow, nearly invisible band costs
# the anchor almost nothing and buys weak protection: at a twentieth of a percent, one ordinary
# rebalance still multiplies the sail supply twenty-one fold. A wider band costs visibly more and holds
# that to nearly nothing. There is no setting that is cheap and strong.

set grid xtics ytics
set colorsequence default
set lmargin at screen 0.13
set rmargin at screen 0.96

set multiplot title "anchor_floor_parameter.gp" noenhanced

# ─────────────── what it costs the anchor
set tmargin at screen 0.94
set bmargin at screen 0.60

set logscale x
set logscale y
set xrange [0.04:6]
set yrange [0.03:9]
set format x "%g%%"
set format y "%g%%"
set xlabel "delta - the share of collateral the anchor never claims"
set ylabel "cost to an anchor holder"
set key at screen 0.5, screen 0.52 center top horizontal maxcols 2 spacing 1.2

# The band the user asked to stay well inside: the anchor worth exactly one by a collateral ratio of 1.01.
set arrow 1 from graph 0, first 1 to graph 1, first 1 nohead dashtype 2 linecolor rgb "red"
set label 1 "band reaches 1.01" at 0.045, 1.25 left textcolor "red"

# $1 = delta, $2 = the anchor at its worst, $3 = where the anchor is whole again
plot \
     datafile using ($1 * 100):((1 - $2) * 100) with linespoints linewidth 3 linetype 1 pointtype 7 \
         title "worst the anchor is ever worth, below one", \
     datafile using ($1 * 100):(($3 - 1) * 100) with linespoints linewidth 3 linetype 7 pointtype 9 \
         title "band where the anchor is not exactly one"

# ─────────────── what it buys
set tmargin at screen 0.44
set bmargin at screen 0.18

unset arrow 1
unset label 1
set yrange [0.8:4000]
set format y "%g"
set xlabel "delta - the share of collateral the anchor never claims"
set ylabel "protection bought"
set key at screen 0.5, screen 0.10 center top horizontal maxcols 1 spacing 1.2

# A conversion that leaves the sail supply where it found it.
set arrow 2 from graph 0, first 1 to graph 1, first 1 nohead dashtype 3 linecolor rgb "gray30"

# $4 = the leverage ceiling, $5 = what one conversion of a hundredth of the anchor does to the supply
plot \
     datafile using ($1 * 100):4 with linespoints linewidth 3 linetype 2 pointtype 7 \
         title "leverage ratio ceiling", \
     datafile using ($1 * 100):5 with linespoints linewidth 3 linetype 3 pointtype 5 \
         title "sail supply multiple from converting one percent of the anchor"

unset multiplot
