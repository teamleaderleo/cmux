package main

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

const defaultCloudCLIBridgeSocketPath = "/tmp/cmux-cloud-cli.sock"

type cloudCLIResponse struct {
	data []byte
	err  string
}

type cloudCLIForwardTarget struct {
	server    *rpcServer
	requestID string
}

type cloudCLIBridge struct {
	mu       sync.Mutex
	nextID   uint64
	servers  map[*rpcServer]struct{}
	pending  map[string]chan cloudCLIResponse
	listener net.Listener
}

func newCloudCLIBridge() *cloudCLIBridge {
	return &cloudCLIBridge{
		servers: map[*rpcServer]struct{}{},
		pending: map[string]chan cloudCLIResponse{},
	}
}

func defaultCloudCLIBridgeSocketIfExists() string {
	if info, err := os.Stat(defaultCloudCLIBridgeSocketPath); err == nil && info.Mode()&os.ModeSocket != 0 {
		return defaultCloudCLIBridgeSocketPath
	}
	return ""
}

func acquireCloudCLIBridgeSocketLock(socketPath string) (*os.File, error) {
	lockPath := socketPath + ".lock"
	fd, err := unix.Open(
		lockPath,
		unix.O_CREAT|unix.O_RDWR|unix.O_CLOEXEC|unix.O_NOFOLLOW|unix.O_NONBLOCK,
		0o600,
	)
	if err != nil {
		return nil, err
	}
	lockFile := os.NewFile(uintptr(fd), lockPath)
	if lockFile == nil {
		_ = unix.Close(fd)
		return nil, fmt.Errorf("failed to wrap cloud CLI bridge lock %q", lockPath)
	}
	closeWithError := func(err error) (*os.File, error) {
		_ = lockFile.Close()
		return nil, err
	}

	var stat unix.Stat_t
	if err := unix.Fstat(fd, &stat); err != nil {
		return closeWithError(err)
	}
	if stat.Mode&unix.S_IFMT != unix.S_IFREG {
		return closeWithError(fmt.Errorf("cloud CLI bridge lock %q is not a regular file", lockPath))
	}
	if stat.Nlink != 1 {
		return closeWithError(fmt.Errorf("cloud CLI bridge lock %q has unexpected hard links", lockPath))
	}
	if stat.Uid != uint32(os.Geteuid()) {
		return closeWithError(fmt.Errorf("cloud CLI bridge lock %q is owned by another user", lockPath))
	}
	if err := unix.Fchmod(fd, 0o600); err != nil {
		return closeWithError(err)
	}
	if err := unix.Fstat(fd, &stat); err != nil {
		return closeWithError(err)
	}
	if stat.Mode&0o077 != 0 {
		return closeWithError(fmt.Errorf("cloud CLI bridge lock %q is not private", lockPath))
	}
	if err := unix.Flock(fd, unix.LOCK_EX|unix.LOCK_NB); err != nil {
		_ = lockFile.Close()
		if errors.Is(err, unix.EWOULDBLOCK) || errors.Is(err, unix.EAGAIN) {
			return nil, fmt.Errorf("cloud CLI bridge socket %q is already owned", socketPath)
		}
		return nil, err
	}
	return lockFile, nil
}

func releaseCloudCLIBridgeSocketLock(lockFile *os.File) {
	if lockFile == nil {
		return
	}
	_ = unix.Flock(int(lockFile.Fd()), unix.LOCK_UN)
	_ = lockFile.Close()
}

