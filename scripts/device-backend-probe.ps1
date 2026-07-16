param(
  [string]$ArtifactDir = '',
  [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$devecoHome = @(
  $env:DEVECO_STUDIO_HOME,
  $env:DEVECO_HOME,
  'C:\Program Files\Huawei\DevEco Studio'
) | Where-Object { $_ -and (Test-Path (Join-Path $_ 'product-info.json')) } |
  Select-Object -First 1
if (-not $devecoHome) {
  throw 'DevEco Studio was not found.'
}

$hdc = Join-Path $devecoHome 'sdk\default\openharmony\toolchains\hdc.exe'
$usbTargets = @(& $hdc list targets -v |
  Where-Object { $_ -match "`t`tUSB`tConnected`t" })
if ($usbTargets.Count -ne 1) {
  throw 'Expected exactly one connected USB target.'
}
$target = ($usbTargets[0] -split "`t")[0]

if (-not $ArtifactDir) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $ArtifactDir = Join-Path $projectRoot ".hvigor\outputs\backend-probe-$stamp"
}
New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null

$hap = Join-Path $projectRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
if (-not $SkipInstall) {
  if (-not (Test-Path $hap)) {
    throw 'The signed HAP is missing. Run scripts/build.ps1 first.'
  }
  & $hdc -t $target install -r $hap | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "HAP install failed with exit code $LASTEXITCODE"
  }
}

& $hdc -t $target shell aa start -b io.github.tailscaleohos -a EntryAbility | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "Ability start failed with exit code $LASTEXITCODE"
}
Start-Sleep -Seconds 2

function Receive-Layout([string]$Name) {
  $remote = "/data/local/tmp/tailscaleohos-$Name.json"
  $local = Join-Path $ArtifactDir "$Name.json"
  & $hdc -t $target shell uitest dumpLayout -p $remote | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Layout capture failed: $Name" }
  & $hdc -t $target file recv $remote $local | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Layout receive failed: $Name" }
  & $hdc -t $target shell rm -f $remote | Out-Null
  return $local
}

function Get-NodeCenter([string]$Layout, [string]$Id) {
  $match = [regex]::Match(
    $Layout,
    'id":"' + [regex]::Escape($Id) +
      '".{0,1600}?origBounds":"\[(\d+),(\d+)\]\[(\d+),(\d+)\]"'
  )
  if (-not $match.Success) { throw "Could not resolve node bounds: $Id" }
  $x = [int](([int]$match.Groups[1].Value + [int]$match.Groups[3].Value) / 2)
  $y = [int](([int]$match.Groups[2].Value + [int]$match.Groups[4].Value) / 2)
  return [PSCustomObject]@{ X = $x; Y = $y }
}

function Get-BackendStatus([string]$Layout) {
  $match = [regex]::Match(
    $Layout,
    'id":"backend-status".{0,1000}?text":"([^"]*)"'
  )
  if (-not $match.Success) { throw 'Backend status text was not found.' }
  return $match.Groups[1].Value
}

$beforePath = Receive-Layout 'before'
$before = Get-Content -Raw $beforePath
foreach ($marker in @('backend-start', 'backend-refresh', 'Go go1.24.5', 'openharmony/arm64')) {
  if (-not $before.Contains($marker)) { throw "Baseline marker missing: $marker" }
}

$start = Get-NodeCenter $before 'backend-start'
& $hdc -t $target shell uitest uiInput click $start.X $start.Y | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Backend start tap failed.' }

$status = ''
for ($attempt = 1; $attempt -le 12; $attempt++) {
  Start-Sleep -Seconds 5
  $layoutPath = Receive-Layout "poll-$attempt"
  $layout = Get-Content -Raw $layoutPath
  $status = Get-BackendStatus $layout
  $loginReady = $status.Contains('loginURLReady=true')
  if ($status.Contains('state=Running') -or $status.StartsWith('FAILED') -or
      ($status.Contains('state=NeedsLogin') -and $loginReady)) {
    break
  }

  # Reusing start is intentional: once the singleton exists, backendStart
  # returns its current status without creating another server. This also
  # works if the dedicated refresh button is below the current viewport.
  $statusNode = Get-NodeCenter $layout 'backend-start'
  & $hdc -t $target shell uitest uiInput click $statusNode.X $statusNode.Y | Out-Null
}

$appPid = (& $hdc -t $target shell pidof io.github.tailscaleohos).Trim()
if ($appPid -notmatch '^\d+$') { throw 'The application process exited.' }
if (-not ($status.Contains('state=NeedsLogin') -or $status.Contains('state=Running'))) {
  throw "Backend did not reach a ready state: $status"
}

[PSCustomObject]@{
  Result = 'passed'
  BackendState = if ($status.Contains('state=Running')) { 'Running' } else { 'NeedsLogin' }
  LoginURLReady = $status.Contains('loginURLReady=true')
  TunExpectedlyDisabled = $status.Contains('tun=false')
  ArtifactDir = (Resolve-Path $ArtifactDir).Path
}
