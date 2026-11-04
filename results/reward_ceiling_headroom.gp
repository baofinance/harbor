datafile = "reward_ceiling_headroom.csv"
set datafile separator comma
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,700 background rgb 'gray90'; set output 'reward_ceiling_headroom.png'" reward_ceiling_headroom.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,6 background rgb 'gray90'; set output 'reward_ceiling_headroom.pdf'" reward_ceiling_headroom.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 780 620 background rgb "gray90" }

# Can the leveraged pool absorb a rebalance once the conversion cap is removed?
#
# The conversion currently hands over the leverage ratio cap as though it were a rate, so a rebalance
# near the peg mints twenty sail per anchor however far the residual has fallen. Removing that is the
# first step of the reserve work - and the sail a rebalance hands the pool is accrued into that pool's
# reward integral, which has a ceiling. If the uncapped minting exceeded it, `_capLiquidation` would
# scale the whole leg down, so removing the cap would SHRINK the rebalance rather than free it, worst
# where the market is most distressed. Hence the question, asked before the removal rather than after.
#
# THE ANSWER IS NO, by a wide margin. The ceiling sits between 1.4e9 and 1.8e15 times the uncapped
# minting across this sweep, at a pool holding two thousandths of the anchor outstanding - and the
# ceiling scales linearly with the pool's share, so a larger pool only has more room.
#
# The gap between the two minting lines is the size of the change being made: at the peg a rebalance
# would hand over fifty thousand times what it hands over today. That is the stability pool depositor
# being paid twenty where the fair answer is a million.
#
# Uncapped minting is COMPUTED, from the contract's own uncapped expression, because with the cap in
# place there is nothing to measure below a collateral ratio of about 1.053 - which is most of the sweep.
# Everything else is read from the market, and the anchor asked of the leveraged leg comes from the same
# call the stability pool manager itself makes.
#
# This measures the LIQUIDATION ceiling, `maxLiquidationReward`, which is scaled by the pool's LIVE
# share. The harvest path has a different one, `_depositRewardCap`, scaled by the pool's FLOOR share
# instead, because a streamed deposit accrues later against a share that may have fallen that far. A
# tight harvest ceiling would not show up here, and removing the conversion cap does not touch it.

set grid xtics ytics
set colorsequence default
set logscale x
set logscale y
set format x "%g"
set format y "%g"
set xlabel "collateral ratio minus one - the pole is on the left"
set ylabel "sail tokens"
set key below title " "

plot \
     datafile using ($1 - 1):5 with lines linewidth 3 linetype 1 \
         title "the leveraged pool reward ceiling", \
     datafile using ($1 - 1):4 with linespoints linewidth 3 linetype 7 pointtype 7 \
         title "sail minted with no conversion cap", \
     datafile using ($1 - 1):3 with linespoints linewidth 2 linetype 2 pointtype 5 \
         title "sail minted as the market answers today"
