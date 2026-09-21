datafile = "conversion_refusal_boundary.csv"
set datafile separator comma
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'conversion_refusal_boundary.png'" conversion_refusal_boundary.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'conversion_refusal_boundary.pdf'" conversion_refusal_boundary.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 780 820 background rgb "gray90" }

# Two rules could stop a conversion before the sail price reaches zero, and this is the difference
# between them. A FLOOR ON THE SAIL PRICE is the mirror of the rule the anchor already has; a CAP ON THE
# LEVERAGE RATIO is what the contract already tests for and then declines to act on. Each floor here is
# paired with the cap it agrees with at one sail token per anchor token, `1/(K-1)` against `K`, so the
# pairs start together by construction and the graph is what becomes of them either side of that.
#
# The UPPER panel is the finding, and it is not close. The leverage cap's boundary is DEAD FLAT across a
# four-thousandfold range of sail supply - `K/(K-1)`, and nothing else enters it. The price floor's
# boundary climbs in proportion to the supply, because the sail price is the residual divided by the
# supply while the leverage ratio is the collateral value divided by the same residual and involves no
# supply at all. At forty-six sail per anchor the 1/4 floor refuses everything below a collateral ratio
# of TWELVE, which is to say it refuses everything.
#
# That drift is also self-feeding, which no static reading of the panel shows: every conversion issues
# sail, so every conversion moves a price-floor market to the right along this axis and pushes its own
# boundary up. A leverage cap has no such term.
#
# The LOWER panel is why the leverage cap is the better instrument rather than merely the more stable
# one. It shows what ONE anchor token converted at each rule's own edge does to the whole sail supply.
# The leverage cap holds that to a flat 0.1% whatever the market holds, because the quantity it admits is
# proportional to the supply already there. The price floor admits a fixed RATE instead - nineteen sail
# per anchor, whatever - so it grows a thin supply by 9.5% and a thick one by nothing: loosest exactly
# when the sail buffer is thinnest, which is the worst moment for it to be.

set grid xtics ytics
set colorsequence default
set lmargin at screen 0.13
set rmargin at screen 0.96

set multiplot title "conversion_refusal_boundary.gp" noenhanced

# ─────────────── where each rule starts refusing
set tmargin at screen 0.93
set bmargin at screen 0.60

set logscale x
set logscale y
set xrange [0.005:200]
set yrange [0.98:30]
set format x "10^{%T}"
set xlabel "sail supply per anchor token"
set ylabel "collateral ratio at or below which the conversion refuses"
set ytics ("1.0" 1, "1.05" 1.05, "1.25" 1.25, "2" 2, "5" 5, "12" 12, "30" 30)
set key at screen 0.5, screen 0.525 center top horizontal maxcols 3 spacing 1.2

# The peg. A boundary resting on this line refuses nothing a solvent market would ask for.
set arrow 1 from graph 0, first 1 to graph 1, first 1 nohead dashtype 2 linecolor rgb "red"

# $1 = sail per anchor; $2..$4 = leverage caps; $5..$7 = price floors
plot \
     datafile using 1:2 with linespoints linewidth 3 linetype 1 pointtype 7 title "leverage cap 5", \
     datafile using 1:3 with linespoints linewidth 3 linetype 2 pointtype 7 title "leverage cap 20", \
     datafile using 1:4 with linespoints linewidth 3 linetype 3 pointtype 7 title "leverage cap 100", \
     datafile using 1:5 with linespoints linewidth 2 dashtype 2 linetype 1 pointtype 6 title "price floor 1/4", \
     datafile using 1:6 with linespoints linewidth 2 dashtype 2 linetype 2 pointtype 6 title "price floor 1/19", \
     datafile using 1:7 with linespoints linewidth 2 dashtype 2 linetype 3 pointtype 6 title "price floor 1/99"

# ─────────────── what one conversion at that edge does to the supply
set tmargin at screen 0.42
set bmargin at screen 0.20

unset arrow 1
unset logscale y
set format y "%.2f"
set yrange [0.99:1.12]
set ytics 0.02
set xlabel "sail supply per anchor token"
set ylabel "sail supply multiple, one anchor converted at the edge"
set key at screen 0.5, screen 0.10 center top horizontal maxcols 2 spacing 1.2

# A conversion that leaves the sail supply where it found it.
set arrow 2 from graph 0, first 1 to graph 1, first 1 nohead dashtype 2 linecolor rgb "red"

plot \
     datafile using 1:10 with linespoints linewidth 3 linetype 2 pointtype 7 title "at the leverage cap 20 edge", \
     datafile using 1:11 with linespoints linewidth 2 dashtype 2 linetype 2 pointtype 6 title "at the price floor 1/19 edge"

unset multiplot
