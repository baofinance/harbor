datafile = "rounded_anchor_knee.csv"
set datafile separator comma
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'rounded_anchor_knee.png'" rounded_anchor_knee.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'rounded_anchor_knee.pdf'" rounded_anchor_knee.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 780 820 background rgb "gray90" }

# Two rules for dividing the collateral's value between the anchor and the sail, read off the SAME market
# at the same moment - the alternative's code installed over the market's own storage, so the two
# readings differ in the rule and in nothing else.
#
# "Current" below is the implementation as it stands; "proposed" is the rounded, shifted knee.
#
# The current rule gives the anchor `min(1, collateralRatio)` and the sail whatever is left. That is why
# the sail runs to nothing at the peg and the conversion rate runs to infinity with it. The alternative
# shifts the sloping arm down to `(1-delta) x collateralRatio`, so the sail always keeps `delta` of the
# collateral, and rounds the corner where the two arms meet.
#
# The UPPER panel is the whole cost of it. Below the peg the anchor gives up one percent - that is delta,
# and it is what buys the floor. Through a band under two hundredths of a ratio wide the give-up falls
# away, and ABOVE 1.0152 the two rules are identical to the last of eighteen decimal places. Every
# production rebalance threshold - 1.05, 1.15, 1.25, 1.30 - is in that identical region, so at the ratios
# markets are actually run at there is no adjustment at all, not a small one.
#
# That exactness is why the corner is rounded with a quadratic smooth minimum rather than blended. A blend
# only ever approaches one, leaving a stablecoin reporting 0.999999999999999999 for ever, which is worse
# than a visible adjustment because no reader can tell it from a rounding fault.
#
# The LOWER panel is what it buys, over the whole range the market can reach, and both lines are MEASURED
# by putting an anchor token through the conversion rather than inferred from the prices above. The rule
# in force pays out without limit as the peg is approached - 1707 per anchor token a twentieth of a
# percent above it - and below the peg it cannot price the conversion at all, so it refuses and the line
# stops. The alternative holds flat at NINETY-NINE, which is `(1-delta)/delta`, and keeps pricing all the
# way down.
#
# Measuring rather than inferring is what makes that column worth having. The two prices always imply a
# fair rate, so a column derived from them would look identical under any rule that prices fairly and
# could never show what one that does not - a cap, or a refusal - would really pay. It also caught a fault
# in the alternative: valuing the anchor at one rather than at what it is worth, which the base gets away
# with only because it refuses wherever the anchor is worth less.
#
# THE SAMPLE POINTS WERE CHOSEN BY THE DATA. The sweep steps a whole collateral ratio at a time and the
# refinement inserted 55 extra samples, every one of them between 0.96 and 5.4, then reported that nothing
# needed inserting from 5.9 to 999.9 across 995 points. That second finding is the one worth having: the
# candidate this rule replaced behaved well everywhere anyone was looking and failed far above it.

set grid xtics ytics
set colorsequence default
set lmargin at screen 0.13
set rmargin at screen 0.96

set multiplot title "rounded_anchor_knee.gp" noenhanced

# ─────────────── what the anchor gives up, and where it stops giving anything
set tmargin at screen 0.94
set bmargin at screen 0.60

set xrange [0.995:1.022]
set yrange [0.9838:1.0012]
set format x "%.3f"
set format y "%.4f"
set xlabel "collateral ratio"
set ylabel "anchor price"
set key at screen 0.5, screen 0.52 center top horizontal maxcols 2 spacing 1.2

# Worth exactly one. The rounded rule rejoins this and stays on it, rather than approaching it.
set arrow 1 from graph 0, first 1 to graph 1, first 1 nohead dashtype 3 linecolor rgb "gray30"
# Where the two rules become identical, and every production threshold sits to the right of it.
set arrow 2 from 1.0152, graph 0 to 1.0152, graph 1 nohead dashtype 2 linewidth 2 linecolor rgb "red"
set label 2 "identical beyond here" at 1.0162, 0.9905 left textcolor "red"

# $1 = collateral ratio, $2 = anchor price now, $3 = anchor price under the rounded knee
plot \
     datafile using 1:2 with lines linewidth 3 linetype 1 title "current", \
     datafile using 1:3 with lines linewidth 3 linetype 7 title "proposed: rounded, shifted knee"

# ─────────────── what one anchor token buys, over everything the market can reach
set tmargin at screen 0.44
set bmargin at screen 0.18

unset arrow 1
unset arrow 2
unset label 2
set logscale y
# Linear and zoomed on the distressed end. The sweep runs to a thousand and the refinement reported
# nothing worth a sample above 5.9, so the far field is established rather than drawn - putting it on the
# axis would squeeze everything that happens into a sliver at the left.
set xrange [0.895:1.06]
set yrange [1:3000]
set format x "%.2f"
set format y "10^{%T}"
set xlabel "collateral ratio"
set ylabel "sail issued per anchor token"
set key at screen 0.5, screen 0.10 center top horizontal maxcols 2 spacing 1.2

# The cap the floor implies, per anchor token: the anchor is worth at most one and the sail at least
# `delta` of the collateral over the supply, so the rate cannot pass `(1-delta)/delta`.
set arrow 3 from graph 0, first 99 to graph 1, first 99 nohead dashtype 2 linecolor rgb "red"
set label 3 "(1-delta)/delta = 99" at 1.055, 135 right textcolor "red"

# $8 = sail per anchor now, $9 = under the rounded knee, both measured by performing the conversion. The
# first is absent below the peg, where the conversion refuses outright - there is nothing the anchor can
# be settled in there, so there is no number to draw.
plot \
     datafile using 1:8 with lines linewidth 3 linetype 1 title "current", \
     datafile using 1:9 with lines linewidth 3 linetype 7 title "proposed: rounded, shifted knee"

unset multiplot
