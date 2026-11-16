param(
  [ValidateSet('install', 'uninstall')]
  [string]$Action = 'install',
  [string]$BinDir = (Join-Path $PSScriptRoot '..\bin')
)

$ErrorActionPreference = 'Stop'
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Run this script from an elevated PowerShell window.'
}

$velumd = Join-Path $BinDir 'velumd.exe'
if (-not (Test-Path -LiteralPath $velumd -PathType Leaf)) {
  throw "velumd.exe was not found in $BinDir"
}

if ($Action -eq 'uninstall') {
  & $velumd --service uninstall
} else {
  & $velumd --service install --tun
}
if ($LASTEXITCODE -ne 0) {
  throw "velumd --service $Action failed with exit code $LASTEXITCODE"
}

Write-Host "Velum service: $Action completed."
if ($Action -eq 'install') {
  $systemData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
  Write-Host "The GUI token is stored in $systemData\Velum\token and is readable by the elevated installing identity."
  Write-Host 'Existing unsafe service objects are refused; this installer does not repair their owner or ACL.'
}
