deployed = "escrow_churn_main.csv"
tree     = "escrow_churn_local.csv"
escrow   = "escrow_churn_local_followsCollateral.csv"
cap      = "escrow_churn_local_leverageCap.csv"
set datafile separator comma
load "style.gp"
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1100,1300 background rgb 'gray90'; set output 'escrow_churn.png'" escrow_churn.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 1100 1300 background rgb "gray90" }

# Does churning the leveraged token move `backing / escrow`, and does it come back? And what does a minter who
# is caught by a rebalance between minting and redeeming get back? All four rules; colour is the rule, marker
# is the market (`style.gp`). Two of the four have no escrow, so the first two panels are the escrow rules'
# alone and the lower two are everyone's.
#
# WHY `backing / escrow` CARRIES SO MUCH. It is three results at once:
#
#   - it IS the leverage ratio reported below the peg, where `phi = CR x escrow/backing` makes `CR / phi`
#     collapse to `backing / escrow` - measured flat at 19.0000 for sixteen rebalance rounds;
#   - it IS the size of the discontinuity at the peg, where the measured sensitivity steps by `1 / phi(1)`;
#   - it sets how many rebalance rounds the escrow floor survives before the leveraged price floors to zero
#     wei - 9, 13 and about 24 rounds for escrow ratios of 0.02, 0.1 and 0.5.
#
# A mint and a redeem both move collateral, and both take a DIFFERENCE of two FLOORED escrow figures across a
# supply they change. Two floors in opposite directions need not cancel - and if they did not, the ratio would
# ratchet with ordinary use and all three results would drift with it.
#
# THE ANSWER IS THAT IT DOES NOT MOVE, AND NOT APPROXIMATELY. Drift is 1.000000000000000000 - exactly one, to
# eighteen decimals - at every one of the 160 collateral ratios, on the candidate and on the tree alike, across
# 3,840 completed round trips each. The reason is that the mint takes `escrowAt(s+o) - escrowAt(s)` and the
# redeem takes THE SAME TWO FLOORED FIGURES in reverse, so they cancel exactly rather than each rounding on its
# own account. THE TOP PANEL IS THEREFORE A FLAT LINE, WHICH IS THE POINT. The band drawn around it is a part
# in 1e15. The deployed rule and the leverage cap are absent from it because they have no escrow and therefore
# no ratio that could drift; that is not a gap, it is the thing being compared against.
#
# THE SECOND PANEL PUTS A REBALANCE BETWEEN THE TWO LEGS, isolated by difference: the same starting state is
# rebalanced ONCE alone, then rebalanced again with the mint before it and the redemption of exactly those
# tokens after it, and the ratio of where the two land is drawn. One means the pair was neutral. The tree is
# EXACT below the peg - 1.000000000000000000 - because `escrowPerLeveragedToken` is invariant there; the
# candidate reads 0.8589, a 14.1% loss, its dilution captured from the minter as well as from incumbents. Above
# the peg the tree reads 1.0265, a real deviation that the third panel shows nobody can extract.
#
# THE THIRD PANEL IS THE ONE ALL FOUR RULES SHARE, AND THE ONE AN ORDINARY USER FEELS: collateral back per
# collateral in, for a minter whose position sits through a rebalance. The tree returns 1.0000000000 at every
# ratio, above and below the peg. The cap returns 0.999999999999999999 - one wei in 1e18 of rounding - at every
# ratio above its floor, and has no reading below it because the mint is refused there: a user cannot be
# caught where they cannot enter. The candidate loses 86.5% below a ratio of 0.57, where a rebalance converts
# the pool's whole holding and the dilution is maximal, and nothing from the peg upward.
#
# THE DEPLOYED RULE PAYS THE MINTER A WINDFALL, AND IT IS THE POOL'S MONEY. Above 1.05 the deployed minter is
# made whole, exactly 1.0. Inside the band where its count cap binds they get back MORE than they put in:
#
#   ratio     back per unit in
#   1.0003    19.91
#   1.001     13.88
#   1.005      6.34
#   1.01       3.73
#   1.02       2.10
#   1.04       1.19
#   1.05       1.00
#
# This is the other face of `conversion_routes.gp`: the pool is paid 0.204 of fair value at 1.01, and the 0.796
# it is not paid does not vanish - burning its pegged raises the residual, and the residual belongs to whoever
# holds leveraged at that moment. A minter who enters just before a rebalance in the band and leaves just after
# takes the pool's shortfall home, 3.7x their stake at 1.01 and twenty times it at the peg. The count cap does
# not merely underpay the pool; it makes the underpayment EXTRACTABLE by anyone watching the keeper. The
# deployed rule has no reading below the peg for the opposite reason to the cap's - its mint divides by a zero
# price there.
#
# THE BOTTOM PANEL IS HOW MANY OF THE 24 ROUND TRIPS EACH MARKET WOULD TAKE. The escrow rules take all 24
# everywhere. The deployed rule takes none below the peg, because it has no leveraged price to mint against -
# the pole seen from the retail side. The cap takes none below its floor of 1.0526 and all 24 above it, and the
# two lines are the two ways of not selling: the deployed rule cannot, the cap will not.

