# SessionGuard M5 ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â Strategy and operating guide

Version 1.01 Ãƒâ€šÃ‚Â· 9 September 2026

SessionGuard M5 is a MetaTrader 5 Expert Advisor for EUR/USD. It buys a lower-low reclaim and sells a higher-high reclaim on M5, only during defined London and New York sessions. M15 trend, candle-size and pivot-room filters are optional and disabled by default while the new entry model is evaluated. Its default planned reward/risk is 1.5, with a 100-unit daily loss shutdown, a 150-unit daily target, and a 75-unit trailing daily equity drawdown shutdown. All money settings use the account's deposit currency, not necessarily USD.

This is an implemented starting strategy, not an optimized or demonstrated profitable system. Compilation does not establish profitability or broker execution quality.

## Files

| File | Responsibility |
| --- | --- |
| `../SessionGuardM5.mq5` | Root EA, inputs, event handling, dashboard and orchestration |
| `../SessionGuardM5.ex5` | Compiled EA |
| `../helpers/SessionClock.mqh` | London/New York DST and broker-day boundaries |
| `../helpers/SignalEngine.mqh` | Indicators, closed-bar entries and nearby pivot filter |
| `../helpers/NewsFilter.mqh` | EUR/USD high-impact economic calendar filter |
| `../helpers/DailyGuard.mqh` | Daily equity limits, persistence, entry count and cooldown |
| `../helpers/Execution.mqh` | Lot sizing, orders, position ownership, closure and trailing |
| `compile.log` | MetaEditor build output |
| `Backtest-PriceOnly.set` | Explicit price-only tester overrides |

## Installation

1. In the terminal installed at `D:\Trading\terminal64.exe`, choose **File ÃƒÂ¢Ã¢â‚¬Â Ã¢â‚¬â„¢ Open Data Folder**. Confirm it is the terminal data folder containing this `MQL5\Experts\5MScalper` directory. The installation folder and data folder are different locations.
2. Refresh **Navigator ÃƒÂ¢Ã¢â‚¬Â Ã¢â‚¬â„¢ Expert Advisors**. `5MScalper\SessionGuardM5` should appear. If the terminal uses a different data folder, copy the EA and `helpers` into that folder's `MQL5\Experts\5MScalper`, then compile there.
3. Use a demo account first. Attach one instance to your broker's EUR/USD chart, preferably M5. Broker prefixes/suffixes work when the symbol metadata specifies EUR base and USD profit currency. Other currency pairs are rejected.
4. Configure the commission estimate and risk inputs for the account. Check the broker's minimum lot size; the EA skips a trade if minimum volume would exceed its risk budget.
5. Keep the computer clock accurate. Allow algorithmic trading when ready to demo-test. No DLL or WebRequest permission is required.

The EA reads M5 and M15 explicitly, regardless of the attached chart's period. Use one instance per account, and keep the magic number unchanged during the day. Do not combine manual trades or another EA on the same symbol, especially on netting accounts where positions merge. A pre-existing position or pending order on the symbol prevents entries, regardless of magic number.

Building this project does not attach the EA or enable live trading.

## Exact strategy

### Sessions

- London: 08:00 inclusive to 10:00 exclusive, London local time.
- New York: 08:00 inclusive to 10:00 exclusive, New York local time.
- Monday through Friday only. A valid setup is required; daily trading is not guaranteed.
- By default, close owned positions outside these windows. Stop management and daily guards continue outside entry hours.
- London uses the last Sunday of March/October transitions. New York uses the second Sunday of March and first Sunday of November, under modern DST rules (2007 onward).
- With automatic UTC enabled in live trading, sessions use `TimeGMT()`. Broker midnight, deal history and calendar queries use broker/server time.
- A signal candle must have opened within a session. Consequently the earliest ordinary signal follows the first completed M5 candle of that session.

