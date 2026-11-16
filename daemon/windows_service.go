//go:build windows

package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
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

func installService(cfg daemonConfig, account string) error {
	var tree *serviceTree
	var manager *mgr.Mgr
	var created *mgr.Service
	defer func() {
		if created != nil {
			_ = created.Close()
		}
		if manager != nil {
			_ = manager.Disconnect()
		}
		if tree != nil {
			tree.close()
		}
	}()
	var currentExe string
	explicitToken := cfg.tokenFile
	return runServiceInstall(serviceInstallPlan{
		elevate: requireElevation,
		prepare: func() error {
			if err := resolvePaths(&cfg); err != nil {
				return err
			}
			dataDir, err := serviceDataDir()
			if err != nil {
				return err
			}
			tokenPath := filepath.Join(dataDir, "token")
			if explicitToken != "" && !strings.EqualFold(explicitToken, tokenPath) {
				return errors.New("service token must be the canonical ProgramData/Velum/token; external token paths are refused")
			}
			cfg.tokenFile = tokenPath
			currentExe, err = os.Executable()
			if err != nil {
				return err
			}
			manager, err = mgr.Connect()
			if err != nil {
				return err
			}
			existing, err := manager.OpenService(serviceName)
			if err == nil {
				_ = existing.Close()
				return errors.New("Velum service is already installed; no files were changed; uninstall before reinstalling")
			}
			if !errors.Is(err, windows.ERROR_SERVICE_DOES_NOT_EXIST) {
				return fmt.Errorf("cannot establish service absence: %w", err)
			}
			tree, err = openServiceTree(true)
			return err
		},
		files: []func() error{
			func() error { return tree.ensureToken() },
			func() error { return tree.copyExecutable(currentExe, "velumd.exe") },
			func() error { return tree.copyExecutable(cfg.core, "sing-box.exe") },
			func() error {
				if cfg.xray != "" {
					return tree.copyExecutable(cfg.xray, "xray.exe")
				}
				return nil
			},
		},
		verify: func() error { return tree.verify() },
		register: func() error {
			binDir := filepath.Join(tree.dir, "bin")
			args := []string{"--service", "run", "--core", filepath.Join(binDir, "sing-box.exe"), "--token-file", cfg.tokenFile}
			if cfg.tunAllowed {
				args = append(args, "--tun")
			}
			if cfg.xray != "" {
				args = append(args, "--xray", filepath.Join(binDir, "xray.exe"))
			}
			if cfg.interfaceName != "" {
				args = append(args, "--interface", cfg.interfaceName)
			}
			var err error
			created, err = manager.CreateService(serviceName, filepath.Join(binDir, "velumd.exe"), mgr.Config{
				DisplayName: serviceDisplayName, Description: serviceDescription, StartType: mgr.StartAutomatic, DelayedAutoStart: true, ServiceStartName: account,
			}, args...)
			if err != nil {
				return fmt.Errorf("register verified service: %w", err)
			}
			if err = eventlog.InstallAsEventCreate(serviceName, eventlog.Info|eventlog.Warning|eventlog.Error); err != nil {
				log.Printf("event log source was not installed: %v", err)
			}
			return nil
		},
		start: func() error {
			// Re-read descriptors after registration as well, before first execution.
			if err := tree.verify(); err != nil {
				return err
			}
			recovery := []mgr.RecoveryAction{{Type: mgr.ServiceRestart, Delay: 5 * time.Second}, {Type: mgr.ServiceRestart, Delay: 15 * time.Second}, {Type: mgr.ServiceRestart, Delay: 60 * time.Second}}
			if err := created.SetRecoveryActions(recovery, 3600); err != nil {
				return err
			}
			if err := created.SetRecoveryActionsOnNonCrashFailures(true); err != nil {
				return err
			}
			if err := created.Start(); err != nil {
				return fmt.Errorf("start verified service: %w", err)
			}
			deadline := time.Now().Add(20 * time.Second)
			for time.Now().Before(deadline) {
				status, err := created.Query()
				if err != nil {
					return err
				}
				if status.State == svc.Running {
					return nil
				}
				time.Sleep(250 * time.Millisecond)
			}
			return errors.New("service did not reach running state; inspect the Windows event log")
		},
		rollback: func() error {
			disable := windows.ChangeServiceConfig(created.Handle, windows.SERVICE_NO_CHANGE, windows.SERVICE_DISABLED, windows.SERVICE_NO_CHANGE, nil, nil, nil, nil, nil, nil, nil)
			_, stop := created.Control(svc.Stop)
			if errors.Is(stop, windows.ERROR_SERVICE_NOT_ACTIVE) {
				stop = nil
			}
			return errors.Join(disable, stop, created.Delete())
		},
	})
}

func uninstallService() error {
	var tree *serviceTree
	defer func() {
		if tree != nil {
			tree.close()
		}
	}()
	return runServiceRemoval(requireElevation, func() error {
		var err error
		tree, err = openServiceTree(false)
		if err != nil {
			return err
		}
		return tree.verify()
	}, func() error { return uninstallVerifiedService(tree) })
}

func uninstallVerifiedService(tree *serviceTree) error {
	manager, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer manager.Disconnect()
	service, err := manager.OpenService(serviceName)
	if err != nil {
		return fmt.Errorf("open service for uninstall: %w", err)
	}
	defer service.Close()
	status, err := service.Query()
	if err != nil {
		return err
	}
	if status.State != svc.Stopped {
		if _, err = service.Control(svc.Stop); err != nil {
			return err
		}
		deadline := time.Now().Add(15 * time.Second)
		for time.Now().Before(deadline) {
			status, err = service.Query()
			if err != nil {
				return err
			}
			if status.State == svc.Stopped {
				break
			}
			time.Sleep(250 * time.Millisecond)
		}
		if status.State != svc.Stopped {
			return errors.New("service did not stop; no files were removed")
		}
	}
	if err = tree.verify(); err != nil {
		return err
	}
	if err = service.Delete(); err != nil {
		return err
	}
	_ = eventlog.Remove(serviceName)
	return tree.removeBinaries()
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
