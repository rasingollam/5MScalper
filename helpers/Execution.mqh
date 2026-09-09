#ifndef EXECUTION_MQH
#define EXECUTION_MQH
#include <Trade/Trade.mqh>
class CScalperExecution
{
private:
   CTrade trade;
   ulong magic;
   datetime lastCloseAttempt,lastModify,lastRejectPrint;
   string lastPrintedReason;
   bool beatsGlobal;
   bool Reject(string reason)
   {
      lastReason=reason;
      datetime now=TimeCurrent();
      if(reason!=lastPrintedReason || now-lastRejectPrint>300)
      {
         lastRejectPrint=now; lastPrintedReason=reason;
         Print("SessionGuard M5 entry skipped: ",reason);
      }
      return false;
   }
   bool Accepted()
   {
      uint code=trade.ResultRetcode();
      if(code==TRADE_RETCODE_DONE || code==TRADE_RETCODE_DONE_PARTIAL) return true;
      PrintFormat("SessionGuard M5 trade response: %u %s",code,trade.ResultRetcodeDescription());
      return false;
   }
   double Price(string symbol,double price,bool up)
   {
      double tick=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
      return NormalizeDouble((up?MathCeil(price/tick):MathFloor(price/tick))*tick,SymbolInfoInteger(symbol,SYMBOL_DIGITS));
   }
public:
   string lastReason;
   bool retryable;
   CScalperExecution():magic(0),lastCloseAttempt(0),lastModify(0),lastRejectPrint(0),lastPrintedReason(""),beatsGlobal(false) {}
   void Init(ulong id,int deviation)
   {
      magic=id; trade.SetExpertMagicNumber(id); trade.SetDeviationInPoints(deviation);
      trade.SetAsyncMode(false);
   }
   bool GlobalMode() { return beatsGlobal; }
   bool OwnTicket()
   {
      return (ulong)PositionGetInteger(POSITION_MAGIC)==magic;
   }
   bool OwnPosition(string symbol)
   {
      for(int i=PositionsTotal()-1;i>=0;i--) if(PositionGetTicket(i)>0 && PositionGetString(POSITION_SYMBOL)==symbol && OwnTicket()) return true;
      return false;
   }
   bool SymbolBusy(string symbol)
   {
      for(int i=PositionsTotal()-1;i>=0;i--) if(PositionGetTicket(i)>0 && PositionGetString(POSITION_SYMBOL)==symbol) return true;
      for(int i=OrdersTotal()-1;i>=0;i--) if(OrderGetTicket(i)>0 && OrderGetString(ORDER_SYMBOL)==symbol) return true;
      return false;
   }
   void CloseAll(datetime now)
   {
      if(now-lastCloseAttempt<2) return;
      lastCloseAttempt=now;
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         ulong ticket=PositionGetTicket(i);
         if(ticket>0 && OwnTicket()) { trade.PositionClose(ticket); Accepted(); }
      }
   }
   bool Enter(string symbol,ScalperSignal &s,double targetR,double moneyRisk,double percentRisk,double remaining,double commission,double maxSpread,double spreadFraction,int deviation)
   {
      lastReason=""; retryable=false;
      if(SymbolBusy(symbol)) return Reject("symbol busy");
      int digits=SymbolInfoInteger(symbol,SYMBOL_DIGITS);
      double point=SymbolInfoDouble(symbol,SYMBOL_POINT);
      MqlTick q; if(!SymbolInfoTick(symbol,q) || q.ask<=q.bid || q.bid<=0) return false;
      double pip=(digits==3 || digits==5)?10*point:point;
      double entry=s.direction>0?q.ask:q.bid;
      double sl=Price(symbol,s.stop,s.direction<0);
      double distance=s.direction*(entry-sl);
      double minStop=(SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL)+1)*point;
      if(distance<=0) return Reject("invalid stop distance");
      if(q.ask-q.bid>maxSpread*pip+point*0.01 || q.ask-q.bid>distance*spreadFraction+point*0.01)
      { retryable=true; return Reject(StringFormat("spread %.2f pips, limit %.2f; spread/stop %.1f%%, limit %.1f%%",(q.ask-q.bid)/pip,maxSpread,100*(q.ask-q.bid)/distance,100*spreadFraction)); }
      if((s.direction>0?q.bid-sl:sl-q.ask)<minStop) return Reject("SL inside broker stop distance");
      double tp=Price(symbol,entry+s.direction*targetR*distance,s.direction>0);
      if((s.direction>0?tp-q.bid:q.ask-tp)<minStop) return Reject("TP inside broker stop distance");
      if(s.barrier>0 && s.direction*(tp-s.barrier)>=0) return Reject("nearby pivot leaves insufficient target room");
      double budget=MathMin(MathMin(moneyRisk,AccountInfoDouble(ACCOUNT_EQUITY)*percentRisk/100.0),remaining);
      double loss=0;
      ENUM_ORDER_TYPE type=s.direction>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
      double entryEdge=entry+s.direction*deviation*point;
      if(!OrderCalcProfit(type,symbol,1.0,entryEdge,sl,loss)) return false;
      double perLot=MathAbs(loss)+commission;
      if(perLot<=0 || budget<=0) return Reject("no risk budget");
      double step=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
      if(step<=0) return false;
      double lots=NormalizeDouble(MathFloor(MathMin(budget/perLot,SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX))/step)*step,8);
      if(lots<SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN)) return Reject("risk budget below minimum lot");
      double margin;
      if(!OrderCalcMargin(type,symbol,lots,entry,margin) || margin>AccountInfoDouble(ACCOUNT_MARGIN_FREE)) return Reject("margin calculation or insufficient margin");
      trade.SetTypeFillingBySymbol(symbol);
      bool sent=s.direction>0?trade.Buy(lots,symbol,0,sl,tp,"SessionGuard M5"):trade.Sell(lots,symbol,0,sl,tp,"SessionGuard M5");
      bool accepted=Accepted();
      return sent && accepted;
   }
   void Trail(datetime now,double rr,double commission)
   {
      if(now-lastModify<5) return;
      MqlTick q; MqlRates r[]; ArraySetAsSeries(r,true);
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         ulong ticket=PositionGetTicket(i); if(ticket==0 || !OwnTicket()) continue;
         string symbol=PositionGetString(POSITION_SYMBOL);
         if(!SymbolInfoTick(symbol,q)) continue;
         if(CopyRates(symbol,PERIOD_M5,1,3,r)!=3) continue;
         int dir=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?1:-1;
         double open=PositionGetDouble(POSITION_PRICE_OPEN),tp=PositionGetDouble(POSITION_TP),sl=PositionGetDouble(POSITION_SL);
         // The original fixed TP preserves initial R after SL modifications and restarts.
         double risk=dir*(tp-open)/rr;
         double current=dir>0?q.bid:q.ask;
         if(tp<=0 || risk<=0 || dir*(current-open)<risk) continue;
         int digits=SymbolInfoInteger(symbol,SYMBOL_DIGITS);
         double point=SymbolInfoDouble(symbol,SYMBOL_POINT);
         double tick=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE),tickProfit;
         if(!OrderCalcProfit(dir>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL,symbol,1,open,open+dir*tick,tickProfit) || tickProfit<=0) continue;
         double costs=commission+MathMax(0.0,-PositionGetDouble(POSITION_SWAP)/PositionGetDouble(POSITION_VOLUME));
         double be=open+dir*(costs/tickProfit*tick+tick);
         double swing=dir>0?MathMin(r[0].low,MathMin(r[1].low,r[2].low))-tick:MathMax(r[0].high,MathMax(r[1].high,r[2].high))+tick;
         double candidate=Price(symbol,dir>0?MathMax(be,swing):MathMin(be,swing),dir<0);
         double gap=(MathMax(SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL),SymbolInfoInteger(symbol,SYMBOL_TRADE_FREEZE_LEVEL))+1)*point;
         if(dir*(current-candidate)<gap || (sl>0 && dir*(candidate-sl)<tick)) continue;
         lastModify=now; trade.PositionModify(ticket,candidate,tp); Accepted();
      }
   }
};
#endif