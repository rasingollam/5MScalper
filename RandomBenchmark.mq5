#property copyright "SessionGuard Benchmark"
#property version "1.00"
#property strict
#property description "Random-entry null benchmark. Same sessions, risk, exits and execution as SessionGuardM5, but setups are random: every eligible session M5 bar generates a random-direction signal with probability InpRandomSetupProb. Used to quantify how much edge the price signal adds over chance."

input group "Identity and risk (account deposit currency)"
input ulong InpMagic=5090999;
input double InpRiskMoney=20.0;
input double InpRiskPercent=0.25;
input double InpDailyMaxLoss=100.0;
input double InpDailyTarget=150.0;
input double InpDailyDrawdown=75.0;
input int InpMaxEntries=6;
input int InpLossCooldownMinutes=15;
input group "Sessions (local city hours, end exclusive)"
input bool InpEnableLondon=true;
input bool InpEnableNewYork=true;
input int InpLondonStart=8;
input int InpLondonEnd=10;
input int InpNewYorkStart=8;
input int InpNewYorkEnd=10;
input bool InpCloseAtSessionEnd=true;
input bool InpAutoServerUTC=true;
input double InpServerUTCOffsetHours=0.0;
input group "Signal and execution"
input double InpRandomSetupProb=0.09;
input int InpRandomSeed=0;
input double InpRewardRisk=1.5;
input double InpEarlyTargetR=0.0;
input double InpATRBuffer=0.2;
input double InpMaxSpreadPips=1.0;
input double InpMaxSpreadStopFraction=0.15;
input double InpCommissionPerLot=7.0;
input int InpDeviationPoints=10;
input bool InpTrailing=true;

#include "helpers/SessionClock.mqh"
#include "helpers/NewsFilter.mqh"
#include "helpers/SignalEngine.mqh"
#include "helpers/DailyGuard.mqh"
#include "helpers/Execution.mqh"

CNewsFilter news;
CDailyGuard guard;
CScalperExecution execution;
ScalperSignal setup;
datetime lastBar=0;
bool pending=false;
string g_status="Starting";
int g_setups=0,g_attempts=0,g_opened=0;
datetime g_nextEntryCheck=0;
int g_atr=INVALID_HANDLE;

