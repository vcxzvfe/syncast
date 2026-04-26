# Round 11: Manual-First Calibration Design

## 背景

Round 1-10 都是 closed-loop mic-feedback 路径。8 路并行调研一致认定该路径在物理上和工程上都不可靠：
- 业界 95% open-loop（Sonos, Roon, AirPlay 2, shairport-sync, Snapcast, Squeezelite）
- 用户主观对齐才是 ground truth (shairport-sync 文档明确)
- 用户实测：手动滑块 2300ms 比算法 1900ms 准 400ms

## 设计目标

1. 用户直接拖滑块，听感对齐时 Lock，UserDefaults 持久化
2. A/B audition (Stevens method bracketing) 帮用户精确收敛
3. Auto-estimate 降级为 "rough start" 不直接覆盖 user 值
4. 长期：per-device delay slider (Phase 2，beta 用户报需要时再做)

## 架构

### Lock 状态机
- DelayLockState: .unlocked | .locked(at: Int)
- 默认 .unlocked
- lockAirplayDelay() 写 UserDefaults syncast.airplayDelayLockedAt
- 启动时读 UserDefaults，> 0 → .locked

### Audition 状态机 (Stevens method)
- AuditionState: .idle | .running(round: Int, side: AuditionSide)
- startAudition() 备份当前值，进入 .running(1, .A)
- 每 1.2s 切 side：side .A → setDelay(baseline - 150)，side .B → setDelay(baseline + 150)
- 用户按 chooseAuditionA() → baseline -= 75，进下一 round
- 4 round 后回 .idle，最终 baseline 即收敛值
- stopAudition() 恢复 baseline

### Manual slider
- range 0-5000ms
- step 10ms (人耳对音乐 transient 的 JND ~10-15ms)
- ←/→ 键盘 ±10ms，Shift+←/→ ±100ms
- 拖动实时改 delay-line（30ms ramp 避免 click）

### Auto-estimate (降级)
- 收进 "Advanced" disclosure，默认折叠
- 改名 "Estimate (rough)"
- 修了 5 个 bug 后，理论上能给 ±100ms 的粗估
- 结果走 banner "Apply / Ignore"，**不直接覆盖** user 已 lock 的值

## 删除的代码 (~1964 LOC)

- PassiveCalibrator.swift (656 LOC)
- HybridDriftTracker.swift (941 LOC)
- Router.swift Passive/Hybrid sections (~250 LOC)
- AppModel hybrid 字段 (~30 LOC)
- MainPopover Hybrid UI (~80 LOC)
- scripts/drift_test_v2.sh + docs/round10_drift_history.csv

## 验收

见 docs/round11_acceptance.md.

## 业界对标

| 产品 | 同步方式 | mic 用法 |
|---|---|---|
| Sonos | SNTP + 软件延迟补偿 | 仅 Trueplay (room EQ)，不做 sync |
| AirPlay 2 multi-room | PTP (IEEE 1588) | 不用 |
| Roon RAAT | 时间戳 + buffer scheduling | 不用 |
| Snapcast | server timestamp | 不用 |
| shairport-sync | PTP + audio_backend_latency_offset | 用户手动 slider |
| Squeezelite | server-driven sample skip | 不用 |
| WiiM | open-loop + manual delay slider | 用户手动 slider |
| **SyncCast (Round 11)** | **Manual + UserDefaults persist** | **不用** |
