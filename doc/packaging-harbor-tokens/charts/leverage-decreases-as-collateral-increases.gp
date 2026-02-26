set terminal pngcairo size 800,600 background "#ffffff"
set grid
set key bmargin
set style line 1 lc rgb "#2563eb" lw 2
set style line 2 lc rgb "#10b981" lw 2
set style line 3 lc rgb "#f59e0b" lw 2
set style line 4 lc rgb "#dc2626" lw 2
set style line 5 lc rgb "#8b5cf6" lw 2
set output "leverage-decreases-as-collateral-increases.png"
set title "Leverage Decreases as Collateral Increases (A = $40M)"
set xlabel "Collateral C ($M)"
set ylabel "Leverage L (ratio)"
set yrange [1:5.5]

plot '-' using 1:2 with linespoints ls 1 notitle
50  5
51.5625  4.45946
53.125  4.04762
54.6875  3.7234
56.25  3.46154
59.375  3.06452
62.5  2.77778
65.625  2.56098
68.75  2.3913
75  2.14286
81.25  1.9697
87.5  1.84211
100  1.66667
125  1.47059
150  1.36364
200  1.25
e
