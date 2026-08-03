param(
  [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$devecoHome = @($env:DEVECO_STUDIO_HOME, $env:DEVECO_HOME, 'C:\Program Files\Huawei\DevEco Studio') |
  Where-Object { $_ -and (Test-Path (Join-Path $_ 'product-info.json')) } | Select-Object -First 1
if (-not $devecoHome) { throw 'DevEco Studio was not found.' }
$hdc = Join-Path $devecoHome 'sdk\default\openharmony\toolchains\hdc.exe'
$usbTargets = @(& $hdc list targets -v | Where-Object { $_ -match "`t`tUSB`tConnected`t" })
if ($usbTargets.Count -ne 1) { throw 'Expected exactly one connected USB target.' }
$target = ($usbTargets[0] -split "`t")[0]
$bundleName = 'io.github.tailscaleohos'

if (-not $SkipInstall) {
  $hap = Join-Path $projectRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
  if (-not (Test-Path $hap)) { throw 'The signed HAP is missing. Run scripts/build.ps1 first.' }
  & $hdc -t $target install -r $hap | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "HAP install failed with exit code $LASTEXITCODE" }
}

$remote = '/data/local/tmp/tailscaleohos-m7-app-shell.json'
$local = Join-Path $projectRoot '.hvigor\outputs\m7-app-shell.json'
function Receive-Layout {
  & $hdc -t $target shell uitest dumpLayout -p $remote | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Layout capture failed.' }
  & $hdc -t $target file recv $remote $local | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Layout receive failed.' }
  return Get-Content -Raw -Encoding utf8 $local
}
function Get-NodeCenter([string]$layout, [string]$id) {
  $match = [regex]::Match($layout, 'id":"' + [regex]::Escape($id) +
    '".{0,1800}?origBounds":"\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')
  if (-not $match.Success) { throw "Could not resolve node bounds: $id" }
  return [pscustomobject]@{
    X = [int](([int]$match.Groups[1].Value + [int]$match.Groups[3].Value) / 2)
    Y = [int](([int]$match.Groups[2].Value + [int]$match.Groups[4].Value) / 2)
  }
}
function Start-NotificationWant([string]$action, [bool]$openInbox) {
  & $hdc -t $target shell aa start -b $bundleName -a EntryAbility `
    --pb taildropOpenInbox $openInbox --ps taildropNotificationAction $action `
    --ps taildropNotificationFileName 'm7-notification.txt' --pi taildropNotificationFileSize 1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Could not start $action Want." }
}

try {
  New-Item -ItemType Directory -Force -Path (Split-Path $local) | Out-Null
  & $hdc -t $target shell aa force-stop $bundleName | Out-Null
  Start-NotificationWant 'later' $true
  Start-Sleep -Seconds 2
  $coldPid = ((& $hdc -t $target shell pidof $bundleName) -join '').Trim()
  $coldLayout = Receive-Layout
  $coldOpenRouted = $coldLayout.Contains('hdsTabs') -and $coldLayout.Contains('transfer-page-title')
  Start-NotificationWant 'later' $true
  Start-Sleep -Seconds 1
  $hotPid = ((& $hdc -t $target shell pidof $bundleName) -join '').Trim()
  $hotLayout = Receive-Layout
  $duplicateWantStable = $coldPid -eq $hotPid -and $hotLayout.Contains('transfer-page-title')
  $homeTab = Get-NodeCenter $hotLayout 'tab-home'
  & $hdc -t $target shell uitest uiInput click $homeTab.X $homeTab.Y | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Home tab tap failed.' }
  Start-Sleep -Milliseconds 700
  $homeLayout = Receive-Layout
  Start-NotificationWant 'delete' $false
  Start-Sleep -Milliseconds 700
  $invalidLayout = Receive-Layout
  $invalidWantRejected = $homeLayout.Contains('exit-node-status') -and
    $invalidLayout.Contains('exit-node-status')
  if (-not ($coldPid -match '^\d+$' -and $coldOpenRouted -and $duplicateWantStable -and $invalidWantRejected)) {
    throw "M7 AppShell Want lifecycle assertions failed: cold=$coldOpenRouted duplicate=$duplicateWantStable invalid=$invalidWantRejected coldPid=$coldPid hotPid=$hotPid"
  }
  [pscustomobject]@{
    Result = 'passed'
    ColdStartOpen = $coldOpenRouted
    HotRepeatedWant = $duplicateWantStable
    InvalidWantRejected = $invalidWantRejected
  }
} finally {
  & $hdc -t $target shell rm -f $remote | Out-Null
  if (Test-Path $local) { Remove-Item -LiteralPath $local -Force }
}
