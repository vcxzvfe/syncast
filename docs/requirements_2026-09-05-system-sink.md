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
重启 coreaudiod（用 `killall coreaudiod`，launchd 会立刻把它拉回来）。

> **2026-09-05 更正**：原来这里用的是
> `launchctl kickstart -k system/com.apple.audio.coreaudiod`，**在本机跑不通**——
> 以 root 身份执行也会被拒：
> `Could not kickstart service: 150: Operation not permitted while System
> Integrity Protection is engaged`。SIP 开着（出厂默认）就不允许 kickstart
> 系统域的 Apple 服务。`killall coreaudiod` 效果完全一样：coreaudiod 归 launchd
> 管，杀掉立刻重启，新起来的那个才会重新扫描 HAL 插件目录。脚本随后会等它回来
> （最多 10 秒），免得调用方一转身就去探测新设备结果跟重启赛跑。

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
- **延迟：预算 ~51 ms（默认 30 ms floor），仍未达到 ≤30 ms 的目标**
  （`swift run SyncCastSystemSinkProbe --latency`，本机实测设备属性 +
  `RingFloorPolicy` 常数，不是声学测量）：

  | 项 | 帧 | 毫秒 | 说明 |
  |---|---|---|---|
  | sink IO buffer | 512 | 10.67 | app 渲染进 sink，tap 隔一个块才看到 |
  | ring floor | 1440 | **30.00** | `LocalOutput` 读取位置落后写指针的量；sink 路径默认值，`SYNCAST_SINK_RING_FLOOR_MS` 可调 10…500 |
  | output IO buffer | 512 | 10.67 | MBP 扬声器 AUHAL 块 |
  | （output hardware） | 798 | 16.62 | 设备自身呈现延迟，任何路径都要付，不算我们加的 |

  **更正（2026-09-05）：之前写的 “~71 ms，其中 50 ms 是
  `Scheduler.plan(safetyMarginMs:)`” 是错的，两半都错。**
  `LocalOutput.render()` 只是把 Scheduler 的 `readBackoffFrames` 拷进状态快照，
  然后**从来没用过**；真正的读取目标是
  `writePosition − ringFloor − 硬件延迟补偿 − block`，而 `ringFloor` 是写死的
  4800 帧（100 ms）。所以这条路径真实代价是 ~121 ms，而且怎么调 Scheduler 都
  不会动这个数。那 100 ms 是当年为 ScreenCaptureKit 的 1024 帧抖动块选的；
  sink 路径的生产者是 Process Tap 的 IOProc，稳定给 512 帧块，所以现在它有自己
  的 30 ms floor，SCK / aggregate 路径维持 100 ms 不变。

  剩下的杠杆：① `SYNCAST_SINK_RING_FLOOR_MS`（拿 dropout 余量换延迟；调低之后
  必须看 app 健康日志里的 `resync` / `underrun` / `minWater` / `idle` 四个计数器，
  并且**只在 `idle` 不涨的那段时间里读前三个**——见 §5.2）；
  ② 让 `SyncCastAudio.driver` 在 `kAudioDevicePropertyLatency` 上申报这条链的
  延迟，视频播放器就会自己补偿、A/V 仍然对齐（未实现）。

  **30 ms floor 还没有做听感验证**（本轮只有算术 + 计数器，没有真机听）。
  **看视频的场景请 supervisor 用耳朵judge一下**：目前 app 以为音频在 sink 的
  呈现时刻出声，我们下游多出来的 ~40 ms 它并不知道，画面会领先声音。

### 代码审查

- **Codex review 第一轮 7 条**（4×P1 + 3×P2）：安装脚本 shell 注入、stale-default
  误伤用户自选的 BlackHole、14.0/14.1 上选了跑不了的路径、tap 启动失败且回滚失败
  时丢掉 sink 所有权、启动失败未回滚采样率、发行版 .app 里装不了驱动、capability
  刷新互相取消。全部已修，并对 ownership claim 与 OS gate 补了单测。
- **Codex review 第二轮 7 条**（3×P1 + 4×P2）：sink 起来了但一个本地输出都没打开
  时静默「running 却没声音」、48 kHz 是异步配置变更却被当同步处理（tap 会拒旧格式）、
  stale-default 清 claim 清得太早（把唯一的恢复证据丢了）、运行中换设备不刷新
  capability（DDC 显示器被永久缓存成软件增益）、唤醒重建无视「用户切走了默认输出」、
  打包不重编驱动会发出旧的、读不到 system output 时臆造了一个快照。全部已修。
