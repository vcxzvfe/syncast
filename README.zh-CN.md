# SyncCast

[English](README.md) / 中文

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Status: Alpha](https://img.shields.io/badge/status-alpha-orange.svg)](#项目状态)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)](https://swift.org)

> 一个音频源,全屋扬声器同步播放。专为 macOS 设计。

**SyncCast** 是一款 macOS 开源菜单栏应用,可以把系统音频实时同步路由到多个本地扬声器和 AirPlay 设备 — 让客厅 HomePod、厨房 AirPlay 音箱、卧室 USB DAC 同时播放同一首歌。

[截图位置 — 菜单栏弹出窗口与设备列表]

---

## 目录

- [它解决什么问题](#它解决什么问题)
- [核心功能](#核心功能)
- [系统要求](#系统要求)
- [安装](#安装)
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

如果你想要的是「客厅 HomePod + 厨房 AirPlay 音箱 + 卧室 USB DAC + 笔记本内置扬声器」**同时**播放同一首歌,系统原生方案做不到。

**SyncCast 把两个世界合并到一起**:捕获一次系统音频,扇出到任意组合的本地 CoreAudio 设备和 AirPlay 2 接收器,每台设备独立调音量。

---

## 核心功能

- **零虚拟驱动捕获**:基于 ScreenCaptureKit 的系统级音频捕获,不需要安装 BlackHole、SoundFlower 这类内核扩展。
- **同时输出到本地 + AirPlay**:一次播放,内置扬声器、USB/HDMI 输出、AirPlay 2 接收器(HomePod、小米音箱等)都同步发声。
- **两种模式**(互斥切换):
  - **全屋模式 (Whole-home / AirPlay)**:所有输出走 AirPlay 2 管道,~1.8 秒延迟,完美 PTP 同步,不适合配视频。
  - **本地模式 (Stereo / Local)**:只用本地 CoreAudio 设备(聚合设备),~50ms 低延迟,口型对得上视频。
- **每台设备独立音量**:菜单栏 UI 给每台输出独立音量推子。
- **菜单栏轻量级 UI**:不抢 Dock 位置,后台运行,顶部 icon 一键展开。

---

## 系统要求

- macOS 14 (Sonoma) 或更高版本
- Apple Silicon 或 Intel 都支持(目前仅打包当前主机架构)
- 首次运行需授予 **Screen Recording**(屏幕录制)权限 — 这是 ScreenCaptureKit 捕获系统音频的前提
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

**注意**:macOS Tahoe 的 TCC(隐私权限子系统)对非 `/Applications` 路径下的应用会静默拒绝 Screen Recording 权限,所以**必须**走这一步把 .app 装进 `/Applications`。

第一次启动时,系统会弹窗请求屏幕录制权限,授予后重启 SyncCast 即可。

---

## 使用方法

1. 装好后启动:`open /Applications/SyncCast.app`
2. 菜单栏右上角会出现 SyncCast icon,点开弹窗
3. 选择模式:
   - **全屋模式**:列出全部 AirPlay 2 接收器,勾选要播的设备
   - **本地模式**:列出全部本地 CoreAudio 输出,勾选要播的设备
4. 用任意 macOS 应用播放音频(Music、Spotify、网页视频等),被勾选的设备就会同时出声
5. 用每台设备旁边的推子调音量

切换模式时正在播放的输出会无缝切到另一组设备。

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

Copyright (c) 2026 Zifan and SyncCast contributors.
