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

// mu serializes lifecycle mutations, not status reads. JSON snapshots never
// alias mutable maps/pointers and remain readable during DNS/core startup.
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
func (s *service) controlCurrent(epoch uint64) bool {
	s.controlMu.Lock()
	defer s.controlMu.Unlock()
	return !s.closing && s.controlGeneration == epoch
}
func (s *service) beginControl(parent context.Context) (context.Context, uint64, context.CancelFunc) {
	s.controlMu.Lock()
	defer s.controlMu.Unlock()
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
	return ctx, epoch, func() { s.finishControl(epoch, cancel) }
}
func (s *service) finishControl(epoch uint64, cancel context.CancelFunc) {
	cancel()
	s.controlMu.Lock()
	defer s.controlMu.Unlock()
	if s.controlGeneration == epoch {
		s.controlCancel = nil
	}
}
func (s *service) cancelControls() {
	s.controlMu.Lock()
	defer s.controlMu.Unlock()
	s.closing = true
	s.controlGeneration++
	if s.controlCancel != nil {
		s.controlCancel()
	}
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
		if !s.controlCurrent(epoch) || ctx.Err() != nil {
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
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.controlCurrent(epoch) || ctx.Err() != nil {
		return context.Canceled
	}
	previousState, previousCmd, previousRequest := s.state, s.cmd, s.desired
	s.state = "connecting"
	s.publishStatusLocked()
	req.endpoint = pin
	req.operationContext = ctx
	e = s.connectRequest(req)
	if !s.controlCurrent(epoch) || ctx.Err() != nil {
		// Candidate validation can be cancelled before it touches the live core.
		if s.cmd == previousCmd && s.tunCleanupErr == nil {
			s.state = previousState
		} else if s.cmd != nil && s.cmd != previousCmd {
			s.stopCore()
		}
		s.desired = previousRequest
		s.publishStatusLocked()
		return errors.Join(context.Canceled, s.tunCleanupErr)
	}
	if e != nil {
		if previousCmd != nil && s.cmd == previousCmd {
			s.state = previousState
		} else if s.cmd == nil {
			s.state = "error"
		}
		s.lastError = e.Error()
		s.logs.add("error", e.Error())
	}
	s.publishStatusLocked()
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
	ctx, epoch, cancel := s.beginControl(r.Context())
	defer cancel()
	if r.URL.Path == "/v1/disconnect" {
		s.mu.Lock()
		if !s.controlCurrent(epoch) || ctx.Err() != nil {
			e = context.Canceled
		} else {
			s.state = "disconnecting"
			s.publishStatusLocked()
			e = s.stop()
		}
		s.publishStatusLocked()
		s.mu.Unlock()
	} else {
		s.mu.Lock()
		if !s.controlCurrent(epoch) || ctx.Err() != nil {
			e = context.Canceled
		} else {
			// An explicit new connection supersedes any pending crash retry.
			s.reconnectAt = time.Time{}
		}
		if e == nil && r.URL.Path == "/v1/reconnect" {
			if s.desired == nil {
				e = errors.New("Нет последнего соединения")
			} else {
				req = *s.desired
			}
		}
		s.mu.Unlock()
		if e == nil {
			e = s.controlledConnect(ctx, epoch, req)
		}
	}
	if e != nil {
		s.writeControlError(w, e)
	} else {
		s.writeStatus(w)
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
	s.controlMu.Lock()
	if s.closing || s.controlGeneration != epoch || s.controlCancel != nil {
		s.controlMu.Unlock()
		return
	}
	s.controlGeneration++
	epoch = s.controlGeneration
	autoCtx, cancel := context.WithCancel(ctx)
	s.controlCancel = cancel
	s.controlMu.Unlock()
	defer s.finishControl(epoch, cancel)
	e := s.controlledConnect(autoCtx, epoch, req)
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.controlCurrent(epoch) {
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
