"""Read MT5 HTML reports, reconcile trades and compare fixed experiment variants."""
import argparse, collections, datetime as dt, html, json, re
from pathlib import Path

def rows(path):
    b=path.read_bytes()
    s=b.decode('utf-16') if b[:2] in (b'\xff\xfe',b'\xfe\xff') else b.decode('utf-8',errors='replace')
    return [[html.unescape(re.sub('<[^>]+>','',c)).strip() for c in re.findall(r'<t[dh]\b[^>]*>(.*?)</t[dh]>',r,re.S)] for r in re.findall(r'<tr\b[^>]*>(.*?)</tr>',s,re.S)]

def number(s): return float(s.replace(' ','').replace('\xa0',''))

def metrics(trades, rate):
    outcomes=[t['pnl']-rate*t['lots'] for t in trades]
    positive=sum(max(0,p) for p in outcomes); negative=-sum(min(0,p) for p in outcomes)
    balance=peak=10000.; dd=0.
    for p in outcomes:
        balance+=p; peak=max(peak,balance); dd=max(dd,peak-balance)
    weeks=collections.Counter((t['time'].date()-dt.timedelta(days=t['time'].weekday())).isoformat() for t in trades)
    return dict(trades=len(trades),net=round(sum(outcomes),2),pf=round(positive/negative,3) if negative else None,
                win_percent=round(100*sum(p>0 for p in outcomes)/len(outcomes),2) if outcomes else 0,
                closed_balance_dd=round(dd,2),active_weeks=len(weeks),weekly=weeks)

def analyze(path):
    rr=rows(path); index=next(i for i,r in enumerate(rr) if r[:5]==['Time','Deal','Symbol','Type','Direction'])
    trades=[]; entry=None; charged=0.
    for r in rr[index+1:]:
        if len(r)!=13 or r[2]!='EURUSD':continue
        charged+=number(r[8])
        if r[4]=='in':
            if entry is not None:raise ValueError('Overlapping entries require position-ID pairing')
            entry=r
        elif r[4]=='out':
            if entry is None:raise ValueError('Exit without entry')
            if number(entry[5])!=number(r[5]):raise ValueError('Partial exit requires allocation')
            trades.append(dict(time=dt.datetime.strptime(entry[0],'%Y.%m.%d %H:%M:%S'),lots=number(entry[5]),
                               pnl=sum(number(entry[j])+number(r[j]) for j in (8,9,10))))
            entry=None
    if entry is not None:raise ValueError('Unclosed trade')
    reported=next(number(r[r.index('Total Net Profit:')+1]) for r in rr if 'Total Net Profit:' in r)
    assert abs(sum(t['pnl'] for t in trades)-reported)<.02
    metadata={r[i]:r[i+1] for r in rr[:index] for i in range(len(r)-1) if r[i] in ['History Quality:','Bars:','Ticks:','Equity Drawdown Maximal:','Profit Factor:']}
    return dict(name=path.stem.replace('experiment_',''),commission_charged=round(charged,2),metadata=metadata,
                raw=metrics(trades,0),cost7=metrics(trades,7),
                jan_apr_cost7=metrics([t for t in trades if t['time']<dt.datetime(2026,5,1)],7),
                may_sep_cost7=metrics([t for t in trades if t['time']>=dt.datetime(2026,5,1)],7))

if __name__=='__main__':
    ap=argparse.ArgumentParser();ap.add_argument('directory');ap.add_argument('output');args=ap.parse_args()
    results=[analyze(p) for p in sorted(Path(args.directory).glob('experiment_*.htm'))]
    Path(args.output).write_text(json.dumps(results,indent=2),encoding='utf-8')
    for r in results:
        print(r['name'], 'raw=',r['raw']['net'], 'cost7=',r['cost7']['net'], 'PF=',r['cost7']['pf'],
              'trades=',r['raw']['trades'], 'Jan-Apr=',r['jan_apr_cost7']['net'],'May-Sep=',r['may_sep_cost7']['net'], 'metadata=',r['metadata'])
