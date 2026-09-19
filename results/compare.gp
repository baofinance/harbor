# A generic overlay: the same columns of two CSVs, drawn together.
#
# Every other .gp here knows what its own graph should look like and says so. This one knows nothing
# about any particular graph, and exists for the question asked once - what moved? - against any results
# file at all, with no edit to the file that normally draws it.
#
# Two sources of the second file, one mechanism:
#
#   another rule, measured now
#     gnuplot -e "before='liquidate_to_all_leveraged.csv'; \
#         after='liquidate_to_all_leveraged_gamma_1.csv'; cols='5'" compare.gp > /tmp/x.svg
#
#   the same graph, at another commit
#     dir=$(../bin/results-at HEAD~1)
#     gnuplot -e "before='../$dir/liquidate.csv'; after='liquidate.csv'; cols='2 3'" compare.gp > /tmp/x.svg
#
# Variables, all optional but `before` and `after`:
#
#   cols      columns to draw, space separated, e.g. '3 5 7'. Default '2'.
#   xcol      the column to draw them against. Default 1.
#   xname     what to call that axis. Default names the column number, since this tool cannot know.
#   logy      set to anything for a logarithmic value axis, for columns spanning orders of magnitude.
#   terminal  as in every other file here: set it to override the terminal from the command line.
#
# Dashed is `before` and solid is `after`, in matching colours, so a column that did not move draws as a
# solid line sitting on its own dashed one. The legend names the columns once, from the header, rather
# than twice with a suffix - which keeps it readable when several columns are compared at once.

if (!exists("before") || !exists("after")) {
    print ""
    print "compare.gp needs two files:"
    print "  gnuplot -e \"before='old.csv'; after='new.csv'; cols='3 5'\" compare.gp"
    print ""
    exit
}
if (!exists("cols")) { cols = "2" }
if (!exists("xcol")) { xcol = 1 }
if (!exists("xname")) { xname = "column ".xcol }

set datafile separator comma
if (!exists("terminal")) { set terminal svg enhanced size 800 600 background rgb "gray90" }
if (exists("logy")) { set logscale y }

# This file knows nothing about the graph it is drawing, so the title names the two files being
# compared as well as itself - nothing else on the canvas says which they were.
set title "compare.gp - ".before." vs ".after noenhanced
set key below noenhanced title "dashed: before        solid: after"
set grid xtics ytics
set colorsequence default
set xlabel xname

# `before` is drawn without titles so that each column earns one legend entry rather than two; which of
# the pair is which is said once, in the key's title, instead of on every line.
plot \
     for [i=1:words(cols)] before using xcol:(column(int(word(cols, i)))) \
         with lines linewidth 2 dashtype 2 linetype i notitle, \
     for [i=1:words(cols)] after using xcol:(column(int(word(cols, i)))) \
         with lines linewidth 2 linetype i title columnheader(int(word(cols, i)))
