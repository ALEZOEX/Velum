param(
  [Parameter(Mandatory = $true)][string]$DaemonBinary,
  [Parameter(Mandatory = $true)][string]$CoreFixture,
  [switch]$DisposableVM
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if (-not $DisposableVM) { throw 'Explicit -DisposableVM authorization required; never run on a physical host.' }
$model = (Get-CimInstance Win32_ComputerSystem).Model
if ($model -notmatch 'Virtual Machine|VMware|VirtualBox|KVM|QEMU|Virtual Platform|HVM domU') {
  throw "Refusing SCM/ACL experiments on an unrecognized VM model: $model"
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'An elevated disposable VM is required.' }
$root = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Velum'
if ((Get-Service Velum -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath $root)) {
  throw 'Use a clean disposable VM: existing Velum service/tree must not be touched.'
}
$daemon = (Resolve-Path -LiteralPath $DaemonBinary).Path
$core = (Resolve-Path -LiteralPath $CoreFixture).Path
# Both commands are local, version-only; the fixture refuses run/check/connect.
if ((& $core version) -ne 'sing-box version 1.12.12' -or $LASTEXITCODE -ne 0) { throw 'Unexpected inert fixture.' }
$port = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 27841)
$port.Start()
$port.Stop()

# All impersonated code runs in C#, not PowerShell scriptblocks on an arbitrary
# runspace thread. Failed logon/impersonation cannot silently probe as admin.
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;
public static class VelumF1Access {
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool LogonUser(string user, string domain, string password, int type, int provider, out SafeAccessTokenHandle token);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr attrs, uint disposition, uint flags, IntPtr template);
    public static int Probe(string user, string password, string sid, string path, uint access) {
        SafeAccessTokenHandle token;
        if (!LogonUser(user, ".", password, 2, 0, out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
        using (token) {
            return WindowsIdentity.RunImpersonated(token, () => {
                using (var actual = WindowsIdentity.GetCurrent()) {
                    if (actual.User.Value != sid) throw new Exception("Wrong probe identity");
                    var admin = new WindowsPrincipal(actual);
                    if (admin.IsInRole(WindowsBuiltInRole.Administrator)) throw new Exception("Probe account is an administrator");
                }
                using (var file = CreateFile(path, access, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
                    return file.IsInvalid ? Marshal.GetLastWin32Error() : 0;
                }
            });
        }
    }
}
'@

$checks = [Collections.Generic.List[string]]::new()
function Pass([string]$name) { $checks.Add($name); Write-Host "PASS: $name" }
function Assert-ServiceAbsent {
  if (Get-Service Velum -ErrorAction SilentlyContinue) { throw 'Unexpected SCM registration after refused installation.' }
}
function Invoke-Installer([string]$action, [bool]$success) {
  $arguments = @('--service', $action)
  if ($action -eq 'install') { $arguments += @('--core', $core, '--xray', $xray) }
  $output = & $daemon @arguments 2>&1
  $code = $LASTEXITCODE
  if (($code -eq 0) -ne $success) { throw "Installer $action exit=$code : $output" }
  if (-not $success) { Write-Host "Expected refusal: $output" }
}
function Assert-ACL([string]$path, [bool]$directory, [bool]$token) {
  $acl = Get-Acl -LiteralPath $path
  $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
  if ($owner -notin @('S-1-5-18', 'S-1-5-32-544') -or -not $acl.AreAccessRulesProtected) { throw "Unsafe owner/inheritance: $path" }
  $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
  $want = @{ 'S-1-5-18' = 0x1f01ff; 'S-1-5-32-544' = 0x1f01ff }
  $want[$identity.User.Value] = $(if ($token) { 0x120089 } else { 0x1200a9 })
  if ($rules.Count -ne $want.Count) { throw "Unexpected ACE count: $path" }
  foreach ($rule in $rules) {
    $sid = $rule.IdentityReference.Value
    $flags = $(if ($directory) { 3 } else { 0 })
    if (-not $want.ContainsKey($sid) -or [uint32]$rule.FileSystemRights -ne $want[$sid] -or
        $rule.AccessControlType -ne 'Allow' -or $rule.IsInherited -or
        [int]$rule.InheritanceFlags -ne $flags -or [int]$rule.PropagationFlags -ne 0) { throw "Unexpected ACE: $path : $rule" }
    $want.Remove($sid)
  }
  if ($want.Count -ne 0) { throw "Missing ACE: $path" }
  Write-Host "Verified descriptor: $path $($acl.Sddl)"
}
function Set-Sddl([string]$path, [string]$sddl) {
  $acl = Get-Acl -LiteralPath $path
  $acl.SetSecurityDescriptorSddlForm($sddl)
  Set-Acl -LiteralPath $path -AclObject $acl
}
function Assert-OutsideUnchanged {
  if ((Get-FileHash -LiteralPath $outside).Hash -ne $outsideHash -or (Get-Acl -LiteralPath $outside).Sddl -ne $outsideSddl) {
    throw 'Foreign sentinel was modified.'
  }
}
function Expect-Denied([string]$path, [uint32]$access) {
  $code = [VelumF1Access]::Probe($userName, $password, $userSid, $path, $access)
  # ERROR_SHARING_VIOLATION is NOT evidence of ACL protection.
  if ($code -ne 5) { throw "Expected ERROR_ACCESS_DENIED, got $code for $path access=$access" }
}

$userName = 'VF1' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
$password = 'F1!aA9' + [Guid]::NewGuid().ToString('N')
$userCreated = $false
$xrayCreated = $false
$workspace = Join-Path (Split-Path $root) ('Velum-F1-SCM-' + [Guid]::NewGuid().ToString('N'))
$ownsRoot = $false
try {
  $user = New-LocalUser -Name $userName -Password (ConvertTo-SecureString $password -AsPlainText -Force) -Description 'Disposable Velum F1 ACL probe'
  $userCreated = $true
  $userSid = $user.SID.Value
  $users = Get-LocalGroup -SID 'S-1-5-32-545'
  if (-not (Get-LocalGroupMember -Group $users.Name | Where-Object { $_.SID.Value -eq $userSid })) {
    Add-LocalGroupMember -Group $users.Name -Member $userName
  }
  New-Item -ItemType Directory -Path $workspace | Out-Null
  Set-Sddl $workspace "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FRFX;;;$userSid)"
  $outside = Join-Path $workspace 'sentinel.txt'
  Set-Content -LiteralPath $outside -Value 'outside fixture must never change'
  $outsideHash = (Get-FileHash -LiteralPath $outside).Hash
  $outsideSddl = (Get-Acl -LiteralPath $outside).Sddl
  $control = Join-Path $workspace 'access-control.txt'
  Set-Content -LiteralPath $control -Value 'positive control'
  Set-Sddl $control "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;$userSid)"
  foreach ($access in @(1, 2, 0x10000, 0x40000, 0x80000)) {
    if ([VelumF1Access]::Probe($userName, $password, $userSid, $control, $access) -ne 0) { throw 'Standard-user positive control failed.' }
  }
  Pass 'real standard-user logon, identity, non-admin membership and access positive controls'

  # Use the same inert image under the Xray name; only version output changes.
  $xray = Join-Path (Split-Path $core) 'xray.exe'
  if (Test-Path -LiteralPath $xray) { throw 'Fixture xray destination already exists.' }
  [IO.File]::Copy($core, $xray, $false)
  $xrayCreated = $true
  $ownsRoot = $true
  Invoke-Installer 'install' $true
  $service = Get-Service Velum
  $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
  $config = Get-CimInstance Win32_Service -Filter "Name='Velum'"
  $installed = Join-Path $root 'bin\velumd.exe'
  $imageArgument = $(if ($installed.Contains(' ')) { '"' + $installed + '"' } else { $installed })
  if ($config.StartName -ne 'LocalSystem' -or -not $config.PathName.StartsWith($imageArgument + ' ') -or $config.PathName -match '(^|\s)--tun(\s|$)') {
    throw 'Unexpected SCM identity, path or TUN flag.'
  }
  $tokenPath = Join-Path $root 'token'
  $token = (Get-Content -LiteralPath $tokenPath -Raw).Trim()
  $headers = @{ Authorization = "Bearer $token" }
  $response = Invoke-RestMethod -Uri 'http://127.0.0.1:27841/v1/status' -Headers $headers
  if ($response.state -ne 'disconnected' -or $response.engineState -ne 'stopped' -or $response.tunAllowed -or $response.serviceMode -ne 'windows-service') {
    throw 'Service must be idle with no TUN/engine.'
  }
  $denied = Invoke-WebRequest -Uri 'http://127.0.0.1:27841/v1/status' -SkipHttpErrorCheck
  if ($denied.StatusCode -ne 401) { throw 'API accepted a missing Bearer token.' }
  Pass 'real SCM install/start under LocalSystem; canonical path; authenticated idle API; no TUN'

  Invoke-Installer 'install' $false
  if ((Get-CimInstance Win32_Service -Filter "Name='Velum'").ProcessId -ne $config.ProcessId) { throw 'Repeat install restarted an existing service.' }
  Pass 'repeat installation refuses unchanged running service'
  Stop-Service Velum
  (Get-Service Velum).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))
  # Test ACLs with service stopped and installer handles released, so image
  # locking/sharing restrictions cannot masquerade as access denial.
  $binaries = @('velumd.exe', 'sing-box.exe', 'xray.exe') | ForEach-Object { Join-Path $root "bin\$_" }
  $hashes = @{}
  $descriptors = @{}
  foreach ($path in @($root, (Join-Path $root 'bin')) + $binaries + @($tokenPath)) {
    $isDirectory = (Get-Item -LiteralPath $path).PSIsContainer
    Assert-ACL $path $isDirectory ($path -eq $tokenPath)
    $descriptors[$path] = (Get-Acl -LiteralPath $path).Sddl
    if (-not $isDirectory) { $hashes[$path] = (Get-FileHash -LiteralPath $path).Hash }
    foreach ($access in @(2, 4, 0x10, 0x100, 0x10000, 0x40000, 0x80000)) { Expect-Denied $path $access }
    if ($isDirectory) { Expect-Denied $path 0x40 }
  }
  Expect-Denied $tokenPath 1
  foreach ($path in $descriptors.Keys) {
    if ((Get-Acl -LiteralPath $path).Sddl -ne $descriptors[$path]) { throw 'Probe altered a descriptor.' }
  }
  foreach ($path in $hashes.Keys) {
    if ((Get-FileHash -LiteralPath $path).Hash -ne $hashes[$path]) { throw 'Probe altered file content.' }
  }
  Pass 'actual protected DACL/owner readback; standard-user write/delete/ACL/owner denial; foreign token read denied'
  $unsafeImage = $binaries[0]
  try {
    $acl = Get-Acl -LiteralPath $unsafeImage
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($userSid), 'Modify', 'Allow'))
    Set-Acl -LiteralPath $unsafeImage -AclObject $acl
    $badImageAcl = (Get-Acl -LiteralPath $unsafeImage).Sddl
    Invoke-Installer 'uninstall' $false
    if ((Get-Service Velum).Status -ne 'Stopped' -or (Get-Acl -LiteralPath $unsafeImage).Sddl -ne $badImageAcl -or
        (Get-FileHash -LiteralPath $unsafeImage).Hash -ne $hashes[$unsafeImage]) { throw 'Unsafe uninstall changed service/files.' }
    Pass 'unsafe executable ACL makes uninstall refuse unchanged before SCM deletion'
  } finally { Set-Sddl $unsafeImage $descriptors[$unsafeImage] }
  Start-Service Velum
  (Get-Service Velum).WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
  Pass 'real SCM stop and restart'
  Invoke-Installer 'uninstall' $true
  Assert-ServiceAbsent
  if (Test-Path -LiteralPath (Join-Path $root 'bin')) { throw 'Uninstall left binary directory.' }
  Assert-ACL $root $true $false
  Assert-ACL $tokenPath $false $true
  if ((Get-FileHash -LiteralPath $tokenPath).Hash -ne $hashes[$tokenPath]) { throw 'Uninstall changed recovery token.' }
  Pass 'real SCM uninstall removes binaries and retains protected recovery token/root'

  # Each mutation is administrator-created inside this run's fresh tree only.
  # Refusal must preserve the unsafe fixture, not silently repair/remove it.
  foreach ($path in @($root, $tokenPath)) {
    $original = (Get-Acl -LiteralPath $path).Sddl
    try {
      $acl = Get-Acl -LiteralPath $path
      $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($userSid), 'Modify', 'Allow'))
      Set-Acl -LiteralPath $path -AclObject $acl
      $bad = (Get-Acl -LiteralPath $path).Sddl
      Invoke-Installer 'install' $false
      Assert-ServiceAbsent
      if ((Get-Acl -LiteralPath $path).Sddl -ne $bad) { throw 'Unsafe ACL was changed by refused install.' }
      Assert-OutsideUnchanged
      Pass "unsafe ACL install refusal unchanged: $path"
    } finally { Set-Sddl $path $original }
  }
  $bin = Join-Path $root 'bin'
  # Token rejection can create an empty protected bin before checking token.
  if (Test-Path -LiteralPath $bin) {
    if (@(Get-ChildItem -LiteralPath $bin -Force).Count -ne 0) { throw 'Unexpected partial files.' }
    Remove-Item -LiteralPath $bin
  }
  try {
    New-Item -ItemType Directory -Path $bin | Out-Null
    Set-Sddl $bin $descriptors[$bin]
    [IO.File]::Copy($daemon, $installed, $false)
    Set-Sddl $installed $descriptors[$installed]
    $acl = Get-Acl -LiteralPath $installed
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($userSid), 'Modify', 'Allow'))
    Set-Acl -LiteralPath $installed -AclObject $acl
    $bad = (Get-Acl -LiteralPath $installed).Sddl
    $before = (Get-FileHash -LiteralPath $installed).Hash
    Invoke-Installer 'install' $false
    Assert-ServiceAbsent
    if ((Get-Acl -LiteralPath $installed).Sddl -ne $bad -or (Get-FileHash -LiteralPath $installed).Hash -ne $before) { throw 'Unsafe binary was modified.' }
    Assert-OutsideUnchanged
    Pass 'writable executable install refusal; no registration/start or file replacement'
  } finally {
    # Explicitly remove this test-created fixture, never a pre-existing object.
    if (Test-Path -LiteralPath $installed) { Remove-Item -LiteralPath $installed }
    if (Test-Path -LiteralPath $bin) { Remove-Item -LiteralPath $bin }
  }
  try {
    New-Item -ItemType Junction -Path $bin -Target $workspace | Out-Null
    Invoke-Installer 'install' $false
    Assert-ServiceAbsent
    if (-not ((Get-Item -LiteralPath $bin).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Junction was modified.' }
    Assert-OutsideUnchanged
    Pass 'junction install refusal; no SCM registration; foreign target content/descriptor unchanged'
  } finally {
    if (Test-Path -LiteralPath $bin) { [IO.Directory]::Delete($bin) }
  }
  Invoke-Installer 'install' $true
  (Get-Service Velum).WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
  Pass 'safe retry after explicit fixture correction'
  Invoke-Installer 'uninstall' $true
  Assert-ServiceAbsent
  Assert-OutsideUnchanged
} finally {
  # Only this clean VM's newly created service/tree/account may be cleaned.
  # Unknown children/reparse points cause refusal rather than recursive deletion.
  if ($ownsRoot) {
    if (Get-Service Velum -ErrorAction SilentlyContinue) {
      Invoke-Installer 'uninstall' $true
    }
    if (Test-Path -LiteralPath $root) {
      if ((Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Cleanup refuses redirected root.' }
      $remaining = @(Get-ChildItem -LiteralPath $root -Force)
      if (@($remaining | Where-Object { $_.Name -ne 'token' -or $_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) }).Count -ne 0) {
        throw 'Unexpected service remnants; preserve VM for investigation.'
      }
      Remove-Item -LiteralPath (Join-Path $root 'token') -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $root
    }
  }
  if ($userCreated) { Remove-LocalUser -Name $userName }
  $password = $null
  if (Test-Path -LiteralPath $workspace) {
    foreach ($name in @('sentinel.txt', 'access-control.txt')) {
      $path = Join-Path $workspace $name
      if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    Remove-Item -LiteralPath $workspace
  }
  if ($xrayCreated -and (Test-Path -LiteralPath $xray)) { Remove-Item -LiteralPath $xray }
}
Assert-ServiceAbsent
if ((Test-Path -LiteralPath $root) -or (Get-LocalUser -Name $userName -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath $workspace)) { throw 'Incomplete test cleanup.' }
Pass 'SCM, canonical tree, foreign sentinel sandbox and disposable account cleanup verified'
$checks | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $env:RUNNER_TEMP 'velum-f1-scm-results.json')
Write-Host 'SCM/ACL runtime checks passed. No connect request, real VPN engine or TUN was used.'
