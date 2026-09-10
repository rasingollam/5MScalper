#property copyright "HTFTrendBreakoutF"
#property version "1.1"
#property strict
#property description "Single-change variant of the frozen V1 baseline: adds the rejection-strength filter (bar must close in the outer third of its own high-low range) on top of the identical H1 channel-breakout rig. All other signal, risk and exit logic is identical to HTFTrendBreakout. Set InpRejectStrength=0 to reproduce the baseline exactly."

input group "Signal"
input int InpChannelBars=40;
input int InpATRPeriod=20;
input double InpStopAtr=2.5;
input double InpTrailAtr=3.0;
input group "Signal filter"
input double InpRejectStrength=0.0;   // 0=off (baseline); 0.6667 = close in outer third
input group "Risk (account deposit currency)"
input double InpRiskPercent=0.25;
input double InpCommissionPerLot=7.0;
input group "Execution"
input ulong InpMagic=5090991;
input int InpDeviationPoints=10;
input double InpMaxSpreadStopFraction=0.35;
input double InpMaxEntryGapPips=15.0;
input int InpMaxRetries=5;

#include <Trade/Trade.mqh>

CTrade trade;
int g_atr=INVALID_HANDLE;
datetime g_lastBar=0,g_pendBar=0;
bool g_pending=false,g_consumed=false,g_inPosition=false;
int g_pendDir=0;
double g_pendAtr=0,g_initSL=0,g_entryPrice=0,g_entryTime=0;
int g_signals=0,g_entries=0,g_closes=0,g_rejects=0,g_retries=0,g_trailMods=0,g_minlotRejects=0,g_filtered=0;
string g_rejectReason="",g_status="Starting";

double Pip(){ return (_Digits==3 || _Digits==5)?10*_Point:_Point; }
double GetATR(datetime barTime)
{
   int sh=iBarShift(_Symbol,PERIOD_H1,barTime,false);
   if(sh<1) return 0;
   double a[1];
   if(CopyBuffer(g_atr,0,sh,1,a)!=1 || a[0]<=0) return 0;
   return a[0];
}
void SignalStep()
{
// Called once when a new H1 bar closes. Bar 1 is the just closed signal bar;
// channel uses bars 2..(1+InpChannelBars), ATR uses completed bars at shift 1.
   int need=1+InpChannelBars+1;
   MqlRates r[]; ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol,PERIOD_H1,1,need,r)!=need) return;
   double hi=r[1].high,lo=r[1].low;
   for(int j=2;j<=InpChannelBars;j++)
   {
      hi=MathMax(hi,r[j].high);
      lo=MathMin(lo,r[j].low);
   }
   double atr=GetATR(r[0].time);
   if(atr<=0) return;
   int dir=0;
   if(r[0].close>hi) dir=1;
   else if(r[0].close<lo) dir=-1;
// Rejection-strength filter: the breakout bar must close in the outer
// InpRejectStrength fraction of its own high-low range (decisive, not marginal).
   if(dir!=0 && InpRejectStrength>0 && InpRejectStrength<1)
   {
      double range=r[0].high-r[0].low;
      bool decisive=range>0 && (dir>0 ? (r[0].close-r[0].low)>=InpRejectStrength*range
                                     : (r[0].high-r[0].close)>=InpRejectStrength*range);
      if(!decisive)
      {
         g_filtered++;
         g_status=StringFormat("Filtered %s bar %s (close not in outer %.0f%% of range)",
            dir>0?"LONG":"SHORT",TimeToString(r[0].time,TIME_MINUTES),100*InpRejectStrength);
         PrintFormat("HTF filtered %s bar=%s close=%.*f chanHi=%.5f chanLo=%.5f range=%.5f",
            dir>0?"LONG":"SHORT",TimeToString(r[0].time,TIME_MINUTES),_Digits,r[0].close,hi,lo,range);
         dir=0;
      }
   }
