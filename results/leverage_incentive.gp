deployed = "leverage_incentive_main.csv"
tree     = "leverage_incentive_local.csv"
escrow   = "leverage_incentive_local_followsCollateral.csv"
cap      = "leverage_incentive_local_leverageCap.csv"
set datafile separator comma
load "style.gp"
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1100,1100 background rgb 'gray90'; set output 'leverage_incentive.png'" leverage_incentive.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 1100 1100 background rgb "gray90" }

# WHERE THE INCENTIVES POINT, AGAINST WHERE THE DAMAGE IS - all four rules. Colour is the rule, solid is a
# mint, dashed is a redeem, marker is the market (`style.gp`).
#
# Every other graph here asks what a rule DOES. This one asks what a user would CHOOSE to do, and whether those
# line up. On the escrow rules they do not - and it is a property of having an escrow at all, since minting
# and redeeming are the same code in both: measured on both and IDENTICAL TO FIVE DECIMALS, so their two lines
# lie on each other in every panel. On the two rules without an escrow there is no damage to line up with:
# the middle and bottom panels have nothing of theirs to draw.
#
# THE QUANTITY IS `backing / escrow`, WHICH IS THE MAXIMUM LEVERAGE AN ESCROW MARKET CAN OFFER - 19 here, and
# 20 at the peg where it is attained. Minting moves collateral INTO the escrow and pushes it down; redeeming
# releases escrow and pushes it back up. Without an escrow the maximum is not a market quantity at all: the
# deployed rule's is the constant 20 of its count cap, the leverage cap's is the constant `K` of its floor, and
# neither can be moved by anything a user does.
#
# THE TOP PANEL IS THE INCENTIVE. It is the leverage the contract reports on offer, and it is greatest AT THE
# PEG - 20 there on every rule, falling monotonically above it. A buyer of leveraged exposure therefore mints
# as close to the peg as they can get, because that is where a unit of collateral buys the most exposure. A
# holder taking profit redeems after the collateral has RISEN, which is high up the same axis. The two arrows
# are the whole graph. The deployed line reads 20 up to 1.0526, its count cap; the leverage cap's line begins
# at its floor, because below 1.0526 there is nothing on offer, so the incentive to mint near the peg is met
# with a refusal rather than a sale.
#
# THE MIDDLE PANEL IS THE DAMAGE, and it is not symmetric between those two places:
#
#   ratio   a mint costs   a redeem gains
#   1.00    16.67%         25.00%
#   1.30     2.76%          2.97%
#   2.00     0.94%          0.97%
#
# At the SAME ratio the two very nearly cancel - which is the escrow round trip conserving, measured
# elsewhere as exactly 1.0. But nobody mints and redeems at the same ratio. THE INCENTIVE-DRIVEN PAIRING IS
# MINT AT THE PEG AND REDEEM HIGH UP: `-16.67% + 0.97%` is about SIXTEEN PERCENT OF THE MAXIMUM LEVERAGE,
# GONE, PER ROUND TRIP, and it does not come back.
#
# THE BOTTOM PANEL IS WHY. The share of a mint that lands in the escrow rather than the backing is
# `E/(R+E)` with `R = B(CR-1)/CR` - derived, and matched by the measurement to four decimals. At the peg the
# residual is zero, so ALL of a mint is escrowed; by a ratio of two it is a tenth. The escrow is unlevered
# collateral, so every unit added there dilutes the leverage of everything already minted.
#
# AND THE PROFIT ITSELF ERODES IT FURTHER. Over a full round trip the escrow returns exactly to where it
# started - the mint's contribution is released by the redemption - but the payout also takes the holder's
# PROFIT out of the BACKING. So `E` is restored while `B` is smaller, and `B/E` ends lower than it began.
# Leveraged holders MAKING MONEY reduces everyone else's maximum leverage; leveraged holders losing money
# restores it. The product degrades precisely when it works - and the two rules without an escrow have
# nothing that can degrade.

set colorsequence default
set xrange [0.95:2.45]

# Columns: 1 collateral ratio, 2 max leverage, 3 max leverage after a mint, 4 after a redeem,
#          5 mint cost, 6 redeem gain, 7 escrow share of a mint, 8 the leverage the contract reports on offer
nz(v) = (v == 0 ? NaN : v)
floor_ratio = 20.0 / 19
# The cap sells nothing below its floor, so nothing is on offer there.
offered(r, v) = (r < floor_ratio ? NaN : nz(v))

set lmargin at screen 0.10
set rmargin at screen 0.97

set multiplot layout 3,1 title "leverage\\_incentive.gp - where a user would act, against where the damage is, all four rules" font ",11"

# ─── the incentive: where the leverage actually is ───
set ylabel "leverage on offer"
set logscale y
set yrange [1:30]
set format y "%g"
set arrow 1 from 1, graph 0 to 1, graph 1 @peg_line
set label 1 "a BUYER mints here -\nmost exposure per unit" at 1.03, 13 textcolor rgb "dark-red" font ",9"
set label 2 "a HOLDER takes profit here" at 1.85, 3.4 textcolor rgb "dark-blue" font ",9"
set arrow 2 from 1.82, 3.0 to 2.30, 1.9 heads filled linewidth 1 linecolor rgb "dark-blue"
plot \
     deployed using 1:(nz($8))          with linespoints @deployed_main @q_first title n_deployed, \
     tree     using 1:(nz($8))          with linespoints @tree_local    @q_first title n_tree, \
     escrow   using 1:(nz($8))          with linespoints @escrow_local  @q_first title n_escrow, \
     cap      using 1:(offered($1, $8)) with linespoints @cap_local     @q_first title n_cap
unset arrow 1
unset arrow 2
unset label 1
unset label 2
unset logscale y

# ─── the damage: what each act does to the market's maximum leverage ───
set ylabel "max leverage moved,\nfraction"
set logscale y
set yrange [0.004:0.4]
set format y "%g"
set arrow 3 from 1, graph 0 to 1, graph 1 @peg_line
# The ratchet: the two places a user actually acts, and the gap between them.
set arrow 4 from 1.0, 0.1667 to 2.0, 0.00971 heads filled linewidth 2 linecolor rgb "black"
set label 3 "mint at the peg costs 16.7%, redeem high up returns 1.0%" at 1.12, 0.055 textcolor "black" font ",9"
plot \
     tree   using 1:(nz($5)) with linespoints @tree_local   @q_first  title n_tree.", a mint costs", \
     tree   using 1:(nz($6)) with linespoints @tree_local   @q_second title n_tree.", a redeem gains", \
     escrow using 1:(nz($5)) with linespoints @escrow_local @q_first  title n_escrow.", a mint costs", \
     escrow using 1:(nz($6)) with linespoints @escrow_local @q_second title n_escrow.", a redeem gains", \
     keyentry with linespoints @deployed_main title n_deployed." (no escrow)", \
     keyentry with linespoints @cap_local     title n_cap." (no escrow)"
unset arrow 3
unset arrow 4
unset label 3
unset logscale y

# ─── the mechanism ───
set ylabel "share of a mint\nthat is escrowed"
set yrange [0:1.1]
set xlabel "collateral ratio the act is performed at"
set arrow 5 from 1, graph 0 to 1, graph 1 @peg_line
set label 4 "at the peg the residual is zero, so ALL of a mint is escrowed" at 1.06, 0.93 textcolor "black" font ",9"
plot \
     tree   using 1:(nz($7)) with linespoints @tree_local   @q_first title n_tree, \
     escrow using 1:(nz($7)) with linespoints @escrow_local @q_first title n_escrow
unset arrow 5
unset label 4

unset multiplot
