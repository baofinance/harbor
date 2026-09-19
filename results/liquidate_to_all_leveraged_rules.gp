set title "liquidate_to_all_leveraged_rules.gp" noenhanced
unbounded = "liquidate_to_all_leveraged_unbounded.csv"
flat = "liquidate_to_all_leveraged.csv"
gamma1 = "liquidate_to_all_leveraged_gamma_1.csv"
gamma025 = "liquidate_to_all_leveraged_gamma_025.csv"
set datafile separator comma
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'liquidate_to_all_leveraged_rules.png'" liquidate_to_all_leveraged_rules.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'liquidate_to_all_leveraged_rules.pdf'" liquidate_to_all_leveraged_rules.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 700 600 background rgb "gray90" }

# HOW MUCH SAIL ONE REBALANCE MINTS, under four conversion rules, over the sweep the flat rate of 20 was
# originally chosen from. The leveraged pool holds all of the anchor here, so every rebalance converts as
# much as it can - the variant that shows a conversion rule most.
#
# The flat rate was chosen by looking at the unbounded line and finding it alarming. Read the two
# together and the trouble is plain: the flat rate FOLLOWS the unbounded line exactly until a collateral
# ratio of about 1.0526, and only bites below that. A market whose rebalance threshold is 1.05 is
# rebalancing in the region where the two are the same line, so it is getting no protection from the
# bound at all - which is what the choice of 20 was meant to buy.
#
# 1.0526 is not a chosen number. It is where the reported leverage ratio reaches 20, which is the
# quantity the rule tests, and it moves with nothing - not with the market, not with the threshold.
#
# The candidate lines are flat because they are what they say: at most gamma of the sail outstanding, per
# conversion, wherever the collateral ratio happens to be. They bind across the whole distressed range
# rather than waiting for a price to cross a threshold. That is the difference between capping the
# quantity minted and capping the rate it is minted at.
#
# Above a collateral ratio of about 1.3 nothing is minted at all - the rebalance has nothing to do - and
# a logarithmic axis cannot draw a zero, so all four lines simply end there.

set xrange [1.0:1.32]
set xlabel "collateral ratio the rebalance fires at"
set xtics 0.05
set logscale y
set yrange [3000:400000]
set ylabel "sail minted to the leveraged pool, in one rebalance"
set ytics ("5k" 5000, "20k" 20000, "50k" 50000, "100k" 100000, "200k" 200000)
set grid xtics ytics
set key top right reverse Left noenhanced
set colorsequence default

# Where the reported leverage ratio reaches its cap, and so the only place the flat rate starts to act.
set arrow 1 from first 20.0 / 19.0, graph 0 to first 20.0 / 19.0, graph 1 nohead dashtype 2 linecolor rgb "gray40"
set label 1 "the flat rate engages here,\nand not before" at first 1.058, first 150000 left textcolor rgb "gray30"

# $1 = collateral ratio swept to, $5 = sail the leveraged pool holds after the rebalance
plot \
     unbounded using ($1):($5) with lines linewidth 2 linetype 8 \
         title "no bound - what the original graphs showed", \
     flat using ($1):($5) with lines linewidth 3 linetype 7 \
         title "the flat rate of 20, as shipped", \
     gamma1 using ($1):($5) with lines linewidth 2 linetype 2 \
         title "candidate, gamma = 1", \
     gamma025 using ($1):($5) with lines linewidth 2 linetype 4 \
         title "candidate, gamma = 0.25"
