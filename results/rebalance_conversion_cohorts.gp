datafile = "rebalance_conversion_cohorts.csv"
set datafile separator comma
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'rebalance_conversion_cohorts.png'" rebalance_conversion_cohorts.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'rebalance_conversion_cohorts.pdf'" rebalance_conversion_cohorts.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 700 700 background rgb "gray90" }

# WHAT SUCCESSIVE COHORTS END UP WITH, having converted the same anchor into sail at different points on
# one market's way down, and all valued at a common final state.
#
# The upper panel is the finding, and it is not the one the phrase "cohort dispersion" leads you to
# expect. The fair line is what each cohort should hold: converting when sail is cheap buys more of it,
# so a cohort converting deep in the band ought to end up with thousands of times what it gave up, and
# one converting early with a fraction of it. That spread is not unfairness - it is what taking a
# position at different prices means.
#
# What the bound actually pays is the flat line. Every cohort inside the band receives the same twenty
# sail per unit of anchor value whatever sail was worth at the time, so every one of them ends up with
# the SAME 0.856 per anchor. The bound does not disperse the cohorts' outcomes; it FLATTENS them. The
# price signal that should separate a cohort converting at 1.06 from one converting at 1.02 is erased
# entirely, and the difference between what they should have had and what they got goes to the sail
# holders who did not convert.
#
# The lower panel is that difference. It is exactly one for the three cohorts that converted before the
# band - which is also what says this measurement is sound, since a conversion the bound never touched
# should be fair to the wei - and then it falls away without limit.
#
# X IS THE DISTANCE ABOVE THE PEG, ON A LOG SCALE, because the cohorts were placed by halving it, and
# because the quantities here are functions of it.

set logscale x
set xrange [0.015:0.5]
set xtics ("1.02" 0.02, "1.03" 0.03, "1.05" 0.05, "1.1" 0.1, "1.2" 0.2, "1.33" 0.33)
set grid xtics ytics
set colorsequence default
set lmargin at screen 0.15
set rmargin at screen 0.96

set multiplot

# ---------------------------------------------- what each cohort holds at the end, and what it should
set tmargin at screen 0.97
set bmargin at screen 0.56

set logscale y
set yrange [0.1:20000]
set ylabel "value per unit of anchor given up"
set ytics ("0.1" 0.1, "0.86" 0.856, "10" 10, "1000" 1000)
unset xlabel
set xtics ("" 0.02, "" 0.03, "" 0.05, "" 0.1, "" 0.2, "" 0.33)
set key top right reverse Left noenhanced

# $1 = collateral ratio converted at, $2 = actual, $3 = fair counterfactual, $4 = actual over fair
plot \
     datafile using ($1-1):($3) with linespoints linewidth 2 pointtype 7 pointsize 0.7 linetype 2 \
         title "what a fair conversion would have left it with", \
     datafile using ($1-1):($2) with linespoints linewidth 2 pointtype 7 pointsize 0.7 linetype 7 \
         title "what the bound actually paid"

# ------------------------------------------------------------------------- the difference between them
set tmargin at screen 0.54
set bmargin at screen 0.27

set yrange [0.00005:3]
set ylabel "actual over fair"
set ytics ("1" 1, "0.1" 0.1, "0.01" 0.01, "0.001" 0.001, "0.0001" 0.0001)
set xlabel "collateral ratio the cohort converted at"
set xtics ("1.02" 0.02, "1.03" 0.03, "1.05" 0.05, "1.1" 0.1, "1.2" 0.2, "1.33" 0.33)
set key at screen 0.5, screen 0.185 center top horizontal maxcols 2 reverse Left noenhanced

set arrow 1 from graph 0, first 1 to graph 1, first 1 nohead dashtype 2 linecolor rgb "gray40"
set label 1 "converted before the band:\nfair to the wei" at first 0.09, first 0.35 left textcolor rgb "gray30"

plot \
     datafile using ($1-1):($4) with linespoints linewidth 2 pointtype 7 pointsize 0.7 linetype 4 \
         title "what the cohort got, over what was fair", \
     1 with lines linewidth 2 dashtype 2 linetype 8 title "fair"

unset multiplot
