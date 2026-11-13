# Background VPN reliability

## Milestone 1 — continuous task lifetime and screen-off verification

Scope: fix the existing UIAbility continuous task that protects the VPN starter
process. Preserve the VPN extension, native protocol, persisted state and user data.
The reported failure is disconnecting after several minutes locked or idle.

Official references checked through HarmonyOS Knowledge MCP:

- [VPN lifecycle](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/net-vpnextension): the system stops VPN when either its starter process or extension process exits.
- [Background tasks](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-resourceschedule-backgroundtaskmanager): Stage continuous tasks must be requested by UIAbility with `KEEP_BACKGROUND_RUNNING`. DATA_TRANSFER requires system live-view updates; missing updates for ten minutes can cancel the task. The string-array overload (API 12) returns the notification/task IDs; cancellation is available since API 15 and suspend/active events since API 20. All fit this project's API 23 minimum on phone, tablet and 2in1.
- [Notification template](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-inner-notification-notificationtemplate): downloadTemplate progress is 0–100; a VPN has no finite completion percentage. Show cumulative real traffic in notification text and leave percentage at zero, rather than fabricate download progress.

Implementation:

1. Keep the existing early foreground task acquisition. Use the returned task and notification IDs, and periodically update the same system live view with redacted traffic totals.
2. Treat missing/stale telemetry as uncertain, with a bounded grace period; explicit disconnect still releases the task promptly.
3. Serialize start/stop/update operations. Do not overwrite a cancellation received while start is pending. Honor user cancellation until a confirmed disconnect; back off system cancellation and API failures.
4. Record task creation, cancellation, suspension and cleanup errors in existing redacted diagnostics. Begin extension heartbeats before waiting for the peer probe; snapshot failures must not falsely announce a VPN failure.

Validation: deterministic lifecycle/race tests, repository debug build and artifact
checks, then a real-device background/lock test exceeding ten minutes with process,
heartbeat and peer reachability evidence. No Release build or upload in this milestone.
An attached HDC cable/charging changes power-management conditions; a passing run
does not establish indefinite survival on battery, force-stop or task removal.

## Results

- `node --test scripts/test-vpn-background-task.mjs`: 14 tests passed, including cancellation during start, destruction during start/publish, reconnect during stop, system retry backoff, user dismissal, stale/future/missing telemetry and live-view identity/traffic.
- Repository Debug build and Go/N-API artifact checks passed using the complete DevEco SDK `26.0.0.105`. The installed package is Debug `1.1.0` / `100000004` (the existing pending iteration's version).
- The build entry now prefers the official Hvigor wrapper and the complete DevEco SDK. Direct engine invocation with the injected IDE `NODE_PATH` failed before PreBuild; the project-local SDK copy `26.0.0.38` built but produced a runtime `@hms:collaboration.systemShare` module-resolution crash. The complete vendor SDK fixes startup without changing the sharing feature.
- Pre-lock real-device data-plane probe passed: browser-generated TUN traffic increased by 13 reads and 18 writes; the extension's peer probe was reachable.
- Uninterrupted locked idle run passed on HUAWEI Pura 80 Pro, HarmonyOS `7.0.0.105`: 721 seconds, 25 samples including the baseline, all 24 post-baseline samples in `SLEEP`, identical UI/VPN process IDs throughout, maximum heartbeat age 1,104 ms. The first run was interrupted by screen-on use and stopped; it is not counted as a continuous-lock pass. No active peer probes were sent during the uninterrupted idle interval; HDC read only process/heartbeat/power state.
- After the idle run, TSMP through WireGuard responded in 6 ms and the phone's PeerAPI HTTP endpoint responded in 8 ms. PowerManager reported the same `SLEEP` state before and after both requests, establishing network service while still asleep, beyond a UI status or process-existence check. ICMP was unavailable at the initial optional baseline; it is not used as evidence of success.
- Post-lock browser/TUN probe initially could not produce traffic while the keyguard was locked. After the user unlocked the screen, the probe passed with 16 additional TUN reads and 20 writes, and the peer probe remained reachable. The VPN app stayed in the background and both process IDs still matched the original baseline. The earlier locked TSMP/PeerAPI success is independent of this browser UI check.

The device remained attached to USB/HDC and charging. Continuous screen-off and
network service passed under those conditions; unplugged battery-only deep idle,
memory pressure, reboot and user force-stop are not covered by this run.

Reproduce the liveness test after connecting in the app, starting with the screen awake:

```powershell
node --test scripts/test-vpn-background-task.mjs
powershell -File scripts/build.ps1 -Product default
powershell -File scripts/device-vpn-data-probe.ps1
powershell -File scripts/device-background-vpn-probe.ps1 -DurationSeconds 720 -LockScreen
```

After the lock test, wake/unlock the device and rerun `device-vpn-data-probe.ps1`
to verify actual browser traffic while the VPN app remains in the background.
Redacted per-sample results are written under the ignored `.codex/background-vpn/`
directory. Do not upload app sandbox files, account state or signing materials.

## Milestone 2 — low-memory kills of the VPN Extension process

Reported failure: the VPN drops within seconds to minutes of backgrounding the app,
mostly while other apps are in use. Evidence from `/data/log/hilog` (decoded with the
SDK's `hilogtool parse`) on a phone running HarmonyOS 7.0.0.111 (API 26):

- The Extension process (`<bundle>:vpn`) is ended with SIGKILL, `Kill Reason:
  LowMemoryKill` or a kernel-level kill, in the same sweep as other small background
  Extensions and services. It never runs `onDestroy`, so its status file still reads
  `state=Running`.
- `/proc/<pid>/oom_score_adj`: UI process **200** (it holds the continuous task),
  ordinary background apps 400, VPN Extension **500** — the first tier to be killed
  once available memory falls below the system buffer (1800–2100 MB observed).
- The continuous task does not cover the Extension: the system VPN service launches
  it, so no app process counts as connected to it.

Measured on the same device and found **not** to change the Extension's tier:
Huawei's published VPN keep-alive sample
(<https://developer.huawei.com/consumer/cn/blog/topic/03228079102148956>: task
requested only in `onBackground`, legacy `BackgroundMode.DATA_TRANSFER` overload,
WantAgent targeting the Extension), and `extensionProcessMode: "runWithMainProcess"`
on the vpn Extension (accepted by the build and by installation, ignored at run time).

Implementation: once a live session is confirmed, `VpnBackgroundTaskManager` binds
the UI process to the VPN Extension with `connectServiceExtensionAbility`, and the
Extension implements `onConnect` returning an `rpc.RemoteObject`. The connection
carries no calls. The Extension's `oom_score_adj` becomes **300** with the app in the
background and **100** in the foreground.

- `onConnect` is mandatory: without it the framework throws while reading the result
  and ends the Extension with `Js Error`.
- A bind starts its target if it is not running. The manager therefore binds only
  against a heartbeat younger than 3 s and, after a lost or refused bind, only once a
  newer heartbeat appears (refusals also back off for 10 s).
- The binding is released on disconnect and when the Ability is destroyed.
- This relies on behaviour the documentation does not describe for vpn Extensions;
  re-verify it on new system versions.

Result: sixteen processes, nine of them ordinary apps, were killed in a two-minute
window while the Extension stayed up at tier 300. Manual disconnect and reconnect
behave as before. Long-duration and screen-off soak runs are still to be done.
