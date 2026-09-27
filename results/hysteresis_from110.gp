deployed = "hysteresis_main_from110.csv"
tree     = "hysteresis_local_from110.csv"
escrow   = "hysteresis_local_followsCollateral_from110.csv"
cap      = "hysteresis_local_leverageCap_from110.csv"
set datafile separator comma
load "style.gp"
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1100,1300 background rgb 'gray90'; set output 'hysteresis_from110.png'" hysteresis_from110.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 1100 1300 background rgb "gray90" }

# Sixteen rebalances, each from a collateral ratio of 1.1 - ABOVE the leverage cap's floor of 1.0526 and below
# the 1.3 threshold, where every one of the four rules can rebalance and every round goes through. The same
# experiment as `hysteresis.gp`, whose sequence from 0.6 two of the rules cannot enter; this is where the cap
# actually does something, and the question becomes which rule holds its terms and its leverage across sixteen
# rounds that all succeed. Colour is the rule, solid and dashed are the two quantities of each panel, marker is
# the market (`style.gp`).
#
# EACH ROUND IS A FRESH 15% FALL. The ratio is put back to 1.1 by writing the collateral price down from
# wherever the last round left it, so the leveraged token is living through sixteen consecutive falls of the
# collateral, and reaching 1.3 from 1.1 burns `1 - 1.1/1.3` = 15.4% of the pegged supply each time. The pool
# holds 0.6 of the supply and is restored before every round, as in `hysteresis.gp`.
#
# THE TOP PANEL: EVERY RULE PAYS ITS DEPOSITOR FAIRLY, EVERY ROUND. All four keep the position at exactly
# 1.000000 in all sixteen rounds, and pay 1.000000 of the conversion's value back. Above the floor the count
# cap does not bind at 1.1 - the leverage there is 11, under 20 - so the deployed conversion is fair, and the
# escrow rules are fair above the peg as they are everywhere. (The deployed manager's configured 1% keeper
# bounty is zeroed for the run, as the harness's own managers carry none; before that it read 0.99 paid, and
# the 0.01 was the bounty, not the rule.)
#
# THE SECOND PANEL IS WHERE THE TREE FAILS. Three rules reach 1.3 in every round. The tree reaches it in the
# first five and then falls short - 1.274 in round six, 1.2545 in round eight, 1.196 in round sixteen - because
# above the peg too its conversion moves backing into escrow, so each round there is less collateral behind
# the pegged for the next conversion to lift. A rebalance that pays fairly and repairs less each time it is
# run.
#
# THE THIRD PANEL IS THE LEVERAGE EACH RULE CARRIES INTO THE NEXT ROUND, and the reason the tree fails. The
# deployed rule and the cap report exactly 11.0000 at every round - `1.1/(1.1-1)`, no escrow, no state - and
# `phi` is zero. The escrow candidate holds 6.9667 and `phi` at 0.0579, flat to four decimals for sixteen
# rounds: its escrow follows the collateral, so a conversion moves nothing into it. The tree starts at the same
# 6.9667 and loses it: 4.45 after round two, 1.05 after round four, 0.44, 0.18, 0.076, and 0.0001 by round
# sixteen, as `phi` runs from 0.058 to 15,667. Sixteen rebalances from a healthy ratio, each one fair, and the
# leveraged token is a collateral wrapper. That is the aged-sweep finding on the axis a depositor lives on:
# the damage is not a sub-peg effect, it accrues on every conversion the tree performs.
#
# THE BOTTOM PANEL IS THE PRICE AND THE COUNT, AND IT IS THE TOKEN WORKING, NOT BREAKING. On the deployed rule
# and the cap the price falls by exactly a third each round - 0.1, 0.0333, 0.0111 - and the count the pool is
# handed rises 2.5x. A token with leverage 11 through a 15.4% fall of its collateral is worth a third of what
# it was; the residual is reset to a tenth of a supply that shrank, over a leveraged supply that grew. The
# escrow candidate's price falls 0.43x a round, less steeply, because its escrow is unlevered collateral that
# does not fall with the residual; the tree's falls 0.52x and then ever more slowly as the escrow becomes the
# whole claim. None of this is dilution - each rule pays fairly each round, the top panel says so - it is
# sixteen falls priced through the leverage each rule actually offers.

set colorsequence default
set xrange [0.5:16.5]
set xtics 1

# Columns: 1 round, 2 CR before, 3 CR after, 4 leveraged price before, 5 leveraged price after,
#          6 leveraged returned, 7 value returned, 8 value given up, 9 value back per given, 10 phi,
#          11 leverage ratio before, 12 minter collateral, 13 holding before, 14 holding after
nz(v) = (v == 0 ? NaN : v)

