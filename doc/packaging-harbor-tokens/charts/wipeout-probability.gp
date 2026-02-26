set terminal pngcairo size 800,600 background "#ffffff"
set grid
set key bmargin
set style line 1 lc rgb "#2563eb" lw 2
set style line 2 lc rgb "#10b981" lw 2
set style line 3 lc rgb "#f59e0b" lw 2
set style line 4 lc rgb "#dc2626" lw 2
set style line 5 lc rgb "#8b5cf6" lw 2
set output "wipeout-probability.png"
set title "Wipeout Probability vs Leverage (σ=60%, μ=10%, T=1yr)"
set xlabel "Leverage"
set ylabel "P(Wipeout within 1yr) (%)"
set xrange [1:5]
set yrange [0:80]

plot '-' using 1:2 with lines ls 1 title ''
1.1  0.0108659
1.2  0.417372
1.3  1.99838
1.5  8.51046
2  28.782
2.25  37.1212
2.5  44.0136
3  54.4298
3.5  61.7654
4  67.1449
4.5  71.2348
5  74.439
e
