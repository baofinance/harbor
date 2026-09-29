deployed = "rebalance_sequence_main.csv"
tree     = "rebalance_sequence_local.csv"
v3       = "rebalance_sequence_main_v3.csv"
set datafile separator comma
load "style.gp"
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1100,1300 background rgb 'gray90'; set output 'rebalance_sequence.png'" rebalance_sequence.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,11 background rgb 'gray90'; set output 'rebalance_sequence.pdf'" rebalance_sequence.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 1100 1300 background rgb "gray90" }

# A REAL rebalance from every starting ratio, on the DEPLOYED contracts, the TREE on a local deploy, and the
# V3 UPGRADE. Colour is the rule; the marker is the market - two of the three are the DEPLOYED market, same
# proxies, same pools, same funding, same pinned block, and only the rule behind them differs; the tree's own
# run is a local deploy of this tree's chain, founded with the same collateral (`style.gp`). The tree and the
# upgrade share a colour because they are the same rule. Nothing is normalised.
#
# WHAT VARIES BETWEEN THE DEPLOYED RUN AND THE UPGRADE IS THE WHOLE v3 UPGRADE, NOT ONE CONTRACT ALONE. The
# minter, the manager and BOTH pools move together, because that is the only upgrade that exists:
# `StabilityPoolManager_v2` calls `maxAssetLoss()` on each pool and that function arrived with
# `StabilityPool_v3`. `results/provenance_*.csv` records the implementation behind every proxy in each run.
#
# THIS MARKET HAS A LEVERAGED POOL ONLY, holding 0.4 of the pegged supply, and no collateral pool. That shapes
# what the tree can do below its floor, and is why the pool it pays there is paid in collateral.
#
# THE TOP PANEL IS REACH. The deployed rule restores the market to the 1.3 threshold from a starting ratio of
# 0.780 and no lower, sub-peg starts included: reaching 1.3 from a ratio `r` burns `1 - r/1.3` of the pegged
# supply, the pool holds 0.4 of it, and `1.3 x (1 - 0.4)` is 0.78 exactly. REACH IS BOUNDED BY POOL SIZE. The
# tree and the upgrade have no point at or below the peg - there `rebalance()` is refused
# (`CollateralRatioNotAbovePeg`), a redemption taking its share of the backing with it and moving nothing -
# and from the floor of 1.0526 upward they land where the deployed rule lands, with its own figures. Between
# the peg and the floor they take the COLLATERAL ROUTE towards the floor, paying the leveraged pool in
# collateral, and reach only as far as the pool goes: from 1.02 the pool's whole 0.4 lifts the ratio to 1.033,
# where the floor would have needed 62% of the supply. The two files agree at every ratio: the upgrade behaves
# on production state as the tree does locally.
#
# THE SECOND PANEL IS THE LEVERAGE RATIO EACH RULE REPORTS BEFORE IT REBALANCES. Below a collateral ratio of
# one the deployed figure pins at exactly 20 - a CAP, engaged because the leveraged claim has gone to zero and
# something has to bound what a conversion mints. Capping what is minted is capping what the converter is
# PAID. The tree reports `CR/(CR-1)` - the true figure, measured identical in `leverage_sensitivity.gp` - above
# the peg, 101 at 1.01 and 51 at 1.02 where the deployed rule says 20, and below the peg the encoding for a
# claim of nothing, which is not drawn.
#
# THE THIRD PANEL IS WHAT THE POOL IS PAID, AGAINST WHAT IT GAVE UP - the fairness line. Columns 10 and 11 are
# the VALUE of the leveraged tokens a rebalance returned and the value of the pegged it took, so their ratio is
# what the pool got back per unit surrendered: 1.0 is a fair exchange and anything below it is the pool
# subsidising the rescue. Read it as a comparison rather than as an absolute - a large rebalance is a path, and
# valuing what went out at the opening price against what came back at the closing one brackets the truth from
# either side. All series are measured identically, so the GAPS between them are exact even where the level is
# approximate. The deployed rule's junior claim is worth exactly zero below the peg, which is why its line sits
# on zero there: you cannot be paid more than the thing you are buying is worth, and that rule has made it
# worth nothing. The tree pays the marginal rate in bulk wherever it pays in leveraged - 1.0 at every ratio
# from the floor up - because nothing dilutes. COLUMN 10 COUNTS LEVERAGED VALUE ONLY, so where the tree paid the
# pool in collateral - between the peg and the floor - a point here would read as nothing paid, and those rows
# are not drawn: the measurement does not yet record the collateral leg's payment.
#
# THE BOTTOM PANEL IS THE LEVERAGED PRICE EACH RULE QUOTED (lines) AND HOW MANY TOKENS THE POOL WAS HANDED
# (points). The deployed rule's price is zero below the peg, so the axis cannot show it; its count there is the
# capped 20 per pegged, worth nothing. The tree's price is the deployed price - the same residual, no escrow -
# drawn from its floor up, because below it nothing is sold.

set colorsequence default
set xrange [0:1.65]

