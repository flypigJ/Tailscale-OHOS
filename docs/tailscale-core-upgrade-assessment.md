# Tailscale 内核更新可行性评估

评估日期：2026-09-23。范围为本项目嵌入的 Tailscale Go 用户态引擎、WireGuard/gVisor 依赖和鸿蒙适配层，不涉及修改 HarmonyOS 系统内核。

> 历史评估：版本、分支和工作区状态均以评估日期为准，不代表最新上游状态。下述补丁记录缺失问题已在 [PR #11](https://github.com/flypigJ/Tailscale-OHOS/pull/11) 中修复；开始升级前仍需重新核对现有补丁与目标版本。

结论：技术上可行，建议推进独立的工具链验证 Milestone；现有环境不能直接升级到最新稳定版。主要障碍是 Go 1.26 的 OpenHarmony 移植，而不是 ArkTS UI。当前证据属于源码和构建配置评估，尚未证明新版可编译或在真机运行。

## 1. 已核实的版本和构建链

| 项目 | 当前状态 | 更新目标或要求 |
| --- | --- | --- |
| Tailscale | v1.86.5，提交 `db392aed39630023f969e1961fcbced785d09358` | 本次查询最新稳定版 v1.102.4，提交 `bbcd7d1fc2054b9189ebc1531acf74bd880ca0c8` |
| Go 模块最低版本 | `go 1.24.4` | v1.102.4 要求 `go 1.26.6` |
| 实际编译工具链 | OpenHarmony SIG Go 1.24.5，提交 `2d8b23f6923100d8c90d8add9299da2c9d032a20` | 需要支持 `openharmony/arm64`、CGO、`c-shared` 的 Go 1.26.6 或更高兼容版本 |
| 当前共享库 | `go version -m entry/libs/arm64-v8a/libtailscale_go.so` 确认 Go 1.24.5、Tailscale v1.86.5、GOOS=openharmony、GOARCH=arm64 | 必须重新交叉编译，不能替换成上游 Linux/Android 客户端二进制 |
| Go 依赖选择 | `native/go_bridge/go.mod` 使用本地 `replace` 指向 `third_party/tailscale` | 单独修改 `require` 或运行 `go get` 不会替换本地内核源码 |

当前调用关系：ArkTS / VpnExtensionAbility → C++ Node-API → Go C ABI → tsnet / Tailscale 引擎 → 鸿蒙提供的 TUN 文件描述符。这个边界允许保留 UI、路由参数、桥接协议和持久化接口，在 Go 层完成主要迁移。

来源：[当前模块](../native/go_bridge/go.mod)、[构建脚本](../scripts/build-go.ps1)、[上游稳定版](https://github.com/tailscale/tailscale/releases/tag/v1.102.4)、[目标 go.mod](https://github.com/tailscale/tailscale/blob/v1.102.4/go.mod)。

## 2. 主要阻碍：Go 1.26 分支尚无鸿蒙适配

读取 OpenHarmony SIG 仓库远端分支后，在独立临时目录检出了以下源码用于比对：

- `release-branch.go1.26`：提交 `3cc00d9c2b8ac231a5432ececa784814cc1eb075`，VERSION 为 Go 1.26.7。
- 该提交的 `src/internal/syslist/syslist.go` 未注册 `openharmony`；`src/internal/platform/supported.go` 未支持 `openharmony/arm64`；源码树没有现有端口的 `zgoos_openharmony.go`、`rt0_openharmony_arm64.s`、`interface_table_openharmony.go` 等文件。
- 本次检查的 dist、Go 命令、runtime、net、平台注册目录也未找到 OpenHarmony 适配引用。因此，分支名称存在不等于已经有可用的鸿蒙 Go 1.26 工具链。
- 同仓库的 `release-branch.go1.24` 仍为 Go 1.24.5，并包含 OpenHarmony 平台文件；master 为 Go 1.22.10。
- 当前 Go 1.24 端口在排除 vendor 后有 91 个源码/测试文件引用 OpenHarmony。这个数字不是必须迁移的文件数，但表明适配跨越构建识别、CGO、链接、runtime、网络接口和标准库，不能只复制几个新增文件。
- 本项目还依赖非标准符号 `runtime.IsOpenharmony`，并带有网络接口枚举时释放 `getifaddrs` 内存和关闭 socket 的补丁。迁移需保留这些行为或提供等价实现。

需要验证的底层能力包括：arm64 共享库初始化、线程/TLS、CGO 调用、信号和 GC、文件描述符关闭/唤醒、DNS/系统证书、网卡枚举、休眠恢复。标准 Go 自动下载工具链不会自动获得鸿蒙端口；把 `go.mod` 的最低版本强改为 1.24 也不能解决新标准库、语言特性和依赖要求。

来源：[SIG Go 仓库](https://gitcode.com/openharmony-sig/ohos_golang_go)、[固定 Go 1.26 提交](https://gitcode.com/openharmony-sig/ohos_golang_go/commit/3cc00d9c2b8ac231a5432ececa784814cc1eb075)、[本项目资源释放补丁](../patches/ohos-go-interface-resources.patch)、[Go 桥接入口](../native/go_bridge/main.go)。远端核查结果仅代表评估日期和上述提交。

## 3. 新版有利于减少定制补丁

v1.102.4 源码已包含下列能力：

| 当前定制点 | 新版情况 | 迁移建议 |
| --- | --- | --- |
| `tsnet.Server.Tun` 接收外部 TUN | 已有上游字段，并传入 userspace engine | 优先采用上游实现 |
| 外部 TUN 与应用内部 netstack 的收包分流 | 上游启用 `CheckLocalTransportEndpoints`，按 gVisor 已注册连接/监听端点分流 | 有望替代本地 56000–60999 端口跟踪方案；须验证其他应用 VPN 流量与应用内 Taildrop/Taildrive 同时工作 |
| Taildrop 发送进度合并 | 已有并发安全的 `outgoingProgress` 合并和结束通知机制 | 按行为比对后移除重复补丁，保留完成/失败/取消回归 |
| tsnet 内置 Taildrive WebDAV | 仍有未实现的 TODO，没有本项目的 `TaildriveHTTPClient()` | 继续迁移进程内文件系统接入和生命周期处理 |
| PeerStatus 设备型号/系统版本 | 目标 PeerStatus 未包含本地扩展字段 | 保留等价数据来源和现有 JSON 协议 |
| Taildrop 收件时间 `ReceivedAtMs` | 目标 WaitingFile 未包含该字段 | 迁移扩展，维持收件箱排序和显示 |

这是源码层面的兼容性判断，不表示上游的新分流行为已经通过鸿蒙真机验证。当前 `UseNetstackForPeerDial` 也不能直接保留在新版 Server 初始化中，需要随上游机制调整。

来源：[新版 tsnet](https://github.com/tailscale/tailscale/blob/v1.102.4/tsnet/tsnet.go)、[新版 netstack](https://github.com/tailscale/tailscale/blob/v1.102.4/wgengine/netstack/netstack.go)、[新版 Taildrop](https://github.com/tailscale/tailscale/blob/v1.102.4/feature/taildrop/localapi.go)、[现有补丁](../patches/tailscale-ohos.patch)。

## 4. 已确认的迁移问题

1. **现有补丁无法直接套用。** 在临时 v1.102.4 源码上执行 `git apply --check --ignore-space-change --ignore-whitespace`，`feature/taildrop/localapi.go`、`ipn/ipnlocal/local.go`、`tsnet/tsnet.go`、`wgengine/netstack/netstack_test.go` 报不匹配。仅作检查，未应用补丁。应逐项重建最小补丁，避免把上游已实现的逻辑重复加回。
2. **评估时补丁记录不完整，后续已修复。** 评估时 vendor 实际修改 8 个文件，296 行新增、43 行删除；受版本控制的补丁仅覆盖 6 个文件，缺少 `client/tailscale/apitype/apitype.go` 和 `feature/taildrop/retrieve.go` 的收件时间扩展。后续 PR #11 将这两个文件纳入补丁。升级前仍须以合并后的补丁重新固定完整基线。
3. **内部 API 已变更。** 例如当前引擎探针调用 `sys.HealthTracker()`，新版是 `sys.HealthTracker.Get()`。需要针对桥接实际导入的包编译检查，不能只检查 C ABI 不变。
4. **依赖也会更新。** WireGuard Go 从 `1d0488a3d7da` 更新至 `2e01ba5b00f0`，gVisor 从 `9414b50a5633` 更新至 `573d5e7127a8`，`x/sys` 从 v0.33.0 更新至 v0.47.0。TUN 的包边界、阻塞读写、关闭、批处理假设均需回归。
5. **版本检查有硬编码。** `scripts/build-go.ps1` 将 1.86.5 写入 linker stamps；engine/backend 探针期望 Go 1.24.5 和 Tailscale 1.86.5。更新源码后必须同步版本来源及探针，防止出现版本标记与实际二进制不一致。
6. **数据迁移与回退尚未验证。** 保留 `tailscaled.state` 路径、控制服务器隔离目录和应用设置格式；在测试数据副本上验证旧状态加载和新版写回。不能承诺旧二进制可以读取新版写过的状态，回退必须保存配套的升级前状态，且不得并发启动同一节点身份。

## 5. 平台边界与更新收益

华为 Knowledge MCP 已按 `searchDocuments` → `getDocumentsById` 核查 VPN 文档。三方 VPN 提供虚拟网卡和路由配置，隧道协议由应用实现；VpnExtensionAbility 从 API 11 起提供，适用 Stage 模型，使用 VPN 网络需要 `ohos.permission.INTERNET`。API 22 起支持首次启动时传递 Want parameters。

本项目文档/示例基线为 SDK 23，设备声明包含 phone、tablet、2in1；上述接口版本满足基线，具体设备仍须具有相应系统能力。升级 Go 内核本身没有证据表明必须提高应用 SDK 基线或新增权限。评估时构建脚本尚有未提交的 SDK 选择改动；实施时仍应固定 SDK 条件，避免同时引入平台升级变量。

继续保持鸿蒙拥有 TUN/路由、应用自身连接绕过 VPN、控制/DERP 走物理网络的行为。当前 `netns.SetEnabled(false)` 和 VPN 配置的应用绕行逻辑不能因升级被 Linux 默认逻辑覆盖。

新版值得更新的收益包括：上游外部 TUN 支持减少长期维护成本，以及近期连接恢复、握手内存泄漏、重新认证邻近 netmap 更新时断连等修复。收益需要在本项目路径上验证，不能把 Linux GSO、桌面 UI 等更新直接视为鸿蒙收益。

安全修复也应按启用功能判断适用性。例如 TS-2026-011 针对发布 4via6 路由的子网路由器，不能仅因客户端接收子网路由，就认定此鸿蒙客户端已暴露同样问题。本次没有执行完整漏洞审计。

来源：[VPN 官方指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/net-vpnextension)、[VPN API](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-net-vpnextension)、[上游更新日志](https://tailscale.com/changelog)、[安全公告](https://tailscale.com/security-bulletins#ts-2026-011)。

## 6. 实施建议：一次一个 Milestone

| 阶段 | 范围 | 通过条件 |
| --- | --- | --- |
| M1：工具链可行性 | 固定完整旧版补丁和工具链提交；在独立目录迁移 Go 1.26 鸿蒙支持，构建最小 arm64 CGO 共享库；再用旧内核作对照 | 真机加载共享库，C/Go 调用、DNS/TLS、网卡枚举、线程/GC、关闭行为正常；旧内核关键路径不回退 |
| M2：内核迁移 | 固定 Tailscale v1.102.4 和依赖；采用上游 TUN/分流/进度实现；迁移 Taildrive、设备元数据、收件时间；调整内部 API 和版本标记 | Go/桥接编译通过；相关单元测试通过；生成头文件、导出符号和 JSON 契约与原接口兼容 |
| M3：真机兼容回归 | 按既有签名/HDC 流程交付测试构建 | 登录状态继承、VPN 实际数据、路由、出口节点、应用内传输、后台稳定性通过；明确状态回退方案 |

M1 建议先安排 1–3 个工程日作探索时间窗，到点按证据决定继续移植或暂缓；这不是承诺完整工具链可在该时间内完成。完整升级粗估 2–4 个工程周，最大不确定性在 Go runtime/CGO；发生底层问题时需重新估时。若已有可复用且经真机验证的 Go 1.26 鸿蒙端口，工作量会明显降低。

不建议把 v1.88.4 作为最终升级目标：它已经要求 Go 1.25.1，仍需解决工具链问题，却不能获得最新版本的完整收益。若 M1 无法通过，可暂留 1.86.5，只回移经确认适用的少量修复；不建议将整个新版强行降级到 Go 1.24。

M3 最小验收范围：

- 旧登录状态、控制服务器、出口节点选择、子网/LAN 设置和传输记录保留；不强制重新登录。
- 普通 peer 直连、DERP 回退、IPv4/IPv6、出口节点和子网的真实流量；不仅检查 Running 状态。
- 系统浏览器 VPN 流量与应用内 Taildrop/Taildrive/媒体探测同时工作。
- Taildrop 双向传输、进度、取消、失败/重试、收件时间和排序；Taildrive 列目录、上传/下载及关闭恢复。
- 反复连接/断开、Wi-Fi/移动网络切换、锁屏和唤醒；在当前 USB 供电后台探针基础上补充电池供电待机及资源趋势。
- 进程重建和重启后恢复既有行为，监测文件描述符、内存、goroutine 及空闲耗电。
- 普通测试按项目规则不执行全量截图审查。Release 仍需用户选择审查，并明确确认 ReleaseChangelog 完整后才能编译/签名/发布。

## 7. 本次评估操作边界

已完成本地源码、二进制版本元数据、官方远端分支和目标源码核查，以及临时目录内的补丁适用性检查。未编译新工具链或应用，未安装、签名、发布、改变应用版本或修改业务代码。仅新增本文档，原工作区未提交改动和原 vendor/toolchain 工作树保持原样。