- **code-reviewer 深挖：1×CRITICAL + 2×HIGH + 8×MEDIUM + 7×LOW**：
  - **CRITICAL（听力安全）**：master 从 sink 自己的 scalar 播种，而首次激活时它是
    1.0（全新驱动 / 没人动过的 BlackHole），再原样拷到各设备硬件音量——戴着耳机
    在 10% 听歌的人，路径一启动就会被顶到 100%。改成**接管谁就采纳谁的当前音量**
    （否则取即将驱动的输出里最大的那个，再否则什么都不写，绝不编数）。实机验证
    `previousDefault=0.1250 → sinkNow=0.1250`。★播种必须放在**接管之后**：macOS 会
    在某设备成为默认输出的瞬间重新施加它自己记住的音量，先写会被覆盖（实测：写
    0.125 读回 0.4375）。
  - HIGH：coordinator 的 refresh 可能在 teardown 之后把监听器又挂回去，并且把
    `watchedUID` 弄脏，导致下次真正启动被短路——系统音量静默失效直到重启 app。
  - HIGH：`replan()` 的 sink 判据是「配置」，`applySystemSinkVolumes()` 的是「活着」，
    两者不一致时每个输出被钉成 unity 且取消静音，用户的平衡量和静音一起丢。
  - MEDIUM/LOW 里已修：唤醒重建缺 unwind、`stop()` 短路导致别的 owner 不被拆、
    音量事件可能乱序（改成回读 sink 这个权威）、软件增益 pair 未知时静默全音量、
    capability 探测不响应取消、装驱动会在引擎运行时重启 coreaudiod（改为拒绝并提示）、
    驱动没持久化静音、driver 在输入 scope 报了控制、RT 回调里无谓 memset、
    build.sh 没真清、install-driver.sh 的 755 权限、probe 的跨线程读。
  - 未处理（记录在案）：`SystemSinkDevice.deinit` 里调 `stop()` 会在任意线程写默认
    设备——与 `DirectStereoOutput` / `WholeHomeSinkOutput` 既有做法一致，本轮不单独改。

## 5. 已知限制

### 5.1 虚拟设备不能当 sink 路径的输出（2026-09-05 真机实测）

**现象**：唯一勾选的输出是 `ZoomAudioDevice`（用户态 `AudioServerPlugIn`，
transport `virt`），sink 是 BlackHole 2ch。结果：

- `Router.start` **108 秒**才返回；
- 往 sink 放 `afplay` 直接报 `AudioQueueStart -66681`；
- 退出 app **永久卡死**在 `TapCapture.stop()` → `AudioDeviceDestroyIOProcID`
  → `HALC_ProxyIOContext::_TellServerAboutStreamUsage`（发给 coreaudiod 的
  IPC 永远没回音）；
- 事后**全机**所有用户态虚拟设备（BlackHole / Zoom / Teams）都不再有任何 IO
  回调，直到 `sudo killall coreaudiod`。内建扬声器全程正常。

**隔离表**（同一台机器、同一晚）：

| 配置 | 结果 |
|---|---|
| 只把 BlackHole 改采样率（不 tap、不渲染） | 正常 |
| 探针：tap BlackHole + 抢默认输出 | 正常 |
| app：输出 = MacBook Pro 扬声器，sink = BlackHole | 正常（<1 s 启动，tap 有数据，音量法正确）|
| app：输出 = ZoomAudioDevice，sink = BlackHole | **108 s 启动 / 退出卡死 / coreaudiod 废掉** |

**结论**：一边 tap 一个用户态插件设备、一边往另一个用户态插件设备里渲染，会把
两者共用的插件宿主（coreaudiod）锁死。这不是我们能修的；能做的是永远不构造这
个组合。

**处理**：`VirtualOutputPolicy`。
`kAudioDevicePropertyTransportType == kAudioDeviceTransportTypeVirtual` 的设备，
在 `selectedStereoOutputPath == .sink` 时从 `isSelectableInMode` 里隐藏（它本来
也不是喇叭，用户没有任何损失），并且 `Router.startSystemSinkPath` 在**接管任何
东西之前**独立复查一遍，命中就抛错并点名设备——失败发生在没装 sink、没改采样
率、没有默认输出要还的时刻，代价为零。

范围**只限 sink 路径**：Direct Stereo 和 capture 路径不 tap 插件设备，从没出过
这个问题，它们能选的设备一个不减。aggregate（`kAudioDeviceTransportTypeAggregate`）
**不算**虚拟设备——它是内核侧的真实端点组合，Direct Stereo 自己的输出就是一个。

