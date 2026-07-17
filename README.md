# Tailscale for HarmonyOS NEXT

This repository is a working native HarmonyOS NEXT port of the Tailscale
userspace client. It is currently an engineering MVP, not a release-ready
consumer application.

## Current milestone

The project now provides a signed ArkTS application with this native stack:

```text
ArkTS UI / VpnExtensionAbility
  -> C++ Node-API bridge
  -> OpenHarmony arm64 Go c-shared library
  -> Tailscale v1.86.5 userspace engine
  -> HarmonyOS vpn-tun file descriptor
```

Verified on a HarmonyOS 6.1 phone:

- persistent browser login and restart without re-authentication;
- strict control-plane TLS, system roots, DNS, and TCP access;
- HarmonyOS VPN authorization and virtual-interface creation;
- an external `tun.Device` adapter feeding wireguard-go;
- backend state `Running` with `tun=true`;
- bidirectional system-browser packets through the TUN;
- an identity-redacted TSMP probe to an online tailnet peer;
- connect, disconnect, backend recovery, and reconnect without logging in again.
- stale VPN-state detection and persistent-backend recovery after a device reboot;
- VPN survival across screen-off and Wi-Fi loss/reassociation, with a live heartbeat;
- control-plane-approved subnet routes passed into the HarmonyOS VPN config,
  with `RouteAll` explicitly enabled to match Tailscale's mobile/Windows
  `--accept-routes` behavior on the OpenHarmony Go runtime;
- full behind-router subnet delivery through a temporary approved `/32`,
  verified by the injected-route count, HarmonyOS TUN deltas, anonymous
  Windows router peer deltas, and successful browser traffic; the temporary
  route and Windows forwarding changes were removed after the test;
- exit-node discovery and selection before connecting, with a safe empty state
  when the tailnet offers no eligible exit node;
- real public-IP traffic through an approved Windows exit node, verified from
  both the HarmonyOS TUN counters and anonymous Windows peer byte counters;
- exit-node choice restored across UI-to-Extension handoff and repeated signed
  HAP replacement installs without requiring the user to select it again.

MagicDNS is treated as an optional feature. The client now has an
identity-redacted DNS/TUN probe, but the current test tailnet returns NXDOMAIN
for the same node name on both this HarmonyOS port and an Android Tailscale
client. Direct Tailscale-IP traffic remains fully functional, so this
cross-platform DNS-record result does not block the MVP.

TODO(LiveView): add the opt-in Tailscale traffic LiveView only after the
application has received the official HarmonyOS LiveView entitlement and an
approved `event` scenario. The VPN Extension should own the start/update/stop
lifecycle, serialize updates at no more than 1 Hz, use the standalone Tailscale
nine-dot mark, and expose only current-session upload/download byte totals.
Until the entitlement is available, do not show a non-functional LiveView
switch in Settings.

TODO(MagicDNS): repeat the end-to-end named-peer lookup on a tailnet with a
known-good MagicDNS record and promote the feature from optional only after a
positive DNS answer and successful peer traffic are both observed. Until then,
do not claim complete MagicDNS compatibility in the user interface.

The bilingual Chinese/English UI uses the SDK 23 HDS floating bottom navigation
with immersive system material. Home owns connection state, the single
`Connect` / `Disconnect` action, exit-node selection, the read-only peer view,
Settings owns persistent disconnected-state controls for subnet-route acceptance,
Tailscale DNS, and LAN access while using an exit node, the four-level
immersive-glow preference, and account management. Connected-state
network controls become read-only so changing VPN routes never produces a
partially updated live tunnel. A confirmation-guarded logout action is
available only while disconnected. Lower-level probes remain behind a
collapsed engineering-diagnostics control on the Settings page.
The destructive logout action is intentionally not exercised by automated
real-device regression checks.

This project intentionally does not request or implement application
auto-start. After a device reboot, the app rejects the previous session's stale
heartbeat and restores the authenticated backend safely when opened; the user
then reconnects the system VPN from the app.

## Important port details

- The OpenHarmony Go port uses Linux build tags, but application processes
  cannot use tailscaled's Linux socket-mark/netns bypass. The bridge disables
  that path with `netns.SetEnabled(false)`.
- `tsnet.Server` has a small local patch allowing an externally owned
  `tun.Device`; netstack does not consume peer or subnet traffic in that mode.
- HarmonyOS owns interface and route creation. The route interface name must be
  the platform-defined `vpn-tun`, as documented by the
  [OpenHarmony VPN Extension guide](https://gitee.com/openharmony/docs/blob/08986484ea997e1da01ac9221d20dbb0a54b4922/en/application-dev/network/net-vpnExtension.md).
- The VPN Extension restores the persistent backend inside its own process,
  then restarts the engine with the HarmonyOS TUN descriptor.
- Status and test results deliberately omit auth URLs, node identities,
  tailnet addresses, keys, and signing information.
- The control-plane machine name is derived from HarmonyOS `marketName` (with
  `productModel` as fallback), and build metadata reports Tailscale `1.86.5`
  with `Linux HongMeng Kernel Build 1.12.0` as the OS build line.

## Build and real-device checks

The application baseline is HarmonyOS 6.1 / SDK 23 for both compatible and
target SDK versions. Run from PowerShell with one USB phone connected:

```powershell
scripts\build.ps1
scripts\device-engine-probe.ps1
scripts\device-backend-probe.ps1
```

After `Connect Tailscale` reports a running tunnel, validate real application
traffic and the optional online-peer probe:

```powershell
scripts\device-vpn-data-probe.ps1
scripts\device-exit-node-probe.ps1
scripts\device-user-ui-probe.ps1 -SkipInstall
```

The UI probe rejects a locked device explicitly, visits Home and Settings,
checks the home Exit Node section, all three glow choices and the engineering
menu, validates that the three connection controls remain on Home and are
editable only while disconnected, and never activates the logout action.

The scripts discover DevEco Studio from `DEVECO_STUDIO_HOME`, `DEVECO_HOME`, or
its standard Windows install location. The OpenHarmony SIG Go source tree and
bootstrap tools are generated local dependencies and are excluded from Git.
The real `build-profile.json5` is also local-only so signing paths and material
cannot be committed accidentally; `build-profile.example.json5` documents the
non-sensitive project shape. Configure local HarmonyOS signing before running
the signed-HAP and HDC workflow.

Tailscale is pinned to v1.86.5 because it supports the Go 1.24 toolchain used by
the current OpenHarmony SIG Go port.

## Roadmap to a distributable client

1. Extend lifecycle and network-transition soak tests from minutes to hours.
2. Review state-file protection, privacy disclosures, logging, resource use,
   signing, and AppGallery policy requirements.
3. Rebase the minimal Tailscale changes onto an upstreamable platform layer and
   add CI for Go, C++, ArkTS, packaging, and physical-device regression tests.
