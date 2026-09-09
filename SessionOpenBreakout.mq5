#property copyright "SessionOpenBreakout"
#property version "1.00"
#property strict
#property description "London/NY opening-range breakout momentum hypothesis. The first InpORBars M5 bars of a session window define the opening range; a later close through the range in the breakout direction triggers a momentum entry with optional H1 trend alignment. Null-hypothesis testable against random-entry benchmark (same sessions/risk/exits)."

input group "Identity and risk (account deposit currency)"
input ulong InpMagic=5090777;
input double InpRiskMoney=2.0;
input double InpRiskPercent=1.0;
input double InpDailyMaxLoss=10.0;
input double InpDailyTarget=15.0;
input double InpDailyDrawdown=10.0;
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
input int InpORBars=3;
input bool InpH1Bias=true;
input bool InpLongOnly=false;
input bool InpTradeMon=true;
input bool InpTradeTue=true;
input bool InpTradeWed=true;
input bool InpTradeThu=true;
input bool InpTradeFri=true;
input int InpBlockServerHourFrom=-1;
input int InpBlockServerHourTo=-1;
input int InpBlockServerHourFrom2=-1;
input int InpBlockServerHourTo2=-1;
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
int g_h1ema=INVALID_HANDLE;

bool opening=false;
int openingBars=0;
double orHigh=0,orLow=0;

