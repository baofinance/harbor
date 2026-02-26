set terminal pngcairo size 800,600 background "#ffffff"
set grid
set key bmargin
set style line 1 lc rgb "#2563eb" lw 2
set style line 2 lc rgb "#10b981" lw 2
set style line 3 lc rgb "#f59e0b" lw 2
set style line 4 lc rgb "#dc2626" lw 2
set style line 5 lc rgb "#8b5cf6" lw 2
set output "fixed-senior-tranche-values.png"
set title "Tranche Values vs Collateral (A=$40M, L_senior=2x)"
set xlabel "Collateral C ($M)"
set ylabel "Value ($M)"
set yrange [0:60]

plot '-' using 1:2 with lines ls 1 title 'Senior', \
     '-' using 1:2 with lines ls 2 title 'Junior'
40  0
50  10
60  20
70  30
80  40
90  45
100  50
110  55
120  60
130  65
140  70
e
40  0
50  0
60  0
70  0
80  0
90  5
100  10
110  15
120  20
130  25
140  30
e
