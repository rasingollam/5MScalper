# SessionGuard M5 — Strategy and operating guide

Version 1.00 · 9 September 2026

SessionGuard M5 is a MetaTrader 5 Expert Advisor for EUR/USD. It trades M5 pullbacks in an M15 trend, only during defined London and New York sessions. Its default planned reward/risk is 1.5, with a 100-unit daily loss shutdown, a 150-unit daily target, and a 75-unit trailing daily equity drawdown shutdown. All money settings use the account's deposit currency, not necessarily USD.

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

1. In the terminal installed at `D:\Trading\terminal64.exe`, choose **File → Open Data Folder**. Confirm it is the terminal data folder containing this `MQL5\Experts\5MScalper` directory. The installation folder and data folder are different locations.
2. Refresh **Navigator → Expert Advisors**. `5MScalper\SessionGuardM5` should appear. If the terminal uses a different data folder, copy the EA and `helpers` into that folder's `MQL5\Experts\5MScalper`, then compile there.
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

In Sri Lanka, the London window is 12:30–14:30 during UK summer and 13:30–15:30 during UK winter. The New York window is 17:30–19:30 during US summer and 18:30–20:30 during US winter. UK and US transition dates differ.

### Buy setup

1. On the last closed M15 candle, EMA20 is above EMA50. Both are higher than their preceding closed-bar values.
2. The last closed M5 candle touches or crosses EMA20 with its low, then closes above EMA20 and above its own open.
3. Its high-to-low range is no greater than 1.5 × M5 ATR(14).
4. Arm a virtual breakout at that candle's high. Enter at market when Bid breaks above the high; buys fill at Ask. The setup lasts two M5 bars, and a newer valid setup can replace it.
5. Recheck the M15 trend at the breakout. Invalidate the setup if price has reached its stop, it expires, trading is blocked, or a position/order occupies the symbol.

Sell rules reverse the comparisons. Signal indicators use closed bars only. A restart discards an unfilled virtual setup and waits for a new bar; there are no broker-side entry stop orders to survive removal or disconnection.

### Stop and target

- Initial stop: lowest low of the last three closed M5 bars for buys, or highest high for sells, plus a 0.2 ATR outward buffer.
- Initial TP: 1.5 times the entry-to-stop distance by default. `InpRewardRisk` accepts 1.0 or higher.
- Prices are rounded to the broker's tick size. Initial stops and targets are sent with the market order; there is no retry that deliberately opens an unprotected position.
- Search bars 3–21 for confirmed one-neighbor local pivots. If the nearest pivot in the trade direction is at or before the proposed target, skip the trade. This is a simple support/resistance approximation.
- SL distance, spread, margin, minimum volume and broker restrictions can reject an otherwise valid setup. Each breakout gets only one execution attempt, to avoid blind resubmission after ambiguous replies.

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
| Daily loss | Equity minus saved baseline ≤ −100 |
| Daily target | Equity minus saved baseline ≥ +150 |
| Daily peak drawdown | Saved intraday equity peak minus equity ≥ 75 |

A lock clears virtual setups, blocks new entries and repeatedly attempts to close **only positions matching this symbol and magic number**, at least two seconds apart. It lasts until the next observed broker day. Other account positions are not closed, although their equity changes can trigger the guard. Thus the guard cannot cap the entire account's losses when other trading remains active.

Live baseline, peak and lock are stored in terminal Global Variables with an account-login/magic key and flushed to disk. They survive ordinary EA and terminal restarts. Tester runs use isolated in-memory state. Do not delete the variables, change magic numbers, or run duplicate instances to reset the limits. Use a unique magic for this account; accounts with identical login numbers on different servers in one terminal should use different magic numbers.

On a first installation without saved state, the EA reconstructs today's opening balance from the current balance and today's buy/sell deal P/L, swap, commission and fees. It cannot reconstruct earlier intraday equity peaks or floating equity at midnight. Install before the trading day on a flat account for a clean baseline. A terminal that was offline across midnight uses the first observed equity after restart as the new day's baseline. Deposits, withdrawals, credits and other trading after initialization change equity and therefore affect these limits; use a dedicated account without intraday cash transfers for predictable behavior.

