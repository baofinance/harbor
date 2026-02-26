set terminal pngcairo size 800,600 background "#ffffff"
set grid
set key bmargin
set style line 1 lc rgb "#2563eb" lw 2
set style line 2 lc rgb "#10b981" lw 2
set style line 3 lc rgb "#f59e0b" lw 2
set style line 4 lc rgb "#dc2626" lw 2
set style line 5 lc rgb "#8b5cf6" lw 2
set output "fixed-leverage-comparison.png"
set title "Fixed vs Variable Leverage (A=$40M, initial L=1.67x)"
set xlabel "Collateral Price Change (%)"
set ylabel "Leverage (ratio)"
set xrange [-30:50]
set yrange [1:5]

plot '-' using 1:2 with lines ls 1 title '2x Fixed', \
     '-' using 1:2 with lines ls 2 title '3x Fixed', \
     '-' using 1:2 with lines ls 3 title 'Variable (starts 1.67x)'
-30  2
50  2
e
-30  3
50  3
e
-30  2.33333
-25  2.14286
-20  2
-15  1.88889
-10  1.8
-5  1.72727
0  1.66667
5  1.61538
10  1.57143
15  1.53333
20  1.5
25  1.47059
30  1.44444
35  1.42105
40  1.4
45  1.38095
50  1.36364
e
