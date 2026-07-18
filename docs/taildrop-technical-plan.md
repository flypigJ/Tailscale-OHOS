# Taildrop on HarmonyOS: feasibility and implementation plan

## Conclusion

Taildrop is feasible in this app with the bundled Tailscale 1.86.5 code. The network protocol, PeerAPI receiver, target filtering, retry/resume logic, staging-file manager, and LocalAPI client methods are already present upstream. The main work is platform integration: register the Taildrop extension in the Go binary, bridge requests into the VPN Extension process, and move files between HarmonyOS Picker URIs and the app sandbox.

The recommended first release is an in-app send/receive experience. System share-sheet integration can follow after the transfer core is stable.

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

## Current `main` status

Last audited on 2026-07-18. The transfer page is visible in both compact and wide navigation on the development branch. Sending and inbox export are reachable. A HarmonyOS-to-Windows real-device send has passed; background, interruption, and large-file coverage remain release gates.

| Area | Status | Evidence and remaining gap |
|---|---|---|
| Taildrop registration | Implemented | The Go bridge blank-imports `tailscale.com/feature/taildrop`, so LocalAPI and PeerAPI handlers are registered in the live VPN Extension backend. |
| Target discovery | Implemented | `local.Client.FileTargets` is queried from the VPN Extension process. Stable peer keys, display names, OS/model, online state, admin-disabled state, and query failures are persisted for the UI. |
| Picker and staging | Implemented | The UI can select up to 10 documents, sanitize base names, copy them into an app-private per-request outbox, verify copied sizes, and publish the request by temporary-file rename. |
| Send engine | Implemented and real-device verified | Tapping an online target opens the document Picker. The Go bridge revalidates the outbox path and file metadata, re-resolves target eligibility, warms the target PeerAPI path, and sends up to 10 files sequentially with `local.Client.PushFile`. In external-TUN mode, peer/PeerAPI TCP dials use the embedded netstack while ordinary control/DERP sockets remain on the physical network. |
| Progress and completion state | Implemented for the first usable flow | Queued/sending state, aggregate byte progress, current filename, completion, failure, and cancellation are rendered from the VPN Extension snapshot. Speed and ETA are not yet shown. |
| History | Implemented | A bounded 20-record send/receive history is rendered and atomically persisted. Restoring the UI also restores the last handled send request ID to avoid duplicate terminal records. |
| Cancellation and retry | Implemented | The user can cancel an active outgoing transfer. Transient PUT failures are retried up to three times from the retained staged file; upstream Taildrop partial hashing resumes at the receiver's confirmed offset. A terminal failed send can still reopen the Picker for the same target. |
| Cleanup | Implemented with a recovery fallback | Staged files are removed after success/failure and stale outbox entries are cleaned when the VPN Extension starts. Free-space checks and a staging quota are still absent. |
| Receive inbox | Implemented for Save/export | The snapshot exposes `WaitingFiles`. Save uses `DocumentViewPicker.save()`, asks the VPN Extension/Go backend to copy `GetWaitingFile` into a validated private staging path, exports it to the Picker URI, and calls `DeleteWaitingFile` only after the copy is verified. An explicit discard-without-save action is not yet exposed. |
| Background/user feedback | Missing validation | No completion notification or real-device proof covers screen-off, UI-process recreation, VPN Extension lifetime, or long/large transfers. |
| Automated coverage | Partial | Go tests cover receive-request path validation, exact-size staging, short-stream rejection, transient send-error classification, retry cancellation, and tracked netstack source-port lifecycle. A 619,844-byte HarmonyOS-to-Windows device probe completed on 2026-07-18. Device-level ArkTS/NAPI, DERP, interruption, background, and large-file coverage are still incomplete. |

The UI process still stops its own backend before starting `TailscaleVpnExtensionAbility`. Active Taildrop I/O must therefore remain in the VPN Extension process, where the live `tsnet.Server` and `local.Client` exist. Calling a UI-process NAPI function directly would address a different, stopped Go runtime.

### 288 KiB send-failure incident

The fixed 294,912-byte progress value was HTTP request buffering, not a file-size limit. `PushFile` entered LocalAPI correctly, but its PeerAPI request used an ordinary system TCP dial when `tsnet.Server` had an externally supplied HarmonyOS TUN. Because the VPN bundle is intentionally listed in `blockedApplications`, that dial bypassed the VPN route and timed out before reaching the Windows receiver. Each failure therefore sat at 294,912 bytes for roughly 40 seconds and ended as a 502-style send error.

The fix keeps canonical Tailscale peer destinations in userspace netstack when the external TUN is active. A reserved source-port range tracks only TCP connections created by those embedded PeerAPI dials, and the inbound hook returns replies for those ports to gVisor. All other traffic for the local Tailscale address still flows to the HarmonyOS TUN, preserving VPN service for other applications. The project stores this vendor integration in `patches/tailscale-ohos.patch`, and `scripts/build-go.ps1` checks/applies it before every Go build.

The post-fix real-device probe sent 619,844 bytes from HarmonyOS to Tailscale 1.98.8 on Windows and reached `completed` with `fileBytes == fileSize`. This crossed the former 294,912-byte boundary and produced the exact-size destination file.

## Remaining implementation plan

### 1. Harden the outgoing-transfer experience

- Add transfer speed and ETA and distinguish permission, low-space, offline, disconnected, and admin-disabled failures in the active panel. Timeout/network interruption now has a dedicated terminal message.
- Decide whether failed staged sends should be retained for zero-copy retry or continue reopening the Picker for least-privilege access.
- Add an explicit busy message instead of only disabling target and inbox rows.

### 2. Harden the cross-process command channel

Extend the existing app-sandbox request/response pattern already used by peer connectivity tests:

- The UI already writes `taildrop-send-request.json` atomically and the VPN Extension polls it before invoking NAPI.
- Snapshot persistence now uses temporary-file plus atomic rename; extend the same generation discipline to every request and response.
- Add a connection generation to requests and snapshots so stale work cannot be accepted after reconnect.
- Keep one active outgoing request at a time, but expose the busy state rather than silently rejecting a second action.

This is simpler and safer than introducing a new service IPC layer for the first version.

### 3. Harden receiving and export

Sending already uses `DocumentViewPicker.select()` and copies Picker URIs into an app-private outbox because Picker grants and file descriptors should not be assumed transferable to the VPN Extension process.

The first Save/export flow is implemented. Remaining work is an explicit discard action, low-space preflight, staging quota/expiry, user-visible cleanup failures, and recovery UI for a process restart between staging and export.

Staging costs temporary extra disk space but gives reliable cross-process access, deterministic resume, and protection from expiring Picker grants. A later optimization can pass duplicated file descriptors through a proper IPC channel to avoid the extra copy for very large sends.

### 4. Release gate

- Reachable outgoing send with progress, cancel, retry, and persistent terminal history.
- Receive inbox with waiting-file count, Save, Delete, collision, and failed-export handling.
- Free-space checks, staging quota/expiry, atomic snapshots, and recovery after process recreation.
- Direct-LAN and DERP interoperability with official clients, interruption/resume, duplicate names, zero-byte and large files, low disk, screen-off/background, reconnect, restart, and policy-disabled states on real devices.
- Taildrop-specific unit/integration tests plus at least one end-to-end device test.

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
