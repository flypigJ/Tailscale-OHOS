$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$helper = Join-Path $PSScriptRoot 'hdc-command-result.ps1'
if (Test-Path -LiteralPath $helper) { . $helper }
$probe = Join-Path $PSScriptRoot 'device-file-lifecycle-probe.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($probe, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'Device probe syntax invalid.' }
$invoke = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Hdc' }, $true)
if ($null -eq $invoke) { throw 'Production Invoke-Hdc not found.' }
Invoke-Expression $invoke.Extent.Text
$fixtureDir = Join-Path $root 'artifacts\ui-u30-hdc-guard-tests'
New-Item -ItemType Directory -Path $fixtureDir -Force | Out-Null
$hdcPath = Join-Path $fixtureDir 'fake-hdc.ps1'
$DeviceId = 'synthetic-device-no-transport'
$cases = @(
  @{ Name='zero exit device unavailable'; Exit=0; Output='[Fail][E001005] Device not found or connected'; Throws=$true },
  @{ Name='zero exit target unavailable'; Exit=0; Output='[Fail]Target device synthetic-device not available'; Throws=$true },
  @{ Name='zero exit fatal transport'; Exit=0; Output='[F][2026-10-21 07:18:00] Send isDead'; Throws=$true },
  @{ Name='failure after blank lines'; Exit=0; Output="`n`n[Fail] Session lost"; Throws=$true },
  @{ Name='case insensitive protocol failure'; Exit=0; Output='[fail] Session lost'; Throws=$true },
  @{ Name='nonzero exit even with success words'; Exit=7; Output='install bundle successfully'; Throws=$true },
  @{ Name='empty pid query is valid'; Exit=0; Output=''; Throws=$false },
  @{ Name='normal installation output'; Exit=0; Output='[Info] install bundle successfully'; Throws=$false },
  @{ Name='normal JSON may contain fail text'; Exit=0; Output='{"requestId":7,"result":"[Fail] sample"}'; Throws=$false },
  @{ Name='numeric pid output'; Exit=0; Output='12345'; Throws=$false }
)
$failures = @()
foreach ($case in $cases) {
  $literal = $case.Output.Replace("'", "''")
  "Write-Output '$literal'`nexit $($case.Exit)`n" | Set-Content -LiteralPath $hdcPath -Encoding utf8
  $threw = $false
  $actual = $null
  try { $actual = Invoke-Hdc @('shell', 'pidof', 'synthetic-bundle') }
  catch { $threw = $true }
  if ($threw -ne $case.Throws) { $failures += $case.Name; continue }
  if (-not $threw -and "$actual" -ne $case.Output) { $failures += $case.Name + ' output changed' }
}
if ($failures.Count -gt 0) { throw ('HDC result regression failures: ' + ($failures -join ', ')) }
Write-Output "PASS: $($cases.Count) HDC result cases; production Invoke-Hdc only, no device commands."
