#property copyright "RollingTrain"
#property version "1.0"
#property strict
#property description "Walk-forward London pullback. At each UTC month boundary the EA re-trains on the previous InpTrainDays of M5 history: a grid of opening-range/lookback/ATR-buffer/R-multiple/H1-bias combos is scored by hypothetical gross profit factor (same signal and stop/TP geometry as live, minimum trade and win-rate floors) and the highest-PF combo is traded for the coming month, then re-trained. The traded month is out-of-sample versus training. Reuses the flat $200 bankroll, capped-risk and $7/lot cost model."

input group "Identity and risk (account deposit currency)"
input ulong InpMagic=5090990;
input double InpRiskMoney=5.0;
input double InpRiskPercent=2.5;
input double InpDailyMaxLoss=120.0;
input double InpDailyTarget=120.0;
input double InpDailyDrawdown=120.0;
input int InpMaxEntries=6;
input int InpLossCooldownMinutes=15;
input group "Session (local city hours, end exclusive)"
input int InpLondonStart=8;
input int InpLondonEnd=17;
input int InpEntryMinutes=300;
input int InpSetupWindowMinutes=30;
input bool InpCloseAtSessionEnd=true;
input bool InpAutoServerUTC=true;
input double InpServerUTCOffsetHours=0.0;
input group "Walk-forward trainer"
input int InpTrainDays=60;
input int InpLookback=6;
input int InpMaxHoldBars=24;
input int InpMinTrainTrades=10;
input double InpWinRateFloor=35.0;
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
ScalperSignal setup;
datetime lastM5Bar=0,lastClosed=0,retrainMonth=0;
int g_h1ema=INVALID_HANDLE,g_atr=INVALID_HANDLE;
int g_orBars,g_lookback;
double g_buffer,g_rr;
bool g_h1bias;
int g_signals=0,g_attempts=0,g_opened=0,g_retrains=0;
string g_status="Starting";
bool g_armed=false;
ulong g_orderTicket=0;

