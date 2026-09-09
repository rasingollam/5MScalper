#property copyright "SessionOpenBreakout"
#property version "2.00"
#property strict
#property description "Portfolio London/NY opening-range breakout momentum EA over a configurable list of pairs (validated on EURUSD+USDJPY). For each symbol the first InpORBars M5 bars of a session window define the opening range; a later close through the range in the breakout direction triggers a momentum entry with optional H1 trend alignment. Daily equity guards are account-wide across the whole portfolio. Configured for a flat $200 bankroll (profits withdrawn, non-compounding): 15% per-trade risk at 1:100 margin ceiling, 60% daily drawdown tolerance."

input group "Portfolio and identity"
input string InpSymbols="EURUSD,USDJPY";
input ulong InpMagic=5090778;
input double InpRiskMoney=51.0;
input double InpRiskPercent=15.0;
input double InpDailyMaxLoss=120.0;
input double InpDailyTarget=120.0;
input double InpDailyDrawdown=120.0;
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
input int InpORBars=6;
input bool InpH1Bias=true;
input bool InpLongOnly=true;
input bool InpTradeMon=true;
input bool InpTradeTue=true;
input bool InpTradeWed=true;
input bool InpTradeThu=true;
input bool InpTradeFri=true;
input int InpBlockServerHourFrom=13;
input int InpBlockServerHourTo=15;
input int InpBlockServerHourFrom2=8;
input int InpBlockServerHourTo2=9;
input double InpRewardRisk=1.3;
input double InpEarlyTargetR=0.0;
input double InpATRBuffer=0.2;
input double InpMaxSpreadPips=1.0;
input string InpSpreadPipsOverrides="USDJPY:2.0";
input double InpMaxSpreadStopFraction=0.15;
input double InpCommissionPerLot=7.0;
input int InpDeviationPoints=10;
input bool InpTrailing=false;

#include "helpers/SessionClock.mqh"
#include "helpers/NewsFilter.mqh"
#include "helpers/SignalEngine.mqh"
#include "helpers/DailyGuard.mqh"
#include "helpers/Execution.mqh"

struct PairState
{
   string symbol;
   int h1handle;
   datetime lastBar;
   bool opening, pending;
   int openingBars;
   double orHigh, orLow;
   ScalperSignal setup;
   datetime nextEntryCheck;
};

CNewsFilter news;
CDailyGuard guard;
CScalperExecution execution;
PairState pairs[];
int g_pairCount=0;
datetime g_lastScan=0;
string g_status="Starting";
int g_setups=0,g_attempts=0,g_opened=0;
string g_ovSym[];
double g_ovCap[];
int g_ovCount=0;

double SpreadCap(string symbol)
{
   for(int i=0;i<g_ovCount;i++) if(g_ovSym[i]==symbol) return g_ovCap[i];
   return InpMaxSpreadPips;
}

