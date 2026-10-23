package main

import (
	"os"
	"testing"

	"tailscale.com/tsnet"
)

func lifecycleTun(t *testing.T) *harmonyTunDevice {
	t.Helper()
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reader.Close(); _ = writer.Close() })
	device, err := newHarmonyTunDevice(int(reader.Fd()), 1280)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = device.Close() })
	return device
}

func TestReleaseTunForStaleStartPreservesNewDevice(t *testing.T) {
	oldDevice := lifecycleTun(t)
	newDevice := lifecycleTun(t)
	oldServer := &tsnet.Server{}
	newServer := &tsnet.Server{}
	backend := backendController{server: newServer, generation: 2, tunDevice: newDevice, externalTun: true}
	backend.releaseTunFor(oldServer, 1, oldDevice)
	if backend.tunDevice != newDevice || !backend.externalTun {
		t.Fatal("stale release changed current TUN ownership")
	}
	if _, err := oldDevice.file.Stat(); err == nil {
		t.Fatal("stale start descriptor is still open")
	}
	if _, err := newDevice.file.Stat(); err != nil {
		t.Fatalf("new session descriptor was closed: %v", err)
	}
}

func TestReleaseTunForCurrentStartIsIdempotent(t *testing.T) {
	device := lifecycleTun(t)
	server := &tsnet.Server{}
	backend := backendController{server: server, generation: 1, tunDevice: device, externalTun: true}
	backend.releaseTunFor(server, 1, device)
	backend.releaseTunFor(server, 1, device)
	if backend.tunDevice != nil || backend.externalTun {
		t.Fatal("failed start retained current TUN ownership")
	}
	if _, err := device.file.Stat(); err == nil {
		t.Fatal("failed start descriptor is still open")
	}
}

func TestInvalidStartClosesUnclaimedTun(t *testing.T) {
	device := lifecycleTun(t)
	var backend backendController
	backend.startWithDevice(t.TempDir(), "test", "://invalid", device)
	if _, err := device.file.Stat(); err == nil {
		t.Fatal("rejected start leaked its descriptor")
	}
}
