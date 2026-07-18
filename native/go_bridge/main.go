package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"fmt"
	"runtime"
	"runtime/debug"
	"unsafe"

	"tailscale.com/net/netns"
	"tailscale.com/net/tsdial"
	"tailscale.com/tsd"
	"tailscale.com/version"
	"tailscale.com/wgengine"
)

//export TSHello
func TSHello() *C.char {
	platform := runtime.GOOS
	if runtime.IsOpenharmony {
		platform = "openharmony"
	}
	message := fmt.Sprintf("OK · Go %s · %s/%s", runtime.Version(), platform, runtime.GOARCH)
	return C.CString(message)
}

//export TSProbeEngine
func TSProbeEngine() (result *C.char) {
	stage := "entry"
	defer func() {
		if recovered := recover(); recovered != nil {
			result = C.CString(fmt.Sprintf(
				"FAILED | stage=%s | Tailscale engine panic | %v\n%s",
				stage, recovered, debug.Stack()))
		}
	}()
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
		HealthTracker: sys.HealthTracker(),
		Metrics:       sys.UserMetricsRegistry(),
	})
	if err != nil {
		return C.CString(fmt.Sprintf("FAILED | Tailscale %s | %v", version.Short(), err))
	}
	stage = "close-userspace-engine"
	defer engine.Close()
	stage = "set-engine-subsystem"
	sys.Set(engine)
	stage = "complete"
	return C.CString(fmt.Sprintf("OK | Tailscale %s | userspace engine initialized", version.Short()))
}

//export TSBackendStart
func TSBackendStart(stateDir *C.char, deviceModel *C.char, controlURL *C.char) *C.char {
	if stateDir == nil || deviceModel == nil || controlURL == nil {
		return C.CString("FAILED | backend start | missing startup metadata")
	}
	return C.CString(harmonyBackend.start(C.GoString(stateDir), C.GoString(deviceModel), C.GoString(controlURL)))
}

//export TSBackendStop
func TSBackendStop() *C.char {
	return C.CString(harmonyBackend.stop())
}

//export TSBackendLogout
func TSBackendLogout() *C.char {
	return C.CString(harmonyBackend.logout())
}

//export TSBackendStatus
func TSBackendStatus() *C.char {
	return C.CString(harmonyBackend.status())
}

//export TSBackendSnapshot
func TSBackendSnapshot() *C.char {
	return C.CString(harmonyBackend.snapshot())
}

//export TSBackendAuthURL
func TSBackendAuthURL() *C.char {
	return C.CString(harmonyBackend.authURL())
}

//export TSBackendVPNConfig
func TSBackendVPNConfig() *C.char {
	return C.CString(harmonyBackend.vpnConfig())
}

//export TSBackendExitNodes
func TSBackendExitNodes() *C.char {
	return C.CString(harmonyBackend.exitNodes())
}

//export TSBackendPeers
func TSBackendPeers() *C.char {
	return C.CString(harmonyBackend.peers())
}

//export TSBackendAccount
func TSBackendAccount() *C.char {
	return C.CString(harmonyBackend.account())
}

//export TSTailscaleVersion
func TSTailscaleVersion() *C.char {
	return C.CString(version.Short())
}

//export TSBackendNetworkSettings
func TSBackendNetworkSettings() *C.char {
	return C.CString(harmonyBackend.networkSettings())
}

//export TSBackendSetNetworkSetting
func TSBackendSetNetworkSetting(key *C.char, enabled C.int) *C.char {
	if key == nil {
		return C.CString("FAILED | network setting | missing key")
	}
	return C.CString(harmonyBackend.setNetworkSetting(C.GoString(key), enabled != 0))
}

//export TSBackendSetExitNode
func TSBackendSetExitNode(id *C.char) *C.char {
	if id == nil {
		return C.CString("FAILED | exit node | missing selection")
	}
	return C.CString(harmonyBackend.setExitNode(C.GoString(id)))
}

//export TSBackendPeerProbe
func TSBackendPeerProbe() *C.char {
	return C.CString(harmonyBackend.peerProbe())
}

//export TSBackendPeerConnectivity
func TSBackendPeerConnectivity(peerKey *C.char) *C.char {
	if peerKey == nil {
		return C.CString(marshalPeerConnectivity(peerConnectivityResult{
			State: "failed", Reason: "missing_peer",
		}))
	}
	return C.CString(harmonyBackend.peerConnectivity(C.GoString(peerKey)))
}

//export TSBackendTaildropSend
func TSBackendTaildropSend(request *C.char) *C.char {
	if request == nil {
		return C.CString(`{"state":"failed","reason":"invalid_request"}`)
	}
	return C.CString(harmonyBackend.taildropSend(C.GoString(request)))
}

//export TSBackendMagicDNSProbeURL
func TSBackendMagicDNSProbeURL() *C.char {
	return C.CString(harmonyBackend.magicDNSProbeURL())
}

//export TSBackendArmMagicDNSProbe
func TSBackendArmMagicDNSProbe() *C.char {
	return C.CString(harmonyBackend.armMagicDNSProbe())
}

//export TSBackendRestartWithTun
func TSBackendRestartWithTun(stateDir *C.char, deviceModel *C.char, controlURL *C.char, fd C.int) *C.char {
	if stateDir == nil || deviceModel == nil || controlURL == nil {
		return C.CString("FAILED | VPN backend | missing startup metadata")
	}
	return C.CString(harmonyBackend.restartWithTun(
		C.GoString(stateDir), C.GoString(deviceModel), C.GoString(controlURL), int(fd)))
}

//export TSControlProbe
func TSControlProbe() *C.char {
	return C.CString(harmonyControlProbe.startOrStatus())
}

//export TSTunFDProbe
func TSTunFDProbe(fd C.int) *C.char {
	return C.CString(probeTunFD(int(fd)))
}

//export TSFreeString
func TSFreeString(value *C.char) {
	C.free(unsafe.Pointer(value))
}

func main() {}
