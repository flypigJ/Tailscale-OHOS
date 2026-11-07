# Developing MeshArc

[Project overview](../README.md) · [Contributing](../CONTRIBUTING.md)

MeshArc is a native HarmonyOS NEXT client built around the Tailscale userspace engine. This guide covers the public source tree and the repository's Windows / PowerShell build and HDC workflow.

## Architecture

```text
ArkTS / ArkUI application
  └─ VpnExtensionAbility
      └─ C++ Node-API bridge
          └─ OpenHarmony arm64 Go shared library
              └─ Tailscale 1.86.5 userspace engine
                  └─ HarmonyOS vpn-tun file descriptor
```

| Path | Responsibility |
| --- | --- |
| `entry/src/main/ets/` | UI, application services and VPN Extension lifecycle. |
| `entry/src/main/cpp/` | Node-API bridge between ArkTS and Go. |
| `native/go_bridge/` | Tailscale integration, routing, device discovery and file services. |
| `patches/` | OpenHarmony Go and Tailscale integration patches. |
| `scripts/` | Build, artifact verification and physical-device probes. |
| `AppScope/app.json5` | Application identity and source-of-truth version values. |

### Port-specific constraints

- The OpenHarmony Go port uses Linux build tags, but app processes cannot use tailscaled's Linux socket-mark / network-namespace bypass. The bridge disables it with `netns.SetEnabled(false)`.
- A local `tsnet.Server` patch accepts an externally owned `tun.Device`. HarmonyOS owns interface and route creation; the platform interface is `vpn-tun`.
- The VPN Extension restores the persistent backend in its own process and restarts the engine with the HarmonyOS TUN descriptor. File-service operations use that running backend through the existing request protocol.
- MagicDNS is disabled. The optional app-level DNS override fills the VPN config's DNS-server and search-domain arrays; without it, both arrays remain empty.
- Tailscale is pinned to `1.86.5` to match the Go 1.24 toolchain used by the OpenHarmony port.
- Diagnostics must redact authentication URLs, keys, node identities, tailnet addresses, local paths and signing information.

## Prepare the environment

A fresh clone is **not yet a one-command build**. Native toolchains, upstream source trees and local signing configuration are intentionally excluded from Git.

1. Install DevEco Studio with the complete vendor HarmonyOS SDK, including HMS and OpenHarmony components. The current build uses Release SDK `26.0.0.105` with `compileSdkVersion: 26.0.0`; compatibility and target remain HarmonyOS 6.1 / API 23, with arm64 native output. See [the example build profile](../build-profile.example.json5). An incomplete, locally assembled SDK can compile successfully yet fail at runtime when an HMS module is missing.
2. Make DevEco Studio discoverable through `DEVECO_STUDIO_HOME`, `DEVECO_HOME`, or the standard Windows install location. `DEVECO_SDK_HOME` can select the SDK used by the build scripts.
3. Prepare the OpenHarmony SIG Go 1.24 toolchain at `third_party/ohos-go/`, including `bin/go.exe`. The repository does not currently provide a complete toolchain-bootstrap script; ordinary desktop Go is not a substitute for this target.
4. Check out Tailscale `v1.86.5` at `third_party/tailscale/`. The bridge's `go.mod` uses a local replacement pointing there. `scripts/build-go.ps1` checks and applies the patches from `patches/`.
5. Copy `build-profile.example.json5` to the ignored `build-profile.json5`, configure your own local development signing through DevEco Studio, and sync project dependencies in the IDE. The example deliberately contains no signing credentials.

Keep private keys, keystores, passwords and provisioning profiles out of Git. The original maintainer's signing material is not needed for a contributor build.

## Build a development HAP

Run from the repository root in PowerShell after preparing the environment:

```powershell
.\scripts\build.ps1
```

This calls the Go bridge build, invokes Hvigor for the default product, and verifies the generated artifacts.

## Install and check a physical device

Connect one unlocked USB device with development access enabled. The engine probe uses HDC to install the locally signed HAP and launch the app:

```powershell
.\scripts\device-engine-probe.ps1
.\scripts\device-backend-probe.ps1
```

After completing login and connecting the system VPN, choose checks relevant to your change:

```powershell
.\scripts\device-vpn-data-probe.ps1
.\scripts\device-exit-node-probe.ps1
.\scripts\device-taildrive-probe.ps1
.\scripts\device-user-ui-probe.ps1 -SkipInstall
```

Read each script's parameters and prerequisites first. Probes can install or replace the app and interact with its UI; route, exit-node and file-service checks need corresponding peers and permissions. The UI probe must not activate the destructive logout action.

Previous engineering checks recorded browser-login persistence, TUN traffic, reconnect and reboot recovery, approved subnet-route delivery, and traffic through an exit node. These are historical device observations, not a guarantee for every device or OS build. Long-session and network-transition testing remains valuable.

## Release maintenance

Before building, signing, promoting or publishing a Release:

1. Complete the first entry in [`ReleaseChangelog.ets`](../entry/src/main/ets/services/ReleaseChangelog.ets), including real Chinese and English dates and non-placeholder changes. Its version values must match [`AppScope/app.json5`](../AppScope/app.json5).
2. Obtain the maintainer's explicit confirmation that the release notes are complete and their decision on a full release review.
3. Verify the release profile and complete certificate chain against the private keystore in ignored local configuration. Never use debug signing for a Release.
4. Use the repository Release entry point, which enforces the changelog gate:

   ```powershell
   .\scripts\build.ps1 -Product release
   ```

Keep `versionName` in numeric `X.Y.Z` form. A new uploaded package uses exactly one more than the highest `versionCode` already used across production and test tracks. Local-only rebuilds do not consume a code. Major-version changes require explicit maintainer confirmation.

## Further reading

- [Taildrop implementation and data flow](taildrop-technical-plan.md)
- [HosPlayer server-import contract](hosplayer-integration-prototype.md)
- [HarmonyOS UI design conventions](harmonyos-ui-design-system.md)
- [Earlier user-facing changelog](../CHANGELOG.md)
