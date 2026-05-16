# Acoustic Calibration 高频 Coded Probe 测试计划

> Status 2026-05-13: historical active-probe test plan. After user reports that high-band probes remain audible, autonomous Goal runs should prefer passive no-probe real-program evidence. Use this document only for explicit lab/diagnostic probe methodology; use `docs/requirements_2026-05-12.md` as the current acceptance source.

## 目标

验证高频 coded probe 作为声学校准观测信号时，能够稳定产生日志、可被客观判读，并且在不满足质量门槛时不会改变当前同步参数。

observe-only 测试必须保持 before/after delay 不变。auto-apply 测试只允许通过当前实现的 fail-closed 门槛写入：delay unlocked、同一路由/音量/麦克风上下文、低不确定性/MAD、足够 confidence、健康 transport，以及小跳变或重复一致的大跳变。

## 范围

- 覆盖 local output 与 AirPlay output 的 coded probe 注入、采集、检测和日志。
- 覆盖用户主观 audibility 反馈：是否听得见、是否刺耳、是否影响正常收听。
- 覆盖 coded probe 与正常播放内容分离测试。
- observe-only 路径仅记录建议值或观测值，不自动写入、应用或持久化 delay 变更。
- auto-apply 路径必须记录写入理由或拒绝理由，例如 `small_jump`、`verified_large_jump`、`low_confidence`、`high_uncertainty`、`delay_locked`、`context_changed`、`verify_disagreed`。
- 后续再验证正常播放期间叠加低可闻 pilot 的方案，本计划只定义入口判据。

## 前置条件

- 使用固定测试音量，先从较低音量开始，确认不会造成不适后再进入完整测试。
- local output 与 AirPlay output 都已连接并可正常播放。
- 日志级别能够输出 acoustic calibration / coded probe 相关记录。
- 测试前记录当前 delay 状态，作为 before delay 基线。
- 测试后再次记录 delay 状态，作为 after delay 对照。

## 客观日志判据

### observe-only 不自动 apply

通过条件：

- 日志中可以出现 probe detection、estimated offset、confidence、suggested delay 等观测或建议字段。
- 日志中不得出现自动应用 delay 的记录，例如 auto apply、applied delay、persisted calibration、updated sync offset 等等价语义。
- 测试完成后，before delay 与 after delay 数值完全一致。

失败条件：

- 任一输出路径在未人工确认的情况下改变 delay。
- 日志显示 coded probe 结果被直接写入运行时同步参数或持久化配置。

### before/after delay 不变

每轮测试必须记录：

```text
before_delay_local_ms=
before_delay_airplay_ms=
after_delay_local_ms=
after_delay_airplay_ms=
```

通过条件：

- `before_delay_local_ms == after_delay_local_ms`
- `before_delay_airplay_ms == after_delay_airplay_ms`

如系统内部使用 sample/frame/tick 表示 delay，需要同时记录原始单位与换算后的毫秒值。

### local_CODED 关键日志

local coded probe 至少需要包含以下信息：

```text
local_CODED emit sequence_id=<id> freq_hz=<value> level_dbfs=<value> duration_ms=<value>
local_CODED detect sequence_id=<id> status=<detected|missed> confidence=<0..1> offset_ms=<value>
local_CODED summary emitted=<n> detected=<n> missed=<n> median_offset_ms=<value> jitter_ms=<value>
```

通过条件：

- `emit` 与 `detect` 的 `sequence_id` 能对应。
- 在安静环境下连续 10 次 probe 中，local detection 成功率应达到 90% 或以上。
- `confidence` 字段存在，并能用于区分 detected 与 missed。
- `summary` 能给出 detected/missed 计数和 offset 分布。

失败条件：

- 只有 probe 发射日志，没有检测日志。
- `sequence_id` 缺失，导致无法追踪单次 probe。
- offset 单位不明确。

### airplay_GROUP / airplay_CODED 关键日志

当前主路径把选中的 AirPlay receiver 视为一个 `airplay-group`，用于估计 Local vs AirPlay group 的整体延迟。旧的 per-target `airplay_CODED` / TDMA 记录只作为研究或未来 per-receiver stream 架构的补充。

AirPlay group coded probe 至少需要包含以下信息：

```text
airplay_GROUP cycle=<n>/<total> peak_time=<ms> prominence=<value> second_ratio=<value> edge=<ms>
airplay_GROUP summary cycles=<n> median=<ms> MAD=<ms> range=<ms> slope=<ms/cycle> confidence=<value>
ActiveCalib DONE local=<...> airplay_max=<...> airplay_uncertainty=<...> delta=<ms> confidence=<value>
```