double UTCNow(datetime server)
{
   if(InpAutoServerUTC && !MQLInfoInteger(MQL_TESTER)) return TimeGMT();
   return server-(int)MathRound(InpServerUTCOffsetHours*3600);
}
bool InSession(datetime now)
{
   return SessionOpen(UTCNow(now),InpEnableLondon?InpLondonStart:0,InpEnableLondon?InpLondonEnd:0,InpEnableNewYork?InpNewYorkStart:0,InpEnableNewYork?InpNewYorkEnd:0);
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
bool ServerHourBlockedRange(datetime ts,int fromHour,int toHour)
{
   if(fromHour<0 || toHour<=fromHour) return false;
   MqlDateTime t; TimeToStruct(ts,t);
   int h=t.hour;
   if(fromHour<toHour) return h>=fromHour && h<toHour;
   return h>=fromHour || h<toHour;
}
bool ServerHourBlocked(datetime ts)
{
   if(ServerHourBlockedRange(ts,InpBlockServerHourFrom,InpBlockServerHourTo)) return true;
   return ServerHourBlockedRange(ts,InpBlockServerHourFrom2,InpBlockServerHourTo2);
}
bool H1BiasOk(PairState &p,int dir)
{
   double b[1],c[1];
   if(CopyBuffer(p.h1handle,0,1,1,b)!=1 || CopyClose(p.symbol,PERIOD_H1,1,1,c)!=1) return false;
   return dir*(c[0]-b[0])>0;
}
string BuildStatus()
{
   string status="";
   for(int i=0;i<g_pairCount;i++)
   {
      PairState p=pairs[i];
      string line=p.symbol;
      if(p.pending) line+=": pending";
      else if(!p.opening && InSession(TimeCurrent())) line+=": waiting";
      else if(p.opening) line+=StringFormat(": OR %d/%d %.5f..%.5f",p.openingBars,InpORBars,p.orLow,p.orHigh);
      else line+=": outside";
      status+=line+"\n";
   }
   return status;
}
void Display()
{
   Comment("OR Breakout Portfolio | ",_Symbol,"\n",g_status,"\n",
           (InpEarlyTargetR>0?StringFormat("Take profit: %.2fR (early target, trailing off)",InpEarlyTargetR):StringFormat("Take profit: %.2fR",InpRewardRisk)),
           (MQLInfoInteger(MQL_TESTER)?"\nTESTER: price-only, news bypassed; manual broker UTC offset":""),
           "\nPairs: ",g_pairCount," | Daily account equity P/L: ",DoubleToString(guard.pnl,2)," ",AccountInfoString(ACCOUNT_CURRENCY),
           " | Entries: ",guard.entries,"/",InpMaxEntries," | Setups/Opened: ",g_setups,"/",g_opened,"\n",
           BuildStatus());
}
bool Maintain(datetime now)
{
   bool locked=guard.Update(now,InpMagic,InpDailyMaxLoss,InpDailyTarget,InpDailyDrawdown);
   if(locked)
   {
      g_status="Daily limit: locked";
      for(int i=0;i<g_pairCount;i++) pairs[i].pending=false;
      execution.CloseAll(now); return false;
   }
   if(!InSession(now))
   {
      for(int i=0;i<g_pairCount;i++) { pairs[i].pending=false; pairs[i].opening=false; pairs[i].orHigh=pairs[i].orLow=0; pairs[i].openingBars=0; }
      g_status="Outside trading sessions";
      if(InpCloseAtSessionEnd) execution.CloseAll(now);
      else if(InpTrailing && InpEarlyTargetR<=0) execution.Trail(now,InpRewardRisk,InpCommissionPerLot);
      return false;
   }
   if(InpTrailing && InpEarlyTargetR<=0) execution.Trail(now,InpRewardRisk,InpCommissionPerLot);
   return true;
}
void ProcessState(PairState &p,int idx,datetime now)
{
   if(!guard.historyOK) { p.pending=false; g_status="Waiting for account history"; return; }
   if(execution.SymbolBusy(p.symbol)) { p.pending=false; g_status="Position/order on "+p.symbol+": managing or waiting"; return; }
   if(guard.entries>=InpMaxEntries || (guard.lastLoss>0 && now-guard.lastLoss<InpLossCooldownMinutes*60))
   { p.pending=false; g_status="Entry cap or loss cooldown"; return; }
   if(news.Blocked(now,15,false)) { p.pending=false; g_status="News window or unavailable calendar"; return; }
   datetime bar=iTime(p.symbol,PERIOD_M5,0);
   if(bar<=0)
   {
      if(now-g_lastScan>10 && MQLInfoInteger(MQL_TESTER)) PrintFormat("PORT: no M5 data for %s at %s",p.symbol,TimeToString(now,TIME_MINUTES));
      return;
   }
   if(p.pending && now>=p.setup.expires) p.pending=false;
   if(bar>0 && bar!=p.lastBar)
   {
      datetime prev=p.lastBar; p.lastBar=bar;
      MqlRates r[]; ArraySetAsSeries(r,true);
      if(CopyRates(p.symbol,PERIOD_M5,1,2,r)!=2) return;
      if(p.opening && !InSession(prev)) { p.opening=false; p.openingBars=0; p.orHigh=p.orLow=0; }
      if(InSession(bar))
      {
         if(!p.opening)
         {
            p.opening=true; p.openingBars=1; p.orHigh=r[0].high; p.orLow=r[0].low;
         }
         else if(p.openingBars<InpORBars)
         {
            p.orHigh=MathMax(p.orHigh,r[0].high); p.orLow=MathMin(p.orLow,r[0].low);
            p.openingBars++;
         }
if(p.openingBars>=InpORBars)
          {
             if(p.pending && now>=p.setup.expires) p.pending=false;
             if((!p.pending) && r[0].close>p.orHigh)
             {
                g_setups++;
                p.setup.direction=1; p.setup.trigger=p.orHigh; p.setup.stop=p.orLow;
               p.setup.barrier=0; p.setup.expires=bar+PeriodSeconds(PERIOD_M5)*36;
               if(InpH1Bias && !H1BiasOk(p,p.setup.direction)) { g_status=p.symbol+": range break but opposing H1"; }
               else if(!WeekdayOk(bar)) { g_status=p.symbol+": range break but filtered weekday"; }
               else if(ServerHourBlocked(bar)) { g_status=p.symbol+": range break but blocked server hour"; }
               else { p.pending=true; p.nextEntryCheck=0; }
            }
else if((!p.pending) && r[0].close<p.orLow)
             {
                g_setups++;
                p.setup.direction=-1; p.setup.trigger=p.orLow; p.setup.stop=p.orHigh;
               p.setup.barrier=0; p.setup.expires=bar+PeriodSeconds(PERIOD_M5)*36;
               if(InpLongOnly) { g_status=p.symbol+": range break but long-only"; }
               else if(InpH1Bias && !H1BiasOk(p,p.setup.direction)) { g_status=p.symbol+": range break but opposing H1"; }
               else if(!WeekdayOk(bar)) { g_status=p.symbol+": range break but filtered weekday"; }
               else if(ServerHourBlocked(bar)) { g_status=p.symbol+": range break but blocked server hour"; }
               else { p.pending=true; p.nextEntryCheck=0; }
            }
         }
      }
   }
   if(!p.pending) return;
   MqlTick q;
   if(SymbolInfoTick(p.symbol,q))
   {
      if((p.setup.direction>0 && q.bid<=p.setup.stop) || (p.setup.direction<0 && q.ask>=p.setup.stop)) p.pending=false;
      else if(now>=p.nextEntryCheck && p.setup.direction*(q.bid-p.setup.trigger)>0)
      {
         p.pending=false;
         double remaining=MathMin(InpDailyMaxLoss+guard.pnl,InpDailyDrawdown-guard.drawdown);
         g_attempts++;
         double targetR=InpEarlyTargetR>0?InpEarlyTargetR:InpRewardRisk;
         bool ok=execution.Enter(p.symbol,p.setup,targetR,InpRiskMoney,InpRiskPercent,remaining,InpCommissionPerLot,SpreadCap(p.symbol),InpMaxSpreadStopFraction,InpDeviationPoints);
         if(ok) g_opened++;
         if(!ok && execution.retryable) { p.pending=true; p.nextEntryCheck=now+30; }
         g_status=ok?"Trade opened on "+p.symbol:"Setup skipped on "+p.symbol+": "+execution.lastReason;
      }
   }
}
void ProcessPair(int idx,datetime now)
{
   PairState p=pairs[idx];
   ProcessState(p,idx,now);
   pairs[idx]=p;
}
int OnInit()
{
   if(InpSymbols=="" || InpORBars<1 || InpORBars>24 || InpRewardRisk<1 || InpEarlyTargetR<0 || InpEarlyTargetR>10 || InpRiskMoney<=0 || InpRiskPercent<=0 || InpRiskPercent>100 || InpDailyMaxLoss<=0 || InpDailyTarget<=0 || InpDailyDrawdown<=0 || InpMaxEntries<1 || InpLossCooldownMinutes<0 || InpATRBuffer<0 || InpMaxSpreadPips<=0 || InpMaxSpreadStopFraction<=0 || InpMaxSpreadStopFraction>1 || InpCommissionPerLot<0 || InpDeviationPoints<0 || InpServerUTCOffsetHours<-14 || InpServerUTCOffsetHours>14 || InpLondonStart<0 || InpLondonEnd>24 || InpLondonStart>=InpLondonEnd || InpNewYorkStart<0 || InpNewYorkEnd>24 || InpNewYorkStart>=InpNewYorkEnd || InpBlockServerHourFrom<-1 || InpBlockServerHourFrom>23 || (InpBlockServerHourTo<-1) || InpBlockServerHourTo>24 || InpBlockServerHourFrom2<-1 || InpBlockServerHourFrom2>23 || (InpBlockServerHourTo2<-1) || InpBlockServerHourTo2>24)
      return INIT_PARAMETERS_INCORRECT;
   string syms[];
   int cnt=StringSplit(InpSymbols,',',syms);
   string good[];
   for(int i=0;i<cnt;i++)
   {
      string s=syms[i];
      StringTrimLeft(s);
      StringTrimRight(s);
      if(s=="") continue;
      int n=ArraySize(good); ArrayResize(good,n+1); good[n]=s;
   }
   ArrayResize(pairs,ArraySize(good));
   g_pairCount=0;
   for(int i=0;i<ArraySize(good);i++)
   {
      PairState p;
      p.symbol=good[i];
      p.h1handle=INVALID_HANDLE;
      p.lastBar=0;
      p.opening=false; p.pending=false; p.openingBars=0;
      p.orHigh=p.orLow=0;
      p.setup.expires=0; p.nextEntryCheck=0;
      if(SymbolSelect(p.symbol,true))
         p.h1handle=iMA(p.symbol,PERIOD_H1,50,0,MODE_EMA,PRICE_CLOSE);
      if(p.h1handle==INVALID_HANDLE)
      {
         PrintFormat("PORT: indicator/data unavailable for %s - removing pair",p.symbol);
         continue;
      }
      PrintFormat("PORT: pair added: %s",p.symbol);
      pairs[g_pairCount]=p;
      g_pairCount++;
   }
   ArrayResize(pairs,g_pairCount);
   if(g_pairCount==0) return INIT_FAILED;
   if(MQLInfoInteger(MQL_TESTER))
   {
      Print("OR Breakout TESTER: price-only test; economic calendar filter bypassed.");
      PrintFormat("OR Breakout TESTER: configured broker UTC offset %.2f h",InpServerUTCOffsetHours);
   }
   execution.Init(InpMagic,InpDeviationPoints); guard.Init(InpMagic);
   g_lastScan=0;
   g_setups=0; g_attempts=0; g_opened=0;
   g_ovCount=0;
   if(InpSpreadPipsOverrides!="")
   {
      string ov[];
      int oc=StringSplit(InpSpreadPipsOverrides,',',ov);
      for(int i=0;i<oc;i++)
      {
         string s=ov[i]; StringTrimLeft(s); StringTrimRight(s);
         int pos=StringFind(s,":");
         if(pos<=0 || pos>=StringLen(s)-1) continue;
         string sym=StringSubstr(s,0,pos);
         string val=StringSubstr(s,pos+1);
         if(StringToDouble(val)<=0) continue;
         int n=ArraySize(g_ovSym); ArrayResize(g_ovSym,n+1); ArrayResize(g_ovCap,n+1);
         g_ovSym[n]=sym;
         StringTrimLeft(g_ovSym[n]);
         StringTrimRight(g_ovSym[n]);
         g_ovCap[n]=StringToDouble(val);
         g_ovCount=n+1;
      }
      if(g_ovCount>0) PrintFormat("PORT: spread overrides parsed (%d): %s",g_ovCount,InpSpreadPipsOverrides);
   }
   if(!EventSetTimer(1)) return INIT_FAILED;
   g_status="Initialized: "+string(g_pairCount)+" pair(s)";
   PrintFormat("PORT: portfolio initialized with %d pairs",g_pairCount);
   Display();
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   PrintFormat("PORT summary: pairs=%d, setups=%d, entry evaluations=%d, opened=%d",g_pairCount,g_setups,g_attempts,g_opened);
   EventKillTimer(); Comment("");
   for(int i=0;i<g_pairCount;i++) if(pairs[i].h1handle!=INVALID_HANDLE) IndicatorRelease(pairs[i].h1handle);
}
void OnTimer()
{
   datetime now=TimeCurrent();
   Maintain(now);
   if(now-g_lastScan<1) return;
   g_lastScan=now;
   for(int i=0;i<g_pairCount;i++) ProcessPair(i,now);
   g_status="Scanning portfolio...";
   Display();
}
void OnTick()
{
   datetime now=TimeCurrent();
   Maintain(now);
   for(int i=0;i<g_pairCount;i++)
   {
      if(pairs[i].symbol==_Symbol)
      {
         ProcessPair(i,now);
         break;
      }
   }
   Display();
}