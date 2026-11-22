package main

import (
	"context"
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"tailscale.com/util/mesharcdiag"
)

func TestGuardExportStringRecoversAndRedactsSecrets(t *testing.T) {
	if err := mesharcdiag.Start(30); err != nil {
		t.Fatalf("mesharcdiag.Start failed: %v", err)
	}
	defer func() {
		mesharcdiag.Stop()
		mesharcdiag.Clear()
	}()

	before := bridgeRecoveredPanicCount.Load()
	const fallback = `{"state":"failed","reason":"internal_panic"}`
	const secret = "secret-key-tskey-123"

	got := guardExportString("TSBackendTaildropSend", fallback, func() string {
		panic(secret)
	})
	after, lastStage, recentStages := bridgePanicDiagnosticSnapshot()

	if got != fallback {
		t.Fatalf("guardExportString() = %q, want %q", got, fallback)
	}
	if after != before+1 {
		t.Fatalf("bridgeRecoveredPanicCount = %d, want %d", after, before+1)
	}
	if lastStage != "TSBackendTaildropSend" {
		t.Fatalf("lastStage = %q, want TSBackendTaildropSend", lastStage)
	}
	if len(recentStages) == 0 || recentStages[len(recentStages)-1] != "TSBackendTaildropSend" {
		t.Fatalf("recentStages = %v, missing TSBackendTaildropSend", recentStages)
	}
	if strings.Contains(got, "secret-key") || strings.Contains(got, "goroutine") || strings.Contains(got, ".go:") {
		t.Fatalf("fallback leaked panic or stack details: %q", got)
	}

	trace := mesharcdiag.Read()
	if trace.InvalidDropped != 0 {
		t.Fatalf("mesharcdiag rejected panic diagnostic event: invalidDropped=%d", trace.InvalidDropped)
	}
	traceJSON, err := json.Marshal(trace)
	if err != nil {
		t.Fatalf("marshal trace: %v", err)
	}
	if strings.Contains(string(traceJSON), "secret-key") || strings.Contains(string(traceJSON), "tskey-") {
		t.Fatalf("mesharcdiag trace leaked panic payload: %s", traceJSON)
	}

	normal := guardExportString("TSHello", fallbackHello, func() string {
		return "OK · healthy"
	})
	if normal != "OK · healthy" {
		t.Fatalf("normal guardExportString() = %q, want OK · healthy", normal)
	}

	probeFallback := formatProbeEnginePanicFallback("new-userspace-engine\nsecret-key")
	if probeFallback != "FAILED | stage=new-userspace-engine_secret-key | Tailscale engine panic" {
		t.Fatalf("unexpected sanitized probe fallback: %q", probeFallback)
	}
}

func TestGuardExportVoidRecoversCleanly(t *testing.T) {
	before := bridgeRecoveredPanicCount.Load()
	guardExportVoid("TSFreeString", func() {
		panic("void-export-secret-tskey-456")
	})
	after := bridgeRecoveredPanicCount.Load()
	if after != before+1 {
		t.Fatalf("bridgeRecoveredPanicCount = %d, want %d", after, before+1)
	}
}

func TestGuardGoroutineRecoversOnPanicAndWaitGroup(t *testing.T) {
	before := bridgeRecoveredPanicCount.Load()
	var onPanicCalled atomic.Bool
	var wg sync.WaitGroup

	wg.Add(2)
	go func() {
		defer wg.Done()
		guardGoroutine("test.workerOne", func() {
			onPanicCalled.Store(true)
			panic("secondary-cleanup-panic-secret")
		}, func() {
			panic("primary-worker-panic-secret")
		})
	}()
	go func() {
		defer wg.Done()
		guardGoroutine("test.workerTwo", nil, func() {})
	}()

	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("WaitGroup deadlocked after goroutine panic")
	}

	if !onPanicCalled.Load() {
		t.Fatal("onPanic callback did not execute")
	}
	// Primary panic + secondary panic inside onPanic must both be caught and counted.
	if got := bridgeRecoveredPanicCount.Load(); got < before+2 {
		t.Fatalf("bridgeRecoveredPanicCount = %d, want at least %d", got, before+2)
	}
}

