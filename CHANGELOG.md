# MeshArc changelog

## 未发布

- 优化 VPN 后台长时任务：连接请求时提前申请保护，恢复已有任务，并更新显示实际流量的实况通知。
- 等待有效网络配置后再创建 VPN 接口，记录已应用的子网路由；启动失败或重启时及时释放旧 TUN 句柄。
- 修复 UI 延迟读取 VPN 终止状态时后台任务与“已连接”通知残留的问题，同时防止旧会话的终止记录中断新连接。

## 1.1.0 (100000003) · September 23, 2026

Tailscale OHOS is now MeshArc. The repository retains the name Tailscale-OHOS.

- Added continuous background VPN support and a notification with actual session traffic totals.
- Improved recovery after temporary status failures and system cancellation, while respecting user dismissal.
- Improved connection updates and fixed false disconnect reports from optional service checks.
- Fixed long device-list scrolling, device-detail gestures and release-note panel actions.
- Refined navigation icons, labels and gradient overlays.
- Fixed vendor SDK metadata detection in the build scripts.

Read the [full release notes](docs/releases/1.1.0.md) for feature highlights, compatibility, contributors and validation details.

## 0.9.10 更新记录

- 0.9.10: Peer OS versions now fall back to control-plane Node Hostinfo when the local Status projection is incomplete.
本次更新覆盖从基线版本 0.8.41 到 0.9.9 的全部用户可见变化，以下内容按重要程度排列。

## 主要更新

- 大幅提升 VPN 连接稳定性：改进启动、断开、前后台切换、熄屏及网络重新连接时的状态恢复，减少连接假在线、后台任务丢失和重复操作。
- 完善 Tailsend 文件互传：支持选择设备并发送文件、查看实时进度、取消或重试任务，以及接收后预览、复制或保存文件。
- 新增接收通知快捷操作：文件到达后可直接打开收件箱或保存；同名同大小文件也会被正确区分，不再误触发旧文件操作。
- 完善出口节点与网络设置：支持选择出口节点、允许出口节点访问局域网、路由全部流量，并改进设置变更与 VPN 重连的衔接。

## 设备与首页体验

- 重做 MeshArc 设备首页：设备状态、连接路径、延迟和可用服务更清晰，刷新过程更加稳定，常用操作彼此独立。
- 增加 Sunshine/Moonlight 远程串流入口与媒体服务探测，可在支持的设备上更快发起远程访问。
- 优化设备列表空间利用：根据设备数量自动调整高度，长列表可滚动，同时保留选中项与展开状态。
- 改进直连、对等中继和 DERP 路径展示，并修正延迟信息的显示与刷新。

## 多设备界面

- 全面适配手机、平板和 2in1 等不同窗口宽度；首页、传输和设置页会根据空间自动切换单栏或分栏布局。
- 改进横竖屏、分屏、自由窗口和尺寸变化时的连续性，切换布局后保留当前页面、滚动位置、选中设备和进行中的任务。
- 更新沉浸式导航、安全区处理、浅色/深色主题、磨砂材质、按钮层级和动效，提升信息辨识度与触控体验。

## 安全、隐私与诊断

- 使用非加密 HTTP 自定义控制服务器时新增明确风险确认；HTTPS 配置保持直接使用。
- 加强诊断日志和报告脱敏，减少服务器地址、认证信息、文件路径及其他敏感数据进入日志或分享报告。
- 完善诊断工具：改进引擎、控制面 TLS、VPN 状态和数据路径检查，并支持生成与分享诊断报告。
- 调整可恢复临时文件与缓存管理，降低异常退出后残留文件或错误恢复带来的影响，同时保留旧版本数据兼容性。

## 其他改进

- 优化首次启动、自定义控制服务器设置、账户信息、退出登录和缓存清理流程。
- 修复 Taildrop 文本、图片和视频预览及保存中的多处边缘问题，包括空文本、忙碌状态和重复通知操作。
- 修复窗口监听清理、控制面探测结果过期、VPN 后台任务竞态及多项异常路径问题。
- 重构内部模块边界与异步生命周期管理，提高后续版本的稳定性和可维护性，不改变已有用户数据格式。
