//go:build windows

package main

import (
	"errors"
	"fmt"
	"os/exec"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

// childJob bounds the lifetime of sing-box and Xray to the daemon process.
// If velumd crashes, Windows closes the job handle and terminates the tree.
var childJob windows.Handle

func initChildJob() error {
	if childJob != 0 {
		return nil
	}
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return err
	}
	info := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	info.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err = windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&info)), uint32(unsafe.Sizeof(info))); err != nil {
		_ = windows.CloseHandle(job)
		return err
	}
	childJob = job
	return nil
}

func configureChild(cmd *exec.Cmd) {
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.HideWindow = true
	cmd.SysProcAttr.CreationFlags |= windows.CREATE_NEW_PROCESS_GROUP
}

func afterStart(cmd *exec.Cmd) error {
	if childJob == 0 {
		// Console mode has no service job; the process lifetime is bounded by
		// the daemon itself.
		return nil
	}
	if cmd == nil || cmd.Process == nil {
		return errors.New("cannot attach a process that has not started")
	}
	process, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE|windows.SYNCHRONIZE, false, uint32(cmd.Process.Pid))
	if err != nil {
		return fmt.Errorf("failed to open child process %d: %w", cmd.Process.Pid, err)
	}
	defer windows.CloseHandle(process)
	if err = windows.AssignProcessToJobObject(childJob, process); err != nil {
		return fmt.Errorf("failed to attach child process %d to the service job: %w", cmd.Process.Pid, err)
	}
	return nil
}

func interruptProcess(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	// A service has no console, so CTRL_BREAK is best effort. The caller
	// terminates the process after a bounded grace period.
	_ = windows.GenerateConsoleCtrlEvent(windows.CTRL_BREAK_EVENT, uint32(cmd.Process.Pid))
}
