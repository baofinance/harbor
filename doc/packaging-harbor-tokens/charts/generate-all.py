#!/usr/bin/env python3
"""Generate gnuplot scripts and charts for Harbor token documentation.

Design:
  series(f, xs, tol, max_depth)
                            -- evaluates f at each seed x, then adaptively inserts
                               midpoints between adjacent points where linear interpolation
                               deviates from the actual function by more than tol (y-axis
                               units). xs are just seed control points; smoothness is
                               automatic. Denser seeds still help in regions of rapid change.
  render(name, config, ...) -- writes <name>.gp from shared HEADER + config + series data,
                               then calls gnuplot to produce <name>.EXT

Formulas are plain functions. Use functools.partial to curry parameters, producing a
single-argument function suitable for series():

    leverage_40M = partial(leverage, A=40)
    series(leverage_40M, [50, 200], tol=0.02)   # adaptive fills the curve automatically

Note: gnuplot's {/Symbol X} encoding works for PostScript/PDF but NOT for SVG terminal.
Use Unicode characters directly in titles and labels (∂, ×, Δ, α, μ, σ, etc.).

Run from the charts/ directory, or from anywhere (script cd's to its own directory).
"""

import os
import subprocess
from functools import partial
from math import erf, exp, log, sqrt

os.chdir(os.path.dirname(os.path.abspath(__file__)))

# ---------------------------------------------------------------------------
# Shared gnuplot style header
# ---------------------------------------------------------------------------

EXT = "png"  # change to "svg" to switch output format

HEADER = f"""\
set terminal {"pngcairo" if EXT == "png" else "svg"} size 800,600 background "#ffffff"
set grid
set key bmargin
set style line 1 lc rgb "#2563eb" lw 2
set style line 2 lc rgb "#10b981" lw 2
set style line 3 lc rgb "#f59e0b" lw 2
set style line 4 lc rgb "#dc2626" lw 2
set style line 5 lc rgb "#8b5cf6" lw 2"""


def _refine_interval(f, x0, y0, x1, y1, tol, max_depth, depth):
    """Recursively insert midpoints where linear interpolation error exceeds tol.

    Returns interior points (excluding the endpoints x0 and x1) needed to make
    the segment (x0,y0)→(x1,y1) smooth to within tol.
    """
    if depth >= max_depth:
        return []
    xm = (x0 + x1) / 2
    ym = f(xm)
    if abs(ym - (y0 + y1) / 2) <= tol:
        return []  # Linear interpolation is close enough
    left = _refine_interval(f, x0, y0, xm, ym, tol, max_depth, depth + 1)
    right = _refine_interval(f, xm, ym, x1, y1, tol, max_depth, depth + 1)
    return left + [(xm, ym)] + right


def series(f, xs, tol=0.5, max_depth=8):
    """Evaluate f at seed points xs, adaptively inserting intermediate points.

    Between each adjacent pair, bisects the interval and inserts the midpoint
    whenever the actual f(midpoint) deviates from linear interpolation by more
    than tol (in y-axis units). Recurses until smooth or max_depth is reached.

    xs are seed control points — they still matter for deciding where to look,
    but the curve will be smooth regardless of their density.
    tol controls quality: smaller = more points = smoother (at the cost of more data).
    """
    xs = list(xs)
    prev_x, prev_y = xs[0], f(xs[0])
    result = [(prev_x, prev_y)]
    for x in xs[1:]:
        y = f(x)
        result.extend(_refine_interval(f, prev_x, prev_y, x, y, tol, max_depth, 0))
        result.append((x, y))
        prev_x, prev_y = x, y
    return result


