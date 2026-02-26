set terminal pngcairo size 800,600 background "#ffffff"
set grid
set key bmargin
set style line 1 lc rgb "#2563eb" lw 2
set style line 2 lc rgb "#10b981" lw 2
set style line 3 lc rgb "#f59e0b" lw 2
set style line 4 lc rgb "#dc2626" lw 2
set style line 5 lc rgb "#8b5cf6" lw 2
set output "junior-buffer-remaining.png"
set title "Junior Buffer Remaining vs Collateral Drop (α=0.5)"
set xlabel "Collateral Drop (%)"
set ylabel "Buffer Remaining (%)"
set xrange [-35:0]
set yrange [0:105]

plot '-' using 1:2 with lines ls 1 title ''
0  100
-5  83.3333
-10  66.6667
-15  50
-20  33.3333
-25  16.6667
-30  0
e
