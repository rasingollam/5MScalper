#ifndef NEWS_FILTER_MQH
#define NEWS_FILTER_MQH
class CNewsFilter
{
private:
   datetime checked;
   bool blocked;
public:
   CNewsFilter():checked(0),blocked(true) {}
   bool Blocked(datetime now,int minutes,bool enabled)
   {
      if(!enabled) return false;
      // Historical calendar is unavailable in MT5 tester. OnInit and the panel
      // explicitly label tester results as price-only; live failure stays closed.
      if(MQLInfoInteger(MQL_TESTER)) return false;
      if(checked!=0 && now>=checked && now-checked<30) return blocked;
      checked=now; blocked=false;
      string currencies[2]={"EUR","USD"};
      for(int c=0;c<2;c++)
      {
         MqlCalendarValue values[];
         int count=CalendarValueHistory(values,now-minutes*60,now+minutes*60,NULL,currencies[c]);
         if(count<0) { blocked=true; return true; }
         for(int i=0;i<count;i++)
         {
            MqlCalendarEvent event;
            if(!CalendarEventById(values[i].event_id,event)) { blocked=true; return true; }
            if(event.importance==CALENDAR_IMPORTANCE_HIGH) { blocked=true; return true; }
         }
      }
      return blocked;
   }
};
#endif
