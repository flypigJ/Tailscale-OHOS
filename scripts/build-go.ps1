#requires -Version 5.1
# Normal builds use only the accepted, version-locked engine pair.
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'build-k7-engine.ps1')