# Columns: 1 start CR, 2 rebalance index, 3 collateral ratio, 4 leverage ratio, 5 leveraged price,
#          6 pegged supply, 7 collateral pool pegged, 8 leveraged pool pegged, 9 leveraged returned,
#          10 leveraged value returned, 11 pegged value given up
#
# Index 0 is the row recorded BEFORE any rebalance at that starting ratio; 1 is the first rebalance, and a rule
# carries further indices where the measurement calls again. `before` and `after` below select those two.
#
# A REBALANCE THAT MOVED NOTHING IS NOT DRAWN AS ONE. The measurement records a pass whenever it calls, and on
# the tree a call between the peg and the floor that finds the pool already spent takes nothing; column 11 is
# zero on exactly those rows. `after` keeps a first pass that took pegged, whatever it paid in - the collateral
# route hands over no leveraged tokens, and the ratio it reached is still where a rebalance left the market.
before(col) = ($2 == 0 ? column(col) : NaN)
after(col)  = ($2 == 1 && $11 > 0 ? column(col) : NaN)
# A report of `uint256.max` is the formula dividing by zero - a claim of nothing - and is not a number to draw.
rep(v) = (v == 0 || v > 1e6 ? NaN : v)
floor_ratio = 20.0 / 19

set lmargin at screen 0.11
set rmargin at screen 0.97

set multiplot layout 4,1 title "rebalance\\_sequence.gp - one rebalance at every collateral ratio: deployed, the tree, and the upgrade" font ",11"

# ─── where a rebalance leaves the market ───
set ylabel "collateral ratio after"
set yrange [0:1.6]
set arrow 1 from graph 0, first 1.3 to graph 1, first 1.3 @threshold_line
set arrow 2 from 1, graph 0 to 1, graph 1 @peg_line
set arrow 3 from floor_ratio, graph 0 to floor_ratio, graph 1 @floor_line
set label 1 "the 1.3 threshold" at 0.05, 1.37 textcolor "gray20" font ",9"
plot \
     deployed using 1:(after(3)) with points @deployed_main_points title n_deployed, \
     tree     using 1:(after(3)) with points @tree_local_points    title n_tree, \
     v3       using 1:(after(3)) with points @tree_main_points     title n_v3, \
     deployed using 1:1          with lines linewidth 1 dashtype 4 linecolor rgb "gray40" title "unrebalanced (y = x)"
unset arrow 1
unset arrow 2
unset arrow 3
unset label 1

# ─── the leverage ratio before: a cap on one, the truth on the other two ───
set ylabel "leverage ratio before"
set logscale y
set yrange [1:200]
set format y "%g"
set arrow 3 from graph 0, first 20 to graph 1, first 20 @threshold_line
set label 2 "K = 20" at 0.05, 25 textcolor "gray20" font ",9"
set arrow 4 from 1, graph 0 to 1, graph 1 @peg_line
plot \
     deployed using 1:(rep(before(4))) with points @deployed_main_points title n_deployed, \
     tree     using 1:(rep(before(4))) with points @tree_local_points    title n_tree, \
     v3       using 1:(rep(before(4))) with points @tree_main_points     title n_v3
unset arrow 3
unset arrow 4
unset label 2
unset logscale y

# ─── what the pool is paid in leveraged, against what it gave up ───
set ylabel "value back / value given"
set yrange [0:1.15]
set format y "%g"
set arrow 5 from graph 0, first 1 to graph 1, first 1 @fair_line
set arrow 6 from 1, graph 0 to 1, graph 1 @peg_line
set arrow 7 from floor_ratio, graph 0 to floor_ratio, graph 1 @floor_line
plot \
     deployed using 1:($2 == 1 && $11 > 0 ? $10 / $11 : NaN) with points @deployed_main_points title n_deployed, \
     tree     using 1:($2 == 1 && $9 > 0 ? $10 / $11 : NaN)  with points @tree_local_points    title n_tree, \
     v3       using 1:($2 == 1 && $9 > 0 ? $10 / $11 : NaN)  with points @tree_main_points     title n_v3
unset arrow 5
unset arrow 6
unset arrow 7

# ─── the leveraged price, and how many tokens the pool was handed ───
set ylabel "price (lines), tokens (points)"
set logscale y
set yrange [1e-4:1e8]
set format y "10^{%T}"
set xlabel "collateral ratio the market was rebalanced from"
set arrow 8 from 1, graph 0 to 1, graph 1 @peg_line
plot \
     deployed using 1:($2 == 0 ? rep($5) : NaN) with lines  linecolor rgb c_deployed linewidth 1 title n_deployed.", price", \
     tree     using 1:($2 == 0 && $1 >= floor_ratio ? rep($5) : NaN) with lines linecolor rgb c_tree linewidth 1 title n_tree.", price", \
     v3       using 1:($2 == 0 && $1 >= floor_ratio ? rep($5) : NaN) with lines linecolor rgb c_tree linewidth 1 dashtype 3 title n_v3.", price", \
     deployed using 1:($2 == 1 ? rep($9) : NaN) with points @deployed_main_points title n_deployed.", tokens", \
     tree     using 1:($2 == 1 ? rep($9) : NaN) with points @tree_local_points    title n_tree.", tokens", \
     v3       using 1:($2 == 1 ? rep($9) : NaN) with points @tree_main_points     title n_v3.", tokens"
unset arrow 8
unset logscale y

unset multiplot
