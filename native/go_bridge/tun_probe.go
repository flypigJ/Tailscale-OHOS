package main

// probeTunFD verifies that a HarmonyOS VPN descriptor can be duplicated and
// wrapped as the wireguard-go TUN device expected by Tailscale. The descriptor
// is never read from or written to during this probe.
func probeTunFD(fd int) string {
	return guardExportString("probeTunFD", fallbackTunFDProbe, func() string {
		if fd < 0 {
			return "FAILED | TUN fd probe | invalid descriptor"
		}

		device, err := newHarmonyTunDevice(fd, 1280)
		if err != nil {
			return "FAILED | TUN fd probe | descriptor adaptation"
		}
		if err := device.Close(); err != nil {
			return "FAILED | TUN fd probe | descriptor close"
		}
		return "OK | HarmonyOS TUN fd adapted for wireguard-go"
	})
}
