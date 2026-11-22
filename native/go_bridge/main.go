package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"fmt"
	"runtime"
	"unsafe"

	"tailscale.com/net/netns"
	"tailscale.com/net/tsdial"
	"tailscale.com/tsd"
	"tailscale.com/version"
	"tailscale.com/wgengine"
)

//export TSHello
func TSHello() *C.char {
	return C.CString(guardExportString("TSHello", fallbackHello, func() string {
		platform := runtime.GOOS
		if runtime.IsOpenharmony {
			platform = "openharmony"
		}
		return fmt.Sprintf("OK · Go %s · %s/%s", runtime.Version(), platform, runtime.GOARCH)
	}))
}

//export TSProbeEngine
func TSProbeEngine() (result *C.char) {
	stage := "entry"
	out := guardExportString("TSProbeEngine", fallbackProbeEngineEntry, func() string {
		stage = "disable-netns"
		netns.SetEnabled(false)
		logf := func(string, ...any) {}
		stage = "new-system"
		sys := tsd.NewSystem()
		dialer := &tsdial.Dialer{Logf: logf}
		stage = "new-userspace-engine"
		engine, err := wgengine.NewUserspaceEngine(logf, wgengine.Config{
			EventBus:      sys.Bus.Get(),
			Dialer:        dialer,
			SetSubsystem:  sys.Set,
			ControlKnobs:  sys.ControlKnobs(),
			HealthTracker: sys.HealthTracker.Get(),
			Metrics:       sys.UserMetricsRegistry(),
		})
		if err != nil {
			return fmt.Sprintf("FAILED | Tailscale %s | %v", version.Short(), err)
		}
		stage = "close-userspace-engine"
		defer engine.Close()
		stage = "set-engine-subsystem"
		sys.Set(engine)
		stage = "complete"
		return fmt.Sprintf("OK | Tailscale %s | userspace engine initialized", version.Short())
	})
	if out == fallbackProbeEngineEntry && stage != "entry" {
		out = formatProbeEnginePanicFallback(stage)
	}
	return C.CString(out)
}

//export TSBackendStart
func TSBackendStart(stateDir *C.char, deviceModel *C.char, osVersion *C.char, controlURL *C.char) *C.char {
	return C.CString(guardExportString("TSBackendStart", fallbackBackendStart, func() string {
		if stateDir == nil || deviceModel == nil || osVersion == nil || controlURL == nil {
			return "FAILED | backend start | missing startup metadata"
		}
		return harmonyBackend.start(
			C.GoString(stateDir), C.GoString(deviceModel), C.GoString(osVersion), C.GoString(controlURL))
	}))
}

//export TSBackendStop
func TSBackendStop() *C.char {
	return C.CString(guardExportString("TSBackendStop", fallbackBackendStop, func() string {
		return harmonyBackend.stop()
	}))
}

//export TSBackendLogout
func TSBackendLogout() *C.char {
	return C.CString(guardExportString("TSBackendLogout", fallbackBackendLogout, func() string {
		return harmonyBackend.logout()
	}))
}

//export TSBackendStatus
func TSBackendStatus() *C.char {
	return C.CString(guardExportString("TSBackendStatus", fallbackBackendStatus, func() string {
		return harmonyBackend.status()
	}))
}

//export TSBackendSnapshot
func TSBackendSnapshot() *C.char {
	return C.CString(guardExportString("TSBackendSnapshot", fallbackDisplaySnapshotJSON, func() string {
		return harmonyBackend.snapshot()
	}))
}

//export TSBackendPeerSnapshot
func TSBackendPeerSnapshot() *C.char {
	return C.CString(guardExportString("TSBackendPeerSnapshot", fallbackDisplaySnapshotJSON, func() string {
		return harmonyBackend.peerSnapshot()
	}))
}

//export TSBackendLocalSendRefresh
func TSBackendLocalSendRefresh() *C.char {
	return C.CString(guardExportString("TSBackendLocalSendRefresh", fallbackLocalSendRefresh, func() string {
		return harmonyBackend.refreshMeshArcDevices()
	}))
}

