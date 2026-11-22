param(
  [ValidateSet('default', 'release')]
  [string]$Product = 'default',
  [Parameter(Mandatory = $true)]
  [string]$ReadElf
)

# Run immediately after the verified HAP build. Never rebuild a historical
# version merely to manufacture symbols: its Build IDs would be different.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$output = Join-Path $root "entry\build\$Product\outputs\default"
$hapPath = Join-Path $output 'entry-default-signed.hap'
if (-not (Test-Path -LiteralPath $hapPath)) {
  $hapPath = Join-Path $output 'entry-default-unsigned.hap'
}
$hapHash = (Get-FileHash -LiteralPath $hapPath -Algorithm SHA256).Hash.ToLowerInvariant()
$hap = [IO.Compression.ZipFile]::OpenRead($hapPath)
try {
  $reader = [IO.StreamReader]::new($hap.GetEntry('module.json').Open())
  try { $module = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
  if ($module.app.bundleName -ne 'io.github.tailscaleohos' -or
      $module.app.versionName -notmatch '^\d+\.\d+\.\d+$') {
    throw 'Unexpected application identity in HAP.'
  }
  $identity = "$($module.app.versionName)-$($module.app.versionCode)-$Product-$($hapHash.Substring(0, 12))"
  $archiveRoot = Join-Path $root "artifacts\apms\$identity"
  $symbolsRoot = Join-Path $archiveRoot 'symbols'
  $packagedRoot = Join-Path $archiveRoot 'packaged'
  $zipPath = Join-Path $archiveRoot 'apms-symbols.zip'
  if (Test-Path -LiteralPath $zipPath) {
    $saved = Get-Content -LiteralPath (Join-Path $archiveRoot 'manifest.json') -Raw | ConvertFrom-Json
    $mapNow = Join-Path $output 'mapping\sourceMaps.map'
    $unchanged = $saved.hapSha256 -eq $hapHash -and
      $saved.archiveSha256 -eq (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant() -and
      $saved.sourceMapSha256 -eq (Get-FileHash -LiteralPath $mapNow -Algorithm SHA256).Hash.ToLowerInvariant()
    foreach ($library in $saved.libraries) {
      if ($library.file -notin @('libtailscale_go.so', 'libtailscale_ohos.so')) { throw 'Unexpected archive library.' }
      $currentSymbol = Join-Path $root "entry\build\$Product\intermediates\libs\default\arm64-v8a\$($library.file)"
      $unchanged = $unchanged -and $library.symbolSha256 -eq
        (Get-FileHash -LiteralPath $currentSymbol -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    if (-not $unchanged -or $saved.libraries.Count -ne 2) {
      throw "Archive exists but its inputs differ; preserve it for investigation: $zipPath"
    }
    Write-Host "APMS symbol archive unchanged and verified: $zipPath"
    return
  }
  New-Item -ItemType Directory -Force -Path $symbolsRoot, $packagedRoot | Out-Null
  $libraries = @()
  foreach ($name in @('libtailscale_go.so', 'libtailscale_ohos.so')) {
    $entryName = "libs/arm64-v8a/$name"
    $entry = $hap.GetEntry($entryName)
    if (-not $entry) { throw "HAP is missing $entryName" }
    $packagedPath = Join-Path $packagedRoot $name
    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $packagedPath, $true)
    # Hvigor retains the pre-strip libraries here. Access only these exact
    # files; do not search caches or accept a similarly named library.
    $symbolPath = Join-Path $root "entry\build\$Product\intermediates\libs\default\arm64-v8a\$name"
    $packedNotes = (& $ReadElf --notes $packagedPath) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "Cannot inspect packaged $name" }
    $symbolNotes = (& $ReadElf --notes $symbolPath) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "Cannot inspect symbols for $name" }
    $packedId = [regex]::Match($packedNotes, 'Build ID:\s*([a-fA-F0-9]+)').Groups[1].Value
    $symbolId = [regex]::Match($symbolNotes, 'Build ID:\s*([a-fA-F0-9]+)').Groups[1].Value
    if (-not $packedId -or $packedId -ne $symbolId) {
      throw "Missing or mismatched GNU Build ID for $name; no upload archive produced."
    }
    $sections = (& $ReadElf --sections $symbolPath) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $sections -notmatch '\.symtab\s' -or
        $sections -notmatch '\.debug_info\s' -or $sections -notmatch '\.debug_line\s') {
      throw "Full debug symbols are missing for $name; no upload archive produced."
    }
    Copy-Item -LiteralPath $symbolPath -Destination (Join-Path $symbolsRoot $name)
    $libraries += [ordered]@{
      file = $name; buildId = $symbolId
      symbolSha256 = (Get-FileHash -LiteralPath $symbolPath -Algorithm SHA256).Hash.ToLowerInvariant()
      packagedSha256 = (Get-FileHash -LiteralPath $packagedPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
  }
  $mapPath = Join-Path $output 'mapping\sourceMaps.map'
  # The map must come from this product's completed build, alongside its HAP.
  # Never reuse the current map for a historical HAP with the same version label.
  $null = Get-Content -LiteralPath $mapPath -Raw | ConvertFrom-Json
  Copy-Item -LiteralPath $mapPath -Destination (Join-Path $symbolsRoot 'sourceMaps.map')
  [IO.Compression.ZipFile]::CreateFromDirectory($symbolsRoot, $zipPath)
  $manifest = [ordered]@{
    bundleName = $module.app.bundleName
    versionName = $module.app.versionName; versionCode = $module.app.versionCode
    product = $Product; buildMode = $module.app.buildMode; debug = $module.app.debug
    hapSha256 = $hapHash
    modulesAbcSha256 = $null
    libraries = $libraries
    sourceMapSha256 = (Get-FileHash -LiteralPath $mapPath -Algorithm SHA256).Hash.ToLowerInvariant()
    archiveSha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    uploaded = $false
  }
  $abc = $hap.GetEntry('ets/modules.abc').Open()
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $manifest.modulesAbcSha256 = ([BitConverter]::ToString($sha.ComputeHash($abc))).Replace('-', '').ToLowerInvariant() }
  finally { $abc.Dispose(); $sha.Dispose() }
  $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $archiveRoot 'manifest.json') -Encoding UTF8
  Write-Host "APMS symbols verified and archived (not uploaded): $zipPath"
} finally { $hap.Dispose() }
