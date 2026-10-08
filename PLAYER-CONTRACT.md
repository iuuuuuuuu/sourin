# PlayerView 交互契约 —— Flutter 重写的验收基准

> **来源**：`cctv_to_client/src/views/PlayerView.vue`（4775 行 script + 518 行 template）
> 逐段读取提取，**每个条目都带源码行号**便于核对。
>
> **Owner 的硬要求（2026-09-22 原话）**：
> 「操作逻辑都还要原来的保持一样的」
>
> 所以这份文档是**验收清单**：Flutter 版每个交互都要能对应到这里某一条。
> **任何有意的差异都必须先跟 Owner 确认。**

---

## 一、播放器生命周期与状态

### 1.1 状态流转

```text
idle → resolving（解析线路）→ loading（起播中）→ playing ⇄ paused
                                    ↓
                              error / 降级提示
                                    ↓
                                 ended → 下一集倒计时
```

源码里的状态变量：`loading`(L219 watch) · `error` · `buffering`(L281–290) ·
`hevcTranscoded`(L4251) · `nextCountdown`(L2728–2736)

### 1.2 加载看门狗（★ 非显而易见）

源：`L195–270`

```text
startLoadWatch()        开始计时
armLoadWatchdog()       起播超过阈值未出画面 → 判定失败
disarmLoadWatchdog()    出画面后撤掉
onFirstFrame()          canplay 时调用（L229）
```

UI 表现（`L4205–4230`）：
```text
loading && !error        → 转圈 + 加载文案
loadSecs >= 6            → 追加提示（L4222）
```

### 1.3 缓冲提示（与 loading 区分）

源：`L281–290`、`L3661–3667`

```text
video:waiting  → startBufferWatch()   （仅在「已经能播」时，即 !loading && !error）
video:playing  → stopBufferWatch()
video:canplay  → stopBufferWatch()
video:error    → stopBufferWatch()
```
UI（`L4234–4237`）：`正在缓冲… {{ bufferSecs }}s`，`bufferSecs >= 8` 时追加提示

---

## 二、键盘快捷键（★ 重写最易漏）

### 2.1 ArtPlayer 内置的 6 个

源：`L3580–3582`（注释里记录了读源码的结论）

```text
Space    播放/暂停
← →      快退/快进（±5 秒）
↑ ↓      音量
Escape   退出网页全屏
```

### 2.2 项目自己补的（`hk.add(code, fn)`，`L3593–3647`）

| 键 | `event.code` | 行为 | 行号 |
|---|---|---|---|
| M | `KeyM` | 静音切换 + 提示「已静音/已取消静音」 | L3595 |
| F | `KeyF` | 全屏切换 | L3602 |
| P | `KeyP` | 画中画（用 ArtPlayer 内置 pip） | L3606 |
| J | `KeyJ` | 后退 10 秒 | L3613 |
| L | `KeyL` | 前进 10 秒 | L3616 |
| , | `Comma` | 降速（步进表见下） | L3631 |
| . | `Period` | 加速 | L3632 |
| N | `KeyN` | 下一集 | L3635 |
| 0–9 | `Digit0`–`Digit9` | 跳到 0%–90% | L3640–3646 |

**倍速步进表**（`L3624`，必须一致）：
```dart
const steps = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];
```
⚠️ 细节：找不到当前值时**默认从索引 2（即 1x）出发**（`L3626` 的 `i < 0 ? 2 : i`）。
倍速会记住：`prefs.lastSpeed`，并在 `loadedmetadata` 时恢复（`L3652`）。

⚠️ 数字键跳转**在直播时无效**（`isLive` 判断，`L3643`）。

### 2.3 ★ 焦点陷阱（必须复现的体验问题）

源：`L3552–3575`

```text
ArtPlayer 的 hotkey 有个前置条件：art.isFocus 必须为 true，
而它只在 document 的 click/contextmenu 落在播放器内时才置位。

实测：
  · 不点击直接按 →/空格 → 完全无反应
  · 点一下播放器后再按 → 全部正常

解决：进入页面自动聚焦一次（dispatchEvent click on art.template.$player）
      ⚠️ 只自动聚焦**首次** —— 用户点去右侧选集栏后不该被抢回来
      兜底：ready 事件 + 1200ms 定时器各试一次
```

★ Flutter 版要让快捷键**开箱即用**，不能有"要先点一下"的问题。

### 2.4 `event.code` 而不是 `event.key`

源：`L3590–3591` —— 逗号是 `Comma`、句号是 `Period`、数字是 `Digit5`。
Flutter 里对应 `LogicalKeyboardKey`，映射要逐一对齐。

---