double UTCNow(datetime server)
{
   if(InpAutoServerUTC && !MQLInfoInteger(MQL_TESTER)) return TimeGMT();
   return server-(int)MathRound(InpServerUTCOffsetHours*3600);
}
bool InSession(datetime now)
{
   return SessionOpen(UTCNow(now),InpEnableLondon?InpLondonStart:0,InpEnableLondon?InpLondonEnd:0,InpEnableNewYork?InpNewYorkStart:0,InpEnableNewYork?InpNewYorkEnd:0);
}
bool H1BiasOk(int dir)
{
   double b[1],c[1];
   if(CopyBuffer(g_h1ema,0,1,1,b)!=1 || CopyClose(_Symbol,PERIOD_H1,1,1,c)!=1) return false;
   return dir*(c[0]-b[0])>0;
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
void Display()
{
   Comment("OR Breakout | ",_Symbol,"\n",g_status,
           (InpEarlyTargetR>0?StringFormat("\nTake profit: %.2fR (early target, trailing off)",InpEarlyTargetR):StringFormat("\nTake profit: %.2fR",InpRewardRisk)),
           (MQLInfoInteger(MQL_TESTER)?"\nTESTER: price-only, news bypassed; manual broker UTC offset":""),
           "\nOpening range: ",(opening?StringFormat("%d/%d bars: %.5f..%.5f",openingBars,InpORBars,orLow,orHigh):"n/a"),
           "\nDaily account equity P/L: ",DoubleToString(guard.pnl,2)," ",AccountInfoString(ACCOUNT_CURRENCY),
           " | Entries: ",guard.entries,"/",InpMaxEntries);
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
      pending=false; opening=false; orHigh=orLow=0; openingBars=0; g_status="Outside trading sessions";
      if(InpCloseAtSessionEnd) execution.CloseAll(now);
      else if(InpTrailing && InpEarlyTargetR<=0) execution.Trail(now,InpRewardRisk,InpCommissionPerLot);
      return false;
   }
   if(InpTrailing && InpEarlyTargetR<=0) execution.Trail(now,InpRewardRisk,InpCommissionPerLot);
   return true;
}
int OnInit()
{
   if(InpORBars<1 || InpORBars>24 || InpRewardRisk<1 || InpEarlyTargetR<0 || InpEarlyTargetR>10 || InpRiskMoney<=0 || InpRiskPercent<=0 || InpRiskPercent>100 || InpDailyMaxLoss<=0 || InpDailyTarget<=0 || InpDailyDrawdown<=0 || InpMaxEntries<1 || InpLossCooldownMinutes<0 || InpATRBuffer<0 || InpMaxSpreadPips<=0 || InpMaxSpreadStopFraction<=0 || InpMaxSpreadStopFraction>1 || InpCommissionPerLot<0 || InpDeviationPoints<0 || InpServerUTCOffsetHours<-14 || InpServerUTCOffsetHours>14 || InpLondonStart<0 || InpLondonEnd>24 || InpLondonStart>=InpLondonEnd || InpNewYorkStart<0 || InpNewYorkEnd>24 || InpNewYorkStart>=InpNewYorkEnd || InpBlockServerHourFrom<-1 || InpBlockServerHourFrom>23 || (InpBlockServerHourTo<-1) || InpBlockServerHourTo>24 || InpBlockServerHourFrom2<-1 || InpBlockServerHourFrom2>23 || (InpBlockServerHourTo2<-1) || InpBlockServerHourTo2>24)
      return INIT_PARAMETERS_INCORRECT;
   g_h1ema=iMA(_Symbol,PERIOD_H1,50,0,MODE_EMA,PRICE_CLOSE);
   if(g_h1ema==INVALID_HANDLE) return INIT_FAILED;
   if(MQLInfoInteger(MQL_TESTER))
   {
      Print("OR Breakout TESTER: price-only test; economic calendar filter bypassed.");
      PrintFormat("OR Breakout TESTER: configured broker UTC offset %.2f h",InpServerUTCOffsetHours);
   }
   execution.Init(InpMagic,InpDeviationPoints); guard.Init(InpMagic);
   pending=false; lastBar=iTime(_Symbol,PERIOD_M5,0);
   if(!EventSetTimer(1)) return INIT_FAILED;
   Print("OR Breakout initialized. Opening-range momentum hypothesis.");
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   PrintFormat("OR Breakout summary: setups=%d, entry evaluations=%d, opened=%d",g_setups,g_attempts,g_opened);
   EventKillTimer(); Comment("");
   if(g_h1ema!=INVALID_HANDLE) IndicatorRelease(g_h1ema);
   g_h1ema=INVALID_HANDLE;
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
      datetime prev=lastBar; lastBar=bar;
      MqlRates r[]; ArraySetAsSeries(r,true);
      if(CopyRates(_Symbol,PERIOD_M5,1,2,r)!=2) { Display(); return; }
      bool prevIn=InSession(prev),curIn=InSession(bar);
      if(curIn && !prevIn) { opening=false; openingBars=0; orHigh=orLow=0; }
      if(curIn)
      {
         if(!opening)
         {
            opening=true; openingBars=1; orHigh=r[0].high; orLow=r[0].low;
         }
         else if(openingBars<InpORBars)
         {
            orHigh=MathMax(orHigh,r[0].high); orLow=MathMin(orLow,r[0].low);
            openingBars++;
         }
         if(openingBars>=InpORBars)
         {
            // Breakout on a close beyond the finalized range.
            if((!pending) && r[0].close>orHigh)
            {
               setup.direction=1; setup.trigger=orHigh; setup.stop=orLow;
               setup.barrier=0; setup.expires=bar+PeriodSeconds(PERIOD_M5)*36;
               if(InpH1Bias && !H1BiasOk(setup.direction)) { g_status="Range break but opposing H1"; }
               else if(!WeekdayOk(bar)) { g_status="Range break but filtered weekday"; }
               else if(ServerHourBlocked(bar)) { g_status="Range break but blocked server hour"; }
               else { pending=true; g_setups++; g_nextEntryCheck=0; }
            }
            else if((!pending) && r[0].close<orLow)
            {
               setup.direction=-1; setup.trigger=orLow; setup.stop=orHigh;
               setup.barrier=0; setup.expires=bar+PeriodSeconds(PERIOD_M5)*36;
               if(InpLongOnly) { g_status="Range break but long-only"; }
               else if(InpH1Bias && !H1BiasOk(setup.direction)) { g_status="Range break but opposing H1"; }
               else if(!WeekdayOk(bar)) { g_status="Range break but filtered weekday"; }
               else if(ServerHourBlocked(bar)) { g_status="Range break but blocked server hour"; }
               else { pending=true; g_setups++; g_nextEntryCheck=0; }
            }
         }
      }
   }
   g_status=pending?"Breakout ready: waiting for valid entry":"Waiting for opening-range break";
   if(pending)
   {
      MqlTick q;
      if(SymbolInfoTick(_Symbol,q))
      {
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