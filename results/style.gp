# style.gp - THE ONE VISUAL GRAMMAR every comparison graph in this directory draws with.
#
#   load "style.gp"
#
# at the top of a graph, after `set datafile separator comma`. Each visual channel carries exactly ONE dimension,
# and the mapping is the same in every graph, so a reader who has learned one legend has learned them all:
#
#   COLOUR       = WHICH RULE.       black: the DEPLOYED contracts (Minter_v2, on chain).
#                                    blue:  the TREE - Minter_v3 as it stands in this repository, whether measured
#                                           on a local deploy or behind the deployed proxies (the v3 upgrade); the
#                                           marker says which.
#   DASH PATTERN = WHICH QUANTITY    within a panel: the headline quantity solid, the second dashed, the third
#                                    dotted, a fourth dash-dot. A panel says in its key which is which.
#   POINT SHAPE  = WHICH MARKET      the line was measured on: a circle for the deployed proxies on a pinned
#                                    fork (files `_main`, and `_main_v3` for the tree upgraded onto them), a
#                                    triangle for a local deploy of this tree's chain (`_local`). Drawn sparsely
#                                    along the line - a marker every `pi_marks` samples - so it labels the line
#                                    without hiding it. Both markets are founded with the same collateral, so
#                                    their columns compare directly; the shape says only where the row came from.
#
# LINE WIDTH CARRIES NO MEANING and is not staggered: every rule is drawn at width 1, so where rules coincide
# the last one drawn is the one seen. The dashed quantities are drawn a little heavier than the solid one,
# because a dash at the same width reads thinner; that is legibility, not a dimension.
#
# Reference lines - the peg, a threshold, the fair line - are black or grey and never take a rule's colour.
#
# Adding a rule means adding it HERE, once, and nowhere else.

set macros

# ─── colour: the rule ───
c_deployed = "black"
c_tree     = "#1f77b4"

# The names the keys use, so every graph calls a rule the same thing. SHORT, because a key entry is the rule
# and the quantity and nothing else - "deployed, conversion" - so that the key lays out in rows beneath its
# panel; what a line shows belongs in the graph's header comment, not in its legend.
n_deployed = "deployed"
n_tree     = "tree (Minter\\_v3)"
n_v3       = "v3 upgrade"

# ─── the key: BELOW each panel, outside the plot, in rows ───
# Every panel's key sits beneath it, under its x axis, never over a line. Vertical with a row limit, so
# gnuplot adds columns as entries need them; a canvas 1100 wide holds three columns of these titles. Set once
# here; a graph does not re-place its keys.
set key below vertical maxrows 3 spacing 1.0 nobox noopaque

# ─── dash: the quantity within a panel ───
# Use as `@q_second` AFTER a rule clause: the width here comes later on the line and so wins, which is how the
# dashed quantities come out heavier than the solid headline.
q_first  = "dashtype 1 linewidth 1"
q_second = "dashtype 2 linewidth 2"
q_third  = "dashtype 3 linewidth 2"
q_fourth = "dashtype 4 linewidth 2"

# ─── point shape: the market ───
pt_main  = 7     # filled circle   - the deployed proxies, pinned fork  (files named `_main`)
pt_local = 9     # filled triangle - this tree's deploy chain, locally  (files named `_local`)
pi_marks = 20    # a marker every this many samples along a line
ps_marks = 0.7

# ─── one clause per (rule, market): colour, width, the market's marker ───
# Use as `with linespoints @deployed_main @q_first title n_deployed` - the quantity is the panel's to choose.
deployed_main = "linecolor rgb c_deployed pointtype pt_main  pointinterval pi_marks pointsize ps_marks"
tree_main     = "linecolor rgb c_tree     pointtype pt_main  pointinterval pi_marks pointsize ps_marks"
tree_local    = "linecolor rgb c_tree     pointtype pt_local pointinterval pi_marks pointsize ps_marks"

# For graphs whose x axis is discrete (a round number), every sample is a marker: the same clauses without the
# interval, for `with linespoints`.
deployed_main_every = "linecolor rgb c_deployed pointtype pt_main  pointsize ps_marks"
tree_main_every     = "linecolor rgb c_tree     pointtype pt_main  pointsize ps_marks"
tree_local_every    = "linecolor rgb c_tree     pointtype pt_local pointsize ps_marks"

# NO APOSTROPHES IN A TITLE ON A LINE THAT USES THESE. Gnuplot expands `@name` only outside quoted strings and
# tracks both quote characters as it scans, so a `'` inside a double-quoted title reads as an opening quote and
# every macro after it on that plot command is left unexpanded ("invalid character @").

# For graphs drawn as scattered points (one per swept ratio, no line between them).
deployed_main_points = "linecolor rgb c_deployed pointtype pt_main  pointsize 0.45"
tree_main_points     = "linecolor rgb c_tree     pointtype pt_main  pointsize 0.45"
tree_local_points    = "linecolor rgb c_tree     pointtype pt_local pointsize 0.45"

# ─── reference lines: never a rule's colour ───
# `set arrow N from ... to ... @peg_line`
peg_line       = "nohead dashtype 3 linecolor rgb 'gray30'"
fair_line      = "nohead linewidth 2 linecolor rgb 'black'"
threshold_line = "nohead dashtype 2 linewidth 1 linecolor rgb 'gray20'"
floor_line     = "nohead dashtype 5 linewidth 1 linecolor rgb 'gray20'"

# Shared canvas conventions.
set grid xtics ytics