### 5.2 静音不是 glitch（计数器口径，2026-09-05 修）

Process Tap 的 IOProc **只在有进程往 sink 里渲染时才触发**。没人放音的时候
`writePos` 一动不动，而输出 AUHAL 照样按时来取数据——于是每一次 render 都被记成
一次 `underrun` 加一次 `resync`。实测：约 35 秒的 run（其中真正有声音的只有约 4 秒）
报出 `ticks 2808 / resync 2437 / underrun 2436 / minWater 0 ms`。这些数字描述的是
一台闲着的机器，不是一台坏了的机器，而且它们把计数器唯一的用途（判断 30 ms ring
floor 够不够）彻底废掉了。

改法：`RingReadSequencer` 记住上一次 render 时生产者的写指针。写指针没动、并且
已经没有一整块写好的音频可放 → 这一块判为 **producer idle**：直接输出静音、
**不推进读游标**、只记进新的 `idleBlocks` 计数器，`resync` / `underrun` /
`minWater` 一律不动。生产者恢复后的第一块**强制重锚**（把 silence 期间被抽干的
floor 重新建起来），这次重锚同样不计——它是预期行为。

健康行因此多一列：`resync:N underrun:N minWater:X idle:N`。

**遗留盲点，明说**：生产者「卡了整整一个 render」和「本来就没声音」在环形缓冲区
这一侧长得一模一样，所以一次一个 render 以上的停顿会落进 `idleBlocks` 而不是
`underrun`。这正是 `idleBlocks` 要显示出来而不是藏起来的原因——**已知在放音的时段
里 `idle` 却在涨，那才是故障信号**。floor 覆盖得住的短暂停顿（30 ms floor ≈ 2.8 块）
不算 idle：那几块放的是真音频，照常计数。

### 5.3 其它

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
- **延迟比 Direct Stereo 高**（见 §4 的 ~51 ms 预算）。要低延迟看视频，
  `SYNCAST_STEREO_PATH=direct` 仍然可用，代价是回到事件 tap 那套音量方案。
- 单测会在 `~/Library/Preferences` 留下空的 `io.syncast.tests.*.plist`（tearDown
  已清内容，文件壳由 cfprefsd 创建）。这是本仓库既有测试就有的脚印，不是本轮新增
  的行为。

## 6. 没做（明确划界）

- **whole-home 的音量保持原样**（设备选择这条轴见 §7）：它的默认输出是自己的
  「AirPlay 全屋」aggregate（无音量
  控制），主音量在 `AudioSocketWriter` 里、走 OwnTone 的 −30 dB 曲线，跟 sink 的
  scalar 不是一个量纲；`wholeHomeVolumeKeyEligible` 因此保留事件 tap。把它接到同
  一个 sink 观察器上并不便宜（要么让 whole-home 也用可调音量的 sink 当默认输出，
  要么在两条音量曲线之间做映射），本轮不做。
- 自动连接 profile（Track B，`feat/auto-connect` 并行）。
- Sidecar / Python 侧无改动。

---

## 7. BlackHole 可卸载（2026-09-05 补，分支 `fix/wholehome-sink-syncast`）

§6 说的「whole-home 保持原样」只针对**音量**那条轴（whole-home 的主音量仍然在
`AudioSocketWriter` 里走 OwnTone 曲线，没变）。**用哪台静音设备**这条轴改了。

### 7.1 改了什么

`WholeHomeSinkOutput` 原来硬性要求 BlackHole 2ch：「AirPlay 全屋」这个 public
aggregate 的唯一 subdevice 写死成 `BlackHole2ch_UID`，找不到就抛
`blackHoleNotInstalled`。现在它跟 Stereo 的 sink 路径**共用同一份优先级表**
（`SystemSinkDevice.candidates`，不是抄一份）：

| 排名 | UID | 说明 |
|---|---|---|
| 0 | `SyncCastAudio_UID` | SyncCast 自己的驱动，名字显示为 "SyncCast" |
| 1 | `BlackHole2ch_UID` | 兜底，给没装过驱动的机器 |

两个都装 → 用 SyncCast 的；只装一个 → 用那个；一个都没有 → 再按
「名字含 blackhole 且输出恰好 2 声道」扫一遍（应对 16ch 版 / 改过包名的安装），
还是没有才抛新的 `noSilentSinkInstalled`，错误文案同时给出两条安装路径。

