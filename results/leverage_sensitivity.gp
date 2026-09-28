deployed = "leverage_sensitivity_main.csv"
tree     = "leverage_sensitivity_local.csv"
escrow   = "leverage_sensitivity_local_followsCollateral.csv"
cap      = "leverage_sensitivity_local_leverageCap.csv"
set datafile separator comma
load "style.gp"
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1100,1100 background rgb 'gray90'; set output 'leverage_sensitivity.png'" leverage_sensitivity.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 1100 1100 background rgb "gray90" }

# Does `leverageRatio()` describe the instrument? Measured, not derived - on all four rules. Colour is the
# rule, solid is what the token DOES, dashed is what the contract SAYS, marker is the market (`style.gp`).
#
# The figure is reported to users and is `CR / (max(0, CR-1) + phi)`. What it is FOR is the leveraged token's
# sensitivity to the collateral price - how many percent the token moves for one percent of collateral. So the
# collateral price is moved one percent at each ratio and the token's response is read off. Nothing traded, so
# `dCR/CR` IS `dprice/price` and the perturbation needs no oracle arithmetic.
#
# THE LEVERAGE CAP IS THE ONE RULE WHOSE REPORT IS TRUE EVERYWHERE IT HAS A VALUE. Measured over reported is
# `1.000000` at all 61 ratios above the peg. With no escrow the claim is the residual alone, its sensitivity
# is `CR/(CR-1)` exactly, and that is what the formula prints. The report includes figures ABOVE 20 between
# the peg and the floor - 101 at 1.01, 51 at 1.02, 21 at 1.05 - and those are true too: they are the leverage
# a token ALREADY SOLD carries after the collateral has fallen, which is what a leveraged token is for. What
# the cap bounds is the leverage SOLD: at 1.05, where the figure is 21, no token is minted on any route; at
# 1.06, where it is 17.67, they are. Below the peg the price is zero, there is no response to measure, and the
# formula's division by zero is not drawn.
#
# THE DEPLOYED RULE UNDERSTATES, by up to five times, exactly where its count cap binds. At a ratio of 1.01 the
# reported figure is 20 and the token actually moves 101 percent for one percent of collateral - the SAME 101
# the cap reports honestly. At 1.02 it is 20 against 51, at 1.05 it is 20 against 21. Above 1.06 the cap stops
# binding and the report becomes exact. A holder sizing a position on the reported figure inside that band
# carries five times the exposure they were told they had, and the direction of the error is the dangerous one.
#
# BELOW THE PEG THE DEPLOYED RULE REPORTS 20 FOR A TOKEN WORTH NOTHING. Its price there is exactly zero, so
# there is no proportional response to have: the sensitivity is not 20, it is undefined. Those points are
# masked here rather than drawn as zero, because a zero would read as "unlevered" when the truth is "no price".
#
# BOTH ESCROW RULES OVERSTATE, by nineteen times, everywhere below the peg - they share a valuation, and on a
# fresh market the tree and the candidate draw the same two lines. Their measured sensitivity there is 1.0000 -
# dead flat, and adaptive refinement carries that right up to 0.9996875, a third of a thousandth below the
# peg - while `leverageRatio()` reports 19. That is not a rounding difference, it is a different instrument:
# below the peg the residual is gone and the whole claim is a FIXED QUANTITY OF COLLATERAL, and a fixed
# quantity of collateral moves one for one with its price. The leveraged token stops being leveraged there and
# becomes a plain unlevered collateral claim, and the change is a STEP rather than a ramp.
#
# ABOVE THE PEG THE ESCROW RULES UNDERSTATE BY EXACTLY 20/19, and that figure is derivable rather than
# observed. With the escrow, the claim is `(C.p - P) + E.p`, so
#
#     beta = (CR + phi) / (CR + phi - 1)      against      reported = CR / (CR + phi - 1)
#
# whose ratio is `1 + phi/CR`, and `phi = CR x escrow/backing`, so the ratio is `1 + escrow/backing` - a
# constant. Here that is 1 + 50/950 = 20/19 = 1.0526, and every measured point above the peg is 1.0526 times
# its reported value to four decimals. The formula simply does not know the escrow is part of the claim.
#
# THE SAMPLES CLUSTER BELOW THE PEG because the sweep refines where the lines bend: five extra points between
# 0.995 and 0.9997 on the escrow rules, none at all across the whole smooth stretch from 1.0 to 1.6. A
# discontinuity never satisfies the bend test - no midpoint of a step is near its chord - so the recursion
# spends its depth drawing the cliff, which is what it is for. The perturbation is taken AWAY from the peg for
# the same reason: downward below it, upward above it, so no sample measures a chord across the jump.
#
# THE MIDDLE PANEL IS THE ERROR ITSELF and the one to read if only one is read. A correct report sits on 1:
# the deployed rule understates up to 5x in its cap band, the escrow rules read 1/19 below the peg and 20/19
# above, the cap reads 1.000000 everywhere it has a value. The bottom panel is the price each sensitivity is a
# sensitivity OF: exactly zero below the peg on the deployed rule, floored by the escrow on the two escrow
# rules, and the deployed price on the cap - no escrow, the same residual - quoted only from its floor up.

