param([string]$QaDirectory=(Join-Path $env:TEMP 'SessionGuardM5-Startup-QA'))
$ErrorActionPreference='Stop'
$variants=@(
 @{Name='baseline';Extra=@()},
 @{Name='strong_close';Extra=@('InpStrongRejectionClose=true')},
 @{Name='trend_veto';Extra=@('InpOpposingTrendVeto=true')},
 @{Name='fixed_exits';Extra=@('InpTrailing=false')},
 @{Name='new_york';Extra=@('InpEnableLondon=false')}
)
$template=[IO.File]::ReadAllText((Join-Path $QaDirectory 'reversal.ini'))
$template=$template.Replace('Model=0','Model=4').Replace('[Tester]',"[Tester]`r`nExecutionMode=100")
foreach($variant in $variants) {
 $name=$variant.Name
 $settings=@('InpServerUTCOffsetHours=0','InpAutoServerUTC=false','InpNewsFilter=false',
 'InpSweepLookback=6','InpUseTrendFilter=false','InpUseCandleFilter=false','InpUsePivotFilter=false',
 'InpStrongRejectionClose=false','InpOpposingTrendVeto=false','InpEnableLondon=true','InpEnableNewYork=true','InpTrailing=true')
 foreach($line in $variant.Extra){$key=($line -split '=')[0];$settings=@($settings | Where-Object {$_ -notlike "$key=*"})+$line}
 $setPath=Join-Path $QaDirectory "MQL5\Profiles\Tester\experiment_$name.set"
 [IO.File]::WriteAllLines($setPath,$settings)
 $config=$template.Replace('Report=startup-report',"Report=experiment_$name").Replace('[Tester]',"[Tester]`r`nExpertParameters=experiment_$name.set")
 $configPath=Join-Path $QaDirectory "experiment_$name.ini"
 [IO.File]::WriteAllText($configPath,$config)
 Write-Output "Starting $name (real ticks, UTC+0, 100ms delay)"
 $existing=@(Get-Process terminal64 -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq (Join-Path $QaDirectory 'terminal64.exe')})
 if($existing.Count -eq 0) {
  $process=Start-Process (Join-Path $QaDirectory 'terminal64.exe') -ArgumentList "/portable /config:experiment_$name.ini" -WorkingDirectory $QaDirectory -WindowStyle Hidden -PassThru
 }
 $report=Join-Path $QaDirectory "experiment_$name.htm"
 $deadline=(Get-Date).AddMinutes(30)
 do {
  Start-Sleep -Seconds 2
  $running=@(Get-Process terminal64 -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq (Join-Path $QaDirectory 'terminal64.exe')})
  if((Get-Date) -gt $deadline){throw "Timed out waiting for $name"}
 } while($running.Count -gt 0)
 if(!(Test-Path -LiteralPath $report)){throw "No report for $name"}
 Write-Output "Completed $name"
}
