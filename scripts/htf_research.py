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

def analyze(path):
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
    peak = balance = 20000.
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
    longest = max(longest, (dt.datetime(2026, 9, 8) - peak_time).total_seconds() / 86400)
    result.update(net=round(net, 2), entry_lots=round(lots, 4), commission=round(commission, 2),
        swap=round(swap, 2), net_at_7_round_trip=round(net - lots * 7, 2),
        annual_net={k: round(v, 2) for k, v in years.items()},
        longest_balance_underwater_days=round(longest, 1),
        top_10_winners=sum(sorted(outcomes, reverse=True)[:10]))
    return result

def compile_all():
    for suffix in ('', 'F', 'V'):
        name = 'HTFTrendBreakout' + suffix
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

def run(name, expert, symbol='EURUSD', period='H1', inputs=None, model=1, frm='2022.01.01', to='2026.09.08'):
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
Deposit=20000
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
    old = report.stat().st_mtime if report.exists() else 0
    proc = subprocess.Popen([str(EXE), '/config:' + str(config)], cwd=EXE.parent)
    proc.wait(timeout=1800)
    time.sleep(2)
    assert report.exists() and report.stat().st_mtime > old, 'No fresh report: ' + name
    raw = text(report)
    for key, value in (inputs or {}).items():
        found = re.search(re.escape(key) + r'=([^<]+)', raw)
        assert found and float(found[1]) == float(value), (key, value, found)
    shutil.copy2(report, OUT / report.name)
    result = analyze(report)
    result.update(symbol=symbol, timeframe=period, inputs=inputs or {})
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
    for args in cases:
        results[args[0]] = run(*args)
        (OUT / ('h4-results.json' if 'h4' in sys.argv else 'results.json')).write_text(json.dumps(results, indent=2))
