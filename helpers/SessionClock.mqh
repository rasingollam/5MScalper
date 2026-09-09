#ifndef SESSION_CLOCK_MQH
#define SESSION_CLOCK_MQH
datetime CalendarDate(int year,int month,int day,int hour=0)
{
   MqlDateTime d={}; d.year=year; d.mon=month; d.day=day; d.hour=hour;
   return StructToTime(d);
}
int Sunday(int year,int month,int nth)
{
   MqlDateTime d; TimeToStruct(CalendarDate(year,month,1),d);
   return 1+(7-d.day_of_week)%7+7*(nth-1);
}
bool LondonDST(datetime utc)
{
   MqlDateTime d; TimeToStruct(utc,d);
   return utc>=CalendarDate(d.year,3,Sunday(d.year,3,5)>31?Sunday(d.year,3,4):Sunday(d.year,3,5),1)
       && utc<CalendarDate(d.year,10,Sunday(d.year,10,5)>31?Sunday(d.year,10,4):Sunday(d.year,10,5),1);
}
bool NewYorkDST(datetime utc)
{
   MqlDateTime d; TimeToStruct(utc,d);
   return utc>=CalendarDate(d.year,3,Sunday(d.year,3,2),7)
       && utc<CalendarDate(d.year,11,Sunday(d.year,11,1),6);
}
datetime ServerMidnight(datetime now)
{
   MqlDateTime d; TimeToStruct(now,d); d.hour=0; d.min=0; d.sec=0;
   return StructToTime(d);
}
bool SessionOpen(datetime utc,int londonStart,int londonEnd,int nyStart,int nyEnd)
{
   MqlDateTime l,n;
   TimeToStruct(utc+(LondonDST(utc)?3600:0),l);
   TimeToStruct(utc+(NewYorkDST(utc)?-4:-5)*3600,n);
   return (l.day_of_week>=1 && l.day_of_week<=5 && l.hour>=londonStart && l.hour<londonEnd)
       || (n.day_of_week>=1 && n.day_of_week<=5 && n.hour>=nyStart && n.hour<nyEnd);
}
#endif
