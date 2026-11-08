//go:build windows

package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/eventlog"
	"golang.org/x/sys/windows/svc/mgr"
)

const (
	serviceName        = "Velum"
	serviceDisplayName = "Velum VPN service"
	serviceDescription = "Privileged Velum network engine: sing-box, optional Xray companion, proxy API and TUN."
)

// ProgramData keeps the installed service binaries and token outside the
// user-writable release directory. Otherwise a standard user could replace
// velumd.exe and obtain LocalSystem privileges.
func serviceDataDir() (string, error) {
	base := os.Getenv("ProgramData")
	if base == "" {
		return "", errors.New("ProgramData is not defined")
	}
	return filepath.Join(base, "Velum"), nil
}

func runServiceAction(action string, cfg daemonConfig, account string) error {
	switch action {
	case "install":
		return installService(cfg, account)
	case "uninstall":
		return uninstallService()
	case "run":
		return runAsService(cfg)
	default:
		return fmt.Errorf("unknown service action %q: use install, uninstall or run", action)
	}
}

func requireElevation() error {
	if windows.GetCurrentProcessToken().IsElevated() {
		return nil
	}
	return errors.New("this action requires an elevated administrator shell")
}

func hiddenCommand(name string, args ...string) *exec.Cmd {
	command := exec.Command(name, args...)
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	return command
}

func currentUserSID() string {
	account, err := user.Current()
	if err != nil || account.Uid == "" {
		return ""
	}
	return account.Uid
}

// restrictACL removes inherited permissions and grants SYSTEM/Administrators
// full control plus read access to the installing user only.
func restrictACL(path string, directory bool) error {
	sid := currentUserSID()
	inheritance := "(OI)(CI)"
	if !directory {
		inheritance = ""
	}
	args := []string{path, "/inheritance:r", "/grant:r", "*S-1-5-18:" + inheritance + "(F)", "*S-1-5-32-544:" + inheritance + "(F)"}
	if sid != "" {
		args = append(args, "*"+sid+":"+inheritance+"(R)")
	}
	if output, err := hiddenCommand("icacls", args...).CombinedOutput(); err != nil {
		return fmt.Errorf("failed to restrict ACL on %s: %w: %s", path, err, strings.TrimSpace(string(output)))
	}
	return nil
}

func ensureServiceDataDir() (string, error) {
	dir, err := serviceDataDir()
	if err != nil {
		return "", err
	}
	if err = os.MkdirAll(dir, 0700); err != nil {
		return "", fmt.Errorf("failed to create %s: %w", dir, err)
	}
	if err = restrictACL(dir, true); err != nil {
		return "", err
	}
	bin := filepath.Join(dir, "bin")
	if err = os.MkdirAll(bin, 0700); err != nil {
		return "", fmt.Errorf("failed to create %s: %w", bin, err)
	}
	if err = restrictACL(bin, true); err != nil {
		return "", err
	}
	return dir, nil
}

func ensureToken(path string) error {
	if info, err := os.Stat(path); err == nil {
		if !info.Mode().IsRegular() || info.Size() > 256 {
			return errors.New("existing service token is not a regular file")
		}
		if err = restrictACL(path, false); err != nil {
			return err
		}
		return nil
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return fmt.Errorf("failed to generate token: %w", err)
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return fmt.Errorf("failed to create token file: %w", err)
	}
	_, writeErr := file.WriteString(hex.EncodeToString(raw) + "\n")
	closeErr := file.Close()
	if writeErr != nil {
		return fmt.Errorf("failed to write token file: %w", writeErr)
	}
	if closeErr != nil {
		return fmt.Errorf("failed to close token file: %w", closeErr)
	}
	return restrictACL(path, false)
}