func (b *cloudCLIBridge) start(ctx context.Context, socketPath string, stderr io.Writer) error {
	if b == nil {
		return nil
	}
	socketPath = stringsTrimSpaceOrDefault(socketPath, defaultCloudCLIBridgeSocketPath)
	if err := os.MkdirAll(filepath.Dir(socketPath), 0o755); err != nil {
		return err
	}
	socketLock, err := acquireCloudCLIBridgeSocketLock(socketPath)
	if err != nil {
		return err
	}
	lockOwned := true
	defer func() {
		if lockOwned {
			releaseCloudCLIBridgeSocketLock(socketLock)
		}
	}()

	_ = os.Remove(socketPath)
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		return err
	}
	if err := os.Chmod(socketPath, 0o666); err != nil {
		_ = listener.Close()
		_ = os.Remove(socketPath)
		return err
	}
	b.mu.Lock()
	b.listener = listener
	b.mu.Unlock()
	_, _ = fmt.Fprintf(stderr, "cmuxd-remote cloud CLI bridge listening on %s\n", socketPath)
	go func() {
		<-ctx.Done()
		_ = listener.Close()
	}()
	go b.acceptLoop(listener, socketPath, stderr, socketLock)
	lockOwned = false
	return nil
}

func (b *cloudCLIBridge) acceptLoop(listener net.Listener, socketPath string, stderr io.Writer, socketLock *os.File) {
	defer releaseCloudCLIBridgeSocketLock(socketLock)
	defer os.Remove(socketPath)
	for {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		go b.handleConn(conn)
	}
}

func (b *cloudCLIBridge) register(server *rpcServer) func() {
	if b == nil || server == nil {
		return func() {}
	}
	b.mu.Lock()
	b.servers[server] = struct{}{}
	b.mu.Unlock()
	return func() {
		b.mu.Lock()
		delete(b.servers, server)
		b.mu.Unlock()
	}
}

func (b *cloudCLIBridge) handleConn(conn net.Conn) {
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(16 * time.Second))
	reader := bufio.NewReaderSize(conn, maxRPCFrameBytes)
	line, oversized, err := readRPCFrame(reader, maxRPCFrameBytes)
	if err != nil {
		return
	}
	if oversized {
		_, _ = conn.Write([]byte(`{"ok":false,"error":{"code":"request_too_large","message":"cloud CLI request exceeded maximum size"}}` + "\n"))
		return
	}
	response, err := b.forward(line)
	if err != nil {
		_, _ = conn.Write([]byte(fmt.Sprintf(`{"ok":false,"error":{"code":"cloud_cli_unavailable","message":%q}}`+"\n", err.Error())))
		return
	}
	_, _ = conn.Write(response)
	if len(response) == 0 || response[len(response)-1] != '\n' {
		_, _ = conn.Write([]byte("\n"))
	}
}

func (b *cloudCLIBridge) forward(request []byte) ([]byte, error) {
	targets, responseCh := b.reserveRequests()
	if len(targets) == 0 {
		return nil, errors.New("no cmux app is attached to this cloud VM")
	}

	dataBase64 := base64.StdEncoding.EncodeToString(request)
	sentTargets := make([]cloudCLIForwardTarget, 0, len(targets))
	var writeErr error
	for _, target := range targets {
		if err := target.server.frameWriter.writeEvent(rpcEvent{
			Event:      "cli.request",
			RequestID:  target.requestID,
			DataBase64: dataBase64,
		}); err != nil {
			b.forgetRequest(target.requestID)
			writeErr = err
			continue
		}
		sentTargets = append(sentTargets, target)
	}
	if len(sentTargets) == 0 {
		if writeErr != nil {
			return nil, writeErr
		}
		return nil, errors.New("no cmux app accepted cloud CLI request")
	}

	defer b.forgetRequests(sentTargets)
	var firstRoutingRejection []byte
	var firstResponseErr string
	pending := len(sentTargets)
	timeout := time.After(15 * time.Second)
	select {
	case <-timeout:
		return nil, errors.New("timed out waiting for cmux app response")
	default:
	}
	for pending > 0 {
		select {
		case response := <-responseCh:
			pending--
			if response.err != "" {
				if firstResponseErr == "" {
					firstResponseErr = response.err
				}
				continue
			}
			if len(sentTargets) > 1 && isCloudCLIWorkspaceRoutingRejection(response.data) {
				if firstRoutingRejection == nil {
					firstRoutingRejection = response.data
				}
				continue
			}
			return response.data, nil
		case <-timeout:
			return nil, errors.New("timed out waiting for cmux app response")
		}
	}
	if firstRoutingRejection != nil {
		return firstRoutingRejection, nil
	}
	if firstResponseErr != "" {
		return nil, errors.New(firstResponseErr)
	}
	return nil, errors.New("cmux app rejected cloud CLI request")
}

