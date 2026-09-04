datafile = "sp-ledger-gap-nsweep.csv"
set datafile separator comma
set key noenhanced below title " "
set terminal svg enhanced size 700 600 background rgb "gray90"

# Gap against the number of depositors, under two deposit-size distributions: all equal, and one whale
# beside dust. The shape is a text column, so each series is filtered out of the one file.
set logscale x
set grid
set autoscale

set xlabel "depositors n"
set ylabel "gap (wei)"

equal = "< awk -F, 'NR>1 && $2==\"equal\"' sp-ledger-gap-nsweep.csv"
whaleDust = "< awk -F, 'NR>1 && $2==\"whaleDust\"' sp-ledger-gap-nsweep.csv"

set colorsequence default
plot \
     equal using ($1):($3) with linespoints linewidth 2 pointtype 7 linetype 1 title "gap, equal deposits", \
     whaleDust using ($1):($3) with linespoints linewidth 2 pointtype 5 linetype 2 title "gap, whale beside dust"
