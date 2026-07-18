# Taildrop on HarmonyOS: feasibility and implementation plan

## Conclusion

Taildrop is feasible in this app with the bundled Tailscale 1.86.5 code. The network protocol, PeerAPI receiver, target filtering, retry/resume logic, staging-file manager, and LocalAPI client methods are already present upstream. The main work is platform integration: register the Taildrop extension in the Go binary, bridge requests into the VPN Extension process, and move files between HarmonyOS Picker URIs and the app sandbox.

The recommended Taildrop release is an in-app send/receive experience. System share-sheet integration can follow after the transfer core is stable. Taildrop is not exposed in the `0.7.10` AppGallery build.

## What already exists upstream

- `local.Client.FileTargets` lists eligible receivers.
- `local.Client.PushFile` streams a file to a target by stable node ID.
- `WaitingFiles`, `GetWaitingFile`, and `DeleteWaitingFile` implement the receive inbox.
- PeerAPI exposes the receive endpoint and validates that the sending peer is eligible.
- Interrupted transfers can resume by comparing remote partial-file block hashes and sending a ranged remainder.
- Incoming files are first written as partial files, then atomically finalized. Filenames are validated as base names and collisions are handled by the upstream file manager.
- Eligibility includes backend running state, Taildrop capability, peer online state, PeerAPI availability, and same-user/explicit target capability checks.

Relevant upstream code:

- [Local client file APIs](https://github.com/tailscale/tailscale/blob/v1.86.5/client/local/local.go#L735-L810)
- [Send progress and resume](https://github.com/tailscale/tailscale/blob/v1.86.5/feature/taildrop/localapi.go#L271-L356)
- [Target eligibility and receive inbox](https://github.com/tailscale/tailscale/blob/v1.86.5/feature/taildrop/ext.go#L277-L410)
- [Partial-file receive and atomic finalize](https://github.com/tailscale/tailscale/blob/v1.86.5/feature/taildrop/send.go#L61-L164)

## Current repository status

The Go binary now blank-imports `tailscale.com/feature/taildrop`, and the VPN Extension contains the initial target-discovery, staged-send, and transfer-snapshot bridge. This remains development code: the device-row send action, failure-safe staging cleanup, transfer-history UI, receiving flow, and full device validation are not complete. For that reason the `0.7.10` release removes the transfer page from both compact and wide navigation while retaining the implementation for continued development.

The UI process also stops its own backend before starting `TailscaleVpnExtensionAbility`. Taildrop must therefore execute in the VPN Extension process, where the live `tsnet.Server` and its `local.Client` exist. Calling a UI-process NAPI function directly would address a different, stopped Go runtime.

## Recommended architecture

### 1. Go transfer service in the VPN Extension process

- Blank-import `tailscale.com/feature/taildrop` in the native Go bridge.
- Add controller operations for targets, send, cancel, inbox, export-to-staging, and delete.
- Use the existing `local.Client` rather than reimplementing PeerAPI or issuing ArkTS HTTP requests.
- Give each transfer a generated ID and write a small status snapshot containing state, bytes, total, speed, error category, and timestamps.
- Keep a cancel function per active outgoing transfer. Retrying the same staged file and target lets upstream resume from the receiver's partial file when supported.

### 2. Cross-process command channel

Extend the existing app-sandbox request/response pattern already used by peer connectivity tests:

- UI writes `taildrop-request.json` atomically.
- `TailscaleVpnExtensionAbility` observes or polls requests and invokes NAPI in its own process.
- The extension writes `taildrop-status.json` atomically; UI polls while the transfer page is visible.
- Serialize commands per transfer ID and reject stale generations to prevent an old command from completing after reconnect.

This is simpler and safer than introducing a new service IPC layer for the first version.

### 3. HarmonyOS file handling

For sending, use `DocumentViewPicker.select()` and open the returned URI with Core File Kit. Because Picker URI grants and open file descriptors should not be assumed transferable to the VPN Extension process, copy the selected file to an app-private outbox first. The request then contains only the staged path, original base name, size, target stable ID, and transfer ID.

For receiving, let the upstream Taildrop manager stage incoming files under the Tailscale state directory. The UI shows `WaitingFiles`; after the user chooses Save, use `DocumentViewPicker.save()` and stream the waiting file to the returned URI. Delete the Taildrop inbox copy only after the export is closed successfully.

Staging costs temporary extra disk space but gives reliable cross-process access, deterministic resume, and protection from expiring Picker grants. A later optimization can pass duplicated file descriptors through a proper IPC channel to avoid the extra copy for very large sends.

### 4. UI scope for the first release

- Device-card action: **Send file**, enabled only for `TaildropTargetAvailable` peers.
- Multi-file Picker, but queue files and send one at a time initially.
- Transfer sheet with filename, target, progress, speed, cancel, retry, and completed state.
- Inbox entry point with waiting-file count, Save, and Delete actions.
- Clear explanations for admin-disabled Taildrop, other-user devices, offline peers, tagged nodes, expired keys, and disconnected VPN state.

System share-sheet support is a second milestone: register the app as a share target, stage incoming shared URIs, then open the same device-picker and transfer queue.

## Background behavior

The live VPN Extension already owns the network engine and should own active Taildrop I/O. Do not use HarmonyOS `request.agent` for the Taildrop data path: it expects ordinary URL uploads/downloads and cannot substitute for Tailscale's internal PeerAPI transport. The UI may leave the foreground while the extension continues, but the implementation must verify VPN Extension lifetime and system background limits on a device. Persist enough status to recover the UI after process recreation.

## Security and reliability requirements

- Accept only a sanitized base filename; never accept an absolute path or path separator from a request.
- Re-check target eligibility in Go immediately before sending; do not trust UI-cached peer state.
- Enforce free-space checks and a configurable staging quota before copying or receiving.
- Write request/status files by temp-file plus atomic rename and restrict them to the app sandbox.
- Never delete the received staging file until user export succeeds.
- Redact local paths and peer identity from diagnostics; expose categorized errors to ArkTS.
- Test direct LAN, DERP-relayed, interruption/resume, reconnect, duplicate filename, zero-byte file, multi-gigabyte file, low disk, sender cancellation, receiver restart, and key-expired/device-approval states.

## Delivery estimate

1. Transfer-core spike (registration, target list, one-file send, receive inbox): 2–3 engineering days.
2. HarmonyOS Picker/staging bridge and progress/cancel UI: 3–5 days.
3. Reliability, background, low-disk, resume, and real-device interoperability tests: 3–5 days.
4. Optional system share target and notification polish: 2–4 days.

The key proof-of-concept gate is small: after registering the feature in the VPN Extension binary, verify that another official Tailscale client lists the HarmonyOS node as a Taildrop target and can PUT a small file into its waiting inbox.
