# SyncCast 迭代需求报告（2026-06-12）

## 1. 用户报告的问题

Stereo（Direct Stereo）模式下：

1. 显示器扬声器（ExternalDisplay，DisplayPort 音频）完全无法调节音量。
2. 本地扬声器 + MacBook Pro 扬声器组合的音量调节体验异常。

## 2. 现场诊断结论（2026-06-12，M5 Pro / macOS 26.5.1）

三个根因，全部有实测证据：

- **媒体音量键事件从未送达 app**。`~/Library/Logs/SyncCast/launch.log` 自 2026-05-19
  起只有每次启动一条 `systemVolumeKey: monitor installed`，零条按键动作日志。
  `NSEvent.addGlobalMonitorForEvents` 对按键类事件（含 systemDefined 媒体键）需要
  辅助功能（Accessibility）授权；app 从未申请。local monitor 只在 app 前台时有效，
  菜单栏 LSUIElement app 几乎从不前台。2026-05-19 的媒体键功能从上线起就没有工作过。
- **ExternalDisplay 没有可写的 CoreAudio 硬件音量/静音**（与 2026-05-19 探测一致），
  当时实现对它 fail closed，UI 滑杆与音量键都无效。但本机
  `ioreg -rc DCPAVServiceProxy` 存在 Location=External 的 DDC/CI I2C 通道，
  实测 VCP 0x62（Audio Speaker Volume）读写成功（current=75 max=100，写 80
  读回 80，恢复 75），VCP 0x8D（Audio Mute）原生支持（1=mute, 2=unmute）。
- **音量键组逻辑摧毁设备间平衡**：取第一个可读硬件音量的设备做参考，把所有
  enabled 设备 route.volume 设成同一绝对值；MBP 扬声器 + 显示器组合下表现异常。

## 3. 本轮落地

### core/router：DDC/CI 显示器扬声器音量（新能力）

- 新增 `DDCTransport.swift`（IOAVService 私有 API 经 dlsym 加载、DCPAVServiceProxy
  枚举、I2C 事务、DDC 包构造/校验和纯函数；参考 m1ddc / MonitorControl，MIT）与
  `DDCDisplayVolume.swift`（专用串行队列、按 uid 合并 pending 写、能力缓存、
  连续 3 次写失败降级 + reconcile 重探自愈、用户意图音量与实际输出电平分层缓存）。
- 显示器↔CoreAudio 设备匹配保守 fail closed：优先 EDID 产品名 == CoreAudio 设备名；
  否则仅"恰好一台外接 DDC 显示器且音频 transport 为 HDMI/DP"才匹配；歧义不支持。
- `DirectStereoOutput.applyHardwareVolume`：CoreAudio 硬件音量写失败时回退 DDC。
- Router 新增 actor API：`directStereoVolumeCapabilities()`（uid →
  coreAudioHardware / ddc / none，等待 in-flight DDC 探测落定、2s 上限超时后
  fail closed）与 `readDirectStereoVolume(uid:)`（硬件读 → DDC 用户意图缓存 → nil）。
- 诊断串追加 ` ddc=N ddcWrites=N ddcErr=N`；两后端都拒绝才记 rejection。
- 新增 `SyncCastDDCProbe` executable（只读 / `--set-volume` / `--verify-write` 带恢复）。

### apps/menubar：媒体键 CGEventTap + 保平衡组音量

- `SystemVolumeKeyController` 重写：CGEventTap（session/headInsert/defaultTap，
  专用线程），仅当 eligible（stereo+direct+running，锁保护布尔）且事件为音量
  加/减/静音（keyDown+keyUp）时消费，其余一切放行；tap 被系统禁用自动重启；
  start/stop 竞态由 `SystemVolumeKeyTapLifecycle` 纯状态机（generation +
  stopRequested）治理，杜绝消费型 tap 泄漏。未授权时降级 NSEvent 监听（不差于现状）。
- 辅助功能权限 UX：首次进入 eligible 且未授权弹一次系统授权框；popover 显示
  "音量键控制需要辅助功能权限 + 打开设置"；经 `com.apple.accessibility.api`
  通知 + popover 重查感知授权变化，授权后免重启自动装 tap。
- 组音量改为每设备相对步进 ±1/16（保平衡），volumeUp 解除静音；mute 键
  "任一未静音→全静音，否则全取消"。删除"参考音量"绝对值方案。
- 硬件快照同步：进入 running / covered 集合变化 / 唤醒重建后，把 route.volume
  同步成真实硬件值（指纹门控，普通滑杆操作不触发回读）。新增
  `HardwareVolumeObserver`（CoreAudio 属性监听 + 120ms 去抖 + 350ms 自写抑制窗），
  外部改音量时回写 routing。
- 媒体键路径不再走全量 `reconcileEngine()`，改 `router.setRouting` 直推。
- capability == none 的设备行显示"音量不可控（用显示器 OSD）"提示。

## 4. 评审与验证

- Codex review（SOP 第一道闸）多轮迭代直至收敛：R1 共 4 条（P2×3 + P3 Optional
  `.none` 字典误删）；R2 共 2 条 P2（读回源需跟随写后端、`.supported` DDC 绑定
  睡眠/重插后纯媒体键路径无法自愈）；R3 共 3 条 P2（DDC 兜底成功掩盖 CoreAudio
  写失败的记账、快照指纹缺 Device.id、同 UID 换 id 观察者不重绑）；R4 共 1 条
  P1（静音写 0 经观察者延迟回灌覆盖 route.volume，unmute 变静音——双层修复：
  CoreAudio Mute 可写时 VolumeScalar 保持用户音量 + 静音回声过滤，并堵住快照
  刷新这第三条同源回灌路径）。全部修复。
- code-reviewer 深挖：HIGH（tap 线程 stop/start 竞态泄漏）+ MEDIUM（DDC writeRaw
  假阴性致误降级）+ LOW×2，全部修复。
- `swift build` core/router 与 apps/menubar 全部通过；SyncCastRouterTimingCheck
  30/30（新增 DDC 包构造 golden vector、标度转换、匹配矩阵、mute 分层缓存、
  读回源决策、记账决策、CoreAudio mute 语义检查）；独立 harness 57 项断言全过
  （含 tap 生命周期竞态与静音回声断言），38 个 XCTest 方法经 shim 跑通；
  DDC 探针实机 verify-write PASS（写 80 → 读回 80 → 恢复 75）。
- 本机 `swift test` 仍因 CommandLineTools 缺 XCTest 不可运行（既有环境问题）；
  测试文件已随 testTarget 入库。

## 5. 已知限制

- IOAVService 是私有 API，macOS 大版本变动时 dlsym 失败 → DDC 路径整体
  fail closed 回到现状。
- DDC 写异步入队（几十 ms 落地）；用户用显示器 OSD 手动改音量不会反向同步
  （DDC 无变更通知）。
- 显示器睡眠/重插后 IOAVService 句柄可能失效：写失败→降级→下次 reconcile 重探自愈。
- 媒体键需要用户授予辅助功能权限后才生效；授予前行为与旧版相同。
- backend == none（无 CoreAudio 音量也无 DDC）的设备仍不可控，仅提示。
