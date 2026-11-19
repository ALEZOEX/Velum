package main

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/netip"
	"time"
)

// The lifecycle gate serializes process and route ownership. The state mutex
// protects publications and command admission. Owners can take the state
// mutex, but a caller must release it before waiting for the gate.
func (s *service) tryLifecycle() bool {
	s.lifecycleOnce.Do(func() { s.lifecycle = make(chan struct{}, 1) })
	select {
	case s.lifecycle <- struct{}{}:
		return true
	default:
		return false
	}
}

func (s *service) enterLifecycle(ctx context.Context) error {
	s.lifecycleOnce.Do(func() { s.lifecycle = make(chan struct{}, 1) })
	select {
	case <-ctx.Done():
		return ctx.Err()
	case s.lifecycle <- struct{}{}:
		if err := ctx.Err(); err != nil {
			s.leaveLifecycle()
			return err
		}
		return nil
	}
}

func (s *service) leaveLifecycle() { <-s.lifecycle }

// JSON snapshots do not alias mutable session state. GET remains responsive
// even when a publication is already in progress.
func (s *service) ensureStatusCache() {
	s.statusOnce.Do(func() { s.mu.Lock(); defer s.mu.Unlock(); s.publishStatusLocked() })
}
func (s *service) publishStatusLocked() {
	data, e := json.Marshal(s.statusView())
	if e == nil {
		s.statusCache.Store(data)
	}
}
func (s *service) writeStatus(w http.ResponseWriter) {
	s.ensureStatusCache()
	if s.mu.TryLock() {
		s.publishStatusLocked()
		s.mu.Unlock()
	}
	_, _ = w.Write(s.statusCache.Load().([]byte))
}
func (s *service) controlCurrentLocked(epoch uint64) bool {
	return !s.closing && s.controlGeneration == epoch
}

func (s *service) beginControl(parent context.Context) (context.Context, uint64, context.CancelFunc) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.beginControlLocked(parent)
}

func (s *service) beginControlLocked(parent context.Context) (context.Context, uint64, context.CancelFunc) {
	if s.controlCancel != nil {
		s.controlCancel()
	}
	s.controlGeneration++
	ctx, cancel := context.WithCancel(parent)
	s.controlCancel = cancel
	if s.closing {
		cancel()
	}
	epoch := s.controlGeneration
	return ctx, epoch, func() {
		cancel()
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.controlGeneration == epoch {
			s.controlCancel = nil
		}
	}
}

// Shutdown owns the final teardown even if the client which started a
// connection has gone away. A bounded unsuccessful stop keeps its handles
// and the F2 journal for recovery, and returns an error.
func (s *service) shutdown() error {
	s.mu.Lock()
	if !s.closing {
		s.closing = true
		s.controlGeneration++
		if s.controlCancel != nil {
			s.controlCancel()
		}
	}
	s.mu.Unlock()

	_ = s.enterLifecycle(context.Background())
	defer s.leaveLifecycle()
	if s.shutdownComplete {
		return nil
	}
	err := s.stop()
	s.shutdownComplete = err == nil
	return err
}

