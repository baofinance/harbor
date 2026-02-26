set terminal pngcairo size 800,600 background "#ffffff"
set grid
set key bmargin
set style line 1 lc rgb "#2563eb" lw 2
set style line 2 lc rgb "#10b981" lw 2
set style line 3 lc rgb "#f59e0b" lw 2
set style line 4 lc rgb "#dc2626" lw 2
set style line 5 lc rgb "#8b5cf6" lw 2
set output "sail-value-vs-collateral.png"
set title "Sail Value S = C - A (A = $40M)"
set xlabel "Collateral C ($M)"
set ylabel "Sail Value S ($M)"
set yrange [0:120]

plot '-' using 1:2 with linespoints ls 1 notitle
40  0
50  10
60  20
70  30
80  40
90  50
100  60
110  70
120  80
130  90
140  100
150  110
e
