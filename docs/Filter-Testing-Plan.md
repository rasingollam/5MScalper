# SessionGuard M5: filter-testing plan

## Evidence reviewed

Completed v1.10 isolated EURUSD M5 test, January 1 to September 8, 2026 (end exclusive). The latest main-terminal visual log was an older, interrupted test, so it is not the basis for these statistics. The completed reversal run contained 694 trades and activity in all 35 full weeks.

- Net result: -1,108.53 USD; profit factor 0.78.
- Reported winning trades: 44.96%; average win 12.82 USD, average loss 13.37 USD. The deal-level calculation counts 310 strictly positive outcomes, two zero outcomes and 382 negative outcomes; MT5 includes the two zeros in its 312 profit-trade count.
- London: 287 trades, -612.36 USD, profit factor 0.72.
- New York: 407 trades, -496.17 USD, profit factor 0.83.
- Buys: -653.55 USD; sells: -454.98 USD. Every weekday group was negative.
- Market/session exits: 148 trades, +303.24 USD. This does not prove forced exits help relative to holding longer; that needs a separate simulation.
- The report charged zero commission and swap. The EA's commission input affects planned sizing, not tester-account charges.

These aggregates identify questions to test, not which future trades will win. Exit categories are known only after a trade and cannot be used as entry filters. See `Loss-Analysis.txt` for the group breakdown.

## Test sequence

1. **Make costs and timestamps reliable.** Repeat the baseline with broker real ticks, actual commission, realistic execution delay and the correct historical broker UTC offset. News was bypassed in these tests; do not claim a news-filter benefit until historical calendar replay or demo evidence exists.
2. **Test rejection strength first.** Keep the six-bar sweep/reclaim, but require a buy candle to close in its upper third, or a sell candle in its lower third. This tests whether decisive rejection is better than barely reclaiming the old level. Do not add multiple wick, body and ATR thresholds simultaneously.
3. **Test an opposing-trend veto independently.** As an initial hypothesis, skip buys when M15 ADX(14) exceeds 25 and EMA20 is below EMA50; reverse for sells. This targets reversal attempts against strong directional movement while retaining opportunities in weaker trends/ranges. The current logs do not record ADX, so this is unverified.
4. **Separate entry quality from exit management.** Compare the current trailing against fixed initial SL and 1.5R TP using the same entry rules. Small realized winners may be caused by exits, but the current aggregate report cannot establish that trailing is harmful. Retain daily shutdowns and session exits for the initial comparison.
5. **Test session selection last.** Compare both sessions against New York only. Its historical profit factor is better, but still below 1. Do not remove weekdays based on these results: none is profitable, and the differences are small.

Test each change separately against the same baseline, then combine only changes with consistent improvements. Keep risk and lot-sizing settings constant. Do not loosen SL or increase risk to hide a poor entry edge.

## Acceptance criteria

Use chronological development and validation blocks, and reserve a genuinely unused period or demo forward run for final confirmation. January–September has already been inspected, so it is not a pristine final holdout. MT5 supports separate forward testing: https://www.metatrader5.com/en/terminal/help/algotrading/testing

Compare net expectancy, profit factor after costs, drawdown, trade count and active weeks. Seek positive expectancy and stable improvement across multiple periods while maintaining useful weekly activity; a higher win rate alone is insufficient. Record rejected entries so reduced losses can be weighed against excluded winners. No forced weekly quota and no claim of retaining only winning trades.

Recommended first experiment: cost-corrected baseline versus the upper/lower-third rejection-close rule. Then test the trend veto separately. No EA settings or trading logic were changed by this review.