In Sri Lanka, the London window is 12:30ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Å“14:30 during UK summer and 13:30ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Å“15:30 during UK winter. The New York window is 17:30ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Å“19:30 during US summer and 18:30ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Å“20:30 during US winter. UK and US transition dates differ.

### Lower-low buy / higher-high sell

The reference range is the lowest low and highest high of the **six closed M5 candles preceding the signal candle** (`InpSweepLookback=6`). The signal candle is excluded from that calculation.

- **Buy:** the completed signal candle makes a low strictly below the reference low, then closes strictly above that reference low.
- **Sell:** the completed signal candle makes a high strictly above the reference high, then closes strictly below that reference high.
- Skip a candle that satisfies both directions. No candle body color or EMA touch is required.
- Enter on the following M5 bar while Bid remains on the reclaimed side of the reference level. There is no additional signal-candle-high/low breakout requirement. A buy fills at Ask; a sell fills at Bid.
- The setup expires at the end of that following M5 bar. Spread retries remain limited to that lifetime. The signal candle must open within a trading session.
- `InpUseTrendFilter=false`, `InpUseCandleFilter=false` and `InpUsePivotFilter=false` are the new defaults. Turning them on adds the existing M15 EMA20/EMA50 direction/slope check, maximum signal-range/ATR check, or confirmed unbroken pivot target-room check respectively.

This is a sweep-and-reclaim reversal: it buys after a new local lower low has been rejected and sells after a new local higher high has been rejected. It does not attempt to know the final bottom/top in advance. All signal calculations use completed candles. Risk, sessions, spread, news, cooldown and daily limits still gate entries. Weekly trades are an evaluation objective, not a forced quota.

Restarting discards an unfilled setup and waits for a new bar. No broker-side entry stop orders are created.

### Stop and target

- Initial stop: lowest low of the last three closed M5 bars for buys, or highest high for sells, plus a 0.2 ATR outward buffer.
- Initial TP: 1.5 times the entry-to-stop distance by default. `InpRewardRisk` accepts 1.0 or higher.
- Prices are rounded to the broker's tick size. Initial stops and targets are sent with the market order; there is no retry that deliberately opens an unprotected position.
- Search bars 3ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Å“21 for confirmed one-neighbor local pivots. If the nearest pivot in the trade direction is at or before the proposed target, skip the trade. This is a simple support/resistance approximation.
- SL distance, spread, margin, minimum volume and broker restrictions can reject an otherwise valid setup. A local spread rejection may be re-evaluated after 30 seconds while the original setup remains valid. A submitted order is never blindly retried after an ambiguous reply.

RR is a planned gross price ratio. Commission, fills, trailing, session exits and daily shutdowns change realized RR, which may be below 1:1. The EA does not promise every trade will realize at least 1R.

### Trailing

Trailing is enabled by default. At approximately +1 initial R, the EA attempts to move SL to entry plus the configured round-trip commission estimate, negative accrued swap and one tick. It then uses the more protective of that level and the last three completed M5 bars' extreme plus one tick. SL only tightens, TP stays fixed, and broker stop/freeze distances are respected. Modification attempts are at least five seconds apart.

Initial R is inferred from the existing TP and configured RR, which allows trailing to resume after restart. Fill slippage makes that estimate approximate. Do not change RR or manually edit TP while an EA position is open. Cost coverage is an estimate, not a guaranteed break-even fill.

## Risk and daily shutdowns

Volume is rounded down to the broker's volume step. The planned trade budget is the smallest of:

- 20 account-currency units;
- 0.25% of current account equity;
- remaining allowance before the daily 100 loss threshold;
- remaining allowance before the 75 peak-drawdown threshold.

`OrderCalcProfit` estimates loss to SL in the account currency. The per-lot budget includes the configured commission and an adverse entry deviation allowance. Insufficient margin or a volume below the broker minimum causes a skip. There is no martingale, grid, recovery multiplier or averaging down.

Daily guards measure **total account equity**, including floating P/L and charged costs. At the first observed tick of a new broker day, the EA saves equity as the new baseline and peak. It locks when any of these is reached:

