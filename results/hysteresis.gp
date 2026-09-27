deployed = "hysteresis_main.csv"
tree     = "hysteresis_local.csv"
escrow   = "hysteresis_local_followsCollateral.csv"
cap      = "hysteresis_local_leverageCap.csv"
set datafile separator comma
load "style.gp"
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1100,1100 background rgb 'gray90'; set output 'hysteresis.png'" hysteresis.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 1100 1100 background rgb "gray90" }

# Does a rebalance offer the same terms as the one before it? All four rules; colour is the rule, solid is the
# depositor's whole position, dashed is the conversion's own increment, marker is the market (`style.gp`).
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
# TWO OF THE FOUR RULES DO NOT PLAY THIS GAME, AND THAT IS THE FIRST READING.
#
#   - THE LEVERAGE CAP REFUSES THE FIRST ROUND. A ratio of 0.6 is below its floor of 1.0526, so it sells no
#     leverage there and its manager, finding no collateral pool in this market, has nothing else to route the
#     rebalance to. Its file has no rows and nothing of it is drawn: the pool keeps exactly what it started
#     with, and the market waits for the price. Whether a sub-peg rebalance SHOULD happen is the question the
#     whole investigation turned on; this rule's answer is no.
#   - THE TREE RULE REBALANCES EVERY ROUND AND REPAIRS NOTHING. It converts, pays fairly - its position line
#     is 1.0000 exactly, sixteen times - and leaves the ratio at 0.6 where it found it, because below the peg
#     its conversion moves backing into escrow and takes no collateral out from under the pegged. What it does
#     instead is visible in the middle panel: `phi` climbs from 0.03 to the hundreds of thousands and the
#     leverage ratio collapses from 19 towards zero, permanently. A perfectly fair sequence of rebalances that
#     leaves the market exactly as broken as it was and destroys the leveraged product on the way.
#
# THE TOP PANEL, FOR THE TWO THAT DO RECAPITALISE, IS NOT THE ANSWER THIS GRAPH USED TO GIVE. Read the
# POSITION, in collateral units, both legs, before and after - not the conversion increment. The increment is
# real but answers a different question: it counts only the tokens a round issued, while the pool's RETAINED
# pegged marks up from 0.6 to par as the burn lifts the ratio, and that retained leg is the larger one. A
# stability pool socialises, so a partial rebalance leaves every depositor part-converted rather than some
# depositors fully converted - the whole position is what a depositor experiences.
#
# NEITHER DECAYS, FOR AS LONG AS EITHER LASTS. The deployed rule retains 0.5229 of the position in round one
# and settles at 0.537 by round four, where it stays. The escrow candidate settles at 0.5914 - about TEN
# PERCENT more of the position per rebalance.
#
# BUT THE CANDIDATE STOPS WORKING AT ROUND 13, and the sequence runs to 16 to show it rather than stopping
# just before. The leveraged price falls about 24x a round while the supply grows about 11x, and a price
# quoted in wei runs out: 433 wei at round 11, 17 at round 12, and at round 13 it floors to ZERO. From there
# the candidate IS the deployed rule - issuing 5.7e18 tokens a round worth nothing at all - and its escrow
# floor, the whole reason it has no pole, is gone.
#
# READ THE SHADED ROUNDS WITH CARE, BECAUSE THE POSITION LINE LIES THERE. It climbs to 0.94, then 0.99, and
# looks like the candidate's best result in the whole graph. It is not: with the price at zero the leveraged
# leg is worth nothing on BOTH sides of the rebalance, so the ratio collapses to the pegged markup alone and
# stops measuring what a depositor was paid. A measure of a position is only as good as the prices in it. The
# INCREMENT line is the honest one past round 12 - it reads 0.0000, which is what the conversion now pays.
#
# THE FAILURE IS GEOMETRIC, SO A BIGGER ESCROW POSTPONES IT RATHER THAN FIXING IT. Supply growth per round is
# about `1 + converted/escrow`, so a ten-times larger escrow would grow the supply about 2x a round instead
# of 11x and buy roughly twice the rounds - still a fixed budget, spent geometrically.
#
# Collateral is the unit because the peg is the one thing this measurement manipulates: the ratio is put back
# by writing the oracle price. The collateral AMOUNT is never touched - not by that reset, and not by a
# rebalance, which burns pegged and mints leveraged against backing that stays where it is - so the pie is
# fixed at 1000 and every row can be read against every other.
#
# THE MIDDLE PANEL IS THE STATE EACH RULE CARRIES FORWARD, on a log axis because the tree's `phi` leaves any
# linear one within three rounds. `phi` is the escrow's value as a share of the pegged claim, and the reported
# leverage ratio is exactly `CR / (max(0, CR-1) + phi)` - so `phi` is the whole of the state the bound carries.
# The deployed rule has no escrow and `phi` is zero throughout (not drawable on a log axis; its leverage reads
# a flat 20). The candidate's `phi` does not move: the escrow dilutes and the pegged claim shrinks in step, so
# their ratio holds and the terms hold with it. The tree's `phi` runs away, which is the leverage going with it.
#
# THE BOTTOM PANEL IS THE MECHANISM, AND IT IS THE ONE NOT TO MISREAD. A leveraged price alone says nothing
# about whether anyone was paid fairly - only the price TIMES the count does, which is why both are drawn here
# on one axis: solid is the count of tokens handed over, dashed the price they were priced at.
#
# THE CANDIDATE'S TWO LINES GO OPPOSITE WAYS. Its price falls 24.3x per round and the count it returns rises
# 11.2x, and 24.3 / 11.2 is 2.17 - exactly the rate at which the market is shrinking, which is the rate at
# which the value given up falls too. So the product holds its share and the top panel is flat. The price fall
# is a change of UNITS, arithmetically a stock split.
#
# THE DEPLOYED RULE'S TWO LINES GO THE SAME WAY. Its count falls 2.165x per round against a market shrinking
# 2.167x - the count is strictly PROPORTIONAL to the pegged taken, because with `K = 20` binding, issuance is
# linear in the input and cannot respond to anything else. Its price falls 3.08x on the first step and settles
# at 2.17x, the market's own rate (its price BEFORE each round is zero, so the price AFTER is the one drawn).
# Price and count both tracking the market means their PRODUCT falls faster than the market does, which is
# the conversion increment in the top panel going to zero by round four.
#
# THE TREE'S PRICE IS A HORIZONTAL LINE. The escrow per token is held, so a token is worth the same in round
# sixteen as in round one, and its count falls only with the market. Fair every round - and useless every
# round, since the ratio never moves.
#
# A cap on issuance is a cap on payment, and a capped payment against a falling price decays to nothing. The
# candidate has no cap, so the falling price is the MECHANISM of fair payment here rather than the cost of it.
# The leverage cap's answer to all of this is not to be here.

