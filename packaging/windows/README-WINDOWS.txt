Velum for Windows
=================

Contents
--------
velum.exe              Flutter desktop GUI
bin\velumd.exe         privileged service host and loopback REST API
bin\sing-box.exe       pinned sing-box 1.12.12 core
bin\xray.exe           optional XHTTP companion
bin\LICENSE.*          third-party notices
LICENSE                Velum license (GPL-3.0-or-later)
NOTICE                 dependency and trademark notes

Requirements
------------
- Windows 10 1809 or newer, x64
- WebView2 is not required; the GUI uses native Flutter rendering
- Administrator rights only for service installation and TUN mode

Install the service
-------------------
The GUI asks for elevation once and runs:

    bin\velumd.exe --service install --tun

Manual installation from an elevated PowerShell prompt:

    .\bin\velumd.exe --service install --tun

The installer copies velumd.exe, sing-box.exe and xray.exe into
%ProgramData%\Velum\bin and registers the service as "Velum". The service
starts automatically with a delayed start. The GUI itself runs as a standard
user and talks to the service over 127.0.0.1:27841 with a Bearer token.

The service account is LocalSystem by default because Wintun, adapter creation
and route changes require those privileges. Do not replace the binaries in
%ProgramData%\Velum\bin with user-writable copies.

Remove the service
------------------
From an elevated PowerShell prompt:

    .\bin\velumd.exe --service uninstall

The token in %ProgramData%\Velum\token and user profiles are kept. Deleting
them is a manual decision.

Proxy and TUN modes
-------------------
- Proxy mode: local SOCKS5/HTTP listener, no administrator rights.
- TUN mode: sing-box creates a "Velum" Wintun adapter with auto_route and
  strict_route. The resolved VPN endpoint is excluded from the tunnel to
  prevent routing loops.

If the explicitly selected outbound interface disappears, the daemon stops the
engine and reports an error instead of claiming a working connection.

Limitations
-----------
This build has no kill switch. If the service or engine crashes, normal
connectivity may return. Do not treat it as leak protection.

Windows Wintun packet flow, Service Control Manager timing under recovery,
UAC installation from the packaged GUI, and route/DNS restoration after a
forced crash have not been verified on real Windows hardware. See
docs/windows.md in the source tree for the full verification status.

There is no MSI installer, no system tray, no background subscription refresh
while the GUI is closed, and no AmneziaWG, crypt1 or TV Relay.

Security notes
--------------
- The REST API binds only to 127.0.0.1 and requires a Bearer token.
- The token ACL grants full control to SYSTEM and Administrators and read
  access to the installing user.
- Password-bearing profiles are stored locally in plain text in the private
  user profile directory. Do not publish or sync that directory.

Velum is not affiliated with INCY or SagerNet.
