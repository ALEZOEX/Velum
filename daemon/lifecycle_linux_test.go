//go:build linux

package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// TestHelperProcess implements the helper process pattern for lifecycle testing.
// It acts as mock child or mock parent processes without external binary dependencies.
func TestHelperProcess(t *testing.T) {
	if os.Getenv("GO_WANT_HELPER_PROCESS") != "1" {
		return
	}

	args := os.Args
	for len(args) > 0 {
		if args[0] == "--" {
			args = args[1:]
			break
		}
		args = args[1:]
	}
	if len(args) == 0 {
		os.Exit(2)
	}

	switch args[0] {
	case "child":
		sigChan := make(chan os.Signal, 2)
		signal.Notify(sigChan, syscall.SIGTERM, os.Interrupt)
		fmt.Println("CHILD_READY")
		<-sigChan
		os.Exit(0)

	case "child_quick_exit":
		fmt.Println("CHILD_EXITING")
		os.Exit(0)

	case "parent":
		child := exec.Command(os.Args[0], "-test.run=TestHelperProcess", "--", "child")
		child.Env = append(os.Environ(), "GO_WANT_HELPER_PROCESS=1")
		configureChild(child)
		stdout, err := child.StdoutPipe()
		if err != nil {
			os.Exit(3)
		}
		if err := child.Start(); err != nil {
			os.Exit(4)
		}
		reader := bufio.NewReader(stdout)
		line, err := reader.ReadString('\n')
		if err != nil || !strings.Contains(line, "CHILD_READY") {
			_ = child.Process.Kill()
			os.Exit(5)
		}
		fmt.Printf("CHILD_PID=%d\n", child.Process.Pid)
		// Block indefinitely until killed by the test runner
		select {}

	case "foreign":
		sigChan := make(chan os.Signal, 2)
		signal.Notify(sigChan, syscall.SIGTERM, os.Interrupt)
		fmt.Println("FOREIGN_READY")
		<-sigChan
		os.Exit(0)
	}

	os.Exit(0)
}

func isProcessDead(pid int) bool {
	if pid <= 0 {
		return true
	}
	err := syscall.Kill(pid, 0)
	if err == syscall.ESRCH {
		return true
	}
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return true
	}
	s := string(data)
	idx := strings.LastIndex(s, ")")
	if idx >= 0 && idx+2 < len(s) {
		state := s[idx+2]
		if state == 'Z' {
			return true
		}
	}
	return false
}

func waitForProcessDeath(pid int, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if isProcessDead(pid) {
			return true
		}
		time.Sleep(50 * time.Millisecond)
	}
	return isProcessDead(pid)
}

func startHelperParent(t *testing.T) (*exec.Cmd, int) {
	t.Helper()
	parent := exec.Command(os.Args[0], "-test.run=TestHelperProcess", "--", "parent")
	parent.Env = append(os.Environ(), "GO_WANT_HELPER_PROCESS=1")
	stdout, err := parent.StdoutPipe()
	if err != nil {
		t.Fatalf("failed to create stdout pipe: %v", err)
	}
	if err := parent.Start(); err != nil {
		t.Fatalf("failed to start parent helper: %v", err)
	}

	scanner := bufio.NewScanner(stdout)
	var childPID int
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "CHILD_PID=") {
			childPID, _ = strconv.Atoi(strings.TrimPrefix(line, "CHILD_PID="))
			break
		}
	}
	if childPID <= 0 {
		_ = parent.Process.Kill()
		_ = parent.Wait()
		t.Fatalf("did not receive valid CHILD_PID from parent helper")
	}
	return parent, childPID
}

// TestLinuxLifecycle_SIGKILLParent tests that when the parent process (velumd)
// is killed with SIGKILL (which cannot be caught and runs no cleanup code),
// the Linux kernel delivers Pdeathsig (SIGTERM) to the child process (sing-box/Xray),
// ensuring it terminates and does not become a persistent orphan.
func TestLinuxLifecycle_SIGKILLParent(t *testing.T) {
	parent, childPID := startHelperParent(t)
	defer func() {
		if parent.Process != nil {
			_ = parent.Process.Kill()
			_ = parent.Wait()
		}
	}()

	if isProcessDead(childPID) {
		t.Fatalf("child process %d should be running", childPID)
	}

	// Terminate parent abruptly with SIGKILL
	if err := parent.Process.Signal(syscall.SIGKILL); err != nil {
		t.Fatalf("failed to send SIGKILL to parent: %v", err)
	}
	_ = parent.Wait()

	if !waitForProcessDeath(childPID, 5*time.Second) {
		t.Fatalf("child process %d survived parent SIGKILL; Pdeathsig failed to terminate it", childPID)
	}
}

// TestLinuxLifecycle_SIGTERMParent tests that when the parent process is killed
// with SIGTERM, the child process receives Pdeathsig and exits.
func TestLinuxLifecycle_SIGTERMParent(t *testing.T) {
	parent, childPID := startHelperParent(t)
	defer func() {
		if parent.Process != nil {
			_ = parent.Process.Kill()
			_ = parent.Wait()
		}
	}()

	if isProcessDead(childPID) {
		t.Fatalf("child process %d should be running", childPID)
	}

	if err := parent.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatalf("failed to send SIGTERM to parent: %v", err)
	}
	_ = parent.Wait()

	if !waitForProcessDeath(childPID, 5*time.Second) {
		t.Fatalf("child process %d survived parent SIGTERM", childPID)
	}
}