// Opposite signal while holding closes; same-direction while holding is ignored.
   if(g_inPosition)
   {
      if(dir!=0 && GetPositionDir()!=0 && dir*GetPositionDir()<0)
      {
         ClosePosition();
         g_status="Closed on opposite signal (no reversal)";
      }
      g_pending=false; g_consumed=false;
      return;
   }
   if(dir!=0)
   {
      g_signals++;
      g_pending=true; g_consumed=false;
      g_pendDir=dir; g_pendAtr=atr; g_pendBar=r[0].time; g_retries=0;
      g_status=StringFormat("Signal %s H1 close %.*f chHi %.5f chLo %.5f ATR %.5f",
         dir>0?"LONG":"SHORT",_Digits,r[0].close,hi,lo,atr);
      PrintFormat("HTF signal %s bar=%s close=%.*f chanHi=%.5f chanLo=%.5f atr=%.5f",
         dir>0?"LONG":"SHORT",TimeToString(r[0].time,TIME_MINUTES),_Digits,r[0].close,hi,lo,atr);
   }
}
int GetPositionDir()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong pt=PositionGetTicket(i);
      if(pt==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol && (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagic)
         return PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?1:-1;
   }
   return 0;
}
bool FindPosition()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong pt=PositionGetTicket(i);
      if(pt==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol && (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagic)
      {
         g_inPosition=true;
         g_entryPrice=PositionGetDouble(POSITION_PRICE_OPEN);
         g_entryTime=(datetime)PositionGetInteger(POSITION_TIME);
         if(g_initSL<=0) g_initSL=PositionGetDouble(POSITION_SL);
         return true;
      }
   }
   g_inPosition=false; return false;
}
bool ClosePosition()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong pt=PositionGetTicket(i);
      if(pt==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol && (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagic)
      {
         if(trade.PositionClose(pt)){ g_closes++; g_inPosition=false; g_initSL=0; return true; }
      }
   }
   return false;
}
void TryEntry()
{
   if(g_retries>=InpMaxRetries){ g_pending=false; return; }
   g_retries++;
   g_rejectReason="";
   MqlTick q;
   if(!SymbolInfoTick(_Symbol,q) || q.ask<=q.bid || q.bid<=0) return;
   double atr=g_pendAtr;
   if(atr<=0) return;
   double entry=g_pendDir>0?q.ask:q.bid;
   double sl=entry-g_pendDir*InpStopAtr*atr;
   double pip=Pip();
   double distance=g_pendDir*(entry-sl);
   if(distance<=0){ g_rejectReason="invalid stop distance"; Reject(); return; }
// Entry-gap guard: current price must sit near the signal close, else the move gapped away.
   double close=iClose(_Symbol,PERIOD_H1,iBarShift(_Symbol,PERIOD_H1,g_pendBar,false));
   double gap=(g_pendDir>0?q.bid:q.ask)-close; gap=MathAbs(gap);
   if(gap>InpMaxEntryGapPips*pip)
   {
      g_rejectReason=StringFormat("entry gap %.1f pips exceeds %s pips",gap/pip,DoubleToString(InpMaxEntryGapPips,1));
      Reject(); return;
   }
   if(q.ask-q.bid>distance*InpMaxSpreadStopFraction+_Point*0.01)
   {
      g_rejectReason=StringFormat("spread %.1f%% of stop > %.1f%%",100*(q.ask-q.bid)/distance,100*InpMaxSpreadStopFraction);
      Reject(); return;
   }
   double minStop=(SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)+1)*_Point;
   if(distance<minStop){ g_rejectReason="stop inside broker stops level"; Reject(); return; }
