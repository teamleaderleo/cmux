//go:build linux

package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"
)

func fieldworkLeaseTokenHash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func installPTYLeaseThroughAdminForTest(cfg wsPTYServerConfig, adminToken string, lease *wsLease) error {
	body, err := json.Marshal(wsLeaseInstallRequest{PTYLease: lease})
	if err != nil {
		return fmt.Errorf("marshal lease install: %w", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/admin/leases", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+adminToken)
	recorder := httptest.NewRecorder()
	handleWebSocketLeaseInstall(recorder, req, cfg)
	if recorder.Code != http.StatusOK {
		return fmt.Errorf("install replacement lease: status=%d body=%q", recorder.Code, recorder.Body.String())
	}
	return nil
}

func TestSingleUseLeaseConsumptionDoesNotDeleteReplacementGeneration(t *testing.T) {
	previousProcs := runtime.GOMAXPROCS(0)
	if previousProcs < 2 {
		runtime.GOMAXPROCS(2)
		t.Cleanup(func() { runtime.GOMAXPROCS(previousProcs) })
	}

	dir := t.TempDir()
	leasePath := filepath.Join(dir, "attach-lease.json")
	adminToken := "admin-token"
	cfg := wsPTYServerConfig{
		PTYAuthLeaseFile: leasePath,
		AdminTokenSHA256: fieldworkLeaseTokenHash(adminToken),
	}

	// ReadFile closes A before consumeWebSocketLease unmarshals and validates it.
	// A large but valid session id makes that post-read interval long enough for
	// an inotify waiter to deterministically publish B through the real admin
	// handler before A reaches its single-use pathname removal.
	sessionA := strings.Repeat("a", 32<<20)
	leaseA := &wsLease{
		Version:       1,
		TokenSHA256:   fieldworkLeaseTokenHash("token-a"),
		ExpiresAtUnix: time.Now().Add(time.Hour).Unix(),
		SessionID:     sessionA,
		SingleUse:     true,
	}
	leaseB := &wsLease{
		Version:       1,
		TokenSHA256:   fieldworkLeaseTokenHash("token-b"),
		ExpiresAtUnix: time.Now().Add(time.Hour).Unix(),
		SessionID:     "replacement-b",
		SingleUse:     true,
	}
	if err := writeLeaseFile(leasePath, leaseA); err != nil {
		t.Fatalf("write lease A: %v", err)
	}

	inotifyFD, err := syscall.InotifyInit1(syscall.IN_CLOEXEC)
	if err != nil {
		t.Fatalf("inotify init: %v", err)
	}
	t.Cleanup(func() { _ = syscall.Close(inotifyFD) })
	if _, err := syscall.InotifyAddWatch(inotifyFD, leasePath, syscall.IN_CLOSE_NOWRITE); err != nil {
		t.Fatalf("inotify watch lease: %v", err)
	}

	installed := make(chan struct{})
	installErr := make(chan error, 1)
	go func() {
		buf := make([]byte, 4096)
		for {
			if _, err := syscall.Read(inotifyFD, buf); err != nil {
				if errors.Is(err, syscall.EINTR) {
					continue
				}
				installErr <- err
				return
			}
			break
		}
		if err := installPTYLeaseThroughAdminForTest(cfg, adminToken, leaseB); err != nil {
			installErr <- err
			return
		}
		close(installed)
	}()

	consumeDone := make(chan error, 1)
	go func() {
		consumeDone <- consumeWebSocketLease(leasePath, wsAuthFrame{
			Token:     "token-a",
			SessionID: sessionA,
		})
	}()

	select {
	case err := <-installErr:
		t.Fatalf("publish replacement B after lease A read-close: %v", err)
	case <-installed:
	case <-time.After(10 * time.Second):
		t.Fatal("replacement B was not published")
	}

	select {
	case err := <-consumeDone:
		if err != nil {
			t.Fatalf("consume lease A: %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("lease A consumption did not settle")
	}

	data, err := os.ReadFile(leasePath)
	if errors.Is(err, os.ErrNotExist) {
		t.Fatal("single-use cleanup for lease A deleted replacement lease B")
	}
	if err != nil {
		t.Fatalf("read replacement lease B: %v", err)
	}
	var got wsLease
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("parse replacement lease B: %v", err)
	}
	if got.TokenSHA256 != leaseB.TokenSHA256 || got.SessionID != leaseB.SessionID {
		t.Fatalf("replacement lease changed: got token=%q session=%q", got.TokenSHA256, got.SessionID)
	}
}

func TestLeaseInstallAfterSingleUseConsumptionSurvives(t *testing.T) {
	dir := t.TempDir()
	leasePath := filepath.Join(dir, "attach-lease.json")
	adminToken := "admin-token"
	cfg := wsPTYServerConfig{
		PTYAuthLeaseFile: leasePath,
		AdminTokenSHA256: fieldworkLeaseTokenHash(adminToken),
	}
	leaseA := &wsLease{
		Version:       1,
		TokenSHA256:   fieldworkLeaseTokenHash("token-a"),
		ExpiresAtUnix: time.Now().Add(time.Hour).Unix(),
		SessionID:     "settled-a",
		SingleUse:     true,
	}
	leaseB := &wsLease{
		Version:       1,
		TokenSHA256:   fieldworkLeaseTokenHash("token-b"),
		ExpiresAtUnix: time.Now().Add(time.Hour).Unix(),
		SessionID:     "replacement-b",
		SingleUse:     true,
	}
	if err := writeLeaseFile(leasePath, leaseA); err != nil {
		t.Fatalf("write lease A: %v", err)
	}
	if err := consumeWebSocketLease(leasePath, wsAuthFrame{Token: "token-a", SessionID: "settled-a"}); err != nil {
		t.Fatalf("consume settled lease A: %v", err)
	}
	if err := installPTYLeaseThroughAdminForTest(cfg, adminToken, leaseB); err != nil {
		t.Fatalf("install replacement B after A settled: %v", err)
	}

	data, err := os.ReadFile(leasePath)
	if err != nil {
		t.Fatalf("read replacement lease B: %v", err)
	}
	var got wsLease
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("parse replacement lease B: %v", err)
	}
	if got.TokenSHA256 != leaseB.TokenSHA256 || got.SessionID != leaseB.SessionID {
		t.Fatalf("replacement lease changed: got token=%q session=%q", got.TokenSHA256, got.SessionID)
	}
}
