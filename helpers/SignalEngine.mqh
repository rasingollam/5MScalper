#ifndef SIGNAL_ENGINE_MQH
#define SIGNAL_ENGINE_MQH
struct ScalperSignal
{
   int direction;
   double trigger,stop,barrier;
   datetime expires;
};
class CSignalEngine
{
private:
   int fast,slow,pullback,atr;
   double Value(int handle,int shift)
   {
      double b[1]; if(CopyBuffer(handle,0,shift,1,b)!=1) return EMPTY_VALUE;
      return b[0];
   }
public:
   CSignalEngine():fast(INVALID_HANDLE),slow(INVALID_HANDLE),pullback(INVALID_HANDLE),atr(INVALID_HANDLE) {}
   bool Init()
   {
      fast=iMA(_Symbol,PERIOD_M15,20,0,MODE_EMA,PRICE_CLOSE);
      slow=iMA(_Symbol,PERIOD_M15,50,0,MODE_EMA,PRICE_CLOSE);
      pullback=iMA(_Symbol,PERIOD_M5,20,0,MODE_EMA,PRICE_CLOSE);
      atr=iATR(_Symbol,PERIOD_M5,14);
      return fast!=INVALID_HANDLE && slow!=INVALID_HANDLE && pullback!=INVALID_HANDLE && atr!=INVALID_HANDLE;
   }
   void Release()
   {
      if(fast!=INVALID_HANDLE) IndicatorRelease(fast);
      if(slow!=INVALID_HANDLE) IndicatorRelease(slow);
      if(pullback!=INVALID_HANDLE) IndicatorRelease(pullback);
      if(atr!=INVALID_HANDLE) IndicatorRelease(atr);
   }
   bool TrendValid(int dir)
   {
      double f=Value(fast,1),fp=Value(fast,2),s=Value(slow,1),sp=Value(slow,2);
      if(f==EMPTY_VALUE || fp==EMPTY_VALUE || s==EMPTY_VALUE || sp==EMPTY_VALUE) return false;
      return dir*(f-s)>0 && dir*(f-fp)>0 && dir*(s-sp)>0;
   }
   bool Build(ScalperSignal &s,double buffer,double maxCandle)
   {
      MqlRates r[]; ArraySetAsSeries(r,true);
      if(CopyRates(_Symbol,PERIOD_M5,0,24,r)!=24 || BarsCalculated(slow)<55) return false;
      double f=Value(fast,1),fp=Value(fast,2),sl=Value(slow,1),sp=Value(slow,2);
      double ema=Value(pullback,1),a=Value(atr,1);
      if(f==EMPTY_VALUE || fp==EMPTY_VALUE || sl==EMPTY_VALUE || sp==EMPTY_VALUE || ema==EMPTY_VALUE || a==EMPTY_VALUE || a<=0) return false;
      if(r[1].high-r[1].low>maxCandle*a) return false;
      int dir=0;
      if(f>sl && f>fp && sl>sp && r[1].low<=ema && r[1].close>ema && r[1].close>r[1].open) dir=1;
      if(f<sl && f<fp && sl<sp && r[1].high>=ema && r[1].close<ema && r[1].close<r[1].open) dir=-1;
      if(dir==0) return false;
      s.direction=dir; s.expires=r[0].time+2*PeriodSeconds(PERIOD_M5);
      s.trigger=dir>0?r[1].high:r[1].low;
      double swing=dir>0?r[1].low:r[1].high;
      for(int i=2;i<=3;i++) swing=dir>0?MathMin(swing,r[i].low):MathMax(swing,r[i].high);
      s.stop=swing-dir*buffer*a; s.barrier=0;
      // Nearest confirmed local pivot from the preceding 20 closed bars.
      for(int i=3;i<=21;i++)
      {
         double level=dir>0?r[i].high:r[i].low;
         bool pivot=dir>0?(level>r[i-1].high && level>=r[i+1].high):(level<r[i-1].low && level<=r[i+1].low);
         if(pivot && dir*(level-s.trigger)>0 && (s.barrier==0 || dir*(level-s.barrier)<0)) s.barrier=level;
      }
      return true;
   }
};
#endif
