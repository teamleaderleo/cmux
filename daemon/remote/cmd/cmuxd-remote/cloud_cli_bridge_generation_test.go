package main

import (
	"context"
	"io"
	"net"
	"os"
	"path/filepath"
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
		_, err := os.Lstat(socketPath)
		if os.IsNotExist(err) {
			break
		}
		if err != nil {
			t.Fatalf("stat bridge socket during first-owner retirement: %v", err)
		}
		if time.Now().After(deadline) {
			t.Fatal("first bridge did not release its socket ownership")
		}
		time.Sleep(10 * time.Millisecond)
	}

	if err := bridgeB.start(ctxB, socketPath, io.Discard); err != nil {
		t.Fatalf("start successor after first owner retired: %v", err)
	}
	conn, err = net.DialTimeout("unix", socketPath, time.Second)
	if err != nil {
		t.Fatalf("successor bridge is not dialable after ownership handoff: %v", err)
	}
	_ = conn.Close()
}
