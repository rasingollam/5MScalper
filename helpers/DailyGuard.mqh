#ifndef DAILY_GUARD_MQH
#define DAILY_GUARD_MQH
class CDailyGuard
{
private:
   string key;
   datetime day;
   double baseline,peak;
   bool locked;
   bool persistent;
   void Save()
   {
      if(!persistent) return;
      GlobalVariableSet(key+"day",(double)day);
      GlobalVariableSet(key+"base",baseline);
      GlobalVariableSet(key+"peak",peak);
      GlobalVariableSet(key+"lock",locked?1:0);
      GlobalVariablesFlush();
   }
public:
   int entries;
   datetime lastLoss;
   double pnl;
   double drawdown;
   bool historyOK;
   CDailyGuard():day(0),baseline(0),peak(0),locked(false),entries(0),lastLoss(0),pnl(0),drawdown(0),historyOK(false) {}
   void Init(ulong magic)
   {
      key=StringFormat("SG5.%I64d.%I64u.",AccountInfoInteger(ACCOUNT_LOGIN),magic);
      persistent=!MQLInfoInteger(MQL_TESTER);
      if(persistent && GlobalVariableCheck(key+"day") && GlobalVariableCheck(key+"base") && GlobalVariableCheck(key+"peak") && GlobalVariableCheck(key+"lock"))
      {
         day=(datetime)GlobalVariableGet(key+"day"); baseline=GlobalVariableGet(key+"base");
         peak=GlobalVariableGet(key+"peak"); locked=GlobalVariableGet(key+"lock")>0;
      }
   }
   bool Update(datetime now,ulong magic,double maxLoss,double target,double maxDD)
   {
      datetime today=ServerMidnight(now);
      double equity=AccountInfoDouble(ACCOUNT_EQUITY);
      if(day!=today)
      {
         bool first=day==0;
         double start=equity;
         if(first)
         {
            // Reconstruct today's starting balance on first installation. Historical
            // midnight floating equity / intraday peaks cannot be recovered from deals.
            historyOK=HistorySelect(today,now);
            if(!historyOK) return locked;
            double realized=0;
            for(int i=0;i<HistoryDealsTotal();i++)
            {
               ulong deal=HistoryDealGetTicket(i);
               long type=HistoryDealGetInteger(deal,DEAL_TYPE);
               if(type==DEAL_TYPE_BUY || type==DEAL_TYPE_SELL)
                  realized+=HistoryDealGetDouble(deal,DEAL_PROFIT)+HistoryDealGetDouble(deal,DEAL_SWAP)+HistoryDealGetDouble(deal,DEAL_COMMISSION)+HistoryDealGetDouble(deal,DEAL_FEE);
            }
            start=AccountInfoDouble(ACCOUNT_BALANCE)-realized;
         }
         day=today; baseline=start; peak=MathMax(start,equity); locked=false; Save();
      }
      pnl=equity-baseline;
      if(equity>peak) { peak=equity; Save(); }
      drawdown=peak-equity;
      if(!locked && (pnl<=-maxLoss || pnl>=target || drawdown>=maxDD))
      { locked=true; Save(); Print("SessionGuard M5: daily equity limit reached. Entries locked until next broker day."); }
      entries=0; lastLoss=0;
      // Include the previous day so cooldown survives midnight.
      historyOK=HistorySelect(today-86400,now);
      if(!historyOK) return locked;
      ulong orders[];
      for(int i=0;i<HistoryDealsTotal();i++)
      {
         ulong deal=HistoryDealGetTicket(i);
         if((ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=magic) continue;
         long type=HistoryDealGetInteger(deal,DEAL_TYPE);
         if(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL) continue;
         datetime time=(datetime)HistoryDealGetInteger(deal,DEAL_TIME);
         long entry=HistoryDealGetInteger(deal,DEAL_ENTRY);
         if((entry==DEAL_ENTRY_IN || entry==DEAL_ENTRY_INOUT) && time>=today)
         {
            ulong order=HistoryDealGetInteger(deal,DEAL_ORDER); bool found=false;
            for(int j=0;j<ArraySize(orders);j++) if(orders[j]==order) found=true;
            if(!found) { int n=ArraySize(orders); ArrayResize(orders,n+1); orders[n]=order; entries++; }
         }
         if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY || entry==DEAL_ENTRY_INOUT)
         {
            double net=HistoryDealGetDouble(deal,DEAL_PROFIT)+HistoryDealGetDouble(deal,DEAL_SWAP)+HistoryDealGetDouble(deal,DEAL_COMMISSION)+HistoryDealGetDouble(deal,DEAL_FEE);
            ulong position=HistoryDealGetInteger(deal,DEAL_POSITION_ID);
            double entryCosts=0,entryVolume=0;
            for(int j=0;j<HistoryDealsTotal();j++)
            {
               ulong prior=HistoryDealGetTicket(j);
               if((ulong)HistoryDealGetInteger(prior,DEAL_POSITION_ID)!=position || HistoryDealGetInteger(prior,DEAL_ENTRY)!=DEAL_ENTRY_IN) continue;
               entryCosts+=HistoryDealGetDouble(prior,DEAL_COMMISSION)+HistoryDealGetDouble(prior,DEAL_FEE);
               entryVolume+=HistoryDealGetDouble(prior,DEAL_VOLUME);
            }
            if(entryVolume>0) net+=entryCosts*HistoryDealGetDouble(deal,DEAL_VOLUME)/entryVolume;
            if(net<0 && time>lastLoss) lastLoss=time;
         }
      }
      return locked;
   }
};
#endif
