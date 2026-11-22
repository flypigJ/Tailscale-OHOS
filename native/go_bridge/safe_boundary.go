package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"

	"tailscale.com/util/mesharcdiag"
)

const (
	bridgePanicRingCapacity = 16
	maxDiagnosticTokenBytes = 64

	fallbackHello                   = "FAILED | Go bridge | internal panic"
	fallbackProbeEngineEntry        = "FAILED | stage=entry | Tailscale engine panic"
	fallbackBackendStart            = "FAILED | backend start | internal panic"
	fallbackBackendStop             = "FAILED | backend stop | internal panic"
	fallbackBackendLogout           = "FAILED | backend logout | internal panic"
	fallbackBackendStatus           = "FAILED | backend status | internal panic"
	fallbackLocalSendRefresh        = "FAILED | LocalSend refresh | internal panic"
	fallbackBackendAuthURL          = "FAILED | auth URL | internal panic"
	fallbackBackendLoginWithAuthKey = "FAILED | auth key | internal panic"
	fallbackBackendVPNConfig        = "FAILED | VPN config | internal panic"
	fallbackBackendDNSRuntime       = "FAILED | DNS runtime | internal panic"
	fallbackTailscaleVersion        = "1.104.5"
	fallbackSetNetworkSetting       = "FAILED | network setting | internal panic"
	fallbackSetExitNode             = "FAILED | exit node | internal panic"
	fallbackPeerProbe               = "FAILED | peer probe | internal panic"
	fallbackRestartWithTun          = "FAILED | VPN backend | internal panic"
	fallbackControlProbe            = "FAILED | stage=panic | category=internal"
	fallbackTunFDProbe              = "FAILED | TUN fd probe | panic"
	fallbackNetworkChanged          = "FAILED | network change | internal panic"

	fallbackJSONArray              = "[]"
	fallbackJSONObject             = "{}"
	fallbackMediaProbeSelfTestJSON = `{"state":"failed","cases":0,"errorMessage":"internal_panic"}`
	fallbackPathDiagnosticJSON     = `{"schema":1,"result":"internal_panic"}`
)

var (
	bridgeRecoveredPanicCount atomic.Uint64

	bridgePanicDiagMu    sync.Mutex
	bridgeLastPanicStage string
	bridgePanicStageRing [bridgePanicRingCapacity]string
	bridgePanicRingIndex int
	bridgePanicRingCount int

	fallbackDisplaySnapshotJSON         = marshalDisplaySnapshotFallback()
	fallbackDNSConfigJSON               = marshalDNSSnapshot(dnsConfigSnapshot{SchemaVersion: 1, State: "unavailable"})
	fallbackNetworkSettingsJSON         = marshalNetworkPreferencesFallback()
	fallbackPeerConnectivityJSON        = marshalPeerConnectivity(peerConnectivityResult{State: "failed", Reason: "internal_panic"})
	fallbackSunshineProbeJSON           = marshalSunshineProbe(sunshineProbeResult{State: "error", CheckedAt: 0, ErrorMessage: "internal_panic"})
	fallbackMediaServiceProbeJSON       = marshalMediaProbe(mediaProbeResult{State: "error", CheckedAt: 0, Services: []mediaServiceResult{}, ErrorMessage: "internal_panic"})
	fallbackTaildropSendJSON            = marshalTaildropTransfer(taildropTransferSnapshot{State: "failed", Reason: "internal_panic"})
	fallbackTaildropCancelJSON          = marshalTaildropTransfer(taildropTransferSnapshot{State: "idle"})
	fallbackTaildropReceiveJSON         = marshalTaildropReceive(taildropReceiveResult{State: "failed", Reason: "internal_panic"})
	fallbackTaildriveListJSON           = marshalTaildriveList(taildriveListResult{State: "failed", Path: "/", Entries: []taildriveEntry{}, Reason: "internal_panic"})
	fallbackTaildriveStatJSON           = marshalTaildriveStat(taildriveStatResult{State: "failed", Reason: "internal_panic"})
	fallbackTaildriveMutateJSON         = marshalTaildriveMutation(taildriveMutationResult{State: "failed", Reason: "internal_panic"})
	fallbackTaildriveTransferFailedJSON = marshalTaildriveTransfer(taildriveTransferSnapshot{State: "failed", Reason: "internal_panic"})
	fallbackTaildriveTransferIdleJSON   = marshalTaildriveTransfer(taildriveTransferSnapshot{State: "idle"})
	fallbackTaildriveCancelJSON         = marshalTaildriveTransfer(taildriveTransferSnapshot{State: "cancelled", Reason: "cancelled"})
)

