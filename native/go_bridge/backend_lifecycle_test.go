package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"
	"tailscale.com/hostinfo"
	"tailscale.com/types/key"
)

func TestStopReleasesProductionStateLease(t *testing.T) {
	root := privateUpgradeTestDirectory(t)
	lease, err := prepareEngineStateUpgrade(root)
	if err != nil {
		t.Fatal(err)
	}
	controller := &backendController{engineLease: lease}
	if _, err := acquireEngineStateLease(root); err == nil {
		t.Fatal("active identity lease was not exclusive")
	}
	controller.stop()
	reopened, err := acquireEngineStateLease(root)
	if err != nil {
		t.Fatalf("stop retained the identity lease: %v", err)
	}
	defer reopened.Close()
	if controller.engineLease != nil {
		t.Fatal("stopped controller retains lease")
	}
}

func TestRejectedStateUpgradeClosesTunAndPreservesState(t *testing.T) {
	base := t.TempDir()
	profile := controlServerStateDir(base, "https://controlplane.tailscale.com")
	if err := os.MkdirAll(profile, 0700); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(profile, engineUpgradeMarker)
	if err := os.WriteFile(marker, []byte("invalid-existing-marker"), 0600); err != nil {
		t.Fatal(err)
	}
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	defer writer.Close()
	device, err := newHarmonyTunDevice(int(reader.Fd()), 1280)
	if err != nil {
		t.Fatal(err)
	}
	fd := int(device.file.Fd())
	controller := &backendController{}
	result := controller.startWithDevice(base, "test", "https://controlplane.tailscale.com", device)
	if result != "FAILED | backend start | private state upgrade" || controller.server != nil || controller.engineLease != nil {
		t.Fatal("unverified state reached server startup")
	}
	if _, err := unix.FcntlInt(uintptr(fd), unix.F_GETFD, 0); err != unix.EBADF {
		t.Fatal("rejected duplicate TUN retained")
	}
	if bytes, err := os.ReadFile(marker); err != nil || string(bytes) != "invalid-existing-marker" {
		t.Fatal("existing state marker overwritten")
	}
	lease, err := acquireEngineStateLease(profile)
	if err != nil {
		t.Fatal("failed upgrade leaked identity lock")
	}
	lease.Close()
}

func TestRejectedStartClosesUnclaimedTun(t *testing.T) {
	for _, scenario := range []string{"invalid-control", "already-starting"} {
		t.Run(scenario, func(t *testing.T) {
			reader, writer, err := os.Pipe()
			if err != nil {
				t.Fatal(err)
			}
			defer reader.Close()
			defer writer.Close()
			device, err := newHarmonyTunDevice(int(reader.Fd()), 1280)
			if err != nil {
				t.Fatal(err)
			}
			defer device.Close()
			fd := int(device.file.Fd())
			controller := &backendController{}
			control := "not-a-url"
			if scenario == "already-starting" {
				controller.starting = true
				control = "https://controlplane.tailscale.com"
			}
			result := controller.startWithDevice(t.TempDir(), "test", control, device)
			if scenario == "invalid-control" && !strings.HasPrefix(result, "FAILED") {
				t.Fatal(result)
			}
			if _, err := unix.FcntlInt(uintptr(fd), unix.F_GETFD, 0); err != unix.EBADF {
				t.Fatalf("unclaimed duplicate still open: %v", err)
			}
			if _, err := reader.Stat(); err != nil {
				t.Fatalf("caller descriptor was closed: %v", err)
			}
		})
	}
}