func (s *service) controlledConnect(ctx context.Context, epoch uint64, req ConnectRequest) error {
	// Validation and DNS are outside the lifecycle queue. A newer command cancels
	// this context and its epoch check prevents late results from starting a core.
	pin, e := s.prepareEndpoint(ctx, req)
	if e == nil {
		if pin != nil {
			req.resolvedServer = pin.IP
		} else {
			var out map[string]any
			out, e = endpointOutbound(req.URI)
			if e == nil {
				host := out["server"].(string)
				req.resolvedServer, e = netip.ParseAddr(host)
				if e != nil {
					queryCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
					var addresses []net.IPAddr
					addresses, e = net.DefaultResolver.LookupIPAddr(queryCtx, host)
					cancel()
					if e == nil && len(addresses) > 0 {
						req.resolvedServer, _ = netip.AddrFromSlice(addresses[0].IP)
						req.resolvedServer = req.resolvedServer.Unmap()
					} else if e == nil {
						e = errors.New("Endpoint DNS returned no IP addresses")
					}
				}
			}
		}
	}
	if e != nil {
		s.mu.Lock()
		if !s.controlCurrentLocked(epoch) || ctx.Err() != nil {
			e = context.Canceled
		} else {
			s.lastError = e.Error()
			s.publishStatusLocked()
		}
		s.mu.Unlock()
		return e
	}
	if pin != nil {
		defer func() {
			s.mu.Lock()
			active := s.endpoint == pin
			s.mu.Unlock()
			if !active {
				pin.cancel()
			}
		}()
	}
	if err := s.enterLifecycle(ctx); err != nil {
		return err
	}
	defer s.leaveLifecycle()
	s.mu.Lock()
	if !s.controlCurrentLocked(epoch) || ctx.Err() != nil {
		s.mu.Unlock()
		return context.Canceled
	}
	previousState, previousCmd := s.state, s.cmd
	s.state = "connecting"
	s.publishStatusLocked()
	s.mu.Unlock()

	req.endpoint = pin
	req.operationContext = ctx
	req.operationEpoch = epoch
	e = s.connectRequest(req)
	if e == nil {
		// connectRequest published the new session under the admission mutex.
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if previousCmd != nil && s.cmd == previousCmd && s.state == "connecting" {
		if failure := s.deadCoreLocked(); failure != "" {
			s.state, s.lastError = "error", failure
		} else {
			s.state = previousState // Failed candidate before teardown.
		}
	} else if s.state != "error" {
		s.state = "disconnected"
	}
	if s.controlCurrentLocked(epoch) && ctx.Err() == nil {
		if s.cmd == nil || s.state != "running" {
			s.state = "error"
		}
		s.lastError = e.Error()
		s.logs.add("error", e.Error())
	}
	s.publishStatusLocked()
	if ctx.Err() != nil || !s.controlCurrentLocked(epoch) {
		return errors.Join(context.Canceled, s.tunCleanupErr)
	}
	return e
}

func (s *service) handleControl(w http.ResponseWriter, r *http.Request) bool {
	if r.Method == "GET" && r.URL.Path == "/v1/status" {
		s.writeStatus(w)
		return true
	}
	if r.Method != "POST" || (r.URL.Path != "/v1/connect" && r.URL.Path != "/v1/reconnect" && r.URL.Path != "/v1/disconnect") {
		return false
	}
	s.ensureStatusCache()
	var req ConnectRequest
	var e error
	if r.URL.Path == "/v1/connect" {
		e = decodeBody(w, r, &req)
		if e == nil {
			e = req.Settings.validate(s.tun)
		}
	}
	if e != nil {
		s.writeControlError(w, e)
		return true
	}
	s.mu.Lock()
	if s.closing || r.Context().Err() != nil {
		s.mu.Unlock()
		s.writeControlError(w, context.Canceled)
		return true
	}
	if r.URL.Path == "/v1/reconnect" {
		if s.desired == nil {
			s.mu.Unlock()
			s.writeControlError(w, errors.New("Нет последнего соединения"))
			return true
		}
		req = *s.desired
	}
	ctx, epoch, finish := s.beginControlLocked(r.Context())
	s.reconnectAt = time.Time{} // Explicit commands supersede a pending retry.
	s.mu.Unlock()
	defer finish()

	if r.URL.Path == "/v1/disconnect" {
		var stopped []byte
		e = s.enterLifecycle(ctx)
		if e == nil {
			s.mu.Lock()
			current := s.controlCurrentLocked(epoch) && ctx.Err() == nil
			s.mu.Unlock()
			if current {
				e = s.stop()
				stopped = s.statusCache.Load().([]byte)
			} else {
				e = context.Canceled
			}
			s.leaveLifecycle()
		}
		if e == nil {
			_, _ = w.Write(stopped)
			return true
		}
	} else {
		e = s.controlledConnect(ctx, epoch, req)
	}
	if e != nil {
		s.writeControlError(w, e)
		return true
	}
	// A replacement committed after this command must not be returned as
	// this command's successful result.
	s.mu.Lock()
	current := s.controlCurrentLocked(epoch) && ctx.Err() == nil
	s.publishStatusLocked()
	snapshot := s.statusCache.Load().([]byte)
	s.mu.Unlock()
	if current {
		_, _ = w.Write(snapshot)
	} else {
		s.writeControlError(w, context.Canceled)
	}
	return true
}
func (s *service) writeControlError(w http.ResponseWriter, e error) {
	s.ensureStatusCache()
	var body map[string]any
	_ = json.Unmarshal(s.statusCache.Load().([]byte), &body)
	body["error"] = e.Error()
	code := http.StatusBadRequest
	if errors.Is(e, context.Canceled) {
		code = http.StatusConflict
	}
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(body)
}
func (s *service) automaticReconnect(ctx context.Context, epoch uint64, req ConnectRequest, attempt int) {
	s.mu.Lock()
	if !s.controlCurrentLocked(epoch) || s.controlCancel != nil || s.reconnectAt.IsZero() {
		s.mu.Unlock()
		return
	}
	autoCtx, autoEpoch, finish := s.beginControlLocked(ctx)
	s.mu.Unlock()
	defer finish()

	e := s.controlledConnect(autoCtx, autoEpoch, req)
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.controlCurrentLocked(autoEpoch) {
		return
	}
	s.reconnectAttempts = attempt
	if e != nil {
		s.lastError = e.Error()
		s.state = "error"
		s.reconnectAt = time.Now().Add(time.Duration(1<<min(attempt, 5)) * time.Second)
	}
	s.publishStatusLocked()
}