通过条件：

- `airplay-group` 结果包含 cycle 数、median/MAD/range/slope、confidence 和 uncertainty。
- 在安静环境下连续 probe 中，AirPlay group 必须达到当前实现的 minimum valid cycle / confidence / MAD / range / slope gates。
- missed probe 必须被显式记录，不能静默丢失。
- local 与 AirPlay 的 coded 日志可以按时间或 run/cycle 编号对齐。

失败条件：

- AirPlay group 日志无法区分本轮是 group 模式还是 per-target 研究模式。
- AirPlay 路径只记录播放，不记录检测结果。
- 检测失败时没有 status 或原因字段。

## 主观验证步骤

### Audibility 反馈

每位测试者按以下模板记录主观反馈：

```text
tester=
device_setup=
room_noise=<quiet|normal|noisy>
volume_level=
heard_probe=<yes|no|unsure>
annoyance=<0..5>
affected_music_listening=<yes|no|unsure>
notes=
```

评分含义：

- `0`: 完全不可闻或无感。
- `1`: 偶尔注意到，但不影响。
- `2`: 可察觉，短时间可接受。
- `3`: 明显可闻，开始影响体验。
- `4`: 刺耳或干扰正常使用。
- `5`: 不可接受，应立即停止该参数组合。

通过条件：

- 对 autonomous/default Goal runs：任何可闻 probe 都视为不可接受，必须停止并回到 passive no-probe 路线。
- 对显式 lab/diagnostic probe 测试：高频 coded probe 在测试音量下不造成不适，且测试者明确知道会播放短测试音。
- `annoyance` 平均值不高于 2。
- 任一测试者报告 4 或 5 时，该频率、音量或持续时间组合不得进入后续常规测试。

### 操作流程

1. 记录当前 local 与 AirPlay delay，填入 before delay。
2. 开启 coded probe 测试模式，确认没有自动 apply 开关被启用。
3. 对 local output 连续运行 10 次 probe。
4. 对每个 AirPlay target 连续运行 10 次 probe。
5. 保存包含 `local_CODED` 与 `airplay_CODED` 的完整日志片段。
6. 记录测试者 audibility 反馈。
7. 再次读取 local 与 AirPlay delay，填入 after delay。
8. 比对 before/after delay，确认完全不变。
9. 汇总 detection rate、median offset、jitter 与 missed probe 原因。

## 正常播放叠加 Pilot 后续测试

本轮 coded probe 测试通过后，才能进入正常播放叠加 pilot 的后续测试。后续测试需要单独确认：

- 正常音乐、播客、系统音频播放时，pilot 不应显著改变听感。
- pilot 日志必须能与正常音频播放日志区分。
- pilot 检测失败不得中断正常播放。
- pilot 只能产生观测结果和建议值，仍不得自动 apply delay。
- 在正常播放状态下，before/after delay 仍必须保持不变。

进入后续测试的最低条件：

- `local_CODED` 与 `airplay_CODED` 关键日志均满足本计划判据。
- coded probe audibility 平均不高于 2，且无人报告 4 或 5。
- 连续完整测试后 before/after delay 完全一致。

## 测试记录模板

```text
date=
build_or_commit=
tester=
local_device=
airplay_targets=
room_noise=
volume_level=

before_delay_local_ms=
before_delay_airplay_ms=

local_CODED_emitted=
local_CODED_detected=
local_CODED_missed=
local_CODED_median_offset_ms=
local_CODED_jitter_ms=

airplay_CODED_target=
airplay_CODED_emitted=
airplay_CODED_detected=
airplay_CODED_missed=
airplay_CODED_median_offset_ms=
airplay_CODED_jitter_ms=

heard_probe=
annoyance=
affected_music_listening=

after_delay_local_ms=
after_delay_airplay_ms=

auto_apply_observed=<yes|no>
pass_fail=
notes=
```

## 退出判据

测试可标记为通过，当且仅当：

- observe-only 测试未观察到任何自动 apply，before/after delay 对照完全不变。
- auto-apply 测试的每一次写入或拒绝都有明确 reason，并且符合 `docs/requirements_2026-05-07.md` 的 fail-closed 门槛。
- `local_CODED` 与 `airplay_GROUP` / `airplay_CODED` 均输出可追踪、可统计的关键日志。
- detection rate 达到本计划的 local 与 AirPlay 最低要求。
- audibility 反馈未触发不可接受阈值。
- 正常播放叠加 pilot 的后续测试入口条件已明确记录。
