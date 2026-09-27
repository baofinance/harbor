deployed = "rebalance_sequence_main.csv"
tree     = "rebalance_sequence_local.csv"
escrow   = "rebalance_sequence_main_followsCollateral.csv"
cap      = "rebalance_sequence_main_leverageCap.csv"
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

# A REAL rebalance from every starting ratio, on all four rules. Colour is the rule; the marker is the market -
# three of the four are the DEPLOYED market, same proxies, same pools, same funding, same pinned block, and only
# the rule behind them differs; the tree rule has no deployed-market run and is measured on a local deploy of
# this tree's chain, founded with the same collateral (`style.gp`). Nothing is normalised.
#
# WHAT VARIES BETWEEN THE DEPLOYED RUN AND THE OTHERS IS THE WHOLE v3 UPGRADE, NOT ONE RULE ALONE. The minter,
# the manager and BOTH pools move together, because that is the only upgrade that exists:
# `StabilityPoolManager_v2` calls `maxAssetLoss()` on each pool and that function arrived with
# `StabilityPool_v3`. `results/provenance_*.csv` records the implementation behind every proxy in each run.
#
# THE TOP PANEL IS REACH, AND ITS FLOOR IS THE POOL'S, NOT ANY RULE'S. The deployed rule and the escrow
# candidate both restore the market to the 1.3 threshold from a starting ratio of 0.780 and no lower - the SAME
# floor, to three decimals, 57 of 160 sampled ratios each. Reaching 1.3 from a ratio `r` burns `1 - r/1.3` of
# the pegged supply, the leveraged pool holds 0.4 of it, and `1.3 x (1 - 0.4)` is 0.78 exactly. REACH IS
# BOUNDED BY POOL SIZE. The tree cannot reach the threshold from anywhere below about 1.03: below the peg its
# conversion moves backing into escrow and leaves the ratio where it was, so its points sit on `y = x` there
# however many passes it takes. The leverage cap reaches the threshold from its floor of 1.0526 upward and has
# no point below it, for the reason given with `after` below.
#
# WHAT DOES DIFFER IS HOW MANY PASSES IT TAKES. The deployed rule rebalances exactly ONCE at each of its
# points - one call consumes the pool and there is nothing left to do. The escrow rules average several passes
# and reach the cap of 12. That is a real difference but it is NOT evidence about the escrow: the manager sizes
# each pass against `maxAssetLoss`, the pools answering it are v3 only in the upgraded runs, and pool solvency
# headroom is the obvious alternative explanation. It is recorded here as unexplained.
#
# THE SECOND PANEL IS THE LEVERAGE RATIO EACH RULE REPORTS BEFORE IT REBALANCES. Below a collateral ratio of
# one the deployed figure pins at exactly 20 - a CAP, engaged because the leveraged claim has gone to zero and
# something has to bound what a conversion issues. Capping what is issued is capping what the converter is
# PAID. The escrow rules report a flat 19 there, an escrow in place of a cap. The leverage cap reports
# `CR/(CR-1)` - the true figure, measured identical in `leverage_sensitivity.gp` - and only from its floor up,
# where it is at most 20 by construction.
#
# THE THIRD PANEL IS WHAT THE POOL IS PAID, AGAINST WHAT IT GAVE UP - the fairness line. Columns 10 and 11 are
# the VALUE of the leveraged tokens a rebalance returned and the value of the pegged it took, so their ratio is
# what the pool got back per unit surrendered: 1.0 is a fair exchange and anything below it is the pool
# subsidising the rescue. Read it as a comparison rather than as an absolute - a large rebalance is a path, and
# valuing what went out at the opening price against what came back at the closing one brackets the truth from
# either side. All series are measured identically, so the GAPS between them are exact even where the level is
# approximate.
#
# THIS PANEL AND `conversion_routes.gp` LOOK LIKE THEY DISAGREE, AND THE DIFFERENCE IS THE POINT. There the
# escrow candidate returns 1.0000 at every ratio; here it returns 0.1163 below a ratio of about 0.6. Both are
# right, and they are the MARGINAL and the BULK rate of the same exchange: `conversion_routes` prices a
# ONE-TOKEN probe, the rate on offer; this prices a REAL rebalance, which converts the pool's entire holding
# and moves the price against itself while it does so. THE ESCROW IS A CEILING ON THE BULK RATE. Below the peg
# the leveraged claim IS the escrow, so however much pegged is converted the whole exchange cannot return more
# than the escrow is worth. The tree does not have that ceiling - it pays fairly in bulk, because it does not
# dilute - and does not repair the market either. The deployed rule's junior claim is worth exactly zero below
# the peg, which is why its line sits on zero: you cannot be paid more than the thing you are buying is worth,
# and that rule has made it worth nothing. The leverage cap pays the marginal rate in bulk wherever it pays at
# all - 1.000000 at every one of its 33 ratios - because nothing dilutes; below its floor it pays nothing and
# takes nothing.
#
# THE BOTTOM PANEL IS THE LEVERAGED PRICE EACH RULE QUOTED (lines) AND HOW MANY TOKENS THE POOL WAS HANDED
# (points). The deployed rule's price is zero below the peg, so the axis cannot show it; its count there is the
# capped 20 per pegged, worth nothing.

set colorsequence default
set xrange [0:1.65]