struct Combo { int orBars,lookback; double buffer,rr; bool h1bias; double pf; int trades; double winrate; };
struct SessionS { bool active; datetime start,lastDay; int orBars,ob; double oH,oL; int dir; };

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
int PeriodKey(datetime t)
{
   MqlDateTime d; TimeToStruct(t,d);
   return d.year*100+d.mon;
}
bool H1BiasOk(datetime barTime,int dir)
{
   int sh=iBarShift(_Symbol,PERIOD_H1,barTime,false);
   if(sh<1) return false;
   datetime open=iTime(_Symbol,PERIOD_H1,sh);
   if(open+3600>barTime) sh++;           // forming H1 -> use the last closed H1
   double c[1]; if(CopyClose(_Symbol,PERIOD_H1,sh,1,c)!=1) return false;
   double e[1]; if(CopyBuffer(g_h1ema,0,sh,1,e)!=1 || e[0]<=0) return false;
   return dir*(c[0]-e[0])>0;
}
void SessionStep(SessionS &st,const MqlRates &br)
{
   bool newSes=!st.active || (ServerMidnight(br.time)!=st.lastDay);
   if(InLondon(br.time))
   {
      if(newSes){ st.active=true; st.start=br.time; st.ob=0; st.oH=0; st.oL=0; st.dir=0; }
      st.lastDay=ServerMidnight(br.time);
      if(br.time>=st.start+InpEntryMinutes*60) return;
      if(st.ob<st.orBars)
      {
         if(st.ob==0){ st.oH=br.high; st.oL=br.low; } else { st.oH=MathMax(st.oH,br.high); st.oL=MathMin(st.oL,br.low); }
         st.ob++;
      }
      else { if(br.close>st.oH) st.dir=1; else if(br.close<st.oL) st.dir=-1; }
   }
   else st.active=false;
}
bool EvalSignal(MqlRates &r[],int i,double &atr[],const Combo &cb,const SessionS &st,ScalperSignal &sig)
{
   if(st.dir==0 || i-cb.lookback<0) return false;
   double pl=r[i-cb.lookback].low,ph=r[i-cb.lookback].high;
   for(int j=i-cb.lookback+1;j<i;j++){ pl=MathMin(pl,r[j].low); ph=MathMax(ph,r[j].high); }
   bool buy=r[i].low<pl && r[i].close>pl;
   bool sell=r[i].high>ph && r[i].close<ph;
   if(buy==sell) return false;
   int sdir=buy?1:-1;
   if(sdir!=st.dir) return false;
   if(cb.h1bias && !H1BiasOk(r[i].time,sdir)) return false;
   double swing=sdir>0?r[i].low:r[i].high;
   for(int k=MathMax(0,i-2);k<=i;k++) swing=sdir>0?MathMin(swing,r[k].low):MathMax(swing,r[k].high);
   double stop=sdir>0?swing-cb.buffer*atr[i]:swing+cb.buffer*atr[i];
   double entry=buy?pl:ph,dist=MathAbs(entry-stop);
   if(dist<=0) return false;
   sig.direction=sdir; sig.trigger=entry; sig.stop=stop; sig.barrier=0;
   sig.expires=r[i].time+PeriodSeconds(PERIOD_M5);
   return true;
}
bool Train(datetime windowStart,Combo &best)
{
   datetime from=windowStart-InpTrainDays*86400;
   int sFrom=iBarShift(_Symbol,PERIOD_M5,from,false)+1;
   int sTo=iBarShift(_Symbol,PERIOD_M5,windowStart,false);
   if(sFrom<=0 || sTo<=0 || sFrom<=sTo) return false;
   int n=sFrom-sTo+1; if(n<160) return false;
   MqlRates r[];
   if(CopyRates(_Symbol,PERIOD_M5,sFrom,n,r)!=n) return false;
   double atr[];
   if(CopyBuffer(g_atr,0,sFrom,n,atr)!=n) return false;
   int winBars=MathMax(1,(int)MathRound(InpSetupWindowMinutes/5.0));
   int orGrid[]={6,9,12};
   int lkGrid[]={6,9,12};
   double bufGrid[]={1.0,1.5,2.0};
   double rrGrid[]={1.5,2.0,3.0};
   bool h1Grid[]={true,false};
   best.pf=0; best.trades=0; best.winrate=0;
   bool found=false;
   for(int a=0;a<ArraySize(orGrid);a++)
   for(int b=0;b<ArraySize(lkGrid);b++)
   for(int c=0;c<ArraySize(bufGrid);c++)
   for(int d=0;d<ArraySize(rrGrid);d++)
   for(int e=0;e<ArraySize(h1Grid);e++)
   {
      Combo cb; cb.orBars=orGrid[a]; cb.lookback=lkGrid[b]; cb.buffer=bufGrid[c]; cb.rr=rrGrid[d]; cb.h1bias=h1Grid[e];
      SessionS st; st.orBars=cb.orBars;
      double grossW=0,grossL=0; int wins=0,losses=0;
      for(int i=0;i<n;i++)
      {
         SessionStep(st,r[i]);
         if(i-cb.lookback<0 || !st.active) continue;
         ScalperSignal sig;
         if(!EvalSignal(r,i,atr,cb,st,sig)) continue;
         double dist=MathAbs(sig.trigger-sig.stop);
         if(dist<=0) continue;
         double tp=sig.trigger+sig.direction*cb.rr*dist;
         int fill=-1;
         for(int j=i+1;j<=MathMin(n-1,i+winBars);j++)
         {
            bool touch=sig.direction>0?(r[j].low<=sig.trigger):(r[j].high>=sig.trigger);
            if(touch){ fill=j; break; }
         }
         if(fill<0) continue;
         ENUM_ORDER_TYPE t=sig.direction>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
         double vw=0,vl=0;
         if(!OrderCalcProfit(t,_Symbol,1.0,sig.trigger,tp,vw)) continue;
         if(!OrderCalcProfit(t,_Symbol,1.0,sig.trigger,sig.stop,vl)) continue;
         bool resolved=false;
         for(int h=fill;h<MathMin(n,fill+1+InpMaxHoldBars);h++)
         {
            bool sl=sig.direction>0?r[h].low<=sig.stop:r[h].high>=sig.stop;
            bool tgt=sig.direction>0?r[h].high>=tp:r[h].low<=tp;
            if(sl){ grossL+=MathAbs(vl)+InpCommissionPerLot; losses++; resolved=true; break; }
            if(tgt){ grossW+=vw-InpCommissionPerLot; wins++; resolved=true; break; }
         }
      }
      int trades=wins+losses;
      double pf=trades>0?(grossL>0?grossW/grossL:999.0):0;
      double wr=trades>0?100.0*wins/trades:0;
      if(trades>=InpMinTrainTrades && wr>=InpWinRateFloor && pf>best.pf)
      {
         best=cb; best.pf=pf; best.trades=trades; best.winrate=wr; found=true;
      }
   }
   return found;
}
void ApplyBest(const Combo &best)
{
   g_orBars=best.orBars; g_lookback=best.lookback; g_buffer=best.buffer; g_rr=best.rr; g_h1bias=best.h1bias;
}
void Retrain(datetime windowStart)
{
   Combo best; best.orBars=6; best.lookback=InpLookback; best.buffer=1.5; best.rr=2.0; best.h1bias=true;
   if(Train(windowStart,best))
   {
      g_retrains++;
      ApplyBest(best);
      PrintFormat("RollingTrain retrained on %s: OR=%d LK=%d buffer=%.1f RR=%.1f H1=%s PF=%.2f trades=%d WR=%.1f%%",
         TimeToString(windowStart,TIME_DATE),best.orBars,best.lookback,best.buffer,best.rr,best.h1bias?"on":"off",
         best.pf,best.trades,best.winrate);
   }
   else
   {
      g_orBars=6; g_lookback=InpLookback; g_buffer=1.5; g_rr=2.0; g_h1bias=true;
      PrintFormat("RollingTrain could not retrain on %s; using fallback OR=6 LK=%d buffer=1.5 RR=2.0 H1=on",
         TimeToString(windowStart,TIME_DATE),InpLookback);
   }
}
void Display()
{
   Comment("RollingTrain | ",_Symbol,"\n",g_status,
           StringFormat("\nConfig: OR=%d LK=%d buffer=%.1f RR=%.1f H1=%s",g_orBars,g_lookback,g_buffer,g_rr,g_h1bias?"on":"off"),
           StringFormat("\nSignal: %s",g_armed?StringFormat("%s @ %.5f stop %.5f",setup.direction>0?"LON":"SHT",setup.trigger,setup.stop):"none"),
           StringFormat("\nRetrains: %d | Daily P/L: %.2f %s | Entries: %d/%d",
              g_retrains,guard.pnl,AccountInfoString(ACCOUNT_CURRENCY),guard.entries,InpMaxEntries),
           (MQLInfoInteger(MQL_TESTER)?"\nTESTER: price-only, news bypassed; manual broker UTC offset":""));
}
int OnInit()
{
   if(InpLondonStart<0 || InpLondonEnd>24 || InpLondonStart>=InpLondonEnd || InpEntryMinutes<0 || InpEntryMinutes>1440 || InpTrainDays<10 || InpTrainDays>365 || InpLookback<2 || InpLookback>60 || InpMaxHoldBars<1 || InpMaxHoldBars>400 || InpMinTrainTrades<1 || InpMinTrainTrades>500 || InpWinRateFloor<0 || InpWinRateFloor>100 || InpRiskMoney<=0 || InpRiskPercent<=0 || InpRiskPercent>100 || InpDailyMaxLoss<=0 || InpDailyTarget<=0 || InpDailyDrawdown<=0 || InpMaxEntries<1 || InpLossCooldownMinutes<0 || InpMaxSpreadPips<=0 || InpMaxSpreadStopFraction<=0 || InpMaxSpreadStopFraction>1 || InpCommissionPerLot<0 || InpDeviationPoints<0 || InpServerUTCOffsetHours<-14 || InpServerUTCOffsetHours>14 || InpBlockServerHourFrom<-1 || InpBlockServerHourFrom>23 || (InpBlockServerHourTo<-1) || InpBlockServerHourTo>24 || InpBlockServerHourFrom2<-1 || InpBlockServerHourFrom2>23 || (InpBlockServerHourTo2<-1) || InpBlockServerHourTo2>24)
      return INIT_PARAMETERS_INCORRECT;
   g_h1ema=iMA(_Symbol,PERIOD_H1,50,0,MODE_EMA,PRICE_CLOSE);
   g_atr=iATR(_Symbol,PERIOD_M5,14);
   if(g_h1ema==INVALID_HANDLE || g_atr==INVALID_HANDLE) return INIT_FAILED;
   execution.Init(InpMagic,InpDeviationPoints); guard.Init(InpMagic);
   lastM5Bar=iTime(_Symbol,PERIOD_M5,0); lastClosed=lastM5Bar;
   datetime now=TimeCurrent();
   datetime ws=ServerMidnight(now); MqlDateTime d; TimeToStruct(now,d); d.hour=0; d.min=0; d.sec=0; d.day=1;
   ws=StructToTime(d);
   retrainMonth=ws;
   if(!EventSetTimer(1)) return INIT_FAILED;
   if(MQLInfoInteger(MQL_TESTER))
      Print("RollingTrain TESTER: price-only test; economic calendar filter bypassed.");
   Retrain(ws);
   Print("RollingTrain initialized.");
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   PrintFormat("RollingTrain summary: retrains=%d, signals=%d, signal evaluations=%d, opened=%d",g_retrains,g_signals,g_attempts,g_opened);
   EventKillTimer(); Comment("");
   if(g_h1ema!=INVALID_HANDLE) IndicatorRelease(g_h1ema);
   if(g_atr!=INVALID_HANDLE) IndicatorRelease(g_atr);
   g_h1ema=INVALID_HANDLE; g_atr=INVALID_HANDLE;
}
void OnTimer()
{
   datetime now=TimeCurrent();
   ManageOrder(now);
   if(!Maintain(now)) { Display(); return; }
   datetime ws=ServerMidnight(now); MqlDateTime d; TimeToStruct(now,d); d.hour=0; d.min=0; d.sec=0; d.day=1;
   ws=StructToTime(d);
   if(ws!=retrainMonth) { retrainMonth=ws; Retrain(ws); }
   datetime m5=iTime(_Symbol,PERIOD_M5,0);
   if(m5!=lastM5Bar){ lastM5Bar=m5; }
   Display();
}
void ManageOrder(datetime now)
{
   if(g_orderTicket==0) return;
   bool still=false;
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i);
      if(t==0) continue;
      if(t==g_orderTicket && OrderGetString(ORDER_SYMBOL)==_Symbol) { still=true; break; }
   }
   if(!still)
   {
      bool filled=false;
      if(HistorySelect(now-300,now))
      {
         for(int i=HistoryDealsTotal()-1;i>=0;i--)
         {
            ulong deal=HistoryDealGetTicket(i);
            if(deal==0) continue;
            if((ulong)HistoryDealGetInteger(deal,DEAL_ORDER)==g_orderTicket && (ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)==InpMagic
               && HistoryDealGetInteger(deal,DEAL_ENTRY)==DEAL_ENTRY_IN) { filled=true; break; }
         }
      }
      if(filled){ g_opened++; g_status="Trade opened at pending limit"; }
      g_armed=false; g_orderTicket=0;
      return;
   }
   if(now>=setup.expires)
   {
      execution.CancelOrder(g_orderTicket);
      g_armed=false; g_orderTicket=0; g_status="Setup limit expired";
   }
}
void OnTick()
{
   datetime now=TimeCurrent();
   if(!Maintain(now))
   {
      Display(); return;
   }
   if(!guard.historyOK)
   {
      g_status="Waiting for account history"; Display(); return;
   }
   if(execution.SymbolBusy())
   {
      g_status="Position/order on symbol: managing or waiting"; Display(); return;
   }
   if(guard.entries>=InpMaxEntries || (guard.lastLoss>0 && now-guard.lastLoss<InpLossCooldownMinutes*60))
   {
      g_status="Entry cap or loss cooldown"; Display(); return;
   }
   if(news.Blocked(now,15,false))
   {
      g_status="News window or unavailable calendar"; Display(); return;
   }
   datetime btc=iTime(_Symbol,PERIOD_M5,1);
   if(btc==0 || btc==lastClosed || !InLondon(btc))
   {
      Display(); return;
   }
   lastClosed=btc;
   int s0=iBarShift(_Symbol,PERIOD_M5,btc,false);
   if(s0<0)
   {
      Display(); return;
   }
   int oldest=s0;
   while(oldest<720)
   {
      datetime older=iTime(_Symbol,PERIOD_M5,oldest+1);
      if(older<=0) break;
      datetime cur=iTime(_Symbol,PERIOD_M5,oldest);
      if(!InLondon(older) || ServerMidnight(older)!=ServerMidnight(cur)) break;
      oldest++;
   }
   int cnt=oldest-s0+1;
   if(cnt<2)
   {
      Display(); return;
   }
   MqlRates r[];
   if(CopyRates(_Symbol,PERIOD_M5,s0,cnt,r)!=cnt)
   {
      Display(); return;
   }
   double atr[]; if(CopyBuffer(g_atr,0,s0,cnt,atr)!=cnt)
   {
      Display(); return;
   }
   SessionS st; st.orBars=g_orBars;
   ScalperSignal sig; bool signalled=false;
   Combo cb; cb.orBars=g_orBars; cb.lookback=g_lookback; cb.buffer=g_buffer; cb.rr=g_rr; cb.h1bias=g_h1bias;
   for(int i=0;i<cnt;i++)
   {
      SessionStep(st,r[i]);
      if(i==cnt-1 && EvalSignal(r,i,atr,cb,st,sig)){ signalled=true; setup=sig; setup.expires=now+InpSetupWindowMinutes*60; }
   }
   if(signalled && WeekdayOk(btc) && !ServerHourBlocked(btc) && g_orderTicket==0)
   {
      g_armed=true; g_signals++;
   }
   if(g_armed && now>=setup.expires) g_armed=false;
   if(g_armed)
   {
      if(!execution.HasOrder())
      {
         double remaining=MathMin(InpDailyMaxLoss+guard.pnl,InpDailyDrawdown-guard.drawdown);
         g_attempts++;
         bool ok=execution.EnterLimit(setup,g_rr,InpRiskMoney,InpRiskPercent,remaining,InpCommissionPerLot,InpMaxSpreadPips,InpMaxSpreadStopFraction,InpDeviationPoints,setup.expires);
         if(ok){ g_orderTicket=execution.lastOrderTicket; g_status="Setup pending: "+execution.lastReason; }
         else { g_status="Setup skipped: "+execution.lastReason; }
      }
      g_armed=false;
   }
   execution.Trail(now,g_rr,InpCommissionPerLot);
   Display();
}