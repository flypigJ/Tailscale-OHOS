param(
  [string]$DeviceId = '7FE0226121003033',
  [switch]$SkipInstall,
  [string]$ExpectedHapSha256,
  [switch]$ConnectForReadOnlyProbe,
  [switch]$PreviewFolderDialog,
  [switch]$RestoreDisconnectedAfterProbe
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hdc-command-result.ps1')
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$hdcPath = 'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
$bundleName = 'io.github.tailscaleohos'
$evidenceRoot = Join-Path $projectRoot ('artifacts\ui-device-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $evidenceRoot | Out-Null
$remoteLayout = '/data/local/tmp/mesh-file-lifecycle-layout.json'
$appStarted = $false
$restoreDisconnected = [bool]$RestoreDisconnectedAfterProbe
$connectionReady = $false
$summary = $null
$uiLogProcess = $null
$packageLogProcess = $null
$folderDialogPreview = 'NOT_RUN'

function Invoke-Hdc([string[]]$Arguments) {
  $output = (& $hdcPath -t $DeviceId @Arguments 2>&1) -join "`n"
  Assert-HdcCommandSucceeded -ExitCode $LASTEXITCODE -Output $output -Operation $Arguments[0]
  return $output
}

function Read-Attributes($Node) {
  if ($null -ne $Node.attributes) { $Node.attributes }
  foreach ($child in $Node.children) { Read-Attributes $child }
}

function Capture-Layout([string]$Name) {
  $null = Invoke-Hdc @('shell', 'uitest', 'dumpLayout', '-p', $remoteLayout)
  $localLayout = Join-Path $evidenceRoot ($Name + '.json')
  $null = Invoke-Hdc @('file', 'recv', $remoteLayout, $localLayout)
  return @(Read-Attributes (Get-Content -LiteralPath $localLayout -Raw -Encoding utf8 | ConvertFrom-Json))
}

function Tap-Node($Nodes, [string]$Id) {
  $node = $Nodes | Where-Object { $_.id -eq $Id } | Select-Object -First 1
  if ($null -eq $node) { throw "Required UI node is unavailable: $Id" }
  $bounds = if ($node.origBounds) { $node.origBounds } else { $node.bounds }
  $match = [regex]::Match($bounds, '\[(\d+),(\d+)\]\[(\d+),(\d+)\]')
  if (-not $match.Success) { throw "UI node bounds are unavailable: $Id" }
  $x = [int](([int]$match.Groups[1].Value + [int]$match.Groups[3].Value) / 2)
  $y = [int](([int]$match.Groups[2].Value + [int]$match.Groups[4].Value) / 2)
  $null = Invoke-Hdc @('shell', 'uitest', 'uiInput', 'click', "$x", "$y")
}

function Assert-UiProcess([string]$ExpectedPid) {
  $currentUiPid = (Invoke-Hdc @('shell', 'pidof', $bundleName)).Trim()
  if ($currentUiPid -ne $ExpectedPid) {
    @{ UiPidBeforeConnect = $ExpectedPid; UiPidAfterConnect = $currentUiPid } | ConvertTo-Json |
      Set-Content -LiteralPath (Join-Path $evidenceRoot 'process-changed.json') -Encoding utf8
    throw 'The UI process exited or changed during connection; inspect the captured live log.'
  }
}

function Preview-ReadOnlyFolderDialog($Nodes) {
  $current = $Nodes
  $result = 'SHARE_UNAVAILABLE'
  # Only directory levels: tailnet -> known machine -> known share. Never tap files.
  for ($depth = 0; $depth -lt 3; $depth++) {
    $entries = @($current | Where-Object { $_.id -like 'taildrive-entry-*' })
    $entry = if ($depth -eq 0) { $entries | Select-Object -First 1 }
      elseif ($depth -eq 1) { $entries | Where-Object { $_.id -match '^taildrive-entry-magicbook-pro-14([.]|$)' } | Select-Object -First 1 }
      else { $entries | Where-Object { $_.id -eq 'taildrive-entry-downloads' } | Select-Object -First 1 }
    if (-not $entry) { break }
    Tap-Node $current $entry.id
    Start-Sleep -Milliseconds 700
    $current = Capture-Layout "folder-preview-level-$depth"
    Assert-UiProcess $uiPid
    for ($attempt = 0; $attempt -lt 3 -and ($current | Where-Object { $_.id -eq 'taildrive-refresh-loading' }); $attempt++) {
      Start-Sleep -Milliseconds 500
      $current = Capture-Layout "folder-preview-level-$depth-wait-$attempt"
    }
    if ($depth -eq 2) {
      $create = $current | Where-Object { $_.id -eq 'taildrive-new-folder' -and "$($_.enabled)" -eq 'true' } | Select-Object -First 1
      if ($create) {
        Tap-Node $current 'taildrive-new-folder'
        $dialog = Capture-Layout 'folder-preview-dialog'
        if (-not ($dialog | Where-Object { $_.id -eq 'taildrive-folder-dialog-input' })) {
          throw 'New-folder action did not expose its input; no authorization is accepted.'
        }
        # No text entry or confirm action: Back cancels the modal without a remote mutation.
        $null = Invoke-Hdc @('shell', 'uitest', 'uiInput', 'keyEvent', 'Back')
        $current = Capture-Layout 'folder-preview-cancelled'
        if ($current | Where-Object { $_.id -eq 'taildrive-folder-dialog' }) {
          # A focused TextInput may consume the first Back to hide its keyboard.
          $null = Invoke-Hdc @('shell', 'uitest', 'uiInput', 'keyEvent', 'Back')
          $current = Capture-Layout 'folder-preview-cancelled-after-keyboard'
        }
        if ($current | Where-Object { $_.id -eq 'taildrive-folder-dialog' }) { throw 'Folder dialog did not close on Back.' }
        $result = 'OPEN_CANCEL_PASSED'
      }
    }
  }
  for ($depth = 0; $depth -lt 3; $depth++) {
    $back = $current | Where-Object { $_.id -eq 'taildrive-back' -and "$($_.enabled)" -eq 'true' } | Select-Object -First 1
    if (-not $back) { break }
    Tap-Node $current 'taildrive-back'
    Start-Sleep -Milliseconds 700
    $current = Capture-Layout "folder-preview-return-$depth"
  }
  $script:folderDialogPreview = $result
  return $current
}

try {
  if (-not $SkipInstall) {
    $hapPath = Join-Path $projectRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
    $hash = (Get-FileHash -LiteralPath $hapPath -Algorithm SHA256).Hash
    if (-not $ExpectedHapSha256 -or $hash -ne $ExpectedHapSha256) {
      throw 'Supply the verified candidate HAP SHA-256 before installation.'
    }
    $installResult = Invoke-Hdc @('install', '-r', $hapPath)
    if ($installResult -notmatch 'install bundle successfully') { throw 'Data-preserving installation did not report success.' }
  }
  $startResult = Invoke-Hdc @('shell', 'aa', 'start', '-b', $bundleName, '-a', 'EntryAbility')
  $startResult | Set-Content -LiteralPath (Join-Path $evidenceRoot 'entry-start.log') -Encoding utf8
  if ($startResult -notmatch 'start ability successfully') { throw 'EntryAbility did not start successfully.' }
  $appStarted = $true
  Start-Sleep -Seconds 1
  $initial = Capture-Layout 'initial'
  if (($initial | Where-Object { $_.id -eq 'update-changelog-navigation' }) -or
    -not ($initial | Where-Object { $_.id -eq 'tab-files' })) {
    # Dismiss only the temporary initial sheet, using the app's existing Back handling.
    $null = Invoke-Hdc @('shell', 'uitest', 'uiInput', 'keyEvent', 'Back')
    Start-Sleep -Milliseconds 400
    $initial = Capture-Layout 'initial-after-back'
  }
  Tap-Node $initial 'tab-files'
  Start-Sleep -Milliseconds 700
  $files = Capture-Layout 'files-before-background'
  if (-not ($files | Where-Object { $_.id -eq 'taildrive-browser' })) {
    throw 'File viewport is not in the foreground; do not count lifecycle assertions as passed.'
  }
  if ($ConnectForReadOnlyProbe) {
    $uiPid = (Invoke-Hdc @('shell', 'pidof', $bundleName)).Trim()
    if ($uiPid -notmatch '^\d+$') { throw 'The UI process is unavailable before connection.' }
    $uiLogProcess = Start-Process -FilePath $hdcPath `
      -ArgumentList @('-t', $DeviceId, 'shell', 'hilog', '-P', $uiPid) `
      -RedirectStandardOutput (Join-Path $evidenceRoot 'ui-process-live.log') `
      -RedirectStandardError (Join-Path $evidenceRoot 'ui-process-live.stderr') `
      -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 200
    if ($uiLogProcess.HasExited) { throw 'The live UI log helper exited before connection.' }
    $packageLogProcess = Start-Process -FilePath $hdcPath `
      -ArgumentList @('-t', $DeviceId, 'shell', 'hilog', '-e', 'io[.]github[.]tailscaleohos') `
      -RedirectStandardOutput (Join-Path $evidenceRoot 'package-events-live.log') `
      -RedirectStandardError (Join-Path $evidenceRoot 'package-events-live.stderr') `
      -WindowStyle Hidden -PassThru
    @{ UiPidBeforeConnect = $uiPid } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidenceRoot 'process-before.json') -Encoding utf8
    $connectionAction = $files | Where-Object { $_.id -eq 'taildrive-connect-action' } | Select-Object -First 1
    if ($connectionAction) {
      $restoreDisconnected = $true
      for ($attempt = 0; $attempt -lt 8 -and "$($connectionAction.enabled)" -ne 'true'; $attempt++) {
        Start-Sleep -Milliseconds 600
        $files = Capture-Layout "connection-ready-$attempt"
        Assert-UiProcess $uiPid
        if ($files | Where-Object { $_.id -eq 'taildrive-refresh' }) { break }
        $connectionAction = $files | Where-Object { $_.id -eq 'taildrive-connect-action' } | Select-Object -First 1
      }
      $alreadyConnected = [bool]($files | Where-Object { $_.id -eq 'taildrive-refresh' })
      if (-not $alreadyConnected -and (-not $connectionAction -or "$($connectionAction.enabled)" -ne 'true')) {
        throw 'The app connection action is unavailable; do not bypass its disabled state.'
      }
      if (-not $alreadyConnected -and $connectionAction.text -notmatch ([regex]::Unescape('\u8fde\u63a5 Tailscale|Connect Tailscale'))) {
        throw 'An existing signed-in account is required; this probe does not perform login.'
      }
      if (-not $alreadyConnected) { Tap-Node $files 'taildrive-connect-action' }
      for ($attempt = 0; $attempt -lt 10; $attempt++) {
        Start-Sleep -Milliseconds 600
        $files = Capture-Layout "connect-$attempt"
        Assert-UiProcess $uiPid
        if ($files | Where-Object { $_.id -eq 'taildrive-refresh' }) { break }
      }
    }
    if (-not ($files | Where-Object { $_.id -eq 'taildrive-refresh' })) {
      throw 'Connection did not expose the file refresh control; no system authorization is accepted by this probe.'
    }
    $connectionReady = $true
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
      if (-not ($files | Where-Object { $_.id -eq 'taildrive-refresh-loading' })) { break }
      Start-Sleep -Milliseconds 600
      $files = Capture-Layout "initial-list-$attempt"
    }
    Tap-Node $files 'taildrive-refresh'
    Start-Sleep -Milliseconds 600
    $files = Capture-Layout 'manual-refresh'
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
      if (-not ($files | Where-Object { $_.id -eq 'taildrive-refresh-loading' })) { break }
      Start-Sleep -Milliseconds 600
      $files = Capture-Layout "manual-refresh-$attempt"
    }
    if ($PreviewFolderDialog) { $files = @(Preview-ReadOnlyFolderDialog $files) }
  }
  $pidBefore = (Invoke-Hdc @('shell', 'pidof', $bundleName)).Trim()
  $null = Invoke-Hdc @('shell', 'uitest', 'uiInput', 'keyEvent', 'Home')
  Start-Sleep -Seconds 1
  $null = Invoke-Hdc @('shell', 'aa', 'start', '-b', $bundleName, '-a', 'EntryAbility')
  Start-Sleep -Seconds 1
  $resumed = Capture-Layout 'files-after-background'
  $pidAfter = (Invoke-Hdc @('shell', 'pidof', $bundleName)).Trim()
  $summary = [ordered]@{
    Result = 'partial'
    SameProcessAfterBackground = ($pidBefore -match '^\d+$' -and $pidBefore -eq $pidAfter)
    FilesVisibleBeforeBackground = [bool]($files | Where-Object { $_.id -eq 'taildrive-browser' })
    FilesVisibleAfterBackground = [bool]($resumed | Where-Object { $_.id -eq 'taildrive-browser' })
    RefreshControlVisible = [bool]($resumed | Where-Object { $_.id -eq 'taildrive-refresh' })
    ConnectionActionVisible = [bool]($resumed | Where-Object { $_.id -eq 'taildrive-connect-action' })
    ConnectedReadOnlyProbe = [bool]$ConnectForReadOnlyProbe
    ManualRefreshSettled = ($ConnectForReadOnlyProbe -and -not [bool]($files | Where-Object { $_.id -eq 'taildrive-refresh-loading' }))
    VisibleEntryCount = @($files | Where-Object { $_.id -like 'taildrive-entry-*' }).Count
    RefreshRetryVisible = [bool]($files | Where-Object { $_.id -eq 'taildrive-empty-retry' -or $_.id -eq 'taildrive-operation-retry' })
    ForegroundRefreshSettled = -not [bool]($resumed | Where-Object { $_.id -eq 'taildrive-refresh-loading' })
    ConnectionStateRestored = 'unchanged'
    DirectoryRaceOnDevice = 'NOT_RUN'
    FullVisualReview = 'NOT_RUN'
    FolderDialogPreview = $folderDialogPreview
    RemoteFolderMutation = 'NOT_RUN'
  }
  if ($summary.SameProcessAfterBackground -and $summary.FilesVisibleBeforeBackground -and $summary.FilesVisibleAfterBackground) {
    $summary.Result = 'lifecycle-smoke-passed'
    if ($ConnectForReadOnlyProbe) {
      $summary.Result = 'connected-readonly-partial'
      if ($summary.ManualRefreshSettled -and $summary.ForegroundRefreshSettled -and
        $summary.RefreshControlVisible -and -not $summary.RefreshRetryVisible -and -not $summary.ConnectionActionVisible) {
        $summary.Result = 'connected-root-smoke-passed'
      }
    }
  }
} finally {
  if ($appStarted) {
    try {
      if ($restoreDisconnected) {
        $null = Invoke-Hdc @('shell', 'aa', 'start', '-b', $bundleName, '-a', 'EntryAbility')
        if (-not $connectionReady) {
          # Cancel a possible system consent dialog before locating app controls.
          $null = Invoke-Hdc @('shell', 'uitest', 'uiInput', 'keyEvent', 'Back')
          $null = Invoke-Hdc @('shell', 'aa', 'start', '-b', $bundleName, '-a', 'EntryAbility')
        }
        $restoreLayout = Capture-Layout 'restore-start'
        # Back only dismisses a temporary modal; no authorization button is tapped.
        if (($restoreLayout | Where-Object { $_.id -eq 'update-changelog-navigation' }) -or
          -not ($restoreLayout | Where-Object { $_.id -eq 'tab-home' })) {
          $null = Invoke-Hdc @('shell', 'uitest', 'uiInput', 'keyEvent', 'Back')
          $restoreLayout = Capture-Layout 'restore-after-back'
        }
        Tap-Node $restoreLayout 'tab-home'
        Start-Sleep -Milliseconds 500
        $restoreLayout = Capture-Layout 'restore-home'
        $restored = $false
        $idleSamples = 0
        for ($attempt = 0; $attempt -lt 16; $attempt++) {
          if ($restoreLayout | Where-Object { $_.id -eq 'vpn-stop' }) {
            Tap-Node $restoreLayout 'vpn-stop'
            $idleSamples = 0
          }
          Start-Sleep -Milliseconds 500
          $restoreLayout = Capture-Layout "restore-disconnected-$attempt"
          if (($restoreLayout | Where-Object { $_.id -eq 'vpn-connect' }) -and
            -not ($restoreLayout | Where-Object { $_.id -eq 'backend-starting' })) {
            $idleSamples++
          } else { $idleSamples = 0 }
          if ($idleSamples -ge 3) { $restored = $true; break }
        }
        @{ RestoredDisconnected = $restored } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidenceRoot 'restore.json') -Encoding utf8
        if ($summary) { $summary.ConnectionStateRestored = $restored }
        if (-not $restored) {
          if ($summary) { $summary.Result = 'restore-failed' }
          throw 'The original disconnected state could not be verified.'
        }
      }
    } finally {
      try {
        $null = Invoke-Hdc @('shell', 'uitest', 'uiInput', 'keyEvent', 'Home')
        if ($summary) { $summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidenceRoot 'summary.json') -Encoding utf8 }
      } finally {
        foreach ($logProcess in @($uiLogProcess, $packageLogProcess)) {
          if ($logProcess -and -not $logProcess.HasExited) { Stop-Process -InputObject $logProcess }
        }
      }
    }
  }
}
if ($summary) { $summary | ConvertTo-Json -Compress }
Write-Output "Evidence: $evidenceRoot"