// guardExportString runs a Cgo string export body behind a panic recovery boundary.
// It never inspects, formats, or logs the recovered panic payload or stack trace.
func guardExportString(stage string, fallback string, fn func() string) (result string) {
	result = fallback
	defer func() {
		if recover() != nil {
			total := bridgeRecoveredPanicCount.Add(1)
			recordBridgePanicDiagnosticWithCount(stage, total)
			result = fallback
		}
	}()
	if fn == nil {
		return fallback
	}
	return fn()
}

// guardExportVoid runs a void Cgo export or panic-cleanup callback behind a
// panic recovery boundary without retaining panic payloads or stack traces.
func guardExportVoid(stage string, fn func()) {
	defer func() {
		if recover() != nil {
			total := bridgeRecoveredPanicCount.Add(1)
			recordBridgePanicDiagnosticWithCount(stage, total)
		}
	}()
	if fn == nil {
		return
	}
	fn()
}

// guardGoroutine runs a managed background goroutine behind a panic recovery
// boundary. If onPanic is supplied, it runs under its own guardExportVoid
// boundary so a secondary panic in cleanup cannot crash the process.
func guardGoroutine(stage string, onPanic func(), fn func()) {
	defer func() {
		if recover() != nil {
			total := bridgeRecoveredPanicCount.Add(1)
			recordBridgePanicDiagnosticWithCount(stage, total)
			if onPanic != nil {
				guardExportVoid(stage+".onPanic", onPanic)
			}
		}
	}()
	if fn == nil {
		return
	}
	fn()
}

func recordBridgePanicDiagnostic(stage string) {
	recordBridgePanicDiagnosticWithCount(stage, bridgeRecoveredPanicCount.Load())
}

func recordBridgePanicDiagnosticWithCount(stage string, total uint64) {
	defer func() {
		_ = recover()
	}()
	safeStage := sanitizeDiagnosticToken(stage)
	bridgePanicDiagMu.Lock()
	bridgeLastPanicStage = safeStage
	bridgePanicStageRing[bridgePanicRingIndex] = safeStage
	bridgePanicRingIndex = (bridgePanicRingIndex + 1) % bridgePanicRingCapacity
	if bridgePanicRingCount < bridgePanicRingCapacity {
		bridgePanicRingCount++
	}
	bridgePanicDiagMu.Unlock()

	if !mesharcdiag.Enabled() {
		return
	}
	// PathDiagnosticService and mesharcdiag enforce a strict kind/result allowlist.
	// Use allowlisted categories so active path traces remain valid and sanitizable.
	kind := "host_monitor"
	if safeStage == "pathDiagnostics.activeProbe" {
		kind = "active_probe"
	}
	mesharcdiag.Record(kind, "error", 0, "", "", nil, nil, int64(total))
}

func sanitizeDiagnosticToken(raw string) string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return "unknown"
	}
	if len(trimmed) > maxDiagnosticTokenBytes {
		trimmed = trimmed[:maxDiagnosticTokenBytes]
	}
	clean := true
	for i := 0; i < len(trimmed); i++ {
		if !isAllowedDiagnosticByte(trimmed[i]) {
			clean = false
			break
		}
	}
	if clean {
		return trimmed
	}
	buf := make([]byte, len(trimmed))
	for i := 0; i < len(trimmed); i++ {
		ch := trimmed[i]
		if isAllowedDiagnosticByte(ch) {
			buf[i] = ch
		} else {
			buf[i] = '_'
		}
	}
	return string(buf)
}

func isAllowedDiagnosticByte(ch byte) bool {
	return (ch >= 'a' && ch <= 'z') ||
		(ch >= 'A' && ch <= 'Z') ||
		(ch >= '0' && ch <= '9') ||
		ch == '_' || ch == '-' || ch == '.'
}