set colorsequence default
set xrange [0:1.6]

# Columns: 1 collateral ratio, 2 leveraged price, 3 leveraged price up 1 percent,
#          4 measured sensitivity (0 where the price is zero or too small to measure), 5 reported leverage,
#          6 pegged price
nz(v) = (v == 0 ? NaN : v)
# A report of `uint256.max` is the formula dividing by zero - a claim of nothing - and is not a number to draw.
rep(v) = (v == 0 || v > 1e6 ? NaN : v)
err(m, r) = (m == 0 || r == 0 || r > 1e6 ? NaN : m / r)

set lmargin at screen 0.10
set rmargin at screen 0.97

set multiplot layout 3,1 title "leverage\\_sensitivity.gp - what leverageRatio() promises against what the token does, all four rules" font ",11"

# ─── measured against reported ───
set ylabel "percent per percent"
set logscale y
set yrange [0.5:200]
set format y "%g"
set arrow 1 from 1, graph 0 to 1, graph 1 @peg_line
plot \
     deployed using 1:(nz($4))  with linespoints @deployed_main @q_first  title n_deployed.", measured", \
     deployed using 1:(rep($5)) with linespoints @deployed_main @q_second title n_deployed.", reported", \
     tree     using 1:(nz($4))  with linespoints @tree_local    @q_first  title n_tree.", measured", \
     tree     using 1:(rep($5)) with linespoints @tree_local    @q_second title n_tree.", reported", \
     escrow   using 1:(nz($4))  with linespoints @escrow_local  @q_first  title n_escrow.", measured", \
     escrow   using 1:(rep($5)) with linespoints @escrow_local  @q_second title n_escrow.", reported", \
     cap      using 1:(nz($4))  with linespoints @cap_local     @q_first  title n_cap.", measured", \
     cap      using 1:(rep($5)) with linespoints @cap_local     @q_second title n_cap.", reported"
unset arrow 1
unset logscale y

# ─── the error: measured divided by reported, where 1 is a correct report ───
set ylabel "measured / reported"
set yrange [0:6]
set arrow 2 from graph 0, first 1 to graph 1, first 1 @fair_line
set label 1 "a correct report" at 0.06, 1.25 textcolor "black" font ",9"
set arrow 3 from 1, graph 0 to 1, graph 1 @peg_line
plot \
     deployed using 1:(err($4, $5)) with linespoints @deployed_main @q_first title n_deployed, \
     tree     using 1:(err($4, $5)) with linespoints @tree_local    @q_first title n_tree, \
     escrow   using 1:(err($4, $5)) with linespoints @escrow_local  @q_first title n_escrow, \
     cap      using 1:(err($4, $5)) with linespoints @cap_local     @q_first title n_cap
unset arrow 2
unset arrow 3
unset label 1

# ─── why: the leveraged price the sensitivity is a sensitivity OF ───
set ylabel "leveraged price"
set logscale y
set yrange [1e-5:1]
set format y "10^{%T}"
set xlabel "collateral ratio"
set arrow 4 from 1, graph 0 to 1, graph 1 @peg_line
plot \
     deployed using 1:(nz($2)) with linespoints @deployed_main @q_first title n_deployed, \
     tree     using 1:(nz($2)) with linespoints @tree_local    @q_first title n_tree, \
     escrow   using 1:(nz($2)) with linespoints @escrow_local  @q_first title n_escrow, \
     cap      using 1:(nz($2)) with linespoints @cap_local     @q_first title n_cap
unset arrow 4
unset logscale y

unset multiplot
