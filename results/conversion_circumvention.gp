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

# WHETHER THE FLOOR BOUNDS BOTH ROUTES, or only decides who pays.
#
# The same move - anchor in, sail out - by the two routes the protocol offers. The rebalance makes it in
# one call that only the StabilityPoolManager can make. Anyone else redeems the anchor for collateral and
# mints sail with it: two fee-bearing calls.
#
# The minter refuses to mint sail below its floor, a collateral ratio of 100/99 = 1.0101, whatever the
# route. So below the floor neither route is drawn: both are refused. From the floor up both pay the fair
# rate, the conversion exactly. Nothing the floor stops the rebalance doing is open to anyone by the long
# way round.
#
# The deployed rule bounds the count instead, at 20 sail per anchor, and the count bound acts on the
# conversion alone: at a collateral ratio of 1.002 its conversion pays 20 where the long way round pays the
# fair 500. The floor closes that.
#
# The lower panel is how close the long way round comes to fair. Up to a collateral ratio of 1.15 it is
# exact. From there the incentive config charges the two user legs a fee and the long way falls short of
# fair: by 0.6% from 1.15, 0.8% from 1.2, 1.3% from 1.45 and 1.5% from 1.5. The conversion pays no fee and
# stays fair there.
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

# The floor, as a distance above the peg: 100/99 - 1. Below it both routes are refused.
floor_distance = 1.0 / 99.0

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

set arrow 1 from first floor_distance, graph 0 to first floor_distance, graph 1 nohead dashtype 2 linecolor rgb "gray40"
set label 1 "the floor: both routes\nrefused below it" at first floor_distance * 1.1, first 300 left textcolor rgb "gray30"

# $1 = collateral ratio, $2 = through the conversion, $3 = the long way round, $4 = fair
plot \
     datafile using ($1-1):($4) with lines linewidth 5 linetype 8 \
         title "fair", \
     datafile using ($1-1):($3) with lines linewidth 2 linetype 2 \
         title "the long way round - redeem the anchor, then mint sail", \
     datafile using ($1-1):($2) with lines linewidth 2 linetype 7 \
         title "the rebalance's conversion"

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
set label 2 "exactly fair from the floor up to 1.15" at first 0.012, first 0.9895 left textcolor rgb "gray20"

plot \
     datafile using ($1-1):(($4 > 0 && $3 > 0) ? ($3 / $4) : 1/0) with lines linewidth 2 linetype 2 notitle

unset multiplot