// TestLinuxLifecycle_GracefulStopCoreAndIdempotency tests graceful shutdown via
// stopProcess(), verifying timeout handling, idempotency, and nil safety.
func TestLinuxLifecycle_GracefulStopCoreAndIdempotency(t *testing.T) {
	child := exec.Command(os.Args[0], "-test.run=TestHelperProcess", "--", "child")
	child.Env = append(os.Environ(), "GO_WANT_HELPER_PROCESS=1")
	configureChild(child)
	stdout, err := child.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}

	reader := bufio.NewReader(stdout)
	line, err := reader.ReadString('\n')
	if err != nil || !strings.Contains(line, "CHILD_READY") {
		_ = child.Process.Kill()
		t.Fatalf("child failed to start properly: %v", err)
	}

	pid := child.Process.Pid
	done := make(chan struct{})
	go func() {
		_ = child.Wait()
		close(done)
	}()

	// 1. Graceful stop
	stopProcess(child, done)
	if !waitForProcessDeath(pid, 3*time.Second) {
		t.Fatalf("child process %d was not stopped gracefully", pid)
	}

	// 2. Idempotent stop: calling stopProcess on already-stopped child must return immediately
	select {
	case <-done:
	default:
		t.Fatal("done channel must be closed")
	}
	stopProcess(child, done)

	// 3. Nil safety
	stopProcess(nil, nil)
}

// TestLinuxLifecycle_AlreadyTerminatedChild tests that if a child process exits
// on its own, stopProcess does not hang or error out.
func TestLinuxLifecycle_AlreadyTerminatedChild(t *testing.T) {
	child := exec.Command(os.Args[0], "-test.run=TestHelperProcess", "--", "child_quick_exit")
	child.Env = append(os.Environ(), "GO_WANT_HELPER_PROCESS=1")
	configureChild(child)
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		_ = child.Wait()
		close(done)
	}()

	// Wait for child to exit on its own
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		_ = child.Process.Kill()
		t.Fatal("child did not exit quickly")
	}

	// Now call stopProcess on the already-terminated child
	stopProcess(child, done)
}

// TestLinuxLifecycle_NoInterferenceWithForeignProcesses tests that Velum never
// terminates or signals foreign processes (such as sing-box/Xray started by Happ).
func TestLinuxLifecycle_NoInterferenceWithForeignProcesses(t *testing.T) {
	// Start an external/foreign process
	foreign := exec.Command(os.Args[0], "-test.run=TestHelperProcess", "--", "foreign")
	foreign.Env = append(os.Environ(), "GO_WANT_HELPER_PROCESS=1")
	stdout, err := foreign.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := foreign.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if foreign.Process != nil {
			_ = foreign.Process.Kill()
			_ = foreign.Wait()
		}
	}()

	reader := bufio.NewReader(stdout)
	line, err := reader.ReadString('\n')
	if err != nil || !strings.Contains(line, "FOREIGN_READY") {
		t.Fatalf("foreign process failed to start: %v", err)
	}
	foreignPID := foreign.Process.Pid

	// Start and stop our own separate child
	child := exec.Command(os.Args[0], "-test.run=TestHelperProcess", "--", "child")
	child.Env = append(os.Environ(), "GO_WANT_HELPER_PROCESS=1")
	configureChild(child)
	childOut, err := child.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	cReader := bufio.NewReader(childOut)
	cLine, err := cReader.ReadString('\n')
	if err != nil || !strings.Contains(cLine, "CHILD_READY") {
		_ = child.Process.Kill()
		t.Fatalf("child process failed to start: %v", err)
	}
	childPID := child.Process.Pid
	done := make(chan struct{})
	go func() {
		_ = child.Wait()
		close(done)
	}()

	// Stop our child
	stopProcess(child, done)
	if !waitForProcessDeath(childPID, 3*time.Second) {
		t.Fatalf("child process %d should be dead", childPID)
	}

	// Verify foreign process is completely unharmed and still running
	if isProcessDead(foreignPID) {
		t.Fatalf("foreign process %d was killed! Velum interfered with a foreign process", foreignPID)
	}
}

// TestLinuxLifecycle_RestartAfterCrash tests that after a simulated crash
// and child cleanup via Pdeathsig, a second instance can immediately start.
func TestLinuxLifecycle_RestartAfterCrash(t *testing.T) {
	// First cycle: crash parent
	parent1, child1 := startHelperParent(t)
	_ = parent1.Process.Signal(syscall.SIGKILL)
	_ = parent1.Wait()
	if !waitForProcessDeath(child1, 5*time.Second) {
		t.Fatalf("first child %d did not terminate after parent SIGKILL", child1)
	}

	// Second cycle: immediate restart
	parent2, child2 := startHelperParent(t)
	defer func() {
		if parent2.Process != nil {
			_ = parent2.Process.Kill()
			_ = parent2.Wait()
		}
	}()

	if isProcessDead(child2) {
		t.Fatalf("second child %d failed to start after first instance crash", child2)
	}

	_ = parent2.Process.Signal(syscall.SIGKILL)
	_ = parent2.Wait()
	if !waitForProcessDeath(child2, 5*time.Second) {
		t.Fatalf("second child %d did not terminate after second parent SIGKILL", child2)
	}
}
