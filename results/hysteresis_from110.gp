deployed = "hysteresis_main_from110.csv"
tree     = "hysteresis_local_from110.csv"
v3       = "hysteresis_main_v3_from110.csv"
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

# Sixteen rebalances, each from a collateral ratio of 1.1 - ABOVE the leverage floor of 1.0526 and below the
# 1.3 threshold, where every rule can rebalance and every round goes through. The same experiment as
# `hysteresis.gp`, whose sequence from 0.6 the tree refuses to enter; here the question is whether a rule holds
# its terms and its leverage across sixteen rounds that all succeed. Three files: the DEPLOYED contracts, the
# TREE on a local deploy, and the V3 UPGRADE - this tree's minter, manager and pools behind the deployed
# proxies. Colour is the rule, solid and dashed are the two quantities of each panel, marker is the market
# (`style.gp`); the tree and the upgrade share a colour because they are the same rule.
#
# EACH ROUND IS A FRESH 15% FALL. The ratio is put back to 1.1 by writing the collateral price down from
# wherever the last round left it, so the leveraged token is living through sixteen consecutive falls of the
# collateral, and reaching 1.3 from 1.1 burns `1 - 1.1/1.3` = 15.4% of the pegged supply each time. The pool
# holds 0.6 of the supply and is restored before every round, as in `hysteresis.gp`.
#
# THE THREE FILES ARE THE SAME FILE. Every figure in every column agrees to the printed precision, sixteen
# rounds over: the position kept is 1.000000, the increment paid is 1.000000, the ratio after is 1.300000, the
# leverage before is 11.0000, the price falls by exactly a third each round and the count the pool is handed
# rises 2.5x. Above the floor the count cap does not bind at 1.1 - the leverage there is 11, under 20 - so the
# deployed conversion is already fair, and the tree changes nothing it did not need to. And the upgrade on the
# deployed proxies lands on the tree's own figures, which is what a measurement of the pending upgrade is for:
# the same code gives the same answers on production state as on a local deploy. (The deployed manager's
# configured 1% keeper bounty is zeroed for the run, as the harness's own managers carry none; before that it
# read 0.99 paid, and the 0.01 was the bounty, not the rule.)
#
# THE THIRD PANEL IS THE LEVERAGE EACH RULE CARRIES INTO THE NEXT ROUND, and it is 11.0000 at every round on all
# three - `1.1/(1.1-1)`, no escrow, no state carried from one round to the next. Nothing accrues on a
# conversion; sixteen fair rebalances leave the leveraged token exactly the instrument it was.
#
# THE BOTTOM PANEL IS THE PRICE AND THE COUNT, AND IT IS THE TOKEN WORKING, NOT BREAKING. The price falls by
# exactly a third each round - 0.1, 0.0333, 0.0111 - and the count the pool is handed rises 2.5x. A token with
# leverage 11 through a 15.4% fall of its collateral is worth a third of what it was; the residual is reset to
# a tenth of a supply that shrank, over a leveraged supply that grew. None of this is dilution - each rule pays
# fairly each round, the top panel says so - it is sixteen falls priced through the leverage each rule actually
# offers.

set colorsequence default
set xrange [0.5:16.5]
set xtics 1

# Columns: 1 round, 2 CR before, 3 CR after, 4 leveraged price before, 5 leveraged price after,
#          6 leveraged returned, 7 value returned, 8 value given up, 9 value back per given, 10 phi (zero: no
#          escrow on any rule measured here), 11 leverage ratio before, 12 minter collateral, 13 holding before,
#          14 holding after
nz(v) = (v == 0 ? NaN : v)

set lmargin at screen 0.10
set rmargin at screen 0.97

set multiplot layout 4,1 title "hysteresis\\_from110.gp - sixteen rebalances from a collateral ratio of 1.1, above the floor: deployed, the tree, and the upgrade" font ",11"

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
     v3       using 1:($14/$13) with linespoints @tree_main_every     @q_first  title n_v3.", position", \
     v3       using 1:9         with linespoints @tree_main_every     @q_second title n_v3.", increment"
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
     v3       using 1:3 with linespoints @tree_main_every     @q_first title n_v3
unset arrow 2
unset arrow 3
unset label 2
unset label 3

# ─── the leverage each rule carries into the next round ───
set ylabel "leverage ratio before"
set yrange [0:25]
set arrow 4 from graph 0, first 20 to graph 1, first 20 @threshold_line
set label 4 "K = 20" at 0.7, 21.5 textcolor "gray20" font ",9"
plot \
     deployed using 1:(nz($11)) with linespoints @deployed_main_every @q_first title n_deployed, \
     tree     using 1:(nz($11)) with linespoints @tree_local_every    @q_first title n_tree, \
     v3       using 1:(nz($11)) with linespoints @tree_main_every     @q_first title n_v3
unset arrow 4
unset label 4

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
     v3       using 1:(nz($6)) with linespoints @tree_main_every     @q_first  title n_v3.", count", \
     v3       using 1:(nz($4)) with linespoints @tree_main_every     @q_second title n_v3.", price"
unset logscale y
set ytics autofreq

unset multiplot
