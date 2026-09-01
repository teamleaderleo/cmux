package main

import (
	"context"
	"io"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestCloudCLIBridgeRejectsOverlappingSocketOwner(t *testing.T) {
	socketPath := filepath.Join(t.TempDir(), "cmux-cloud-cli.sock")

	ctxA, cancelA := context.WithCancel(context.Background())
	bridgeA := newCloudCLIBridge()
	if err := bridgeA.start(ctxA, socketPath, io.Discard); err != nil {
		t.Fatalf("start first bridge: %v", err)
	}

	ctxB, cancelB := context.WithCancel(context.Background())
	defer cancelB()
	bridgeB := newCloudCLIBridge()
	if err := bridgeB.start(ctxB, socketPath, io.Discard); err == nil {
		cancelA()
		t.Fatal("second bridge took over the socket while the first owner was still alive")
	}

	conn, err := net.DialTimeout("unix", socketPath, time.Second)
	if err != nil {
		cancelA()
		t.Fatalf("first bridge stopped being dialable after rejected overlap: %v", err)
	}
	_ = conn.Close()

	cancelA()
	deadline := time.Now().Add(5 * time.Second)
	for {
		err = bridgeB.start(ctxB, socketPath, io.Discard)
		if err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("successor could not acquire socket after first owner retired: %v", err)
		}
		time.Sleep(10 * time.Millisecond)
	}

	conn, err = net.DialTimeout("unix", socketPath, time.Second)
	if err != nil {
		t.Fatalf("successor bridge is not dialable after ownership handoff: %v", err)
	}
	_ = conn.Close()
}

func TestCloudCLIBridgeRejectsSymlinkedSocketLock(t *testing.T) {
	dir := t.TempDir()
	socketPath := filepath.Join(dir, "cmux-cloud-cli.sock")
	lockPath := socketPath + ".lock"
	targetPath := filepath.Join(dir, "target")
	if err := os.WriteFile(targetPath, []byte("sentinel"), 0o644); err != nil {
		t.Fatalf("write target: %v", err)
	}
	if err := os.Symlink(targetPath, lockPath); err != nil {
		t.Fatalf("symlink lock: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := newCloudCLIBridge().start(ctx, socketPath, io.Discard); err == nil {
		t.Fatal("symlinked cloud CLI socket lock was accepted")
	}

	data, err := os.ReadFile(targetPath)
	if err != nil {
		t.Fatalf("read target: %v", err)
	}
	if string(data) != "sentinel" {
		t.Fatalf("symlink target content changed: %q", string(data))
	}
	info, err := os.Stat(targetPath)
	if err != nil {
		t.Fatalf("stat target: %v", err)
	}
	if info.Mode().Perm() != 0o644 {
		t.Fatalf("symlink target mode changed to %o", info.Mode().Perm())
	}
}

func TestCloudCLIBridgeRejectsFIFOSocketLockWithoutBlocking(t *testing.T) {
	socketPath := filepath.Join(t.TempDir(), "cmux-cloud-cli.sock")
	lockPath := socketPath + ".lock"
	if err := syscall.Mkfifo(lockPath, 0o600); err != nil {
		t.Fatalf("mkfifo lock: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	result := make(chan error, 1)
	go func() {
		result <- newCloudCLIBridge().start(ctx, socketPath, io.Discard)
	}()

	select {
	case err := <-result:
		if err == nil {
			t.Fatal("FIFO cloud CLI socket lock was accepted")
		}
	case <-time.After(time.Second):
		t.Fatal("opening a FIFO cloud CLI socket lock blocked before type validation")
	}
}

func TestCloudCLIBridgeRejectsHardLinkedSocketLockWithoutChmod(t *testing.T) {
	dir := t.TempDir()
	socketPath := filepath.Join(dir, "cmux-cloud-cli.sock")
	lockPath := socketPath + ".lock"
	aliasPath := filepath.Join(dir, "lock-alias")
	if err := os.WriteFile(lockPath, nil, 0o644); err != nil {
		t.Fatalf("write lock: %v", err)
	}
	if err := os.Link(lockPath, aliasPath); err != nil {
		t.Fatalf("hard link lock: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := newCloudCLIBridge().start(ctx, socketPath, io.Discard); err == nil {
		t.Fatal("hard-linked cloud CLI socket lock was accepted")
	}
	info, err := os.Stat(lockPath)
	if err != nil {
		t.Fatalf("stat lock: %v", err)
	}
	if info.Mode().Perm() != 0o644 {
		t.Fatalf("rejected hard-linked lock mode changed to %o", info.Mode().Perm())
	}
}

func TestCloudCLIBridgeMigratesOwnedSocketLockToPrivateMode(t *testing.T) {
	socketPath := filepath.Join(t.TempDir(), "cmux-cloud-cli.sock")
	lockPath := socketPath + ".lock"
	if err := os.WriteFile(lockPath, nil, 0o644); err != nil {
		t.Fatalf("write lock: %v", err)
	}
	if err := os.Chmod(lockPath, 0o644); err != nil {
		t.Fatalf("chmod lock fixture: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := newCloudCLIBridge().start(ctx, socketPath, io.Discard); err != nil {
		t.Fatalf("start bridge with owned lock: %v", err)
	}
	info, err := os.Stat(lockPath)
	if err != nil {
		t.Fatalf("stat lock: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("owned lock mode = %o, want 600", info.Mode().Perm())
	}
}
