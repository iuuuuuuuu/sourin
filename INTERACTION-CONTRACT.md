# 源影 Flutter 重写 —— 交互契约（必须逐条对齐）

> **来源**：从现有 Tauri/Vue 版源码**逐一提取**（不是回忆、不是推测）。
> 每一项都标了源文件与行号，便于核对。
>
> **Owner 的要求（2026-09-22 原话）**：
> 「操作逻辑都还要原来的保持一样的」
>
> 所以这份文档是**验收基准**：Flutter 版的每个交互都要能对应到这里某一条。
> 任何**有意的**差异都必须先跟 Owner 确认，不能自己决定。

---

## 一、导航骨架

### 1.1 路由表

源：`src/router.ts`

| # | path | name | 说明 |
|---|---|---|---|
| 1 | `/` | home | 发现（首页） |
| 2 | `/live` | live | 直播 |
| 3 | `/follow` | follow | 追更 |
| 4 | `/browse` | browse | 浏览（**隐藏底栏**） |
| 5 | `/search` | search | 搜索 |
| 6 | `/settings` | settings | 设置 |
| 7 | `/detail/:provider/:id` | detail | 详情（**隐藏底栏**） |
| 8 | `/play` | play | 播放（**保留底栏与标题栏**） |
| 9 | `/:pathMatch(.*)*` | — | 兜底 |

⚠️ 关于 `/play`：源码注释明确写了两条需求——
```text
① 「播放不应该默认全屏」
② 右侧要能选集 / 换线路 / 调清晰度
③ 同时保留底栏与标题栏
```

### 1.2 底栏 5 个入口

源：`src/App.vue` L79–109

```
顺序（这个顺序有语义，见 1.3）：
  1. home      发现   /
  2. live      直播   /live
  3. follow    追更   /follow     ← 带 badge = store.unreadCount
  4. search    搜索   /search
  5. settings  设置   /settings
```

### 1.3 页面切换动画方向

源：`src/App.vue` L41–45

```text
按 tab 顺序判断方向（发现 → 直播 → 追更 → 搜索 → 设置）：
  · 往后切（发现 → 直播）→ 新页面【从右】进（+24px）
  · 往前切（直播 → 发现）→ 新页面【从左】进（-24px）
  · 跳着切（发现 → 设置）→ 按同一规则算，方向仍合理
```
★ Flutter 版必须复现这个「按 tab 序号定方向」的行为，不能简单用默认转场。

### 1.4 隐藏底栏的页面

源：`src/App.vue` L112–114

```dart
// 原版：
const hideTabBar = computed(() => route.name === "detail" || route.name === "browse");
```
即：**只有 detail 和 browse 隐藏底栏**，其它页面（含 play）都显示。

---

## 二、TV / 遥控器行为（必须在 Flutter 版保留）

源：`src/App.vue` L469–477（注释里记录了**真机实测**）

```text
实测发现（TV 真机，adb 方向键）——
「发现 / 直播 / 追更 / 搜索 / 设置」，TV 上等于困死在一个页面。
```

这意味着 Flutter 版必须：
- 支持**方向键 / 遥控器**在底栏 5 个入口间移动
- 焦点可见（TV 上没有鼠标悬停）
- 与 `src/design/device.ts` 的判定一致：
  ```text
  TV 判据 = UA 含 TV 标志词，或 (!hover && fine && !coarse)
  ⚠️ 不能靠 pointer: coarse 判 TV（真机是 coarse=false）
  ⚠️ 不能靠 UA 是否含 Mobile（TV 的 UA 含 Mobile）
  ```

---

## 三、遥控（局域网用手机控制）

源：`src/App.vue` L118–190、L261–283

```text
★ 关键设计（源码注释明确）：
搜索与首页浏览在【任何页面】都能用 —— 不能只在播放页注册。
原来的 bug：遥控的搜索/发现只在点开视频后才存在 →
           用户在首页 → 手机发搜索 → 没有桥 → 永远「搜索中…」超时
```

必须保留的能力：
- 手机发**搜索**命令 → 任意页面都能响应
- 手机从搜索结果**点进条目** → 打开详情
- 打开条目时可带 `title`（让播放页先显示标题，避免闪烁）

---

## 四、播放器交互

源：`src/views/PlayerView.vue`（4775 行 —— 最大的文件）

⚠️ 这是重写工作量最集中的地方，需要单独逐条梳理。
已知必须保留的（来自记忆与源码注释）：

