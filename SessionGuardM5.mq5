#property copyright "SessionGuard M5"
#property version "1.01"
#property strict
#property description "EURUSD M5 pullback scalper with M15 trend confirmation and daily equity guards."

input group "Identity and risk (account deposit currency)"
input ulong InpMagic=5090901;
input double InpRiskMoney=20.0;
input double InpRiskPercent=0.25;
input double InpDailyMaxLoss=100.0;
input double InpDailyTarget=150.0;
input double InpDailyDrawdown=75.0;
input int InpMaxEntries=6;
input int InpLossCooldownMinutes=15;
input group "Sessions (local city hours, end exclusive)"
input int InpLondonStart=8;
input int InpLondonEnd=10;
input int InpNewYorkStart=8;
input int InpNewYorkEnd=10;
input bool InpCloseAtSessionEnd=true;
input bool InpAutoServerUTC=true;
input double InpServerUTCOffsetHours=2.0;
input group "Signal and execution"
input double InpRewardRisk=1.5;
input double InpATRBuffer=0.2;
input double InpMaxCandleATR=1.5;
input double InpMaxSpreadPips=1.0;
input double InpMaxSpreadStopFraction=0.15;
input double InpCommissionPerLot=7.0;
input int InpDeviationPoints=10;
input bool InpTrailing=true;
input group "News"
input bool InpNewsFilter=true;
input int InpNewsWindowMinutes=15;

#include "helpers/SessionClock.mqh"
#include "helpers/NewsFilter.mqh"
#include "helpers/SignalEngine.mqh"
#include "helpers/DailyGuard.mqh"
#include "helpers/Execution.mqh"

CNewsFilter news;
CSignalEngine signals;
CDailyGuard guard;
CScalperExecution execution;
ScalperSignal setup;
datetime lastBar=0;
bool pending=false;
string g_status="Starting";