aggregate 包装层和「AirPlay 全屋」这个名字**不变**：Sound 菜单里的 "SyncCast"
只说明设备归谁，不说明当前是哪个模式；而且 `sweepOrphans()` 和「被顶掉」横幅都
是认这个 aggregate 的 UID 前缀的。

### 7.2 为什么随便哪台静音设备都行

whole-home 的捕获是 `SCKCapture`（ScreenCaptureKit），**在 HAL 之上**抓系统音频，
从来不打开这台 sink 设备。所以：

- **不需要重采样。** SCK 固定 48 kHz；SyncCast 驱动原生 48 kHz
  （`kDevice_DefaultSampleRate`，另支持 44.1 / 96）；BlackHole 在这台机器上是
  96 kHz。三者互不相干——sink 的标称采样率根本不在信号通路上。
  `inheritsSubdeviceSampleRate = true` 因此保留：强行给 aggregate 设采样率会传染
  给 main subdevice，把一台**共享**设备的采样率替全系统改掉。
- 对比 `SystemSinkDevice.requiredSampleRate = 48000`：那条路径是拿 Process Tap
  去 tap 这台设备本身，格式不是 48 kHz 就直接报错，所以它必须钉住。两条路径的
  差别就在这里，不是随手写的不一致。
- sink 自己的 `VolumeScalar` 衰减同理，够不到 whole-home 的音频。

### 7.3 还原逻辑（重要）

`isRestorableDefault` 原来只按**名字**拒绝裸 BlackHole。现在多一条按 **UID** 拒绝
`SystemSinkDevice.isSinkUID(uid)`——因为 SyncCast 驱动的名字就叫 "SyncCast"，
`blackhole` 这个 needle 永远匹配不上。少了这条，退出 whole-home 时会把一台静音
设备当成「用户原来的默认输出」还回去，全机所有 app 从此没声音，且没有任何提示。

同理，`Router` 里 whole-home 的本地 bridge 目标过滤新增
`SystemSinkDevice.isSinkUID` 一条：名字过滤看不见 "SyncCast"，往里渲染会闭合
`bridge → sink → 静音设备 → SCK → OwnTone → bridge` 这个反馈环。

输出列表侧不用改：`AppModel.isUserSelectableOutput` 早就有
`SystemSinkDevice.isSinkUID` 这一条，`applyRememberedWholeHomeLocalOutputs` 走的是
`isSelectableInMode`，`WholeHomeMemberStore` 只存/回放用户实际启用过的 UID，
不会凭空提供这台设备。

### 7.4 用户操作：卸载 BlackHole

前提：`SyncCastAudio.driver` 已经装好并加载（Sound 菜单里能看到 "SyncCast"）。
本机 2026-09-05 状态：两个驱动都在 `/Library/Audio/Plug-Ins/HAL/`，SyncCast 设备
id = 144。

```bash
# 0) 先确认驱动在位（应输出 SyncCastAudio.driver）
ls -d /Library/Audio/Plug-Ins/HAL/*.driver

# 1) 退出 SyncCast（别在 whole-home 或 Stereo sink 路径运行时拔设备）

# 2) 卸载 BlackHole
sudo rm -rf /Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver && sudo killall coreaudiod
```

`killall coreaudiod` 会让全机音频断一两秒并重新枚举设备，这是正常的。
（用 `brew` 装的话 `brew uninstall --cask blackhole-2ch` 等效，但它同样要 sudo，
而且不会替你重启 coreaudiod。）

卸完检查：

1. `ls -d /Library/Audio/Plug-Ins/HAL/*.driver` → 不再有 `BlackHole2ch.driver`。
2. `( cd core/router && swift run SyncCastSystemSinkProbe )` → sink 应报
   `SyncCastAudio_UID`，路径为 sink。
3. 启动 SyncCast，切到 **whole-home**：System Settings → 声音 的输出应变成
   **「AirPlay 全屋」**；`RouterLog` 里 `whole-home sink active:` 那行应是
   `sub=SyncCastAudio_UID`。
4. 退出 whole-home（或退出 app）：默认输出应回到你原来的喇叭，**不是**
   "SyncCast"。
5. 反悔的话 `brew install --cask blackhole-2ch` 随时装回来，代码里的兜底分支
   没有删。

### 7.5 未验证

whole-home 以 `SyncCastAudio_UID` 作 sink 的**真实播放**（AirPlay 接收端 +
本地喇叭同时出声、无双播、退出后默认输出正确还原）只能人工验证——本轮的自动化
只覆盖到纯逻辑（优先级、错误文案、还原白名单）。
