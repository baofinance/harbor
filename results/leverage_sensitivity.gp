deployed = "leverage_sensitivity_main.csv"
tree     = "leverage_sensitivity_local.csv"
v3       = "leverage_sensitivity_main_v3.csv"
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

# Does `leverageRatio()` describe the instrument? Measured, not derived - on the DEPLOYED contracts, the TREE on
# a local deploy, and the V3 UPGRADE (this tree's minter, manager and pools behind the deployed proxies). Colour
# is the rule, solid is what the token DOES, dashed is what the contract SAYS, marker is the market (`style.gp`);
# the tree and the upgrade share a colour because they are the same rule.
#
# The figure is reported to users and is `CR / (CR - 1)`. What it is FOR is the leveraged token's sensitivity
# to the collateral price - how many percent the token moves for one percent of collateral. So the collateral
# price is moved one percent at each ratio and the token's response is read off. Nothing traded, so `dCR/CR` IS
# `dprice/price` and the perturbation needs no oracle arithmetic.
#
# THE TREE'S REPORT IS TRUE EVERYWHERE IT HAS A VALUE, on the local deploy and on the deployed proxies alike.
# Measured over reported is `1.000000` at every ratio above the peg. The claim is the residual alone, its
# sensitivity is `CR/(CR-1)` exactly, and that is what the formula prints. The report includes figures ABOVE
# 20 between the peg and the floor - 101 at 1.01, 51 at 1.02, 21 at 1.05 - and those are true too: they are the
# leverage a token ALREADY SOLD carries after the collateral has fallen, which is what a leveraged token is
# for. What the cap bounds is the leverage SOLD: at 1.05, where the figure is 21, no token is minted on any
# route; at 1.06, where it is 17.67, they are. Below the peg the price is zero, there is no response to
# measure, and the report is `uint256.max` - the encoding for a claim of nothing - which is not a number and is
# not drawn.
#
# THE DEPLOYED RULE UNDERSTATES, by up to five times, exactly where its count cap binds. At a ratio of 1.01 the
# reported figure is 20 and the token actually moves 101 percent for one percent of collateral - the SAME 101
# the tree reports. At 1.02 it is 20 against 51, at 1.05 it is 20 against 21. Above 1.06 the cap stops binding
# and the report becomes exact. A holder sizing a position on the reported figure inside that band carries five
# times the exposure they were told they had, and the direction of the error is the dangerous one.
#
# BELOW THE PEG THE DEPLOYED RULE REPORTS 20 FOR A TOKEN WORTH NOTHING. Its price there is exactly zero, so
# there is no proportional response to have: the sensitivity is not 20, it is undefined. Those points are
# masked here rather than drawn as zero, because a zero would read as "unlevered" when the truth is "no price".
#
# THE MIDDLE PANEL IS THE ERROR ITSELF and the one to read if only one is read. A correct report sits on 1:
# the deployed rule understates up to 5x in its cap band; the tree and the upgrade read 1.000000 everywhere
# they have a value. The bottom panel is the price each sensitivity is a sensitivity OF, and it is ONE line
# drawn three times: no rule here carries an escrow, so all three price the same residual, and the price is
# exactly zero below the peg on all of them.

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

set multiplot layout 3,1 title "leverage\\_sensitivity.gp - what leverageRatio() promises against what the token does: deployed, the tree, and the upgrade" font ",11"

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
     v3       using 1:(nz($4))  with linespoints @tree_main     @q_first  title n_v3.", measured", \
     v3       using 1:(rep($5)) with linespoints @tree_main     @q_second title n_v3.", reported"
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
     v3       using 1:(err($4, $5)) with linespoints @tree_main     @q_first title n_v3
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
     v3       using 1:(nz($2)) with linespoints @tree_main     @q_first title n_v3
unset arrow 4
unset logscale y

unset multiplot