set lmargin at screen 0.10
set rmargin at screen 0.97

set multiplot layout 4,1 title "hysteresis\\_from110.gp - sixteen rebalances from a collateral ratio of 1.1, above the floor, all four rules" font ",11"

# ─── what the depositor is paid, round by round ───
set ylabel "kept per rebalance"
set yrange [0.98:1.01]
set arrow 1 from graph 0, first 1 to graph 1, first 1 @fair_line
set label 1 "fair" at 0.7, 1.0035 textcolor "black" font ",9"
plot \
     deployed using 1:($14/$13) with linespoints @deployed_main_every @q_first  title n_deployed.", position", \
     deployed using 1:9         with linespoints @deployed_main_every @q_second title n_deployed.", increment", \
     tree     using 1:($14/$13) with linespoints @tree_local_every    @q_first  title n_tree.", position", \
     tree     using 1:9         with linespoints @tree_local_every    @q_second title n_tree.", increment", \
     escrow   using 1:($14/$13) with linespoints @escrow_local_every  @q_first  title n_escrow.", position", \
     escrow   using 1:9         with linespoints @escrow_local_every  @q_second title n_escrow.", increment", \
     cap      using 1:($14/$13) with linespoints @cap_local_every     @q_first  title n_cap.", position", \
     cap      using 1:9         with linespoints @cap_local_every     @q_second title n_cap.", increment"
unset arrow 1
unset label 1

# ─── where each round leaves the market ───
set ylabel "collateral ratio after"
set yrange [1.0:1.35]
set arrow 2 from graph 0, first 1.3 to graph 1, first 1.3 @threshold_line
set label 2 "the 1.3 threshold" at 0.7, 1.315 textcolor "gray20" font ",9"
set arrow 3 from graph 0, first 1.1 to graph 1, first 1.1 @peg_line
set label 3 "each round starts at 1.1" at 0.7, 1.085 textcolor "gray30" font ",9"
plot \
     deployed using 1:3 with linespoints @deployed_main_every @q_first title n_deployed, \
     tree     using 1:3 with linespoints @tree_local_every    @q_first title n_tree, \
     escrow   using 1:3 with linespoints @escrow_local_every  @q_first title n_escrow, \
     cap      using 1:3 with linespoints @cap_local_every     @q_first title n_cap
unset arrow 2
unset arrow 3
unset label 2
unset label 3

# ─── the leverage each rule carries into the next round, and phi ───
set ylabel "leverage ratio (solid)\nphi (dashed)"
set logscale y
set yrange [1e-5:1e5]
set format y "10^{%T}"
plot \
     deployed using 1:(nz($11)) with linespoints @deployed_main_every @q_first  title n_deployed.", leverage", \
     tree     using 1:(nz($11)) with linespoints @tree_local_every    @q_first  title n_tree.", leverage", \
     tree     using 1:(nz($10)) with linespoints @tree_local_every    @q_second title n_tree.", phi", \
     escrow   using 1:(nz($11)) with linespoints @escrow_local_every  @q_first  title n_escrow.", leverage", \
     escrow   using 1:(nz($10)) with linespoints @escrow_local_every  @q_second title n_escrow.", phi", \
     cap      using 1:(nz($11)) with linespoints @cap_local_every     @q_first  title n_cap.", leverage"
unset logscale y

# ─── price and count on ONE axis ───
set ylabel "tokens returned (solid)\nprice (dashed)"
set logscale y
set yrange [1e-10:1e14]
set ytics 1e-10, 1e4
set format y "10^{%T}"
set xlabel "rebalance round, each from a collateral ratio of 1.1"
plot \
     deployed using 1:(nz($6)) with linespoints @deployed_main_every @q_first  title n_deployed.", count", \
     deployed using 1:(nz($4)) with linespoints @deployed_main_every @q_second title n_deployed.", price", \
     tree     using 1:(nz($6)) with linespoints @tree_local_every    @q_first  title n_tree.", count", \
     tree     using 1:(nz($4)) with linespoints @tree_local_every    @q_second title n_tree.", price", \
     escrow   using 1:(nz($6)) with linespoints @escrow_local_every  @q_first  title n_escrow.", count", \
     escrow   using 1:(nz($4)) with linespoints @escrow_local_every  @q_second title n_escrow.", price", \
     cap      using 1:(nz($6)) with linespoints @cap_local_every     @q_first  title n_cap.", count", \
     cap      using 1:(nz($4)) with linespoints @cap_local_every     @q_second title n_cap.", price"
unset logscale y
set ytics autofreq

unset multiplot