## 三、鼠标 / 触摸手势

### 3.1 ★ 桌面端手势必须自己补

源：`L3693–3698`

```text
ArtPlayer 内置手势**只在移动端生效**：
  gestureInit(art, events) { if (isMobile && !art.option.isLive) {...} }
→ 桌面端双击快进与滚轮音量都没有（实测确认无效果）
```

| 手势 | 行为 | 行号 |
|---|---|---|
| 双击左 1/3 | 后退 10 秒 + 提示「◀◀ 后退 10 秒」 | L3709–3716 |
| 双击右 1/3 | 前进 10 秒 | L3716+ |
| 双击中间 | **不处理** | L3704 |
| 滚轮 | 调音量 + **阻止默认滚动** | L3722+ |

⚠️ 用原生 `dblclick` 而不是自己防抖两次 click —— 否则与 ArtPlayer 的单击播放/暂停打架（`L3700–3703`）。

---

## 四、线路 / 剧集 / 清晰度

| 功能 | 函数 | 行号 |
|---|---|---|
| 解析线路 | `resolveStreams()` | L1822 |
| 开始播放 | `startPlayback(stream)` | L1442 |
| 切换线路 | `switchStream(st)` | L2839 |
| 打开换源面板 | `openSwitchSource()` | L2907 |
| 选源回调 | `onSwitchSourcePick()` | L2916 |
| 切平台/源 | `pickSource(code)` | L2811 |
| 跳集 | `gotoEpisode(ep)` | L2789 |

### ⚠️ 线路名的显示规则（易漏）

```text
streamName(s)     L127   显示名
showStreamTag(s)  L146   是否显示标签
isDrm(s)          L154   ★ DRM 检测 —— 有独立的降级 UI！
```
DRM 的 UI：`L4281–4300`（`showDrmHelp`），带「返回」按钮。

---

## 五、进度与续看

| 功能 | 行号 |
|---|---|
| 开始进度上报 | `startProgressWatch()` L613 |
| 停止 | `stopProgressWatch()` L718 |
| 立即上报 | `reportProgress(immediate)` L2044 |
| 位置快照 | `snapshotPosition()` L2028 |
| 准备续看 | `prepareResume()` L1951 |
| 应用真实时长 | `applyRealDuration(secs)` L686 |

★ 记忆里已记录的坑（必须遵守）：
```text
· switchUrl 会把 currentTime 重置为 0
· handlers.metadata 会在 loadedmetadata **再覆盖一次**位置
→ 重开后的定位必须晚于它
```

---

## 六、片头片尾跳过

| 功能 | 行号 |
|---|---|
| 加载标记 | `loadSkipMarker()` L2296 |
| 自动记录 | `maybeRememberSkip()` L2360 |
| 保存 | `saveSkip()` L2409 |
| 应用 | `applySkipMarkers()` L2462 |
| 片尾自动跳 | `maybeSkipOutro()` L2552 |
| 清除本集标记 | `clearSkipOfThis()` L2635 |
| 打开设置弹窗 | `openSkipDialog()` L2663 |
| 拖动回调 | `onSkipSeek(pos)` L2684 |
| 保存回调 | `onSkipSave(payload)` L2692 |

### ★★ 一个真 bug 的修复（必须保留）

源：`L3672–3688`

```text
applySkipMarkers 从 loadedmetadata 调用时，readyState = 1（只有元数据，**还不可 seek**）
→ 设 currentTime 会「看起来成功却被后续加载重置回 0」（实测确认）

而 canplay 时 readyState >= 3，**真正可以 seek**
→ 所以 canplay 里**再调一次**

幂等由 introSkippedForThisLoad 保证
```

**Flutter 版必须复现这个「两次调用」的行为**，否则片头跳过会失效。

---

## 七、多音轨（外挂音频）

源：`L1174–1350`

```text
teardownAudioTrack()   L1174
attachAudioTrack(url)  L1197
mirrorPlay/Pause/Seek  L1223–1237   把音频轨与视频轨同步
syncAudioTime(force)   L1296
```
用途：某些源视频轨是 HEVC 但音轨要单独拉（`audioOnlyStreams`，见 `L4296`）。

---

## 八、HEVC 相关的历史 UI（换 media_kit 后可简化）

源：`L393–613`、`L1034–1046`

```text
resetHevcProbe()      L393
canPlayHevc()         L398   canPlayType 探测
probeCodec(url)       L458   判断是 h264 还是 hevc
openHevcStore()       L1034  打开微软商店装扩展
retryAfterInstall()   L1046
showHevcHelp          L4267  提示 UI：「去安装 HEVC 扩展」/「我已安装，重试」
```