//export TSBackendTaildropIncomingSnapshot
func TSBackendTaildropIncomingSnapshot() *C.char {
	return C.CString(guardExportString("TSBackendTaildropIncomingSnapshot", fallbackJSONArray, func() string {
		return harmonyBackend.taildropIncomingSnapshotJSON()
	}))
}

//export TSBackendAuthURL
func TSBackendAuthURL() *C.char {
	return C.CString(guardExportString("TSBackendAuthURL", fallbackBackendAuthURL, func() string {
		return harmonyBackend.authURL()
	}))
}

//export TSBackendLoginWithAuthKey
func TSBackendLoginWithAuthKey(authKey *C.char) *C.char {
	return C.CString(guardExportString("TSBackendLoginWithAuthKey", fallbackBackendLoginWithAuthKey, func() string {
		if authKey == nil {
			return "FAILED | auth key | empty"
		}
		return harmonyBackend.loginWithAuthKey(C.GoString(authKey))
	}))
}

//export TSBackendVPNConfig
func TSBackendVPNConfig() *C.char {
	return C.CString(guardExportString("TSBackendVPNConfig", fallbackBackendVPNConfig, func() string {
		return harmonyBackend.vpnConfig()
	}))
}

//export TSBackendDNSConfig
func TSBackendDNSConfig() *C.char {
	return C.CString(guardExportString("TSBackendDNSConfig", fallbackDNSConfigJSON, func() string {
		return harmonyBackend.dnsConfig()
	}))
}

//export TSBackendDNSRuntime
func TSBackendDNSRuntime(command *C.char) *C.char {
	return C.CString(guardExportString("TSBackendDNSRuntime", fallbackBackendDNSRuntime, func() string {
		if command == nil {
			return "FAILED | DNS runtime | empty input"
		}
		return harmonyBackend.dnsRuntimeCommand(C.GoString(command))
	}))
}

//export TSBackendExitNodes
func TSBackendExitNodes() *C.char {
	return C.CString(guardExportString("TSBackendExitNodes", fallbackJSONArray, func() string {
		return harmonyBackend.exitNodes()
	}))
}

//export TSBackendPeers
func TSBackendPeers() *C.char {
	return C.CString(guardExportString("TSBackendPeers", fallbackJSONArray, func() string {
		return harmonyBackend.peers()
	}))
}

//export TSBackendAccount
func TSBackendAccount() *C.char {
	return C.CString(guardExportString("TSBackendAccount", fallbackJSONObject, func() string {
		return harmonyBackend.account()
	}))
}

//export TSTailscaleVersion
func TSTailscaleVersion() *C.char {
	return C.CString(guardExportString("TSTailscaleVersion", fallbackTailscaleVersion, func() string {
		return version.Short()
	}))
}

//export TSBackendNetworkSettings
func TSBackendNetworkSettings() *C.char {
	return C.CString(guardExportString("TSBackendNetworkSettings", fallbackNetworkSettingsJSON, func() string {
		return harmonyBackend.networkSettings()
	}))
}

//export TSBackendSetNetworkSetting
func TSBackendSetNetworkSetting(key *C.char, enabled C.int) *C.char {
	return C.CString(guardExportString("TSBackendSetNetworkSetting", fallbackSetNetworkSetting, func() string {
		if key == nil {
			return "FAILED | network setting | missing key"
		}
		return harmonyBackend.setNetworkSetting(C.GoString(key), enabled != 0)
	}))
}

//export TSBackendSetExitNode
func TSBackendSetExitNode(id *C.char) *C.char {
	return C.CString(guardExportString("TSBackendSetExitNode", fallbackSetExitNode, func() string {
		if id == nil {
			return "FAILED | exit node | missing selection"
		}
		return harmonyBackend.setExitNode(C.GoString(id))
	}))
}

//export TSBackendPeerProbe
func TSBackendPeerProbe() *C.char {
	return C.CString(guardExportString("TSBackendPeerProbe", fallbackPeerProbe, func() string {
		return harmonyBackend.peerProbe()
	}))
}

