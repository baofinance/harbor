set terminal pngcairo size 800,600 background "#ffffff"
set grid
set key bmargin
set style line 1 lc rgb "#2563eb" lw 2
set style line 2 lc rgb "#10b981" lw 2
set style line 3 lc rgb "#f59e0b" lw 2
set style line 4 lc rgb "#dc2626" lw 2
set style line 5 lc rgb "#8b5cf6" lw 2
set output "expected-decay-comparison.png"
set title "Volatility Drag Comparison (σ=60%)"
set xlabel "Holding Period (days)"
set ylabel "Decay (%)"
set yrange [-40:5]

plot '-' using 1:2 with lines ls 1 title 'Senior 2x Fixed (36%/yr)', \
     '-' using 1:2 with lines ls 2 title 'Variable (\~12%/yr)', \
     '-' using 1:2 with lines ls 3 title 'Junior (\~24%/yr)'
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
0  -0
30  -1.97146
60  -3.94293
90  -5.91439
120  -7.88586
150  -9.85732
180  -11.8288
210  -13.8003
240  -15.7717
270  -17.7432
300  -19.7146
330  -21.6861
360  -23.6576
e
