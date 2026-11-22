#requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'k1-toolchain-common.ps1')
$project=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$manifest=Get-Content -Raw -LiteralPath (Join-Path $project 'patches/experimental/k1-toolchain-manifest.json') | ConvertFrom-Json
$archive=Join-Path $project 'artifacts/kernel-k1/go1.27.3.src.tar.gz'
$patch=Join-Path $project $manifest.patch
if ((Get-FileHash -LiteralPath $archive).Hash -cne $manifest.sourceArchiveSha256 -or
    (Get-FileHash -LiteralPath $patch).Hash -cne $manifest.patchSha256) {throw 'Verified official source archive and reviewed K1 patch are required'}
$out=Join-Path $project ('artifacts/kernel-k1/replay-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
$root=Join-Path $out 'go'
New-Item -ItemType Directory -Path $root | Out-Null
$report=[ordered]@{schemaVersion=1;milestone='K1';status='preparing';sourceArchiveSha256=$manifest.sourceArchiveSha256;
  portPatchSha256=$manifest.patchSha256;toolchainRoot=$root;officialGitCommit=$false;buildExecuted=$false}
try {
  & tar -xzf $archive --strip-components=1 -C $root
  if ($LASTEXITCODE -ne 0) {throw 'Official source extraction failed'}
  & git -C $root init -q
  if ($LASTEXITCODE -ne 0) {throw 'Isolated Git initialization failed'}
  & git -C $root config core.autocrlf false
  & git -C $root config core.longpaths true
  & git -C $root add --all
  if ($LASTEXITCODE -ne 0) {throw 'Cannot index source archive'}
  # This local artifact commit contains only public Go source and is not a
  # project commit or an upstream commit. The official archive hash is primary.
  & git -C $root -c user.name='MeshArc K1 fixture' -c user.email='mesharc-k1@localhost' -c commit.gpgsign=false commit -q -m 'Verified official go1.27.3 source archive'
  if ($LASTEXITCODE -ne 0) {throw 'Cannot freeze isolated source baseline'}
  $report.localFixtureCommit=(& git -C $root rev-parse HEAD).Trim()
  & git -C $root apply --check $patch
  if ($LASTEXITCODE -ne 0) {throw 'K1 patch does not replay on the official source'}
  & git -C $root apply $patch
  if ($LASTEXITCODE -ne 0) {throw 'K1 patch replay failed'}
  $added=@(& git -C $root ls-files --others --exclude-standard -- src)
  if ($LASTEXITCODE -ne 0) {throw 'Cannot enumerate port additions'}
  if ($added.Count) {
    & git -C $root add -N -- @added
    if ($LASTEXITCODE -ne 0) {throw 'Cannot track port additions'}
  }
  $null=Assert-K1ToolchainSource $root
  $report.verifiedFiles=@($manifest.changedFiles).Count
  $report.status='source_replay_passed'
} catch {$report.status='failed';$report.failure=$_.Exception.Message;throw}
finally {
  $report.finishedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
  $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $out 'report.json') -Encoding utf8
  Write-Host "K1 source replay: $out/report.json"
}
Write-Output $root
