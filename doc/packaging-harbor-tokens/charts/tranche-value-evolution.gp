set terminal pngcairo size 800,600 background "#ffffff"
set grid
set key bmargin
set style line 1 lc rgb "#2563eb" lw 2
set style line 2 lc rgb "#10b981" lw 2
set style line 3 lc rgb "#f59e0b" lw 2
set style line 4 lc rgb "#dc2626" lw 2
set style line 5 lc rgb "#8b5cf6" lw 2
set output "tranche-value-evolution.png"
set title "Tranche Value Evolution (α=0.5, C0=$100M, A=$40M)"
set xlabel "Collateral Drop (%)"
set ylabel "Value ($M)"
set xrange [-60:0]
set yrange [0:35]

plot '-' using 1:2 with lines ls 1 title 'Senior', \
     '-' using 1:2 with lines ls 2 title 'Junior'
0  30
-5  30
-10  30
-15  30
-20  30
-25  30
-30  30
-35  25
-40  20
-45  15
-50  10
-55  5
-60  0
e
0  30
-5  25
-10  20
-15  15
-20  10
-25  5
-30  0
-35  0
-40  0
-45  0
-50  0
-55  0
-60  0
e
