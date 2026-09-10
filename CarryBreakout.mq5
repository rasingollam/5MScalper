#property copyright "CarryBreakout"
#property version "1.00"
#property strict
#property description "H4 trend-following engine with optional carry-side bias. Longs when H4 close>EMA, shorts when close<EMA, exit on flip. InpSideBias=1 long-only, -1 short-only, 0 both. Sizing by reference ATR risk (no SL/TP; positions exit on trend flip)."

input group "Signal"
input ENUM_TIMEFRAMES InpTrendTF=PERIOD_H4;
input int InpTrendEma=100;
input int InpSideBias=0;
input group "Risk (account deposit currency)"
input double InpRiskPercent=0.25;
input double InpCommissionPerLot=7.0;
input double InpRefStopAtr=2.5;
input int InpRefAtrPeriod=20;
input group "Execution"
input ulong InpMagic=5090899;
input int InpDeviationPoints=10;
input int InpMaxRetries=5;

#include <Trade/Trade.mqh>

CTrade trade;
int g_ema=INVALID_HANDLE,g_atr=INVALID_HANDLE;
datetime g_lastBar=0;
bool g_inPosition=false;
int g_entries=0,g_closes=0,g_rejects=0,g_minlotRejects=0;
string g_status="Starting";


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
int Tilt(int dir)
{
   if(InpSideBias>0) return dir>0?1:0;
   if(InpSideBias<0) return dir<0?-1:0;
   return dir;
}
bool ClosePosition()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong pt=PositionGetTicket(i);
      if(pt==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol && (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagic)
      {
         if(trade.PositionClose(pt) && trade.ResultRetcode()==TRADE_RETCODE_DONE){ g_closes++; g_inPosition=false; return true; }
      }
   }
   return false;
}
bool ResultOk()
{
   uint code=trade.ResultRetcode();
   return code==TRADE_RETCODE_DONE || code==TRADE_RETCODE_DONE_PARTIAL || code==TRADE_RETCODE_PLACED;
}
void BarStep()
{
   MqlRates r[];
   ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol,InpTrendTF,1,3,r)!=3) return;
   double ema[2];
   if(CopyBuffer(g_ema,0,1,2,ema)!=2) return;
   int rawDir = r[1].close>ema[0] ? 1 : (r[1].close<ema[0] ? -1 : 0);
   int target = Tilt(rawDir);
   int have = GetPositionDir();
   if(have!=0 && target!=have)
   {
      if(!ClosePosition()) return;
      g_status="Closed on trend flip";
   }
   if(target!=0 && GetPositionDir()==0) TryEnter(target);
}
void TryEnter(int dir)
{
   MqlTick q;
   if(!SymbolInfoTick(_Symbol,q) || q.ask<=q.bid || q.bid<=0) return;
   double entry=dir>0?q.ask:q.bid;
   double atr=0,a[1];
   if(CopyBuffer(g_atr,0,1,1,a)!=1 || a[0]<=0) return;
   atr=a[0];
   double ref=InpRefStopAtr*atr;
   double slRef=entry-dir*ref;
   double loss=0;
   if(!OrderCalcProfit(dir>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL,_Symbol,1.0,entry,slRef,loss)){ g_rejectReason="profit calc failed"; Reject(); return; }
   double budget=AccountInfoDouble(ACCOUNT_EQUITY)*InpRiskPercent/100.0;
   double perLot=MathAbs(loss)+InpCommissionPerLot;
   if(perLot<=0){ g_rejectReason="no risk base"; Reject(); return; }
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0){ g_rejectReason="no volume step"; Reject(); return; }
   double floor=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double cap=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double lots=NormalizeDouble(MathFloor(MathMin(budget/perLot,cap)/step)*step,8);
   if(lots<floor)
   {
      g_minlotRejects++;
      g_rejectReason=StringFormat("min lot %.2f exceeds risk budget (budget=%.2f perLot=%.2f)",floor,budget,perLot);
      Reject(); return;
   }
   double margin=0;
   if(!OrderCalcMargin(dir>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL,_Symbol,lots,entry,margin) || margin>AccountInfoDouble(ACCOUNT_MARGIN_FREE)){ g_rejectReason="insufficient margin"; Reject(); return; }
   bool sent=dir>0?trade.Buy(lots,_Symbol,0,0,0,"CAR"):trade.Sell(lots,_Symbol,0,0,0,"CAR");
   if(!sent || !ResultOk()){ g_rejectReason="order rejected: "+trade.ResultRetcodeDescription(); g_rejects++; return; }
   g_entries++;
   g_status=StringFormat("Entered %s %s lots=%s @%.*f",dir>0?"LONG":"SHORT",_Symbol,DoubleToString(lots,2),_Digits,entry);
}
string g_rejectReason="";
void Reject(){ g_rejects++; g_status="Skipped: "+g_rejectReason; }
void Display()
{
   Comment("CarryBreakout | ",_Symbol,"\n",g_status,
      StringFormat("\nParams: TF=%s EMA=%d bias=%d refStop=%.1fATR risk=%.2f%%",
         EnumToString(InpTrendTF),InpTrendEma,InpSideBias,InpRefStopAtr,InpRiskPercent),
      StringFormat("\nEntries %d | Closes %d | Rejects %d | Min-lot blocks %d",g_entries,g_closes,g_rejects,g_minlotRejects),
      (MQLInfoInteger(MQL_TESTER)?"\nTESTER: "+EnumToString((ENUM_TIMEFRAMES)_Period):""));
}
int OnInit()
{
   if(InpTrendEma<2 || InpRefAtrPeriod<2 || InpRiskPercent<=0 || InpRiskPercent>100 || InpRefStopAtr<=0
      || InpSideBias<-1 || InpSideBias>1 || InpCommissionPerLot<0)
      return INIT_PARAMETERS_INCORRECT;
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);
   g_ema=iMA(_Symbol,InpTrendTF,InpTrendEma,0,MODE_EMA,PRICE_CLOSE);
   g_atr=iATR(_Symbol,InpTrendTF,InpRefAtrPeriod);
   if(g_ema==INVALID_HANDLE || g_atr==INVALID_HANDLE) return INIT_FAILED;
   g_lastBar=0;
   if(!EventSetTimer(30)) return INIT_FAILED;
   PrintFormat("CarryBreakout initialized %s (TF=%s EMA=%d bias=%d ref=%.1fATR risk=%.2f%%)",
      _Symbol,EnumToString(InpTrendTF),InpTrendEma,InpSideBias,InpRefStopAtr,InpRiskPercent);
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   PrintFormat("CarryBreakout summary %s: entries=%d closes=%d rejects=%d minlotBlocks=%d",_Symbol,g_entries,g_closes,g_rejects,g_minlotRejects);
   EventKillTimer(); Comment("");
   if(g_ema!=INVALID_HANDLE) IndicatorRelease(g_ema);
   if(g_atr!=INVALID_HANDLE) IndicatorRelease(g_atr);
   g_ema=INVALID_HANDLE; g_atr=INVALID_HANDLE;
}
void OnTimer()
{
   datetime bar=iTime(_Symbol,InpTrendTF,1);
   if(bar!=g_lastBar){ g_lastBar=bar; BarStep(); }
}
void OnTick(){ Display(); }