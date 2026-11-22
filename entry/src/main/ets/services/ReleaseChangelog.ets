/**
 * Release changelog editor
 *
 * 每次准备发布时只编辑本文件：
 * 1. 把最新版本放在 RELEASE_CHANGELOG_ENTRIES 的第一项；
 * 2. 让 versionName/versionCode 与 AppScope/app.json5 完全一致；
 * 3. 填写至少一条中英文更新内容和发布日期；
 * 4. 旧版本按时间顺序保留在后面。
 *
 * Release 构建会校验第一项，内容为空或版本不一致时会直接失败。
 */
export interface ReleaseChangelogDefinition {
  versionName: string;
  versionCode: number;
  releaseDateZh: string;
  releaseDateEn: string;
  changesZh: string[];
  changesEn: string[];
}

export const RELEASE_CHANGELOG_ENTRIES: ReleaseChangelogDefinition[] = [
  {
    versionName: '2.0.0',
    versionCode: 200000000,
    releaseDateZh: '2026年11月22日',
    releaseDateEn: 'November 22, 2026',
    changesZh: [
      '升级 Tailscale 内核至上游最新，修复安全问题',
      '新增“连接优化”入口，优化连接、后台恢复和重连稳定性',
      '加入 MagicDNS 和自定义 DNS 支持',
      '改进部分功能交互',
      '优化大文件取消传输响应与后台连接恢复稳定性'
    ],
    changesEn: [
      'Upgraded the Tailscale engine to the latest upstream release and fixed security issues',
      'Added a Connection optimization entry and improved connection, background recovery and reconnection stability',
      'Added MagicDNS and custom DNS support',
      'Refined interactions across several features',
      'Improved large-transfer cancellation responsiveness and background connection recovery stability'
    ]
  },
  {
    versionName: '1.1.6',
    versionCode: 100000016,
    releaseDateZh: '2026年11月1日',
    releaseDateEn: 'November 1, 2026',
    changesZh: [
      '紧急修复上个版本导致的异常闪退问题\n亲爱的用户，很抱歉上个版本的bug给你们带来许多不便。本人为学生开发者，近期忙于期中考，故在前段时间疏于更新，望各位谅解。非常感谢。'
    ],
    changesEn: [
      'Urgent fix for unexpected crashes introduced in the previous version\nDear users, I am sorry for the inconvenience caused by bugs in the previous version. I am a student developer and have recently been busy with midterm exams, which has kept me from updating the app as regularly as I should. Thank you very much for your understanding.'
    ]
  },
  {
    versionName: '1.1.5',
    versionCode: 100000015,
    releaseDateZh: '2026年10月20日',
    releaseDateEn: 'October 20, 2026',
    changesZh: [
      '优化应用稳定性，尝试解决偶发闪退',
      '支持从相册、文件管理等应用分享文件到其他设备',
      '支持点击保存收到的图片和视频到相册',
      '支持通过系统文件选择器保存收到的其他文件',
      '修复未连接时分享设备界面持续闪动的问题'
    ],
    changesEn: [
      'Improved app stability to address occasional crashes',
      'Share files from Gallery, Files and other apps to other devices',
      'Save received images and videos to the gallery with a tap',
      'Save other received files using the system file picker',
      'Fixed continuous flickering of the share device screen while disconnected'
    ]
  },
  {
    versionName: '1.1.1',
    versionCode: 100000005,
    releaseDateZh: '2026年10月15日',
    releaseDateEn: 'October 15, 2026',
    changesZh: [
      '优化文件页操作布局与原生系统材质，调整排序、视图切换和多选操作入口；本版本需要 HarmonyOS API 26 或更高版本',
      '补充连接、文件传输、共享目录、子网、出口节点及媒体功能的配置说明与帮助入口',
      '改进后台任务、网络恢复与 VPN 生命周期诊断，保留脱敏错误码和异常上下文，减少周期探测日志对关键事件的覆盖',
      '修复传输帮助按钮的系统图标资源引用，确保应用正常编译'
    ],
    changesEn: [
      'Refined file-page controls and native system materials, including sorting, view switching and selection actions; this version requires HarmonyOS API 26 or later',
      'Added setup instructions and help entry points for connections, file transfers, shared folders, subnets, exit nodes and media services',
      'Improved background-task, network-recovery and VPN lifecycle diagnostics with redacted error codes and failure context, preserving key events amid periodic probes',
      'Fixed the system icon resource used by the transfer help button so the app compiles successfully'
    ]
  },
  {
    versionName: '1.1.0',
    versionCode: 100000003,
    releaseDateZh: '2026年9月23日',
    releaseDateEn: 'September 23, 2026',
    changesZh: [
      '新增 VPN 连接后的持续后台任务与流量通知，显示本次连接的真实上传和下载总量',
      '改进后台连接恢复：短暂状态读取异常不再立即停止保护任务；系统取消后延迟重试，用户主动关闭后尊重其选择',
      '优化连接状态更新，避免设备探测阻塞心跳，减少可选服务查询失败导致的错误断开提示',
      '修复主页设备列表过长时无法滚动到底的问题，优化设备详情半模态滚动与底部导航手势',
      '修复更新日志面板关闭及显示偏好操作，并优化底部导航的图标、文字和渐变遮罩'
    ],
    changesEn: [
      'Added a continuous background task and VPN traffic notification showing real upload and download totals for the current connection',
      'Improved background recovery: tolerate brief status-read failures, back off retries after system cancellation, and respect explicit user dismissal',
      'Start connection heartbeats before peer probes and avoid false disconnect reports when optional service snapshots fail',
      'Fixed scrolling to the end of long Home device lists and refined device-detail sheet scrolling and bottom-navigation gestures',
      'Fixed release-note dismissal and display-preference actions, and refined bottom-navigation icons, labels and gradient masking'
    ]
  },
  {
    versionName: '1.0.1',
    versionCode: 100000002,
    releaseDateZh: '2026年8月25日',
    releaseDateEn: 'August 25, 2026',
    changesZh: [
      '修复主页设备列表过长时无法滚动到底的问题'
    ],
    changesEn: [
      'Fixed an issue that prevented the Home device list from scrolling to the bottom when it was long'
    ]
  },
  {
    versionName: '1.0.0',
    versionCode: 100000000,
    releaseDateZh: '2026年8月19日',
    releaseDateEn: 'August 19, 2026',
    changesZh: [
      '合作联动：MeshArc设备卡片→媒体→点击跳转到HosPlayer；需在远程媒体服务器上安装并配置Tailscale',
      '新增应用锁：每次应用返回前台时通过系统身份验证解锁，支持设备已启用的人脸、指纹或 PIN；仅保存开关策略，不保存任何身份凭据或认证令牌',
      '新增文件夹锁：可在 Taildrive 中锁定指定远程文件夹及其全部子内容，访问受保护目录和调整锁定规则时均需系统身份验证；重命名、移动或删除文件夹后会同步更新锁定规则',
      '新增安全设置与诊断：集中查看应用锁、文件夹锁和受保护文件夹数量，并可运行不修改设置的系统身份验证自检',
      '优化设置界面：保留账户卡片，按网络、外观、存储、关于和安全分类进入二级页面；统一页面标题、材质和连续滚动的半模态交互',
      '优化外观与动效：支持背景图片、沉浸色彩和材质效果；动画预设、时长、幅度与阻尼可预览并自动保存到本地偏好',
      '优化存储与更新日志：新增本地数据、已接收文件和临时缓存的环形占用统计；更新日志支持按版本横向浏览，最新合作图展示在详细内容顶部',
      '更新 HosPlayer 服务器导入链接，并修复连接、传输和媒体联动中的若干边界问题'
    ],
    changesEn: [
      'Partnership integration: MeshArc device card → Media → tap to open HosPlayer; install and configure Tailscale on the remote media server',
      'Added App Lock: each return to the foreground requires system authentication using enrolled face, fingerprint, or PIN; only the lock policy is stored, never credentials or authentication tokens',
      'Added Folder Lock: protect a selected Taildrive remote folder and all of its contents; opening protected folders or changing their lock policy requires system authentication, and lock rules follow folder rename, move, and delete operations',
      'Added Security settings and diagnostics: view App Lock, Folder Lock, and protected-folder counts together, then run a system-authentication self-test without changing settings',
      'Polished Settings: retain the account card and organize Network, Appearance, Storage, About, and Security into second-level pages with consistent titles, material, and continuously scrolling bottom sheets',
      'Polished appearance and motion: choose a background image, immersive color, and material effects, then preview and persist animation presets, duration, amplitude, and damping',
      'Polished storage and release notes: added a ring summary for app data, received files, and temporary cache; release notes now browse by version horizontally and show the latest partnership image above the details',
      'Updated the HosPlayer server import handoff and fixed several connection, transfer, and media integration edge cases'
    ]
  },
  {
    versionName: '0.9.10',
    versionCode: 99000002,
    releaseDateZh: '2026年8月3日',
    releaseDateEn: 'August 3, 2026',
    changesZh: [
      '完善 MeshSend 文件传输流程',
      '优化响应式首页布局',
      '增加 VPN 与媒体联动诊断'
    ],
    changesEn: [
      'Expanded the MeshSend file transfer flow',
      'Polished the responsive home layout',
      'Added VPN and media integration diagnostics'
    ]
  },
  {
    versionName: '0.9.8',
    versionCode: 9800000,
    releaseDateZh: '2026年7月29日',
    releaseDateEn: 'July 29, 2026',
    changesZh: [
      '完成 Taildrop 收发文件流程',
      '增加媒体服务发现',
      '改进 VPN 启动与恢复'
    ],
    changesEn: [
      'Completed the Taildrop send and receive flow',
      'Added media service discovery',
      'Improved VPN startup and recovery'
    ]
  }
];
