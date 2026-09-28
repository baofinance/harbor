deployed = "liquidate_to_partial_both44_main.csv"
tree     = "liquidate_to_partial_both44_local.csv"
escrow   = "liquidate_to_partial_both44_local_followsCollateral.csv"
cap      = "liquidate_to_partial_both44_local_leverageCap.csv"
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

# `liquidate_to_partial_both44` - all four rules. Colour is the rule, solid is BEFORE the liquidation and dashed
# AFTER where both are drawn, marker is the market (`style.gp`).
#
# This is the measurement that produced the `K = 20` leverage cap, which makes it the one every candidate most
# needs reading against: the count cap is exactly what the escrow replaced, and exactly what the leverage cap
# turns into a refusal. One liquidation at each collateral ratio, with 0.4 of the founding pegged in each
# stability pool so both the collateral leg and the conversion are available - the same split the original
# measured.
#
# NOTHING HERE IS NORMALISED OR DERIVED. All four markets are founded with the same 500 collateral tranches,
# so every column is the raw figure the contracts reported and any two can be read against each other
# directly. A graph that has to correct for its inputs is one where a mistake in the correction cannot be told
# from a difference in the thing measured - and the market size is an input, so there is no reason to correct
# for it afterwards.
#
# THE TOP PANEL IS WHERE A LIQUIDATION LEAVES THE MARKET, and the four rules split two ways:
#
#   - The DEPLOYED rule and the ESCROW CANDIDATE land in the same place at every ratio: the 1.3 threshold from
#     0.5 upward, and less below, where the pools run out before the threshold does. The candidate does this
#     WITHOUT the count cap.
#   - The TREE rule and the LEVERAGE CAP sit on the unliquidated line `y = x` below the peg, and for opposite
#     reasons. The tree CONVERTS there - it pays the pool fairly, in the bottom panel it hands over 7.6 million
#     tokens - but its conversion moves backing into escrow and takes nothing out from under the pegged, so
#     the ratio does not move: a rebalance that rebalances nothing. The cap mints NOTHING there: its floor is
#     1.0526, its manager gives the leveraged leg no headroom below it and routes the target to the collateral
#     leg, and below the peg that leg redeems each pegged for its share of the backing, which is the average
#     and leaves the ratio exactly where it was. Between the peg and the floor the collateral leg redeems at
#     par and lifts the ratio a little - 1.02 to 1.0333, 1.05 to 1.0833 - and from the floor upward both legs
#     run and the cap lands where the deployed rule lands, with the deployed rule's own figures. The tree
#     reaches the threshold from just above the peg, because its conversion above the peg is a real repair.
#
# THE MIDDLE PANEL IS WHY THE COUNT CAP EXISTED. Two lines per rule, and the distinction matters: the price
# BEFORE the liquidation is what a converter is paid at, and the deployed one is ZERO below a collateral ratio
# of one - the residual has gone and nothing else backs the token, so a conversion into it mints without
# bound. That is the pole `K = 20` was bolted on to contain. The two escrow rules' before-price never reaches
# zero, because the escrow is a claim the residual's absence cannot touch. The leverage cap's before-price IS
# the deployed price - no escrow, the same residual - and is drawn only from its floor up, because below it
# nothing is priced: the cap contains the pole by never quoting near it.
#
# The price AFTER is a different thing and is not zero in any rule above about 0.3 - the liquidation has
# restored the market by then, so the price it leaves behind is healthy. Reading the after-price as though it
# were the before-price makes the pole disappear from the graph; they are plotted separately here for that
# reason. Where a rule did nothing, before and after coincide.
#
# THE BOTTOM PANEL IS WHAT THE DEPOSITOR IS LEFT HOLDING, in leveraged tokens, on a linear axis as the original
# drew it. The escrow candidate hands over slightly FEWER tokens than the deployed rule - about four percent
# across most of the range - and that is not a shortfall: its tokens carry the escrow, so each is worth more,
# which is the middle panel. Count and value have to be read together, and a rule paying more tokens at a
# lower price has not paid more. The tree hands over the most of all below the peg - constant-price tokens in
# a market it did not repair. The cap hands over none there: the depositor keeps their pegged, worth what it is
# worth, and has not traded it for tokens worth nothing.

set colorsequence default
set xrange [0:1.62]

# Columns: 1 current CR, 2 after user collateral, 3 after SPCollateral collateral, 4 after user leveraged,
#          5 after SPLeveraged leveraged, 6 after minter collateral, 7 after minter pegged,
#          8 before leveraged price, 9 after leveraged price, 10 after CR
nz(v) = (v == 0 ? NaN : v)
floor_ratio = 20.0 / 19
# The cap quotes no leveraged price below its floor; the column carries the residual's arithmetic there, which
# nothing was ever sold at.
quoted(r, v) = (r < floor_ratio ? NaN : nz(v))

set lmargin at screen 0.10
set rmargin at screen 0.97

set multiplot layout 3,1 title "liquidate\\_to\\_partial\\_both44\\_candidates.gp - one liquidation at each collateral ratio, all four rules" font ",11"

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
     escrow   using 1:10 with linespoints @escrow_local  @q_first title n_escrow, \
     cap      using 1:10 with linespoints @cap_local     @q_first title n_cap, \
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
     tree     using 1:8                with linespoints @tree_local    @q_first  title n_tree.", before", \
     tree     using 1:9                with linespoints @tree_local    @q_second title n_tree.", after", \
     escrow   using 1:8                with linespoints @escrow_local  @q_first  title n_escrow.", before", \
     escrow   using 1:9                with linespoints @escrow_local  @q_second title n_escrow.", after", \
     cap      using 1:(quoted($1, $8)) with linespoints @cap_local     @q_first  title n_cap.", before", \
     cap      using 1:(quoted($1, $9)) with linespoints @cap_local     @q_second title n_cap.", after"
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
     escrow   using 1:4 with linespoints @escrow_local  @q_first title n_escrow, \
     cap      using 1:4 with linespoints @cap_local     @q_first title n_cap
unset arrow 5

unset multiplot
