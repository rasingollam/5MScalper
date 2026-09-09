#property copyright "H1DonchianBreakout"
#property version "1.0"
#property strict
#property description "H1 Donchian channel breakout momentum. On the close of each H1 bar, a break of the prior N-bar high/low arms a pending order for the breakout direction. Entry fills on the first tick beyond the channel (market order through the CScalperExecution scaffold), initial stop is a fixed ATR multiple, and exit is a chandelier trail (a set multiple of H1 ATR below the highest high / above the lowest low since entry) ratcheted on each new H1 bar; all positions are flattened at the close of the last enabled session. Reuses the flat $200 bankroll, 15% risk and $7/lot cost model."

input group "Identity and risk (account deposit currency)"
input ulong InpMagic=5090777;
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
input int InpLondonEnd=17;
input int InpNewYorkStart=8;
input int InpNewYorkEnd=16;
input bool InpCloseAtSessionEnd=true;
input bool InpAutoServerUTC=true;
input double InpServerUTCOffsetHours=0.0;
input group "Signal and risk geometry"
input int InpChannelN=20;
input int InpStopATR=150;
input int InpTrailATR=200;
input double InpRewardRisk=6.0;
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
input double InpMaxSpreadPips=1.0;
input double InpMaxSpreadStopFraction=0.15;
input double InpCommissionPerLot=7.0;
input int InpDeviationPoints=10;

#include "helpers/SessionClock.mqh"
#include "helpers/NewsFilter.mqh"
#include "helpers/SignalEngine.mqh"
#include "helpers/DailyGuard.mqh"
#include "helpers/Execution.mqh"
#include <Trade/Trade.mqh>

CNewsFilter news;
CDailyGuard guard;
CScalperExecution execution;
CTrade trail;
ScalperSignal setup;
datetime lastM5Bar=0,lastH1Bar=0;
datetime h1SignalTime=0;
int g_h1atr=INVALID_HANDLE;
int g_entries=0,g_attempts=0,g_opened=0;
string g_status="Starting";

