param(
  [Parameter(Mandatory = $true)]
  [string]$TestBinary,
  [switch]$DisposableVM
)

$ErrorActionPreference = 'Stop'
if (-not $DisposableVM) { throw 'Explicit -DisposableVM authorization is required. Revert a clean Windows 11 VM snapshot afterwards.' }
$model = (Get-CimInstance Win32_ComputerSystem).Model
if ($model -notmatch 'Virtual Machine|VMware|VirtualBox|KVM|QEMU|Virtual Platform|HVM domU') {
  throw "Refusing filesystem/ACL experiments on an unrecognized VM model: $model"
}
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Use an elevated shell inside the disposable VM, never on the physical host.'
}
if (Get-Service Velum -ErrorAction SilentlyContinue) {
  throw 'Use a clean VM without an installed Velum service.'
}
$binary = (Resolve-Path -LiteralPath $TestBinary).Path
$systemData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
foreach ($ancestor in @([IO.Path]::GetPathRoot($systemData), $systemData)) {
  $descriptor = Get-Acl -LiteralPath $ancestor
  Write-Host "Read-only ancestor inspection: $ancestor owner=$($descriptor.Owner) sddl=$($descriptor.Sddl)"
}
$previous = $env:VELUM_F1_DISPOSABLE_VM
try {
  $env:VELUM_F1_DISPOSABLE_VM = '1'
  # Native NTFS fixture tests only: no SCM installation, no VPN, no TUN.
  $testArguments = @('-test.run=^TestService', '-test.v', '-test.timeout=120s')
  & $binary @testArguments
  if ($LASTEXITCODE -ne 0) { throw "Security tests failed with exit code $LASTEXITCODE" }
} finally {
  if ($null -eq $previous) { Remove-Item Env:VELUM_F1_DISPOSABLE_VM -ErrorAction SilentlyContinue }
  else { $env:VELUM_F1_DISPOSABLE_VM = $previous }
}
Write-Host 'No service was installed. Preserve test output and fixture security descriptors, then revert the VM snapshot.'