The 75-unit peak drawdown can stop trading before the 100-unit daily loss is reached. Shutdowns depend on a running, connected terminal and available execution; slippage, gaps, rejected closes or outages can cause an overshoot. Existing broker SL/TP remain when the EA is offline.

Daily entry count is reconstructed from unique entry orders in deal history, with a default cap of six. Partial fills of the same order count once. Losing exit deals, including allocated entry costs from the loaded history, start a 15-minute cooldown. History includes today and yesterday so cooldown survives midnight. Default session closure keeps holding periods short; unusually long manually retained positions may have entry fees outside that history window.

## News filter

The EA queries MT5's built-in calendar for high-importance EUR and USD releases from 15 minutes before to 15 minutes after server time. It caches the result for up to 30 seconds. During a blocked period it discards entry setups, but continues managing existing trades. It does not close positions solely because news is approaching.

Calendar query or event lookup failure blocks new entries. A successful empty response means no scheduled event was returned; the EA cannot independently detect an incomplete broker calendar. Unscheduled news is not covered.

MT5's economic calendar is unavailable in Strategy Tester. Testing with news enabled is rejected at initialization rather than silently omitting the filter. A historical calendar-file replay is not implemented in this version.

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
| `InpRewardRisk` | 1.5 | Planned gross TP/SL distance ratio, minimum 1 |
| `InpATRBuffer` | 0.2 | Initial stop buffer in M5 ATR units |
| `InpMaxCandleATR` | 1.5 | Maximum signal candle range in ATR units |
| `InpMaxSpreadPips` | 1 | Maximum entry spread in pips |
| `InpMaxSpreadStopFraction` | 0.15 | Maximum spread divided by stop distance |
| `InpCommissionPerLot` | 7 | Estimated round-trip cost per standard lot, account currency |
| `InpDeviationPoints` | 10 | Requested execution deviation; also used in risk estimate |
| `InpTrailing` | true | Enable cost-adjusted trailing |
| `InpNewsFilter` | true | Block high-impact EUR/USD news and calendar errors |
| `InpNewsWindowMinutes` | 15 | Symmetric pre/post-release window |

For five-digit EUR/USD, 10 points equal one pip. The actual permitted execution deviation depends on broker execution mode. The commission default is a placeholder to replace with your broker's charges.

## Validation and backtesting

The EA was compiled using `D:\Trading\MetaEditor64.exe`; see `compile.log` for the result. No profitability backtest or live/demo execution result is claimed by this delivery.

1. Open Strategy Tester and select `5MScalper\SessionGuardM5`, your EUR/USD symbol and M5.
2. Select **Every tick based on real ticks**, with sufficient history to warm up M15 EMA50. Use the intended account currency, realistic starting equity, leverage and commission.
3. Load `Backtest-PriceOnly.set`. It explicitly disables news and automatic UTC. Set the manual offset to the broker's offset over the tested dates.
4. If the broker changes its server UTC offset seasonally, split the test at those changes and use the appropriate offset in each segment. London/New York DST conversion remains automatic, but the historical broker offset is manual.
5. These results test price/session/risk logic **without news filtering**. They do not validate the complete live strategy.
6. Compare trailing enabled versus disabled, then use unseen dates and a demo forward test. Review costs, trade count, drawdown and loss clusters, not just net profit. Do not optimize against a daily income target.

Before live use, verify in tester/demo: no entries outside sessions; M15 trend/closed-M5 entry behavior; session closures; loss cooldown and six-entry cap; lot sizing at minimum volume; each daily guard; restart with an open position and a daily lock; news blackout/unavailable-calendar behavior; and stop/freeze or rejected-order handling. Realized daily loss can exceed a trigger under adverse execution.

## API references

- [MT5 CalendarValueHistory: server-time calendar queries](https://www.mql5.com/en/docs/calendar/calendarvaluehistory)
- [MT5 CTrade PositionModify: check server return codes](https://www.mql5.com/en/docs/standardlibrary/tradeclasses/ctrade/ctradepositionmodify)

The implementation checks trade-server return codes and logs rejected operations in the Experts journal. The on-chart panel shows the current block/wait state, daily account-equity P/L and entry count.
