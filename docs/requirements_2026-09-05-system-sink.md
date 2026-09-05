# SyncCast 迭代需求报告（2026-09-05）— 系统音量 / System volume sink

Track A of the 2026-09-05 round. Branch `feat/system-volume-sink`.

## 1. 用户报告的问题

Stereo（本地）模式下，MacBook Pro 扬声器 + ExternalDisplay 显示器扬声器同时出声时，
**macOS 自己的音量 UI 必须能用**：菜单栏滑杆、F11/F12、音量 HUD、LinearMouse
滚轮。今天做不到，原因链条是：

1. Direct Stereo 把一个 public aggregate 设成默认输出；
2. aggregate 没有 `kAudioDevicePropertyVolumeScalar`（2026-09-05 实测：SyncCast
   的 Direct Stereo aggregate 与用户自建的「多输出设备」都是 `has=false`），
   于是 macOS 把音量滑杆置灰、音量键出「禁止」HUD；
3. 为了让音量键还能用，2026-06-12 那一轮加了 `SystemVolumeKeyController`
   （CGEventTap 抢媒体键）。它需要辅助功能权限，会从所有 app 手里抢走这三个键，
   而且 **SyncCast 一运行，LinearMouse 自己的音量 HUD 就坏了**。

用户的要求是把这个 hack 去掉，让系统音量 UI 本身来控制两只喇叭。

## 2. 现场实测（2026-09-05，M5 Pro / macOS 26 / Swift 6.3.3）

探针源码：`core/router/Sources/SyncCastSystemSinkProbe`（入库，可复跑）以及
scratchpad 里的 `dbprobe.swift` / `tapprevol.swift`。

| 事实 | 证据 |
|---|---|
| 虚拟 HAL 设备有音量控制，macOS 就当它是普通可调音量的输出 | SHARED_CONTEXT 已实测（BlackHole / Teams / Zoom 都是 `yes`）|
| **Process Tap 取的是驱动之前的音频**（原始、不受该设备 VolumeScalar 影响）| `tapprevol`：把 1 kHz 正弦送进 BlackHole，sink scalar = 1.0 / 0.5 / 0.0 三次，捕获 RMS 都是 **0.35355**（比值 1.0000）|
| Apple 内建扬声器的音量曲线是 **dB 线性**，范围 `[-63.5, 0] dB` | `dbprobe`：`rangeDb=[-63.50, 0.00]`，`s2db = 0.25→-47.6 / 0.50→-31.8 / 0.75→-15.9 / 1.00→0.0`，与 `-63.5·(1-s)` 完全吻合 |
| BlackHole 的曲线同形，只是底 `-64 dB` | `dbprobe`：`rangeDb=[-64.00, 0.00]`，无 `ScalarToDecibels` 属性；SHARED_CONTEXT 实测 scalar 0.5 → −32 dB |
| 改系统音量会在 sink 上触发 HAL 属性通知 | `--smoke`：`osascript -e 'set volume output volume 40'` → 监听器 `fired=2`，`readback=0.4000` |
| 本机默认输出与**默认系统输出**指向不同设备 | `MacBook Pro扬声器` vs `多输出设备`。两个属性必须分别快照/恢复 |

## 3. 本轮落地：System Sink 路径

```
   App / Spotify / 浏览器
            │  (macOS 默认输出 = 虚拟 sink，有音量控制)
            ▼
   ┌──────────────────────┐        ← 系统音量滑杆 / F11-F12 / HUD /
   │  SyncCast (虚拟声卡)  │           LinearMouse 直接调这里
   │  或 BlackHole 2ch     │        VolumeScalar = 主音量（纯意图，不缩放数据）
   └───────┬──────────────┘
           │ Process Tap（pin 到 sink，取驱动前的原始信号）
           ▼
   RingBuffer → 私有 aggregate + 一个 AUHAL
           │
     ┌─────┴─────┐
     ▼           ▼
  MBP 扬声器   ExternalDisplay
 （硬件音量）  （DDC/CI 0x62）
```

### core/router

- **`SystemSinkDevice.swift`**：检测 sink（优先自家 `SyncCastAudio_UID`，回退
  `BlackHole2ch_UID`），把它同时设成 `kAudioHardwarePropertyDefaultOutputDevice`
  与 `kAudioHardwarePropertyDefaultSystemOutputDevice`，把采样率钉到 48 kHz
  （`TapCapture` 不重采样，宁可报错），stop 时两个属性 + 采样率全部还原。
  接管默认输出时会写一条 **ownership claim**（pid + sink uid，存 UserDefaults），
  干净停止时清除；只有「claim 的进程已经死了」才授权下次启动去动默认输出——
  BlackHole 是共享设备，用户完全可能自己把它选成默认来录音，SyncCast 光是启动
  不许碰它（Codex R1-P1，已补 7 条单测，含这个误伤场景）。
  还原状态机 `restoreAction` 是纯函数（4 个分支全部有单测）：
  仍是我们的默认 → 还原快照；没有可用快照 → 退到任意普通输出（绝不把默认留在
  静音 sink 上）；**用户自己切走了 → 不抢回来**；当前默认读不出来 → 报失败，
  阻止退出并告诉用户。另有 `sweepStaleDefault`，专治上一次被 SIGKILL 后默认输出
  卡在静音 sink（表现为「界面一切正常，就是没声音」）。
