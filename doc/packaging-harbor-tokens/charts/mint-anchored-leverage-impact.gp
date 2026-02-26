set terminal pngcairo size 800,600 background "#ffffff"
set grid
set key bmargin
set style line 1 lc rgb "#2563eb" lw 2
set style line 2 lc rgb "#10b981" lw 2
set style line 3 lc rgb "#f59e0b" lw 2
set style line 4 lc rgb "#dc2626" lw 2
set style line 5 lc rgb "#8b5cf6" lw 2
set output "mint-anchored-leverage-impact.png"
set title "Mint Anchored: Relative Leverage Impact (ΔL/L = α)"
set xlabel "Operation Size (% of Collateral)"
set ylabel "Leverage Change (%)"
set yrange [0:20]

plot '-' using 1:2 with linespoints ls 1 notitle
0  0
2  2
4  4
6  6
8  8
10  10
12  12
14  14
16  16
18  18
20  20
e
