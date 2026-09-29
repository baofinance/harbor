deployed = "liquidate_to_partial_both44_main.csv"
tree     = "liquidate_to_partial_both44_local.csv"
v3       = "liquidate_to_partial_both44_main_v3.csv"
set datafile separator comma
load "style.gp"
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1100,1100 background rgb 'gray90'; set output 'liquidate_to_partial_both44_candidates.png'" liquidate_to_partial_both44_candidates.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 1100 1100 background rgb "gray90" }

# `liquidate_to_partial_both44` on the DEPLOYED contracts, the TREE on a local deploy, and the V3 UPGRADE (this
# tree's minter, manager and pools behind the deployed proxies). Colour is the rule, solid is BEFORE the
# liquidation and dashed AFTER where both are drawn, marker is the market (`style.gp`); the tree and the
# upgrade share a colour because they are the same rule.
#
# This is the measurement that produced the `K = 20` leverage cap, which makes it the one the tree most needs
# reading against: the count cap is exactly what the tree turns into a refusal. One liquidation at each
# collateral ratio, with 0.4 of the founding pegged in each stability pool so both the collateral leg and the
# conversion are available - the same split the original measured.
#
# NOTHING HERE IS NORMALISED OR DERIVED. All three markets are founded with the same 500 collateral tranches,
# so every column is the raw figure the contracts reported and any two can be read against each other
# directly. A graph that has to correct for its inputs is one where a mistake in the correction cannot be told
# from a difference in the thing measured - and the market size is an input, so there is no reason to correct
# for it afterwards.
#
# THE TOP PANEL IS WHERE A LIQUIDATION LEAVES THE MARKET, and the rules split at the peg:
#
#   - The DEPLOYED rule lands on the 1.3 threshold from 0.5 upward, and less below, where the pools run out
#     before the threshold does - sub-peg included, by converting the pool's pegged into tokens worth nothing.
#   - The TREE and the UPGRADE sit on the unliquidated line `y = x` at and below the peg: `rebalance()` is
#     refused there (`CollateralRatioNotAbovePeg`), because a pegged redeemed for collateral takes its share of
#     the backing with it and no amount redeemed moves the ratio. From just above the peg they reach 1.3 - at
#     1.02 as at 1.25 - in TWO STEPS within one call: both pools give up pegged by the collateral route until
#     the ratio reaches the floor of 1.0526, and from the floor both legs run and land where the deployed rule
#     lands, with the deployed rule's own figures. The two files agree at every ratio: the upgrade behaves on
#     production state as the tree does locally.
#
# THE MIDDLE PANEL IS WHY THE COUNT CAP EXISTED. Two lines per rule, and the distinction matters: the price
# BEFORE the liquidation is what a converter is paid at, and it is ZERO below a collateral ratio of one - the
# residual has gone and nothing else backs the token, so a conversion into it mints without bound. That is the
# pole `K = 20` was bolted on to contain. The tree prices the same residual - no escrow, the same before-price
# - and is drawn only from its floor up, because below it nothing is sold: the tree contains the pole by never
# quoting near it.
#
# The price AFTER is a different thing and is not zero in any rule above about 0.3 - the liquidation has
# restored the market by then, so the price it leaves behind is healthy. Reading the after-price as though it
# were the before-price makes the pole disappear from the graph; they are plotted separately here for that
# reason. Where a rule did nothing, before and after coincide.
#
# THE BOTTOM PANEL IS WHAT THE DEPOSITOR IS LEFT HOLDING, in leveraged tokens, on a linear axis as the original
# drew it. The tree hands over none below the floor: at and below the peg the depositor keeps their pegged,
# worth what it is worth, and has not traded it for tokens worth nothing; between the peg and the floor the
# leveraged pool is paid in COLLATERAL, which this column does not count. From the floor up the tree hands over
# what the deployed rule does.

set colorsequence default
set xrange [0:1.62]

# Columns: 1 current CR, 2 after user collateral, 3 after SPCollateral collateral, 4 after user leveraged,
#          5 after SPLeveraged leveraged, 6 after minter collateral, 7 after minter pegged,
#          8 before leveraged price, 9 after leveraged price, 10 after CR
nz(v) = (v == 0 ? NaN : v)
floor_ratio = 20.0 / 19
# The tree sells no leveraged below its floor; the column carries the residual's arithmetic there, which
# nothing was ever sold at.
quoted(r, v) = (r < floor_ratio ? NaN : nz(v))

set lmargin at screen 0.10
set rmargin at screen 0.97

set multiplot layout 3,1 title "liquidate\\_to\\_partial\\_both44\\_candidates.gp - one liquidation at each collateral ratio: deployed, the tree, and the upgrade" font ",11"

# ─── where a liquidation leaves the market ───
set ylabel "collateral ratio after"
set yrange [0:1.7]
set arrow 1 from graph 0, first 1.3 to graph 1, first 1.3 @threshold_line
set label 1 "the 1.3 threshold" at 0.04, 1.38 textcolor "gray20" font ",9"
set arrow 2 from 1, graph 0 to 1, graph 1 @peg_line
set arrow 3 from floor_ratio, graph 0 to floor_ratio, graph 1 @floor_line
plot \
     deployed using 1:10 with linespoints @deployed_main @q_first title n_deployed, \
     tree     using 1:10 with linespoints @tree_local    @q_first title n_tree, \
     v3       using 1:10 with linespoints @tree_main     @q_first title n_v3, \
     deployed using 1:1  with lines linewidth 1 dashtype 4 linecolor rgb "gray40" title "unliquidated (y = x)"
unset arrow 1
unset arrow 2
unset arrow 3
unset label 1

# ─── the leveraged price, before and after, on a linear axis ───
set ylabel "leveraged price"
set yrange [0:0.6]
set arrow 4 from 1, graph 0 to 1, graph 1 @peg_line
set label 2 "collateral ratio 1" at 1.02, 0.52 textcolor "gray30" font ",9"
plot \
     deployed using 1:8                with linespoints @deployed_main @q_first  title n_deployed.", before", \
     deployed using 1:9                with linespoints @deployed_main @q_second title n_deployed.", after", \
     tree     using 1:(quoted($1, $8)) with linespoints @tree_local    @q_first  title n_tree.", before", \
     tree     using 1:(quoted($1, $9)) with linespoints @tree_local    @q_second title n_tree.", after", \
     v3       using 1:(quoted($1, $8)) with linespoints @tree_main     @q_first  title n_v3.", before", \
     v3       using 1:(quoted($1, $9)) with linespoints @tree_main     @q_second title n_v3.", after"
unset arrow 4
unset label 2

# ─── what the depositor is left holding, in tokens, linear ───
set ylabel "leveraged tokens held after"
set autoscale y
set format y "%.0s%c"
set xlabel "collateral ratio the liquidation was made at"
set arrow 5 from 1, graph 0 to 1, graph 1 @peg_line
plot \
     deployed using 1:4 with linespoints @deployed_main @q_first title n_deployed, \
     tree     using 1:4 with linespoints @tree_local    @q_first title n_tree, \
     v3       using 1:4 with linespoints @tree_main     @q_first title n_v3
unset arrow 5

unset multiplot
