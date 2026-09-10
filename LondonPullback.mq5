#property copyright "LondonPullback"
#property version "1.0"
#property strict
#property description "London open session-momentum pullback. The opening range (first InpORBars closed M5 bars of the London session) defines an orHigh/orLow; the session momentum direction is the last breakout of that range. A pullback entry is accepted only when the M5 reclaim signal from the SignalEngine (dip below the near-term swing then a close back through it) is aligned with the momentum direction, and only within the first InpEntryMinutes of the session. Positions carry an initial ATR-based stop and a fixed R target, are trailed to a swing stop, and flattened at London close on session end. Reuses the flat $200 bankroll, capped-risk and $7/lot cost model."

input group "Identity and risk (account deposit currency)"
input ulong InpMagic=5090880;
input double InpRiskMoney=51.0;
input double InpRiskPercent=15.0;
input double InpDailyMaxLoss=120.0;
input double InpDailyTarget=120.0;
input double InpDailyDrawdown=120.0;
input int InpMaxEntries=6;
input int InpLossCooldownMinutes=15;
input group "Session (local city hours, end exclusive)"
input int InpLondonStart=8;
input int InpLondonEnd=17;
input int InpEntryMinutes=180;
input bool InpCloseAtSessionEnd=true;
input bool InpAutoServerUTC=true;
input double InpServerUTCOffsetHours=0.0;
input group "Opening range and momentum"
input int InpORBars=6;
input double InpBufferATR=1.5;
input int InpLookback=6;
input double InpRewardRisk=3.0;
input bool InpBarrierBlock=true;
input bool InpAllowLong=true;
input bool InpAllowShort=true;
input group "Signal-engine filters"
input bool InpCandleFilter=true;
input bool InpTrendFilter=true;
input bool InpStrongClose=true;
input bool InpTrendVeto=true;
input bool InpH1Bias=true;
input bool InpTightReclaim=false;
input bool InpTradeMon=true;
input bool InpTradeTue=true;
input bool InpTradeWed=true;
input bool InpTradeThu=true;
input bool InpTradeFri=true;
input int InpBlockServerHourFrom=-1;
input int InpBlockServerHourTo=-1;
input int InpBlockServerHourFrom2=-1;
input int InpBlockServerHourTo2=-1;
input double InpMaxSpreadPips=1.0;
input double InpMaxSpreadStopFraction=0.15;
input double InpCommissionPerLot=7.0;
input int InpDeviationPoints=10;

#include "helpers/SessionClock.mqh"
#include "helpers/NewsFilter.mqh"
#include "helpers/SignalEngine.mqh"
#include "helpers/DailyGuard.mqh"
#include "helpers/Execution.mqh"

CNewsFilter news;
CDailyGuard guard;
CScalperExecution execution;
CSignalEngine engine;
ScalperSignal setup;
datetime lastM5Bar=0,lastBarTime=0;
datetime g_sessionStart=0,lastClosed=0;
int g_orBars=0;
double g_orHigh=0,g_orLow=0;
int g_dir=0;
int g_entries=0,g_attempts=0,g_opened=0;
string g_status="Starting";
bool g_armed=false;

