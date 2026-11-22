#requires -Version 5.1
param([ValidateSet('K7','D1','D2','D3')][string]$Milestone='K7')
$ErrorActionPreference='Stop'
$project=(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$out=Join-Path ([IO.Path]::GetTempPath()) ("mesharc-go-host-"+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $out -Force|Out-Null
function WslPath([string]$Path){$p=[IO.Path]::GetFullPath($Path);return '/mnt/'+$p.Substring(0,1).ToLowerInvariant()+'/'+$p.Substring(3).Replace('\','/')}
$lock=Get-Content -Raw -LiteralPath (Join-Path $project 'native/engine-lock.json')|ConvertFrom-Json
$bridge=Join-Path $project 'native/go_bridge';$hostGo=Join-Path $project 'artifacts/kernel-k2/linux-host/go'
if((Get-Content -LiteralPath (Join-Path $hostGo 'VERSION') -TotalCount 1).Trim() -cne 'go1.27.3'){throw 'Go 1.27.3 host compiler required'}
$sourceFiles=@(Get-ChildItem -LiteralPath $bridge -File -Filter '*.go')+@(Get-ChildItem -LiteralPath (Join-Path $bridge 'vpnroute') -File -Filter '*.go')+@(Get-Item -LiteralPath (Join-Path $bridge 'go.mod'),(Join-Path $bridge 'go.sum'))
$sourceEvidence=@($sourceFiles|ForEach-Object{@{path=$_.FullName;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}})
$rawMod=Get-Content -Raw -LiteralPath (Join-Path $bridge 'go.mod')
if($rawMod -notmatch '(?m)^replace tailscale\.com => .+$'){throw 'Missing tailscale.com replace directive in native/go_bridge/go.mod'}
$vendorReplacement=("replace tailscale.com => $(WslPath (Join-Path $project $lock.vendorRoot))").Replace('$','$$')
$mod=[regex]::Replace($rawMod,'(?m)^replace tailscale\.com => .+$',$vendorReplacement)
[IO.File]::WriteAllText((Join-Path $out 'test.mod'),$mod,(New-Object System.Text.UTF8Encoding($false)))
Copy-Item -LiteralPath (Join-Path $bridge 'go.sum') -Destination (Join-Path $out 'test.sum')
$envArgs=@("GOROOT=$(WslPath $hostGo)",'GOENV=off','GOTOOLCHAIN=local','GOWORK=off','GOOS=linux','GOARCH=amd64','CGO_ENABLED=0','GOPROXY=off','GOSUMDB=off','TS_NO_LOGS_NO_SUPPORT=true',
  "GOMODCACHE=$(WslPath (Join-Path $project 'artifacts/kernel-k2/module-cache'))","GOCACHE=$(WslPath (Join-Path $project 'artifacts/kernel-k2/linux-cache'))")
if($env:MESHARC_TEST_SUNSHINE_HOST){$envArgs+="MESHARC_TEST_SUNSHINE_HOST=$($env:MESHARC_TEST_SUNSHINE_HOST)"}
$prevOutEncoding=[Console]::OutputEncoding
try {
  [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false)
  & wsl.exe --exec env @envArgs "$(WslPath $hostGo)/bin/go" -C (WslPath $bridge) test -p 2 -mod=readonly "-modfile=$(WslPath (Join-Path $out 'test.mod'))" -count=1 -timeout=180s -json '-ldflags=-X tailscale.com/version.longStamp=1.104.5 -X tailscale.com/version.shortStamp=1.104.5' ./... | Set-Content -LiteralPath (Join-Path $out 'tests.jsonl') -Encoding UTF8
  $code=$LASTEXITCODE
} finally {
  [Console]::OutputEncoding=$prevOutEncoding
}
$events=@(Get-Content -LiteralPath (Join-Path $out 'tests.jsonl') -Encoding UTF8|Where-Object {$_ -and $_.Trim()}|ForEach-Object{$_|ConvertFrom-Json})
$passes=@($events|Where-Object {$_.Action -ceq 'pass' -and $_.Test -and $_.Test -notmatch '/'})
$failures=@($events|Where-Object {$_.Action -ceq 'fail'});$skips=@($events|Where-Object {$_.Action -ceq 'skip'})
$optInSkips=@($skips|Where-Object {-not $env:MESHARC_TEST_SUNSHINE_HOST -and $_.Test -ceq 'TestGameStreamLiveHost'})
$unexpectedSkips=@($skips|Where-Object {$env:MESHARC_TEST_SUNSHINE_HOST -or $_.Test -cne 'TestGameStreamLiveHost'})
$expected=0;foreach($f in @($sourceFiles|Where-Object {$_.Name -like '*_test.go'})){$expected+=[regex]::Matches((Get-Content -Raw -LiteralPath $f.FullName),'(?m)^func Test\w+\(t \*testing\.T\)').Count}
$unchanged=$true;foreach($f in $sourceEvidence){if((Get-FileHash -LiteralPath $f.path).Hash -cne $f.sha256){$unchanged=$false}}
$passed=$code -eq 0 -and $failures.Count -eq 0 -and $unexpectedSkips.Count -eq 0 -and ($passes.Count + $optInSkips.Count) -eq $expected -and $unchanged
@{milestone=$Milestone;passed=$passed;tests=$passes.Count;expectedTests=$expected;failed=$failures.Count;skipped=$skips.Count;optInSkipped=$optInSkips.Count;unexpectedSkipped=$unexpectedSkips.Count;sourceUnchanged=$unchanged;sourceFiles=$sourceEvidence;logSha256=(Get-FileHash -LiteralPath (Join-Path $out 'tests.jsonl')).Hash}|
  ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $out 'report.json') -Encoding UTF8
Write-Host "$Milestone host report: $(Join-Path $out 'report.json')"
if(-not $passed){throw 'K7 host tests failed'}