set colorsequence default
set xrange [0:1.62]

# Columns: 1 collateral ratio, 2 backing per escrow before, 3 backing per escrow after, 4 drift,
#          5 leverage ratio before, 6 leverage ratio after, 7 escrow before, 8 escrow after,
#          9 cycles completed, 10 backing per escrow after a rebalance ALONE,
#          11 the same after mint-rebalance-redeem, 12 the ratio of the two, 13 the minter's own return
nz(v) = (v == 0 ? NaN : v)

set lmargin at screen 0.11
set rmargin at screen 0.97

set multiplot layout 4,1 title "escrow\\_churn.gp - 24 leveraged mint-and-redeem round trips at every collateral ratio, all four rules" font ",11"

# ─── the drift, against a band far tighter than anything that would matter ───
# Plotted as the DEVIATION from one, in the last decimal place the figure carries. A ratio drawn directly
# would need fifteen decimals of tic label to show anything, and would look like a flat line whether it was
# exactly one or merely close. This way zero means EXACTLY one and any drift at all leaves the axis.
set ylabel "drift from 1, in 1e-18"
set yrange [-10:10]
set ytics 5
set arrow 1 from graph 0, first 0 to graph 1, first 0 @fair_line
set label 2 "exactly conserved" at 0.04, 2.5 textcolor "black" font ",9"
set arrow 3 from 1, graph 0 to 1, graph 1 @peg_line
plot \
     tree   using 1:(nz($4) - 1) * 1e18 with linespoints @tree_local   @q_first title n_tree, \
     escrow using 1:(nz($4) - 1) * 1e18 with linespoints @escrow_local @q_first title n_escrow, \
     keyentry with linespoints @deployed_main title n_deployed." (no escrow)", \
     keyentry with linespoints @cap_local     title n_cap." (no escrow)"
unset arrow 1
unset arrow 3
unset label 2
set ytics autofreq

# ─── the same pair, but with a REBALANCE between its two legs ───
set ylabel "across a rebalance, vs\nrebalance alone"
set yrange [0.82:1.06]
set arrow 4 from graph 0, first 1 to graph 1, first 1 @fair_line
set label 3 "neutral" at 0.04, 1.015 textcolor "black" font ",9"
set arrow 5 from 1, graph 0 to 1, graph 1 @peg_line
plot \
     tree   using 1:(nz($12)) with linespoints @tree_local   @q_first title n_tree, \
     escrow using 1:(nz($12)) with linespoints @escrow_local @q_first title n_escrow
unset arrow 4
unset arrow 5
unset label 3

# ─── what the minter gets back, across a rebalance: the panel every rule is in ───
set ylabel "collateral back per\ncollateral in"
# Log, because the same axis has to hold a minter losing 86.5% and one taking twenty times their stake.
set logscale y
set yrange [0.08:40]
set format y "%g"
set arrow 6 from graph 0, first 1 to graph 1, first 1 @fair_line
set label 4 "made whole" at 0.04, 1.25 textcolor "black" font ",9"
set arrow 7 from 1, graph 0 to 1, graph 1 @peg_line
plot \
     deployed using 1:(nz($13)) with linespoints @deployed_main @q_first title n_deployed, \
     tree     using 1:(nz($13)) with linespoints @tree_local    @q_first title n_tree, \
     escrow   using 1:(nz($13)) with linespoints @escrow_local  @q_first title n_escrow, \
     cap      using 1:(nz($13)) with linespoints @cap_local     @q_first title n_cap
unset arrow 6
unset arrow 7
unset label 4
unset logscale y

# ─── how many of the 24 round trips the market would take ───
set ylabel "round trips completed, of 24"
set yrange [0:26]
set xlabel "collateral ratio the churn was run at"
set arrow 2 from 1, graph 0 to 1, graph 1 @peg_line
set label 1 "the deployed rule CANNOT sell below the peg; the cap WILL NOT below 1.0526" at 0.04, 3.2 textcolor "black" font ",9"
plot \
     deployed using 1:9 with linespoints @deployed_main @q_first title n_deployed, \
     tree     using 1:9 with linespoints @tree_local    @q_first title n_tree, \
     escrow   using 1:9 with linespoints @escrow_local  @q_first title n_escrow, \
     cap      using 1:9 with linespoints @cap_local     @q_first title n_cap
unset arrow 2
unset label 1

unset multiplot