| Guard | Default trigger |
| --- | --- |
| Daily loss | Equity minus saved baseline ÃƒÂ¢Ã¢â‚¬Â°Ã‚Â¤ ÃƒÂ¢Ã‹â€ Ã¢â‚¬â„¢100 |
| Daily target | Equity minus saved baseline ÃƒÂ¢Ã¢â‚¬Â°Ã‚Â¥ +150 |
| Daily peak drawdown | Saved intraday equity peak minus equity ÃƒÂ¢Ã¢â‚¬Â°Ã‚Â¥ 75 |

A lock clears virtual setups, blocks new entries and repeatedly attempts to close **only positions matching this symbol and magic number**, at least two seconds apart. It lasts until the next observed broker day. Other account positions are not closed, although their equity changes can trigger the guard. Thus the guard cannot cap the entire account's losses when other trading remains active.

Live baseline, peak and lock are stored in terminal Global Variables with an account-login/magic key and flushed to disk. They survive ordinary EA and terminal restarts. Tester runs use isolated in-memory state. Do not delete the variables, change magic numbers, or run duplicate instances to reset the limits. Use a unique magic for this account; accounts with identical login numbers on different servers in one terminal should use different magic numbers.

On a first installation without saved state, the EA reconstructs today's opening balance from the current balance and today's buy/sell deal P/L, swap, commission and fees. It cannot reconstruct earlier intraday equity peaks or floating equity at midnight. Install before the trading day on a flat account for a clean baseline. A terminal that was offline across midnight uses the first observed equity after restart as the new day's baseline. Deposits, withdrawals, credits and other trading after initialization change equity and therefore affect these limits; use a dedicated account without intraday cash transfers for predictable behavior.

The 75-unit peak drawdown can stop trading before the 100-unit daily loss is reached. Shutdowns depend on a running, connected terminal and available execution; slippage, gaps, rejected closes or outages can cause an overshoot. Existing broker SL/TP remain when the EA is offline.

Daily entry count is reconstructed from unique entry orders in deal history, with a default cap of six. Partial fills of the same order count once. Losing exit deals, including allocated entry costs from the loaded history, start a 15-minute cooldown. History includes today and yesterday so cooldown survives midnight. Default session closure keeps holding periods short; unusually long manually retained positions may have entry fees outside that history window.

## News filter

The EA queries MT5's built-in calendar for high-importance EUR and USD releases from 15 minutes before to 15 minutes after server time. It caches the result for up to 30 seconds. During a blocked period it discards entry setups, but continues managing existing trades. It does not close positions solely because news is approaching.

Calendar query or event lookup failure blocks new entries. A successful empty response means no scheduled event was returned; the EA cannot independently detect an incomplete broker calendar. Unscheduled news is not covered.

