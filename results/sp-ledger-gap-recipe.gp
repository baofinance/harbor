datafile = "sp-ledger-gap-recipe.csv"
set datafile separator comma
set key autotitle columnheader noenhanced below title " "
set terminal svg enhanced size 700 600 background rgb "gray90"

# The error recipe drives the gap between the StabilityPool's two ledgers - the exact supply counter
# and the product-decayed sum of balances - to its bound, then absorbs it. Both axes span many
# decades, so both are logarithmic.
set logscale x
set logscale y
set format x "10^{%L}"
set format y "10^{%L}"
set grid

set xlabel "baseline supply t (wei)"
set ylabel "gap (wei)"

# The measured gap after the engineered loss must sit on the predicted one: they are plotted together
# so any divergence shows as the lines parting. The bound is t/1e18, the outstanding over-application.
#
# The gap after the absorbing loss (column 4) is not drawn: it is precisely zero at every supply,
# which a logarithmic axis cannot represent. That it is zero is the point of that column - the absorb
# walks the gap all the way back - so read its absence here as the result, not as missing data.
set colorsequence default
plot \
     datafile using ($1):($2) with linespoints linewidth 2 pointtype 7 linetype 1, \
     datafile using ($1):($3) with lines linewidth 1 dashtype 2 linetype 2, \
     datafile using ($1):($5) with lines linewidth 1 dashtype 3 linetype 4
