datafile = "conversion_bound_step.csv"
set datafile separator comma
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'conversion_bound_step.png'" conversion_bound_step.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'conversion_bound_step.pdf'" conversion_bound_step.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 700 640 background rgb "gray90" }

# WHAT THE BOUND DOES WHEN IT LETS GO, against how many sail tokens the market carries.
#
# The bound always releases at the same collateral ratio: the leverage ratio reaches the cap of 20 at
# 20/19, and the leverage ratio is a function of the collateral ratio alone. What the applied conversion
# rate does when it gets there is not fixed at all.
#
# The upper panel is why. Inside the bound the applied conversion rate is the ceiling, 20, whatever the
# market looks like - the flat line. Outside it the conversion rate is the fair one, the sail supply over
# the residual, and since the residual at the release is a fixed share of the collateral that rises in
# proportion to the sail supply - the sloped line. The bound is a ceiling held at one height while the
# thing it is capping sweeps five orders of magnitude in all, ninety-fourfold of that above it.
#
# The lower panel is the consequence: the step the applied conversion rate takes across the release, which
# is one line over the other. It passes through 1 - a continuous join, the behaviour the specification
# assumes - at exactly ONE sail supply, 20/19 of the anchor supply, where the two lines above cross.
# Every other market gets a jump, and the jump goes as one over the sail supply, so it is unbounded in
# both directions: a thousandfold over-issue at a thousandth of that supply, a hundredfold under-issue at
# a hundred times it.
#
# Nothing holds a market at the crossing. Sail supply here is swept by buying and selling sail, both
# price-neutral - they change how many tokens carry the residual, not what one is worth - so every point
# is an undistressed market that could exist at any time, with no holder diluted to reach it.
#
# Both axes are logarithmic on both panels because these are power laws, which a log-log axis draws as
# straight lines whose slopes are the powers: the fair conversion rate rises with slope +1, the step falls
# with slope -1, and the ceiling is flat.

set logscale x
set logscale y
set xrange [0.0007:150]
set grid xtics ytics
set colorsequence default
set lmargin at screen 0.13
set rmargin at screen 0.96

# The one sail supply at which the bound releases exactly where the fair conversion rate reaches it.
crossing = 20.0 / 19.0

set multiplot title "conversion_bound_step.gp" noenhanced

# ------------------------------------------------- the ceiling, and the conversion rate it is capping
set tmargin at screen 0.93
set bmargin at screen 0.56

set yrange [0.01:3000]
set ylabel "conversion rate (sail per unit of anchor value)"
set ytics ("0.01" 0.01, "1" 1, "20" 20, "100" 100, "1000" 1000)
unset xlabel
set xtics ("" 0.001, "" 0.01, "" 0.1, "" 1, "" 10, "" 100)
set key top left reverse Left noenhanced

set arrow 1 from first crossing, graph 0 to first crossing, graph 1 nohead dashtype 2 linecolor rgb "gray40"
set label 1 "the two meet here" at first crossing * 1.4, graph 0.12 left textcolor rgb "gray30"

# $1 = sail supply per anchor token, $2 = applied inside the bound, $3 = fair at the release, $4 = step
plot \
     datafile using ($1):($2) with lines linewidth 2 linetype 7 \
         title "applied, inside the bound (the ceiling)", \
     datafile using ($1):($3) with lines linewidth 2 linetype 2 \
         title "fair, at the release"

# --------------------------------------------------------- the step between them, which is their ratio
set tmargin at screen 0.54
set bmargin at screen 0.11

set yrange [0.008:2000]
set ylabel "step at the release (multiple)"
set ytics ("0.01" 0.01, "0.1" 0.1, "1" 1, "10" 10, "100" 100, "1000" 1000)
set xlabel "sail supply per anchor token"
set xtics ("0.001" 0.001, "0.01" 0.01, "0.1" 0.1, "1" 1, "10" 10, "100" 100)
set key top right reverse Left noenhanced
unset label 1

# A step of one is a continuous join: the bound releases exactly where the fair conversion rate reaches
# it, and nothing jumps.
set arrow 2 from graph 0, first 1 to graph 1, first 1 nohead dashtype 2 linecolor rgb "red"
set label 2 "continuous" at graph 0.02, first 1.6 left textcolor rgb "red"
set label 3 "bound OVER-issues" at graph 0.03, first 200 left textcolor rgb "gray20"
set label 4 "bound UNDER-issues" at graph 0.55, first 0.02 left textcolor rgb "gray20"

plot \
     datafile using ($1):($4) with lines linewidth 2 linetype 4 \
         title "step at the release (applied over fair)"

unset multiplot
