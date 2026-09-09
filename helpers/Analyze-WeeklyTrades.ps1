param(
    [Parameter(Mandatory=$true)][string]$AgentLog,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [datetime]$FromDate='2026-01-01',
    [datetime]$ToDate='2026-09-08'
)
$ErrorActionPreference='Stop'
$lines=Get-Content -LiteralPath $AgentLog
$start=-1
for($i=0;$i -lt $lines.Count;$i++) {
    if($lines[$i] -match 'InpSweepLookback=') { $start=$i }
}
if($start -lt 0) { throw 'No reversal test inputs found in this agent log.' }
$run=$lines[$start..($lines.Count-1)]
if(!($run | Where-Object {$_ -match 'SessionGuard M5 summary:'})) {
    throw 'The reversal test has not finished.'
}
$trades=@()
foreach($line in $run) {
    if($line -match '(\d{4}\.\d{2}\.\d{2}) (\d{2}:\d{2}:\d{2})\s+CTrade::OrderSend: market (buy|sell) [0-9.]+ EURUSD sl:.*\[done') {
        $date=[datetime]::ParseExact($Matches[1]+' '+$Matches[2],'yyyy.MM.dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture)
        if($date -ge $FromDate -and $date -lt $ToDate) {
            $trades += [pscustomobject]@{Time=$date; Direction=$Matches[3]}
        }
    }
}
$monday=$FromDate.Date.AddDays(-(([int]$FromDate.DayOfWeek+6)%7))
$weeks=@()
while($monday -lt $ToDate) {
    $next=$monday.AddDays(7)
    $items=@($trades | Where-Object {$_.Time -ge $monday -and $_.Time -lt $next})
    $weeks += [pscustomobject]@{Monday=$monday;Count=$items.Count;Buy=@($items | Where-Object {$_.Direction -eq 'buy'}).Count;Sell=@($items | Where-Object {$_.Direction -eq 'sell'}).Count;Partial=($monday -lt $FromDate -or $next -gt $ToDate)}
    $monday=$next
}
$active=@($weeks | Where-Object {$_.Count -gt 0}).Count
$report=@('# Reversal entry weekly validation','',
    "Test dates: $($FromDate.ToString('yyyy-MM-dd')) to $($ToDate.ToString('yyyy-MM-dd')) (end exclusive).",
    '',"Successful entry orders: $($trades.Count). Active calendar weeks: $active / $($weeks.Count).",
    '', 'Generated every-tick EURUSD M5 test, default v1.10 strategy inputs, configured broker UTC+2. News is bypassed in tester mode. These results measure historical activity, not a guarantee of future weekly trades or profitability.',
    '', '| Monday of week | Buys | Sells | Total | Coverage |','| --- | ---: | ---: | ---: | --- |')
foreach($week in $weeks) {
    $coverage=if($week.Partial){'Partial'}else{'Full'}
    $report += "| $($week.Monday.ToString('yyyy-MM-dd')) | $($week.Buy) | $($week.Sell) | $($week.Count) | $coverage |"
}
$report += @('', '## Tester evidence', '', '```text')
$report += @($run | Where-Object {$_ -match 'SessionGuard M5 summary:|final balance|ticks,.*bars generated'})
$report += '```'
Set-Content -LiteralPath $OutputPath -Value $report -Encoding UTF8
Write-Output "Entries=$($trades.Count); active weeks=$active/$($weeks.Count); zero-trade weeks=$(@($weeks | Where-Object {$_.Count -eq 0}).Count)"
