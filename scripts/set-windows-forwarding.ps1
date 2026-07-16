param(
  [Parameter(Mandatory)]
  [ValidatePattern('^\d+(,\d+)*$')]
  [string]$InterfaceIndexCsv,

  [Parameter(Mandatory)]
  [ValidateSet('Enabled', 'Disabled')]
  [string]$State
)

$ErrorActionPreference = 'Stop'
$indices = @($InterfaceIndexCsv.Split(',') | ForEach-Object { [int]$_ })
foreach ($index in $indices) {
  Set-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 `
    -Forwarding $State
}