void InitTrail()
{
   trail.SetExpertMagicNumber(InpMagic);
   trail.SetDeviationInPoints(InpDeviationPoints);
   trail.SetTypeFillingBySymbol(_Symbol);
   trail.SetAsyncMode(false);
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
bool H1ChannelBreakout(bool &buyOut,bool &sellOut,double &triggerOut)
{
   int n=InpChannelN;
   MqlRates r[]; ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol,PERIOD_H1,1,n+1,r)!=n+1) return false;
   double hi=r[1].high,lo=r[1].low;
   for(int i=2;i<=n;i++){ hi=MathMax(hi,r[i].high); lo=MathMin(lo,r[i].low); }
   buyOut=r[0].close>hi;
   sellOut=r[0].close<lo;
   triggerOut=buyOut?hi:lo;
   return true;
}
double H1ATR()
{
   double a[1];
   if(CopyBuffer(g_h1atr,0,1,1,a)!=1 || a[0]<=0) return 0;
   return a[0];
}
void ChandelierTrailRatchets()
{
   if(g_h1atr==INVALID_HANDLE) return;
   double atr=H1ATR();
   if(atr<=0) return;
   double tick=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double gap=MathMax(SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL),SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL))+1;
   gap=gap*tick;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i); if(ticket==0 || !execution.OwnSelected()) continue;
      int dir=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?1:-1;
      double sl=PositionGetDouble(POSITION_SL),tp=PositionGetDouble(POSITION_TP);
      datetime openTime=(datetime)PositionGetInteger(POSITION_TIME);
      MqlRates hs[]; ArraySetAsSeries(hs,true);
      if(CopyRates(_Symbol,PERIOD_H1,1,2048,hs)<=0) continue;
      double peak=dir>0?hs[0].high:hs[0].low;
      bool after=false;
      for(int j=0;j<ArraySize(hs);j++)
      {
         if(hs[j].time>=openTime) after=true;
         if(after) peak=dir>0?MathMax(peak,hs[j].high):MathMin(peak,hs[j].low);
      }
      if(!after) continue;
      double stop=dir>0?peak-InpTrailATR/100.0*atr:peak+InpTrailATR/100.0*atr;
      MqlTick q; SymbolInfoTick(_Symbol,q);
      double cur=dir>0?q.bid:q.ask;
      if(dir>0 && stop<=sl+tick) continue;
      if(dir<0 && stop>=sl-tick) continue;
      if(dir*(cur-stop)<gap) continue;
      trail.PositionModify(ticket,Price(dir>0?stop:stop,dir<0),tp);
   }
}
double Price(double price,bool up)
{
   double t=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   return NormalizeDouble((up?MathCeil(price/t):MathFloor(price/t))*t,_Digits);
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
   if(locked)
   {
      g_status="Daily limit: locked"; execution.CloseAll(now); return false;
   }
   if(!InSession(now))
   {
      g_status="Outside trading sessions";
      if(InpCloseAtSessionEnd) execution.CloseAll(now);
      else ChandelierTrailRatchets();
      return false;
   }
   return true;
}
void Display()
{
   Comment("H1 Donchian | ",_Symbol,"\n",g_status,
           StringFormat("\nChannel %dH | Stop %.2f ATR | Trail %.2f ATR | TP %.1fR",InpChannelN,InpStopATR/100.0,InpTrailATR/100.0,InpRewardRisk),
           (MQLInfoInteger(MQL_TESTER)?"\nTESTER: price-only, news bypassed; manual broker UTC offset":""),
           "\nDaily account equity P/L: ",DoubleToString(guard.pnl,2)," ",AccountInfoString(ACCOUNT_CURRENCY),
           " | Entries: ",guard.entries,"/",InpMaxEntries);
}
int OnInit()
{
   if(InpChannelN<2 || InpChannelN>200 || InpStopATR<10 || InpStopATR>1000 || InpTrailATR<10 || InpTrailATR>1000 || InpRewardRisk<0 || InpRewardRisk>20 || InpRiskMoney<=0 || InpRiskPercent<=0 || InpRiskPercent>100 || InpDailyMaxLoss<=0 || InpDailyTarget<=0 || InpDailyDrawdown<=0 || InpMaxEntries<1 || InpLossCooldownMinutes<0 || InpMaxSpreadPips<=0 || InpMaxSpreadStopFraction<=0 || InpMaxSpreadStopFraction>1 || InpCommissionPerLot<0 || InpDeviationPoints<0 || InpServerUTCOffsetHours<-14 || InpServerUTCOffsetHours>14 || InpLondonStart<0 || InpLondonEnd>24 || InpLondonStart>=InpLondonEnd || InpNewYorkStart<0 || InpNewYorkEnd>24 || InpNewYorkStart>=InpNewYorkEnd || InpBlockServerHourFrom<-1 || InpBlockServerHourFrom>23 || (InpBlockServerHourTo<-1) || InpBlockServerHourTo>24 || InpBlockServerHourFrom2<-1 || InpBlockServerHourFrom2>23 || (InpBlockServerHourTo2<-1) || InpBlockServerHourTo2>24)
      return INIT_PARAMETERS_INCORRECT;
   g_h1atr=iATR(_Symbol,PERIOD_H1,14);
   if(g_h1atr==INVALID_HANDLE) return INIT_FAILED;
   InitTrail();
   if(MQLInfoInteger(MQL_TESTER))
   {
      Print("H1 Donchian TESTER: price-only test; economic calendar filter bypassed.");
      PrintFormat("H1 Donchian TESTER: configured broker UTC offset %.2f h",InpServerUTCOffsetHours);
   }
   execution.Init(InpMagic,InpDeviationPoints); guard.Init(InpMagic);
   lastM5Bar=iTime(_Symbol,PERIOD_M5,0); lastH1Bar=iTime(_Symbol,PERIOD_H1,0);
   if(!EventSetTimer(1)) return INIT_FAILED;
   Print("H1 Donchian initialized.");
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   PrintFormat("H1 Donchian summary: entries=%d, entry evaluations=%d, opened=%d",g_entries,g_attempts,g_opened);
   EventKillTimer(); Comment("");
   if(g_h1atr!=INVALID_HANDLE) IndicatorRelease(g_h1atr);
   g_h1atr=INVALID_HANDLE;
}
void OnTimer()
{
   datetime now=TimeCurrent();
   if(!Maintain(now)) { Display(); return; }
   datetime h1=iTime(_Symbol,PERIOD_H1,0);
   if(h1!=lastH1Bar)
   {
      lastH1Bar=h1;
      ChandelierTrailRatchets();
      bool b=false,s=false; double trg=0;
      if(!H1ChannelBreakout(b,s,trg)) return;
      MqlRates r[]; ArraySetAsSeries(r,true);
      if(CopyRates(_Symbol,PERIOD_H1,1,1,r)!=1) return;
      MqlDateTime t; TimeToStruct(r[0].time,t);
      bool allowed=WeekdayOk(r[0].time) && !ServerHourBlocked(r[0].time) && InSession(now);
      if(allowed)
      {
         double atr=H1ATR();
         if(atr<=0) return;
         int dir=0;
         if(b && !InpLongOnly) dir=1;
         else if(s && !InpLongOnly) dir=-1;
         else if(b) dir=1;
         if(dir!=0)
         {
            setup.direction=dir;
            setup.trigger=trg;
            setup.stop=dir>0?r[0].close-InpStopATR/100.0*atr:r[0].close+InpStopATR/100.0*atr;
            setup.barrier=0;
            setup.expires=r[0].time+3*3600;
            h1SignalTime=r[0].time;
            g_entries++;
         }
      }
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
   if(h1SignalTime>0 && now>=setup.expires) h1SignalTime=0;
   if(h1SignalTime>0)
   {
      MqlTick q;
      if(SymbolInfoTick(_Symbol,q))
      {
         bool cross=setup.direction>0?(q.bid>setup.trigger):(q.ask<setup.trigger);
         if(cross)
         {
            h1SignalTime=0;
            double remaining=MathMin(InpDailyMaxLoss+guard.pnl,InpDailyDrawdown-guard.drawdown);
            g_attempts++;
            bool ok=execution.Enter(setup,InpRewardRisk,InpRiskMoney,InpRiskPercent,remaining,InpCommissionPerLot,InpMaxSpreadPips,InpMaxSpreadStopFraction,InpDeviationPoints);
            if(ok) g_opened++;
            if(!ok && execution.retryable) { h1SignalTime=now; }
            g_status=ok?"Trade opened":"Setup skipped: "+execution.lastReason;
         }
      }
   }
   Display();
}