//export TSBackendPeerConnectivity
func TSBackendPeerConnectivity(peerKey *C.char) *C.char {
	return C.CString(guardExportString("TSBackendPeerConnectivity", fallbackPeerConnectivityJSON, func() string {
		if peerKey == nil {
			return marshalPeerConnectivity(peerConnectivityResult{
				State: "failed", Reason: "missing_peer",
			})
		}
		return harmonyBackend.peerConnectivity(C.GoString(peerKey))
	}))
}

//export TSBackendSunshineProbe
func TSBackendSunshineProbe(peerKey *C.char) *C.char {
	return C.CString(guardExportString("TSBackendSunshineProbe", fallbackSunshineProbeJSON, func() string {
		if peerKey == nil {
			return `{"state":"error","checkedAt":0,"errorMessage":"missing_peer"}`
		}
		return harmonyBackend.sunshineProbe(C.GoString(peerKey))
	}))
}

//export TSBackendMediaServiceProbe
func TSBackendMediaServiceProbe(peerKey *C.char) *C.char {
	return C.CString(guardExportString("TSBackendMediaServiceProbe", fallbackMediaServiceProbeJSON, func() string {
		if peerKey == nil {
			return `{"state":"error","checkedAt":0,"services":[],"errorMessage":"missing_peer"}`
		}
		return harmonyBackend.mediaServiceProbe(C.GoString(peerKey))
	}))
}

//export TSMediaProbeSelfTest
func TSMediaProbeSelfTest() *C.char {
	return C.CString(guardExportString("TSMediaProbeSelfTest", fallbackMediaProbeSelfTestJSON, func() string {
		return mediaProbeSelfTest()
	}))
}

//export TSBackendTaildropSend
func TSBackendTaildropSend(request *C.char) *C.char {
	return C.CString(guardExportString("TSBackendTaildropSend", fallbackTaildropSendJSON, func() string {
		if request == nil {
			return `{"state":"failed","reason":"invalid_request"}`
		}
		return harmonyBackend.taildropSend(C.GoString(request))
	}))
}

//export TSBackendTaildropCancel
func TSBackendTaildropCancel() *C.char {
	return C.CString(guardExportString("TSBackendTaildropCancel", fallbackTaildropCancelJSON, func() string {
		return harmonyBackend.taildropCancel()
	}))
}

//export TSBackendTaildropReceive
func TSBackendTaildropReceive(request *C.char) *C.char {
	return C.CString(guardExportString("TSBackendTaildropReceive", fallbackTaildropReceiveJSON, func() string {
		if request == nil {
			return `{"state":"failed","reason":"invalid_request"}`
		}
		return harmonyBackend.taildropReceive(C.GoString(request))
	}))
}

//export TSBackendTaildriveList
func TSBackendTaildriveList(request *C.char) *C.char {
	return C.CString(guardExportString("TSBackendTaildriveList", fallbackTaildriveListJSON, func() string {
		if request == nil {
			return `{"state":"failed","path":"/","entries":[],"reason":"invalid_request"}`
		}
		return harmonyBackend.taildriveList(C.GoString(request))
	}))
}

//export TSBackendTaildriveStat
func TSBackendTaildriveStat(request *C.char) *C.char {
	return C.CString(guardExportString("TSBackendTaildriveStat", fallbackTaildriveStatJSON, func() string {
		if request == nil {
			return marshalTaildriveStat(taildriveStatResult{State: "failed", Reason: "invalid_request"})
		}
		return harmonyBackend.taildriveStat(C.GoString(request))
	}))
}

//export TSBackendTaildriveMutate
func TSBackendTaildriveMutate(request *C.char) *C.char {
	return C.CString(guardExportString("TSBackendTaildriveMutate", fallbackTaildriveMutateJSON, func() string {
		if request == nil {
			return `{"state":"failed","reason":"invalid_request"}`
		}
		return harmonyBackend.taildriveMutate(C.GoString(request))
	}))
}

