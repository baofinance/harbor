set terminal pngcairo size 800,600 background "#ffffff"
set grid
set key bmargin
set style line 1 lc rgb "#2563eb" lw 2
set style line 2 lc rgb "#10b981" lw 2
set style line 3 lc rgb "#f59e0b" lw 2
set style line 4 lc rgb "#dc2626" lw 2
set style line 5 lc rgb "#8b5cf6" lw 2
set output "volatility-decay.png"
set title "Volatility Drag vs Holding Period (σ=60%, decay term only)"
set xlabel "Holding Period (days)"
set ylabel "Decay (%)"
set yrange [-115:5]

plot '-' using 1:2 with lines ls 1 title '2x Fixed (36%/yr)', \
     '-' using 1:2 with lines ls 2 title '3x Fixed (108%/yr)', \
     '-' using 1:2 with lines ls 3 title 'Variable (\~12%/yr)'
0  -0
30  -2.9589
60  -5.91781
90  -8.87671
120  -11.8356
150  -14.7945
180  -17.7534
210  -20.7123
240  -23.6712
270  -26.6301
300  -29.589
330  -32.5479
360  -35.5068
e
0  -0
30  -8.87671
60  -17.7534
90  -26.6301
120  -35.5068
150  -44.3836
180  -53.2603
210  -62.137
240  -71.0137
270  -79.8904
300  -88.7671
330  -97.6438
360  -106.521
e
0  -0
30  -0.985092
60  -1.97018
90  -2.95528
120  -3.94037
150  -4.92546
180  -5.91055
210  -6.89564
240  -7.88073
270  -8.86583
300  -9.85092
330  -10.836
360  -11.8211
e