set colorsequence default
set xrange [0.5:16.5]
set xtics 1

# Columns: 1 round, 2 CR before, 3 CR after, 4 leveraged price before, 5 leveraged price after,
#          6 leveraged returned, 7 value returned, 8 value given up, 9 value back per given, 10 phi,
#          11 leverage ratio before, 12 minter collateral, 13 holding before, 14 holding after
#
# 13 and 14 are the leveraged pool's WHOLE position - both legs, pegged and leveraged - denominated in
# collateral, and 12 is the market's entire collateral so the share is derivable. 14/13 is what a rebalance
# did to the depositor; column 9 is what the CONVERSION alone paid, which is a different and smaller thing.
nz(v) = (v == 0 ? NaN : v)

set lmargin at screen 0.10
set rmargin at screen 0.97

set multiplot layout 3,1 title "hysteresis.gp - sixteen rebalances from a collateral ratio of 0.6, all four rules" font ",11"

# ─── what the depositor is paid, round by round ───
set ylabel "kept per rebalance"
set yrange [0:1.05]
# Everything from round 13 is after the candidate's price floored to zero. The position line RISES there and
# means nothing - a leg worth zero on both sides of the rebalance cancels out of the ratio - so the region is
# marked rather than left to be read as the best result in the graph.
set object 1 rectangle from 12.5, graph 0 to 16.5, graph 1 fillcolor rgb "gray50" fillstyle solid 0.30 noborder behind
set label 3 "price floored to zero:\nthe position line is\nmeaningless past here" at 12.7, 0.62 textcolor "black" font ",8"
plot \
     deployed using 1:($14/$13) with linespoints @deployed_main_every @q_first  title n_deployed.", position", \
     deployed using 1:9         with linespoints @deployed_main_every @q_second title n_deployed.", increment", \
     tree     using 1:($14/$13) with linespoints @tree_local_every    @q_first  title n_tree.", position", \
     tree     using 1:9         with linespoints @tree_local_every    @q_second title n_tree.", increment", \
     escrow   using 1:($14/$13) with linespoints @escrow_local_every  @q_first  title n_escrow.", position", \
     escrow   using 1:9         with linespoints @escrow_local_every  @q_second title n_escrow.", increment", \
     keyentry with linespoints @cap_local_every title n_cap." (refuses round one)"
unset object 1
unset label 3

# ─── phi and the leverage ratio: the state each rule carries into the next round ───
set ylabel "leverage ratio (solid)\nphi (dashed)"
set logscale y
set yrange [1e-6:1e6]
set format y "10^{%T}"
plot \
     deployed using 1:(nz($11)) with linespoints @deployed_main_every @q_first  title n_deployed.", leverage", \
     tree     using 1:(nz($11)) with linespoints @tree_local_every    @q_first  title n_tree.", leverage", \
     tree     using 1:(nz($10)) with linespoints @tree_local_every    @q_second title n_tree.", phi", \
     escrow   using 1:(nz($11)) with linespoints @escrow_local_every  @q_first  title n_escrow.", leverage", \
     escrow   using 1:(nz($10)) with linespoints @escrow_local_every  @q_second title n_escrow.", phi"
unset logscale y

# ─── price and count on ONE axis: only their product is a payment ───
#
# Both series share the axis so the candidate's two lines can be read as what they are - MIRROR IMAGES about a
# horizontal line, one falling by what the other rises. A second axis on the right would carry the count at its
# own scale, which hides that.
set ylabel "tokens returned (solid)\nprice (dashed)"
set logscale y
set yrange [1e-18:1e19]
set ytics 1e-18, 1e6
set format y "10^{%T}"
set xlabel "rebalance round, each from a collateral ratio of 0.6"
plot \
     deployed using 1:(nz($6)) with linespoints @deployed_main_every @q_first  title n_deployed.", count", \
     deployed using 1:(nz($5)) with linespoints @deployed_main_every @q_second title n_deployed.", price after", \
     tree     using 1:(nz($6)) with linespoints @tree_local_every    @q_first  title n_tree.", count", \
     tree     using 1:(nz($4)) with linespoints @tree_local_every    @q_second title n_tree.", price", \
     escrow   using 1:(nz($6)) with linespoints @escrow_local_every  @q_first  title n_escrow.", count", \
     escrow   using 1:(nz($4)) with linespoints @escrow_local_every  @q_second title n_escrow.", price"
unset logscale y
set ytics autofreq

unset multiplot
