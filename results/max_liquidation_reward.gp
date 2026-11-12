set title "max_liquidation_reward.gp" noenhanced
datafile = "max_liquidation_reward.csv"
set datafile separator comma
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,700 background rgb 'gray90'; set output 'max_liquidation_reward.png'" max_liquidation_reward.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,6 background rgb 'gray90'; set output 'max_liquidation_reward.pdf'" max_liquidation_reward.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 780 620 background rgb "gray90" }

# Can the leveraged pool absorb a rebalance's conversion, now that the minter does not bound how many
# sail it mints per anchor?
#
# The deployed Minter_v2 mints twenty sail per anchor at or below a collateral ratio of 20/19 = 1.0526,
# however far the residual has fallen. Minter_v3 has no such bound. The sail a rebalance hands the
# leveraged pool is accrued into that pool's reward integral. `maxLiquidationReward` is the most sail the
# pool can credit in one liquidation without overflowing that integral. The stability pool manager holds
# the pool's leg within it (`_maxPeggedFrom`, through `_capLiquidation`). It passes the shortfall to the
# collateral pool's leg. Hence the question: where would the conversion exceed `maxLiquidationReward`?
#
# THE CONVERSION WOULD EXCEED IT ONLY WITHIN 1.7e-15 OF THE PEG, where Minter_v3 mints nothing. On this
# sweep, `maxLiquidationReward` is below the computed minting up to a collateral ratio of 1 + 6.9e-16,
# and above it from 1 + 1.7e-15. Minter_v3 mints no sail below `MINIMUM_COLLATERAL_RATIO`, about 1.0101,
# so a rebalance never converts there. Where it mints on this sweep, from 1.014 up,
# `maxLiquidationReward` is between 2.1e13 and 1.2e15 times what it mints. Each pool holds two
# thousandths of the anchor outstanding. `maxLiquidationReward` scales linearly with the pool's total
# share, so a larger pool only raises it.
#
# The two minting lines are the same from 1.014 up. Below `MINIMUM_COLLATERAL_RATIO` the market mints
# zero, which a log axis does not draw.
#
# The computed minting is the anchor asked times the sail supply over the residual. It agrees with what
# Minter_v3 mints to the last digit wherever Minter_v3 mints. It is computed because below
# `MINIMUM_COLLATERAL_RATIO` there is nothing to measure. Everything else is read from the market. The
# anchor asked of the leveraged leg comes from `redeemPeggedForCollateralRatio`, the call the manager sizes
# its legs with, here with no limit on either leg. A rebalance also holds each leg within its pool's
# `maxAssetLoss`, which this sweep does not apply.
#
# This measures `maxLiquidationReward`, which scales with the pool's live total share. A streamed reward
# deposit, such as a harvest's, is held within `_depositRewardCap` instead. That scales with the pool's
# floor share, `_minTotalShare()`, because a streamed deposit accrues later against a share that may have
# fallen that far. This graph does not show `_depositRewardCap`, and the conversion does not touch it.
#
# The collateral ratio minus one is read from the decimal digits of column 1. Subtracting one in double
# precision rounds it to a multiple of 2.2e-16. That would draw none of the six points below 1.1e-16,
# and would move the others near the peg.

set grid xtics ytics
set colorsequence default
set logscale x
set logscale y
set format x "%g"
set format y "%g"
set xlabel "collateral ratio minus one - the pole is on the left"
set ylabel "sail tokens"
set key below noenhanced title " "

# Every collateral ratio in the CSV has the integer part 1, so its fraction is the ratio minus one.
aboveThePeg(columnNumber) = real("0".substr(strcol(columnNumber), 2, strlen(strcol(columnNumber))))

plot \
     datafile skip 1 using (aboveThePeg(1)):5 with lines linewidth 3 linetype 1 \
         title "the leveraged pool's maxLiquidationReward", \
     datafile skip 1 using (aboveThePeg(1)):4 with linespoints linewidth 3 linetype 7 pointtype 7 \
         title "sail minted with no MINIMUM_COLLATERAL_RATIO, computed", \
     datafile skip 1 using (aboveThePeg(1)):3 with linespoints linewidth 2 linetype 2 pointtype 5 \
         title "sail Minter_v3 mints, by its dry run"