double UTCNow(datetime server)
{
   if(InpAutoServerUTC && !MQLInfoInteger(MQL_TESTER)) return TimeGMT();
   return server-(int)MathRound(InpServerUTCOffsetHours*3600);
}
bool InLondon(datetime now)
{
   return SessionOpen(UTCNow(now),InpLondonStart,InpLondonEnd,0,0);
}
bool WeekdayOk(datetime ts)
{
   MqlDateTime t; TimeToStruct(ts,t);
   switch(t.day_of_week)
   {
      case 0: return true;
      case 1: return InpTradeMon;
      case 2: return InpTradeTue;
      case 3: return InpTradeWed;
      case 4: return InpTradeThu;
      case 5: return InpTradeFri;
   }
   return true;
}
bool ServerHourBlocked(datetime ts)
{
   if(ServerHourBlockedRange(ts,InpBlockServerHourFrom,InpBlockServerHourTo)) return true;
   return ServerHourBlockedRange(ts,InpBlockServerHourFrom2,InpBlockServerHourTo2);
}
bool ServerHourBlockedRange(datetime ts,int fromHour,int toHour)
{
   if(fromHour<0 || toHour<=fromHour) return false;
   MqlDateTime t; TimeToStruct(ts,t);
   int h=t.hour;
   if(fromHour<toHour) return h>=fromHour && h<toHour;
   return h>=fromHour || h<toHour;
}
bool Maintain(datetime now)
{
   bool locked=guard.Update(now,InpMagic,InpDailyMaxLoss,InpDailyTarget,InpDailyDrawdown);
   if(locked){ g_status="Daily limit: locked"; execution.CloseAll(now); return false; }
   if(!InLondon(now))
   {
      g_status="Outside London session";
      if(InpCloseAtSessionEnd) execution.CloseAll(now);
      return false;
   }
   return true;
}
void OnNewBar(datetime bar)
{
   bool start=false;
   MqlRates p[]; ArraySetAsSeries(p,true);
   if(CopyRates(_Symbol,PERIOD_M5,1,2,p)==2)
   {
      if(g_sessionStart==0) start=true;
      else if(InLondon(p[1].time)!=InLondon(p[0].time)) start=true;
      else if(ServerMidnight(p[0].time)!=ServerMidnight(p[1].time)) start=true;
   }
   else return;
   if(start)
   {
      g_sessionStart=p[0].time; g_orBars=0; g_orHigh=0; g_orLow=0; g_dir=0; g_armed=false;
   }
   if(!InLondon(p[0].time) || p[0].time>=g_sessionStart+InpEntryMinutes*60) return;
   if(g_orBars<InpORBars)
   {
      if(g_orBars==0){ g_orHigh=p[0].high; g_orLow=p[0].low; }
      else { g_orHigh=MathMax(g_orHigh,p[0].high); g_orLow=MathMin(g_orLow,p[0].low); }
      g_orBars++;
      return;
   }
   if(p[0].close>g_orHigh) g_dir=1;
   else if(p[0].close<g_orLow) g_dir=-1;
   if(g_dir==0) return;
   if((g_dir>0 && !InpAllowLong) || (g_dir<0 && !InpAllowShort)) return;
   if(!WeekdayOk(p[0].time) || ServerHourBlocked(p[0].time)) return;
   ScalperSignal s;
   if(!engine.Build(s,InpBufferATR,2.0,InpLookback,InpCandleFilter,InpTrendFilter,InpStrongClose,InpTrendVeto,InpH1Bias,InpTightReclaim)) return;
   if(s.direction!=g_dir) return;
   if(!InpBarrierBlock) s.barrier=0;
   setup=s;
   g_armed=true; g_entries++;
}
void Display()
{
   string orinfo=g_orBars<InpORBars?StringFormat("building OR %d/%d",g_orBars,InpORBars)
                                  :StringFormat("OR [%s][%.5f..%.5f] dir=%s",TimeToString(g_sessionStart,TIME_DATE),g_orLow,g_orHigh,g_dir>0?"LON":g_dir<0?"SHT":"-");
   Comment("London Pullback | ",_Symbol,"\n",g_status," | ",orinfo,
           StringFormat("\nSignal: %s",g_armed?StringFormat("%s @ %.5f stop %.5f",setup.direction>0?"LON":"SHT",setup.trigger,setup.stop):"none"),
           (MQLInfoInteger(MQL_TESTER)?"\nTESTER: price-only, news bypassed; manual broker UTC offset":""),
           "\nDaily account equity P/L: ",DoubleToString(guard.pnl,2)," ",AccountInfoString(ACCOUNT_CURRENCY),
           " | Entries: ",guard.entries,"/",InpMaxEntries);
}
int OnInit()
{
   if(InpLondonStart<0 || InpLondonEnd>24 || InpLondonStart>=InpLondonEnd || InpEntryMinutes<0 || InpEntryMinutes>1440 || InpORBars<2 || InpORBars>24 || InpLookback<2 || InpLookback>60 || InpBufferATR<=0 || InpBufferATR>5 || InpRewardRisk<=0 || InpRewardRisk>20 || InpRiskMoney<=0 || InpRiskPercent<=0 || InpRiskPercent>100 || InpDailyMaxLoss<=0 || InpDailyTarget<=0 || InpDailyDrawdown<=0 || InpMaxEntries<1 || InpLossCooldownMinutes<0 || InpMaxSpreadPips<=0 || InpMaxSpreadStopFraction<=0 || InpMaxSpreadStopFraction>1 || InpCommissionPerLot<0 || InpDeviationPoints<0 || InpServerUTCOffsetHours<-14 || InpServerUTCOffsetHours>14 || InpBlockServerHourFrom<-1 || InpBlockServerHourFrom>23 || (InpBlockServerHourTo<-1) || InpBlockServerHourTo>24 || InpBlockServerHourFrom2<-1 || InpBlockServerHourFrom2>23 || (InpBlockServerHourTo2<-1) || InpBlockServerHourTo2>24)
      return INIT_PARAMETERS_INCORRECT;
   if(!engine.Init()) return INIT_FAILED;
   execution.Init(InpMagic,InpDeviationPoints); guard.Init(InpMagic);
   lastM5Bar=iTime(_Symbol,PERIOD_M5,0); lastClosed=lastM5Bar;
   if(!EventSetTimer(1)) { engine.Release(); return INIT_FAILED; }
   if(MQLInfoInteger(MQL_TESTER))
      Print("London Pullback TESTER: price-only test; economic calendar filter bypassed.");
   Print("London Pullback initialized.");
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   PrintFormat("London Pullback summary: signals=%d, signal evaluations=%d, opened=%d",g_entries,g_attempts,g_opened);
   EventKillTimer(); Comment("");
   engine.Release();
}
void OnTimer()
{
   datetime now=TimeCurrent();
   if(!Maintain(now)) { Display(); return; }
   datetime m5=iTime(_Symbol,PERIOD_M5,0);
   if(m5!=lastM5Bar)
   {
      lastM5Bar=m5;
      OnNewBar(m5);
   }
   Display();
}
void OnTick()
{
   datetime now=TimeCurrent();
   if(!Maintain(now)) { Display(); return; }
   if(!guard.historyOK) { g_status="Waiting for account history"; Display(); return; }
   if(execution.SymbolBusy()) { g_status="Position/order on symbol: managing or waiting"; Display(); return; }
   if(guard.entries>=InpMaxEntries || (guard.lastLoss>0 && now-guard.lastLoss<InpLossCooldownMinutes*60))
   { g_status="Entry cap or loss cooldown"; Display(); return; }
   if(news.Blocked(now,15,false))
   { g_status="News window or unavailable calendar"; Display(); return; }
   if(now>=setup.expires) g_armed=false;
   if(g_armed)
   {
      MqlTick q;
      if(SymbolInfoTick(_Symbol,q))
      {
         bool cross=setup.direction>0?(q.bid>setup.trigger):(q.ask<setup.trigger);
         if(cross)
         {
            g_armed=false;
            double remaining=MathMin(InpDailyMaxLoss+guard.pnl,InpDailyDrawdown-guard.drawdown);
            g_attempts++;
            bool ok=execution.Enter(setup,InpRewardRisk,InpRiskMoney,InpRiskPercent,remaining,InpCommissionPerLot,InpMaxSpreadPips,InpMaxSpreadStopFraction,InpDeviationPoints);
            if(ok) g_opened++;
            if(!ok && execution.retryable) g_armed=true;
            g_status=ok?"Trade opened":"Setup skipped: "+execution.lastReason;
         }
      }
   }
   execution.Trail(now,InpRewardRisk,InpCommissionPerLot);
   Display();
}