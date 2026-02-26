set terminal pngcairo size 800,600 background "#ffffff"
set grid
set key bmargin
set style line 1 lc rgb "#2563eb" lw 2
set style line 2 lc rgb "#10b981" lw 2
set style line 3 lc rgb "#f59e0b" lw 2
set style line 4 lc rgb "#dc2626" lw 2
set style line 5 lc rgb "#8b5cf6" lw 2
set output "leverage-delta-variable-sail.png"
set title "∂L/∂C ×100 (A = $40M) - Rate of Leverage Change"
set xlabel "Collateral C ($M)"
set ylabel "Delta ∂L/∂C ×100"
set yrange [-45:0]

plot '-' using 1:2 with linespoints ls 1 notitle
50  -40
51.25  -31.6049
52.5  -25.6
53.75  -21.157
55  -17.7778
57.5  -13.0612
60  -10
65  -6.4
70  -4.44444
80  -2.5
120  -0.625
200  -0.15625
e