func bridgePanicDiagnosticSnapshot() (count uint64, lastStage string, recentStages []string) {
	count = bridgeRecoveredPanicCount.Load()
	bridgePanicDiagMu.Lock()
	defer bridgePanicDiagMu.Unlock()
	lastStage = bridgeLastPanicStage
	recentStages = make([]string, 0, bridgePanicRingCount)
	start := 0
	if bridgePanicRingCount == bridgePanicRingCapacity {
		start = bridgePanicRingIndex
	}
	for i := 0; i < bridgePanicRingCount; i++ {
		idx := (start + i) % bridgePanicRingCapacity
		recentStages = append(recentStages, bridgePanicStageRing[idx])
	}
	return count, lastStage, recentStages
}

func formatProbeEnginePanicFallback(stage string) string {
	return fmt.Sprintf("FAILED | stage=%s | Tailscale engine panic", sanitizeDiagnosticToken(stage))
}

func marshalDisplaySnapshotFallback() string {
	return marshalBackendSnapshot(backendSnapshot{
		Status:          "FAILED | backend snapshot | internal panic",
		ExitNodes:       []exitNodeChoice{},
		Peers:           []peerSummary{},
		NetworkSettings: defaultNetworkPreferences(),
		Account:         accountSummary{Addresses: []string{}},
		Taildrop: taildropSnapshot{
			State:         "unavailable",
			Reason:        "internal_panic",
			Targets:       []taildropTargetSummary{},
			IncomingFiles: []taildropIncomingFile{},
			WaitingFiles:  []taildropWaitingFileSummary{},
			Transfer:      taildropTransferSnapshot{State: "idle"},
		},
		Taildrive:       taildriveSnapshot{State: "unavailable", Reason: "internal_panic", Transfer: taildriveTransferSnapshot{State: "idle"}},
		MeshArcReceiver: meshArcReceiverStatus{State: "idle"},
	})
}

func marshalNetworkPreferencesFallback() string {
	encoded, err := json.Marshal(defaultNetworkPreferences())
	if err != nil {
		return `{"routeAll":true,"exitNodeAllowLANAccess":false}`
	}
	return string(encoded)
}

func exportJSONFallbacks() map[string]string {
	return map[string]string{
		"TSBackendSnapshot":                  fallbackDisplaySnapshotJSON,
		"TSBackendPeerSnapshot":              fallbackDisplaySnapshotJSON,
		"TSBackendTaildropIncomingSnapshot":  fallbackJSONArray,
		"TSBackendDNSConfig":                 fallbackDNSConfigJSON,
		"TSBackendExitNodes":                 fallbackJSONArray,
		"TSBackendPeers":                     fallbackJSONArray,
		"TSBackendAccount":                   fallbackJSONObject,
		"TSBackendNetworkSettings":           fallbackNetworkSettingsJSON,
		"TSBackendPeerConnectivity":          fallbackPeerConnectivityJSON,
		"TSBackendSunshineProbe":             fallbackSunshineProbeJSON,
		"TSBackendMediaServiceProbe":         fallbackMediaServiceProbeJSON,
		"TSMediaProbeSelfTest":               fallbackMediaProbeSelfTestJSON,
		"TSBackendTaildropSend":              fallbackTaildropSendJSON,
		"TSBackendTaildropCancel":            fallbackTaildropCancelJSON,
		"TSBackendTaildropReceive":           fallbackTaildropReceiveJSON,
		"TSBackendTaildriveList":             fallbackTaildriveListJSON,
		"TSBackendTaildriveStat":             fallbackTaildriveStatJSON,
		"TSBackendTaildriveMutate":           fallbackTaildriveMutateJSON,
		"TSBackendTaildriveDownload":         fallbackTaildriveTransferFailedJSON,
		"TSBackendTaildriveManualDownload":   fallbackTaildriveTransferFailedJSON,
		"TSBackendTaildriveUpload":           fallbackTaildriveTransferFailedJSON,
		"TSBackendTaildriveTransferSnapshot": fallbackTaildriveTransferIdleJSON,
		"TSBackendTaildriveCancel":           fallbackTaildriveCancelJSON,
		"TSBackendPathDiagnostic":            fallbackPathDiagnosticJSON,
	}
}
