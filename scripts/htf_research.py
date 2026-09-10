"""Isolated MT5 research runner; explicit presets, fresh reports, deal reconciliation.

Run from the repository root. Uses the existing QA terminal only.
Commission sensitivity is USD 7 per entry lot ROUND TRIP, not a broker quote.
"""
import datetime as dt
import html
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
QA = Path(os.environ['APPDATA']) / 'MetaQuotes/Terminal/F76814D0838EB1EEB269E1473C19ACE8'
EXE = Path(os.environ['LOCALAPPDATA']) / 'Temp/SessionGuardM5-QA-v2/terminal64.exe'
TEMP = Path(os.environ['LOCALAPPDATA']) / 'Temp/opencode'
OUT = ROOT / 'research/htf-corrected'

def text(path):
    data = path.read_bytes()
    return data.decode('utf-16' if data.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8-sig')

def analyze(path, deposit=20000., anchor='2026.09.08'):
    raw = text(path)
    def stat(label):
        match = re.search(re.escape(label) + r'</td>\s*<td[^>]*><b>(.*?)</b>', raw, re.S)
        return html.unescape(match[1]).strip() if match else None
    result = {k: stat(k) for k in ('Period:', 'History Quality:', 'Total Net Profit:', 'Profit Factor:',
        'Total Trades:', 'Profit Trades (% of total):', 'Average profit trade:', 'Average loss trade:',
        'Expected Payoff:', 'Equity Drawdown Maximal:', 'Balance Drawdown Maximal:')}
    rows = re.findall(r'<tr\b[^>]*>(.*?)</tr>', raw.split('<b>Deals</b>')[1], re.S)
    deals = []
    for row in rows:
        cells = [html.unescape(re.sub('<[^>]+>', '', c)).strip() for c in re.findall(r'<td\b[^>]*>(.*?)</td>', row, re.S)]
        if len(cells) == 13 and cells[4] in ('in', 'out'):
            deals.append(cells)
    num = lambda v: float(v.replace(' ', '').replace('\xa0', ''))
    lots = sum(num(d[5]) for d in deals if d[4] == 'in')
    commission = sum(num(d[8]) for d in deals)
    swap = sum(num(d[9]) for d in deals)
    net = sum(sum(num(d[i]) for i in (8, 9, 10)) for d in deals)
    assert abs(net - num(result['Total Net Profit:'])) < .02, (net, result)
    assert sum(d[4] == 'out' for d in deals) == int(result['Total Trades:'])
    years = {}
    outcomes = []
    pending = None
    peak = balance = deposit
    peak_time = dt.datetime(2022, 1, 1)
    longest = 0.
    for d in deals:
        value = sum(num(d[i]) for i in (8, 9, 10))
        years[d[0][:4]] = years.get(d[0][:4], 0.) + value
        when = dt.datetime.strptime(d[0], '%Y.%m.%d %H:%M:%S')
        balance += value
        if balance >= peak:
            longest = max(longest, (when - peak_time).total_seconds() / 86400)
            peak, peak_time = balance, when
        if d[4] == 'in':
            assert pending is None, 'Unexpected overlapping positions'
            pending = value
        else:
            assert pending is not None
            outcomes.append(pending + value)
            pending = None
    longest = max(longest, (dt.datetime.strptime(anchor, '%Y.%m.%d') - peak_time).total_seconds() / 86400)
    result.update(net=round(net, 2), entry_lots=round(lots, 4), commission=round(commission, 2),
        swap=round(swap, 2), net_at_7_round_trip=round(net - lots * 7, 2),
        annual_net={k: round(v, 2) for k, v in years.items()},
        longest_balance_underwater_days=round(longest, 1),
        top_10_winners=sum(sorted(outcomes, reverse=True)[:10]))
    return result

def _compile(name):
    log = TEMP / (name + '-corrected.log')
    if log.exists(): log.unlink()
    subprocess.run(['D:/Trading/MetaEditor64.exe', '/compile:' + str(ROOT / (name + '.mq5')), '/log:' + str(log)])
    for _ in range(60):
        if log.exists() and 'Result:' in text(log): break
        time.sleep(1)
    output = text(log)
    print(output[output.index('Result:'):].strip(), flush=True)
    assert '0 errors, 0 warnings' in output, output
    shutil.copy2(ROOT / (name + '.ex5'), QA / ('MQL5/Experts/5MScalper/' + name + '.ex5'))

def compile_all():
    for name in ('HTFTrendBreakout', 'HTFTrendBreakoutF', 'HTFTrendBreakoutV', 'IndexBreakout'):
        _compile(name)

def run(name, expert, symbol='EURUSD', period='H1', inputs=None, model=1, frm='2022.01.01', to='2026.09.08', deposit=20000.):
    for p in sorted(OUT.glob(name + '*.htm')):
        raw = text(p)
        if all((lambda m: m is not None and float(m[1]) == float(value))(re.search(re.escape(k) + r'=([^<]+)', raw))
               for k, value in (inputs or {}).items()):
            r = analyze(p, deposit=deposit, anchor=to)
            r.update(symbol=symbol, timeframe=period, inputs=inputs or {},
                     history_quality=r.get('History Quality:'))
            print(name, '(cached)', json.dumps(r), flush=True)
            return r
    preset = QA / ('MQL5/Profiles/Tester/' + name + '.set')
    preset.write_text('\n'.join(f'{k}={v}' for k, v in (inputs or {}).items()), encoding='ascii')
    config = TEMP / (name + '.ini')
    config.write_text(f'''[Common]
Login=463855945
Server=Exness-MT5Trial17
[Experts]
AllowLiveTrading=0
AllowDllImport=0
[Tester]
Expert=5MScalper\\{expert}.ex5
ExpertParameters={name}.set
Symbol={symbol}
Period={period}
Model={model}
ExecutionMode=100
Optimization=0
FromDate={frm}
ToDate={to}
Deposit={int(deposit)}
Currency=USD
Leverage=100
Visual=0
Report={name}
ReplaceReport=1
ShutdownTerminal=1
UseLocal=1
UseRemote=0
UseCloud=0
''', encoding='ascii')
    report = QA / (name + '.htm')
    old = max((p.stat().st_mtime for p in QA.glob(name + '*.htm')), default=0)
    proc = subprocess.Popen([str(EXE), '/config:' + str(config)], cwd=EXE.parent)
    proc.wait(timeout=1800)
    time.sleep(2)
    reports = sorted(QA.glob(name + '*.htm'), key=lambda p: p.stat().st_mtime)
    assert reports and reports[-1].stat().st_mtime > old, 'No fresh report: ' + name
    report = reports[-1]
    raw = text(report)
    for key, value in (inputs or {}).items():
        found = re.search(re.escape(key) + r'=([^<]+)', raw)
        assert found and float(found[1]) == float(value), (key, value, found)
    shutil.copy2(report, OUT / report.name)
    result = analyze(report, deposit=deposit, anchor=to)
    result.update(symbol=symbol, timeframe=period, inputs=inputs or {}, history_quality=result.get('History Quality:'))
    print(name, json.dumps(result), flush=True)
    return result

if __name__ == '__main__':
    assert QA.is_dir() and EXE.is_file() and TEMP.is_dir()
    OUT.mkdir(parents=True, exist_ok=True)
    if sys.argv[-1] == 'analyze':
        for p in OUT.glob('*.htm'): print(p.stem, json.dumps(analyze(p)))
        sys.exit()
    compile_all()
    results = {}
    cases = [('corrected_base', 'HTFTrendBreakout', 'EURUSD', 'H1', {'InpSignalTF': 16385}),
             ('corrected_close', 'HTFTrendBreakoutF', 'EURUSD', 'H1', {'InpRejectStrength': 0.6667}),
             ('corrected_veto', 'HTFTrendBreakoutV', 'EURUSD', 'H1', {'InpVetoADX': 25})]
    if 'h4' in sys.argv:
        cases = [('h4_' + s, 'HTFTrendBreakout', s, 'H1', {'InpSignalTF': 16388}) for s in ('EURUSD', 'GBPUSD', 'USDJPY', 'AUDUSD')]
    if 'm4' in sys.argv:
        results = {r: run('m4_' + r, 'HTFTrendBreakout', r, 'H1', {'InpSignalTF': 16388}, model=4, frm='2026.01.01', to='2026.09.08')
                   for r in ('EURUSD', 'USDJPY')}
        (OUT / 'm4-results.json').write_text(json.dumps(results, indent=2))
        sys.exit()
    if 'probe' in sys.argv:
        for s in ('US30', 'US500', 'USTEC', 'JP225'):
            try:
                run('idx_probe_' + s, 'HTFTrendBreakout', s, 'H1', {'InpMaxEntryGapPips': 100000},
                    model=1, frm='2022.01.01', to='2026.09.08')
            except Exception as e:
                print('PROBE_FAIL', s, repr(e), flush=True)
        sys.exit()
    if 'idx' in sys.argv:
        symbols = ('US30', 'US500', 'USTEC', 'JP225')
        chan = (20, 40, 80)
        sess_on = {s: (14, 23) if s != 'JP225' else (0, 10) for s in symbols}
        IS_FROM, IS_TO = '2022.01.01', '2024.06.30'
        OOS_FROM, OOS_TO = '2024.07.01', '2026.09.08'
        is_table = {}
        for symbol in symbols:
            for tfnum, tfname in ((16385, 'h1'), (16388, 'h4')):
                for c in chan:
                    for sess, sessv in (('off', (0, 0)), ('on', sess_on[symbol])):
                        key = f'{tfname}-c{c}-sess{sess}'
                        name = f'idx_is_{symbol}_{key}'
                        result = run(name, 'IndexBreakout', symbol, 'H1',
                                     {'InpSignalTF': tfnum, 'InpChannelBars': c,
                                      'InpSessionStart': sessv[0], 'InpSessionEnd': sessv[1]},
                                     model=1, frm=IS_FROM, to=IS_TO)
                        is_table.setdefault(key, []).append({**result, 'symbol': symbol})
        by_cfg = {}
        for key, rows in is_table.items():
            nets = [r['net_at_7_round_trip'] for r in rows]
            by_cfg[key] = {'mean_net_comm7': round(sum(nets) / len(nets), 2),
                           'sum_net_comm7': round(sum(nets), 2),
                           'pos_symbols': sum(1 for n in nets if n >= 0)}
        chosen = max(by_cfg, key=lambda k: (by_cfg[k]['mean_net_comm7'], by_cfg[k]['pos_symbols']))
        tf_chosen = 16385 if chosen.startswith('h1') else 16388
        c_chosen = int(chosen.split('-c')[1].split('-sess')[0])
        sess_chosen = chosen.split('-sess')[1]
        oos_table = {}
        for symbol in symbols:
            s = sess_on[symbol] if sess_chosen == 'on' else (0, 0)
            name = f'idx_oos_{symbol}'
            r = run(name, 'IndexBreakout', symbol, 'H1',
                    {'InpSignalTF': tf_chosen, 'InpChannelBars': c_chosen,
                     'InpSessionStart': s[0], 'InpSessionEnd': s[1]},
                    model=1, frm=OOS_FROM, to=OOS_TO)
            r['avg_lots_per_trade'] = round(r['entry_lots'] / max(int(r['Total Trades:']), 1), 3)
            r['commission_per_trade'] = round(r['avg_lots_per_trade'] * 7, 2)
            oos_table[symbol] = r
        (OUT / 'idx-results.json').write_text(json.dumps(
            {'is_from': IS_FROM, 'is_to': IS_TO, 'oos_from': OOS_FROM, 'oos_to': OOS_TO,
             'session_windows_server_hours': sess_on, 'is_by_config': by_cfg, 'chosen_config': chosen,
             'is_detail': {k: [{'s': r['symbol'], 'net7': r['net_at_7_round_trip'],
                                'pf': r['Profit Factor:'], 'n': r['Total Trades:'],
                                'avg_lots': round(r['entry_lots'] / max(int(r['Total Trades:']), 1), 3),
                                'hq': r['History Quality:']} for r in v]
                           for k, v in is_table.items()},
             'oos_after_commission': {s: {k: r[k] for k in ('net', 'net_at_7_round_trip', 'Profit Factor:',
                                                            'Total Trades:', 'Profit Trades (% of total):',
                                                            'Expected Payoff:', 'Equity Drawdown Maximal:',
                                                            'History Quality:', 'annual_net', 'avg_lots_per_trade',
                                                            'commission_per_trade')}
                                      for s, r in oos_table.items()}},
            indent=2))
        print('IDX_CHOSEN', chosen)
        oos_sum = sum(r['net_at_7_round_trip'] for r in oos_table.values())
        if oos_sum > 0:
            print('OOS aggregate positive; running Model=4 real-tick cross-check')
            m4 = {s: run('idx_m4_' + s, 'IndexBreakout', s, 'H1',
                         {'InpSignalTF': tf_chosen, 'InpChannelBars': c_chosen,
                          'InpSessionStart': (sess_on[s] if sess_chosen == 'on' else (0, 0))[0],
                          'InpSessionEnd': (sess_on[s] if sess_chosen == 'on' else (0, 0))[1]},
                         model=4, frm='2026.01.01', to='2026.09.08')
                  for s in symbols}
            (OUT / 'idx-m4-results.json').write_text(json.dumps(
                {s: {k: r[k] for k in ('net', 'net_at_7_round_trip', 'Profit Factor:', 'Total Trades:',
                                       'History Quality:')} for s, r in m4.items()}, indent=2))
        sys.exit()
    if 'wf' in sys.argv:
        symbols = ('EURUSD', 'GBPUSD', 'USDJPY', 'AUDUSD', 'NZDUSD', 'AUDNZD', 'GBPJPY')
        grid = [(16385, 'h1'), (16388, 'h4')]
        chan = (20, 40, 80)
        IS_FROM, IS_TO = '2022.01.01', '2024.06.30'
        OOS_FROM, OOS_TO = '2024.07.01', '2026.09.08'
        is_table = {}
        for symbol in symbols:
            for tfnum, tfname in grid:
                for c in chan:
                    key = f'{tfname}-c{c}'
                    name = f'wf_is_{symbol}_{key}'
                    result = run(name, 'HTFTrendBreakout', symbol, 'H1',
                                 {'InpSignalTF': tfnum, 'InpChannelBars': c},
                                 model=1, frm=IS_FROM, to=IS_TO)
                    is_table.setdefault(key, []).append({**result, 'symbol': symbol})
        by_cfg = {}
        for key, rows in is_table.items():
            nets = [r['net_at_7_round_trip'] for r in rows]
            by_cfg[key] = {'mean_net_comm7': round(sum(nets) / len(nets), 2),
                           'any_negative': sum(1 for n in nets if n >= 0),
                           'sum_net_comm7': round(sum(nets), 2)}
        chosen = max(by_cfg, key=lambda k: by_cfg[k]['mean_net_comm7'])
        tf_chosen = 16385 if chosen.startswith('h1') else 16388
        c_chosen = int(chosen.split('-c')[1])
        oos_table = {}
        for symbol in symbols:
            name = f'wf_oos_{symbol}'
            oos_table[symbol] = run(name, 'HTFTrendBreakout', symbol, 'H1',
                                    {'InpSignalTF': tf_chosen, 'InpChannelBars': c_chosen},
                                    model=1, frm=OOS_FROM, to=OOS_TO)
        (OUT / 'wf-results.json').write_text(json.dumps(
            {'is_from': IS_FROM, 'is_to': IS_TO, 'oos_from': OOS_FROM, 'oos_to': OOS_TO,
             'is_by_config': by_cfg, 'chosen_config': chosen,
             'is_detail': {k: [{'s': r['symbol'], 'net7': r['net_at_7_round_trip'],
                                'pf': r['Profit Factor:'], 'n': r['Total Trades:'],
                                'hq': r['History Quality:']} for r in v]
                           for k, v in is_table.items()},
             'oos_after_commission': {s: {'net7': r['net_at_7_round_trip'], 'pf': r['Profit Factor:'],
                                          'n': r['Total Trades:'], 'wr': r['Profit Trades (% of total):'],
                                          'hq': r['History Quality:'], 'eqdd': r['Equity Drawdown Maximal:'],
                                          'annual': r['annual_net']} for s, r in oos_table.items()}},
            indent=2))
        print('WF_CHOSEN', chosen)
        sys.exit()
    for args in cases:
        results[args[0]] = run(*args)
        (OUT / ('h4-results.json' if 'h4' in sys.argv else 'results.json')).write_text(json.dumps(results, indent=2))
