datafile = "sail_claim_floor.csv"
set datafile separator comma
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'sail_claim_floor.png'" sail_claim_floor.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'sail_claim_floor.pdf'" sail_claim_floor.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 780 820 background rgb "gray90" }

# Putting a floor under what the sail CLAIMS, rather than a rule on what a trade may DO.
#
# The x axis is the residual as a fraction of the collateral value, which is one over the leverage ratio -
# so the right of the graph is a healthy market and the left is the pole. The floor is drawn at one
# twentieth, which is to say a leverage ratio of twenty, reached by defining the token rather than by
# capping anything.
#
# The UPPER panel is what it buys. Unfloored, the rate runs to a million sail per anchor token inside this
# sweep alone and to a sextillion at the pole itself. The hard floor holds it at exactly TWENTY, and
# approaches that asymptotically from below rather than arriving at it - 19.3, 19.7, 19.87, 19.95 - so
# the schedule is continuous, with a corner only where the floor first bites.
#
# The LOWER panel is who pays, and it is the question the whole idea rests on. The HARD floor leaves a
# healthy market untouched and hands the entire cost to a fund; its draw is bounded by the floor itself,
# so it can never exceed five percent of the collateral value however bad things get. The BLEND is
# self-financing instead - above the floor the sail claims a tenth less of the gap and the difference
# accrues, below it the difference is drawn back - and it takes 2.855% where it needs at most 0.500%, a
# margin of nearly six to one.
#
# The blend pays for that with a ceiling ten times looser (200 rather than 20, being 20/b) and with a
# haircut on healthy sail holders of 8.5% at a collateral ratio of 1.5. The two panels together are the
# trade: a fund bought from outside buys a tight ceiling and no distortion, a fund raised from within
# buys neither but needs nobody's permission.

set grid xtics ytics
set colorsequence default
set lmargin at screen 0.13
set rmargin at screen 0.96

set multiplot title "sail_claim_floor.gp" noenhanced

# ─────────────── what one anchor token buys, floored and not
set tmargin at screen 0.94
set bmargin at screen 0.58

set logscale x
set logscale y
set xrange [0.0000008:0.5]
set yrange [0.5:3e6]
set format x "10^{%T}"
set format y "10^{%T}"
set xlabel "residual as a fraction of collateral value (one over the leverage ratio)"
set ylabel "sail issued for one anchor token"
set key at screen 0.5, screen 0.495 center top horizontal maxcols 3 spacing 1.2

# Where the floor sits: a residual of one twentieth of the collateral value, i.e. a leverage ratio of 20.
set arrow 1 from 0.05, graph 0 to 0.05, graph 1 nohead dashtype 2 linewidth 2 linecolor rgb "red"
set label 1 "the floor" at 0.042, 3e4 right textcolor "red"

# $2 = residual fraction, $3 = unfloored, $4 = hard floor, $5 = blended floor
plot \
     datafile using 2:3 with linespoints linewidth 2 linetype 1 pointtype 7 title "no floor", \
     datafile using 2:5 with linespoints linewidth 2 linetype 3 pointtype 5 title "blended floor", \
     datafile using 2:4 with linespoints linewidth 3 linetype 2 pointtype 9 title "hard floor"

# ─────────────── who pays for it
set tmargin at screen 0.42
set bmargin at screen 0.20

unset logscale y
unset label 1
set format y "%+.1f"
set yrange [-3.5:5.8]
set ytics 1
set xlabel "residual as a fraction of collateral value (one over the leverage ratio)"
set ylabel "fund flow (% of collateral value)"
set key at screen 0.5, screen 0.115 center top horizontal maxcols 1 spacing 1.2

# Nothing given and nothing taken.
set arrow 2 from graph 0, first 0 to graph 1, first 0 nohead dashtype 2 linecolor rgb "red"

plot \
     datafile using 2:($6 * 100) with linespoints linewidth 3 linetype 2 pointtype 9 \
         title "hard floor: paid out by a fund", \
     datafile using 2:($7 * 100) with linespoints linewidth 2 linetype 3 pointtype 5 \
         title "blend: negative is taken in, positive is paid out"

unset multiplot