func TestManagedControllersRecoverAndResetRunningGates(t *testing.T) {
	// 1. controlProbeController resets running=false and stores redacted panic status.
	probe := controlProbeController{
		probeFn: func() string {
			panic("control-probe-secret-tskey-789")
		},
	}
	if status := probe.startOrStatus(); status != "OK | control probe starting" {
		t.Fatalf("initial startOrStatus() = %q", status)
	}
	deadline := time.Now().Add(3 * time.Second)
	var finalProbeResult string
	for time.Now().Before(deadline) {
		got := probe.startOrStatus()
		if got != "OK | control probe running" {
			finalProbeResult = got
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if finalProbeResult != fallbackControlProbe {
		t.Fatalf("controlProbe panic result = %q, want %q", finalProbeResult, fallbackControlProbe)
	}
	probe.mu.Lock()
	stillRunning := probe.running
	probe.mu.Unlock()
	if stillRunning {
		t.Fatal("controlProbeController remained stuck in running=true after panic")
	}

	// 2. pathProbeGate resets running=false when active probe goroutine panics.
	if err := mesharcdiag.Start(30); err != nil {
		t.Fatalf("mesharcdiag.Start failed: %v", err)
	}
	defer func() {
		mesharcdiag.Stop()
		mesharcdiag.Clear()
	}()
	pathProbeGate.Lock()
	savedLast := pathProbeGate.last
	pathProbeGate.running = false
	pathProbeGate.last = time.Time{}
	pathProbeGate.Unlock()
	defer func() {
		pathProbeGate.Lock()
		pathProbeGate.running = false
		pathProbeGate.last = savedLast
		pathProbeGate.Unlock()
	}()

	var nilBackend *backendController
	if got := nilBackend.startPathDiagnosticProbe(); got != "probe_started" {
		t.Fatalf("startPathDiagnosticProbe() = %q, want probe_started", got)
	}
	gateCleared := false
	for time.Now().Before(time.Now().Add(3 * time.Second)) {
		pathProbeGate.Lock()
		running := pathProbeGate.running
		pathProbeGate.Unlock()
		if !running {
			gateCleared = true
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !gateCleared {
		t.Fatal("pathProbeGate.running remained true after active probe panic")
	}

	// 3. backendController.startAsync sets redacted error with zero stack trace on panic.
	controller := &backendController{
		starting:   true,
		generation: 1,
	}
	controller.startAsync(nil, t.TempDir(), 1, context.Background())
	status := controller.status()
	if status != "FAILED | backend start | backend startup internal panic" {
		t.Fatalf("startAsync panic status = %q", status)
	}
	if strings.Contains(status, "goroutine") || strings.Contains(status, ".go:") {
		t.Fatalf("startAsync status leaked stack trace: %q", status)
	}
}

func TestAllExportJSONFallbacksMatchSchemas(t *testing.T) {
	fallbacks := exportJSONFallbacks()
	if len(fallbacks) != 24 {
		t.Fatalf("exportJSONFallbacks() count = %d, want 24 JSON exports", len(fallbacks))
	}
	for name, payload := range fallbacks {
		if !json.Valid([]byte(payload)) {
			t.Fatalf("%s fallback is not valid JSON: %q", name, payload)
		}
		if strings.Contains(payload, "goroutine") || strings.Contains(payload, ".go:") || strings.Contains(payload, "debug.Stack") {
			t.Fatalf("%s fallback contains stack trace text: %q", name, payload)
		}
	}

	var snapshot backendSnapshot
	if err := json.Unmarshal([]byte(fallbackDisplaySnapshotJSON), &snapshot); err != nil {
		t.Fatalf("unmarshal fallbackDisplaySnapshotJSON: %v", err)
	}
	if !strings.HasPrefix(snapshot.Status, "FAILED |") || snapshot.Peers == nil || snapshot.ExitNodes == nil || snapshot.Taildrop.Targets == nil {
		t.Fatalf("fallbackDisplaySnapshotJSON missing required non-nil slices: %#v", snapshot)
	}

	var dnsSnap dnsConfigSnapshot
	if err := json.Unmarshal([]byte(fallbackDNSConfigJSON), &dnsSnap); err != nil || dnsSnap.SchemaVersion != 1 || dnsSnap.State != "unavailable" {
		t.Fatalf("unexpected fallbackDNSConfigJSON: %#v, err=%v", dnsSnap, err)
	}

	var netSettings networkPreferences
	if err := json.Unmarshal([]byte(fallbackNetworkSettingsJSON), &netSettings); err != nil || !netSettings.RouteAll || netSettings.ExitNodeAllowLANAccess {
		t.Fatalf("unexpected fallbackNetworkSettingsJSON: %#v, err=%v", netSettings, err)
	}

	var tdTransfer taildriveTransferSnapshot
	if err := json.Unmarshal([]byte(fallbackTaildriveTransferFailedJSON), &tdTransfer); err != nil || tdTransfer.State != "failed" || tdTransfer.Reason != "internal_panic" {
		t.Fatalf("unexpected fallbackTaildriveTransferFailedJSON: %#v, err=%v", tdTransfer, err)
	}

	var diagEnvelope pathDiagnosticEnvelope
	if err := json.Unmarshal([]byte(fallbackPathDiagnosticJSON), &diagEnvelope); err != nil || diagEnvelope.Schema != 1 || diagEnvelope.Result != "internal_panic" {
		t.Fatalf("unexpected fallbackPathDiagnosticJSON: %#v, err=%v", diagEnvelope, err)
	}
}

func TestASTAll44ExportsGuardedAndZeroRuntimeDebugImports(t *testing.T) {
	fset := token.NewFileSet()
	mainFile, err := parser.ParseFile(fset, "main.go", nil, parser.ParseComments)
	if err != nil {
		t.Fatalf("parse main.go: %v", err)
	}

	exportedFuncs := make(map[string]*ast.FuncDecl)
	for _, decl := range mainFile.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Doc == nil {
			continue
		}
		for _, comment := range fn.Doc.List {
			text := strings.TrimSpace(comment.Text)
			if strings.HasPrefix(text, "//export ") {
				exportName := strings.TrimSpace(strings.TrimPrefix(text, "//export "))
				if exportName != fn.Name.Name {
					t.Fatalf("//export %s does not match function name %s", exportName, fn.Name.Name)
				}
				exportedFuncs[exportName] = fn
			}
		}
	}

	if len(exportedFuncs) != 44 {
		t.Fatalf("found %d //export functions in main.go, want 44", len(exportedFuncs))
	}

	for name, fn := range exportedFuncs {
		wantGuard := "guardExportString"
		if name == "TSFreeString" {
			wantGuard = "guardExportVoid"
		}
		foundGuard := false
		ast.Inspect(fn.Body, func(node ast.Node) bool {
			call, ok := node.(*ast.CallExpr)
			if !ok {
				return true
			}
			if ident, ok := call.Fun.(*ast.Ident); ok {
				if ident.Name == wantGuard {
					foundGuard = true
				}
				if ident.Name == "recover" {
					t.Errorf("export %s calls raw recover() directly instead of %s", name, wantGuard)
				}
			}
			return true
		})
		if !foundGuard {
			t.Errorf("export %s does not invoke %s", name, wantGuard)
		}
	}

	for _, dir := range []string{".", "vpnroute"} {
		entries, err := os.ReadDir(dir)
		if err != nil {
			t.Fatalf("read dir %s: %v", dir, err)
		}
		for _, entry := range entries {
			if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".go") || strings.HasSuffix(entry.Name(), "_test.go") {
				continue
			}
			path := filepath.Join(dir, entry.Name())
			rawBytes, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read %s: %v", path, err)
			}
			parsed, err := parser.ParseFile(fset, path, rawBytes, 0)
			if err != nil {
				t.Fatalf("parse %s: %v", path, err)
			}
			for _, imp := range parsed.Imports {
				if strings.Trim(imp.Path.Value, `"`) == "runtime/debug" {
					t.Errorf("%s imports forbidden package runtime/debug", path)
				}
			}
			if strings.Contains(string(rawBytes), "debug.Stack(") {
				t.Errorf("%s calls forbidden debug.Stack()", path)
			}
		}
	}
}
