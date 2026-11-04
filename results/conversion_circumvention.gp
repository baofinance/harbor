datafile = "conversion_circumvention.csv"
set datafile separator comma
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'conversion_circumvention.png'" conversion_circumvention.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'conversion_circumvention.pdf'" conversion_circumvention.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 700 620 background rgb "gray90" }

# WHETHER THE BOUND BOUNDS ANYTHING, or only decides who pays.
#
# The same move - anchor in, sail out - by the two routes the protocol offers. The rebalance makes it in
# one bounded call that only the StabilityPoolManager can make. Anyone else redeems the anchor for
# collateral and mints sail with it: two fee-bearing calls, neither of them bounded.
#
# The long way round pays EXACTLY the fair rate up to a collateral ratio of 1.10, and the bound engages
# only below 1.0526 - so throughout the band where the bound is active, the trade it bounds is available
# to anyone at full fair value. It is not limiting how much sail is created at a depressed price. It is
# deciding that the stability pool alone is paid a twenty-fifth of what everyone else gets for it: at a
# collateral ratio of 1.002 the conversion pays 20 and the long way pays 500.
#
# The lower panel is where that claim stops holding, and it is drawn rather than asserted. Above 1.10 the
# incentive config charges the two user legs a fee and the long way falls short of fair - by 0.8% around
# 1.2 to 1.4, by 1.5% at 1.6. That is real, and it is irrelevant to the argument: the bound is long since
# disengaged there. Where the bound acts, the panel reads exactly one.
#
# Above 1.0526 the two coincide, because the bound has let go and the conversion is fair as well. Below a
# collateral ratio of 1 the long way is SHUT - minting sail is disallowed with no residual to price it
# against - so the bound there is the whole rule and not a choice between routes. That region is not
# drawn: it has no second line to compare against, and the conversion's flat 20 across it is
# `rebalance_trigger_mismatch`'s subject.
#
# The axis is the distance above the peg, logarithmically, because the quantities are functions of it -
# the fair rate is exactly 1/(collateral ratio - 1) - and because that draws them as the straight lines
# they are.

set logscale x
set xrange [0.0015:0.75]
set xtics ("1.002" 0.002, "1.005" 0.005, "1.01" 0.01, "1.02" 0.02, "1.05" 0.05, \
           "1.1" 0.1, "1.2" 0.2, "1.6" 0.6)
set grid xtics ytics
set colorsequence default
set lmargin at screen 0.14
set rmargin at screen 0.97

# Where the bound lets go, after which the two routes agree because the conversion is fair too.
release = 1.0 / 19.0

set multiplot title "conversion_circumvention.gp" noenhanced

# ------------------------------------- what each route pays, over two and a half orders of magnitude
set tmargin at screen 0.93
set bmargin at screen 0.46

set logscale y
set yrange [1:800]
set ylabel "sail received per unit of anchor given up"
set ytics ("1" 1, "3" 3, "10" 10, "20" 20, "100" 100, "500" 500)
unset xlabel
set xtics ("" 0.002, "" 0.005, "" 0.01, "" 0.02, "" 0.05, "" 0.1, "" 0.2, "" 0.6)
set key bottom left reverse Left noenhanced

set arrow 1 from first release, graph 0 to first release, graph 1 nohead dashtype 2 linecolor rgb "gray40"
set label 1 "the bound lets go here" at first 0.06, first 1.25 left textcolor rgb "gray30"

# $1 = collateral ratio, $2 = through the conversion, $3 = the long way round, $4 = fair
plot \
     datafile using ($1-1):($4) with lines linewidth 5 linetype 8 \
         title "fair", \
     datafile using ($1-1):($3) with lines linewidth 2 linetype 2 \
         title "the long way round - redeem the anchor, then mint sail", \
     datafile using ($1-1):($2) with lines linewidth 2 linetype 7 \
         title "the rebalance's bounded conversion"

# ----------------------------------- and how close the long way round actually is to fair, on its own
set tmargin at screen 0.44
set bmargin at screen 0.17

unset logscale y
set yrange [0.978:1.006]
set ylabel "the long way round,\nover fair"
set ytics 0.01
set xlabel "collateral ratio, by log distance above the peg"
set xtics ("1.002" 0.002, "1.005" 0.005, "1.01" 0.01, "1.02" 0.02, "1.05" 0.05, \
           "1.1" 0.1, "1.2" 0.2, "1.6" 0.6)
unset key
unset label 1

set arrow 2 from graph 0, first 1 to graph 1, first 1 nohead dashtype 2 linecolor rgb "red"
set label 2 "exactly fair while the bound acts" at first 0.0022, first 0.9895 left textcolor rgb "gray20"

plot \
     datafile using ($1-1):(($4 > 0 && $3 > 0) ? ($3 / $4) : 1/0) with lines linewidth 2 linetype 2 notitle

unset multiplot
