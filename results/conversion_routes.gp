deployed = "conversion_routes_main.csv"
tree     = "conversion_routes_local.csv"
v3       = "conversion_routes_main_v3.csv"
set datafile separator comma
load "style.gp"
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1100,1100 background rgb 'gray90'; set output 'conversion_routes.png'" conversion_routes.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 1100 1100 background rgb "gray90" }

# What a stability pool is PAID when its pegged is converted, against what the same move is worth by hand - on
# the DEPLOYED contracts, the TREE on a local deploy, and the V3 UPGRADE. Colour is the rule, dash is the
# route, marker is the market (`style.gp`); the tree and the upgrade share a colour because they are the same
# rule.
#
# TWO OF THE THREE FILES ARE THE DEPLOYED MARKET. Same proxies, same pools, same funding, same block - the ONLY
# difference is the rule behind them: `Minter_v2` as deployed, and this tree's minter, manager and both pools
# upgraded in place (the whole v3 upgrade, which is the only upgrade that exists). Those two carry the market's
# own fee configuration. The tree's own run is a local deploy of this tree's chain, founded with the same
# collateral and FEE-FREE, and wears the triangle marker to say so. `results/provenance_*.csv` records the
# implementation behind every proxy in each run.
#
# THREE ROUTES: the CONVERSION a rebalance performs; the same move BY HAND (redeem pegged for collateral, mint
# leveraged with it); and what a REAL REBALANCE returns per pegged it burned, which is the only one that passes
# through the manager's sizing and clamping instead of being asked for a token at a time.
#
# EVERY ROUTE HERE IS PRICED ON ONE PEGGED TOKEN, so what this graph measures is the MARGINAL rate - the rate
# on offer, not the rate a real rebalance achieves. A rebalance converts a whole pool and moves the price
# against itself as it goes; `rebalance_sequence.gp` measures that.
#
# THE TOP PANEL IS THE FINDING AND IT IS NOT A MATTER OF DEGREE. A fair route returns value equal to the value
# given up, so a correct line sits on 1.
#
#   - The TREE and the UPGRADE sit on 1.0000 on both routes at every ratio above the floor of 1.0526, and are
#     ABSENT - not zero - below it: nothing is minted there on any route, so nothing is paid and nothing is
#     taken. A gap in a line is a refusal; a line at zero would be a payment of nothing, which is the deployed
#     rule's failure and a different thing. Above the floor the two draw the deployed rule's own figures.
#   - The DEPLOYED rule pays ZERO below the peg. Not a little, not most of it - the leveraged price there is
#     exactly zero, so twenty tokens are handed over and they are worth nothing at all. The retail route is
#     not merely worse there, it CANNOT BE TAKEN: minting leveraged divides by that zero price and reverts.
#   - In the band just above the peg where `K = 20` binds, the deployed conversion pays 0.204 of what the
#     retail route pays at a ratio of 1.01, 0.408 at 1.02, and reaches parity only at about 1.05. A holder
#     doing it by hand is paid up to five times what the pool is paid for the same move at the same instant.
#
# THE MIDDLE PANEL SHOWS THE TWO FAILURES THAT PRODUCE THAT. Both are on the deployed rule and both are the
# same zero price seen from opposite sides:
#
#   - THE CAP ON COUNT. The conversion returns a flat 20 tokens everywhere below 1.05, because `K = 20` is what
#     bounds it, and 20 tokens at a price of zero is a payment of zero.
#   - THE POLE. At a ratio of exactly 1.000 the retail route returns 2.2e21 tokens for ONE pegged token. That
#     is `freeMintLeveragedToken` dividing by a price that has reached zero - unbounded minting, which is the
#     thing the count cap was bolted on to contain, still reachable by the route the cap does not cover.
#
# The tree has neither failure, by the opposite means: it stops minting before the price can get near zero.
# Same `K = 20` as the deployed rule; the deployed rule caps the COUNT and hands over tokens worth nothing, the
# tree REFUSES and hands over nothing. Its real rebalance (dotted) returns the same count as its one-token
# conversion from the floor up - and one point more: at 1.05, just under the floor, the one-token probes are
# refused while a real rebalance still returns 15.36 tokens per pegged, because a rebalance from below the
# floor first takes the collateral route up TO the floor and then converts from there, in the same call.
#
# THE BOTTOM PANEL IS WHY: the leveraged price each route is quoted at. It is one line: no rule here carries an
# escrow, so all three price the same residual. The deployed line simply stops at the peg, because below it
# there is no price to quote; the tree's stops at its floor, because below it nothing is sold.