★ **这一整块在 Flutter 版里可以删掉** —— media_kit 自带 FFmpeg，不需要
用户装扩展。但**删之前要跟 Owner 确认**（属于"操作逻辑变化"）。

---

## 九、转码（HEVC→H.264）

源：`L784–934`

```text
scheduleReseekTranscode(secs)  L784
doReseekTranscode(secs)        L798
stopTranscode()                L896
tryTranscode(...)              L934
```
UI：`hevcTranscoded` 指示（`L4251–4252`）

★ 同样可以删（media_kit 直接播 HEVC），但需确认。

---

## 十、下一集倒计时

源：`L2728–2748`、`L2789`

```text
cancelNextCountdown()  L2728
startNextCountdown()   L2736
onEnded()              L2748   播完触发
```
UI（`L4313–4320`）：
```text
「即将播放下一集」+ 倒计时数字 + 「立即播放」按钮
```

---

## 十一、局域网遥控

源：`L3016–3343`

```text
buildRemoteState()  L3016   把播放状态给手机端
execRemote(cmd)     L3091   执行手机发来的命令
```
★ 契约文档（INTERACTION-CONTRACT.md §三）里已记：
**搜索与首页浏览在任何页面都要能用**，不能只在播放页注册。

---

## 十二、布局

模板结构（`L4165–4683`）：

```text
.watch
 ├── .main-col
 │    └── .stage
 │         ├── .artwrap            L4193  播放器挂载点
 │         ├── .stage__overlay     L4205  加载中
 │         ├── .stage__overlay--soft L4234 缓冲中
 │         ├── .stage__transcode   L4251  转码指示
 │         ├── .stage__overlay     L4262  错误
 │         └── .stage__help        L4267  HEVC/DRM 帮助
 └── （右侧面板：选集 / 换源 / 清晰度）
```

★ 需求明确：**播放不默认全屏**，右侧能选集/换线路/调清晰度，
**同时保留底栏与标题栏**（见 INTERACTION-CONTRACT.md §1.1）。

---

## 十三、重写风险清单（按危险度排序）

| # | 风险 | 为什么危险 | 对策 |
|---|---|---|---|
| 1 | **canplay 二次调 applySkipMarkers** | 只调一次会导致片头跳过静默失效，且不报错 | 在 Flutter 里也监听"可 seek"时机 |
| 2 | **快捷键焦点** | Flutter 没有 ArtPlayer 的 isFocus 概念，但也不能出现"要先点一下" | 用全局 `Focus` + `Shortcuts` |
| 3 | **桌面手势要自己实现** | ArtPlayer 桌面端本来就没有，我们补的；Flutter 若不做就**倒退** | 显式实现双击分区 + 滚轮 |
| 4 | 倍速步进表 + 默认从 1x 出发 | 细节不一致用户能感知 | 照抄 `steps` 与 `i<0?2:i` |
| 5 | DRM 分支 | 有独立 UI 与降级路径，漏了会卡死 | 保留 `isDrm` + `showDrmHelp` |
| 6 | 进度上报时机 | 早了位置是 0，晚了丢进度 | 复现 `startProgressWatch` 的节流 |
| 7 | 外挂音轨同步 | 三个 mirror 回调要一起搬 | 用 media_kit 的多音轨能力替代或保留 |
| 8 | 缓冲提示与加载提示**区分** | 混在一起会一直显示"加载中" | 两套状态机分开 |

---

## 十四、待确认事项（不能自己决定）

这三处**属于操作逻辑变化**，需要 Owner 拍板：

1. **HEVC 帮助 UI 是否保留** —— media_kit 不需要装扩展了。
   但如果保留，对用户是无害的冗余；删掉则界面更干净。
2. **转码功能是否保留** —— 同理。media_kit 直接硬解 HEVC，
   转码的唯一价值是「极老的设备」。
3. **快捷键是否扩展** —— 原版是 6 内置 + 11 自定义。
   Flutter 版可以顺势补齐（如 `[` `]` 调速度），但那是**新增行为**。

---

## 附：尚未逐行核对的区域

诚实说明 —— 本次提取覆盖了：
```text
✓ 全部 60+ 函数签名与行号
✓ 键盘/手势/焦点（逐行读了 L3552–3716）
✓ 模板结构与 UI 元素（L4165–4683 扫描）
✓ 关键陷阱（源码注释里明确记载的）
```

**未逐行读的**：
```text
· L1442–1822  startPlayback 内部（380 行）
· L3016–3343  execRemote 的完整命令表（327 行）
· L4685–5759  样式（1074 行，重写时不参考）
```
这三块如果要精确对齐，需要单独再读。
