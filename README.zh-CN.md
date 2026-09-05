# SyncCast

> 虚拟输出设备驱动独立成仓库 [SyncCastAudio](https://github.com/vcxzvfe/SyncCastAudio)，以 git submodule 形式挂在 `drivers/SyncCastAudio`；克隆时加 `--recurse-submodules`，已有仓库执行 `git submodule update --init`。

[English](README.md) / 中文

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Status: Alpha](https://img.shields.io/badge/status-alpha-orange.svg)](#项目状态)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)](https://swift.org)

> 一个音频源,多设备路由。当前稳定路径是本地 Stereo; 本地 + AirPlay 同步仍在主动研发。

**SyncCast** 是一款 macOS 开源菜单栏应用,目标是把系统音频路由到多个本地扬声器和 AirPlay 设备。当前本地 Stereo 模式已经是主要可用路径; 本地扬声器 + AirPlay 的自动同步仍属于 alpha / R&D 阶段。

[截图位置 — 菜单栏弹出窗口与设备列表]

---

## 目录

- [它解决什么问题](#它解决什么问题)
- [核心功能](#核心功能)
- [系统要求](#系统要求)
- [安装](#安装)
- [系统音量](#系统音量)
- [使用方法](#使用方法)
- [架构概览](#架构概览)
- [项目状态](#项目状态)
- [贡献](#贡献)
- [License](#license)

---

## 它解决什么问题

macOS 自带的音频多路输出方案各有缺陷:

1. **音频 MIDI 设置 → 多输出设备**:可以把多个本地扬声器组合起来,但 AirPlay 2 接收器经常掉线,而且没有按设备调音量的能力。
2. **控制中心 → AirPlay 多房间**:只能输出到 AirPlay 2 设备。一旦你 AirPlay 出去,本地内置扬声器、USB DAC 就全部静音。

如果你想要的是「客厅 HomePod + 厨房 AirPlay 音箱 + 卧室 USB DAC + 笔记本内置扬声器」**同时**播放同一首歌,系统原生方案做不到可靠、可控。

**SyncCast 正在把两个世界合并到一起**:捕获一次系统音频,扇出到本地 CoreAudio 设备和 AirPlay 2 接收器,每台设备独立调音量。请注意:本地 + AirPlay 的自动对齐还没有达到生产级可靠性。

---

## 核心功能

- **系统音频捕获**:AirPlay/捕获相关路径仍可使用 ScreenCaptureKit; 本地 Stereo 现在默认走 Direct Stereo CoreAudio 输出路径,不需要 ScreenCaptureKit 或屏幕录制权限。
- **同时输出到本地 + AirPlay**:一次播放,内置扬声器、USB/HDMI 输出、AirPlay 2 接收器(HomePod、小米音箱等)都可以出声; 但本地 + AirPlay 的自动同步仍是实验功能。
- **两种模式**(互斥切换):
  - **AirPlay 实验模式**:本地输出 + AirPlay 接收器走 AirPlay/OwnTone 管道。多个 AirPlay 设备之间由 AirPlay 自己维护时序;本地扬声器通过环形缓冲水位控制环从属锁到同一个 OwnTone 时钟域,并可对每个输出做毫秒级延迟微调以补偿听音位置差异。
  - **本地模式 (Stereo / Local)**:只用本地 CoreAudio 设备,默认走 Direct Stereo,低延迟,口型对得上视频。这是当前最稳定的模式。
- **每台设备独立音量**:菜单栏 UI 给每台输出独立音量推子。
- **每台设备独立调音器 (EQ)**:给每个输出单独一套十段图示均衡器(31.5 Hz … 16 kHz,±12 dB,0.5 dB 一档),外加整体增益微调和旁路开关 —— 某个音箱低音太厉害就单独把它压下来,不影响别的音箱。曲线按 CoreAudio UID 记住,**每次连接自动恢复**,换工位接另一台显示器也不会串。AirPlay 全屋模式下同样生效:本地音箱各自经过自己的 bridge 渲染,曲线原样沿用,不用重新调一遍;AirPlay 接收端则共用**一条组曲线**(OwnTone 只往外发一路流,做不到分接收端),在 AirPlay 分区里单独一行。仅 Direct Stereo 路径下不生效(音频不经过本程序),界面会直接说明而不是给一个动了没反应的滑块。
- **每台设备独立声场处理**:紧凑型立体声音箱把两个高音单元并排放在几厘米之内、共用一个单声道低音,坐在桌前听两耳收到的左右几乎一样,声像塌成一个点。在与调音器相同的路径上,每个已启用的输出行多出一个「声场」按钮,里面是两级各自独立的处理:**宽度**只放大左右声道的差值(中/侧展宽),而且只在某个拐点频率以上生效(默认 1.5 kHz —— 这类音箱在那以下本来就没有立体声信息),按构造保证合并成单声道不会抵消;**串扰消除**是递归式的,延迟不用猜,由两个拿尺子就能量的滑杆推出来 —— 两个单元的中心间距和你的听音距离,面板会把算出的延迟直接显示出来,同时标明这套递归会把中置内容抬高多少(这是它真正的代价)。两级共用一个 **A/B 旁路**开关,因为唯一能判断好坏的仪器是坐在那个位置上的耳朵。同样按 CoreAudio UID 记住、**每次连接自动恢复**。注意串扰消除只在设定的那个听音位置成立,人一挪开就变成梳状滤波。
- **每台设备独立延迟补偿**:有些输出(尤其是显示器内置音箱)自己会额外做几十毫秒的音频处理,而且完全不上报,于是它比内建扬声器慢半拍。本地 Stereo 下每个已启用的输出行都有一条延迟滑杆(−100…+100 ms,1 ms ≈ 34 cm):正值 = 让这台晚出声,只有各台之间的**差值**有意义,最早的那台永远是基准。老老实实上报了自己延迟的设备会先自动对齐,滑杆只用来补那些不上报的部分。同样按 CoreAudio UID 记住、**每次连接自动恢复**;适用范围与调音器一致。全程不用麦克风,靠耳朵调。
- **每台设备独立声道分配**:一路立体声不是永远都该按立体声放。桌子左边单独摆的一只音箱,应该放**左声道** —— 而且是它自己两个单元都放左声道,因为它是一只完整的音箱,不是一对里的一半;床头那只单元数不够的,要的是 L+R 合并,不是随便分到哪半边。每个已启用的输出行多出一个「声道」按钮,里面是 立体声 / 左 / 右 / 单声道 四个预设,外加「自定义」下的四个分贝滑杆(−∞…+6 dB)。单声道按 0.5 相加,所以相干的满幅内容合并后正好是满幅而不会削顶。处理位置在调音器和声场之后、音量之前 —— 音量滑杆永远是信号链上最后一道。按输出 UID 记住、**每次连接自动恢复**;停在「立体声」时渲染路径逐位不变,没打开过面板的人一点代价都不付。
- **把另一台 Mac 当成一只音箱**:在另一台 Mac 上跑 `synccast-receiver`,它就会像本地输出一样出现在列表里,而且是**和身边这台同步出声**,不是 AirPlay 那样慢将近两秒。这是 SyncCast 自己的链路:48 kHz Int16,每 5 ms 一个 UDP 包,包头写明这一包必须在接收端 DAC 上出声的时刻 —— 而这个时刻是从采集环形缓冲自己的时钟推出来的,所以接收端锁的是音源的速率,不是任何一台机器上的定时器。目标延迟是一根滑杆(30…300 ms,默认 90),本地输出会自动被拖后到和它一起出声,面板会直接把最终的音画延迟写出来,而不是留给你自己去发现。只走局域网,用共享令牌认证,令牌存在**钥匙串**里。协议见 [`proto/lan-pcm-link.md`](proto/lan-pcm-link.md)。
- **不使用声学测量**:2026-08-09 起,主动探针与被动麦克风两条测量路线均已从代码中删除。SyncCast 不会打开麦克风,也不会播放任何校准音;对齐完全依靠 OwnTone 时钟域。
- **自动连接规则**:指定某个输出设备作为「触发设备」(按 CoreAudio UID 匹配,所以换个工位接另一台显示器不会误触发),它一出现 SyncCast 就自动切到本地 Stereo 并开启你选好的那几个输出。可选:它断开时停止播放、切回内建扬声器、并把内建音量设成固定值 —— 0% 是真正的静音,合上盖子带出门不会突然外放。
- **菜单栏轻量级 UI**:不抢 Dock 位置,后台运行,顶部 icon 一键展开。

---

## 系统要求

- macOS 14 (Sonoma) 或更高版本
- Apple Silicon 或 Intel 都支持(目前仅打包当前主机架构)
- 默认本地 Stereo 路径不需要 **Screen Recording**(屏幕录制)权限; AirPlay / SCK fallback 等捕获路径仍可能需要
- 不需要麦克风权限; 没有任何代码路径会打开麦克风,应用包内也不再包含 `NSMicrophoneUsageDescription`
- Netflix、Prime Video、Apple TV+ 等 DRM 视频可能会因为 ScreenCaptureKit 路径触发黑屏/拒播; 这是当前 P0 改造方向之一
- AirPlay 输出需要 macOS 与目标设备处于同一局域网

---

## 下载

预编译 `.app` 通过 GitHub Releases 发布:
[github.com/vcxzvfe/syncast/releases](https://github.com/vcxzvfe/syncast/releases)

最新 alpha 用 self-signed 证书签的。运行方式:

```bash
unzip SyncCast.app.zip
mv SyncCast.app /Applications/
xattr -dr com.apple.quarantine /Applications/SyncCast.app
open /Applications/SyncCast.app
```

或者从源码编译 — 见下方。

---

## 安装

目前仅支持源码编译。预编译版本待 v1 release。

### 1. 克隆仓库

```bash
git clone https://github.com/<your-user>/syncast.git
cd syncast
```

### 2. 安装依赖

```bash
./scripts/bootstrap.sh
```

这一步会准备 Python sidecar 虚拟环境,用于跟 AirPlay 设备说话。

### 3. 构建并打包成 .app

```bash
swift build -c release
./scripts/package-app.sh
```

打包脚本会:
- 编译 Swift 菜单栏可执行文件(release 模式)
- 用 PyInstaller 打包 Python sidecar 成单文件二进制
- 把 OwnTone 二进制及其依赖的 dylib 全部捆进 `dist/SyncCast.app/Contents/Frameworks/`
- 用 ad-hoc 或自签名证书 codesign

### 4. 安装到 /Applications

```bash
./scripts/install-app.sh
```

**注意**:macOS Tahoe 的 TCC(隐私权限子系统)对非 `/Applications` 路径下的应用会静默拒绝捕获类权限,所以**必须**走这一步把 .app 装进 `/Applications`。

默认本地 Stereo / Direct Stereo 路径不需要 Screen Recording。只有在使用 SCK fallback 或其他捕获依赖路径时,系统才可能弹窗请求屏幕录制权限; 授权后按提示重启 SyncCast。

---

## 系统音量

本地 **Stereo** 模式下，SyncCast 可以把自己接到 macOS 自己的音量 UI 底下：菜单栏
滑杆、F11/F12、音量 HUD、LinearMouse 滚轮，都直接调你那几只喇叭。不需要辅助功能
权限，也不再抢媒体键。

原理：把一台**虚拟 sink 设备**设成默认输出（macOS 会给这类设备真正的音量控制，
aggregate 则没有），用 Core Audio Process Tap 把它捕获下来，再把音量施加到真实
输出上——设备自己有硬件音量就写硬件音量，显示器支持 DDC/CI 就写 VCP 0x62，都没有
就走软件增益。运行期间「声音」菜单里显示的输出会是 **SyncCast**（或
**BlackHole 2ch**），那就是这台 sink，不是出错。

```bash
# 看当前会走哪条路径、装了哪台 sink：
( cd core/router && swift run SyncCastSystemSinkProbe )

# 看这条路径加了多少延迟（只读，按设备属性算）：
( cd core/router && swift run SyncCastSystemSinkProbe --latency )

# 端到端自检（会短暂占用默认输出几秒，结束后原样还原）：
( cd core/router && swift run SyncCastSystemSinkProbe --smoke )
```

### sink 路径的延迟

本机上 sink 路径多加 **~51 ms**：10.7 ms sink IO buffer + 30 ms ring floor +
10.7 ms 输出 IO buffer。设备自身的硬件呈现延迟不算在内——任何路径都要付。
Direct Stereo 加 ~0，因为 app 直接渲染进 aggregate，没有采集也没有环形缓冲。

之前仓库里写的“71 ms，其中 50 ms 是 Scheduler 的安全余量”是错的：Scheduler 的
backoff 根本没有进入 `LocalOutput` 的读取目标，而环形缓冲那一项是写死的 100 ms
floor，所以真实数字是 ~121 ms。现在 floor 按生产者分开：ScreenCaptureKit 路径
仍是 100 ms，sink 路径的 Process Tap 稳定给 512 帧块，用 30 ms。

用 `SYNCAST_SINK_RING_FLOOR_MS` 调（10…500，其它值会打警告并回落到 30）。调低
是拿 dropout 余量换延迟——在决定保留之前，先看
`~/Library/Logs/SyncCast/launch.log` 健康日志里的 `resync` / `underrun` /
`minWater` 三个计数器。**30 ms 这个默认值还没有做听感验证。**

### 安装 SyncCast 音频驱动

SyncCast 自带一台只有输出流的虚拟声卡（`SyncCastAudio.driver`，2 ch / 48 kHz；
没有输入流，所以不会触发任何麦克风类权限）。安装要管理员密码（HAL 插件放在
`/Library/Audio/Plug-Ins/HAL`），并且会重启 coreaudiod——全机音频会断一两秒。

```bash
bash drivers/SyncCastAudio/build.sh          # 产出 build/SyncCastAudio.driver
sudo bash scripts/install-driver.sh          # 安装并重启 coreaudiod
sudo bash scripts/install-driver.sh --uninstall
```

弹窗里的**「安装 SyncCast 音频驱动」**按钮走的是同一个脚本，密码由 macOS 自己的
授权对话框收取。装完请重启 SyncCast——路径每次启动只解析一次。

没装驱动时：有 **BlackHole 2ch** 就用它兜底；两者都没有则回到旧的 Direct Stereo
路径（那条路依然靠媒体键 event tap）。可用 `SYNCAST_STEREO_PATH=sink|direct|capture`
强制指定。

全屋模式走的是同一套优先级；装了 `SyncCastAudio.driver` 之后它会**直接把这台
设备设成系统默认输出**——于是**菜单栏音量滑杆、F11/F12、音量 HUD、滚轮调音工具
在全屋模式下都能直接控制总音量**，不再需要媒体键 event tap。只有 BlackHole 兜底
那条路还藏在「AirPlay 全屋」这个 aggregate 后面：aggregate 没有音量控制，所以那
条路继续用面板上的总音量滑杆加媒体键 tap。

**BlackHole 在任何模式下都只是兜底、可以不装**。装好 `SyncCastAudio.driver`
之后可以直接卸掉它：

```bash
sudo rm -rf /Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver
sudo killall coreaudiod
```

---

## 使用方法

1. 装好后启动:`open /Applications/SyncCast.app`
2. 菜单栏右上角会出现 SyncCast icon,点开弹窗
3. 选择模式:
   - **AirPlay 实验模式**:列出 AirPlay 2 接收器和可用本地输出,勾选要播的设备
   - **本地模式**:列出全部本地 CoreAudio 输出,勾选要播的设备
4. 用任意 macOS 应用播放音频(Music、Spotify、网页视频等),被勾选的设备就会同时出声
5. 调音量：sink 路径下**系统音量滑杆就是总音量**，每台设备旁边的推子是叠加在它
   上面的平衡量（详见[系统音量](#系统音量)）
6. (可选)配好自动连接:先勾好想要的设备,在设备列表下面的「自动连接」里选好触发设备,点「用当前选择创建规则」。之后只要触发设备一出现就会自动恢复这套选择;如果你自己改过选择,规则会先让路,直到触发设备拔掉再插上、或者你点「重新应用规则」。

切换模式时会重新规划输出。Stereo 本地模式是当前推荐的日常稳定路径; AirPlay 实验模式适合继续测试同步、漂移和中断恢复。

[截图位置 — 模式切换与设备勾选]

---

## 架构概览

```
              系统音频(任意 macOS 应用)
                       │
                       ▼
        ┌──────────────────────────────────┐
        │  ScreenCaptureKit 系统音频捕获     │
        └─────────────────┬────────────────┘
                          │
                          ▼
        ┌──────────────────────────────────┐
        │      SyncCast Router (Swift)     │
        │   • 设备注册表(可插拔传输层)     │
        │   • 每设备音量 + 模式调度         │
        │   • 经 Unix socket 跟 sidecar 通信│
        └─┬──────────────┬─────────────────┘
          │              │
          ▼              ▼
     CoreAudio       Python sidecar (pyatv + OwnTone)
   (聚合设备/本地)    AirPlay 2 RTSP/PTP
          │              │
          ▼              ▼
   内置扬声器、     HomePod、小米音箱、
   USB DAC、       第三方 AirPlay 2 接收器、
   HDMI 显示器      运行 AirPlay Receiver 的 Mac
```

详细设计见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

仓库布局:

```
syncast/
├── apps/menubar/        # SwiftUI 菜单栏应用
├── core/router/         # Swift Package — 音频捕获 + 路由 + 传输层
├── core/discovery/      # Swift Package — CoreAudio + Bonjour 设备发现
├── sidecar/             # Python sidecar — pyatv 驱动 AirPlay 2 多目标
├── proto/               # Swift ↔ Python IPC 协议(Unix socket 上的 JSON-RPC)
├── tools/               # CLI 工具(syncast-discover、syncast-route)
├── docs/                # 架构、ADR、协议规范
└── scripts/             # 构建、打包、安装脚本
```

---

## 项目状态

**Alpha — 开发中,使用风险自负。**

SyncCast 还在早期阶段,API 和 UI 都可能在不通知的情况下变更。当前已知限制:

- 仅支持当前编译机器的架构(没做 universal2)
- 未公证(non-notarized),首次启动需手动允许 Gatekeeper
- 没有自动更新机制
- 本地 + AirPlay 同步现在走 OwnTone 时钟域,只在单一环境下由人耳验证过; 尚未在多种接收端和长时间会话中验证
- ScreenCaptureKit 捕获会影响部分 DRM 视频播放; 本地 Stereo 已默认绕过 SCK,但 AirPlay / Process Tap 捕获验证仍在推进
- 部分边缘情况下设备掉线后需要手动重连

如果你愿意当 alpha 测试用户、能接受偶尔重启 app、能读 Console 日志反馈 bug,欢迎试用。

进度路线图见 [docs/ROADMAP.md](docs/ROADMAP.md)。

---

## 贡献

SyncCast 大量使用 [Claude Code](https://claude.com/claude-code) 多 agent 工作流开发 — 在隔离 worktree 里并行跑多个 agent 完成研究、规划、实现、code review、文档等任务。欢迎 PR、issue 和讨论:

- **Bug 反馈**:开 issue 时请附上 macOS 版本、芯片(Intel / Apple Silicon)、设备清单、复现步骤
- **PR**:请先看 [CONTRIBUTING.md](CONTRIBUTING.md);保持 commit 信息符合 conventional commits 风格
- **文档/翻译**:`docs/` 下任何错误、不清晰的描述都欢迎修正

---

## License

MIT — 详见 [LICENSE](LICENSE)。

Copyright (c) 2026 SyncCast contributors.
