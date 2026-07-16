param(
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
$usbTargets = & $hdc list targets -v |
  Where-Object { $_ -match "\t\tUSB\tConnected\t" }
if (@($usbTargets).Count -ne 1) {
  throw 'Expected exactly one connected USB target.'
}
$target = ($usbTargets -split "\t")[0]

if (-not $SkipInstall) {
  $hap = Join-Path $projectRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
  if (-not (Test-Path $hap)) {
    throw 'The signed HAP is missing. Run scripts/build.ps1 first.'
  }
  & $hdc -t $target install -r $hap | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "HAP install failed with exit code $LASTEXITCODE"
  }
}

$startOutput = (& $hdc -t $target shell aa start -b io.github.tailscaleohos -a EntryAbility 2>&1) -join "`n"
if ($startOutput.Contains('device screen is locked')) {
  throw 'The device screen is locked. Unlock it before running the UI probe.'
}
if ($LASTEXITCODE -ne 0 -or -not $startOutput.Contains('start ability successfully')) {
  throw "Ability start failed: $startOutput"
}
Start-Sleep -Seconds 4

$remote = '/data/local/tmp/tailscaleohos-user-ui.json'
$local = Join-Path $projectRoot '.hvigor\outputs\user-ui-probe.json'
try {
  New-Item -ItemType Directory -Force -Path (Split-Path $local) | Out-Null
  function Receive-Layout {
    & $hdc -t $target shell uitest dumpLayout -p $remote | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Layout capture failed with exit code $LASTEXITCODE"
    }
    & $hdc -t $target file recv $remote $local | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Layout receive failed with exit code $LASTEXITCODE"
    }
    return Get-Content -Raw -Encoding UTF8 $local
  }

  function Get-NodeCenter([string]$Layout, [string]$Id) {
    $match = [regex]::Match(
      $Layout,
      'id":"' + [regex]::Escape($Id) +
        '".{0,1800}?origBounds":"\[(\d+),(\d+)\]\[(\d+),(\d+)\]"'
    )
    if (-not $match.Success) {
      throw "Could not resolve node bounds: $Id"
    }
    return [pscustomobject]@{
      X = [int](([int]$match.Groups[1].Value + [int]$match.Groups[3].Value) / 2)
      Y = [int](([int]$match.Groups[2].Value + [int]$match.Groups[4].Value) / 2)
    }
  }

  # HdsTabs may restore the last selected page while the app process remains
  # alive. Select Home explicitly so the probe is independent of prior UI state.
  $initialLayout = Receive-Layout
  $homeTab = Get-NodeCenter $initialLayout 'tab-home'
  & $hdc -t $target shell uitest uiInput click $homeTab.X $homeTab.Y | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw 'Home tab tap failed.'
  }
  Start-Sleep -Milliseconds 700
  $homeLayout = Receive-Layout
  # Control IDs are unique tokens in both the JSON and XML dumpLayout formats.
  # Matching only the token keeps this probe compatible with either format.
  $appVisible = $homeLayout.Contains('smoke-title')
  $connected = $homeLayout.Contains('vpn-stop')
  $authenticated = $homeLayout.Contains('peer-summary')
  $homeTabVisible = $homeLayout.Contains('tab-home')
  $settingsTabVisible = $homeLayout.Contains('tab-settings')
  $exitNodeOnHome = $homeLayout.Contains('exit-node-status')
  $routeToggleOnHome = $homeLayout.Contains('route-all-toggle')
  $dnsToggleOnHome = $homeLayout.Contains('tailscale-dns-toggle')
  $lanToggleOnHome = $homeLayout.Contains('exit-node-lan-toggle')

  $settingsTab = Get-NodeCenter $homeLayout 'tab-settings'
  & $hdc -t $target shell uitest uiInput click $settingsTab.X $settingsTab.Y | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw 'Settings tab tap failed.'
  }
  Start-Sleep -Milliseconds 700
  $settingsLayout = Receive-Layout

  # The floating tab bar intentionally overlays the scroll edge. Capture a
  # second viewport so off-screen About/diagnostics content is also verified.
  $swipeStartY = [Math]::Max(900, $settingsTab.Y - 420)
  & $hdc -t $target shell uitest uiInput swipe $settingsTab.X $swipeStartY $settingsTab.X 520 600 | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw 'Settings scroll failed.'
  }
  Start-Sleep -Milliseconds 700
  $settingsLowerLayout = Receive-Layout
  $settingsAllLayout = $settingsLayout + $settingsLowerLayout
  $authenticated = $authenticated -or $settingsAllLayout.Contains('account-display-name')

  $logoutVisible = $settingsAllLayout.Contains('logout-open')
  $autoStartControlPresent = $settingsAllLayout.Contains('auto-connect-toggle')
  $settingsVisible = $settingsAllLayout.Contains('settings-page-title')
  $engineeringMenuVisible = $settingsAllLayout.Contains('diagnostics-toggle')
  $glowSettingsVisible = $settingsAllLayout.Contains('glow-settings') -and
    $settingsAllLayout.Contains('glow-select')
  $networkPanelOnSettings = $settingsAllLayout.Contains('network-settings-panel')
  $appVersionVisible = $settingsAllLayout.Contains('app-version')
  $tailscaleVersionVisible = $settingsAllLayout.Contains('tailscale-version')
  $routeToggleOnSettings = $settingsAllLayout.Contains('route-all-toggle')
  $dnsToggleOnSettings = $settingsAllLayout.Contains('tailscale-dns-toggle')
  $lanToggleOnSettings = $settingsAllLayout.Contains('exit-node-lan-toggle')
  $safeAccountState = -not ($connected -and $logoutVisible)
  $networkControlsAbsentFromHome = -not (
    $routeToggleOnHome -or $dnsToggleOnHome -or $lanToggleOnHome)
  $safeSettingsConnectionState = if ($connected) {
    -not ($routeToggleOnSettings -or $dnsToggleOnSettings -or $lanToggleOnSettings)
  } elseif ($authenticated) {
    $routeToggleOnSettings -and $dnsToggleOnSettings -and $lanToggleOnSettings
  } else {
    -not ($routeToggleOnSettings -or $dnsToggleOnSettings -or $lanToggleOnSettings)
  }

  [pscustomobject]@{
    Result = if ($appVisible -and $homeTabVisible -and $settingsTabVisible -and
      $settingsVisible -and $glowSettingsVisible -and $engineeringMenuVisible -and
      $exitNodeOnHome -and $safeAccountState -and $networkControlsAbsentFromHome -and
      $networkPanelOnSettings -and $safeSettingsConnectionState -and $appVersionVisible -and
      $tailscaleVersionVisible -and -not $autoStartControlPresent) {
      'passed'
    } else {
      'needs-attention'
    }
    AppVisible = $appVisible
    Connected = $connected
    SettingsViewVisible = $settingsVisible
    Authenticated = $authenticated
    ExitNodeOnHome = $exitNodeOnHome
    RouteToggleOnHome = $routeToggleOnHome
    TailscaleDNSToggleOnHome = $dnsToggleOnHome
    ExitNodeLANToggleOnHome = $lanToggleOnHome
    NetworkControlsAbsentFromHome = $networkControlsAbsentFromHome
    NetworkPanelOnSettings = $networkPanelOnSettings
    SettingsSafeForConnectionState = $safeSettingsConnectionState
    HomeTabVisible = $homeTabVisible
    SettingsTabVisible = $settingsTabVisible
    GlowSettingsVisible = $glowSettingsVisible
    AppVersionVisible = $appVersionVisible
    TailscaleVersionVisible = $tailscaleVersionVisible
    EngineeringMenuOnSettings = $engineeringMenuVisible
    PeerViewOnHome = $homeLayout.Contains('peer-summary')
    LogoutVisible = $logoutVisible
    LogoutHiddenWhileConnected = $safeAccountState
    AutoStartControlAbsent = -not $autoStartControlPresent
  }
} finally {
  & $hdc -t $target shell rm -f $remote | Out-Null
  if (Test-Path $local) {
    Remove-Item -LiteralPath $local -Force
  }
}