func copyExecutable(source, destination string) error {
	input, err := os.Open(source)
	if err != nil {
		return fmt.Errorf("failed to open %s: %w", source, err)
	}
	defer input.Close()
	output, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0755)
	if err != nil {
		return fmt.Errorf("failed to create %s: %w", destination, err)
	}
	if _, err = io.Copy(output, input); err != nil {
		_ = output.Close()
		return fmt.Errorf("failed to copy %s: %w", source, err)
	}
	if err = output.Close(); err != nil {
		return fmt.Errorf("failed to close %s: %w", destination, err)
	}
	return nil
}

func installService(cfg daemonConfig, account string) error {
	if err := requireElevation(); err != nil {
		return err
	}
	explicitToken := cfg.tokenFile
	if err := resolvePaths(&cfg); err != nil {
		return err
	}
	if !filepath.IsAbs(cfg.core) {
		return errors.New("core path must be absolute")
	}
	if _, err := os.Stat(cfg.core); err != nil {
		return fmt.Errorf("sing-box executable not found: %w", err)
	}
	if cfg.xray != "" {
		if _, err := os.Stat(cfg.xray); err != nil {
			return fmt.Errorf("Xray executable not found: %w", err)
		}
	}
	manager, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("failed to connect to the service manager: %w", err)
	}
	defer manager.Disconnect()
	if existing, openErr := manager.OpenService(serviceName); openErr == nil {
		_ = existing.Close()
		return errors.New("the Velum service is already installed; uninstall it before reinstalling")
	}
	dataDir, err := ensureServiceDataDir()
	if err != nil {
		return err
	}
	tokenPath := cfg.tokenFile
	if explicitToken == "" {
		tokenPath = filepath.Join(dataDir, "token")
	}
	if !filepath.IsAbs(tokenPath) {
		return errors.New("token path must be absolute")
	}
	if err = ensureToken(tokenPath); err != nil {
		return err
	}
	binDir := filepath.Join(dataDir, "bin")
	serviceExe := filepath.Join(binDir, "velumd.exe")
	coreExe := filepath.Join(binDir, "sing-box.exe")
	currentExe, err := os.Executable()
	if err != nil {
		return fmt.Errorf("failed to locate the current executable: %w", err)
	}
	if err = copyExecutable(currentExe, serviceExe); err != nil {
		return err
	}
	if err = copyExecutable(cfg.core, coreExe); err != nil {
		return err
	}
	args := []string{"--service", "run", "--core", coreExe, "--token-file", tokenPath}
	if cfg.tunAllowed {
		args = append(args, "--tun")
	}
	if cfg.xray != "" {
		xrayExe := filepath.Join(binDir, "xray.exe")
		if err = copyExecutable(cfg.xray, xrayExe); err != nil {
			return err
		}
		args = append(args, "--xray", xrayExe)
	}
	if cfg.interfaceName != "" {
		args = append(args, "--interface", cfg.interfaceName)
	}
	if err = eventlog.InstallAsEventCreate(serviceName, eventlog.Info|eventlog.Warning|eventlog.Error); err != nil {
		log.Printf("event log source was not installed: %v", err)
	}
	created, err := manager.CreateService(serviceName, serviceExe, mgr.Config{
		DisplayName:      serviceDisplayName,
		Description:      serviceDescription,
		StartType:        mgr.StartAutomatic,
		DelayedAutoStart: true,
		ServiceStartName: account,
	}, args...)
	if err != nil {
		return fmt.Errorf("failed to create the Velum service: %w", err)
	}
	defer created.Close()
	recovery := []mgr.RecoveryAction{
		{Type: mgr.ServiceRestart, Delay: 5 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 15 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 60 * time.Second},
	}
	if err = created.SetRecoveryActions(recovery, 3600); err != nil {
		_ = created.Delete()
		return fmt.Errorf("failed to configure service recovery: %w", err)
	}
	if err = created.SetRecoveryActionsOnNonCrashFailures(true); err != nil {
		_ = created.Delete()
		return fmt.Errorf("failed to configure recovery on non-crash failures: %w", err)
	}
	if err = created.Start(); err != nil {
		_ = created.Delete()
		return fmt.Errorf("failed to start the Velum service: %w", err)
	}
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		status, queryErr := created.Query()
		if queryErr == nil && status.State == svc.Running {
			return nil
		}
		time.Sleep(250 * time.Millisecond)
	}
	return errors.New("the Velum service did not reach the running state; inspect the Windows event log")
}

