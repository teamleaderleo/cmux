package main

import (
	"context"
	"io"
	"net"
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