func (b *cloudCLIBridge) reserveRequests() ([]cloudCLIForwardTarget, chan cloudCLIResponse) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if len(b.servers) == 0 {
		return nil, nil
	}
	responseCh := make(chan cloudCLIResponse, len(b.servers))
	targets := make([]cloudCLIForwardTarget, 0, len(b.servers))
	for server := range b.servers {
		b.nextID++
		requestID := fmt.Sprintf("cli-%d", b.nextID)
		b.pending[requestID] = responseCh
		targets = append(targets, cloudCLIForwardTarget{server: server, requestID: requestID})
	}
	return targets, responseCh
}

func (b *cloudCLIBridge) forgetRequest(requestID string) {
	b.mu.Lock()
	delete(b.pending, requestID)
	b.mu.Unlock()
}

func (b *cloudCLIBridge) forgetRequests(targets []cloudCLIForwardTarget) {
	b.mu.Lock()
	for _, target := range targets {
		delete(b.pending, target.requestID)
	}
	b.mu.Unlock()
}

func (b *cloudCLIBridge) deliverResponse(requestID string, response cloudCLIResponse) bool {
	b.mu.Lock()
	ch := b.pending[requestID]
	if ch != nil {
		delete(b.pending, requestID)
	}
	b.mu.Unlock()
	if ch == nil {
		return false
	}
	ch <- response
	return true
}

func (s *rpcServer) handleCLIResponse(req rpcRequest) rpcResponse {
	if s.cliBridge == nil {
		return rpcResponse{ID: req.ID, OK: false, Error: &rpcError{Code: "unavailable", Message: "cloud CLI bridge is not enabled"}}
	}
	requestID, ok := getStringParam(req.Params, "request_id")
	if !ok || requestID == "" {
		return rpcResponse{ID: req.ID, OK: false, Error: &rpcError{Code: "invalid_params", Message: "cli.response requires request_id"}}
	}
	responseOK := true
	if raw, exists := req.Params["ok"]; exists {
		if typed, isBool := raw.(bool); isBool {
			responseOK = typed
		}
	}
	var response cloudCLIResponse
	if responseOK {
		dataBase64, ok := getStringParam(req.Params, "data_base64")
		if !ok {
			return rpcResponse{ID: req.ID, OK: false, Error: &rpcError{Code: "invalid_params", Message: "cli.response requires data_base64"}}
		}
		data, err := base64.StdEncoding.DecodeString(dataBase64)
		if err != nil {
			return rpcResponse{ID: req.ID, OK: false, Error: &rpcError{Code: "invalid_params", Message: "data_base64 must be valid base64"}}
		}
		response.data = data
	} else {
		response.err, _ = getStringParam(req.Params, "error")
		if response.err == "" {
			response.err = "cmux app rejected cloud CLI request"
		}
	}
	if !s.cliBridge.deliverResponse(requestID, response) {
		return rpcResponse{ID: req.ID, OK: false, Error: &rpcError{Code: "not_found", Message: "cloud CLI request not found"}}
	}
	return rpcResponse{ID: req.ID, OK: true, Result: map[string]any{"delivered": true}}
}

func isCloudCLIWorkspaceRoutingRejection(data []byte) bool {
	var envelope struct {
		OK    bool `json:"ok"`
		Error *struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(data, &envelope); err != nil {
		return false
	}
	if envelope.OK || envelope.Error == nil {
		return false
	}
	return envelope.Error.Code == "remote_cli_workspace_denied" ||
		envelope.Error.Code == "remote_cli_unscoped"
}

func stringsTrimSpaceOrDefault(value string, fallback string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return fallback
	}
	return value
}
