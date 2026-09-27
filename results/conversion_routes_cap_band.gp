deployed = "conversion_routes_main.csv"
tree     = "conversion_routes_local.csv"
escrow   = "conversion_routes_main_followsCollateral.csv"
cap      = "conversion_routes_main_leverageCap.csv"
set datafile separator comma
load "style.gp"
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1100,800 background rgb 'gray90'; set output 'conversion_routes_cap_band.png'" conversion_routes_cap_band.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 1100 800 background rgb "gray90" }

# The same measurement as `conversion_routes.gp`, over the NARROW BAND where `K = 20` binds - and where the
# leverage cap's floor sits. Colour is the rule, dash is the route, marker is the market (`style.gp`).
#
# It needs its own graph because the whole of it happens between ratios of 1.00 and 1.06 - three percent of
# the full sweep, where the lines cross and the interesting one is a factor of five. On the full graph it is
# a single pixel column.
#
# TWO RULES CARRY THE SAME `K = 20`, AND THE BAND IS WHERE THEY DIFFER. `K/(K-1)` = 20/19 = 1.0526 is where
# the deployed cap lets go - the deployed leverage reads 20.0000 at every ratio up to 1.05 and falls away
# above it - and it is exactly where the leverage cap's floor sits: refused at 1.0525, sold at 1.0528. The same
# number from two sides. What each does BELOW it is the whole difference:
#
#   ratio   deployed conversion pays   by hand pays   leverage cap
#   1.01    0.204                      1.000          refused - nothing paid, nothing taken
#   1.02    0.408                      1.000          refused
#   1.03    0.612                      1.000          refused
#   1.04    0.816                      1.000          refused
#   1.05    1.020                      1.000          refused
#   1.06    parity                     1.000          1.000, both routes
#
# So at 1.01 a holder doing the move BY HAND is paid five times what the pool is paid for the same move, at
# the same instant, on the same market. The deployed cap does not bound the hand route - it bounds only the
# conversion, which is the leg a stability pool has no choice but to take. The leverage cap bounds both
# routes alike, by declining both.
#
# The straight line is the giveaway. The deployed conversion pays 0.204, 0.408, 0.612, 0.816 - exactly 0.204
# per step - because it returns a FLAT 20 tokens across the whole band while the price rises linearly. A
# payment that is constant in COUNT while the price moves is not a payment at a price at all. The bottom panel
# shows the count: the deployed hand route's count falls as the price rises, its conversion is flat at 20, and
# the cap's conversion is the hand route's count from the floor up and nothing below it.
#
# THE TWO ESCROW RULES HAVE NO BAND. They sit on 1.0000 through all of it, and their conversion and hand
# routes are the same number to the last digit, because nothing truncates either.

set colorsequence default
set xrange [0.98:1.14]
set xtics 0.02

# Columns: 1 collateral ratio, 2 conversion tokens, 3 retail tokens, 4 rebalance tokens, 5 leverage ratio,
#          6 leveraged price, 7 conversion value, 8 retail value, 9 pegged given up
fair(v, g) = (g == 0 || v == 0 ? NaN : v / g)
nz(v) = (v == 0 ? NaN : v)
floor_ratio = 20.0 / 19

set lmargin at screen 0.10
set rmargin at screen 0.97

set multiplot layout 2,1 title "conversion\\_routes\\_cap\\_band.gp - the band where K = 20 binds, all four rules" font ",11"

# ─── what each route pays, where the cap binds ───
set ylabel "value back per value given"
set yrange [0:1.25]
set arrow 1 from graph 0, first 1 to graph 1, first 1 @fair_line
set label 1 "a fair route" at 0.985, 1.08 textcolor "black" font ",9"
set arrow 2 from floor_ratio, graph 0 to floor_ratio, graph 1 @floor_line
set label 2 "K/(K-1) = 1.0526: the deployed cap lets go,\nthe leverage cap's floor" at 1.056, 0.55 textcolor "gray20" font ",9"
plot \
     deployed using 1:(fair($8, $9)) with linespoints @deployed_main_every @q_second title n_deployed.", by hand", \
     deployed using 1:(fair($7, $9)) with linespoints @deployed_main_every @q_first  title n_deployed.", conversion", \
     tree     using 1:(fair($7, $9)) with linespoints @tree_local_every    @q_first  title n_tree.", conversion", \
     escrow   using 1:(fair($7, $9)) with linespoints @escrow_main_every   @q_first  title n_escrow.", conversion", \
     cap      using 1:(fair($7, $9)) with linespoints @cap_main_every      @q_first  title n_cap.", conversion", \
     cap      using 1:(fair($8, $9)) with linespoints @cap_main_every      @q_second title n_cap.", by hand"
unset arrow 1
unset arrow 2
unset label 1
unset label 2

# ─── the count that produces it: flat where it should be falling ───
set ylabel "leveraged tokens per pegged"
set logscale y
set yrange [1:200]
set format y "%g"
set xlabel "collateral ratio"
set arrow 3 from floor_ratio, graph 0 to floor_ratio, graph 1 @floor_line
plot \
     deployed using 1:(nz($3)) with linespoints @deployed_main_every @q_second title n_deployed.", by hand", \
     deployed using 1:(nz($2)) with linespoints @deployed_main_every @q_first  title n_deployed.", conversion", \
     tree     using 1:(nz($2)) with linespoints @tree_local_every    @q_first  title n_tree.", conversion", \
     escrow   using 1:(nz($2)) with linespoints @escrow_main_every   @q_first  title n_escrow.", conversion", \
     cap      using 1:(nz($2)) with linespoints @cap_main_every      @q_first  title n_cap.", conversion"
unset arrow 3
unset logscale y

unset multiplot