set colorsequence default
set xrange [0:1.6]

# Columns: 1 collateral ratio, 2 conversion tokens, 3 retail tokens, 4 rebalance tokens, 5 leverage ratio,
#          6 leveraged price, 7 conversion value, 8 retail value, 9 pegged given up
#
# 7/9 and 8/9 are the fairness of each route: what came back, over what it cost. A route that pays fairly
# returns 1. Zero tokens means the route was refused or paid nothing, and is drawn as a gap.
fair(v, g) = (g == 0 || v == 0 ? NaN : v / g)
nz(v) = (v == 0 ? NaN : v)

# Left and right pinned so every panel shares one x scale whatever its y tic labels are; the heights are
# gnuplot's, so each panel can make room for the key above it.
set lmargin at screen 0.10
set rmargin at screen 0.97

set multiplot layout 3,1 title "conversion\\_routes.gp - what a conversion pays against the same move by hand: deployed, the tree, and the upgrade" font ",11"

# ─── the answer: value returned per value given up ───
set ylabel "value back per value given"
set yrange [0:1.25]
set arrow 1 from graph 0, first 1 to graph 1, first 1 @fair_line
set label 1 "a fair route" at 0.04, 1.08 textcolor "black" font ",9"
set arrow 2 from 1, graph 0 to 1, graph 1 @peg_line
plot \
     deployed using 1:(fair($7, $9)) with linespoints @deployed_main @q_first  title n_deployed.", conversion", \
     deployed using 1:(fair($8, $9)) with linespoints @deployed_main @q_second title n_deployed.", by hand", \
     tree     using 1:(fair($7, $9)) with linespoints @tree_local    @q_first  title n_tree.", conversion", \
     tree     using 1:(fair($8, $9)) with linespoints @tree_local    @q_second title n_tree.", by hand", \
     v3       using 1:(fair($7, $9)) with linespoints @tree_main     @q_first  title n_v3.", conversion", \
     v3       using 1:(fair($8, $9)) with linespoints @tree_main     @q_second title n_v3.", by hand"
unset arrow 1
unset arrow 2
unset label 1

# ─── the count cap and the pole, in tokens ───
set ylabel "leveraged tokens per pegged"
set logscale y
set yrange [0.5:1e23]
set format y "10^{%T}"
set label 2 "the pole - 2.2e21 tokens for ONE pegged" at 0.4, 2e10 textcolor "black" font ",9"
set arrow 5 from 0.62, 7e10 to 0.99, 3e20 filled linewidth 1 linecolor rgb "black"
plot \
     deployed using 1:(nz($3)) with linespoints @deployed_main @q_second title n_deployed.", by hand", \
     deployed using 1:(nz($2)) with linespoints @deployed_main @q_first  title n_deployed.", conversion", \
     tree     using 1:(nz($2)) with linespoints @tree_local    @q_first  title n_tree.", conversion", \
     tree     using 1:(nz($4)) with linespoints @tree_local    @q_third  title n_tree.", real rebalance", \
     v3       using 1:(nz($2)) with linespoints @tree_main     @q_first  title n_v3.", conversion", \
     v3       using 1:(nz($4)) with linespoints @tree_main     @q_third  title n_v3.", real rebalance"
unset arrow 5
unset label 2
unset logscale y

# ─── the price every route is quoted at ───
set ylabel "leveraged price"
set logscale y
set yrange [1e-3:1]
set format y "10^{%T}"
set xlabel "collateral ratio"
set arrow 4 from 1, graph 0 to 1, graph 1 @peg_line
plot \
     deployed using 1:(nz($6)) with linespoints @deployed_main @q_first title n_deployed, \
     tree     using 1:(nz($6)) with linespoints @tree_local    @q_first title n_tree, \
     v3       using 1:(nz($6)) with linespoints @tree_main     @q_first title n_v3
unset arrow 4
unset logscale y

unset multiplot