| 行为 | 细节 |
|---|---|
| 换线路 | `switchUrl` 重建 hls；`art.url` setter 触发 `customType` |
| 续看定位 | `switchUrl` 会把 currentTime 重置为 0，且 `handlers.metadata` 会再覆盖一次 → **重开后的定位必须晚于它** |
| 片头片尾 | `skip_markers` 表；用户可设置 |
| 进度上报 | 写 `progress` 表 |
| 选集 / 换源 / 清晰度 | 右侧面板 |

**待办**：把 PlayerView 的交互逐条提取成清单（下一轮做）。

---

## 五、UI 技术选型（已定）

| 项 | 决定 | 依据 |
|---|---|---|
| 播放内核 | **media_kit**（libmpv） | 实测 HEVC 硬解成功：`hwdec-current = "d3d11va-copy"` |
| UI 库 | **forui** | 实测跑通并截图；Release 压缩后 20.91 MB（无 UI 库 19.46 MB，**只多 1.45 MB**） |
| Flutter | **3.47.5** | forui / shadcn_flutter 都要求 ≥3.47 |

---

## 六、已实测的硬指标（2026-09-22）

在 `D:\WishProject\sourin-flutter-spike` 上跑出来的一手数据：

| 指标 | Windows | Android (BlueStacks) |
|---|---|---|
| HEVC 解码 | ✅ **硬件** `hwdec-current = "d3d11va-copy"` | ✅ 软件解码成功，画面正常 |
| 分辨率识别 | ✅ 1920×1080 | ✅ 1280×720 |
| 视频跟随滚动 | ✅ 滚动 640px，画面跟着走 | ✅（同一份 Dart 代码） |
| Release 体积 | ✅ 20.91 MB（含 forui） | APK 57.3 MB（单 x86_64，debug 符号未剥） |
| 可运行 | ✅ 进程存活 + 截图见画面 | ✅ 截图见画面 |

### ★ 跨平台踩到的四个真坑（都已解决）

这些是「一套代码多端」的实际成本，记录在此避免重踩：

| # | 症状 | 根因 | 解法 |
|---|---|---|---|
| 1 | Android **纯白屏**，无 Dart 异常 | `window_manager` 是**桌面专用**插件，`ensureInitialized()` 在 Android 上 await 不返回 → `runApp` 执行不到 | 用 `Platform.isWindows/isMacOS/isLinux` 分支 |
| 2 | Android 白屏（debug 构建） | `Could not create root isolate` —— debug 的 63MB `kernel_blob.bin` 在 BlueStacks 上准备 isolate 失败 | **用 release 构建测 Android** |
| 3 | `Permission denied` 打不开文件 | 未在 manifest 声明存储权限 | 加 `READ/WRITE_EXTERNAL_STORAGE` + `INTERNET` |
| 4 | `Could not open codec` | media_kit 的 `PlayerConfiguration` **没有 hwdec 字段**，Android 上默认不开硬解 | Player 创建后 `NativePlayer.setProperty('hwdec','auto-safe')` |

### 各平台硬解后端（必须知道）

```text
Windows  → d3d11va        （实测生效）
Android  → mediacodec     （libmpv 二进制已确认含 ff_hevc_mediacodec_decoder）
macOS    → videotoolbox
Linux    → vaapi / nvdec
```

⚠️ **BlueStacks 测不出 Android 硬解**：它只有 `OMX.google.hevc.decoder` /
`OMX.ffmpeg.hevc.decoder`（都是软件），没有厂商硬件解码器。
所以硬解这条**必须真机验证** —— 但 Android CDD **强制要求** HEVC 硬解，
真机/真盒子都有。

体积明细（Windows Release，未压缩 76.21 MB）：
```text
libmpv-2.dll        28.39 MB   播放内核
flutter_windows.dll 20.29 MB   Flutter 引擎
libGLESv2.dll        7.07 MB   ANGLE
app.so               6.09 MB   Dart AOT
d3dcompiler_47.dll   4.66 MB
vk_swiftshader.dll   4.59 MB
Inter 字体 x2        1.69 MB   ← forui 带的
```

---

## 七、待办（按优先级）

1. **提取 PlayerView 的完整交互清单** —— 4775 行，必须逐条对齐
2. **实测弱 TV 上的性能** —— BlueStacks 代表不了（跑在 Ryzen 9 上）
3. **确定 Rust 核心复用方案** —— 12,809 行（81%）如何接进 Flutter
4. **处理 git checkout 丢失的改动** —— `streamproxy.rs` 少约 836 行、`lib.rs` 少约 746 行
5. **forui 在 Android 上的渲染验证** —— 目前只验证了纯 Flutter 能渲染