func uninstallService() error {
	if err := requireElevation(); err != nil {
		return err
	}
	manager, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("failed to connect to the service manager: %w", err)
	}
	defer manager.Disconnect()
	service, err := manager.OpenService(serviceName)
	if err != nil {
		return errors.New("the Velum service is not installed")
	}
	status, _ := service.Query()
	if status.State != svc.Stopped {
		if _, err = service.Control(svc.Stop); err != nil {
			_ = service.Close()
			return fmt.Errorf("failed to stop the Velum service: %w", err)
		}
		deadline := time.Now().Add(15 * time.Second)
		for time.Now().Before(deadline) {
			status, _ = service.Query()
			if status.State == svc.Stopped {
				break
			}
			time.Sleep(250 * time.Millisecond)
		}
	}
	if err = service.Delete(); err != nil {
		_ = service.Close()
		return fmt.Errorf("failed to delete the Velum service: %w", err)
	}
	_ = service.Close()
	_ = eventlog.Remove(serviceName)
	if dir, dirErr := serviceDataDir(); dirErr == nil {
		_ = os.RemoveAll(filepath.Join(dir, "bin"))
	}
	return nil
}

type velumWindowsService struct {
	cfg daemonConfig
}

func (h *velumWindowsService) Execute(_ []string, requests <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	eventLog, _ := eventlog.Open(serviceName)
	logInfo := func(message string) {
		log.Print(message)
		if eventLog != nil {
			_ = eventLog.Info(1, message)
		}
	}
	logError := func(message string) {
		log.Print(message)
		if eventLog != nil {
			_ = eventLog.Error(1, message)
		}
	}
	defer func() {
		if eventLog != nil {
			_ = eventLog.Close()
		}
	}()
	status <- svc.Status{State: svc.StartPending}
	mutexName, _ := windows.UTF16PtrFromString(`Global\VelumServiceInstance`)
	mutex, err := windows.CreateMutex(nil, false, mutexName)
	if err == windows.ERROR_ALREADY_EXISTS {
		_ = windows.CloseHandle(mutex)
		logError("another Velum instance is already running")
		return false, 1
	}
	if err != nil {
		logError(fmt.Sprintf("failed to create the instance mutex: %v", err))
		return false, 1
	}
	defer windows.CloseHandle(mutex)
	if err = initChildJob(); err != nil {
		logError(fmt.Sprintf("failed to create the child process job: %v", err))
		return false, 1
	}
	h.cfg.managedBy = "windows-service"
	runtime, err := prepareDaemon(h.cfg)
	if err != nil {
		logError(err.Error())
		return false, 1
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- runtime.serve(ctx) }()
	status <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	logInfo("Velum service started")
	for {
		select {
		case request := <-requests:
			switch request.Cmd {
			case svc.Interrogate:
				status <- request.CurrentStatus
			case svc.Stop, svc.Shutdown:
				status <- svc.Status{State: svc.StopPending}
				cancel()
				select {
				case <-done:
				case <-time.After(12 * time.Second):
					logError("network engine did not stop within the timeout")
				}
				logInfo("Velum service stopped")
				return false, 0
			}
		case err := <-done:
			if err != nil {
				logError(err.Error())
				return false, 1
			}
			logInfo("Velum service finished")
			return false, 0
		}
	}
}

func runAsService(cfg daemonConfig) error {
	isService, err := svc.IsWindowsService()
	if err != nil {
		return fmt.Errorf("failed to detect the service context: %w", err)
	}
	if !isService {
		return errors.New("--service run must be started by the Windows service manager")
	}
	return svc.Run(serviceName, &velumWindowsService{cfg: cfg})
}
