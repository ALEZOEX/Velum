# Velum on Windows

Velum ships a Flutter desktop GUI and a privileged Windows service that owns
`sing-box`, the optional Xray companion, the loopback REST API and the TUN
adapter. The GUI never runs with permanent administrator rights.

## Layout

```
Velum\
  velum.exe              Flutter GUI
  bin\
    velumd.exe           service host and HTTP API
    sing-box.exe         pinned core 1.12.12
    xray.exe             optional XHTTP companion
    LICENSE.*            third-party notices
  README-WINDOWS.txt
```

The service installer copies `velumd.exe`, `sing-box.exe` and `xray.exe` into
`%ProgramData%\Velum\bin`. The service never executes binaries from the
user-writable release directory, because that would let a standard user replace
the executable and gain LocalSystem privileges.

## Installation

From an elevated PowerShell window in a source checkout:

```powershell
.\scripts\install-windows-service.ps1 -Action install
```

In a packaged build the same action is available directly:

```powershell
.\bin\velumd.exe --service install --tun
```

Or from the GUI: open the connection mode help and press `Установить службу`.
The GUI starts `velumd.exe --service install --tun` through
`Start-Process -Verb RunAs`, so Windows shows a single UAC prompt.

The service is registered as `Velum`, starts automatically with a delayed start,
and accepts Stop and Shutdown from the Service Control Manager. Recovery actions
restart it after 5 s, then 15 s, then 60 s, and the failure counter resets after
one hour. Recovery also applies to non-zero service exits, not only crashes.

Removal:

```powershell
.\scripts\install-windows-service.ps1 -Action uninstall
```

In a packaged build:

```powershell
.\bin\velumd.exe --service uninstall
```

The token and user profiles are kept. Removing them is a manual decision.

## Service account and token

The default account is `LocalSystem`. This is deliberate: loading the Wintun
driver, creating the adapter and changing routes requires privileges that
`LocalService` and `NetworkService` do not have. `--service-account` allows an
operator to provide a different account, but that account must then be granted
the same network privileges and read access to the token.

The service token lives in `%ProgramData%\Velum\token`. Its ACL removes
inheritance and grants:

- `NT AUTHORITY\SYSTEM`: full control
- `BUILTIN\Administrators`: full control
- the installing user: read

The REST API keeps Bearer authentication and binds only to `127.0.0.1:27841`.
There is no remote listener and no unauthenticated administrative endpoint.

## TUN and routing

The Windows TUN inbound uses:

- adapter name `Velum`
- MTU 1500 unless the user chose another value
- IPv4 `172.28.0.1/30`
- IPv6 `fdfe:7665:6c75::1/126` unless disabled
- `auto_route: true`
- `strict_route: true`

`strict_route` is supported by sing-box 1.12.12 on Windows. It marks unsupported
networks unreachable and limits DNS leaks caused by Windows multi-homed
resolution. Earlier builds disabled it without evidence; that workaround was
removed.

Loop prevention:

- `route.auto_detect_interface` binds sing-box outbound sockets to the current
  physical adapter.
- The resolved VPN endpoint is added to `route_exclude_address`, so neither
  sing-box nor the Xray companion can send its own transport back into TUN.
- The Xray companion also receives `sockopt.interface` when an interface is
  known.
- The Xray bridge to sing-box uses loopback and an explicit loopback bind.

On service stop the daemon terminates the whole child job. As a safety net it
removes only the four routes that `auto_route` creates on the `Velum` adapter
and resets DNS on that adapter. Physical adapters are never modified.

If the explicitly selected outbound interface disappears, the daemon stops the
engine, reports an error and uses the existing reconnect policy.

## Process lifetime

`sing-box.exe` and `xray.exe` are assigned to a Windows Job Object with
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. If `velumd.exe` crashes, the job handle is
closed by the kernel and the child tree is terminated. A named mutex prevents
two service instances from running at once.

## GUI states

The connection screen reports four separate values:

- service availability
- VPN engine state
- active connection mode
- selected server and measured latency

`Подключено` is shown only after the daemon reports `state: running`. A TUN
initialization failure is returned as an API error, never as a successful
connection.

## Verification status

Automated on Linux:

- `go test ./...`, `go vet ./...`
- Windows cross-build `GOOS=windows GOARCH=amd64`
- Windows cross-vet
- generated Windows TUN config validated by the pinned sing-box core
- `flutter analyze`, `flutter test`

Not verified without a real Windows host:

- Wintun adapter creation and packet flow
- Windows route and DNS restoration after a forced engine crash
- Service Control Manager start/stop timing under recovery
- UAC install flow from a packaged GUI
- proxy mode against a live provider
- interaction with third-party VPN adapters and Windows Filtering Platform
