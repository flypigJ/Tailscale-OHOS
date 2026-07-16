param(
  [int]$AppUserId = 100
)

$ErrorActionPreference = 'Stop'

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
$bundleName = 'io.github.tailscaleohos'
$filesDir = "/data/app/el2/$AppUserId/base/$bundleName/haps/entry/files"
$vpnStatusPath = "$filesDir/vpn-probe-status.txt"

function Read-BundleFile([string]$Path) {
  $text = (& $hdc -t $target shell -b $bundleName cat $Path) -join ''
  if ($LASTEXITCODE -ne 0) {
    throw "Could not read application diagnostic state: $Path"
  }
  return $text
}

function Get-PacketCounts([string]$Status) {
  $match = [regex]::Match($Status, 'tunRead=(\d+) \| tunWrite=(\d+)')
  if (-not $match.Success) {
    throw 'VPN status does not contain TUN packet counters.'
  }
  return [PSCustomObject]@{
    Read = [uint64]$match.Groups[1].Value
    Write = [uint64]$match.Groups[2].Value
  }
}

$beforeStatus = Read-BundleFile $vpnStatusPath
if (-not ($beforeStatus.Contains('state=Running') -and
    $beforeStatus.Contains('tun=true') -and
    $beforeStatus.Contains('exitNode=true'))) {
  throw 'Connect an exit node in the app before running this probe.'
}
$before = Get-PacketCounts $beforeStatus

# Use a literal public IP to avoid counting MagicDNS or resolver traffic as
# proof of a default route. The nonce prevents the browser from reusing a page.
$probeNonce = Get-Date -Format 'yyyyMMddHHmmssfff'
& $hdc -t $target shell aa start -A ohos.want.action.viewData `
  -U "https://1.1.1.1/cdn-cgi/trace?exitprobe=$probeNonce" | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw 'Could not launch the public exit-node probe.'
}
Start-Sleep -Seconds 8

$afterStatus = Read-BundleFile $vpnStatusPath
$after = Get-PacketCounts $afterStatus
if ($after.Read -le $before.Read -or $after.Write -le $before.Write) {
  throw 'Public IP traffic did not increase both TUN packet counters.'
}

[PSCustomObject]@{
  Result = 'passed'
  ExitNodeSelected = $afterStatus.Contains('exitNode=true')
  BackendRunning = $afterStatus.Contains('state=Running')
  ExternalTun = $afterStatus.Contains('tun=true')
  TunReadDelta = $after.Read - $before.Read
  TunWriteDelta = $after.Write - $before.Write
}