def render(name, config, *series_data):
    """Write <name>.gp (HEADER + config + series data) and render to <name>.EXT."""
    lines = [HEADER, f'set output "{name}.{EXT}"', config]
    for data in series_data:
        for x, y in data:
            lines.append(f"{x:g}  {y:.6g}")
        lines.append("e")
    gp_path = name + ".gp"
    with open(gp_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    subprocess.run(["gnuplot", gp_path], check=True)


# ===========================================================================
# Formulas
# ===========================================================================


def sail_value(C, *, A):
    """Sail value: S = C - A
    The sail token's total collateral value minus anchor debt.
    """
    return C - A


def leverage(C, *, A):
    """Leverage: L = C / (C - A) = C / S
    Hyperbolic: approaches infinity as C → A (wipeout), declines to 1 as C → ∞.
    """
    return C / (C - A)


def leverage_delta(C: float, *, A: float) -> float:
    """First derivative of leverage w.r.t. collateral: ∂L/∂C = -A / (C-A)²
    Always negative — leverage falls as collateral rises. Scaled ×100 for visibility.
    Quantifies how much leverage changes per $1M of collateral movement.
    """
    return -A / (C - A) ** 2 * 100


def leverage_gamma(C, *, A):
    """Second derivative of leverage w.r.t. collateral: ∂²L/∂C² = 2A / (C-A)³
    Scaled ×1000 for visibility. Spikes near wipeout (C → A).
    Formula from differentiating L = C/(C-A) twice w.r.t. C.
    """
    return 2 * A / (C - A) ** 3 * 1000


def mint_anchored_impact(alpha: float) -> float:
    """ΔL/L = α: minting anchored increases leverage proportionally to operation size.
    Alpha is the operation size as % of collateral; result is % leverage change.
    Linear identity — minting 1% of collateral as anchored raises leverage by 1%.
    """
    return alpha


def _phi(x: float) -> float:
    """Standard normal CDF via error function. No scipy dependency."""
    return (1.0 + erf(x / sqrt(2.0))) / 2.0


def volatility_decay_pct(T_days: float, *, L: float, sigma: float) -> float:
    """Volatility drag on a fixed-leverage position, expressed as % return over T_days.
    Linear approximation: -L(L-1)/2 * σ² * T. Actual exp() gives slightly smaller losses.
    For variable leverage, effective L is lower than the initial ratio due to anti-correlated drift.
    """
    return -L * (L - 1) / 2 * sigma**2 * T_days / 365 * 100


def wipeout_prob(L: float, *, mu: float = 0.10, sigma: float = 0.60, T: float = 1.0) -> float:
    """GBM first-passage probability of wipeout within T years for sail leverage L.
    Sail wipes when collateral drops by fraction 1/L; log-barrier h = log((L-1)/L).
    P = Φ(d1) + exp(2νh/σ²)·Φ(d2),  ν = μ − σ²/2,
        d1 = (h − νT)/(σ√T),  d2 = (h + νT)/(σ√T).
    Returns probability as a percentage.
    """
    if L <= 1.0:
        return 100.0
    h = log((L - 1.0) / L)
    nu = mu - sigma**2 / 2.0
    sqrtT = sqrt(T)
    d1 = (h - nu * T) / (sigma * sqrtT)
    d2 = (h + nu * T) / (sigma * sqrtT)
    return min((_phi(d1) + exp(2.0 * nu * h / sigma**2) * _phi(d2)) * 100.0, 100.0)


def senior_value_fixed(C: float, *, A: float, L_senior: float) -> float:
    """Senior tranche value with fixed-leverage target: min(C-A, C/L_senior)."""
    return min(C - A, C / L_senior) if C > A else 0.0


def junior_value_fixed(C: float, *, A: float, L_senior: float) -> float:
    """Junior tranche residual: max(0, (C-A) - C/L_senior)."""
    return max(0.0, (C - A) - C / L_senior) if C > A else 0.0


def senior_leverage_fixed(C: float, *, A: float, L_senior: float) -> float:
    """Effective senior leverage = C/V_senior. Equals L_senior while junior has value."""
    V = senior_value_fixed(C, A=A, L_senior=L_senior)
    return C / V if V > 0 else 0.0


def junior_leverage_fixed(C: float, *, A: float, L_senior: float) -> float:
    """Junior tranche leverage = C/V_junior. Returns 0 when junior is wiped."""
    V = junior_value_fixed(C, A=A, L_senior=L_senior)
    return C / V if V > 0 else 0.0


def senior_value_waterfall(drop_pct: float, *, C0: float, A: float, alpha: float) -> float:
    """Senior value in α-split waterfall: senior gets priority up to (1-α)×S0."""
    S_senior0 = (1.0 - alpha) * (C0 - A)
    C = C0 * (1.0 + drop_pct / 100.0)
    return min(S_senior0, max(0.0, C - A))


def junior_value_waterfall(drop_pct: float, *, C0: float, A: float, alpha: float) -> float:
    """Junior value in α-split waterfall: residual after senior priority claim."""
    S_senior0 = (1.0 - alpha) * (C0 - A)
    C = C0 * (1.0 + drop_pct / 100.0)
    return max(0.0, (C - A) - S_senior0)


def senior_leverage_waterfall(drop_pct: float, *, C0: float, A: float, alpha: float) -> float:
    """Senior tranche leverage: C/V_senior in α-split waterfall."""
    V = senior_value_waterfall(drop_pct, C0=C0, A=A, alpha=alpha)
    C = C0 * (1.0 + drop_pct / 100.0)
    return C / V if V > 0 else 0.0


def junior_leverage_waterfall(drop_pct: float, *, C0: float, A: float, alpha: float) -> float:
    """Junior tranche leverage: C/V_junior in α-split waterfall. Returns 0 when wiped."""
    V = junior_value_waterfall(drop_pct, C0=C0, A=A, alpha=alpha)
    C = C0 * (1.0 + drop_pct / 100.0)
    return C / V if V > 0 else 0.0


def junior_buffer_pct(drop_pct: float, *, C0: float, A: float, alpha: float) -> float:
    """Junior buffer remaining as % of initial junior value."""
    V0 = junior_value_waterfall(0.0, C0=C0, A=A, alpha=alpha)
    return junior_value_waterfall(drop_pct, C0=C0, A=A, alpha=alpha) / V0 * 100.0 if V0 > 0 else 0.0


def variable_leverage_at_price_change(price_pct: float, *, C0: float, A: float) -> float:
    """Variable sail leverage at a given % price change from initial collateral C0."""
    return leverage(C0 * (1.0 + price_pct / 100.0), A=A)


# ===========================================================================
# 0-anchor-sail-mathematics.md
# Parameters: A = anchor debt = $40M
# ===========================================================================

A = 40  # anchor debt ($M)

# Sail value is linear — adaptive refinement never triggers, any seed spacing works.
render(
    "sail-value-vs-collateral",
    """\
set title "Sail Value S = C - A (A = $40M)"
set xlabel "Collateral C ($M)"
set ylabel "Sail Value S ($M)"
set yrange [0:120]

plot '-' using 1:2 with linespoints ls 1 notitle""",
    series(partial(sail_value, A=A), range(40, 155, 10)),
)

# Leverage is hyperbolic: steep near C=50 (L≈5), flat near C=200 (L≈1.25).
# Seed with just a few points; adaptive refinement adds density where the curve bends.
render(
    "leverage-vs-collateral",
    """\
set title "Leverage L = C/S vs Collateral (A = $40M) - Hyperbolic Decline"
set xlabel "Collateral C ($M)"
set ylabel "Leverage (ratio)"
set yrange [0:5.5]

plot '-' using 1:2 with linespoints ls 1 notitle""",
    series(partial(leverage, A=A), [50, 75, 100, 150, 200], tol=0.02),
)

# Delta is the rate of leverage change per $1M collateral: ∂L/∂C = -A/(C-A)²
# Most negative near wipeout (C≈50), approaches zero as C grows large.
render(
    "leverage-delta",
    """\
set title "∂L/∂C ×100 (A = $40M) - Leverage Sensitivity to Collateral"
set xlabel "Collateral C ($M)"
set ylabel "Delta ∂L/∂C ×100"
set yrange [-45:0]

plot '-' using 1:2 with linespoints ls 1 notitle""",
    series(partial(leverage_delta, A=A), [50, 60, 80, 120, 200], tol=0.5),
)

# Gamma is cubic (∝ 1/(C-A)³): spikes to 80 at C=50, nearly zero by C=200.
# Seed with just endpoints and a few waypoints; adaptive refinement handles the spike.
render(
    "leverage-gamma",
    """\
set title "∂²L/∂C² ×1000 (A = $40M) - Spikes Near Wipeout"
set xlabel "Collateral C ($M)"
set ylabel "Gamma ∂²L/∂C² ×1000"
set yrange [0:85]

plot '-' using 1:2 with linespoints ls 1 notitle""",
    series(partial(leverage_gamma, A=A), [50, 60, 80, 120, 200], tol=0.5),
)

render(
    "mint-anchored-leverage-impact",
    """\
set title "Mint Anchored: Relative Leverage Impact (ΔL/L = α)"
set xlabel "Operation Size (% of Collateral)"
set ylabel "Leverage Change (%)"
set yrange [0:20]

plot '-' using 1:2 with linespoints ls 1 notitle""",
    series(mint_anchored_impact, range(0, 21, 2)),
)

render(
    "mint-sail-leverage-impact",
    """\
set title "Mint Sail: Relative Leverage Impact at Different Initial Leverage"
set xlabel "Operation Size (% of Collateral)"
set ylabel "Leverage Change (%)"
set yrange [-60:0]

plot '-' using 1:2 with linespoints ls 1 title 'L=1.5x', \\
     '-' using 1:2 with linespoints ls 2 title 'L=2x', \\
     '-' using 1:2 with linespoints ls 3 title 'L=3x', \\
     '-' using 1:2 with linespoints ls 4 title 'L=4x'""",
    # TODO: compute from formula ΔL/L = -(L-1)×α; partial(mint_sail_impact, L=1.5) etc.
    [(0, 0), (2, -1), (4, -2), (6, -3), (8, -4), (10, -5), (12, -6), (14, -7), (16, -8), (18, -9), (20, -10)],
    [(0, 0), (2, -2), (4, -4), (6, -6), (8, -8), (10, -10), (12, -12), (14, -14), (16, -16), (18, -18), (20, -20)],
    [(0, 0), (2, -4), (4, -8), (6, -12), (8, -16), (10, -20), (12, -24), (14, -28), (16, -32), (18, -36), (20, -40)],
    [(0, 0), (2, -6), (4, -12), (6, -18), (8, -24), (10, -30), (12, -36), (14, -42), (16, -48), (18, -54), (20, -60)],
)

# ===========================================================================
# 1-variable-leveraged-sail.md
# Same A = $40M, same formulas as above
# ===========================================================================

render(
    "leverage-decreases-as-collateral-increases",
    """\
set title "Leverage Decreases as Collateral Increases (A = $40M)"
set xlabel "Collateral C ($M)"
set ylabel "Leverage L (ratio)"
set yrange [1:5.5]

plot '-' using 1:2 with linespoints ls 1 notitle""",
    series(partial(leverage, A=A), [50, 75, 100, 150, 200], tol=0.02),
)

render(
    "leverage-delta-variable-sail",
    """\
set title "∂L/∂C ×100 (A = $40M) - Rate of Leverage Change"
set xlabel "Collateral C ($M)"
set ylabel "Delta ∂L/∂C ×100"
set yrange [-45:0]

plot '-' using 1:2 with linespoints ls 1 notitle""",
    series(partial(leverage_delta, A=A), [50, 60, 80, 120, 200], tol=0.5),
)

render(
    "leverage-gamma-variable-sail",
    """\
set title "∂²L/∂C² ×1000 (A = $40M)"
set xlabel "Collateral C ($M)"
set ylabel "Gamma ∂²L/∂C² ×1000"
set yrange [0:85]

plot '-' using 1:2 with linespoints ls 1 notitle""",
    series(partial(leverage_gamma, A=A), [50, 60, 80, 120, 200], tol=0.5),
)

render(
    "mint-anchored-tvl-impact",
    """\
set title "Mint Anchored Impact: ΔL/L vs Operation Size (% of TVL)"
set xlabel "Operation Size (% of Collateral)"
set ylabel "Leverage Change (%)"
set yrange [0:20]

plot '-' using 1:2 with linespoints ls 1 notitle""",
    series(mint_anchored_impact, range(0, 21, 2)),
)

# ===========================================================================
# 2-tiered-sail.md
# C0 = $100M, A = $40M, α = 0.5 (waterfall), L_senior = 2x (fixed), σ = 60%, μ = 10%
# ===========================================================================

C0_t = 100  # initial collateral ($M)
A_t = 40  # anchor debt ($M)
alpha_t = 0.5  # junior fraction for waterfall charts
Ls = 2  # senior leverage target for fixed-leverage charts
σ = 0.60  # asset volatility
μ = 0.10  # drift

# Fixed leverage comparison: 2x/3x constant vs variable starting at C0=100, A=40 (L=1.67x)
render(
    "fixed-leverage-comparison",
    """\
set title "Fixed vs Variable Leverage (A=$40M, initial L=1.67x)"
set xlabel "Collateral Price Change (%)"
set ylabel "Leverage (ratio)"
set xrange [-30:50]
set yrange [1:5]

plot '-' using 1:2 with lines ls 1 title '2x Fixed', \\
     '-' using 1:2 with lines ls 2 title '3x Fixed', \\
     '-' using 1:2 with lines ls 3 title 'Variable (starts 1.67x)'""",
    [(-30, 2), (50, 2)],
    [(-30, 3), (50, 3)],
    series(partial(variable_leverage_at_price_change, C0=C0_t, A=A_t), range(-30, 51, 5), tol=0.02),
)

# Volatility drag: linear approximation of geometric compounding loss.
# Variable (~12%/yr) uses effective L=1.457 (lower than static 1.67x due to anti-correlated drift).
render(
    "volatility-decay",
    """\
set title "Volatility Drag vs Holding Period (σ=60%, decay term only)"
set xlabel "Holding Period (days)"
set ylabel "Decay (%)"
set yrange [-115:5]

plot '-' using 1:2 with lines ls 1 title '2x Fixed (36%/yr)', \\
     '-' using 1:2 with lines ls 2 title '3x Fixed (108%/yr)', \\
     '-' using 1:2 with lines ls 3 title 'Variable (\\~12%/yr)'""",
    series(partial(volatility_decay_pct, L=2, sigma=σ), range(0, 366, 30), tol=0.5),
    series(partial(volatility_decay_pct, L=3, sigma=σ), range(0, 366, 30), tol=0.5),
    # Effective L≈1.457 gives ~12%/yr: variable leverage is lower than formula predicts
    # because leverage falls when the position is winning (anti-correlated drift).
    series(partial(volatility_decay_pct, L=1.457, sigma=σ), range(0, 366, 30), tol=0.5),
)

# Wipeout probability from GBM first-passage formula.
# Correct values (μ=10%, σ=60%, T=1yr): L=1.5→8.5%, L=2→28.8%, L=3→54.5%, L=5→74.5%
render(
    "wipeout-probability",
    """\
set title "Wipeout Probability vs Leverage (σ=60%, μ=10%, T=1yr)"
set xlabel "Leverage"
set ylabel "P(Wipeout within 1yr) (%)"
set xrange [1:5]
set yrange [0:80]

plot '-' using 1:2 with lines ls 1 title ''""",
    series(partial(wipeout_prob, mu=μ, sigma=σ, T=1.0), [1.1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5], tol=0.5),
)

# Tranche value evolution (α=0.5 waterfall, drop 0 to -60%).
# At C0=100, A=40, α=0.5: S_senior0=30, S_junior0=30. Junior wipes at drop=-30% (C=70).
render(
    "tranche-value-evolution",
    """\
set title "Tranche Value Evolution (α=0.5, C0=$100M, A=$40M)"
set xlabel "Collateral Drop (%)"
set ylabel "Value ($M)"
set xrange [-60:0]
set yrange [0:35]

plot '-' using 1:2 with lines ls 1 title 'Senior', \\
     '-' using 1:2 with lines ls 2 title 'Junior'""",
    series(partial(senior_value_waterfall, C0=C0_t, A=A_t, alpha=alpha_t), range(0, -61, -5), tol=0.1),
    series(partial(junior_value_waterfall, C0=C0_t, A=A_t, alpha=alpha_t), range(0, -61, -5), tol=0.1),
)

# Leverage by tranche (α=0.5 waterfall).
# Senior: C/V_senior — falls from 3.33 to 2.33 while junior absorbs losses, then rises.
# Junior: C/V_junior — rises rapidly toward infinity as junior approaches wipeout at -30%.
render(
    "leverage-drift-by-tranche",
    """\
set title "Leverage by Tranche as Collateral Drops (α=0.5)"
set xlabel "Collateral Drop (%)"
set ylabel "Leverage (ratio)"
set xrange [-60:0]
set yrange [0:20]

plot '-' using 1:2 with lines ls 1 title 'Senior', \\
     '-' using 1:2 with lines ls 2 title 'Junior'""",
    series(partial(senior_leverage_waterfall, C0=C0_t, A=A_t, alpha=alpha_t), range(0, -61, -5), tol=0.1),
    # Junior leverage spikes near wipeout (-30%); cap at 20 for chart visibility.
    series(
        lambda d: min(junior_leverage_waterfall(d, C0=C0_t, A=A_t, alpha=alpha_t), 20.0),
        [0, -5, -10, -15, -20, -25, -29, -30, -35, -40, -50, -60],
        tol=0.1,
    ),
)

# Junior buffer remaining (α=0.5 waterfall). Depletes linearly: 100% at drop=0 → 0% at drop=-30%.
render(
    "junior-buffer-remaining",
    """\
set title "Junior Buffer Remaining vs Collateral Drop (α=0.5)"
set xlabel "Collateral Drop (%)"
set ylabel "Buffer Remaining (%)"
set xrange [-35:0]
set yrange [0:105]

plot '-' using 1:2 with lines ls 1 title ''""",
    series(partial(junior_buffer_pct, C0=C0_t, A=A_t, alpha=alpha_t), range(0, -31, -5), tol=0.5),
)

# Senior fixed at 2x (while junior has value), junior leverage declines from spike at C=80.
# At C=45: senior=9x (variable region). At C=80: boundary (L_senior=2, junior=0).
# At C=90: junior=18x. At C=160: junior=4x (approaches 1x as C→∞).
render(
    "fixed-senior-junior-variable-leverage",
    """\
set title "Leverage: Senior Fixed 2x, Junior Variable (A=$40M)"
set xlabel "Collateral C ($M)"
set ylabel "Leverage (ratio)"
set yrange [0:20]

plot '-' using 1:2 with lines ls 1 title 'Senior (2x fixed)', \\
     '-' using 1:2 with lines ls 2 title 'Junior (variable)'""",
    series(partial(senior_leverage_fixed, A=A_t, L_senior=Ls), [45, 60, 80, 100, 130, 160], tol=0.05),
    # Junior leverage spikes near C=80 (wipeout); cap at 20 for chart visibility.
    series(
        lambda C: min(junior_leverage_fixed(C, A=A_t, L_senior=Ls), 20.0), [45, 80, 84, 90, 100, 120, 160], tol=0.05
    ),
)

# Tranche values vs collateral for fixed 2x senior.
# V_senior = min(C-40, C/2): slope 1 for C<80, slope 0.5 for C≥80.
# V_junior = max(0, C-40-C/2) = max(0, C/2-40): 0 for C≤80, slope 0.5 for C>80.
render(
    "fixed-senior-tranche-values",
    """\
set title "Tranche Values vs Collateral (A=$40M, L_senior=2x)"
set xlabel "Collateral C ($M)"
set ylabel "Value ($M)"
set yrange [0:60]

plot '-' using 1:2 with lines ls 1 title 'Senior', \\
     '-' using 1:2 with lines ls 2 title 'Junior'""",
    series(partial(senior_value_fixed, A=A_t, L_senior=Ls), range(40, 141, 10), tol=0.1),
    series(partial(junior_value_fixed, A=A_t, L_senior=Ls), range(40, 141, 10), tol=0.1),
)

# Expected decay comparison: senior 2x fixed vs variable sail vs junior (higher effective L).
# Variable (~12%/yr) and junior (~24%/yr) use effective L values from simulation.
render(
    "expected-decay-comparison",
    """\
set title "Volatility Drag Comparison (σ=60%)"
set xlabel "Holding Period (days)"
set ylabel "Decay (%)"
set yrange [-40:5]

plot '-' using 1:2 with lines ls 1 title 'Senior 2x Fixed (36%/yr)', \\
     '-' using 1:2 with lines ls 2 title 'Variable (\\~12%/yr)', \\
     '-' using 1:2 with lines ls 3 title 'Junior (\\~24%/yr)'""",
    series(partial(volatility_decay_pct, L=2, sigma=σ), range(0, 366, 30), tol=0.5),
    # Variable: effective L≈1.457 (~12%/yr due to anti-correlated leverage drift)
    series(partial(volatility_decay_pct, L=1.457, sigma=σ), range(0, 366, 30), tol=0.5),
    # Junior: effective L≈1.758 (~24%/yr; intermediate despite high initial leverage
    # because junior leverage is variable and falls as the junior absorbs gains)
    series(partial(volatility_decay_pct, L=1.758, sigma=σ), range(0, 366, 30), tol=0.5),
)