datetime UTCNow(datetime server)
{
   if(InpAutoServerUTC && !MQLInfoInteger(MQL_TESTER)) return TimeGMT();
   return server-(int)MathRound(InpServerUTCOffsetHours*3600);
}
bool InSession(datetime now)
{
   return SessionOpen(UTCNow(now),InpEnableLondon?InpLondonStart:0,InpEnableLondon?InpLondonEnd:0,InpEnableNewYork?InpNewYorkStart:0,InpEnableNewYork?InpNewYorkEnd:0);
}
void Display()
{
   Comment("Random Benchmark | ",_Symbol,"\n",g_status,
           (InpEarlyTargetR>0?StringFormat("\nTake profit: %.2fR (early target, trailing off)",InpEarlyTargetR):StringFormat("\nTake profit: %.2fR",InpRewardRisk)),
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
      else if(InpTrailing && InpEarlyTargetR<=0) execution.Trail(now,InpRewardRisk,InpCommissionPerLot);
      return false;
   }
   if(InpTrailing && InpEarlyTargetR<=0) execution.Trail(now,InpRewardRisk,InpCommissionPerLot);
   return true;
}
bool BuildRandom(ScalperSignal &s)
{
   MqlRates r[]; ArraySetAsSeries(r,true);
   int count=8;
   if(CopyRates(_Symbol,PERIOD_M5,0,count,r)!=count) return false;
   double b[1]; if(CopyBuffer(g_atr,0,1,1,b)!=1) return false;
   double a=b[0];
   if(a==EMPTY_VALUE || a<=0) return false;
   s.direction=(MathRand()%2)==0?1:-1;
   s.expires=r[0].time+PeriodSeconds(PERIOD_M5);
   double swing=s.direction>0?r[0].low:r[0].high;
   for(int i=1;i<=2;i++) swing=s.direction>0?MathMin(swing,r[i].low):MathMax(swing,r[i].high);
   s.stop=swing-s.direction*InpATRBuffer*a;
   MqlTick q; if(!SymbolInfoTick(_Symbol,q)) return false;
   s.trigger=s.direction>0?q.bid-0.00001:q.ask+0.00001;
   s.barrier=0;
   return true;
}
int OnInit()
{
   if(InpRandomSetupProb<=0 || InpRandomSetupProb>1 || InpRewardRisk<1 || InpEarlyTargetR<0 || InpEarlyTargetR>10 || InpRiskMoney<=0 || InpRiskPercent<=0 || InpRiskPercent>100 || InpDailyMaxLoss<=0 || InpDailyTarget<=0 || InpDailyDrawdown<=0 || InpMaxEntries<1 || InpLossCooldownMinutes<0 || InpATRBuffer<0 || InpMaxSpreadPips<=0 || InpMaxSpreadStopFraction<=0 || InpMaxSpreadStopFraction>1 || InpCommissionPerLot<0 || InpDeviationPoints<0 || InpServerUTCOffsetHours<-14 || InpServerUTCOffsetHours>14 || InpLondonStart<0 || InpLondonEnd>24 || InpLondonStart>=InpLondonEnd || InpNewYorkStart<0 || InpNewYorkEnd>24 || InpNewYorkStart>=InpNewYorkEnd)
      return INIT_PARAMETERS_INCORRECT;
   if(InpRandomSeed==0) MathSrand((uint)TimeCurrent()); else MathSrand((uint)InpRandomSeed);
   g_atr=iATR(_Symbol,PERIOD_M5,14);
   if(g_atr==INVALID_HANDLE) return INIT_FAILED;
   if(MQLInfoInteger(MQL_TESTER))
   {
      Print("Random Benchmark TESTER: price-only test; economic calendar filter bypassed.");
      PrintFormat("Random Benchmark TESTER: configured broker UTC offset %.2f h; seed %I64u",InpServerUTCOffsetHours,(ulong)InpRandomSeed);
   }
   execution.Init(InpMagic,InpDeviationPoints); guard.Init(InpMagic);
   pending=false; lastBar=iTime(_Symbol,PERIOD_M5,0);
   if(!EventSetTimer(1)) return INIT_FAILED;
   Print("Random Benchmark initialized. Random-direction setups with same risk/exit mechanics.");
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   PrintFormat("Random Benchmark summary: setups=%d, entry evaluations=%d, opened=%d",g_setups,g_attempts,g_opened);
   EventKillTimer(); Comment("");
   if(g_atr!=INVALID_HANDLE) IndicatorRelease(g_atr);
   g_atr=INVALID_HANDLE;
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
   if(news.Blocked(now,15,false))
   { pending=false; g_status="News window or unavailable calendar"; Display(); return; }
   datetime bar=iTime(_Symbol,PERIOD_M5,0);
   if(pending && now>=setup.expires) pending=false;
   if(bar>0 && bar!=lastBar)
   {
      lastBar=bar;
      if((!pending) && MathRand()/32767.0<InpRandomSetupProb && BuildRandom(setup))
      {
         pending=true; g_setups++; g_nextEntryCheck=0; g_status="Random setup: waiting for valid entry";
      }
   }
   if(pending)
   {
      MqlTick q;
      if(SymbolInfoTick(_Symbol,q))
      {
         // Chart bars use Bid; use Bid for both breakout directions.
         if((setup.direction>0 && q.bid<=setup.stop) || (setup.direction<0 && q.ask>=setup.stop)) pending=false;
         else if(now>=g_nextEntryCheck && setup.direction*(q.bid-setup.trigger)>0)
         {
            pending=false;
            double remaining=MathMin(InpDailyMaxLoss+guard.pnl,InpDailyDrawdown-guard.drawdown);
            g_attempts++;
            double targetR=InpEarlyTargetR>0?InpEarlyTargetR:InpRewardRisk;
            bool ok=execution.Enter(setup,targetR,InpRiskMoney,InpRiskPercent,remaining,InpCommissionPerLot,InpMaxSpreadPips,InpMaxSpreadStopFraction,InpDeviationPoints);
            if(ok) g_opened++;
            if(!ok && execution.retryable) { pending=true; g_nextEntryCheck=now+30; }
            g_status=ok?"Trade opened":"Setup skipped: "+execution.lastReason;
         }
      }
   }
   Display();
}