//export TSBackendTaildriveDownload
func TSBackendTaildriveDownload(request *C.char) *C.char {
	return C.CString(guardExportString("TSBackendTaildriveDownload", fallbackTaildriveTransferFailedJSON, func() string {
		if request == nil {
			return `{"state":"failed","reason":"invalid_request"}`
		}
		return harmonyBackend.taildriveDownload(C.GoString(request))
	}))
}

//export TSBackendTaildriveManualDownload
func TSBackendTaildriveManualDownload(request *C.char) *C.char {
	return C.CString(guardExportString("TSBackendTaildriveManualDownload", fallbackTaildriveTransferFailedJSON, func() string {
		if request == nil {
			return `{"state":"failed","reason":"invalid_request"}`
		}
		return harmonyBackend.taildriveManualDownload(C.GoString(request))
	}))
}

//export TSBackendTaildriveUpload
func TSBackendTaildriveUpload(request *C.char) *C.char {
	return C.CString(guardExportString("TSBackendTaildriveUpload", fallbackTaildriveTransferFailedJSON, func() string {
		if request == nil {
			return `{"state":"failed","reason":"invalid_request"}`
		}
		return harmonyBackend.taildriveUpload(C.GoString(request))
	}))
}

//export TSBackendTaildriveTransferSnapshot
func TSBackendTaildriveTransferSnapshot() *C.char {
	return C.CString(guardExportString("TSBackendTaildriveTransferSnapshot", fallbackTaildriveTransferIdleJSON, func() string {
		return marshalTaildriveTransfer(harmonyBackend.taildriveTransferSnapshot())
	}))
}

//export TSBackendTaildriveCancel
func TSBackendTaildriveCancel() *C.char {
	return C.CString(guardExportString("TSBackendTaildriveCancel", fallbackTaildriveCancelJSON, func() string {
		harmonyBackend.cancelTaildriveTransfer("cancelled")
		return marshalTaildriveTransfer(harmonyBackend.taildriveTransferSnapshot())
	}))
}

//export TSBackendRestartWithTun
func TSBackendRestartWithTun(
	stateDir *C.char, deviceModel *C.char, osVersion *C.char,
	controlURL *C.char, fd C.int,
) *C.char {
	return C.CString(guardExportString("TSBackendRestartWithTun", fallbackRestartWithTun, func() string {
		if stateDir == nil || deviceModel == nil || osVersion == nil || controlURL == nil {
			return "FAILED | VPN backend | missing startup metadata"
		}
		return harmonyBackend.restartWithTun(
			C.GoString(stateDir), C.GoString(deviceModel), C.GoString(osVersion),
			C.GoString(controlURL), int(fd))
	}))
}

//export TSControlProbe
func TSControlProbe() *C.char {
	return C.CString(guardExportString("TSControlProbe", fallbackControlProbe, func() string {
		return harmonyControlProbe.startOrStatus()
	}))
}

//export TSTunFDProbe
func TSTunFDProbe(fd C.int) *C.char {
	return C.CString(guardExportString("TSTunFDProbe", fallbackTunFDProbe, func() string {
		return probeTunFD(int(fd))
	}))
}

//export TSFreeString
func TSFreeString(value *C.char) {
	guardExportVoid("TSFreeString", func() {
		if value != nil {
			C.free(unsafe.Pointer(value))
		}
	})
}

func main() {}

//export TSBackendNetworkChanged
func TSBackendNetworkChanged(interfaceName *C.char) *C.char {
	return C.CString(guardExportString("TSBackendNetworkChanged", fallbackNetworkChanged, func() string {
		if interfaceName == nil {
			return "FAILED | network change | missing interface"
		}
		return harmonyBackend.networkChanged(C.GoString(interfaceName))
	}))
}

//export TSBackendPathDiagnostic
func TSBackendPathDiagnostic(command *C.char) *C.char {
	return C.CString(guardExportString("TSBackendPathDiagnostic", fallbackPathDiagnosticJSON, func() string {
		if command == nil {
			return "{}"
		}
		return harmonyBackend.pathDiagnostic(C.GoString(command))
	}))
}