- **`SystemSinkVolumeLaw.swift`**：把 sink 的 scalar 翻译成每个输出的实际动作。
  - CoreAudio 硬件音量（MBP 扬声器）→ **原样拷贝 scalar**。目标设备自己的曲线
    和 sink 的曲线是同一条，所以 1:1 拷贝就等于原生响度；在这里先转成振幅再写
    过去会 taper 两次，正是「BlackHole 回环听起来小得离谱」的成因。
  - DDC/CI 显示器 → VCP 0x62 百分比 = `scalar × 100`。
  - 其它 → 软件增益，**必须**过 dB 曲线：`a = 10^(dB(s)/20)`，`scalar 0` 直接给
    真零（系统音量归零还有声音会被当成 bug；这是它与 `VolumeCurve` 那条 −30 dB
    地板的 OwnTone 曲线的唯一区别）。
  - 每设备滑杆变成**平衡量**，在 dB 域叠加：`dB_eff = dB(master) + dB(balance)`，
    balance = 1.0 时精确等于 master，硬件路径依然是「原样拷贝」。
- **`TapCapture`**：新增 `tapDeviceUID`，即 `CATapDescription.deviceUID`。全局 tap
  会把我们自己送去真喇叭的音频也录进来（反馈环），所以必须 pin。
- **`Router`**：sink 路径的 start / stop / 唤醒重建；`activeCapture` 让本地输出
  从 pin 住的 tap 读环形缓冲；`applySystemSinkVolumes()` 做硬件 → DDC → 软件增益
  的逐级降级（同一次 replan 内完成，用户不会看到「滑杆动了但没反应」）；
  `systemSinkStatus()` / `systemSinkVolumeCapabilities()` / `setSystemSinkMaster`；
  诊断串新增 `driver=systemSink(n)`、`systemSink=active … master=…`；路由过滤器
  保证 sink 永远不会被当成播放目标。
- **`StereoOutputPathPolicy`**：新增 `.sink`，**装了 sink 且 macOS ≥ 14.2 才默认
  走它**（capture 腿是 Process Tap，包的部署目标却是 14.0；14.0/14.1 上装了
  BlackHole 会让每次 Stereo 启动直接抛错——Codex R1-P1）；
  `SYNCAST_STEREO_PATH=direct` 仍然强制旧路径，`sink` 但没装设备时降级到
  direct 并告警（绝不静默改语义）。

### apps/menubar

- **`SystemSinkCoordinator`**（`AppModel+SystemSink.swift`）：在 sink 上挂
  CoreAudio 属性监听（复用 `HardwareVolumeObserver`，去抖缩到 20 ms，否则按住
  F12 时喇叭会明显落后于 HUD），把每次 scalar/mute 变化推给 Router。
  **我们从不写 sink 自己的音量**（只有 macOS 写），所以这条链天生没有自写回声，
  不需要抑制窗。
- 事件 tap 自然退场：`directStereoVolumeKeyEligible` 本来就要求
  `path == .direct`，sink 路径不满足，一行都不用改。whole-home 保持原样（见 §6）。
- popover 增加一行状态：当前系统音量由哪台设备承载 / 被用户切走了 / 已暂停；
  以及「安装 SyncCast 音频驱动」按钮（走 `osascript … with administrator
  privileges`，密码由 macOS 自己收，SyncCast 看不到）。命令用 AppleScript
  字面量转义 + `quoted form of` 双层引用——只转义双引号的话，路径里带
  `$(...)`/反引号就会以 root 执行（Codex R1-P1）。`package-app.sh` 把编译好的
  driver 和 `install-driver.sh` 一起塞进 `Contents/Resources`，脚本发现同级有
  driver 就直接装它，所以发行版 .app 里这个按钮真的能用（Codex R1-P2）。
- 用户在「声音」里把输出切走 = **意图**：停止路由、什么都不还原（他们已经自己
  改了）、popover 说明情况并给「继续」按钮。绝不定时抢回默认输出。

### drivers/SyncCastAudio（自家虚拟声卡）

用户态 AudioServerPlugIn（脱胎自 Apple NullAudio）：只有输出流（没有输入流 →
不碰麦克风类 TCC）、2 ch、48 kHz 默认（另报 44.1 / 96）、名字 "SyncCast"、
UID `SyncCastAudio_UID`、带音量 + 静音控制、**不缩放音频数据**（数据本来就丢弃）。
音量曲线照抄上面实测的 `[-63.5, 0] dB` dB 线性，所以滑杆手感和内建喇叭一致。
`build.sh` 出 universal + ad-hoc（或 `SYNCAST_USE_SYNCCAST_DEV=1` 用 "SyncCast Dev"）
签名的 bundle；`scripts/install-driver.sh` 装到 `/Library/Audio/Plug-Ins/HAL` 并
`launchctl kickstart -k system/com.apple.audio.coreaudiod`。