// Size from initial-stop risk exactly like the account risk model.
   double budget=AccountInfoDouble(ACCOUNT_EQUITY)*InpRiskPercent/100.0;
   double loss=0;
   ENUM_ORDER_TYPE t=g_pendDir>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   if(!OrderCalcProfit(t,_Symbol,1.0,entry+g_pendDir*InpDeviationPoints*_Point,sl,loss)){ g_rejectReason="profit calc failed"; Reject(); return; }
   double perLot=MathAbs(loss)+InpCommissionPerLot;
   if(perLot<=0 || budget<=0){ g_rejectReason="no risk budget"; Reject(); return; }
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0){ g_rejectReason="no volume step"; Reject(); return; }
   double lots=NormalizeDouble(MathFloor(MathMin(budget/perLot,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX))/step)*step,8);
   if(lots<SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN))
   {
      g_minlotRejects++;
      g_rejectReason=StringFormat("min lot %.2f exceeds risk budget (%.2f/%.2f per lot)",SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),budget,perLot);
      Reject(); return;
   }
   double margin=0;
   if(!OrderCalcMargin(t,_Symbol,lots,entry,margin) || margin>AccountInfoDouble(ACCOUNT_MARGIN_FREE)){ g_rejectReason="insufficient margin"; Reject(); return; }
   bool sent=g_pendDir>0?trade.Buy(lots,_Symbol,0,sl,0,"HTF"):trade.Sell(lots,_Symbol,0,sl,0,"HTF");
   if(!sent || !ResultOk())
   {
      g_rejectReason="order rejected: "+trade.ResultRetcodeDescription();
      g_rejects++;
      return;
   }
   g_entries++;
   g_initSL=sl;
   g_pending=false; g_consumed=true;
   g_status=StringFormat("Entered %s %s lots=%s @%.*f sl=%.*f atr=%.5f",
      g_pendDir>0?"LONG":"SHORT",_Symbol,DoubleToString(lots,2),_Digits,entry,_Digits,sl,atr);
   PrintFormat("HTF entered %s %s lots=%s entry=%.*f sl=%.*f risk=%.2f",
      g_pendDir>0?"LONG":"SHORT",_Symbol,DoubleToString(lots,2),_Digits,entry,_Digits,sl,MathAbs(loss)*lots);
}
void Reject()
{
   g_rejects++;
   g_status="Entry rejected: "+g_rejectReason;
}
bool ResultOk()
{
   uint code=trade.ResultRetcode();
   return code==TRADE_RETCODE_DONE || code==TRADE_RETCODE_DONE_PARTIAL || code==TRADE_RETCODE_PLACED;
}
void ManageTrailing()
{
   if(!FindPosition()) return;
   if(g_inPosition)
   {
      int dir=GetPositionDir();
      if(dir==0) return;
      double sl=PositionGetDouble(POSITION_SL);
      datetime t=(datetime)PositionGetInteger(POSITION_TIME);
      int since=iBarShift(_Symbol,PERIOD_H1,t,false);
      if(since<1) return;
      int look=MathMin(since,500);
      double h[]; ArraySetAsSeries(h,true);
      if(CopyHigh(_Symbol,PERIOD_H1,1,look,h)!=look) return;
      double ref=dir>0?h[0]:h[0];
      for(int j=1;j<look;j++) ref=dir>0?MathMax(ref,h[j]):MathMin(ref,h[j]);
      double atr=GetATR(iTime(_Symbol,PERIOD_H1,1));
      if(atr<=0) return;
      double cand=dir>0?ref-InpTrailAtr*atr:ref+InpTrailAtr*atr;
      if(g_initSL>0 && dir*(cand-g_initSL)<0) cand=g_initSL;   // never loosen original risk
      MqlTick q; if(!SymbolInfoTick(_Symbol,q)) return;
      double current=dir>0?q.bid:q.ask;
      double gapLevel=(MathMax(SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL),SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL))+1)*_Point;
      double tick=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
      if(dir*(current-cand)<gapLevel || (sl>0 && dir*(cand-sl)<tick)) return;
      ulong ticket=PositionGetInteger(POSITION_TICKET);
      if(trade.PositionModify(ticket,cand,0)){ g_trailMods++; g_status="Trail stop updated"; }
   }
}
void Display()
{
   Comment("HTFTrendBreakoutF | ",_Symbol,"\n",g_status,
      StringFormat("\nParams: chan=%d ATR=%d stop=%.1fATR trail=%.1fATR filter=%.2f risk=%.2f%%",
         InpChannelBars,InpATRPeriod,InpStopAtr,InpTrailAtr,InpRejectStrength,InpRiskPercent),
      StringFormat("\nSignals %d | Filtered %d | Entries %d | Closes %d | Rejects %d | Trail mods %d | Min-lot blocks %d",
         g_signals,g_filtered,g_entries,g_closes,g_rejects,g_trailMods,g_minlotRejects),
      (MQLInfoInteger(MQL_TESTER)?"\nTESTER: "+EnumToString((ENUM_TIMEFRAMES)_Period):""));
}
int OnInit()
{
   if(InpChannelBars<2 || InpATRPeriod<2 || InpStopAtr<=0 || InpTrailAtr<=0 || InpRiskPercent<=0 || InpRiskPercent>100
      || InpMaxSpreadStopFraction<=0 || InpMaxSpreadStopFraction>1 || InpMaxEntryGapPips<0
      || InpRejectStrength<0 || InpRejectStrength>=1)
      return INIT_PARAMETERS_INCORRECT;
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);
   g_atr=iATR(_Symbol,PERIOD_H1,InpATRPeriod);
   if(g_atr==INVALID_HANDLE) return INIT_FAILED;
   g_lastBar=iTime(_Symbol,PERIOD_H1,1);
   if(!EventSetTimer(1)) return INIT_FAILED;
   g_inPosition=FindPosition();
   if(g_inPosition) g_initSL=PositionGetDouble(POSITION_SL);
   PrintFormat("HTF initialized %s (sig H1, chan=%d, ATR=%d, stop=%.1f, trail=%.1f, filter=%.2f, risk=%.2f%%)",
      _Symbol,InpChannelBars,InpATRPeriod,InpStopAtr,InpTrailAtr,InpRejectStrength,InpRiskPercent);
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   PrintFormat("HTF summary %s: signals=%d, filtered=%d, entries=%d, closes=%d, trailMods=%d, rejects=%d, minlotBlocks=%d",
      _Symbol,g_signals,g_filtered,g_entries,g_closes,g_trailMods,g_rejects,g_minlotRejects);
   EventKillTimer(); Comment("");
   if(g_atr!=INVALID_HANDLE) IndicatorRelease(g_atr);
   g_atr=INVALID_HANDLE;
}
void OnTimer(){ ManageTrailing(); }
void OnTick()
{
   datetime bar=iTime(_Symbol,PERIOD_H1,1);
   if(bar!=g_lastBar)
   {
      g_lastBar=bar;
      SignalStep();
   }
// Manage trailing before entry-only paths so management is never skipped.
   if(FindPosition())
   {
      g_inPosition=true;
      if(!g_consumed && g_pending && GetPositionDir()!=0 && g_pendDir*GetPositionDir()>0) g_pending=false;
      ManageTrailing();
   }
   else if(g_inPosition)
   {
// Position vanished (closed externally / SL/TP). Reset state.
      g_inPosition=false; g_initSL=0; g_status="Position closed externally";
   }
   if(g_pending && !g_inPosition) TryEntry();
   Display();
}