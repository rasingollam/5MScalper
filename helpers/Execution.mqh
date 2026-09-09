#ifndef EXECUTION_MQH
#define EXECUTION_MQH
#include <Trade/Trade.mqh>
class CScalperExecution
{
private:
   CTrade trade;
   ulong magic;
   datetime lastCloseAttempt,lastModify;
   bool Accepted()
   {
      uint code=trade.ResultRetcode();
      if(code==TRADE_RETCODE_DONE || code==TRADE_RETCODE_DONE_PARTIAL) return true;
      PrintFormat("SessionGuard M5 trade response: %u %s",code,trade.ResultRetcodeDescription());
      return false;
   }
   double Price(double price,bool up)
   {
      double tick=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
      return NormalizeDouble((up?MathCeil(price/tick):MathFloor(price/tick))*tick,_Digits);
   }
public:
   CScalperExecution():magic(0),lastCloseAttempt(0),lastModify(0) {}
   void Init(ulong id,int deviation)
   {
      magic=id; trade.SetExpertMagicNumber(id); trade.SetDeviationInPoints(deviation);
      trade.SetTypeFillingBySymbol(_Symbol); trade.SetAsyncMode(false);
   }
   bool OwnSelected()
   {
      return PositionGetString(POSITION_SYMBOL)==_Symbol && (ulong)PositionGetInteger(POSITION_MAGIC)==magic;
   }
   bool OwnPosition()
   {
      for(int i=PositionsTotal()-1;i>=0;i--) if(PositionGetTicket(i)>0 && OwnSelected()) return true;
      return false;
   }
   bool SymbolBusy()
   {
      for(int i=PositionsTotal()-1;i>=0;i--) if(PositionGetTicket(i)>0 && PositionGetString(POSITION_SYMBOL)==_Symbol) return true;
      for(int i=OrdersTotal()-1;i>=0;i--) if(OrderGetTicket(i)>0 && OrderGetString(ORDER_SYMBOL)==_Symbol) return true;
      return false;
   }
   void CloseAll(datetime now)
   {
      if(now-lastCloseAttempt<2) return;
      lastCloseAttempt=now;
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         ulong ticket=PositionGetTicket(i);
         if(ticket>0 && OwnSelected()) { trade.PositionClose(ticket); Accepted(); }
      }
   }
   bool Enter(ScalperSignal &s,double rr,double moneyRisk,double percentRisk,double remaining,double commission,double maxSpread,double spreadFraction,int deviation)
   {
      if(SymbolBusy()) return false;
      MqlTick q; if(!SymbolInfoTick(_Symbol,q) || q.ask<=q.bid || q.bid<=0) return false;
      double pip=(_Digits==3 || _Digits==5)?10*_Point:_Point;
      double entry=s.direction>0?q.ask:q.bid;
      double sl=Price(s.stop,s.direction<0);
      double distance=s.direction*(entry-sl);
      double minStop=(SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)+1)*_Point;
      if(distance<=0 || q.ask-q.bid>maxSpread*pip || q.ask-q.bid>distance*spreadFraction) return false;
      if((s.direction>0?q.bid-sl:sl-q.ask)<minStop) return false;
      double tp=Price(entry+s.direction*rr*distance,s.direction>0);
      if((s.direction>0?tp-q.bid:q.ask-tp)<minStop) return false;
      if(s.barrier>0 && s.direction*(tp-s.barrier)>=0) return false;
      double budget=MathMin(MathMin(moneyRisk,AccountInfoDouble(ACCOUNT_EQUITY)*percentRisk/100.0),remaining);
      double loss=0;
      ENUM_ORDER_TYPE type=s.direction>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
      if(!OrderCalcProfit(type,_Symbol,1.0,entry+s.direction*deviation*_Point,sl,loss)) return false;
      double perLot=MathAbs(loss)+commission;
      if(perLot<=0 || budget<=0) return false;
      double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
      if(step<=0) return false;
      double lots=NormalizeDouble(MathFloor(MathMin(budget/perLot,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX))/step)*step,8);
      if(lots<SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN)) return false;
      double margin;
      if(!OrderCalcMargin(type,_Symbol,lots,entry,margin) || margin>AccountInfoDouble(ACCOUNT_MARGIN_FREE)) return false;
      bool sent=s.direction>0?trade.Buy(lots,_Symbol,0,sl,tp,"SessionGuard M5"):trade.Sell(lots,_Symbol,0,sl,tp,"SessionGuard M5");
      bool accepted=Accepted();
      return sent && accepted;
   }
   void Trail(datetime now,double rr,double commission)
   {
      if(now-lastModify<5) return;
      MqlTick q; if(!SymbolInfoTick(_Symbol,q)) return;
      MqlRates r[]; ArraySetAsSeries(r,true);
      if(CopyRates(_Symbol,PERIOD_M5,1,3,r)!=3) return;
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         ulong ticket=PositionGetTicket(i); if(ticket==0 || !OwnSelected()) continue;
         int dir=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?1:-1;
         double open=PositionGetDouble(POSITION_PRICE_OPEN),tp=PositionGetDouble(POSITION_TP),sl=PositionGetDouble(POSITION_SL);
         // The original fixed TP preserves initial R after SL modifications and restarts.
         double risk=dir*(tp-open)/rr;
         double current=dir>0?q.bid:q.ask;
         if(tp<=0 || risk<=0 || dir*(current-open)<risk) continue;
         double tick=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE),tickProfit;
         if(!OrderCalcProfit(dir>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL,_Symbol,1,open,open+dir*tick,tickProfit) || tickProfit<=0) continue;
         double costs=commission+MathMax(0.0,-PositionGetDouble(POSITION_SWAP)/PositionGetDouble(POSITION_VOLUME));
         double be=open+dir*(costs/tickProfit*tick+tick);
         double swing=dir>0?MathMin(r[0].low,MathMin(r[1].low,r[2].low))-tick:MathMax(r[0].high,MathMax(r[1].high,r[2].high))+tick;
         double candidate=Price(dir>0?MathMax(be,swing):MathMin(be,swing),dir<0);
         double gap=(MathMax(SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL),SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL))+1)*_Point;
         if(dir*(current-candidate)<gap || (sl>0 && dir*(candidate-sl)<tick)) continue;
         lastModify=now; trade.PositionModify(ticket,candidate,tp); Accepted();
      }
   }
};
#endif