## 4. 验证

### 已在真机验证

- `swift build` + `swift test`：`core/router` 139 tests / 0 failures，
  `apps/menubar` 138 tests / 0 failures（新增 45 条：sink 检测与优先级、音量法
  映射、还原状态机、路径选择、ownership claim）。
- `SyncCastSystemSinkProbe --smoke`（BlackHole 作 sink）→ **PASS**：
  - pin 到 sink 的 tap 捕到 `written=240 maxPeak=0.2297`（信号来自**另一个进程**
    的 afplay；因为 sink 丢弃音频，全程听不到）；
  - `osascript -e 'set volume output volume 40'` → 监听器 `fired=2`、
    `readback=0.4000`；
  - 默认输出、默认系统输出、sink 自身音量三者全部还原（本机这两个默认属性指向
    不同设备，正好覆盖了「只处理一个属性就会弄坏另一个」的情况）。
- Process Tap 取驱动前音频：见 §2 表格（比值 1.0000 / 1.0000）。
- 驱动静态检查：`clang -Werror` 编译通过、`plutil -lint` OK、
  `nm -gU` 确认 `_SyncCastAudio_Create` 已导出、`codesign --verify --strict` 通过、
  `otool -L` 只链 CoreFoundation / CoreAudio / libSystem、universal (x86_64 arm64)。

### 尚未验证（需要用户操作）

- **驱动装载**：装 `/Library/Audio/Plug-Ins/HAL` 需要 sudo，本环境没有。
  装完请跑 `swift run SyncCastSystemSinkProbe`，应看到
  `sink : SyncCast (SyncCastAudio_UID, rank 0)` 且 `volume control : yes`。
  在此之前 BlackHole 回退路径已经完全可用（上面的 PASS 就是走它跑的）。
- 完整听感链路（真的从两只喇叭出声 + 拖系统滑杆）：需要在真机上跑 app 本体，
  由 supervisor 做。
- 延迟：设计上是 tap → RingBuffer → AUHAL，与既有 SCK 采集路径同构（现有
  `Scheduler` 按 12 ms 记本地输出），预算目标 ≤30 ms；**本轮没有实测数字**，
  不写没测过的数。

### 代码审查

- Codex review（SOP 第一道闸）第一轮 7 条：4×P1（安装脚本 shell 注入、
  stale-default 误伤用户自选的 BlackHole、14.0/14.1 上选了跑不了的路径、
  tap 启动失败且回滚失败时丢掉 sink 所有权导致无人重试）+ 3×P2（启动失败未回滚
  采样率、发行版 .app 里装不了驱动、capability 刷新互相取消导致每行提示空白）。
  全部已修，并对 ownership claim 与 OS gate 补了单测。

## 5. 已知限制

- 路径在**每次启动时解析一次**（`SystemSinkDevice.resolved`）。装完驱动要重启
  SyncCast——反正装驱动会重启 coreaudiod，音频本来就断一下。
- sink 一旦成为默认输出，「声音」菜单里显示的就是 "SyncCast"（或 "BlackHole 2ch"）
  而不是「MacBook Pro扬声器」。这是设计的一部分，popover 那行状态就是为了说清楚。
- 用户用显示器 OSD 或 Audio MIDI Setup 单独改某个下游设备的音量时，我们不监听
  它，下一次 replan 会覆盖回去。系统滑杆是唯一的音量真相来源（这是防反馈环的
  设计选择，不是疏忽）。
- sink 被钉到 48 kHz；停止时还原原采样率。若无法设置 48 kHz，tap 会因格式不符
  报错——宁可响亮失败，也不静默重采样。
- DDC 写是异步的（几十 ms 落地），且显示器 OSD 的改动不会反向同步（DDC 没有变更
  通知）。与 2026-06-12 那轮的限制相同。
- macOS < 14.2 没有 Process Tap，sink 路径整体不可用，自动回落到 Direct Stereo。
- 单测会在 `~/Library/Preferences` 留下空的 `io.syncast.tests.*.plist`（tearDown
  已清内容，文件壳由 cfprefsd 创建）。这是本仓库既有测试就有的脚印，不是本轮新增
  的行为。

## 6. 没做（明确划界）

- **whole-home 保持原样**：它的默认输出是自己的「AirPlay 全屋」aggregate（无音量
  控制），主音量在 `AudioSocketWriter` 里、走 OwnTone 的 −30 dB 曲线，跟 sink 的
  scalar 不是一个量纲；`wholeHomeVolumeKeyEligible` 因此保留事件 tap。把它接到同
  一个 sink 观察器上并不便宜（要么让 whole-home 也用可调音量的 sink 当默认输出，
  要么在两条音量曲线之间做映射），本轮不做。
- 自动连接 profile（Track B，`feat/auto-connect` 并行）。
- Sidecar / Python 侧无改动。
