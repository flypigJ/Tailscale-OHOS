package main

import (
	"context"
	"encoding/json"
	"runtime"
	"sync"
	"time"

	"tailscale.com/tailcfg"
	"tailscale.com/util/mesharcdiag"
)

// Supplied by build-go.ps1 from the reviewed source manifest, never a key.
var pathDiagnosticBuild = "working-tree-unrecorded"

var pathProbeGate struct {
	sync.Mutex
	running bool
	last    time.Time
}

type pathDiagnosticCommand struct {
	ProtectionCode int64  `json:"protectionCode"`
	Action         string `json:"action"`
	Seconds        int    `json:"seconds"`
	Stage          int64  `json:"stage"`
	Code           int64  `json:"code"`
	Generation     int64  `json:"generation"`
	Revision       int64  `json:"revision"`
	NetID          int64  `json:"netId"`
	Interface      string `json:"interface"`
	Bearer         int64  `json:"bearer"`
	IPv4Count      int64  `json:"ipv4Count"`
	IPv6Count      int64  `json:"ipv6Count"`
	Protection     int64  `json:"protection"`
}

type pathDiagnosticEnvelope struct {
	Schema      int                  `json:"schema"`
	Result      string               `json:"result"`
	BuildSource string               `json:"buildSource"`
	Core        string               `json:"core"`
	Go          string               `json:"go"`
	ExportedMS  int64                `json:"exportedMs"`
	Trace       mesharcdiag.Snapshot `json:"trace"`
}

func (b *backendController) pathDiagnostic(input string) string {
	result := "ok"
	var cmd pathDiagnosticCommand
	if len(input) > 2048 || json.Unmarshal([]byte(input), &cmd) != nil {
		result = "invalid_command"
	} else {
		switch cmd.Action {
		case "start":
			b.mu.Lock()
			ready := b.server != nil && b.externalTun && !b.starting
			b.mu.Unlock()
			if !ready {
				result = "vpn_unavailable"
			} else if mesharcdiag.Start(cmd.Seconds) != nil {
				result = "random_unavailable"
			} else {
				b.mu.Lock()
				server := b.server
				b.mu.Unlock()
				if server != nil {
					server.PathDiagnosticSnapshot()
				}
			}
		case "stop":
			mesharcdiag.Stop()
		case "clear":
			mesharcdiag.Clear()
		case "snapshot":
			if mesharcdiag.Enabled() {
				b.mu.Lock()
				server := b.server
				b.mu.Unlock()
				if server != nil {
					server.PathDiagnosticSnapshot()
				}
			}
		case "host":
			if mesharcdiag.Enabled() {
				reason := "other"
				if cmd.Bearer == 1 {
					reason = "wifi"
				}
				if cmd.Bearer == 2 {
					reason = "cellular"
				}
				if cmd.Bearer == 3 {
					reason = "offline"
				}
				mesharcdiag.Record("host_network", reason, 0, "", cmd.Interface, nil, nil, cmd.NetID, cmd.Generation, cmd.Revision, cmd.IPv4Count, cmd.IPv6Count, cmd.Stage, cmd.Code)
				protectionReason := "unknown"
				if cmd.Protection == 1 {
					protectionReason = "protected"
				}
				if cmd.Protection == 2 {
					protectionReason = "fallback"
				}
				mesharcdiag.Record("host_protection", protectionReason, 0, "", "", nil, nil, cmd.Protection, cmd.ProtectionCode, 1)
			}
		case "probe":
			result = b.startPathDiagnosticProbe()
		default:
			result = "invalid_command"
		}
	}
	envelope := pathDiagnosticEnvelope{Schema: 1, Result: result, BuildSource: pathDiagnosticBuild, Core: "1.104.5", Go: runtime.Version(), ExportedMS: time.Now().UnixMilli(), Trace: mesharcdiag.Read()}
	encoded, err := json.Marshal(envelope)
	if err != nil {
		return `{"schema":1,"result":"serialization_failed"}`
	}
	return string(encoded)
}

func (b *backendController) startPathDiagnosticProbe() string {
	if !mesharcdiag.Enabled() {
		return "capture_disabled"
	}
	pathProbeGate.Lock()
	if pathProbeGate.running {
		pathProbeGate.Unlock()
		return "probe_busy"
	}
	if time.Since(pathProbeGate.last) < 30*time.Second {
		pathProbeGate.Unlock()
		return "probe_rate_limited"
	}
	pathProbeGate.running = true
	pathProbeGate.last = time.Now()
	pathProbeGate.Unlock()
	// Bind cancellation to this capture before launching; a new capture cannot
	// inherit an old probe's authority or results.
	sessionContext := mesharcdiag.Context()
	ctx, cancel := context.WithTimeout(sessionContext, 12*time.Second)
	go func() {
		defer cancel()
		defer func() { pathProbeGate.Lock(); pathProbeGate.running = false; pathProbeGate.Unlock() }()
		guardGoroutine("pathDiagnostics.activeProbe", nil, func() {
			if ctx.Err() != nil {
				return
			}
			b.mu.Lock()
			client, server := b.client, b.server
			b.mu.Unlock()
			if client == nil || server == nil {
				return
			}
			mesharcdiag.RecordIn(sessionContext, "active_probe", "start", 0, "", "", nil, nil)
			err := server.RequestPathDiagnosticSTUN()
			mesharcdiag.RecordIn(sessionContext, "restun", mesharcdiag.Result(err), 0, "", "", nil, err)
			status, err := client.Status(ctx)
			if err != nil {
				mesharcdiag.RecordIn(sessionContext, "active_probe", "error", 0, "", "", nil, err)
				return
			}
			count := 0
			for _, peer := range status.Peer {
				if count >= 3 || ctx.Err() != nil {
					break
				}
				if !peer.Online || len(peer.TailscaleIPs) == 0 {
					continue
				}
				count++
				for attempt := 0; attempt < 3 && ctx.Err() == nil; attempt++ {
					pingCtx, pingCancel := context.WithTimeout(ctx, 1200*time.Millisecond)
					r, e := client.Ping(pingCtx, peer.TailscaleIPs[0], tailcfg.PingDisco)
					pingCancel()
					if ctx.Err() != nil {
						break
					}
					reason := "error"
					endpoint := ""
					var latency int64
					if e == nil && r != nil && r.Err == "" {
						reason = "derp"
						endpoint = r.Endpoint
						latency = int64(r.LatencySeconds * 1000)
						if endpoint != "" {
							reason = "direct"
						} else if r.PeerRelay != "" {
							reason = "peer_relay"
						}
					}
					mesharcdiag.RecordIn(sessionContext, "active_probe", reason, 0, string(peer.ID), endpoint, nil, e, int64(attempt+1), latency)
					if reason == "direct" {
						break
					}
				}
			}
			if ctx.Err() == nil {
				mesharcdiag.RecordIn(sessionContext, "active_probe", "complete", 0, "", "", nil, nil, int64(count))
			}
		})
	}()
	return "probe_started"
}
