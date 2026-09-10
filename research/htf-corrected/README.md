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

## Full-universe walk-forward (IS 2022.01.01-2024.06.30, OOS 2024.07.01-2026.09.08)
Grid: InpSignalTF {H1, H4} x InpChannelBars {20, 40, 80}, Model=1, all 7 symbols
(EURUSD, GBPUSD, USDJPY, AUDUSD, NZDUSD, AUDNZD, GBPJPY), one global config
selected on the IS block only by best mean net-after-commission@7 (no per-symbol
cherry-picking), then run untouched on every symbol over the OOS block.

IS mean net+comm@7 per config (7-symbol aggregate / 7):
| config | mean | | config | mean |
|---|---|---|---|---|
| h1-c20 | -1 548 | | h4-c20 | -665 |
| h1-c40 | -1 206 | | h4-c40 | -384 |
| h1-c80 | -713 | | h4-c80 | -244 (chosen) |

Even the globally best config is negative on IS. Chosen = h4-c80 (H4 signal,
80-bar channel). OOS on h4-c80, net+comm@7: EURUSD -227 (PF 0.82), GBPUSD -248
(0.82), USDJPY -228 (0.84), AUDUSD -290 (0.79), NZDUSD -259 (0.83), AUDNZD +187
(1.25), GBPJPY -106 (0.92). Total -1 172 across 7 symbols; 6/7 negative; all
runs 100% history quality, deal-reconciled.

IS-period winners flipped in OOS (USDJPY +485..+1 169 on IS, -228 OOS;
GBPJPY +357..+1 253 on IS, -106 OOS). The single positive OOS symbol (AUDNZD,
+187 on 54 trades) was negative on IS for every config -> consistent with noise,
not an edge. DFS details: `scripts/wf-results.json` is written under
`research/htf-corrected/`.

## Indices (US30 / US500 / USTEC / JP225) — same mechanism, new market
`IndexBreakout.mq5` = corrected rig + two index-aware changes: entry air-gap guard
expressed in ATR units (`InpMaxEntryAirGapFrac`, FX-pips guard would reject ~all
index fills) and an optional server-hour session gate (US: 14–23, JP225: 0–10).
History: broker server data, IS block 98% (2022–2024), OOS 100% (2024-07-2026-09),
Model=1.

Pre-registered grid TF{H1,H4} x channel{20,40,80} x session{off,on} = 12 configs x
4 symbols; one global config selected on IS by mean net+comm@7 (none were
aggregate-positive; best = h4-c80-sesson, -731). IS gives useful structural facts
on costs (avg lots/trade x $7):

| symbol | avg lots/trade (h4-c80-sesson) | commission per trade |
|---|---|---|
| US30 | 0.12 | 0.8 USD |
| US500 | 0.77 | 5.4 USD |
| USTEC | 0.19 | 1.4 USD |
| JP225 | 4.7 | 33 USD (of 50 risk) |

OOS on chosen h4-c80-sesson (untouched): US30 -211 (PF 0.77), US500 -588 (0.66),
USTEC -150 (0.88), JP225 -1048 (1.13 gross +47). Total -1 996 across the four;
gross is negative for 3/4 even before commission. As for FX, the IS heroes are
period-bound (USTEC H1 extra-positive 2022 only), and JP225 is structurally
commission-unviable at this sizing regardless of direction.

## Verdict
None of the tested implementations yields a positive, stable, cost-aware
expectancy. The framework (single-market/small-group rate curve breakouts with
2.5x/3x ATR stops on EURUSD/H1-H4) is rejected as a hypothesis, not merely "not
yet profitable": the failure is spread, robust to one-time param/filter changes,
to parameterized signal-TF/channel grid search, and worsens under corrected
mechanics and real ticks. The walk-forward closes the residual question — no
config was aggregate-positive in-sample, and the globally best config still
lost 1 172 USD out-of-sample. The index line (4 indices, same corrected rig with
ATR-relative gap guard and session gate) fails on the same walk-forward basis:
no config aggregate-positive in-sample and chosen config -1 996 USD out-of-sample,
with structural commission drag documented per symbol. Data and scripts used:
`scripts/htf_research.py`, `research/htf-corrected/*.json`.

Default disposition: do NOT trade this line on this $200 account (fractional
trade sizes also fall below minimum lot at 0.25% risk).
Exported findings and methodology remain available for the next hypothesis,
which should be tested on a different market/mechanism with the same cost and
reconciliation machinery rather than this one in different clothes.