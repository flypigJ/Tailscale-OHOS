# K1 is isolated from the normal toolchain and application libraries.
function Assert-K1ToolchainSource {
  param([Parameter(Mandatory)][string]$ToolchainRoot)
  $project = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
  $root = (Resolve-Path -LiteralPath $ToolchainRoot).Path
  if (-not $root.StartsWith((Join-Path $project 'artifacts/kernel-k1') + [IO.Path]::DirectorySeparatorChar,
      [StringComparison]::OrdinalIgnoreCase)) { throw 'K1 requires an isolated toolchain source directory' }
  $manifest = Get-Content -Raw -LiteralPath (Join-Path $project 'patches/experimental/k1-toolchain-manifest.json') | ConvertFrom-Json
  if ($manifest.milestone -cne 'K1' -or $manifest.goVersion -cne 'go1.27.3' -or
      (Get-Content -LiteralPath (Join-Path $root 'VERSION') -TotalCount 1).Trim() -cne 'go1.27.3' -or
      (Get-FileHash -LiteralPath (Join-Path $project $manifest.patch)).Hash -cne $manifest.patchSha256) {
    throw 'K1 source/patch identity mismatch'
  }
  $actual = @(& git -C $root diff --name-only HEAD -- src)
  if ($LASTEXITCODE -ne 0 -or
      (($actual | Sort-Object) -join "`n") -cne (($manifest.changedFiles.path | Sort-Object) -join "`n")) {
    throw 'K1 source delta differs from the reviewed port'
  }
  $unknown = @(& git -C $root ls-files --others --exclude-standard -- src)
  # The official source archive omits Git's ignore rules for make.bat outputs.
  # Allow only cmd/dist's exact generated paths, never arbitrary source files.
  $generated=@('src/cmd/cgo/zdefaultcc.go','src/cmd/dist/dist.exe','src/cmd/go/internal/cfg/zdefaultcc.go',
    'src/cmd/internal/objabi/zbootstrap.go','src/internal/buildcfg/zbootstrap.go',
    'src/internal/runtime/sys/zversion.go','src/time/tzdata/zzipdata.go')
  if ($LASTEXITCODE -ne 0 -or @($unknown | Where-Object { $_ -notin $generated }).Count -ne 0) { throw 'Unrecorded K1 source files' }
  foreach ($file in $manifest.changedFiles) {
    if ($file.path -cnotmatch '^src/[A-Za-z0-9_./-]+$' -or $file.path -match '(^|/)\.\.(/|$)' -or
        (Get-FileHash -LiteralPath (Join-Path $root $file.path)).Hash -cne $file.sha256) {
      throw 'K1 source content differs from the reviewed port'
    }
  }
  if ((Get-FileHash -LiteralPath (Join-Path $root 'src/crypto/x509/verify.go')).Hash -cne $manifest.securityVerifierSha256) {
    throw 'Official certificate verifier changed during porting'
  }
  return $manifest
}

function Get-K1CompilerBinaries {
  param([Parameter(Mandatory)][string]$ToolchainRoot)
  return @('bin/go.exe','bin/gofmt.exe','pkg/tool/windows_amd64/asm.exe',
    'pkg/tool/windows_amd64/compile.exe','pkg/tool/windows_amd64/link.exe',
    'pkg/tool/windows_amd64/cgo.exe') | ForEach-Object {
    [ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath (Join-Path $ToolchainRoot $_)).Hash}
  }
}