# Columns: 1 start CR, 2 rebalance index, 3 collateral ratio, 4 leverage ratio, 5 leveraged price,
#          6 pegged supply, 7 collateral pool pegged, 8 leveraged pool pegged, 9 leveraged returned,
#          10 leveraged value returned, 11 pegged value given up
#
# Index 0 is the row recorded BEFORE any rebalance at that starting ratio; 1 is the first rebalance, and a rule
# carries further indices where it takes more passes. `before` and `after` below select those two.
#
# A REBALANCE THAT CONVERTED NOTHING IS NOT DRAWN AS ONE. Below its floor the leverage cap's manager gives the
# leveraged leg no headroom and routes the target to the collateral leg - and this market has no collateral
# pool, so neither leg can take anything, the manager returns having converted nothing, and the measurement
# records a pass in which nothing happened. Column 9 is zero on exactly those rows; `after` leaves them out, so
# a point on this graph means pegged was actually converted. The tree's points on `y = x` below the peg are the
# opposite case and are kept: it converts millions of tokens there and moves the ratio not at all.
before(col) = ($2 == 0 ? column(col) : NaN)
after(col)  = ($2 == 1 && $9 > 0 ? column(col) : NaN)
# A report of `uint256.max` is the formula dividing by zero - a claim of nothing - and is not a number to draw.
rep(v) = (v == 0 || v > 1e6 ? NaN : v)
floor_ratio = 20.0 / 19

set lmargin at screen 0.11
set rmargin at screen 0.97

set multiplot layout 4,1 title "rebalance\\_sequence.gp - one rebalance at every collateral ratio, all four rules" font ",11"

# ─── where a rebalance leaves the market ───
set ylabel "collateral ratio after"
set yrange [0:1.6]
set arrow 1 from graph 0, first 1.3 to graph 1, first 1.3 @threshold_line
set arrow 2 from 1, graph 0 to 1, graph 1 @peg_line
set label 1 "the 1.3 threshold" at 0.05, 1.37 textcolor "gray20" font ",9"
plot \
     deployed using 1:(after(3)) with points @deployed_main_points title n_deployed, \
     tree     using 1:(after(3)) with points @tree_local_points    title n_tree, \
     escrow   using 1:(after(3)) with points @escrow_main_points   title n_escrow, \
     cap      using 1:(after(3)) with points @cap_main_points      title n_cap, \
     deployed using 1:1          with lines linewidth 1 dashtype 4 linecolor rgb "gray40" title "unrebalanced (y = x)"
unset arrow 1
unset arrow 2
unset label 1

# ─── the leverage ratio before: a cap on one, an escrow on two, the truth on the fourth ───
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
     escrow   using 1:(rep(before(4))) with points @escrow_main_points   title n_escrow, \
     cap      using 1:($1 < floor_ratio ? NaN : rep(before(4))) with points @cap_main_points title n_cap
unset arrow 3
unset arrow 4
unset label 2
unset logscale y

# ─── what the pool is paid, against what it gave up ───
set ylabel "value back / value given"
set yrange [0:1.15]
set format y "%g"
set arrow 5 from graph 0, first 1 to graph 1, first 1 @fair_line
set arrow 6 from 1, graph 0 to 1, graph 1 @peg_line
plot \
     deployed using 1:($2 == 1 && $11 > 0 ? $10 / $11 : NaN) with points @deployed_main_points title n_deployed, \
     tree     using 1:($2 == 1 && $11 > 0 ? $10 / $11 : NaN) with points @tree_local_points    title n_tree, \
     escrow   using 1:($2 == 1 && $11 > 0 ? $10 / $11 : NaN) with points @escrow_main_points   title n_escrow, \
     cap      using 1:($2 == 1 && $11 > 0 ? $10 / $11 : NaN) with points @cap_main_points      title n_cap
unset arrow 5
unset arrow 6

# ─── the leveraged price, and how many tokens the pool was handed ───
set ylabel "price (lines), tokens (points)"
set logscale y
set yrange [1e-4:1e8]
set format y "10^{%T}"
set xlabel "collateral ratio the market was rebalanced from"
set arrow 7 from 1, graph 0 to 1, graph 1 @peg_line
plot \
     deployed using 1:($2 == 0 ? rep($5) : NaN) with lines  linecolor rgb c_deployed linewidth 1 title n_deployed.", price", \
     tree     using 1:($2 == 0 ? rep($5) : NaN) with lines  linecolor rgb c_tree     linewidth 1 title n_tree.", price", \
     escrow   using 1:($2 == 0 ? rep($5) : NaN) with lines  linecolor rgb c_escrow   linewidth 1 title n_escrow.", price", \
     cap      using 1:($2 == 0 && $1 >= floor_ratio ? rep($5) : NaN) with lines linecolor rgb c_cap linewidth 1 title n_cap.", price", \
     deployed using 1:($2 == 1 ? rep($9) : NaN) with points @deployed_main_points title n_deployed.", tokens", \
     tree     using 1:($2 == 1 ? rep($9) : NaN) with points @tree_local_points    title n_tree.", tokens", \
     escrow   using 1:($2 == 1 ? rep($9) : NaN) with points @escrow_main_points   title n_escrow.", tokens", \
     cap      using 1:($2 == 1 ? rep($9) : NaN) with points @cap_main_points      title n_cap.", tokens"
unset arrow 7
unset logscale y

unset multiplot
