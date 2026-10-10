<div align="center">

# 源影 · Flutter

**跨端视频聚合客户端 —— Flutter 重写版**

[![构建](https://github.com/sourin-app/sourin/actions/workflows/build.yml/badge.svg)](https://github.com/sourin-app/sourin/actions/workflows/build.yml)
[![许可证](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.47.5-02569B.svg)](https://flutter.dev)
[![Rust](https://img.shields.io/badge/Rust-1.85-000000.svg)](https://www.rust-lang.org)

Windows · macOS · Android · Android TV

</div>

---

## 这是什么

「源影」是一个**跨端视频聚合客户端**：把多个内容源（CMS 站点、内置站点、B 站、
Emby、IPTV 直播）聚合成一个界面，统一搜索、收藏、追更、播放与下载。

这个仓库是它的 **Flutter 重写版**，取代了最初的 Tauri + Vue 实现。重写的动机是
**播放内核**：原版跑在 WebView2 上，走 Media Foundation 解码，而 Windows 默认
不注册 HEVC 解码器 MFT（实测 61 个 MFT 里零个 HEVC）—— 用户一遇到 HEVC 就黑屏。
Flutter 版用 **media_kit + libmpv**（自带完整 FFmpeg，完全不碰 Media Foundation），
把这个问题从根上解决。

> **架构要点**：业务逻辑（数据源解析、插件沙箱、流代理、云同步、数据库）全部在
> Rust 里，Flutter 只做 UI —— 两侧通过 **Dart FFI** 直接调用，不经过任何 IPC 层。
> 这让 81% 的原版 Rust 代码被原样复用。

---

## 目录

- [功能](#功能)
- [架构](#架构)
- [从源码构建](#从源码构建) ← 含 [开发流程](#开发流程走-pr不走直推-main)（**走 PR，不走直推 main**）
- [平台支持](#平台支持) ← Windows / macOS / Android / **Android TV**
- [配置说明](#配置说明) ← **这一节最详细**
- [数据目录](#数据目录)
- [插件开发](#插件开发)
- [主题包](#主题包) ← 自己写一套配色（JSON，零门槛）
- [测试](#测试)
- [常见问题](#常见问题)
- [许可证](#许可证)

---

## 功能

### 内容聚合

| 能力 | 说明 |
|---|---|
| **多源聚合** | 内置站点 + 第三方插件 + 声明式 JSON 源 + HTTP 进程外源，统一成一个源列表 |
| **跨源搜索** | 一次搜索并发打全部源，**边搜边出**（流式返回，不等最慢的那个） |
| **跨源换源** | 同一部剧在别的源上也能看 —— 按标题相似度排序，带进度迁移 |
| **TVBox 直连** | 直接填 TVBox 配置**地址**或 JSON，内部解析成源，**不需要转换脚本** |
| **B 站** | 二维码扫码登录、搜索、弹幕（含分 P）、自动更新 |
| **Emby / Jellyfin** | 登录、媒体库、直接播放 |
| **IPTV 直播** | iptv-org 频道表、分组、上下键切台 |
| **CCTV** | 央视栏目与直播（含 DRM 流的「仅音频可播」如实提示） |

### 播放

| 能力 | 说明 |
|---|---|
| **内核** | libmpv（media_kit），硬解 d3d11va / MediaCodec |
| **格式** | HEVC / H.264 / AV1、AC3 / DTS / AAC、ASS / SRT 字幕 |
| **字幕** | 内封轨切换、外挂字幕、ASS 样式（字号/颜色/位置）、Assrt 字幕库 |
| **弹幕** | B 站弹幕、自定义弹幕服务器、速度/透明度/密度/区域可调 |
| **手势** | PC 与触摸两套（双击全屏、长按倍速、左右滑动跳转、上下滑音量/亮度） |
| **控件自动隐藏** | 鼠标停手 3 秒后**顶栏与底栏一起淡出**（同一个动画源），一晃动一起回来 |
| **画中画** | 独立窗口，可从播放页一键切出 |
| **投屏** | DLNA 投到电视（自动改写 m3u8 内嵌地址，电视直接能拉） |
| **遥控** | 手机当遥控器（局域网 HTTP + 二维码配对） |

### 下载

| 能力 | 说明 |
|---|---|
| **整片下载** | 把 HLS 播放列表里的**全部分片**拼成一个文件（不是存清单） |
| **按组存放** | 一部剧一个文件夹，落在 `视频/源影/<剧名>/` |
| **单集 / 全部集** | 详情页头部的「下载」菜单两个动作；全部集走**串行**队列 |
| **片段缓存** | 播放页「下载本集到缓存」，独立目录 + 上限淘汰 |

### 桌面集成

- **托盘图标** —— 单击打开、右键菜单（打开主界面 / 退出）
- **关闭确认** —— 首次点 X 问「最小化到托盘 / 彻底退出 / 取消」，选择被记住
- **自绘标题栏** —— 可拖动、双击最大化、贴边 Aero Snap、窗口阴影
- **窗口几何记忆** —— 下次启动回到上次的位置和大小（自动夹进工作区）
- **云同步** —— WebDAV 备份/恢复，多设备共享收藏与进度

---

## 架构

```text
┌───────────────────────────────────────────────────────────────┐
│  Flutter (Dart)              lib/                              │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │  shell.dart        自绘标题栏 / 5 个 tab / 保活 Stack    │  │
│  │  ui/player_page   播放页（控制条 / 弹幕 / 手势 / 浮层）  │  │
│  │  ui/detail_page   详情页（剧集 / 换源 / 下载）           │  │
│  │  ui/live_page     直播页（频道 / EPG / 内嵌播放器）      │  │
│  │  ui/settings_page 设置（源 / 代理 / 同步 / 关于）        │  │
│  │  core/            FFI 绑定、API 封装、偏好、下载器       │  │
│  └─────────────────────────────────────────────────────────┘  │
└──────────────────────────┬────────────────────────────────────┘
                           │  dart:ffi（直接函数调用，无 IPC）
┌──────────────────────────▼────────────────────────────────────┐
│  Rust 核心 (cdylib)          rust/sourin_core/                 │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │  ffi.rs            C ABI 导出（7 个符号）                │  │
│  │  registry.rs       源注册表（内置 / 插件 / 声明式 / HTTP）│  │
│  │  plugins/mod.rs    QuickJS 插件沙箱（host.* API）        │  │
│  │  streamproxy.rs    本地流代理（防盗链 / 地址改写 / 预取） │  │
│  │  store.rs          SQLite（收藏 / 历史 / 进度 / 片头片尾）│  │
│  │  tvbox.rs          TVBox 配置解析（不生成 JS）           │  │
│  │  sync/             WebDAV 云同步                         │  │
│  │  remote/           手机遥控（局域网 HTTP 服务）           │  │
│  └─────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────┘
```

### 为什么业务逻辑放 Rust

```text
① 复用       原版 Tauri 的 Rust 业务代码 81% 可以原样搬过来，只改掉 Tauri 引用
② 性能       插件沙箱（QuickJS）、SQLite、HTTP 代理都在原生侧，Dart 侧零开销
③ 跨端       同一份 .rs 编出 Windows 的 .dll 和 Android 的三个 .so
④ 可测       cargo test 直接测业务逻辑，不需要起 UI
```

### FFI 契约

Rust 侧只导出 **7 个符号**（`rust/sourin_core/src/ffi.rs`）：

```text
sourin_core_version()     版本号
sourin_start(json)        启动核心（数据目录等）
sourin_call(json)         同步调用一个命令
sourin_call_async(json)   异步调用（阻塞池）
sourin_call_stream(json)  流式调用（边算边回，搜索用这个）
sourin_cancel_stream(id)  取消一条流
sourin_free(ptr)          释放返回的字符串
```

> ⚠️ **实现约束**（踩过坑）：`sourin_call_async` 走 `spawn_blocking` → `dispatch_blocking`，
> 绝不能在 `runtime().spawn()` 的 worker 里直接 `block_on` —— 会饿死线程池，
> 实测 8 个并发调用**全部** 120 秒超时。

---

## 从源码构建

### 前置依赖

| 依赖 | 版本 | 说明 |
|---|---|---|
| Flutter | **3.47.5**（Dart 3.13.4） | 低于 3.47 编不过（用到了 `material_ui` 拆包后的 API） |
| Rust | **1.85+** | 核心是 edition 2021 |
| Visual Studio | 2022 + 「使用 C++ 的桌面开发」 | Windows 端编译 runner |
| Android SDK + NDK | NDK **27.0.12077973** | 只有编 Android 需要 |
| CMake | 3.14+ | 随 VS 安装 |

> **Android NDK 版本必须对齐** —— 仓库里的 `rust/sourin_core/.cargo/config.toml.example`
> 写死了三个 target 的 linker 路径（模板里是 `<NDK>` 占位符）。
> 用之前先 copy 一份并填上你本机的 NDK 路径：
>
> ```powershell
> Copy-Item rust/sourin_core/.cargo/config.toml.example rust/sourin_core/.cargo/config.toml
> # 然后把 <NDK> 换成 C:/Users/<你>/AppData/Local/Android/Sdk/ndk/27.0.12077973
> ```
>
> ⚠️ `.cargo/config.toml` 本身**不在仓库里**（含本机绝对路径），只有 `.example` 进库。

### 1. 拉代码 + 装依赖

```bash
git clone https://github.com/sourin-app/sourin.git
cd sourin
flutter pub get
```

### 2. 编 Rust 核心

```bash
cd rust/sourin_core
cargo build --release
cd ../..
```

产物在 `rust/sourin_core/target/release/sourin_core.dll`（Windows）或
`libsourin_core.so`（Linux / Android）。

### 3. 把核心放进构建目录

```powershell
# Windows
Copy-Item rust\sourin_core\target\release\sourin_core.dll windows\
```

`windows/CMakeLists.txt` 会在构建时把它拷到 runner 目录。

> ⚠️ **`.dll` 必须真的重新编出来。** `cargo build --release` 在源码没改动时会
> 直接跳过，`mtime` 保持不变；此时若你只是把一个**旧的** `.dll` 拷回
> `rust/sourin_core/target/release/`，构建会把那个旧件原样装进包 ——
> 症状是「改了 Rust 但行为没变」。**改完核心请核 `sourin_core.dll` 的哈希或
> `mtime` 确实变了**。（`windows/CMakeLists.txt` 用的是 `install(FILES ...)`，
> 它会无条件复制源件，不按时间戳判断；需要强制刷新时直接删掉包目录里的那个 `.dll`。）

### 4. 编 Flutter

```bash
# Windows（注意 -t：入口是 shell.dart 不是 main.dart）
flutter build windows --release -t lib/shell.dart

# Android
flutter build apk --release --target-platform android-arm64
```

> ⚠️ **`-t lib/shell.dart` 不能漏**。`lib/main.dart` 是一个早期的 HEVC 验收 spike
> （见那个文件头的说明），不是产品入口。漏了 `-t` 会编出一个 spike 而不是客户端。

### 5. Android 的 Rust 交叉编译

```powershell
$ndk = "$env:LOCALAPPDATA\Android\Sdk\ndk\27.0.12077973\toolchains\llvm\prebuilt\windows-x86_64\bin"
$env:PATH = "$ndk;$env:PATH"

cd rust/sourin_core
foreach ($t in @("x86_64-linux-android","aarch64-linux-android")) {
  cargo build --release --target $t
}
# armv7 要额外给 cc crate 指编译器（它猜不出 v7 的名字）
$env:CC_armv7_linux_androideabi = "$ndk\armv7a-linux-androideabi24-clang.cmd"
cargo build --release --target armv7-linux-androideabi

# 拷进 jniLibs
cd ../..
$map = @{
  "x86_64-linux-android"      = "x86_64"
  "aarch64-linux-android"     = "arm64-v8a"
  "armv7-linux-androideabi"   = "armeabi-v7a"
}
foreach ($k in $map.Keys) {
  Copy-Item "rust\sourin_core\target\$k\release\libsourin_core.so" "android\app\src\main\jniLibs\$($map[$k])\" -Force
}
```

> ⚠️ **改完 `ffi.rs` 必须重编这三个 target 并重新拷贝** —— `jniLibs/*/libsourin_core.so`
> 是**手动拷贝**的产物，不在 Flutter 的构建链里。漏了会在 Android 上看到：
> ```text
> [SHELL] ★ 核心启动失败: Failed to lookup symbol sourin_call_stream
> ```
> 然后**所有命令都超时**（看起来像网络问题，实际是旧的 .so 里没有新符号）。

### 6. 验证

```powershell
# 核心里应当有 7 个导出符号
strings android/app/src/main/jniLibs/x86_64/libsourin_core.so | Select-String "^sourin_"
```

### CI

`.github/workflows/build.yml` 在每次 push / PR 时：

```text
windows  编 Rust 核心 → analyze → 全量测试 → 打包 → 上传 Artifact
macos    编 Rust 核心 → analyze → 全量测试 → 打包 .app → 上传 Artifact
android  NDK 交叉编译三个 ABI → 两个 APK → 上传（**默认关闭**）
```

Android 那个 job 默认关掉：它最慢（要 NDK + 三个 target 交叉编译），
而 Windows job 已经覆盖了 Dart 与 Rust 两侧的全部测试。
要跑就手动触发 `workflow_dispatch` 并勾上 `build_android`。

### CI 里几个有意加的核验（都是踩过的坑）

| 检查 | 防的是什么 |
|---|---|
| Windows：`data/app.so` 必须 > 5 MB | 漏了 `-t lib/shell.dart` 会编出 spike 而不是客户端，而**编错了不报错** |
| Windows：显式确认 `windows/sourin_core.dll` 存在 | CMake 的拷贝按时间戳判断，会静默跳过 |
| macOS：`codesign -d --entitlements` 核验带上了 `network.client/server` | 少了它应用能启动但所有请求都失败 |
| Android：数 `.so` 里的 `sourin_` 导出符号 ≥ 7 个 | 改完 `ffi.rs` 没重编那个 ABI，症状是「所有命令都超时」 |
| Android：`aapt dump badging` 检查 `LEANBACK_LAUNCHER` | 少了它 TV 上找不到应用 |

> ⚠️ `flutter analyze` 在 CI 里跑的是 `--no-fatal-infos --no-fatal-warnings`：
> 本仓有约 440 条既有 warning/info（探针文件与测试里的既有项），
> 默认设置会让 CI 永远红。加了这两个 flag 之后**只有 error 才卡住**
> （实测：有 error 时仍返回 1）。

### 开发流程：走 PR，不走直推 main

功能迭代走 **「开 PR → AI 审核 → 完善 → 合并」**，细则见
[CONTRIBUTING.md](CONTRIBUTING.md)。摘要：

```text
① 开分支   git switch -c feat/<短描述>
② 提交     git commit
③ 开 PR    git push -u origin <branch> → GitHub 上开 PR
④ 自动评审 CI 跑起来；CodeRabbit 几分钟内贴出评审
           ★ 触发条件：App 已装 + PR 目标 main + 非草稿 + 标题未命中排除词
⑤ 完善     逐条判断：真问题就修，误报就回帖说明并 resolve
⑥ 再评审   推新 commit 后自动复审增量
⑦ 合并     意见都处理完 + CI 全绿 → 合并
```

> ⚠️ **`main` 已开分支保护，任何直推都会被服务端拒绝**（GH006）。
> 下面这些改动**仍要开 PR**，只是**可以自己直接合并**、不用等人看：
> 错别字 / 注释 / 文档 / `.gitignore` 这类元数据 / 回滚刚推错的东西 /
> main 已经红了要紧急修 CI。
> 判断标准是「**这个改动有没有可能悄悄改变产品行为？**」——有就走完整流程
> （等 CI + 处理评审意见）；没有就开 PR 后直接合。

#### CodeRabbit（AI 代码评审）

配置在 [`.coderabbit.yaml`](.coderabbit.yaml)。它补的正是 CI 拦不住的那类问题：

| 只有 CI 时能拦住 | 需要有人看才能拦住 |
|---|---|
| 编译不过、测试红、analyze error | 某个分支在某种平台组合下永远走不到 |
| 依赖缺失、格式不符 | 一条断言其实**恒真**（假门禁） |
| 版本号对不上 | 改了 A 忘了同步 B（如 `.nsi` 的安装侧 / 卸载侧） |
|  | 并发 / 时序问题（测试改进程级全局量） |

右列这几类本仓**每一条都真踩过**，共同特征是「CI 全绿，问题在用户那里才爆」。

**费用**：公开仓库免费（本仓是 public），私有仓库没有免费档。

**安装**：给 `coderabbitai` 这个 GitHub App 授权本仓 ——
打开 <https://github.com/apps/coderabbitai/installations/new>，
选 `iuuuuuuuu/sourin`，授权即可（只给这一个仓库，不要给全部）。

**在 PR 里可用的命令**：
```text
@coderabbitai review          重新评审（增量：不重看已评过的提交）
@coderabbitai full review     完整评审（重看所有文件）
@coderabbitai resolve         把它的评论标记为已解决
@coderabbitai configuration   打印当前生效的完整配置
@coderabbitai help            全部命令
```

> ⚠️ 处理评审意见的纪律（写在 CONTRIBUTING.md 里，这里再强调一次）：
> **不许**用「加 ignore 注释」「放宽断言」「删掉那行」来消掉意见。
> 本仓已有一条同类教训 —— 为了让 CI 变绿而放宽断言，等于把缺陷藏进绿里。

**已实测有效**（PR #1；实测 run 的时间戳是 UTC 2026-10-08T23:11Z = 北京时间
2026-10-09 07:11）：CodeRabbit 在 PR 里贴出了 3 条行内意见，
其中一条指出本文档里一处**错误的技术论断**，我按它的指引做了对照实验，
**实测确认它是对的、我写错了**（详见 `.coderabbit.yaml` 里那段「实测读数」）。
这说明它不是只会说「建议优化」的复读机。

---

## 配置说明

> 这一节是本 README 最详细的部分 —— 所有可调项、它们存在哪、怎么手改。

配置分**三层**，从「用户点的」到「系统级的」：

```text
① 界面设置      设置页里能点的开关与滑杆        → ui-prefs.json
② 数据目录文件  源列表 / 订阅 / 同步 / 数据库   → 见「数据目录」一节
③ 环境变量      编译期与运行期的逃生开关        → 进程环境
```

### ① 界面设置（`ui-prefs.json`）

全部偏好都是**扁平键值对**，存在 `<数据目录>/ui-prefs.json`。
文件不存在 / 损坏时**降级为空偏好**（不会让应用起不来）。

#### 外观

| 键 | 取值 | 默认 | 说明 |
|---|---|---|---|
| `dsh.theme` | `system` / `light` / `dark` | `system` | 跟随系统 / 浅色 / 深色 |
| `dsh.pageTransition` | `slideRight` / `fade` / `slideUp` / `zoom` / `fadeUp` / `none` | `slideRight` | 页面切换动画风格 |
| `dsh.homeSource` | 源 id | 空 | 首页默认站点 |

#### 窗口

| 键 | 取值 | 说明 |
|---|---|---|
| `dsh.window.bounds` | `x,y,w,h` | 上次的窗口位置与大小。**会自动夹进显示器工作区**（扣掉任务栏）—— 换分辨率 / 拔掉副屏后不会跑到屏幕外 |
| `dsh.closeAction` | `ask` / `tray` / `quit` | 点 X 的行为。`ask` = 每次都问；选过一次之后自动记住 |

#### 播放

| 键 | 取值 | 默认 | 说明 |
|---|---|---|---|
| `dsh.playprefs.lastVolume` | 0 ~ 100 | 95 | 上次的音量 |
| `dsh.playprefs.lastSpeed` | 0.5 ~ 3.0 | 1.0 | 上次的倍速 |
| `dsh.playprefs.endAction` | `none` / `next` / `loop` | — | 播完之后干什么 |
| `dsh.playprefs.countdownBeforeNext` | 秒 | — | 「下一集」倒计时秒数 |
| `dsh.playprefs.keepSourceOnNext` | `0` / `1` | — | 连播时保持当前源（不自动换源） |
| `dsh.playprefs.autoSkip` | `0` / `1` | — | 自动跳过片头片尾 |
| `dsh.playprefs.hwdecMode` | `auto` / `auto-safe` / `no` / … | `auto` | 硬解模式，直接透传给 mpv 的 `hwdec` |
| `dsh.playprefs.videoZoom` | 50 ~ 200 | 100 | 画面缩放百分比 |

> `hwdecMode` 是最常需要手改的一项。播某些老片源花屏 / 黑屏时，改成 `no`（软解）
> 通常能解决 —— 在设置页「播放与下载」里就能切，不用改文件。

#### 下载

| 键 | 取值 | 默认 | 说明 |
|---|---|---|---|
| `dsh.download.concurrency` | 0 ~ 8 | 4 | **片段**下载的并发数（0 = 不限制）。整片下载**不走这个** —— 它固定串行，把带宽留给播放 |
| `dsh.cache.limitMb` | 64 / 128 / 256 / 512 | 256 | 片段缓存上限。超了从**最旧**的开始删 |

> **整片下载不受缓存上限管**。它落在 `视频/源影/<剧名>/`，是你自己的文件，
> 不会被自动淘汰 —— 否则下一集就会把上一集删掉。

#### 弹幕

| 键 | 取值 | 默认 | 说明 |
|---|---|---|---|
| `dsh.danmaku.enabled` | `0` / `1` | 1 | 弹幕总开关 |
| `dsh.danmaku.fontScale` | 见设置页滑杆范围 | — | 字号缩放 |
| `dsh.danmaku.opacity` | 见设置页滑杆范围 | — | 不透明度 |
| `dsh.danmaku.speed` | 见设置页滑杆范围 | — | 滚动速度 |
| `dsh.danmaku.area` | 见设置页滑杆范围 | — | 显示区域（占屏比） |
| `dsh.danmaku.appId` | 字符串 | 空 | 自定义弹幕服务器的 AppId |
| `dsh.danmaku.appSecret` | 字符串 | 空 | 自定义弹幕服务器的 AppSecret |

> ⚠️ **`appId` / `appSecret` 目前是明文存在 `ui-prefs.json` 里**。设置页里也如实
> 写明了这一点。只有你自己填了自定义弹幕服务器才会用到；B 站弹幕走扫码登录的
> cookie，不需要这两项。

#### 字幕

| 键 | 取值 | 默认 | 说明 |
|---|---|---|---|
| `dsh.subtitle.enabled` | `0` / `1` | 1 | 字幕自动加载总开关 |
| `dsh.subtitle.autoLoad` | `0` / `1` | 1 | 播放时自动匹配外挂字幕 |
| `dsh.subtitle.languages` | 逗号分隔 | — | 优先语言（如 `zh,en`） |
| `dsh.subtitle.lastKeyword` | 字符串 | 空 | 上次搜索字幕用的关键词 |
| `dsh.subtitle.attribution` | `0` / `1` | 1 | 是否显示字幕来源标注 |

#### 源偏好

| 键 | 取值 | 说明 |
|---|---|---|
| `dsh.srcpref.<provider>:<id>` | 源 id | 每部剧**单独记住**上次用的源。换源之后下次打开还是那个源 |
| `dsh.bili.*` | — | B 站相关（登录态、自动更新开关与间隔、上次同步时间） |

### ② 数据目录文件

| 文件 | 内容 | 能否手改 |
|---|---|---|
| `ui-prefs.json` | 上面所有界面偏好 | ✅ 改完重启生效 |
| `provider-order.json` | 源列表的顺序 | ✅ 数组顺序 |
| `disabled-providers.json` | 被停用的源 id | ✅ |
| `third-party-providers.json` | 第三方源持久化 | ⚠️ 一般别手改 |
| `tvbox-sources.json` | TVBox 订阅来源（每个源从哪个配置来的） | ✅ 可手填链接 |
| `remote-pref.json` | 手机遥控的开关与端口 | ✅ |
| `sync-settings.json` | WebDAV 云同步配置 | ⚠️ **密码不在这个文件里**（走系统凭据存储） |
| `dsh-media.db` | SQLite：收藏 / 历史 / 进度 / 片头片尾 | ⚠️ 建议只读 |
| `plugins/*.js` | 已安装的插件 | ✅ 见「插件开发」 |
| `plugins/.data/*.json` | 插件的私有数据（如 B 站 cookie） | ⚠️ 含凭据 |
| `logs/` | 运行日志（按天） | ✅ 排查问题看这个 |
| `mpv-cache/` | 播放缓存 | ✅ 可随时删 |
| `clip-cache/` | 片段下载缓存 | ✅ 可随时删（设置页有「清空」） |

### ③ 环境变量

#### 编译期（`--dart-define`）

| 变量 | 说明 |
|---|---|
| `DATA_DIR_OVERRIDE` | 覆盖数据目录。**开发与测试必用** —— 指到临时目录就不会碰到你正在用的真实数据 |

```bash
flutter build windows --release -t lib/shell.dart \
  --dart-define=DATA_DIR_OVERRIDE=D:\tmp\sourin-dev
```

> ⚠️ 这一条很重要：**真实用户数据目录是 `%APPDATA%\app.sourin.player`**，
> 里面有真实的收藏、进度、片头片尾。开发调试时一定要用 `DATA_DIR_OVERRIDE` 隔离，
> 否则一次写探针就可能把用户数据改掉。

#### 运行期（进程环境变量）

| 变量 | 取值 | 说明 |
|---|---|---|
| `SOURIN_DRAG_SELFTEST` | `1` | 启动时跑一次「标题栏拖拽」自检然后退出。结果写到 `%TEMP%\sourin_drag_selftest.txt` |
| `SOURIN_WF_DEPENDS_ON_SIZE` | `0` | 让窗口边框**不**注册尺寸依赖（模拟修复前的行为，用来复现「白角」）。**只用于验证** |
| `SOURIN_NO_REMOTE_AUTOSTART` | 任意 | 不自动启动手机遥控服务 |
| `SOURIN_PREFETCH_DISABLE` | 任意 | 关掉流代理的预取。★ 在**构造** `StreamProxy` 时读一次并存进实例字段（2026-10-08 改）—— 改前是每次请求现读全局，会让并发跑的测试互相干扰（见 `streamproxy.rs` 的 `prefetch_switch_is_per_instance_not_process_global`） |
| `SOURIN_PREFETCH_DEBUG` | 任意 | 打开预取的调试日志 |

> 默认全部**关闭** —— 生产行为与不设这些变量时逐字相同。

---

## 平台支持

| 平台 | 状态 | 说明 |
|---|---|---|
| **Windows 10/11** | ✅ 完整 | 主开发与交付平台 |
| **Android 手机/平板** | ✅ 完整 | arm64 / armv7 / x86_64 |
| **Android TV** | ✅ 完整 | 与手机**同一个 APK**，见下 |
| **macOS** | ✅ 可构建 | 见下（有已知差异） |
| **Linux** | ⚠️ 未适配 | 缺 `linux/` 壳，依赖本身支持 |

### Android TV

**TV 不需要单独的构建** —— 同一个 APK 装上手机是手机版，装上电视是 TV 版：

```text
AndroidManifest.xml 同时声明：
  android.intent.category.LAUNCHER           → 手机/平板桌面图标
  android.intent.category.LEANBACK_LAUNCHER  → Android TV 主界面
  uses-feature android.software.leanback     required=false
  uses-feature android.hardware.touchscreen  required=false  ← 关键
```

> ⚠️ `touchscreen required=false` **不能漏**：电视没有触摸屏，不声明的话
> 应用商店会认为 TV 不兼容。而 `LEANBACK_LAUNCHER` 不能漏是因为——
> **APK 能装到 TV 上，但电视的启动器里根本看不到它**，用户装完找不到应用，
> 等于没装。（实测确认：`aapt dump badging` 里会出现 `leanback-launchable-activity`。）

运行时靠平台通道读系统 feature 判定设备类型（`MainActivity.kt` 的 `sourin/device`）：

```text
leanback          → 设备声明自己是 TV（有遥控器）
touchscreen       → 有没有触摸屏
leanbackOnly      → android.software.leanback_only
```

⇒ UI 自动切 TV 形态：整套字号放大（`AppMetrics.textScaleFor`）、
焦点用方向键移动（`spatial_nav.dart`）、播放器让方向键给选集面板。

构建时`--target-platform` 只影响 CPU 架构，**不影响** TV 能力：

```bash
flutter build apk --release --target-platform android-arm64 -t lib/shell.dart   # 现代电视盒子
flutter build apk --release --target-platform android-armv7 -t lib/shell.dart   # 32 位老盒子
```

### macOS

macOS 是**后加的**平台，可以构建、可以跑，但有两点如实说明的差异：

| | 现状 | 原因 |
|---|---|---|
| **标题栏** | 用系统标题栏，不自绘 | macOS 的红黄绿交通灯是系统约定，自绘会与那 40px 的栏重叠；产品代码里 `kIsDesktop` 包含 macOS，`_CustomTitleBar` 会照画，所以留着系统栏至少保证有可拖动/可关闭的入口 |
| **窗口几何记忆** | 可用 | `window_manager` + `screen_retriever` 都支持 macOS |
| **托盘** | 可用 | `tray_manager` 支持 macOS |
| **字体** | 自动用系统字体 | 主题里按平台选字族：Windows 用雅黑、其它端用 `Noto Sans CJK SC`。macOS 上系统会回退到苹方 —— 这正是「不内置苹果字体」那条约定的收益 |

#### macOS 的权限声明（`*.entitlements`）

**这是 macOS 上最容易踩的坑**。macOS 默认把应用关进 App Sandbox，
没有声明就没有权限 —— 而且症状很有迷惑性：

```text
只声明 network.server  → 应用能启动、界面正常，但一播放就报「无法连接」
                         因为出站请求（拉 m3u8）被沙箱拦了，
                         而入站（本地流代理监听）是通的
```

所以两个 entitlements 文件里都必须有这五项（`DebugProfile` 与 `Release` **同步**）：

```text
app-sandbox                                   沙箱本身（保持开启）
cs.allow-jit                                  Flutter 引擎的 Dart VM
network.client        ★ 出站：拉流 / 插件 HTTP / WebDAV / 弹幕
network.server        ★ 入站：核心层的本地流代理要监听 127.0.0.1
files.user-selected.read-write  外挂字幕 / 导入备份
assets.movies.read-write        整片下载默认落在「视频 / 源影」
```

> ⚠️ **只改一个文件会得到「开发时好的、打包后坏的」** —— 最难查的那类。
> CI 里有一步专门用 `codesign -d --entitlements` 核验产物真的带上了这两项。

#### 构建 macOS

```bash
cd rust/sourin_core && cargo build --release && cd ../..
flutter build macos --release -t lib/shell.dart
# 产物：build/macos/Build/Products/Release/sourin_spike.app
```

> ⚠️ macOS 上 Rust 核心编出的是 `libsourin_core.dylib`，由 `macos/` 的
> Xcode 工程里那个 `Embed Rust Core` 构建阶段拷进
> `sourin_spike.app/Contents/Frameworks/`（与 Windows 的 CMake 拷贝是同一角色）。
> **改完 `ffi.rs` 同样要重编** —— 症状是 `Failed to lookup symbol`。
>
> 这个阶段是**后加的**（2026-10-08）。在那之前 `macos/` 整棵树对
> `sourin_core` **零引用**，产物里根本没有这个 dylib，而 Dart 侧
> `DynamicLibrary.open('libsourin_core.dylib')` 用的是裸文件名 ——
> dlopen 走的是 dyld 搜索路径，**不会**去 `Contents/Frameworks/` 里翻
> （那个目录只对二进制里带 LC_RPATH 的调用方生效，管不到 dart:ffi）。
> 症状是 macOS 版**能启动但所有核心功能不可用**，只剩一个错误页。
> 所以 `lib/core/ffi.dart` 现在先按**包内绝对路径**找，找不到才退回裸名。

> ⚠️ `PRODUCT_NAME` 必须是 ASCII 的 `sourin_spike`：
> `project.pbxproj` 里有 3 处硬引用 `sourin_spike.app`，改中文会让产物名与引用名对不上。
> 用户看到的窗口标题由 Dart 侧的 `WindowOptions(title: '源影')` 决定，与它无关。

---

## 数据目录

按平台自动解析（`lib/shell.dart` 的 `_resolveDataDir()`）：

| 平台 | 路径 |
|---|---|
| Windows | `%APPDATA%\app.sourin.player` |
| Android | 应用私有目录（`path_provider` 的 `getApplicationSupportDirectory()`） |
| macOS | `~/Library/Containers/app.sourin.player/Data/app.sourin.player` |
| Linux | `$HOME/app.sourin.player` |

> Windows 上**与原版 Tauri 用同一个目录** —— 这样从原版迁过来的用户，
> 收藏 / 历史 / 进度 / 插件全都还在。

> ⚠️ **macOS 那行按文档推断，未经真机核实**（本机没有 Mac）——
> 依据是 Apple 的 App Sandbox 文档与微软的 Mac Catalyst 文档都写着
> 「沙箱内 `$HOME` 解析为 `~/Library/Containers/<bundle-id>/Data`」。
> 真机跑一次 `echo $HOME` 就能确认；若实测不是这样，**以实测为准**并回来改这一行。
>
> 它之所以长这样，是因为**沙箱会把 `$HOME` 重定向**：
> 桌面端分支用的是 `Platform.environment['APPDATA'] ?? Platform.environment['HOME']`
>（`lib/shell.dart` 的 `_resolveDataDir()`），而 macOS 版**开着 App Sandbox**
>（`macos/Runner/*.entitlements` 的 `com.apple.security.app-sandbox`）⇒
> `$HOME` 不再是 `/Users/<你>`，而是
> `~/Library/Containers/<bundle-id>/Data`。
> 又因为代码会再拼一层 `app.sourin.player`，所以最终落在
> `Data/app.sourin.player`（目录名重复一层是正常的，不是 bug）。
>
> Linux 上同理：那里没有 `APPDATA`，于是取 `HOME` 直接拼 ——
> **不是** XDG 的 `~/.local/share`。

### 数据目录里都有什么

```text
%APPDATA%\app.sourin.player\
├── dsh-media.db                SQLite：收藏 / 历史 / 进度 / 片头片尾 / 追更
├── dsh-media.db-wal            预写日志（正常，别删）
├── ui-prefs.json               界面偏好（见「配置说明」）
├── provider-order.json         源排序
├── disabled-providers.json     停用的源
├── third-party-providers.json  第三方源
├── tvbox-sources.json          TVBox 订阅来源
├── remote-pref.json            手机遥控配置
├── sync-settings.json          WebDAV 配置（不含密码）
├── themes/                     主题包目录（*.json，见「主题包」）
│   └── *.json                  自定义配色
├── plugins/                    插件目录
│   ├── *.js                    插件源码
│   └── .data/*.json            插件私有数据（含凭据，注意保护）
├── logs/                       按天滚动的日志
├── mpv-cache/                  播放缓存
├── clip-cache/                 片段下载缓存
└── transcode/                  转码临时文件
```

### 备份与恢复

三种方式，按需求选：

| 方式 | 在哪 | 覆盖范围 |
|---|---|---|
| **应用内导出 / 导入** | 设置 → 备份与恢复 | 收藏 / 历史 / 进度 / 源 / 插件 / 偏好（**合并不覆盖**） |
| **WebDAV 云同步** | 设置 → 云同步 | 同上，多设备 |
| **手动拷目录** | 直接复制整个 `app.sourin.player` | 全部（含缓存） |

> **导入是合并语义，不覆盖**。同一个源 / 同一条收藏已存在时保留**较新**的那份 ——
> 所以「导入旧备份」不会把你现在的进度退回去。

---

## 主题包

主题包是**一个 JSON 文件**，描述一套配色。放进数据目录下的 `themes/`
就会自动出现在「设置 → 主题 → 配色」里；也可以在那一页直接
**从文件导入**或**粘贴 JSON**。切换即时生效，不需要重启。

> 这一节对应 Owner 的一条需求：「主题如果可以做多主题就是外部插件式
> 或者之类的，能做的话就做一下」。

### 「明暗」与「配色」是两件独立的事

主题页分成两个区块，这不是为了凑成两个下拉框：

| 区块 | 管什么 | 可选值 |
|---|---|---|
| **明暗** | 这个界面是亮底还是暗底 | 跟随系统 / 浅色 / 深色 |
| **配色** | 这个界面的具体颜色 | 午夜 / 日间 / OLED 纯黑 / 深海蓝 / 樱粉 / 森绿 / 你的自定义 |

所以「深色 + 樱粉」是合法的组合。**没有选配色时**完全退回原来的
三态明暗行为（兼容旧偏好 `dsh.theme`）。

> 播放器画面区域**始终深色**，不跟主题变 —— 亮色画面适配是 mpv 侧的
> 另一套逻辑，与主题无关。

### 最小主题包

```json
{
  "name": "我的暗夜",
  "brightness": "dark",
  "colors": {
    "primary": "#8ED9A8"
  }
}
```

只有三行也是合法的：**没写的字段一律用默认值**（深色主题的默认色板）。
应用不会因为你少写了字段而拒绝它。

### 全部字段

```json
{
  "version": 1,
  "id": "my-theme",
  "name": "我的暗夜",
  "brightness": "dark",

  "colors": {
    "background":       "#0A0A0A",
    "surface":          "#171717",
    "foreground":       "#FAFAFA",
    "mutedForeground":  "#A1A1A1",
    "primary":          "#E5E5E5",
    "onPrimary":        "#171717",
    "secondary":        "#262626",
    "border":           "#1AFFFFFF",
    "error":            "#FF6467"
  },

  "radius": 12,
  "buttonPadding": { "horizontal": 10, "vertical": 11 }
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `version` | 整数 | 格式版本，当前是 `1`。写成更大的值**也能用**，只是未知字段会被忽略并给一条提示 |
| `id` | 字符串 | 唯一标识。**省略时用文件名**（去掉 `.json`） |
| `name` | 字符串 | 主题页上显示的名字。省略时叫「导入的主题」 |
| `brightness` | `"dark"` \| `"light"` \| `"system"` | 省略 `system` 时按 `colors.background` 的亮度自动推断 |
| `colors.*` | `#RGB` \| `#RRGGBB` \| `#AARRGGBB` | 颜色。`#RGB` 的简写**不支持**，请写全 |
| `radius` | 0–40 | 控件圆角。省略 = 10 |
| `buttonPadding` | 对象 | 按钮内边距，`horizontal` / `vertical` 都要给 |

`colors` 里的角色对应关系：

| 角色 | 用在哪 |
|---|---|
| `background` | 页面底色 |
| `surface` | 卡片 / 弹窗 / 提示条的底 |
| `foreground` | 正文 |
| `mutedForeground` | 次要文字（说明、时间戳） |
| `primary` | 选中态、开关、滑杆、进度、主按钮底 |
| `onPrimary` | 主色之上的文字（图标与文字） |
| `secondary` | 次级填充面 |
| `border` | 描边。**可以带 alpha**（写 `#1AFFFFFF` 就是白 10%） |
| `error` | 错误提示 |

### 写坏了会怎样

**不会让应用起不来。** 这是这个功能最重要的一条性质，所以它是被测试
守着的（`test/theme_pack_test.dart`）：

| 你写错了 | 发生什么 |
|---|---|
| JSON 语法错误 | 该文件**不出现在列表里**，日志里一行说明。手动导入时会提示 |
| 少了几个颜色 | 其余用默认值，**已写的照常生效** |
| 颜色值是 `#GGGGGG` / `not-a-color` | **那一个**字段回落默认，并提示是哪个字段 |
| `radius` 是 9999 | 忽略（圆角会画出整屏），并提示 |
| `buttonPadding` 只写一半 | 整项忽略，并提示 |
| `version` 比应用新 | 仍能用，未知字段忽略，并提示 |
| `brightness` 拼错 | 按 `colors.background` 的亮度推断，并提示 |

主题页里也会把警告原文显示出来 —— 一份「导入成功但有 N 处被忽略」
比一句「导入成功」诚实得多：你不会以为每个字段都按你写的生效了。

### 对比度

内置的每一套主题都按 WCAG 校验过（`test/theme_pack_test.dart` 逐套断言）：

| 角色 | 阈值 |
|---|---|
| 正文 | ≥ 4.5:1 |
| 次要文字 | ≥ 3:1 |
| 主色按钮（文字 vs 底） | ≥ 4.5:1 |

⚠️ **自己写主题包时**：如果正文压到 4.5:1 以下，在电视和手机远距离
上会明显看不清。可以自己量一下（取两个色的相对亮度再按
`(亮+0.05)/(暗+0.05)` 算），或者从内置主题改起 —— 内置的那几套都过线。

### 删除

主题卡片右上角的 ✕ 删掉的是**文件本身**（内置主题没有 ✕，删不掉）。

---

## 插件开发

插件是**一个 JS 文件**，跑在 Rust 侧的 QuickJS 沙箱里。

> **配套仓库**：[sourin-app/sourin-plugins](https://github.com/sourin-app/sourin-plugins) ——
> 作者自用的源、完整的插件 API 契约（`docs/API.md`）与可运行示例（`examples/demo.js`）。
> 本节的契约以**那个仓库的 `docs/API.md`** 为最新准。
> 那个仓库是**公开仓库**（无需任何权限即可访问与克隆）。

### 最小插件

```javascript
globalThis.plugin = {
  id: 'my-source',
  name: '我的源',
  version: '1.0.0',

  capabilities: {
    vod: true,      // 点播
    search: true,   // 搜索
    live: false,    // 直播
    loginRequired: false,
  },

  // 首页分类（可选）
  categories: [
    { id: '1', name: '电影', pid: null },
    { id: '2', name: '电视剧', pid: null },
  ],

  // 分类列表
  async category({ categoryId, page }) {
    const r = await host.http.get(
      'https://example.com/api?ac=list&t=' + categoryId + '&pg=' + page
    );
    const data = JSON.parse(r);
    return {
      items: data.list.map((it) => ({
        id: String(it.vod_id),
        title: it.vod_name,
        cover: it.vod_pic,
        remark: it.vod_remarks,
      })),
      hasMore: page < 10,
    };
  },

  // 详情
  async detail({ id }) {
    const r = await host.http.get('https://example.com/api?ac=detail&ids=' + id);
    const it = JSON.parse(r).list[0];
    return {
      id: String(it.vod_id),
      title: it.vod_name,
      cover: it.vod_pic,
      description: it.vod_content,
      episodes: it.vod_play_url.split('#').map((seg, i) => {
        const parts = seg.split('$');
        return { id: String(i + 1), title: parts[0], url: parts[1] };
      }),
    };
  },

  // 播放地址
  async play({ id, episodeId }) {
    // 返回候选列表，播放器会挑第一个能播的
    return [
      { url: 'https://example.com/play/' + id + '/' + episodeId + '.m3u8', label: '默认' },
    ];
  },
};
```

### 可用的 host API

| API | 说明 |
|---|---|
| `host.http.get(url, opts)` | GET，返回**响应体字符串** |
| `host.http.post(url, body, opts)` | POST |
| `host.http.raw(url, opts)` | 返回 `{status, body, headers}` —— **需要读响应头时用这个** |
| `host.log(msg)` | 写进应用日志 |
| `host.cache.*` | 插件私有缓存（落在 `plugins/.data/`） |

> `opts` 支持 `headers`（对象）。同名头只保留**第一个**。

### 安装插件

三个入口，都在 设置 → 内容源：

| 入口 | 用途 |
|---|---|
| **粘贴源码安装** | 直接把上面的 JS 贴进去 |
| **从网址安装** | 填一个 `.js` 的 URL，自动下载 |
| **导入源 → TVBox 配置** | 填 TVBox 的配置**地址或 JSON**，内部解析成源 |

> **TVBox 不需要转换成脚本**。核心层直接解析 TVBox 配置的 `sites` 段，
> 把 `type: 1`（苹果 CMS）的站点建成内容源。所以配置作者更新了配置，
> 你在应用里点「检测更新 → 应用更新」就行，**不用重新转换、不用重装**。

---

## 测试

### 跑测试

```bash
# Dart 侧（205 个文件 / 约 6.7 万行）
flutter test

# Rust 侧（21 个文件 / 约 6.3 千行）
cd rust/sourin_core && cargo test
```

### 关于 native-media 标签

有一批测试会调 `MediaKit.ensureInitialized()`（真加载 libmpv）。
libmpv 在 `flutter_tester` 里**偶发原生崩溃**（第三方库的问题，改不了源码），
所以它们在 `dart_test.yaml` 里被标记为**默认跳过**。

要跑它们：

```bash
flutter test --run-skipped --tags native-media --concurrency=1
```

> ⚠️ `--concurrency=1` **不能**完全避免崩溃（实测串行 8 次里也红 5 次）。
> 它只是让输出更易读。

### 测试纪律

这个项目的测试有两个不寻常的要求，写在多处测试的文件头：

```text
① ★ 判据必须能测出**反面**
   一条永远为真的断言比没有断言更危险。所以关键测试都配「红度证明」：
   把修复代码改回缺陷写法，断言**必须**变红。测不出反面的结论作废。

② ★ 区分「测试环境错」和「产品 bug」
   同一条断言失败时，先问「是我的仪器错了吗」。
   本项目因此推翻过两次自己的根因（都记在对应测试的文件头）。
```

---

## 常见问题

<details>
<summary><b>HEVC / AC3 / DTS 播不了，只有声音没画面</b></summary>

Flutter 版用 libmpv，**自带 FFmpeg**，理论上都支持。如果遇到黑屏：

1. 设置 → 播放与下载 → 把「硬解模式」改成 `no`（软解）试试；
2. 看 `logs/` 里的日志，搜 `[PLAY]`；
3. 部分源是 DRM 加密的（尤其央视），**只有音频能播** —— 这种情况界面会明确提示
   「仅音频可播」，不是 bug。

</details>

<details>
<summary><b>改了 Rust 代码但行为没变</b></summary>

90% 是 CMake 没拷贝新的 `.dll`（它按时间戳判断）：

```powershell
# 直接删掉目标文件强制重拷
Remove-Item windows\sourin_core.dll -ErrorAction SilentlyContinue
flutter build windows --release -t lib/shell.dart
```

Android 侧同理 —— `jniLibs/*/libsourin_core.so` 是**手动拷贝**的，见
「从源码构建 → 5. Android 的 Rust 交叉编译」。

</details>

<details>
<summary><b>Android 上所有操作都超时</b></summary>

看 logcat 里有没有：

```text
[SHELL] ★ 核心启动失败: Failed to lookup symbol 'sourin_call_stream'
```

有的话是 `jniLibs` 里的 `.so` 太旧（改完 `ffi.rs` 没重编那个 ABI）。
重编三个 target 并重新拷贝即可。

</details>

<details>
<summary><b>开发时怎么不碰到我正在用的数据</b></summary>

**务必**用 `DATA_DIR_OVERRIDE` 指到临时目录：

```bash
flutter run --dart-define=DATA_DIR_OVERRIDE=D:\tmp\sourin-dev
```

默认数据目录里有你真实的收藏、进度、片头片尾 —— 一次写探针就可能改掉。

</details>

<details>
<summary><b>窗口跑到屏幕外面了 / 换显示器后不见了</b></summary>

窗口几何会自动夹进显示器工作区。如果还是不对，删掉这一行再启动：

```json
// <数据目录>/ui-prefs.json
"dsh.window.bounds": "571,159,1444,845"   <- 删掉整行
```

</details>

<details>
<summary><b>点 X 直接退出了，我想让它最小化到托盘</b></summary>

设置 → 通用 → 「关闭行为」，或者删掉 `ui-prefs.json` 里的 `dsh.closeAction`
让它重新问一次。

</details>

---

## 项目结构

```text
sourin/
├── lib/                      Flutter 侧（135 文件 / 约 9.7 万行）
│   ├── shell.dart            应用外壳：标题栏 / tab / 保活 / 窗口
│   ├── main.dart             ⚠️ 早期 HEVC 验收 spike，**不是产品入口**
│   ├── core/                 FFI 绑定、API、偏好、下载器、弹幕、字幕
│   │   ├── ffi.dart            Dart 侧 FFI 绑定
│   │   ├── sourin_api.dart     所有命令的 Dart 封装
│   │   ├── ui_prefs.dart       偏好读写
│   │   ├── clip_download.dart  片段下载 + 缓存淘汰
│   │   ├── hls_download.dart   HLS 整片下载（分片拼接）
│   │   ├── download_dir.dart   下载目录解析（按组存放）
│   │   ├── download_queue.dart 整片下载串行队列
│   │   ├── app_tray.dart       托盘 + 关闭确认
│   │   └── bili/ danmaku.dart  B 站与弹幕
│   └── ui/                   UI 页面与组件
│       ├── player_page.dart    播放页（最大单文件，约 65 万字节）
│       ├── detail_page.dart    详情页
│       ├── live_page.dart      直播页
│       ├── settings_page.dart  设置
│       ├── tokens.dart         设计令牌（间距 / 字号 / 字重 / 动效）
│       └── widgets/            复用组件
├── rust/sourin_core/         Rust 核心（31 文件 / 约 3.4 万行）
│   ├── src/ffi.rs             C ABI 导出（7 个符号）
│   ├── src/registry.rs        源注册表
│   ├── src/plugins/mod.rs     QuickJS 插件沙箱
│   ├── src/streamproxy.rs     本地流代理
│   ├── src/store.rs           SQLite
│   ├── src/tvbox.rs           TVBox 配置解析
│   ├── src/sync/              WebDAV 云同步
│   ├── src/remote/            手机遥控
│   ├── plugins/*.js           内置插件（include_str! 编进二进制）
│   └── tests/                 21 个集成测试
├── test/                     Dart 测试（205 文件 / 约 6.7 万行）
├── android/                  Android 壳 + jniLibs
├── windows/                  Windows 壳（含自绘窗口的 C++ 实现）
├── assets/                   托盘图标等资源
└── .github/workflows/        CI
```

---

## 致谢

- [media_kit](https://github.com/media-kit/media-kit) —— 播放内核
- [forui](https://github.com/duobaseio/forui) —— 桌面风格组件库
- [liquid_glass_widgets](https://pub.dev/packages/liquid_glass_widgets) —— 玻璃拟态
- [rquickjs](https://github.com/DelSkayn/rquickjs) —— 插件沙箱
- [iptv-org](https://github.com/iptv-org/iptv) —— IPTV 频道表

---

## 免责声明

本项目**不提供、不托管、不分发任何影视内容**。它只是一个聚合客户端 ——
所有内容都来自用户自己配置的第三方数据源，播放地址由那些源提供。

请在你所在地区法律法规允许的范围内使用。

---

## 许可证

[MIT](LICENSE)
