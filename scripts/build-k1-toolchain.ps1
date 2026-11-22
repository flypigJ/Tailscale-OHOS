#requires -Version 7.0
[CmdletBinding()]
param(
  [string]$ToolchainRoot = (Join-Path $PSScriptRoot '../artifacts/kernel-k1/ohos-go-1.27.3'),
  [string]$BootstrapRoot = (Join-Path $PSScriptRoot '../artifacts/kernel-k1/bootstrap-go1.27.3/go')
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'k1-toolchain-common.ps1')
$project=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$root=(Resolve-Path -LiteralPath $ToolchainRoot).Path
$bootstrap=(Resolve-Path -LiteralPath $BootstrapRoot).Path
$manifest=Assert-K1ToolchainSource $root
if (-not $bootstrap.StartsWith((Join-Path $project 'artifacts/kernel-k1')+[IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase)) { throw 'K1 requires an isolated bootstrap' }
$archive=Join-Path $project 'artifacts/kernel-k1/go1.27.3.windows-amd64.zip'
if ((Get-FileHash -LiteralPath $archive).Hash -cne $manifest.bootstrapArchiveSha256) { throw 'Bootstrap archive mismatch' }
# Check the actual executable files used for bootstrap against the verified zip.
$zip=[IO.Compression.ZipFile]::OpenRead($archive)
try {
  foreach ($binary in (Get-K1CompilerBinaries $bootstrap)) {
    $entry=$zip.GetEntry('go/'+$binary.path)
    if ($null -eq $entry) { throw 'Missing official bootstrap executable' }
    $stream=$entry.Open()
    try { $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)) }
    finally { $stream.Dispose() }
    if ($digest -cne $binary.sha256) { throw 'Extracted bootstrap binary differs from its official archive' }
  }
} finally { $zip.Dispose() }
$out=Join-Path $project ('artifacts/kernel-k1/bootstrap-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $out | Out-Null
$report=[ordered]@{schemaVersion=1;milestone='K1';status='building';startedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');
  expectedGoVersion='go1.27.3';sourceArchiveSha256=$manifest.sourceArchiveSha256;portPatchSha256=$manifest.patchSha256;
  bootstrapArchiveSha256=$manifest.bootstrapArchiveSha256;toolchainRoot=$root;
  bootstrapRoot=$bootstrap;applicationBuild=$false;deviceTested=$false;defaultToolchainChanged=$false}
try {
  $start=[Diagnostics.ProcessStartInfo]::new()
  $start.FileName=$env:ComSpec; $start.WorkingDirectory=Join-Path $root 'src'
  $start.UseShellExecute=$false; $start.CreateNoWindow=$true
  $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
  foreach ($argument in @('/d','/c','make.bat')) { $start.ArgumentList.Add($argument) }
  foreach ($name in @('GOROOT','GOOS','GOARCH','GOHOSTOS','GOHOSTARCH','CC','CXX','GOFLAGS','GOEXPERIMENT','GOTOOLDIR','GO_EXTLINK_ENABLED')) {
    $start.Environment.Remove($name) | Out-Null
  }
  $environment=@{GOROOT_BOOTSTRAP=$bootstrap;GOENV='off';GOTOOLCHAIN='local';GOWORK='off';CGO_ENABLED='0';
    GOPROXY='off';GOSUMDB='off';GOCACHE=(Join-Path $project 'artifacts/kernel-k1/bootstrap-cache');
    GOPATH=(Join-Path $project 'artifacts/kernel-k1/bootstrap-gopath');GOTMPDIR=(Join-Path $out 'tmp')}
  New-Item -ItemType Directory -Path $environment.GOTMPDIR | Out-Null
  foreach ($name in $environment.Keys) { $start.Environment[$name]=$environment[$name] }
  $process=[Diagnostics.Process]::Start($start)
  try {
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(1800000)) { $process.Kill($true);$process.WaitForExit();$report.timedOut=$true }
    [IO.File]::WriteAllText((Join-Path $out 'build.log'),$stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult())
    $report.exitCode=$process.ExitCode
    if ($report.timedOut -or $process.ExitCode -ne 0) { throw 'K1 bootstrap failed; inspect build.log' }
  } finally { $process.Dispose() }
  $null=Assert-K1ToolchainSource $root
  $report.binaries=@(Get-K1CompilerBinaries $root)
  $version=(& (Join-Path $root 'bin/go.exe') version) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $version -cne 'go version go1.27.3 windows/amd64') { throw 'Built compiler version mismatch' }
  $report.version=$version; $report.status='bootstrap_passed_tests_pending'
} catch { $report.status='failed';$report.failure=$_.Exception.Message;throw }
finally {
  $report.finishedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
  $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $out 'report.json') -Encoding utf8
  Write-Host "K1 bootstrap receipt: $out/report.json"
}
