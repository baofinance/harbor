deployed = "hysteresis_main.csv"
tree     = "hysteresis_local.csv"
v3       = "hysteresis_main_v3.csv"
set datafile separator comma
load "style.gp"
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1100,800 background rgb 'gray90'; set output 'hysteresis.png'" hysteresis.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 1100 800 background rgb "gray90" }

# Does a rebalance offer the same terms as the one before it? Three files: the DEPLOYED contracts (`Minter_v2`
# on a pinned fork), the TREE (this tree's chain on a local deploy), and the V3 UPGRADE (this tree's minter,
# manager and both pools behind the deployed proxies - the pending upgrade, measured on production state). Colour
# is the rule, solid is the depositor's whole position, dashed is the conversion's own increment, marker is the
# market (`style.gp`): the tree and the upgrade share a colour because they are the same rule.
#
# A market does not fall once. It falls, is rebalanced, and falls again, and what a stability pool depositor
# is actually asking is whether being liquidated in the fourth round is worse than being liquidated in the
# first. No sweep across the collateral ratio can answer that - a sweep compares DIFFERENT markets, one per
# point, each freshly founded.
#
# THE COLLATERAL RATIO IS PUT BACK TO 0.6 BEFORE EVERY ROUND. That is the design. Each round faces a market
# of identical health, so anything that differs between rounds is what the rounds before it left behind.
# All markets are founded with the same collateral, so every column is raw and nothing is normalised; and the
# deployed manager's keeper bounty and harvest cut are zeroed for the run, as the harness's own managers carry
# none, so no column carries a fee schedule.
#
# THE POOL HOLDS 0.6 OF THE PEGGED SUPPLY, RESTORED BEFORE EVERY ROUND, and both halves of that are
# load-bearing. Below the peg the pegged claim IS the whole collateral, divided by holding - so a pool holding
# ALL of it claims the entire market however much of its own pegged a conversion burned, its position cannot
# fall, and every value-retained column reads as conserved whatever the rule does. An earlier version of this
# graph did exactly that and reported a decay that does not exist. A pool holding too LITTLE cannot complete a
# round either: reaching the 1.3 threshold from 0.6 burns 1 - 0.6/1.3 = 53.85% of the supply. So the share
# sits above that and is topped back up each round from the 40% held outside the pool.
#
# ONLY THE DEPLOYED RULE PLAYS THIS GAME, AND THAT IS THE FIRST READING. The tree and the upgrade REFUSE every
# round: at or below the peg a pegged token redeemed for collateral takes its share of the backing with it, so
# no amount redeemed moves the ratio, `rebalanceable()` is false and `rebalance()` reverts
# `CollateralRatioNotAbovePeg`. Their files have no rows and nothing of them is drawn: the pool keeps exactly
# what it started with, and the market waits for the price. Whether a sub-peg rebalance SHOULD happen is the
# question the whole investigation turned on; this rule's answer is no, and it is the same answer on production
# state as on the local deploy - the upgrade's file is as empty as the tree's.
#
# THE DEPLOYED RULE DOES REBALANCE, AND ITS PAYMENT DECAYS TO NOTHING. Read the POSITION, in collateral units,
# both legs, before and after - not the conversion increment. The increment is real but answers a different
# question: it counts only the tokens a round minted, while the pool's RETAINED pegged marks up from 0.6 to
# par as the burn lifts the ratio, and that retained leg is the larger one. The position settles at 0.537 of
# what the depositor held, round after round; the increment - what the conversion itself paid - is 0.3922 in
# round one, 0.1273 in round two, 0.0517, 0.0226, 0.0102, and reaches nothing by round eight.
#
# THE BOTTOM PANEL IS THE MECHANISM. The deployed count falls 2.165x per round against a market shrinking
# 2.167x - the count is strictly PROPORTIONAL to the pegged taken, because with `K = 20` binding, minting is
# linear in the input and cannot respond to anything else. Its price before each round is zero (the residual is
# gone below the peg), so the price AFTER is the one drawn, and it falls at the market's own rate. Price and
# count both tracking the market means their PRODUCT falls faster than the market does, which is the increment
# in the top panel going to zero.
#
# A cap on minting is a cap on payment, and a capped payment against a falling price decays to nothing. The
# tree's answer to all of this is not to be here: a rebalance below the peg cannot repair the market, so it
# does not take the pool's pegged for the attempt.

set colorsequence default
set xrange [0.5:16.5]
set xtics 1

# Columns: 1 round, 2 CR before, 3 CR after, 4 leveraged price before, 5 leveraged price after,
#          6 leveraged returned, 7 value returned, 8 value given up, 9 value back per given, 10 phi (zero: no
#          escrow on any rule measured here), 11 leverage ratio before, 12 minter collateral, 13 holding before,
#          14 holding after
#
# 13 and 14 are the leveraged pool's WHOLE position - both legs, pegged and leveraged - denominated in
# collateral, and 12 is the market's entire collateral so the share is derivable. 14/13 is what a rebalance
# did to the depositor; column 9 is what the CONVERSION alone paid, which is a different and smaller thing.
nz(v) = (v == 0 ? NaN : v)

set lmargin at screen 0.10
set rmargin at screen 0.97

set multiplot layout 2,1 title "hysteresis.gp - sixteen rebalances from a collateral ratio of 0.6: deployed, the tree, and the upgrade on the deployed market" font ",11"

# ─── what the depositor is paid, round by round ───
set ylabel "kept per rebalance"
set yrange [0:1.05]
plot \
     deployed using 1:($14/$13) with linespoints @deployed_main_every @q_first  title n_deployed.", position", \
     deployed using 1:9         with linespoints @deployed_main_every @q_second title n_deployed.", increment", \
     keyentry with linespoints @tree_local_every title n_tree." (refuses every round)", \
     keyentry with linespoints @tree_main_every  title n_v3." (refuses every round)"

# ─── price and count on ONE axis: only their product is a payment ───
set ylabel "tokens returned (solid)\nprice after (dashed)"
set logscale y
set yrange [1e-18:1e19]
set ytics 1e-18, 1e6
set format y "10^{%T}"
set xlabel "rebalance round, each from a collateral ratio of 0.6"
plot \
     deployed using 1:(nz($6)) with linespoints @deployed_main_every @q_first  title n_deployed.", count", \
     deployed using 1:(nz($5)) with linespoints @deployed_main_every @q_second title n_deployed.", price after"
unset logscale y
set ytics autofreq

unset multiplot
