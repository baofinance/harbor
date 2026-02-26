set terminal pngcairo size 800,600 background "#ffffff"
set grid
set key bmargin
set style line 1 lc rgb "#2563eb" lw 2
set style line 2 lc rgb "#10b981" lw 2
set style line 3 lc rgb "#f59e0b" lw 2
set style line 4 lc rgb "#dc2626" lw 2
set style line 5 lc rgb "#8b5cf6" lw 2
set output "mint-sail-leverage-impact.png"
set title "Mint Sail: Relative Leverage Impact at Different Initial Leverage"
set xlabel "Operation Size (% of Collateral)"
set ylabel "Leverage Change (%)"
set yrange [-60:0]

plot '-' using 1:2 with linespoints ls 1 title 'L=1.5x', \
     '-' using 1:2 with linespoints ls 2 title 'L=2x', \
     '-' using 1:2 with linespoints ls 3 title 'L=3x', \
     '-' using 1:2 with linespoints ls 4 title 'L=4x'
0  0
2  -1
4  -2
6  -3
8  -4
10  -5
12  -6
14  -7
16  -8
18  -9
20  -10
e
0  0
2  -2
4  -4
6  -6
8  -8
10  -10
12  -12
14  -14
16  -16
18  -18
20  -20
e
0  0
2  -4
4  -8
6  -12
8  -16
10  -20
12  -24
14  -28
16  -32
18  -36
20  -40
e
0  0
2  -6
4  -12
6  -18
8  -24
10  -30
12  -36
14  -42
16  -48
18  -54
20  -60
e
