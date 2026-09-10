# HTFTrendBreakout line of research — conclusion (2026-09-10)

Single-change experiments were run as development evidence, not validation.
Reference rig (frozen baseline then corrected): close-style breakout of the
previous `InpChannelBars`-range (signal + forming bars excluded), ATR(20)
volatility, 2.5x ATR initial stop, 3x ATR one-way trailing stop, market entry
on the first tick after the confirming close, one position per symbol, no
pyramiding/reversal. Risk 0.25% of equity, deposit 20 000 USD for research.

## Execution model
- MT5 Model=1 = "1 minute OHLC"; Model=4 = "every tick based on real ticks".
  Earlier notes that Model=1 meant "every tick from 1-min OHLC" were mislabeled.
- The tester charged `swap` in every report but charged **0 commission**;
  commission is therefore reported as a sensitivity line (USD 7 per entry lot
  round trip), not as broker fact.
- Corrected implementation defects that had flattered earlier results:
  - short trailing used the *lowest high* instead of the *lowest low* (asymmetric);
  - position state could be stale at signal time;
  - stop updates counted `PositionModify` calls without checking the retcode;
  - entry-gap/spread rejection paths and filter/veto checks could also block
    opposite-signal exits of an open position, and broker-rejected orders could
    be silently resubmitted.
  - After correction, trades/signals counts changed and results got *worse*.

## Corrected H1 EURUSD 2022–2026 (Model=1, 100% history)
| variant | trades | net | net + comm@7 | PF | WR | max eq DD |
|---|---|---|---|---|---|---|
| baseline | 751 | -2 212.07 | -2 968.84 | 0.85 | 33.6% | 15.77% |
| decisive-close | 694 | -2 206.91 | -2 902.71 | 0.84 | 32.9% | 14.99% |
| trend veto | 747 | -2 172.66 | -2 926.63 | 0.85 | 33.6% | 15.80% |

Longest balance under water ≈ 1 473 days for baseline/veto, ≈ 1 390 for filter.
Nearly all gross profit comes from the top-10 winners; annual P/L is negative in
2023–2026 for every variant (2022 only marginal).

## H4 signal timeframe, diversified (same rig, InpSignalTF=H4, Model=1, 2022–2026)
| symbol | trades | net | net + comm@7 | PF | WR |
|---|---|---|---|---|---|
| EURUSD | 185 | -1 124.91 | -1 212.83 | 0.68 | 34.6% |
| GBPUSD | 188 | -690.15 | -757.56 | 0.80 | 31.9% |
| USDJPY | 190 | +637.94 | +546.45 | 1.17 | 38.4% |
| AUDUSD | 198 | -1 424.77 | -1 527.04 | 0.62 | 31.3% |

USDJPY's positive figure is concentration risk in time: +1 178.67 in 2022,
then negative 2024 (-? , listed -202.45/240.34/-448.32/-130.30 by year 2023-2026).
On Model=4 real ticks, 2026 only: EURUSD -284.55 (PF 0.54, WR 23.1%),
USDJPY -125.25 (PF 0.83, WR 25.0%). The single nominal winner fails the
strictest execution model in the only untouched out-of-sample interval.

## Verdict
None of the tested implementations yields a positive, stable, cost-aware
expectancy. The framework (single-market/small-group rate curve breakouts with
2.5x/3x ATR stops on EURUSD/H1-H4) is rejected as a hypothesis, not merely "not
yet profitable": the failure is spread, robust to one-time param/filter changes,
and worsens under corrected mechanics and real ticks. Data and scripts used:
`scripts/htf_research.py`, `research/htf-corrected/*.json`.

Default disposition: do NOT trade this line on this $200 account (fractional
trade sizes also fall below minimum lot at 0.25% risk).
Exported findings and methodology remain available for the next hypothesis,
which should be tested on a different market/mechanism with the same cost and
reconciliation machinery rather than this one in different clothes.