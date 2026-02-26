set terminal pngcairo size 800,600 background "#ffffff"
set grid
set key bmargin
set style line 1 lc rgb "#2563eb" lw 2
set style line 2 lc rgb "#10b981" lw 2
set style line 3 lc rgb "#f59e0b" lw 2
set style line 4 lc rgb "#dc2626" lw 2
set style line 5 lc rgb "#8b5cf6" lw 2
set output "leverage-gamma-variable-sail.png"
set title "∂²L/∂C² ×1000 (A = $40M)"
set xlabel "Collateral C ($M)"
set ylabel "Gamma ∂²L/∂C² ×1000"
set yrange [0:85]

plot '-' using 1:2 with linespoints ls 1 notitle
50  80
50.625  66.6965
51.25  56.1866
51.875  47.7737
52.5  40.96
53.75  30.7739
55  23.7037
56.25  18.6436
57.5  14.9271
60  10
62.5  7.02332
65  5.12
70  2.96296
80  1.25
120  0.15625
200  0.0195312
e
