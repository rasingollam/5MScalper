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
   int fast,slow,pullback,atr,adx,h1bias;
   double Value(int handle,int shift)
   {
      double b[1]; if(CopyBuffer(handle,0,shift,1,b)!=1) return EMPTY_VALUE;
      return b[0];
   }
   double H1EMA(int shift)
   {
      return Value(h1bias,shift);
   }
   double H1Close(int shift)
   {
      double c[1]; if(CopyClose(_Symbol,PERIOD_H1,shift,1,c)!=1) return EMPTY_VALUE;
      return c[0];
   }
public:
   CSignalEngine():fast(INVALID_HANDLE),slow(INVALID_HANDLE),pullback(INVALID_HANDLE),atr(INVALID_HANDLE),adx(INVALID_HANDLE),h1bias(INVALID_HANDLE) {}
   bool Init()
   {
      fast=iMA(_Symbol,PERIOD_M15,20,0,MODE_EMA,PRICE_CLOSE);
      slow=iMA(_Symbol,PERIOD_M15,50,0,MODE_EMA,PRICE_CLOSE);
      pullback=iMA(_Symbol,PERIOD_M5,20,0,MODE_EMA,PRICE_CLOSE);
      atr=iATR(_Symbol,PERIOD_M5,14);
      adx=iADX(_Symbol,PERIOD_M15,14);
      h1bias=iMA(_Symbol,PERIOD_H1,50,0,MODE_EMA,PRICE_CLOSE);
      return fast!=INVALID_HANDLE && slow!=INVALID_HANDLE && pullback!=INVALID_HANDLE && atr!=INVALID_HANDLE && adx!=INVALID_HANDLE && h1bias!=INVALID_HANDLE;
   }
   void Release()
   {
      if(fast!=INVALID_HANDLE) IndicatorRelease(fast);
      if(slow!=INVALID_HANDLE) IndicatorRelease(slow);
      if(pullback!=INVALID_HANDLE) IndicatorRelease(pullback);
      if(atr!=INVALID_HANDLE) IndicatorRelease(atr);
      if(adx!=INVALID_HANDLE) IndicatorRelease(adx);
      if(h1bias!=INVALID_HANDLE) IndicatorRelease(h1bias);
   }
   bool TrendValid(int dir)
   {
      double f=Value(fast,1),fp=Value(fast,2),s=Value(slow,1),sp=Value(slow,2);
      if(f==EMPTY_VALUE || fp==EMPTY_VALUE || s==EMPTY_VALUE || sp==EMPTY_VALUE) return false;
      return dir*(f-s)>0 && dir*(f-fp)>0 && dir*(s-sp)>0;
   }
   bool OpposingTrend(int dir)
   {
      double strength=Value(adx,1),f=Value(fast,1),s=Value(slow,1);
      if(strength==EMPTY_VALUE || f==EMPTY_VALUE || s==EMPTY_VALUE) return true;
      return strength>25 && dir*(f-s)<0;
   }
   bool H1BiasValid(int dir)
   {
      double e=H1EMA(1),c=H1Close(1);
      if(e==EMPTY_VALUE || c==EMPTY_VALUE) return false;
      return dir*(c-e)>0;
   }
   bool Build(ScalperSignal &s,double buffer,double maxCandle,int lookback,bool candleFilter,bool trendFilter,bool strongClose,bool trendVeto,bool h1Bias,bool tightReclaim)
   {
      MqlRates r[]; ArraySetAsSeries(r,true);
      int count=MathMax(24,lookback+2);
      if(CopyRates(_Symbol,PERIOD_M5,0,count,r)!=count) return false;
      double a=Value(atr,1);
      if(a==EMPTY_VALUE || a<=0) return false;
      if(candleFilter && r[1].high-r[1].low>maxCandle*a) return false;
      // Exclude the signal candle from the reference range; no future bars.
      double priorLow=r[2].low,priorHigh=r[2].high;
      for(int i=3;i<=lookback+1;i++)
      {
         priorLow=MathMin(priorLow,r[i].low);
         priorHigh=MathMax(priorHigh,r[i].high);
      }
      bool buy=r[1].low<priorLow && r[1].close>priorLow;
      bool sell=r[1].high>priorHigh && r[1].close<priorHigh;
      if(buy==sell) return false; // Neither side, or an ambiguous double sweep.
      int dir=buy?1:-1;
      if(tightReclaim && !(buy?r[1].close>r[2].close:r[1].close<r[2].close)) return false;
      if(h1Bias && !H1BiasValid(dir)) return false;
      double range=r[1].high-r[1].low;
      if(strongClose && (range<=0 || (buy?r[1].close<r[1].high-range/3.0:r[1].close>r[1].low+range/3.0))) return false;
      if(trendVeto && OpposingTrend(dir)) return false;
      if(trendFilter && !TrendValid(dir)) return false;
      s.direction=dir; s.expires=r[0].time+PeriodSeconds(PERIOD_M5);
      // Enter after the reclaim close, without waiting for a candle-high breakout.
      s.trigger=buy?priorLow:priorHigh;
      double swing=dir>0?r[1].low:r[1].high;
      for(int i=2;i<=3;i++) swing=dir>0?MathMin(swing,r[i].low):MathMax(swing,r[i].high);
      s.stop=swing-dir*buffer*a; s.barrier=0;
      // Confirm with two bars on either side. A level crossed by a later
      // closed bar is already broken and must not block a continuation entry.
      for(int i=3;i<=21;i++)
      {
         double level=dir>0?r[i].high:r[i].low;
         bool pivot=true;
         for(int j=1;j<=2;j++)
         {
            if(dir>0 && (level<=r[i-j].high || level<r[i+j].high)) pivot=false;
            if(dir<0 && (level>=r[i-j].low || level>r[i+j].low)) pivot=false;
         }
         for(int j=i-1;j>=1 && pivot;j--)
         {
            if(dir>0 && r[j].high>level) pivot=false;
            if(dir<0 && r[j].low<level) pivot=false;
         }
         if(pivot && dir*(level-s.trigger)>0 && (s.barrier==0 || dir*(level-s.barrier)<0)) s.barrier=level;
      }
      return true;
   }
};
#endif