datetime UTCNow(datetime server)
{
   if(InpAutoServerUTC && !MQLInfoInteger(MQL_TESTER)) return TimeGMT();
   return server-(int)MathRound(InpServerUTCOffsetHours*3600);
}
bool InSession(datetime now)
{
   return SessionOpen(UTCNow(now),InpLondonStart,InpLondonEnd,InpNewYorkStart,InpNewYorkEnd);
}
void Display()
{
   Comment("SessionGuard M5 | ",_Symbol,"\n",g_status,
           (MQLInfoInteger(MQL_TESTER)?"\nTESTER: price-only, news bypassed; manual broker UTC offset":""),
           "\nDaily account equity P/L: ",DoubleToString(guard.pnl,2)," ",AccountInfoString(ACCOUNT_CURRENCY),
           " | Entries: ",guard.entries,"/",InpMaxEntries,
           "\nLoss limit: ",InpDailyMaxLoss," | Target: ",InpDailyTarget," | Peak DD: ",InpDailyDrawdown);
}
bool Maintain(datetime now)
{
   bool locked=guard.Update(now,InpMagic,InpDailyMaxLoss,InpDailyTarget,InpDailyDrawdown);
   if(locked)
   {
      pending=false; g_status="Daily limit: locked"; execution.CloseAll(now); return false;
   }
   if(!InSession(now))
   {
      pending=false; g_status="Outside trading sessions";
      if(InpCloseAtSessionEnd) execution.CloseAll(now);
      else if(InpTrailing) execution.Trail(now,InpRewardRisk,InpCommissionPerLot);
      return false;
   }
   if(InpTrailing) execution.Trail(now,InpRewardRisk,InpCommissionPerLot);
   return true;
}
int OnInit()
{
   if(SymbolInfoString(_Symbol,SYMBOL_CURRENCY_BASE)!="EUR" || SymbolInfoString(_Symbol,SYMBOL_CURRENCY_PROFIT)!="USD")
   { Print("Attach SessionGuard M5 to your broker's EURUSD symbol (suffixes supported)."); return INIT_PARAMETERS_INCORRECT; }
   if(InpMagic==0 || InpRiskMoney<=0 || InpRiskPercent<=0 || InpRiskPercent>100 || InpDailyMaxLoss<=0 || InpDailyTarget<=0 || InpDailyDrawdown<=0 || InpMaxEntries<1 || InpLossCooldownMinutes<0 || InpRewardRisk<1 || InpATRBuffer<0 || InpMaxCandleATR<=0 || InpMaxSpreadPips<=0 || InpMaxSpreadStopFraction<=0 || InpMaxSpreadStopFraction>1 || InpCommissionPerLot<0 || InpDeviationPoints<0 || InpNewsWindowMinutes<1 || InpServerUTCOffsetHours< -14 || InpServerUTCOffsetHours>14 || InpLondonStart<0 || InpLondonEnd>24 || InpLondonStart>=InpLondonEnd || InpNewYorkStart<0 || InpNewYorkEnd>24 || InpNewYorkStart>=InpNewYorkEnd)
      return INIT_PARAMETERS_INCORRECT;
   if(MQLInfoInteger(MQL_TESTER))
   {
      Print("SessionGuard M5 TESTER: price-only test; economic calendar filter bypassed (historical calendar unavailable).");
      PrintFormat("SessionGuard M5 TESTER: using configured broker UTC offset %.2f hours; automatic live UTC is not used.",InpServerUTCOffsetHours);
   }
   if(!signals.Init()) return INIT_FAILED;
   execution.Init(InpMagic,InpDeviationPoints); guard.Init(InpMagic);
   pending=false; lastBar=iTime(_Symbol,PERIOD_M5,0);
   if(!EventSetTimer(1)) return INIT_FAILED;
   Print("SessionGuard M5 initialized. Daily guards measure ACCOUNT equity; closures affect this EA's symbol/magic only.");
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   EventKillTimer(); signals.Release(); Comment("");
}
void OnTimer()
{
   datetime now=TimeCurrent(); Maintain(now); Display();
}
void OnTick()
{
   datetime now=TimeCurrent();
   if(!Maintain(now)) { Display(); return; }
   if(!guard.historyOK) { pending=false; g_status="Waiting for account history"; Display(); return; }
   if(execution.SymbolBusy()) { pending=false; g_status="Position/order on symbol: managing or waiting"; Display(); return; }
   if(guard.entries>=InpMaxEntries || (guard.lastLoss>0 && now-guard.lastLoss<InpLossCooldownMinutes*60))
   { pending=false; g_status="Entry cap or loss cooldown"; Display(); return; }
   if(news.Blocked(now,InpNewsWindowMinutes,InpNewsFilter))
   { pending=false; g_status="News window or unavailable calendar"; Display(); return; }
   datetime bar=iTime(_Symbol,PERIOD_M5,0);
   if(pending && now>=setup.expires) pending=false;
   if(bar>0 && bar!=lastBar)
   {
      lastBar=bar;
      ScalperSignal candidate;
      if(InSession(bar-PeriodSeconds(PERIOD_M5)) && signals.Build(candidate,InpATRBuffer,InpMaxCandleATR)) { setup=candidate; pending=true; }
   }
   g_status=pending?"Setup armed: waiting for breakout":"Waiting for M5 pullback";
   if(pending)
   {
      MqlTick q;
      if(SymbolInfoTick(_Symbol,q))
      {
         // Chart bars use Bid; use Bid for both breakout directions.
         if((setup.direction>0 && q.bid<=setup.stop) || (setup.direction<0 && q.ask>=setup.stop)) pending=false;
         else if(setup.direction*(q.bid-setup.trigger)>0)
         {
            // One execution attempt per setup; no duplicate orders on ambiguous replies.
            pending=false;
            if(!signals.TrendValid(setup.direction)) { g_status="Setup expired: trend changed"; Display(); return; }
            double remaining=MathMin(InpDailyMaxLoss+guard.pnl,InpDailyDrawdown-guard.drawdown);
            bool ok=execution.Enter(setup,InpRewardRisk,InpRiskMoney,InpRiskPercent,remaining,InpCommissionPerLot,InpMaxSpreadPips,InpMaxSpreadStopFraction,InpDeviationPoints);
            g_status=ok?"Trade opened":"Setup skipped: execution/risk filters";
         }
      }
   }
   Display();
}
