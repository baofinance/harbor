datafile = "sail_reserve.csv"
set datafile separator comma
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'sail_reserve.png'" sail_reserve.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'sail_reserve.pdf'" sail_reserve.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 780 820 background rgb "gray90" }

# A COLLATERAL ESCROW behind the sail - MODELLED, not measured. Read the next paragraph before the graph.
#
# ONLY ONE LINE HERE IS A REAL TRANSACTION: "as the market answers today". Every other line is computed
# in the test from the market's own state, because no contract holds an escrow yet. The arithmetic is
# exact given the design - the conversion goes as one over the sail's claim, and an escrow moves nothing
# else in it - but "exact given the design" is not the same as "true of the contract". These lines are
# kept so the implementation can be compared against what was predicted, and that comparison is the
# point: the previous proposal also looked right modelled, and its fatal defect appeared only when a real
# market was really minted into.
#
# WHAT THE ESCROW IS. The sail's claim is the residual - what the collateral is worth once the anchor is
# paid - so at the peg it is nothing and the conversion mints without limit. The escrow holds a fixed
# amount of COLLATERAL per sail token, making the claim `residual + escrow x supply x price`, which
# cannot reach zero. The anchor is untouched: its price is still the smaller of one and the collateral
# ratio, read from the main account alone.
#
# Two choices in that sentence, and both were arrived at by getting them wrong first:
#
#   PER SAIL TOKEN, not as a share of the collateral. A share of the collateral caps the anchor's claim
#   at `(1 - share) x collateral`, which is the earlier proposal under another name - and a capped claim
#   cannot grow, so minting anchor stops being self-limiting and takes a market below full
#   collateralisation.
#
#   IN COLLATERAL, not in pegged tokens. A floor of so many pegged tokens per sail needs the escrow's
#   pegged value held constant, and that value falls with the collateral price - so the escrow would have
#   to GROW in a crash, the one event it exists for and the one moment nothing can fund it. Denominated
#   in collateral it is always exactly what was set aside.
#
# The escrow is SIZED in pegged terms and then divided by the price once and held fixed, because a round
# number of collateral per sail means nothing on its own - collateral here costs about two thousand
# pegged tokens. The sail is worth one pegged token when first minted, so the three sizes read as a
# tenth, a hundredth and a thousandth of the sail's opening price.
#
# The x axis is the collateral ratio minus one, logarithmic, running from ONE WEI above the peg to a
# healthy market - eighteen orders of magnitude. The pole is on the LEFT. It is not the residual share,
# which floors to zero at the sample nearest the peg and would be dropped by a log axis.
#
# THE UPPER PANEL is the conversion rate.
#
#   NO CAP AND NO ESCROW is the fair rate. It runs to a MILLION MILLION MILLION sail per anchor token
#   one wei above the peg, and to two in a healthy market - eighteen orders. That is the defect.
#
#   AS THE MARKET ANSWERS TODAY is flat at twenty across the whole region - not a rate but the leverage
#   ratio cap handed over as though it were one, so a converter one wei above the peg is paid twenty
#   where the fair answer is a million million million. The cap does not bound the pole; it replaces the price with a constant.
#
#   THE ESCROW LINES bound it. Sized at a hundredth of the opening sail price the bound is about two
#   hundred; at a tenth, about twenty. Not one over the size, because the escrow is collateral and the
#   collateral price HALVES between this market's reference state and the pole - so the escrow is worth
#   half as much where it matters most. That is the honest cost of a floor that can always be honoured,
#   and it is visible here rather than assumed away.
#
# The cost is the same panel on the right: sized at a hundredth, a healthy market at a collateral ratio
# of 1.5 pays 1.95 against a fair 2.00, under three percent.
#
# THE LOWER PANEL is what one conversion does to the sail supply - about one percent at a hundredth, and
# flat across the sweep.

set grid xtics ytics
set colorsequence default
set lmargin at screen 0.13
set rmargin at screen 0.96

set multiplot title "sail_reserve.gp" noenhanced

# ─────────────── what the conversion pays
#
# No x axis label on this panel: it shares its axis with the one below, and labelling it here puts the
# text under the key.
set tmargin at screen 0.94
set bmargin at screen 0.64

set logscale x
set logscale y
set format x "%g"
set format y "%g"
unset xlabel
set ylabel "sail per anchor token"
set key at screen 0.5, screen 0.60 center top horizontal maxcols 2 spacing 1.2

plot \
     datafile using ($1 - 1):4 with lines linewidth 3 linetype 1 \
         title "no cap and no escrow", \
     datafile using ($1 - 1):3 with lines linewidth 3 linetype 7 dashtype 2 \
         title "as the market answers today", \
     datafile using ($1 - 1):5 with lines linewidth 2 linetype 2 \
         title "escrow sized at 0.001", \
     datafile using ($1 - 1):6 with lines linewidth 2 linetype 3 \
         title "escrow sized at 0.01", \
     datafile using ($1 - 1):7 with lines linewidth 2 linetype 4 \
         title "escrow sized at 0.1"

# ─────────────── what it does to the supply
set tmargin at screen 0.44
set bmargin at screen 0.22

unset logscale y
set format y "%g"
set yrange [0.9999:1.0105]
set xlabel "collateral ratio minus one - the pole is on the left"
set ylabel "sail supply multiple from one conversion"
set key at screen 0.5, screen 0.10 center top horizontal maxcols 3 spacing 1.2

plot \
     datafile using ($1 - 1):8 with lines linewidth 2 linetype 2 title "escrow sized at 0.001", \
     datafile using ($1 - 1):9 with lines linewidth 2 linetype 3 title "escrow sized at 0.01", \
     datafile using ($1 - 1):10 with lines linewidth 2 linetype 4 title "escrow sized at 0.1"

unset multiplot