func TestConcurrentStopAndRestartSerializeLeaseWithoutBlockingStatus(t *testing.T) {
	base := t.TempDir()
	if err := os.Chmod(base, 0700); err != nil {
		t.Fatal(err)
	}
	const controlURL = "http://127.0.0.1:1"
	profile := controlServerStateDir(base, controlURL)
	if err := os.MkdirAll(profile, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(profile, 0700); err != nil {
		t.Fatal(err)
	}
	lease, err := prepareEngineStateUpgrade(profile)
	if err != nil {
		t.Fatal(err)
	}

	inTeardown := make(chan struct{})
	allowLeaseClose := make(chan struct{})
	controller := &backendController{
		engineLease: lease,
		onStopBeforeLeaseClose: func() {
			close(inTeardown)
			<-allowLeaseClose
		},
	}
	defer controller.stop()

	stopDone := make(chan string, 1)
	go func() {
		stopDone <- controller.stop()
	}()

	select {
	case <-inTeardown:
	case <-time.After(3 * time.Second):
		t.Fatal("stop() did not reach teardown hook")
	}

	// b.mu must NOT be held during server/lease teardown, so status() stays non-blocking.
	statusDone := make(chan string, 1)
	go func() {
		statusDone <- controller.status()
	}()
	select {
	case gotStatus := <-statusDone:
		if gotStatus != "STOPPED | backend not started" {
			t.Fatalf("status() during teardown = %q, want STOPPED | backend not started", gotStatus)
		}
	case <-time.After(500 * time.Millisecond):
		t.Fatal("status() blocked on lifecycle teardown")
	}

	// Clear hook before restart's subsequent cleanup.
	controller.mu.Lock()
	controller.onStopBeforeLeaseClose = nil
	controller.mu.Unlock()

	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	defer writer.Close()

	restartDone := make(chan string, 1)
	go func() {
		restartDone <- controller.restartWithTun(base, "HUAWEI Mate 60", "5.0.0", controlURL, int(reader.Fd()))
	}()

	// Give restartWithTun time to contend on lifecycleMu while lease is still held.
	time.Sleep(25 * time.Millisecond)
	close(allowLeaseClose)

	select {
	case stopRes := <-stopDone:
		if stopRes != "OK | backend stopped" {
			t.Fatalf("stop() = %q", stopRes)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("stop() timed out")
	}

	select {
	case restartRes := <-restartDone:
		if restartRes != "OK | VPN backend starting | persistent private state" {
			t.Fatalf("concurrent restartWithTun() = %q, want OK | VPN backend starting | persistent private state", restartRes)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("restartWithTun() timed out waiting on lifecycleMu")
	}
}

func TestRestartWithTunClearsWarmCachesAndRefreshesHostinfo(t *testing.T) {
	updateActiveHarmonyHostinfo("5.0.0", "HUAWEI Mate 60 Pro")
	firstInfo := hostinfo.New()
	if firstInfo.OS != "HarmonyOS" || firstInfo.OSVersion != "5.0.0" || firstInfo.DeviceModel != "Mate 60 Pro" {
		t.Fatalf("first hostinfo.New() = %+v", firstInfo)
	}

	updateActiveHarmonyHostinfo("6.0.0", "HUAWEI Pura 80 Ultra")
	secondInfo := hostinfo.New()
	if secondInfo.OS != "HarmonyOS" || secondInfo.OSVersion != "6.0.0" || secondInfo.DeviceModel != "Pura 80 Ultra" {
		t.Fatalf("second hostinfo.New() remained stale: %+v", secondInfo)
	}

	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	defer writer.Close()

	peerKey := key.NewNode().Public()
	controller := &backendController{
		taildriveWarmAt:     map[string]time.Time{"nas": time.Now()},
		taildriveDAVReadyAt: map[string]time.Time{"nas": time.Now()},
		peerHostinfoGen:     1,
		peerHostinfo: map[key.NodePublic]cachedPeerHostinfo{
			peerKey: {osName: "linux", osVersion: "6.12", expiresAt: time.Now().Add(time.Minute)},
		},
	}

	res := controller.restartWithTun(t.TempDir(), "HUAWEI Pura 80 Ultra", "6.0.0", "not-a-url", int(reader.Fd()))
	if res != "FAILED | backend start | invalid control server" {
		t.Fatalf("restartWithTun with invalid control = %q", res)
	}
	if controller.taildriveWarmAt != nil || controller.taildriveDAVReadyAt != nil {
		t.Fatal("restartWithTun did not clear Taildrive warm caches")
	}
	if controller.peerHostinfo != nil || controller.peerHostinfoGen != 0 {
		t.Fatal("restartWithTun did not clear peerHostinfo cache")
	}
}
