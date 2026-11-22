$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'engine-abi-checks.ps1')
$expected = "extern char* TSHello();`nextern void TSFreeString(char* value);"
$actual = "extern void TSFreeString(char* value);`nextern char* TSHello(void);"
if ((Assert-EngineCAbi -ExpectedHeader $expected -ActualHeader $actual) -ne 2) { throw 'Rejected equivalent zero-argument declarations' }
foreach ($invalid in @($actual.Replace('char* TSHello', 'int TSHello'),
  $actual.Replace('char* value', 'int value'), $actual.Replace('TSHello', 'TSHelloNew'),
  'extern char* TSHello(void);', "$actual`nextern void TSNew();")) {
  $rejected = $false
  try { Assert-EngineCAbi -ExpectedHeader $expected -ActualHeader $invalid | Out-Null } catch { $rejected = $true }
  if (-not $rejected) { throw 'Accepted an incompatible C ABI' }
}
Write-Output '6 engine C ABI checks passed'
