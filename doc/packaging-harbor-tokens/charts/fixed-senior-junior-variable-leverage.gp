set terminal pngcairo size 800,600 background "#ffffff"
set grid
set key bmargin
set style line 1 lc rgb "#2563eb" lw 2
set style line 2 lc rgb "#10b981" lw 2
set style line 3 lc rgb "#f59e0b" lw 2
set style line 4 lc rgb "#dc2626" lw 2
set style line 5 lc rgb "#8b5cf6" lw 2
set output "fixed-senior-junior-variable-leverage.png"
set title "Leverage: Senior Fixed 2x, Junior Variable (A=$40M)"
set xlabel "Collateral C ($M)"
set ylabel "Leverage (ratio)"
set yrange [0:20]

plot '-' using 1:2 with lines ls 1 title 'Senior (2x fixed)', \
     '-' using 1:2 with lines ls 2 title 'Junior (variable)'
45  9
45.4688  8.31429
45.9375  7.73684
46.875  6.81818
47.8125  6.12
48.75  5.57143
50.625  4.76471
52.5  4.2
56.25  3.46154
60  3
65  2.6
70  2.33333
80  2
100  2
130  2
160  2
e
45  0
80  0
80.0156  20
80.0312  20
80.0625  20
80.125  20
80.25  20
80.5  20
81  20
82  20
84  20
87  20
88.5  20
88.875  20
89.25  19.2973
90  18
90.625  17.0588
91.25  16.2222
92.5  14.8
93.75  13.6364
95  12.6667
96.25  11.8462
97.5  11.1429
100  10
102.5  9.11111
105  8.4
110  7.33333
115  6.57143
120  6
130  5.2
140  4.66667
160  4
e