MT5's economic calendar is unavailable in Strategy Tester. Tester runs automatically bypass the news filter, even with the live defaults. The initialization journal and on-chart panel explicitly identify these as price-only tests. A historical calendar-file replay is not implemented in this version.

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `InpMagic` | 5090901 | Ownership and persistent state identifier |
| `InpRiskMoney` | 20 | Maximum planned risk per trade in account currency |
| `InpRiskPercent` | 0.25 | Additional equity-percent risk cap |
| `InpDailyMaxLoss` | 100 | Loss from saved daily baseline |
| `InpDailyTarget` | 150 | Profit from saved daily baseline |
| `InpDailyDrawdown` | 75 | Drawdown from daily equity peak |
| `InpMaxEntries` | 6 | Daily filled entry-order cap |
| `InpLossCooldownMinutes` | 15 | Pause following a losing exit |
| `InpLondonStart`, `InpLondonEnd` | 8, 10 | London local hours; same-day window |
| `InpNewYorkStart`, `InpNewYorkEnd` | 8, 10 | New York local hours; same-day window |
| `InpCloseAtSessionEnd` | true | Close owned positions outside sessions |
| `InpAutoServerUTC` | true | Use computer-derived UTC live |
| `InpServerUTCOffsetHours` | 2 | Manual broker offset; server time = UTC + offset |
| `InpSweepLookback` | 6 | Prior closed M5 candles defining the reference range; allowed 2–100 |
| `InpUseTrendFilter` | false | Optional M15 EMA20/EMA50 direction and slope filter |
| `InpUseCandleFilter` | false | Optional maximum signal candle range/ATR filter |
| `InpRewardRisk` | 1.5 | Planned gross TP/SL distance ratio, minimum 1 |
| `InpATRBuffer` | 0.2 | Initial stop buffer in M5 ATR units |
| `InpMaxCandleATR` | 1.5 | Maximum signal candle range in ATR units |
| `InpMaxSpreadPips` | 1 | Maximum entry spread in pips |
| `InpMaxSpreadStopFraction` | 0.15 | Maximum spread divided by stop distance |
| `InpUsePivotFilter` | false | Optional target room before an unbroken confirmed pivot |
| `InpCommissionPerLot` | 7 | Estimated round-trip cost per standard lot, account currency |
| `InpDeviationPoints` | 10 | Requested execution deviation; also used in risk estimate |
| `InpTrailing` | true | Enable cost-adjusted trailing |
| `InpNewsFilter` | true | Block high-impact EUR/USD news and calendar errors |
| `InpNewsWindowMinutes` | 15 | Symmetric pre/post-release window |

For five-digit EUR/USD, 10 points equal one pip. The actual permitted execution deviation depends on broker execution mode. The commission default is a placeholder to replace with your broker's charges.

## Validation and backtesting

The EA was compiled using `D:\Trading\MetaEditor64.exe`; see `compile.log` for the result. Version 1.01 also passed the short tester startup/runtime regression check below. No profitability or live/demo execution result is claimed.

1. Open Strategy Tester and select `5MScalper\SessionGuardM5`, your EUR/USD symbol and M5.
2. Select **Every tick based on real ticks**, with sufficient history to warm up M15 EMA50. Use the intended account currency, realistic starting equity, leverage and commission.
3. Default inputs now start in the tester. News is automatically bypassed and the configured manual broker UTC offset is always used in tester mode. The optional `Backtest-PriceOnly.set` makes these settings explicit. Set the offset to the broker's offset over the tested dates.
4. If the broker changes its server UTC offset seasonally, split the test at those changes and use the appropriate offset in each segment. London/New York DST conversion remains automatic, but the historical broker offset is manual.
5. These results test price/session/risk logic **without news filtering**. They do not validate the complete live strategy.
6. Compare trailing enabled versus disabled, then use unseen dates and a demo forward test. Review costs, trade count, drawdown and loss clusters, not just net profit. Do not optimize against a daily income target.

Before live use, verify in tester/demo: no entries outside sessions; closed-M5 sweep/reclaim entry behavior; session closures; loss cooldown and six-entry cap; lot sizing at minimum volume; each daily guard; restart with an open position and a daily lock; news blackout/unavailable-calendar behavior; and stop/freeze or rejected-order handling. Realized daily loss can exceed a trigger under adverse execution.

## API references

