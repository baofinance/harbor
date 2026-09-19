datafile = "rebalance_trigger_mismatch.csv"
set datafile separator comma
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'rebalance_trigger_mismatch.png'" rebalance_trigger_mismatch.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'rebalance_trigger_mismatch.pdf'" rebalance_trigger_mismatch.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 700 600 background rgb "gray90" }

# The conversion is bounded at 20 sail per unit of anchor value, so it should engage where the fair
# rate - the reciprocal of the sail price - crosses 20. It engages on the reported leverage ratio
# instead. Both are plotted against the collateral ratio, with the ratio of applied to fair on the
# right axis: 1 means the conversion is fair, below 1 the bound costs the pool, above 1 it over-issues.
#
# THE X AXIS IS THE DISTANCE ABOVE THE PEG, ON A LOG SCALE, because that is the variable this data is
# actually a function of: the fair conversion rate is exactly 1/(collateral ratio - 1) across the whole
# sweep, so on a logarithmic pair of axes it is a straight line of slope -1 and every departure from it is
# legible as a departure from a straight line. A linear axis instead gives the collateral ratios this
# graph is about -
# the six hundredths above the peg - three percent of the width, and compressing such an axis by
# stretches is not an answer: it changes each line's visual gradient by the compression factor, so a
# bend can be an artefact of the axis rather than a property of the data. A logarithmic axis distorts
# too, but it distorts smoothly and says what it is doing, which is why a straight line on it means
# something.
#
# The peg itself is a singularity of that axis, so the stretch at and below it - where every line sits
# flat at the bound and there is no residual behind the sail token to compare against - is drawn in its
# own narrow panel on its own linear axis, rather than dropped or bent into the log one.

set logscale y
set yrange [1:600]
set grid xtics ytics

set multiplot title "rebalance_trigger_mismatch.gp" noenhanced

# ---------------------------------------------------------------- at and below the peg: 18% of width
set lmargin at screen 0.11
set rmargin at screen 0.247
set bmargin at screen 0.22
set tmargin at screen 0.91

set ylabel "conversion rate (sail per unit of anchor value)"
set ytics nomirror
unset y2tics
unset y2label
unset key

set xlabel "collateral ratio" offset 0,0.3
set xrange [0:1]
set xtics ("0" 0, "0.5" 0.5, "1" 1)

set arrow 1 from graph 0, first 20 to graph 1, first 20 nohead linetype 1 dashtype 2 linecolor "red"

# The reported leverage ratio, the applied rate and the bound are the same number over this whole
# stretch, so they draw as one line and a reader would otherwise count one where there are three.
set label 2 "reported leverage ratio, applied conversion rate and bound all sit here" \
    at graph 0.5, graph 0.72 center rotate by 90 font ",8" textcolor "gray20"

set colorsequence default
# $1 = collateral ratio, $2 = reported leverage ratio, $3 = fair rate, $4 = applied rate (measured).
# The fair conversion rate is NaN here - no residual, so nothing to be fair against - and gnuplot skips
# it, as it does the applied-over-fair column that depends on it. The other two sit on the bound and on
# each other, so the leverage ratio is drawn last: its dashes over the applied rate are what show that
# two lines are there rather than one.
plot \
     datafile using ($1):($3) with lines linewidth 2 linetype 2, \
     datafile using ($1):($4) with lines linewidth 2 linetype 7, \
     datafile using ($1):($2) with lines linewidth 1 linetype 1 dashtype 2

# ------------------------------------------------------------------------ above the peg: 72% of width
set lmargin at screen 0.267
set rmargin at screen 0.87

# Margin either side of the data - the first sample sits at 0.002 above the peg and the last at 0.6 -
# so neither end of what is being shown is jammed against the frame.
set logscale x
set xrange [0.0015:0.75]
set xlabel "collateral ratio, by log distance above the peg" offset 0,0.3
set xtics ("1.002" 0.002, "1.005" 0.005, "1.01" 0.01, "1.02" 0.02, "1.05" 0.05, \
           "1.1" 0.1, "1.2" 0.2, "1.6" 0.6)

# The left panel carries the conversion-rate axis for both; this one carries the fairness axis.
unset ylabel
set format y ""
set y2label "applied over fair conversion rate"
set y2range [0:1.2]
set y2tics 0.2

unset label 2
set label 1 "  bound = 20" at graph 0.02, first 23 left textcolor "red"
set key at screen 0.5, screen 0.13 center top horizontal maxcols 2 autotitle columnheader noenhanced

# Rows at or below the peg have no log distance above it, so the log axis drops them - they are the
# left panel's subject.
plot \
     datafile using ($1-1):($2) axes x1y1 with lines linewidth 1 linetype 1 dashtype 2, \
     datafile using ($1-1):($3) axes x1y1 with lines linewidth 2 linetype 2, \
     datafile using ($1-1):($4) axes x1y1 with lines linewidth 2 linetype 7, \
     datafile using ($1-1):($5) axes x1y2 with lines linewidth 2 linetype 4

unset multiplot
