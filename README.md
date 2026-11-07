# MeshArc

<img src="AppScope/resources/base/media/app_icon.png" width="96" alt="MeshArc app icon">

A native Tailscale community client for HarmonyOS NEXT.

[![Latest release](https://img.shields.io/github/v/release/flypigJ/Tailscale-OHOS?label=Release&logo=github)](https://github.com/flypigJ/Tailscale-OHOS/releases/latest)
[![AppGallery](https://img.shields.io/badge/AppGallery-Download-2563eb)](https://appgallery.huawei.com/app/detail?id=io.github.tailscaleohos)
[![License: BSD-3-Clause](https://img.shields.io/badge/License-BSD--3--Clause-blue.svg)](LICENSE)

Connect your HarmonyOS device to your tailnet. Reach your computers and NAS, move files between devices, and open your remote media library.

## Features

1. **Private networking:** connect to Tailscale, inspect device status and latency, and access services by Tailscale IP.
2. **Exit nodes and subnet routes:** use an available exit node, accept approved routes, and control local network access.
3. **File sharing:** send and receive files with Taildrop through MeshSend; browse, upload and download authorized Taildrive shares.
4. **Media integration:** discover Jellyfin, Emby and Plex servers and open them in HosPlayer.
5. **Local privacy:** protect app access and Taildrive folders with system authentication.
6. **Custom DNS:** use primary and backup resolvers for apps routed through the VPN, with optional DNS search domains.
7. **Native experience:** adaptive ArkUI layouts, light and dark themes, and English and Chinese app interfaces.

## Compatibility

The source project targets **HarmonyOS 6.1 / API 23** and **arm64**, with layouts for phones, tablets and 2in1 devices. Check AppGallery for the requirements of the store version. Device testing has primarily used a physical phone.

The Tailscale engine is currently pinned to **1.86.5** with the OpenHarmony Go 1.24 toolchain.

- MagicDNS is not enabled; use Tailscale IP addresses.
- Reconnect manually after restarting your device.
- Disconnect other system VPNs before connecting.

## Usage

- [Get MeshArc on AppGallery](https://appgallery.huawei.com/app/detail?id=io.github.tailscaleohos)
- [Download HAP builds and read release notes](https://github.com/flypigJ/Tailscale-OHOS/releases/latest)
- [Installation and first connection](docs/getting-started.md)
- [Build on Windows](docs/development.md) · [Build on macOS](docs/build-macos.md)

## Contributing

Bug reports, documentation, device testing and focused pull requests are welcome. Read the [contributing guide](CONTRIBUTING.md) and search [existing issues](https://github.com/flypigJ/Tailscale-OHOS/issues) before opening a report.

## License

MeshArc is licensed under the [BSD 3-Clause License](LICENSE). Third-party components retain their original licenses and copyright notices; see [third-party notices](THIRD_PARTY_NOTICES.md).

## Credits

- [Tailscale](https://github.com/tailscale/tailscale) for the networking engine.
- [OpenHarmony Go](https://gitcode.com/openharmony-sig/ohos_golang_go) for the Go toolchain port.
- [LocalSend](https://github.com/localsend/localsend) for the local file-sharing protocol and implementation reference.
- Everyone testing MeshArc, reporting issues and contributing improvements.

MeshArc is an independent community project and is not affiliated with or endorsed by Tailscale Inc. The app is named MeshArc; this repository retains the name `Tailscale-OHOS`.