- [MT5 CalendarValueHistory: server-time calendar queries](https://www.mql5.com/en/docs/calendar/calendarvaluehistory)
- [MT5 CTrade PositionModify: check server return codes](https://www.mql5.com/en/docs/standardlibrary/tradeclasses/ctrade/ctradepositionmodify)

The implementation checks trade-server return codes and logs rejected operations in the Experts journal. The on-chart panel shows the current block/wait state, daily account-equity P/L and entry count.

## Version 1.01 startup fix and regression check

The original tester log confirmed that `OnInit` rejected the default news setting. A second check rejected default automatic UTC. Both tester-only startup rejections were removed. Tester mode bypasses unavailable calendar queries and uses `InpServerUTCOffsetHours`, with explicit journal and chart notices. Live calendar failures still block new entries.

An isolated MT5 Strategy Tester run with default EA inputs completed on EURUSD M5, 2025-06-02 through 2025-06-04 (end exclusive), using generated every-tick mode: **125,652 ticks and 576 bars**, with no runtime error. No trades occurred in this short run. This verifies startup and processing through the test period, not profitability or order execution. Evidence: `tester-startup-validation.log`. Compilation: **0 errors, 0 warnings**.

## Version 1.02: sparse-entry diagnosis and trading test

The latest user visual-test agent log contained a buy on January 26, 2026 at 16:42:17 and its session-end close at 17:00. The test was stopped by closing the visual tester window. The issue was sparse entries rather than a complete inability to send orders.

A January 2026 diagnostic run found 79 setups and 61 breakout evaluations: 52 were rejected by the pivot filter, seven by spread/stop ratio, and two opened trades. The old pivot implementation counted small single-neighbor pivots, including levels already crossed by subsequent price action.

Version 1.02 confirms pivots using two candles on each side and removes levels already broken by later closed bars. A locally rejected spread check can now wait 30 seconds and retry within the original setup lifetime. Orders actually submitted to the broker are not retried. Entry rejection reasons and end-of-test setup/evaluation/opened counts are now printed in the journal.

In version 1.02, `InpUsePivotFilter` defaulted to true. That historical pullback comparison is superseded by the version 1.10 reversal baseline below. Use `Reversal-Weekly-Test.set` for the current strategy.

Validation used EURUSD M5, January 1â€“February 1, 2026 (end exclusive), generated every-tick mode, 10,000 USD initial balance, 1:100 leverage and a configured UTC+2 broker offset:

| Configuration | Opened trades | Final balance |
| --- | ---: | ---: |
| Original entry logic with diagnostics | 2 | 9,983.92 USD |
| Corrected pivot filter enabled | 3 | 9,968.84 USD |
| Activity-Test preset, pivot filter disabled | 37 | 9,956.93 USD |

The activity test processed 1,172,962 ticks and 6,043 bars and completed without runtime errors. These are generated-tick functional comparisons without historical news filtering. Broker tester commission settings determine charged costs; the EA commission input is a sizing estimate, not a command to charge commission. These results do not establish profitability. Evidence: `entry-diagnostics-before.log`, `entry-diagnostics-after.log`, and `activity-test-validation.log`.

## Version 1.10: lower-low / higher-high reversal baseline

The default entry model now buys a lower low followed by a close above the preceding six-bar low, and sells a higher high followed by a close below the preceding six-bar high. Orders are evaluated on the following M5 candle. The EMA trend, maximum candle/ATR and pivot-room filters are off by default so the reversal model can be assessed before adding quality filters. Daily limits, sessions, spread controls, SL/TP and sizing remain active.

Load `Reversal-Weekly-Test.set` in Strategy Tester Inputs, or reset EA inputs to the new defaults. Old saved input sets may retain filters from previous versions. Verify the broker UTC offset. No calendar news replay is included in tester mode.

A default-input generated every-tick EURUSD M5 run from January 1 to September 8, 2026 (end exclusive), with UTC+2 configured, 10,000 USD deposit and 1:100 leverage, completed without runtime errors:

- 694 opened trades; 8,748,688 ticks and 50,955 bars processed.
- Trades in all 35 complete calendar weeks, plus the starting partial week.
- The ending partial week consisted only of September 7 and had no trades: 36 of 37 calendar-week buckets were active overall.
- Final balance: 8,891.47 USD, a loss of 1,108.53 USD. This is an activity baseline, not a profitable validated strategy.

See `Reversal-Weekly-Validation.md` for each week's buy/sell counts and tester evidence. Weekly activity in historical data cannot guarantee future weekly trades. No trades are forced to meet a quota. The reusable report script is `../helpers/Analyze-WeeklyTrades.ps1`.