datafile = "conversion_bound_gamma.csv"
thin = "conversion_bound_gamma_thin_sail.csv"
thick = "conversion_bound_gamma_thick_sail.csv"
flat = "conversion_bound_gamma_flat_rate.csv"
set datafile separator comma
# Renders to stdout. To write a file in another format instead, override the terminal on the command
# line - the guard below is what makes that possible, and it works for multiplot graphs, which `replot`
# cannot. Run from this directory:
#
#   gnuplot -e "terminal=1; set terminal pngcairo size 1000,900 background rgb 'gray90'; set output 'conversion_bound_gamma.png'" conversion_bound_gamma.gp
#   gnuplot -e "terminal=1; set terminal pdfcairo size 9,8 background rgb 'gray90'; set output 'conversion_bound_gamma.pdf'" conversion_bound_gamma.gp
#
# Do not commit what those write: results/ holds the CSVs the tests regress against, and rendered output
# is gitignored.
if (!exists("terminal")) { set terminal svg enhanced size 700 700 background rgb "gray90" }

# CHOOSING GAMMA for the supply-relative conversion bound: what it buys, and what it costs.
#
# The upper panel is what it buys. Two cohorts convert the same anchor at different collateral ratios and
# are valued at a common final state; the later one entered lower and took more risk, so it should end up
# ahead. Unbounded it ends up ten times ahead. Under the flat rate in use it ends up exactly level - the
# total compression measured in rebalance_conversion_cohorts, which erases the reward for taking the risk
# along with the lottery. Gamma buys back as much of that spread as it is allowed to.
#
# The lower panel is what it costs. A conversion may issue up to gamma of the supply outstanding, so a
# run of them compounds; ten repeated conversions at the lower ratio are plotted. Read the cost against
# the unbounded line, not against one: an unbounded conversion multiplies the supply twenty million fold
# over those ten events, and the bound's job is to stop that.
#
# The two panels are the trade in full. Dispersion grows about linearly in gamma; supply growth grows
# exponentially. Gamma of 1 keeps a fifth of the spread for six parts in a hundred thousand of the supply
# growth, which is the shape of the bargain - and it confirms the figure doc section 9 proposed from
# arithmetic, measured here at 2.05 against its claimed 2.0.
#
# The upper panel's flat top is the cap ceasing to bind at all: past that gamma the rule is the unbounded
# one, which is also what the graph's own reference line is.

set logscale x
set xrange [0.0008:1200]
set xlabel "gamma - the share of the sail supply one conversion may issue"
set xtics ("0.001" 0.001, "0.01" 0.01, "0.1" 0.1, "0.25" 0.25, "1" 1, "10" 10, "100" 100, "1000" 1000)
set grid xtics ytics
set colorsequence default
set lmargin at screen 0.15
set rmargin at screen 0.96

set multiplot title "conversion_bound_gamma.gp" noenhanced

# ----------------------------------------------------------------- what gamma buys: the spread it keeps
set tmargin at screen 0.93
set bmargin at screen 0.56

set logscale y
set yrange [0.9:20]
set ylabel "later cohort over earlier,\nvalued at a common state"
set ytics ("1" 1, "2" 2, "5" 5, "10" 10)
unset xlabel
# The lower panel carries the labels for the shared axis; an explicit tic list ignores `set format`, so
# the same positions are repeated here without them.
set xtics ("" 0.001, "" 0.01, "" 0.1, "" 0.25, "" 1, "" 10, "" 100, "" 1000)
set key top left reverse Left noenhanced

set arrow 1 from graph 0, first 10 to graph 1, first 10 nohead dashtype 2 linecolor rgb "gray40"
set label 1 "unbounded: the whole spread" at graph 0.62, first 6.0 left textcolor rgb "gray30"

# $1 = gamma, $2 = later over earlier, $3 = supply multiple after two events, $4 = after ten
#
# The three candidate markets carry a tenth, one, and ten sail tokens per anchor token - a hundredfold
# range of the quantity that made the flat rate indefensible. Their curves lie on top of one another to
# four decimal places, which is what "a fraction of the supply means the same in every market" looks like
# when it is measured rather than argued. They are drawn as three lines, not one, so that the coincidence
# is the evidence.
plot \
     datafile using ($1):($2) with lines linewidth 4 linetype 2 \
         title "spread kept - one sail per anchor", \
     thin using ($1):($2) with lines linewidth 2 linetype 4 \
         title "a tenth of the sail per anchor", \
     thick using ($1):($2) with points pointtype 6 pointsize 1.0 linetype 8 \
         title "ten times the sail per anchor", \
     flat using ($1):($2) with lines linewidth 2 dashtype 2 linetype 7 \
         title "the flat rate in use - no gamma to vary"

# -------------------------------------------------------- what it costs: what a run of conversions does
set tmargin at screen 0.54
set bmargin at screen 0.21

set yrange [1:100000000]
set ylabel "sail supply multiple\nafter ten conversions"
set ytics ("1" 1, "10" 10, "1000" 1000, "1e6" 1000000, "2e7" 20000000)
set xlabel "gamma - the share of the sail supply one conversion may issue"
set xtics ("0.001" 0.001, "0.01" 0.01, "0.1" 0.1, "0.25" 0.25, "1" 1, "10" 10, "100" 100, "1000" 1000)
set key at screen 0.5, screen 0.125 center top horizontal maxcols 2 reverse Left noenhanced
unset label 1
unset label 2
unset arrow 1
unset arrow 2

set arrow 3 from graph 0, first 20155392 to graph 1, first 20155392 nohead dashtype 2 linecolor rgb "gray40"
set label 3 "unbounded" at graph 0.03, first 7000000 left textcolor rgb "gray30"

# Where the candidate crosses the flat rate's line is the gamma at which it dilutes no more than the rule
# in use already does - and at that gamma the panel above says it keeps more of the spread. Left of the
# crossing the candidate is better on both counts at once.
plot \
     datafile using ($1):($4) with lines linewidth 4 linetype 2 \
         title "after ten conversions - one sail per anchor", \
     thin using ($1):($4) with lines linewidth 2 linetype 4 \
         title "a tenth of the sail per anchor", \
     thick using ($1):($4) with points pointtype 6 pointsize 1.0 linetype 8 \
         title "ten times the sail per anchor", \
     flat using ($1):($4) with lines linewidth 2 dashtype 2 linetype 7 \
         title "the flat rate in use"

unset multiplot
