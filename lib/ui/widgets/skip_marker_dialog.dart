// ═══════════════════════════════════════════════════════════════════════
//  片头 / 片尾设置弹窗（4 点区间 + 独立预览）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须做（用户指出「片头片尾的设置你也没做」）
//
// 我只做了**自动跳过**（`player_page.dart` 的 `_maybeSkip`），
// 但用户**没有任何途径去设置**那四个点 —— 功能是半截的。
//
// # 原版的设计意图（`SkipMarkerDialog.vue` 文件头，Owner 两次指正）
//
// ## ① 是**区间**，不是单点
//
// Owner 原话：
// > 设置片头片尾应该是独立的…是可以配置**开始是从 xx 秒开始 xx 秒跳转**的，
// > 结尾也是一样，不是简单粗暴设置个片头的时间、片尾的时间就结束了，
// > 你搞错了，也做的不完善。
//
// 原版第一版只让用户设「片头结束位置」**一个点** —— 表达不了
// "片头是哪一段"，用户看不到 `00:00:12 - 00:00:49` 这个区间，
// 就没法判断设得对不对。所以改成**四个点**：
// ```text
// [========|——————————————|==========]
//  ↑        ↑              ↑         ↑
// intro_start intro_end  outro_start outro_end
// ```
//
// ## ② 预览播放器必须**独立**，不能联动主播放器
//
// Owner 原话：
// > 设置片头片尾的这个也应该视频是单独的，而不是使用第一层的那个 video，
// > 这两个应该是分别独立的…并且可以预览的，而不是跟底层的进行联动。
//
// 原版第一版把主播放器 seek 来 seek 去，后果：
// ```text
// · 用户设完片头，主播放器进度被改掉 —— 关掉弹窗后从"预览位置"继续看
// · 拖动滑块让主播放器反复取分片（HLS 每次 seek 都要重新拉），
//   把主播放器的缓冲搅乱
// · 手机上更糟：主播放器在弹窗背后还在播，用户看到两个画面不同步
// ```
//
// ═══════════════════════════════════════════════════════════════════════
// ★★★ 2026-09-26 task-57：一次**走了弯路又走回来**的记录（请完整读完）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（**第二次**说不能用）
//
// > 还有片头片尾设置根本不能用，你自己好好用用这个功能，你看到底合理不合理？
//
// # ① 我先怀疑"第二个播放器会饿死主播放器" —— ★ 这个怀疑**未确证**
//
// 编排者的日志（`.probe/FINAL3-LAUNCH.txt`）里**观测到过一次**：
// ```text
// L221 [NAV] 打开播放器: cycani:3862          ← 主播放器开始 open
// L232 media_kit: ANGLESurfaceManager ...     ← ★ 预览播放器也起来了
// L239 [SKIPDLG] 独立预览播放器已启动
// L242 [PLAYER] hwdec-current = （就绪=否，等待 12000ms 超时）
// L243 [PLAYER] ★ 续播已生效: 419s （等时长 12000ms, duration=0s）
// ```
//
// ★★ 但**两次独立实测都没能复现**，所以**不能**把它当成事实：
// ```text
// · 我：5 轮「主播放器还在加载时开弹窗」⇒ 就绪=是 **5/5**、就绪=否 0/5
//       + 另一次弹窗开着主播放器仍 `就绪=是`（弹窗外围纯黑仅 1.2%）⇒ 合计 6/6
//       续播耗时 4000ms（开弹窗）vs 3750ms（不开）⇒ **无差异**
// · fix-window-shadow：双向 A/B（含"弹窗先于就绪打开"那组）
//       ⇒ 主播放器**仍然就绪**（duration=1420s）
// · ★ 反向证据：我另一次**全程没开弹窗**（SKIPDLG 0 行）也出现
//       `hwdec-current = （就绪=否，等待 12000ms 超时）`
// ```
// ⇒ ★★★ 结论：那个签名（`就绪=否` + `duration=0`）的真实含义是
//    「**这条流没打开**」，**原因未确定** —— 可能是上游/代理慢，
//    也可能是两个播放器竞争。**不能**归因给弹窗。
//
// # ② 我据此把预览改成了"主播放器抓帧"（方案 D）—— ★ 这是**错的**
//
// ```text
// D 的做法：弹窗不再起播放器，改为 seek 主播放器 + player.screenshot()
// D 的理由：全进程只有一个 Player ⇒ 从结构上消除"两个播放器抢流"
// ```
// ★★★ 但 D 违背了 **Owner 明确、逐字的要求**（就是上面 L28-40 那段）：
// ```text
// > 设置片头片尾的这个也应该视频是单独的，而不是使用第一层的那个 video，
// > 这两个应该是分别独立的…并且可以预览的，而不是跟底层的进行联动。
//
// 而 Owner 记录的、被否掉的第一版的后果，**恰好就是 D 的必然结果**：
// · 用户设完片头，主播放器进度被改掉 —— 关掉弹窗后从"预览位置"继续看
// · 拖动滑块让主播放器反复取分片（HLS 每次 seek 都要重新拉），搅乱缓冲
// · 手机上更糟：主播放器在弹窗背后还在播，用户看到两个画面不同步
// ```
// ⇒ ★ 我当时的推理是「6/6 未复现 ⇒ 删掉独立预览」——
//   **这个推理有洞**：**"没复现 bug" ≠ "这个设计不好"**，
//   而 Owner **明确要过**这个设计。⇒ 已回退到"独立预览"。
//
// # ③ ★★★ 真正的根因（这才是用户说"不能用"的原因）
//
// 我用**用户正在跑的那个 build** 当用户走了一遍，每 4 秒量一次预览框：
// ```text
//   + 4s  纯黑  99.3%  颜色数      3   黑框
//   + 9s  纯黑  99.3%  颜色数      3   黑框
//   +15s  纯黑   0.0%  颜色数  57216   ★ 有画面
// ```
// ⇒ ★★★ **用户要等 15 秒才能看到画面，而这 15 秒是纯黑、且没有任何提示。**
//   ⇒ 用户的心理：打开 → 黑框 → 等几秒 → 还是黑 → **"这功能坏了"** →
//     关掉 → 报「不能用」。
//
// ★ 而这**与"用哪个播放器"无关** —— 等的是**网络（代理 TTFB 3~5s）+ 
//   demux + seek + 解码**，抓帧方案同样要等这么久。
//   ⇒ 所以 D **既违背 Owner，又修不了用户的病**。
//
// # ④ 为什么原来的 loading 提示**恰好不显示**
//
// 旧代码的条件挂错了：
// ```dart
// child: _previewCtrl == null
//     ? const Center(child: CircularProgressIndicator())  // 只在"控制器还没建"时显示
//     : Video(controller: _previewCtrl!, ...)             // 控制器一建就切走
// ```
// `_previewCtrl` 在 `await p.open(...)` **之后**就赋值了，而
// **`open()` 返回 ≠ 流就绪**（本文件 `_previewSeek` 的注释里早就写了这一条）
// ⇒ ★ spinner 在**真正需要它的那 15 秒**里恰好不显示。
//
// # ⑤ 本次的修法（三件事）
//
// ```text
// ① 预览回到"独立 Player"（满足 Owner：独立 / 可播放 / 不影响主播放器）
// ② ★ 加载态用**第一帧真的渲染出来**作为判据，而不是"控制器建好了"
//      判据来源：media_kit_video 的 `VideoController.rect`
//      —— 它在首帧渲染前是 null / 1x1（库自己用这个值决定要不要画 Texture，
//         见 media_kit_video-1.3.1/lib/src/video/video_texture.dart L427-437）
// ③ ★ 加载时给**文字**（不只是转圈）—— 15 秒的等待必须让用户知道
//      "在加载，不是坏了"；超时后还要给**可操作的出路**
// ```
//
// # ⑥ 如实记录的取舍
//
// ```text
// · 仍然是**两个 mpv**（Owner 要的独立预览必然如此）。
//   它会不会互相影响 ⇒ ★ **未确证**（见 ①）—— 不写成事实。
// · 预览**可以播放**（Owner 要的"可以预览的"）—— 区间循环保留。
// ```

import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/sourin_api.dart';
import '../tokens.dart';
import 'skip_timeline.dart';
import '../../ui/app_palette.dart';

/*
 * ═══════════════════════════════════════════════════════════════════════
 *  高度预算常量（2026-09-24 —— 用户「只看到片头两行」的真修法）
 * ═══════════════════════════════════════════════════════════════════════
 *
 * # 用户原话
 *
 * > 进度条只显示片头设置的两个箭头没有显示片尾的
 *
 * # 真因：**高度预算超了**，第 3、4 行被挤出滚动视口
 *
 * `_rows()` 里**确实有 4 行**（片头开始/结束、片尾开始/结束），
 * 时间轴也**确实画了 4 个箭头**（`drawArrow` 四次，单测断言过）。
 * 但四行落在 y=517/557/597/637，而滚动视口底边只到约 600 ——
 * 「片尾结束」整行在视口外，「片尾开始」只剩一半。
 * 用户只看到前两行 → 以为"只有片头的两个箭头"。
 *
 * # 修法：把「固定开销」压到最小，把剩下的高度全给预览
 *
 * 弹窗高度是**有限**的（`maxHeight 640`）。要让四行一定可见，
 * 就得先算清楚"除预览外还要多少"，剩下的才给预览：
 * ```text
 * 弹窗内高 640
 *   Padding(Sp.x5*2)          40
 *   _header                   32   ← 关闭按钮 48→32（本轮收紧）
 *   SizedBox(Sp.x4)           16
 *   ─────────────────────────────
 *   固定开销 A                88
 *
 * 中段（滚动区）里除预览外：
 *   预览后的间距 Sp.x4         16
 *   时间轴（SkipTimeline）     64
 *   间距 Sp.x4                 16
 *   四行（4 × 36）            144   ← `kRowH = 32` 时代的数字；
 *                                      现行 `kRowH = 36` ⇒ 每行 40、四行 160
 *   间距 Sp.x3                 12
 *   自动跳过                   40
 *   ─────────────────────────────
 *   固定开销 B               292
 *
 * 中段外：
 *   间距 Sp.x2                  8
 *   _footer                    40
 *   ─────────────────────────────
 *   固定开销 C                 48
 *
 * 合计固定 = 88 + 292 + 48 = 428
 * → 预览最多能占 640 - 428 = 212
 * ```
 * ⚠️ 当时把「四行」误算成 `4 × 32 = 128`（真实行距是 `kRowH + Sp.x1` = 36），
 *    于是合计算成 412、预览上限写成 **228** —— 比真实可用多 16px。
 *    预览高原来又写死 260，两者相加正好把第 4 行挤出滚动视口。
 *    上面的数字已按真实行距改正（292 / 428 / 212）。
 *
 * ★ 2026-10-02：`kRowH` 后来又被 task-66 D 从 32 抬到 **36**（见下面 `kRowH`
 *   的注释），于是行距变成 `36 + 4 = 40`、四行占 **160**（不是 144），
 *   B 段变成 308、合计 444、预览上限 196。
 *   ⚠️ 上面那段 144 / 292 / 428 / 212 只对 `kRowH = 32` 成立 ——
 *   它是**历史推导**，别拿它当现行预算；现行预算看 `kChromeH` + `kMidRestH`。
 *
 * ⚠️ 上面这段是 **2026-09-24 的推导**，留作历史记录；它只算了当时的弹窗
 *    （640 高、没有「整段」预览行）。**现行预算以下面 `kMidRestH` +
 *    `kChromeH` 为准** —— 那两个常量才是代码真正用的，且已被 task-66
 *    改过两轮（`kMidRestH` 300 → 340 → 360）。
 *
 * ⚠️ 这些常量**必须与真实 widget 尺寸对得上**，否则又会溢出。
 *    所以 `test/skip_dialog_rows_test.dart` 用 widget 测试**实测**四行的
 *    `getRect().bottom` 是否 <= 弹窗内底边 —— 常量写错那条测试就红。
 */

/// 关闭按钮 / 行内按钮的边长（默认 48 太大 —— 见上面的预算）
const double kHeaderBtn = 32;

/// 每行 `_EdgeRow` 的高度（`_StepBtn` 的命中区边长）
///
/// ══════════════════════════════════════════════════════════════════
/// ★★★ task-66 D：32 → 36（Owner：「四行 +/− 加大」+「有点丑，要美观」）
/// ══════════════════════════════════════════════════════════════════
///
/// 32 是 2026-09-24 为了「四行塞进视口」压出来的值 —— 当时每行 40px，
/// 第 4 行「片尾结束」被挤出滚动视口。压到 32 解决了溢出，但按钮小到
/// 点起来别扭。36 是折中：仍然 <= 原来的 40，同时命中区大了 12.5%。
///
/// ⚠️ 行**实际占高** = `kRowH` + `_EdgeRow` 的 `Padding(bottom: Sp.x1)`
///    = 36 + 4 = **40px**，所以 `kMidRestH` 里的「四行」一项按 4×40 算。
const double kRowH = 36;

/// 行内**约束提示**（`≤ 00:19`）占的宽
///
/// ★ 必须与 `_EdgeRow` 里那个 `SizedBox(width: kHintW)` **一致** ——
/// 提示是显式限宽的（不是按内容自适应），否则宽度预算又对不上：
/// ```text
/// 提示最长 = "00:05-00:19" = 11 字符 × cap(12) ≈ 46px
/// 取 56 留一点余量（含左边距 Sp.x1=4）
/// ```
const double kHintW = 56;

/// 约束提示**最多**能占的宽（可让位）
///
/// `kHintW` 是"预算里按 56 记"，这个常量是"提示文字本身最多量到多宽"。
/// 两者分开是因为 `_EdgeRow` 现在**按实测需要**分配：
/// ```text
/// 提示要占宽 = min(实测文字宽 + Sp.x1, kHintMaxW)
/// 挤不下时提示**让位**（标签与读数优先）—— 见 _EdgeRow 的分配段
/// ```
/// 取 `kHintW` 同一个值：提示最长 `"00:05-00:19"` 在 `FontSizes.cap`
/// 下约 46px，56 足够，超过就说明我算错了，不该继续吃标签的宽。
const double kHintMaxW = kHintW;

/// 配对色条的宽度（task㉝）
///
/// # 为什么是 3px
///
/// ```text
/// 1px  → 在 2x 缩放的屏上几乎看不见（用户会以为没做）
/// 3px  → 一眼能看到颜色，又不与文字争注意力
/// 6px+ → 变成"装饰条"，四行各一条会显得很吵
/// ```
/// ★ 高度用 `kRowH`（= 36，撑满整行）—— 与 `−/+` 按钮的命中区等高，
///   视觉上"这条色条就是这一行的标记"。
///
/// ⚠️ 它**计入** `_EdgeRow` 的宽度预算（`fixedW`）—— 漏算会溢出。
///    高度上它是 `Row` 的子项，**不加行高**（见 `_EdgeRow.accent` 的说明）。
const double kAccentW = 3;

/// 预览最大高度
///
/// 740 高的弹窗里算出来是 296（宽 526）—— 见 `kDialogMaxH` 的说明。
/// 上限 400 是"再高也没必要"的封顶（16:9 时宽 711，已经接近弹窗宽度）。
const double kPreviewMaxH = 400;

/// 预览最小高度 —— 再挤也要让用户看得见画面
const double kPreviewMinH = 96;

/// 中段里**除预览外**的全部高度（**实测**值）
///
/// ```text
/// 预览后的间距 Sp.x4        16
/// 时间轴（SkipTimeline）    64
/// 间距 Sp.x4                16
/// 四行（4 × 40）           160   ← 每行 = kRowH(36) + 行底距 Sp.x1(4)
/// ★ 间距 Sp.x2               8   ← task-66 新增
/// ★ 「整段」预览行（kRowH）  36   ← task-66 新增
/// 间距 Sp.x3                12
/// 自动跳过开关行            48
/// ─────────────────────────────
/// 合计                     360   （task-66 之前 = 300）
/// ```
///
/// ⚠️ 这是**真机实测**出来的（`.probe\dlg\dlg-probe.txt`：
///    `中段内容总高 456 = 预览 156 + 其余 300`），不是估的。
///    改动任何一项的尺寸都要同步改这里 ——
///    `skip_dialog_rows_test.dart` 会断言「中段内容总高 <= 视口高」，
///    常量漂了那条测试立刻红。
///
/// ══════════════════════════════════════════════════════════════════
/// ★★★ task-66 B：300 → 340（Owner 要求「预览片头 片尾**整段**」）
/// ★★★ task-66 D：340 → 360（Owner「四行 +/− 加大」：kRowH 32 → 36）
/// ══════════════════════════════════════════════════════════════════
///
/// # 为什么必须同步改（否则复发一个**已修过的** bug）
///
/// `previewHeightFor` 是 `boxH - kChromeH - kMidRestH` ——
/// 它把"中段里除预览外的开销"整个扣掉，剩下的全给预览。
/// 若新加了一行却**不加** `kMidRestH`：
/// ```text
/// 预览会多算 40px ⇒ 中段真实总高比视口高 40px
/// ⇒ ★ 第四行「片尾结束」被挤出滚动视口
/// ⇒ 正是用户 2026-09-24 报的「只看到片头设置的两个箭头」
///   （那次根因逐字记录在上面 `kRowH` 的说明里）
/// ```
/// ★ 也就是说：**漏改这个常量 = 把两年前修好的 bug 原样请回来**。
///
/// # 代价（如实记录）
///
/// 弹窗高 740 时：预览 `740-144-360 = 236`（task-66 前 296，B 少 40，D 再少 20）。
/// 仍然远大于最初的 156（宽 526 → 约 455）——
/// 而这两轮买到的是 Owner 明确要求的「整段预览」+「按钮加大」能力，值。
///
/// ⚠️ 若将来有人想省掉这 60px：**不许**直接把 360 改回 300，
///    那会让预览把第四行挤出去。要么真的删掉那一行（同时删掉功能），
///    要么另找地方安置那两个按钮。
const double kMidRestH = 360;

/// 中段**之外**的全部高度（**实测**值）
///
/// ```text
/// Padding(Sp.x5) 上下       40
/// _header                   32
/// Sp.x4 间距                16
/// Sp.x2 间距                 8
/// _footer                   48
/// ─────────────────────────────
/// 合计                     144
/// ```
///
/// 实测依据（真机探针，窗口 1280x800、弹窗高 640）：
/// ```text
/// 滚动视口高 496      640 - 496 = 144  ✓
/// ```
const double kChromeH = 144;

/// 弹窗**上限**尺寸（2026-09-25 用户「中间的预览太小了」）
///
/// # 为什么要放大
///
/// 真机实测（`.probe\dlg\dlg-probe.txt`）改前：
/// ```text
/// 弹窗 720x640   →   预览只有 277x156
/// ```
/// 用户原话「中间的预览太小了」—— 277px 宽的画面里连人脸都看不清，
/// 而**判断"片头设到哪一秒"恰恰要靠看清画面**。这是这个弹窗的核心诉求，
/// 所以宁可让弹窗占满大部分屏幕，也要把预览做大。
///
/// 改后（下面这两个值）：
/// ```text
/// 弹窗 820x740   →   预览 526x296   （面积 ×3.6）
/// ```
///
/// ⚠️ 上限仍受**窗口尺寸**限制（`min(上限, 窗口 - 2*边距)`）——
///    窗口小的时候自动缩，不会溢出屏幕。
const double kDialogMaxW = 820;
const double kDialogMaxH = 740;

/// 由弹窗可用高算出**预览该多高**
///
/// # 为什么必须动态算（2026-09-24 用户「还是没做好」）
///
/// 原来预览高度写死 260。实测中段内容总高 = 560，而视口只有 488 ——
/// **超了 72px**，于是「片尾结束」那一行要靠滚动才看得到，
/// 用户就是看不到（他原话「只显示片头设置的两个箭头」）。
///
/// 修法：预览是唯一可以伸缩的元素（时间轴、四行、开关都有最小可用尺寸），
/// 所以把"剩余高度"全给它：
/// ```text
/// 预览高 = clamp(弹窗高 - 中段外开销 - 中段内其余开销, 最小, 最大)
///        = clamp(boxH - 144 - 300, 96, 400)
/// ```
/// 740 高时 = **296**（宽 526）—— 比改前的 156（宽 277）大一倍多。
///
/// ⚠️ 下限 96：窗口极矮时宁可滚动，也不能把画面压成一条缝
///    （那样用户没法判断"片头设到哪一秒了"）。
double previewHeightFor(double boxH) => (boxH - kChromeH - kMidRestH)
    .clamp(kPreviewMinH, kPreviewMaxH)
    .toDouble();

/// 片头/片尾设置弹窗
///
/// 用法：
/// ```dart
/// final r = await showDialog<SkipMarkerResult>(
///   context: context,
///   builder: (_) => SkipMarkerDialog(
///     provider: widget.provider,
///     id: widget.id,
///     title: widget.title,
///     streamUrl: url,          // ★ 独立预览用（Owner 要求）
///     duration: _realDuration, // 主播放器已知的时长
///   ),
/// );
/// ```
class SkipMarkerDialog extends StatefulWidget {
  const SkipMarkerDialog({
    super.key,
    required this.provider,
    required this.id,
    required this.title,
    required this.streamUrl,
    required this.duration,
  });

  final String provider;
  final String id;
  final String title;

  /// 预览用的流地址（**与主播放器同一个 URL，但独立实例**）
  ///
  /// ⚠️ 这是 **Owner 明确要求的形态**：
  /// > 设置片头片尾的这个也应该视频是单独的，而不是使用第一层的那个 video，
  /// > 这两个应该是分别独立的…并且可以预览的，而不是跟底层的进行联动。
  ///
  /// ⇒ ★ **不要**把它改成"seek 主播放器 / 抓帧"（我 task-57 试过，已回退）。
  ///    完整理由与实测见本文件头 task-57 那一大段。
  final String streamUrl;

  /// 总时长（秒）—— 主播放器已经知道，不必等预览加载
  final Duration duration;

  @override
  State<SkipMarkerDialog> createState() => _SkipMarkerDialogState();
}

/// 保存结果（`null` 的点 = 该区间被清空）
class SkipMarkerResult {
  const SkipMarkerResult({
    this.introStart,
    this.introEnd,
    this.outroStart,
    this.outroEnd,
    this.autoSkip = true,
  });

  final int? introStart;
  final int? introEnd;
  final int? outroStart;
  final int? outroEnd;
  final bool autoSkip;
}

class _SkipMarkerDialogState extends State<SkipMarkerDialog> {
  // ── 四个点（秒）──
  //
  // ⚠️ 用 `int?` 而不是 `int` —— **null 表示"未设置"**，
  //    与"设成了 0 秒"是两回事（原版也是 `number | null`）。
  //    片头开始天然就是 0，所以 0 是合法值，不能用 0 当哨兵。
  int? _introStart;
  int? _introEnd;
  int? _outroStart;
  int? _outroEnd;

  bool _autoSkip = true;

  /// 独立预览播放器（**不与主播放器共享**）
  Player? _preview;
  VideoController? _previewCtrl;
  String? _previewError;

  /// ★★★ 首帧是否**真的渲染出来了**（task-57 新增 —— 这是本次的核心修复）
  ///
  /// # 为什么不能再用 `_previewCtrl == null` 当 loading 判据
  ///
  /// 实测（用**用户正在跑的 build**，每 4 秒量一次预览框）：
  /// ```text
  ///   + 4s  纯黑  99.3%  颜色数      3   黑框   ← ★ 用户看到的就是这个
  ///   + 9s  纯黑  99.3%  颜色数      3   黑框
  ///   +15s  纯黑   0.0%  颜色数  57216   ★ 有画面
  /// ```
  /// ⇒ ★★★ **用户要等 15 秒**，而这 15 秒里预览框是**纯黑且无提示**。
  ///   用户无法区分"在加载"和"坏了" ⇒ 这就是他说「根本不能用」的直接来源。
  ///
  /// 旧条件为什么恰好不显示：
  /// ```dart
  /// _previewCtrl == null ? 转圈 : Video(...)
  /// ```
  /// `_previewCtrl` 在 `await p.open(...)` **之后**就赋值了，
  /// 而 **`open()` 返回 ≠ 流就绪**（本文件 `_previewSeek` 注释里早写了）
  /// ⇒ spinner 在**真正需要它的那 15 秒**里恰好被切走。
  ///
  /// # 判据来源（读 media_kit_video 源码确认，不是猜的）
  ///
  /// `VideoController.rect`（`ValueNotifier<Rect?>`）在**首帧渲染前**
  /// 是 `null` 或 1x1 —— 库**自己**就用这个值决定要不要画 `Texture`：
  /// ```text
  /// media_kit_video-1.3.1/lib/src/video/video_texture.dart L427-437
  ///   // Keep the |Texture| hidden before the first frame renders.
  ///   if (rect.width <= 1.0 && rect.height <= 1.0)
  ///     Positioned.fill(child: Container(color: videoViewParameters.fill))
  /// ```
  /// ⇒ 用同一个判据，我们的 loading 就与库的"有没有画面"**严格同步**。
  bool _firstFrame = false;

  /// 预览画面的**真实宽高比**（由 `VideoController.rect` 读出）
  ///
  /// # 为什么要有它（task-66 C「预览去黑边」）
  ///
  /// 原来预览框写死 `AspectRatio(16 / 9)`，再套一层 `ColoredBox(Colors.black)`
  /// ⇒ 只要片源不是 16:9（老剧 4:3、电影 2.39:1、竖屏 9:16），
  /// 画面就会在**我们自己加的**黑底上留出黑边 —— 用户看到的就是"预览有黑边"。
  ///
  /// ⚠️ 黑边**不是 media_kit 画的**：`Video` 内部已经是
  /// `FittedBox(fit: BoxFit.contain)` + 按 `rect` 定尺寸的 `SizedBox`
  /// （`media_kit_video-1.3.1/lib/src/video/video_texture.dart` L390-415）。
  /// 罪魁是**外层那个写死的 16/9**：它先把画布定成 16:9，库再把真画面
  /// contain 进去，两边比例不一致的那部分就变成黑边。
  ///
  /// ⇒ 修法：把外层画布的比例改成**视频自己的比例**，contain 就退化成
  ///    "刚好铺满"，黑边自然消失。`rect` 就是视频原生尺寸（见 L406-415
  ///    库用它算 `SizedBox` 的宽），所以 `rect.width / rect.height` 即宽高比。
  ///
  /// 默认 16/9 是**兜底**：首帧出来前 `rect` 是 null / 1x1，没有比例可读，
  /// 此时预览区显示的是加载提示（不是画面），用哪个比例都看不见。
  double _previewAspect = 16 / 9;

  /// 预览当前播放位置（秒）—— **乐观值**
  ///
  /// ⚠️ 它会被 `_previewSeek` 直接设成目标值（用户点了"预览"就希望读数
  ///    立刻跳到那一秒）。所以**不能**拿它当"画面真的到那了"的证据 ——
  ///    要验证 seek 有没有落地，用 [_rawPos]。
  double _previewPos = 0;

  /// 预览播放器**自己报告**的真实位置（秒）
  ///
  /// # 为什么要和 `_previewPos` 分开（2026-09-24 实测抓到的静默 bug）
  ///
  /// `_previewPos` 是**乐观**的：`_previewSeek` 一调用就把它设成目标值。
  /// 但 seek **可能被静默丢弃** —— 不报错、不抛异常、日志还显示成功：
  /// ```text
  /// Player.open() 返回时 mpv 还没 demux 完（duration 仍是 0）；
  /// 此刻发出的 seek 只是排队，随后音视频链重建时**播放位置被复位**
  /// → 状态/日志都显示"已跳到 N 秒"，画面却还在原地
  /// ```
  /// `player_page.dart` 踩过同一个坑（"日志说续播到 276s，画面是 00:29"）。
  ///
  /// 所以另留一个**只由播放器流更新**的位置，用于：
  /// ```text
  /// ① 区间循环的判据（该按"画面实际播到哪"判，不是按乐观读数）
  /// ② 实测验证 seek 到底落地没有（[_verifySeek]）
  /// ```
  double _rawPos = 0;

  /// seek 代次号 —— 防"上一次的延迟 seek 打到新流上"
  ///
  /// 用户可能连点几次"预览"（或换了要预览的端点），
  /// 每次起一个新的代次号，过期的验证就自己放弃。
  int _seekToken = 0;

  /// 预览时长（可能比 widget.duration 更准 —— 以实际拉的流为准）
  double _mediaDuration = 0;

  /// 是否已经做过"打开弹窗后的首帧定位"（只做一次）
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ 2026-09-26 task-52：**真机实测**发现预览区**打开时全黑**
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// # 实测读数（隔离实例，用户真实数据副本）
  ///
  /// ```text
  /// 打开弹窗后等 10 秒（期间不碰任何控件）：
  ///   all-black ratio = 4118/16000 = 25.7%
  ///   预览区中心像素 #000000
  /// 截图 .probe\t52_dlg_wait.png —— 预览框**纯黑**，什么都看不到
  /// 点一次「预览」之后：
  ///   [SKIPDLG] seek 已落地: 目标 0.0s，实际 1.1s
  ///   all-black ratio 25.7% → 15.3%，画面**出来了**
  /// ```
  ///
  /// ⇒ 根因：`_initPreview()` 用 `play: false` 打开（那是为修
  ///   「打开就自动播放」加的，**这个修复本身是对的**），
  ///   但**没有任何一次 seek** ⇒ 解码器停在 0 帧且不解码 ⇒ 全黑。
  ///
  /// # 为什么这个缺陷正好命中用户的抱怨
  ///
  /// 用户原话：「播放页面的片头片尾设置**根本就不能正常用**」。
  /// 弹窗打开是纯黑 ⇒ 用户**没有任何参照**去判断"片头该切在哪一秒"，
  /// 而"看着画面定片头片尾"正是这个弹窗**唯一**的用途。
  ///
  /// # 修法：时长一到就**定位到片头结束那一帧**（保持暂停）
  ///
  /// 只 seek、**不 play** —— 不违反"打开不自动播放"那条既有要求。
  bool _didInitialSeek = false;

  /// 正在循环预览的区间（null = 不在循环）
  Timer? _loopTimer;
  int? _loopFrom;
  int? _loopTo;

  /// ★★★ 2026-10-02：**正在播哪一段**（Owner：「预览的时候不支持暂停」）
  ///
  /// ```text
  /// null      没在播（按钮显示「▶ 片头整段」）
  /// intro     正在播片头整段（按钮显示「⏸ 暂停」）
  /// outro     正在播片尾整段
  /// ```
  /// ★ 用"哪一段"而不是 `bool` —— 两个区间各自独立：
  ///   播片头时"片尾整段"按钮仍应显示为可播（点了就切过去）。
  SkipEdge? _playingRange;

  /// 当前预览位置的**显示用**读数（`00:12`）
  ///
  /// ⚠️ 与 `_previewPos` 的区别：那个是"目标位置"（乐观值），
  ///    这个是**实际画面在哪**（由播放器 position 流驱动）。
  ///    Owner 要在时间轴旁边看到"现在到哪了"。
  double _shownPos = 0;

  /// ★ task-57：边界改动后"预览跟随"的 debounce 定时器
  ///
  /// 见 `_applyEdge` 的说明 —— 合并高频改动，只对"停手后的值"seek 一次。
  Timer? _followTimer;

  bool _loading = true;
  bool _saving = false;

  double get _total => _mediaDuration > 0
      ? _mediaDuration
      : widget.duration.inSeconds.toDouble().clamp(1, double.infinity);

  @override
  void initState() {
    super.initState();
    /*
     * ★ 起**独立**预览播放器 —— Owner 明确要求的形态
     *   （见本文件头 L28-40；task-57 试过改成"抓帧"已回退）。
     */
    _loadExisting();
    _initPreview();
  }

  @override
  void dispose() {
    _loopTimer?.cancel();
    _followTimer?.cancel();
    /*
     * ★ 必须 dispose 预览播放器（2026-09-24）
     *
     * 不 dispose 的话这个独立 `Player` 的原生 mpv 实例会**泄漏** ——
     * 用户开几次设置弹窗就多几个解码器在后台跑。
     *
     * ⚠️ `Player.dispose()` 是异步的，但 dispose 是同步方法 ——
     *    fire-and-forget（media_kit 内部自己会清）。
     */
    _preview?.dispose();
    super.dispose();
  }

  /// 读已存的跳过点（有就回填，用户改起来方便）
  Future<void> _loadExisting() async {
    try {
      final m = await SourinApi.getSkipMarker(widget.provider, widget.id);
      if (!mounted) return;
      setState(() {
        _introStart = m?.introStart;
        _introEnd = m?.introEnd;
        _outroStart = m?.outroStart;
        _outroEnd = m?.outroEnd;
        // 原版默认 true —— 设了跳过点就是希望自动跳
        _autoSkip = m?.autoSkip ?? true;
        _loading = false;
      });
      /*
       * ★ task-52：时长可能**比这里先到**（`_maybeInitialLocate` 里有
       *   `if (_loading) return;` 的闸门）—— 所以读完必须再补一次，
       *   否则那条路径下首帧定位被静默跳过，预览又是全黑。
       */
      _maybeInitialLocate();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      debugPrint('[SKIPDLG] 读跳过点失败: $e');
      // 读失败也要出画面 —— 否则用户看到的是"打不开的黑框"
      _maybeInitialLocate();
    }
  }

  /// 起一个**独立的**预览播放器（Owner 明确要求的形态）
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★ 为什么必须"独立"（Owner 逐字要求，见本文件头 L28-40）
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// > 设置片头片尾的这个也应该视频是单独的，而不是使用第一层的那个 video，
  /// > 这两个应该是分别独立的…并且可以预览的，而不是跟底层的进行联动。
  ///
  /// ⚠️ 我 task-57 曾把它改成"seek 主播放器 + 抓帧"（方案 D），**已回退**：
  ///    D 恰好就是 Owner 否掉的那一版，且它的三条后果**必然发生**。
  ///    完整记录见本文件头。
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ 本次的核心修复：**首帧判据**（修"15 秒黑框"）
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// # 实测：用户要等 15 秒，而这 15 秒是纯黑且无提示
  ///
  /// ```text
  ///   + 4s  纯黑  99.3%  颜色数      3   黑框   ← ★ 用户看到的就是这个
  ///   + 9s  纯黑  99.3%  颜色数      3   黑框
  ///   +15s  纯黑   0.0%  颜色数  57216   ★ 有画面
  /// ```
  /// ⇒ 用户无法区分"在加载"和"坏了" ⇒ 这就是「根本不能用」的直接来源。
  ///
  /// # 旧条件为什么恰好不显示
  ///
  /// ```dart
  /// _previewCtrl == null ? 转圈 : Video(...)     // ← 旧写法
  /// ```
  /// `_previewCtrl` 在 `await p.open(...)` **之后**就赋值了，而
  /// **`open()` 返回 ≠ 流就绪**（下面 `_previewSeek` 的注释里早写了）
  /// ⇒ spinner 在**真正需要它的那 15 秒**里被切走。
  ///
  /// # 新判据：`VideoController.rect`（读库源码确认，不是猜的）
  ///
  /// `VideoController.rect` 是 `ValueNotifier<Rect?>`，首帧渲染前是
  /// `null` 或 1x1 —— **库自己就用它决定要不要画 Texture**：
  /// ```text
  /// media_kit_video-1.3.1/lib/src/video/video_texture.dart L427-437
  ///   // Keep the |Texture| hidden before the first frame renders.
  ///   if (rect.width <= 1.0 && rect.height <= 1.0)
  ///     Positioned.fill(child: Container(color: videoViewParameters.fill))
  /// ```
  /// ⇒ 用**同一个判据**，我们的 loading 就与库的"有没有画面"**严格同步**，
  ///   不会出现"库已经出画、我们还在转圈"或反过来的错位。
  ///
  /// ⚠️ 另外还叠了一个**保险**：`waitUntilFirstFrameRendered`（库提供的
  ///    Future）。两者取先到者 —— 单一信号在异常路径下可能不触发，
  ///    两个都挂能降低"永远转圈"的风险。
  Future<void> _initPreview() async {
    try {
      /*
       * ⚠️ 与主播放器**完全相同**的硬解设置
       *
       * 不设 `hwdec` 的话：Android 上软解、Windows 上可能也退软解 ——
       * 预览会卡（用户在拖动时要即时看到画面，卡顿直接毁掉体验）。
       *
       * `libass` 不用开 —— 预览只在看画面位置，字幕不重要，
       * 而且多开一个 libass 会多占内存。
       */
      final p = Player(
        configuration: const PlayerConfiguration(
          title: '片头片尾预览',
          logLevel: MPVLogLevel.error,
        ),
      );
      /*
       * ⚠️ `setProperty` 在 `Player` 上**不存在** —— 必须拿到
       *    `p.platform` 并转成 `NativePlayer`（我第一版写错了，
       *    编译报 `The method 'setProperty' isn't defined for Player`）。
       *    与主播放器 `player_page.dart:_setHwdec` 的写法保持一致。
       */
      final native = p.platform;
      if (native is NativePlayer) {
        await native.setProperty('hwdec', 'auto-safe');
      }
      // 预览**静音** —— 原版也是（避免和主播放器声音重叠）
      await p.setVolume(0);
      final c = VideoController(p);

      /*
       * ★★★ 首帧判据 —— 本文件头"⑤ 本次的修法"里的第 ② 条
       *
       * `c.rect` 在首帧渲染前是 null / 1x1。监听它 ⇒ 一旦变成真实尺寸
       * 就说明**画面真的有了**，此时才把 loading 换成 Video。
       */
      void onRect() {
        if (!mounted) return;
        final r = c.rect.value;
        final ready = r != null && r.width > 1.0 && r.height > 1.0;
        if (!ready) return;
        /*
         * ★ task-66 C「预览去黑边」：顺手把视频的**真实宽高比**记下来。
         *
         * `rect` 就是视频原生尺寸（库自己用它算 `SizedBox` 的宽，见
         * `video_texture.dart` L406-415），所以 `width / height` 即宽高比。
         * 外层画布用它替换写死的 16/9 ⇒ 库的 `BoxFit.contain` 退化成"刚好
         * 铺满"，我们自己那层黑底就露不出来了。
         *
         * ⚠️ 只在**真的变了**才 setState：这个监听器会被渲染循环反复调用
         *    （窗口 resize / 旋转都会触发），无条件 setState 会变成重建风暴。
         */
        final a = r.width / r.height;
        if (a.isFinite && a > 0.1 && a < 10.0 && (a - _previewAspect).abs() > 0.001) {
          debugPrint('[SKIPDLG] 预览宽高比 ${_previewAspect.toStringAsFixed(3)}'
              ' → ${a.toStringAsFixed(3)}（rect=${r.width.toInt()}x${r.height.toInt()}）');
          setState(() => _previewAspect = a);
        }
        if (!_firstFrame) {
          debugPrint('[SKIPDLG] ★ 首帧已渲染（rect=${r.width.toInt()}x'
              '${r.height.toInt()}）—— 预览可见');
          setState(() => _firstFrame = true);
        }
      }

      c.rect.addListener(onRect);

      /*
       * ★ 保险：库的 `waitUntilFirstFrameRendered`。两者谁先到都算数。
       *   ⚠️ 不 await 它（那会阻塞 `open`），只挂一个回调。
       */
      unawaited(c.waitUntilFirstFrameRendered.then((_) {
        if (!mounted || _firstFrame) return;
        debugPrint('[SKIPDLG] ★ 首帧已渲染（waitUntilFirstFrameRendered）');
        setState(() => _firstFrame = true);
      }).catchError((_) {}));

      p.stream.position.listen((pos) {
        if (!mounted) return;
        final sec = pos.inMilliseconds / 1000.0;
        /*
         * ⚠️ 真实位置**只**由这条流更新（不要在 `_previewSeek` 里同步设它）——
         *    否则它就退化成第二个"乐观值"，失去验证 seek 是否落地的能力。
         */
        _rawPos = sec;
        setState(() => _previewPos = sec);
      });
      p.stream.duration.listen((d) {
        if (!mounted) return;
        final secs = d.inMilliseconds / 1000.0;
        if (secs > 0 && (secs - _mediaDuration).abs() > 1) {
          setState(() => _mediaDuration = secs);
        }
        // ★ task-52：时长一出来就做一次"首帧定位"（修"打开全黑"）
        _maybeInitialLocate();
      });

      /*
       * ★★★ `play: false` —— 弹窗打开时**不得自动播放**（2026-09-25 用户实测）
       *
       * # 用户原话
       *
       * > 而且还**自动播放**
       *
       * # 根因（读 `media_kit` 库源码确认，不是猜的）
       *
       * `media_kit-1.2.6/lib/src/player/player.dart:160-163`：
       * ```dart
       * Future<void> open(
       *   Playable playable, {
       *   bool play = true,          // ← ★ 默认就是 true
       * }) async { ... }
       * ```
       * 而这里原来只写了 `p.open(Media(widget.streamUrl))` ——
       * **没传 `play`**，于是吃默认值 `true` → 弹窗一打开，预览就开始播。
       *
       * # 为什么这是错的（不只是"用户不喜欢"）
       *
       * ```text
       * ① 用户打开设置是想**看**自己设的片头片尾在哪，不是想看剧
       * ② 预览自己一路播下去 → 播放头一直跑 → 用户刚想拖箭头，
       *    画面已经跑到别处了，"设得对不对"根本没法判断
       * ③ 预览虽然静音（setVolume(0)），但**解码器在满速跑** ——
       *    手机上是白耗电，弱网源上是白耗流量
       * ```
       *
       * # ⚠️ 注意：这只影响**打开时**的初始状态
       *
       * 用户点「预览」按钮 / 拖时间轴时**仍然会播** —— 那是用户主动要求的：
       * `_previewRange` 里显式调 `_preview?.play()`（区间循环必须有播放
       * 才能验证"这段跳得对不对"）。这里只是把"没人要求就播"去掉。
       */
      await p.open(Media(widget.streamUrl), play: false);
      if (!mounted) {
        await p.dispose();
        return;
      }
      setState(() {
        _preview = p;
        _previewCtrl = c;
      });
      debugPrint('[SKIPDLG] 独立预览播放器已启动（与主播放器无关）');
    } catch (e) {
      if (!mounted) return;
      setState(() => _previewError = '$e');
      debugPrint('[SKIPDLG] 预览启动失败: $e');
    }
  }

  /// 跳到某秒（预览）
  ///
  /// # ★ 为什么不能直接 `seek()` 了事（2026-09-24 编排者转来的实测 bug）
  ///
  /// `Player.open()` **返回 ≠ 流已就绪**。media_kit 里 open 只等到
  /// `playlist-pos` 之类，此刻 `duration` 还是 **0**、demux 还没完成。
  /// 这时发出的 seek 有两个坏结局：
  /// ```text
  /// ① 被随后的"音视频链重建"复位掉（挂外挂音轨时必然重建）
  /// ② seek 调用**不报错**，所以日志/状态全都显示成功
  /// ```
  /// `player_page.dart` 里踩过一模一样的坑，现象是
  /// **"日志说已续播到 276s，画面上是 00:29"**。
  ///
  /// # 在本弹窗里的后果更严重
  ///
  /// 因为预览做的是**区间循环**：播到区间末尾要 seek 回起点。
  /// seek 被丢弃 → 循环失效 → 用户看到"预览一直往前播，不循环"，
  /// 而**任何日志都不会报错** —— 只会以为"预览按钮坏了"。
  ///
  /// # 修法（与 `player_page.dart:_seekAfterReady` 同一套思路，但更简单）
  ///
  /// ```text
  /// ① 若 duration 还没出来 → 先 await 等它（最多 8 秒）
  /// ② 等到了再 seek —— 那时 demux 完成，seek 不会再被复位
  /// ③ seek 之后**回头核对**：位置真的到目标附近才算成功（[_verifySeek]）
  /// ```
  /// ⚠️ 用 `async` 而不是"轮询直到就绪"：`_previewSeek` 在
  ///    拖动/按键时会**高频调用**，同步轮询会把 UI 卡住。
  Future<void> _previewSeek(num seconds) async {
    final s = seconds.clamp(0, _total).toDouble();
    final p = _preview;

    /*
     * 乐观更新读数：用户点了"预览"，进度读数**立刻**跳到那一秒。
     * ⚠️ 但 `_rawPos` 不跟着动 —— 它是画面真实位置的唯一来源，
     *    下面靠它判断 seek 到底落地没有。
     */
    setState(() => _previewPos = s);
    if (p == null) return;

    final token = ++_seekToken;

    // ── ① 等流就绪（最多 8 秒；8 秒后仍无时长就走兜底 seek）──
    var waited = 0;
    while (_mediaDuration <= 0 && mounted && waited < 32) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      waited++;
    }
    if (!mounted || token != _seekToken) return; // 期间又点了别的 → 本次作废

    // ── ② 目标夹到真实时长内（新流可能更短）──
    final target = _mediaDuration > 0 && s > _mediaDuration ? _mediaDuration : s;
    await p.seek(Duration(milliseconds: (target * 1000).round()));

    // ── ③ 回头核对：seek 真的落地了吗 ──
    unawaited(_verifySeek(target, token));
  }

  /// 打开弹窗后的**首帧定位** —— 修「预览区全黑」
  ///
  /// # 为什么必须有这一步
  ///
  /// 预览播放器用 `play: false` 打开（修「打开就自动播放」，见 `_initPreview`），
  /// 于是解码器停在 0 帧、**不解码也不出画面** ⇒ 预览框纯黑。
  /// 实测读数见 `_didInitialSeek` 的说明。
  ///
  /// # 定位到哪里
  ///
  /// ```text
  /// 已设过片头结束 → 定位到**片头结束**那一帧（用户最想看的就是这一帧对不对）
  /// 否则           → 定位到**片头开始**（默认 0 秒）
  /// ```
  ///
  /// ⚠️ **只 seek、不 play** —— 不违反"打开不自动播放"那条既有要求。
  ///    用户看到的是一张**静止的画面**，正是"这一秒切得对不对"的判据。
  ///
  /// ⚠️ 只做**一次**（`_didInitialSeek`）：时长流会反复回调，
  ///    每次都 seek 会把用户自己拖到的时间点冲掉。
  void _maybeInitialLocate() {
    if (_didInitialSeek) return;
    if (!mounted || _loading) return;
    if (_mediaDuration <= 0) return;   // 时长还没出来 → seek 会被丢弃
    if (_preview == null) return;

    _didInitialSeek = true;

    /*
     * 用户设过片头 ⇒ 停在"片头结束"，让他一眼看到"这里开始就是正片了"。
     * 没设过 ⇒ 停在 0（片头开始）。
     */
    final target = (_introEnd ?? _introStart ?? 0).toDouble();
    if (target <= 0 || target >= _mediaDuration) {
      // 0 秒没什么可定位的；但仍然要 seek 一次把首帧解出来
      unawaited(_previewSeek(0));
      return;
    }
    debugPrint('[SKIPDLG] 打开定位到片头结束 ${target.toStringAsFixed(0)}s（保持暂停）');
    unawaited(_previewSeek(target));
  }

  /// seek 之后回头核对"画面真的到那了吗"
  ///
  /// # 为什么必须核对（而不是"调用了就算成功"）
  ///
  /// seek **不会**因为被丢弃而抛异常 —— 唯一的判据是**位置有没有变过去**。
  /// 所以这里等 1.2 秒再读一次 `_rawPos`：
  /// ```text
  /// 到了目标附近（±3 秒）        → ✅ 落地
  /// 还在原来那（差得远）          → ❌ **真的被丢弃了**，重试一次
  /// ```
  /// ⚠️ 容差 3 秒是必要的：拖动时画面还在播，位置本来就会前进；
  ///    区间循环的目标点又常常在开头，读取时刻也会差个几百毫秒。
  ///
  /// ⚠️ 只重试**一次** —— 反复重试会在"这个源根本 seek 不动"时
  ///    变成一个死循环，反而把播放器打爆。
  Future<void> _verifySeek(double target, int token) async {
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (!mounted || token != _seekToken) return;

    final drift = (_rawPos - target).abs();
    if (drift <= 3.0) {
      debugPrint('[SKIPDLG] seek 已落地: 目标 ${target.toStringAsFixed(1)}s，'
          '实际 ${_rawPos.toStringAsFixed(1)}s');
      return;
    }

    /*
     * ★ 这里就是那个"静默丢弃"被抓住的地方。
     *   原实现只打"已 seek 到 Ns"，所以**永远看不出失败**。
     */
    debugPrint('[SKIPDLG] ⚠️ seek 疑似被丢弃: 目标 ${target.toStringAsFixed(1)}s，'
        '实际 ${_rawPos.toStringAsFixed(1)}s（差 ${drift.toStringAsFixed(1)}s）—— 重试一次');

    final p = _preview;
    if (p == null) return;
    await p.seek(Duration(milliseconds: (target * 1000).round()));
  }

  /// 「预览」按钮：跳到某点，**停在那一帧**给用户看
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ task-66（2026-09-27）：Owner 要求「四个按钮显示对应的那一帧」
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// # Owner 原话（逐字）
  /// ```text
  /// > 点击片头片尾那四个按钮可以显示出对应的停止的那一帧的画面，
  /// > 方便确认自己没有截取错
  /// ```
  ///
  /// # 为什么不能直接用 `_previewSeek`
  ///
  /// `_previewSeek` **只 seek、不暂停**。而用户上一步很可能是
  /// 点了「整段」（`_previewRange` ⇒ `play()`）—— 那时播放器**正在播**，
  /// 于是 seek 过去之后画面**继续往前走**，用户根本来不及看那一帧。
  /// ⇒ 观感是"点了预览，画面一闪而过"，与 Owner 要的"停在那一帧"相反。
  ///
  /// # 为什么暂停要放在这里、而不是塞进 `_previewSeek`
  ///
  /// `_previewRange` 内部也调 `_previewSeek`（然后紧接着 `play()`）。
  /// 若把 `pause()` 塞进 `_previewSeek`，它会**晚于** `play()` 落地
  /// （`_previewSeek` 是 async，要先 await 等时长）——
  /// ⇒ **把区间循环播放直接掐死**（点了「整段」却一动不动）。
  /// ⇒ 所以拆成两个方法：`_previewSeek` = 纯定位，`_previewFrame` = 定位 + 停住。
  ///
  /// # 顺带把"区间循环"退出干净
  ///
  /// 用户点了某一帧之后，就不该再被 `_loopTimer` 拉回区间里 ——
  /// 那会变成"我点的是片尾，它却把我拽回片头"，比不响应更糟。
  Future<void> _previewFrame(num seconds) async {
    _loopTimer?.cancel();
    _loopTimer = null;
    _loopFrom = null;
    _loopTo = null;
    // ★ 2026-10-02：也要清掉"正在播哪一段" —— 否则按钮会一直显示「暂停」
    _playingRange = null;
    _preview?.pause();
    if (mounted) setState(() {});
    await _previewSeek(seconds);
  }

  /// ★★★ 2026-10-06（task-13 ⑥）：**单击 ⇒ 预览该端点停留的那一帧**
  ///
  /// Owner 原话（逐字）：
  /// 「片头片尾的片头 片尾 的开始与结束，单独点击预览没有反应，
  ///   点击后应该预览这一帧的画面才对，剪头也是一样的，
  ///   支持单击后预览这个停留的位置的画面」
  ///
  /// # 两条入口都走这里（同一个语义只实现一次）
  /// ```text
  /// ① 时间轴上**单击箭头**（含未设置时的幽灵箭头）⇒ SkipTimeline.onTapEdge
  /// ② 读数行**单击那个秒数文本**          ⇒ _EdgeRow.onTapValue
  /// ```
  /// ⚠️ 第三个入口是既有的「▶ 预览」按钮（onPreview ⇒ _previewFrame），
  ///    三个都落在**同一个** _previewFrame 上 —— 不再各写一套。
  ///
  /// # 已设置 / 未设置 分别预览哪里
  /// ```text
  /// 已设置  ⇒ 该端点自己的值（就是"这一刀切在这儿"的那一帧）
  /// 未设置  ⇒ 该端点"若现在设下去会落在哪"（见 _defaultAt）
  /// ```
  /// ★ 为什么未设置也要有反应：Owner 说的是「点击预览**没有反应**」——
  ///   改前四个幽灵箭头是**画出来的**（可交互的样子）却点了没动静。
  ///   画出来的东西就该有反应（同 hitEdge 用幽灵位置参与命中那条纪律）。
  ///
  /// # 为什么不是"播放该点所在的区间"
  /// Owner 这次要的是「预览**这一帧**的画面」；"整段"已经有**独立按钮**
  /// （_rangePreviewRow 的「片头整段 / 片尾整段」）⇒ 单击一律**定格该帧**。
  void _tapEdge(SkipEdge e) {
    /*
     * 预览真的不可用时**如实说**（不静默）—— 否则用户点箭头又是"没反应"，
     * 而这次的原因是"预览起不来"，与改前那个 bug 表现一样、原因不同。
     */
    final err = _previewError;
    if (err != null) {
      debugPrint('[SKIPDLG] 单击${_edgeName(e)}：预览不可用（$err）—— 仍按设置走');
      _toast('预览不可用：$err');
    }
    final v = switch (e) {
      SkipEdge.introStart => _introStart,
      SkipEdge.introEnd => _introEnd,
      SkipEdge.outroStart => _outroStart,
      SkipEdge.outroEnd => _outroEnd,
    };
    if (v != null) {
      debugPrint('[SKIPDLG] 单击 ${_edgeName(e)}（= ${_fmtSeconds(v)}）⇒ 预览该帧并停住');
      unawaited(_previewFrame(v));
      return;
    }
    final d = _defaultAt(e);
    debugPrint('[SKIPDLG] 单击 ${_edgeName(e)}（未设置）⇒ 定格到默认位置 ${_fmtSeconds(d)} 并停住');
    unawaited(_previewFrame(d));
  }

  /// 某个端点**未设置**时，"现在设下去会落在哪" —— 与「整段」按钮的默认区间同源
  ///
  /// ```text
  /// 片头开始 0                 片头结束 30（或总长）
  /// 片尾开始 总长-30           片尾结束 总长
  /// ```
  /// ⚠️ 与 _rangePreviewRow 里那两个 fallback **必须一致** ——
  ///    否则"点箭头看到的位置"和"点整段播的位置"对不上（同一个概念两个数）。
  /// ⚠️ 还要过一遍 _clampTo：别的端点可能已经把它挤走了
  ///    （例：片尾开始已设 20 ⇒ 片头结束的默认 30 越界，应预览 19）。
  int _defaultAt(SkipEdge e) {
    final total = _total.toInt();
    const span = 30;
    final tailFrom = (total - span).clamp(0, total);
    final raw = switch (e) {
      SkipEdge.introStart => 0,
      SkipEdge.introEnd => span.clamp(0, total),
      SkipEdge.outroStart => tailFrom,
      SkipEdge.outroEnd => total,
    };
    return _clampTo(raw, e);
  }

  /// 循环预览某个区间（「整段」按钮）
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★ task-57 的历史：一度被改成"抓一帧"（方案 D），**已回退**
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// 原版是 `previewRange(from, to)` —— 设片头时反复看那几十秒，
  /// 这是"设得对不对"的唯一验证方式。
  ///
  /// ⚠️ Owner 原话里的「**并且可以预览的**」指的就是这个：
  ///    预览要能**播**（看到运动），不是一张静止图。
  ///
  /// ⚠️ task-66：**这个能力必须保留** —— Owner 这次明确又说了一遍
  ///    「预览还要支持预览片头 片尾**整段**」。
  ///    所以它从"结束点那个预览按钮"挪到了**独立的「整段」按钮**上
  ///    （四个预览按钮改成统一"显示该帧"，见 `_previewFrame`）。
  ///
  /// ══════════════════════════════════════════════════════════════════════
  /// ★★★ 2026-10-02：加**暂停**（Owner：「预览的时候不支持暂停」）
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// # 改前的问题
  /// ```text
  /// 点「片头整段」⇒ 开始循环播 ⇒ **没有任何办法停下来**
  ///   · 再点一次？同一个按钮，但 onPressed 又是 `_previewRange` ⇒ 重头播
  ///   · 想停在某一帧仔细看？做不到
  /// ⇒ 只能关掉弹窗，或者点别的东西把它顶掉
  /// ```
  ///
  /// # 修法：同一个按钮**切换**播放/暂停
  /// ```text
  /// 没在播       ⇒ 点 ⇒ 从区间开头循环播（按钮变「⏸ 暂停」）
  /// 正在播这段   ⇒ 点 ⇒ **暂停在当前帧**（按钮变回「▶ 片头整段」）
  /// 正在播另一段 ⇒ 点 ⇒ 切到这一段播
  /// ```
  /// ⇒ 见 `_toggleRange`（它才是按钮的 `onPressed`）。
  ///
  /// # 暂停语义：**停在当前帧**，不回开头
  /// ★ 与 `_previewFrame` 同一个原则 —— Owner 反复要的是
  ///   "看清楚这一帧"，回开头等于把他刚看到的东西弄丢了。
  void _previewRange(int from, int to, {SkipEdge? which}) {
    _loopTimer?.cancel();
    if (to <= from) return;
    _loopFrom = from;
    _loopTo = to;
    _playingRange = which;
    unawaited(_previewSeek(from));
    _preview?.play();
    if (mounted) setState(() {}); // 让按钮立刻变成「暂停」

    /*
     * 用 200ms 的轮询而不是监听 position 流 ——
     * 流的频率取决于解码（可能很高），每次都判区间会浪费；
     * 200ms 对"人眼判断位置"完全够（相邻两次跳 0.2 秒看不出来）。
     *
     * ⚠️ 判据用 `_rawPos`（播放器真实位置）而**不是** `_previewPos`：
     *    `_previewPos` 是乐观值，seek 被静默丢弃时它照样是目标值 ——
     *    拿它判循环会在"画面根本没跳回去"时以为循环成功了。
     */
    _loopTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) {
        _loopTimer?.cancel();
        return;
      }
      /*
       * ★ 顺带把"当前到哪了"喂给时间轴读数（Owner 要看到位置）。
       *   ⚠️ 只在**真的变了**时 setState —— 每 200ms 无条件重建
       *      会让整页反复刷新（弹窗里有视频纹理，代价不小）。
       */
      if ((_shownPos - _rawPos).abs() > 0.4) {
        setState(() => _shownPos = _rawPos);
      }
      if (_loopTo == null || _rawPos >= _loopTo!) {
        unawaited(_previewSeek(_loopFrom!));
        _preview?.play();
      }
    });
  }

  /// 「整段」按钮的动作：**播放 ⇄ 暂停** 切换
  ///
  /// 见 `_previewRange` 的说明（Owner：「预览的时候不支持暂停」）。
  ///
  /// ⚠️ 暂停时**停在当前帧**（不 seek 回开头）——
  ///    Owner 要的是"停下来让我看清这一帧"。
  ///    `_previewFrame` 正好是这个语义（退循环 + pause + seek）。
  void _toggleRange(SkipEdge which, int from, int to) {
    if (_playingRange == which) {
      // 正在播这一段 ⇒ 暂停在当前帧
      final cur = _rawPos > 0 ? _rawPos : from.toDouble();
      _stopRange();
      unawaited(_previewFrame(cur));
      return;
    }
    // 没在播 / 在播另一段 ⇒ 播这一段
    _previewRange(from, to, which: which);
  }

  /// 停止区间循环（**不 seek** —— 由调用方决定停在哪一帧）
  void _stopRange() {
    _loopTimer?.cancel();
    _loopTimer = null;
    _loopFrom = null;
    _loopTo = null;
    _playingRange = null;
    _preview?.pause();
    if (mounted) setState(() {});
  }

  /// 保存
  Future<void> _save() async {
    /*
     * ★ 前端也要校验区间合法性（2026-09-24）
     *
     * 原版注释：
     * > ⚠️ 后端会校验区间合法性（start < end、片头在片尾之前），
     * >    违反时**抛错**。
     *
     * 但让用户点了"确认"才看到报错很糟 —— 这里先在 UI 层拦一道，
     * 把不合法的组合直接禁用按钮（见 `_canSave`）。
     */
    setState(() => _saving = true);
    try {
      await SourinApi.setSkipMarker(
        widget.provider,
        widget.id,
        title: widget.title,
        introStart: _introStart,
        introEnd: _introEnd,
        outroStart: _outroStart,
        outroEnd: _outroEnd,
        autoSkip: _autoSkip,
      );
      if (!mounted) return;
      Navigator.of(context).pop(SkipMarkerResult(
        introStart: _introStart,
        introEnd: _introEnd,
        outroStart: _outroStart,
        outroEnd: _outroEnd,
        autoSkip: _autoSkip,
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('保存失败：$e');
    }
  }

  /// 重置（清空四个点）
  Future<void> _reset() async {
    try {
      await SourinApi.clearSkipMarker(widget.provider, widget.id);
    } catch (e) {
      debugPrint('[SKIPDLG] 清除失败: $e');
    }
    if (!mounted) return;
    setState(() {
      _introStart = null;
      _introEnd = null;
      _outroStart = null;
      _outroEnd = null;
    });
    _toast('已重置');
  }

  /// 能不能保存（区间合法性 —— 原版后端会抛错，这里提前拦）
  bool get _canSave {
    if (_saving) return false;
    // 片头：起点 < 终点
    if (_introStart != null && _introEnd != null && _introStart! >= _introEnd!) {
      return false;
    }
    // 片尾：起点 < 终点
    if (_outroStart != null && _outroEnd != null && _outroStart! >= _outroEnd!) {
      return false;
    }
    // 片头必须在片尾之前
    if (_introEnd != null && _outroStart != null && _introEnd! > _outroStart!) {
      return false;
    }
    return true;
  }

  /// 弹一条 2 秒的提示（"被夹到边界了"）
  ///
  /// ══════════════════════════════════════════════════════════════════════
  /// ★★★ 2026-10-02：**提示失败绝不能让功能挂掉**（真 bug）
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// # 改前
  /// ```dart
  /// final messenger = ScaffoldMessenger.maybeOf(context);
  /// messenger?.showSnackBar(...);   // ← 看着是安全的（有 `?.`）
  /// ```
  /// ★ 但**本弹窗没有 `Scaffold` 祖先** ⇒ `showSnackBar` 内部抛断言：
  /// ```text
  /// '_scaffolds.isNotEmpty': ScaffoldMessenger.showSnackBar was called,
  /// but there are currently no descendant Scaffolds to present to.
  /// ```
  /// `maybeOf` 只保证 **messenger 存在**，不保证它**能显示** ——
  /// `MaterialApp` 自带一个 messenger，所以 `maybeOf` 一直非 null。
  ///
  /// # 后果（`t463` 抓到的真 bug）
  /// `_applyEdge` 里 `_toast` 在赋值**之前** ⇒ 异常把 `switch` 的赋值吞掉
  /// ⇒ **只要「+」被夹到边界，值就卡住不动**。
  /// Owner 看到的就是「那四个三角根本不能拖动 / 调不动」。
  ///
  /// ★★★ 2026-10-02：判据从 `Scaffold.maybeOf` 改成**直接试**（探针实测）
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// # 我第一版写错了判据
  /// ```dart
  /// if (Scaffold.maybeOf(context) == null) { debugPrint(...); return; }
  /// ```
  /// 理由看着很顺：「弹窗没有 `Scaffold` 祖先 ⇒ `showSnackBar` 会抛」。
  /// ★ 但 `showSnackBar` 的断言**不是**这个：
  /// ```dart
  /// assert(_scaffolds.isNotEmpty, '...no descendant Scaffolds to present to.');
  /// ```
  /// `_scaffolds` 是**注册到 messenger 的 `ScaffoldState` 列表**，
  /// 与"弹窗的祖先里有没有 Scaffold"**不是一回事**。
  ///
  /// # 生产里的实际结构
  /// ```text
  /// MaterialApp → ScaffoldMessenger → Navigator
  ///                                   ├─ 路由1：PlayerPage（**有** Scaffold）
  ///                                   └─ 路由2：Dialog（弹窗本体，兄弟关系）
  /// ```
  /// 弹窗往上找不到 Scaffold ⇒ `Scaffold.maybeOf(弹窗ctx) == null` 成立，
  /// **但** PlayerPage 那个 Scaffold 已经注册进同一个 messenger
  /// ⇒ `_scaffolds` 非空 ⇒ `showSnackBar` **根本不抛**，
  ///    SnackBar 显示在页面 Scaffold 里（半透明 barrier 之下，仍可见）。
  ///
  /// # 实测（`.probe/probe_tests/zz_snackbar_host_probe_test.dart`）
  /// ```text
  /// 生产同构树（页面有 Scaffold + showDialog）：
  ///   Scaffold.maybeOf(弹窗ctx) != null  = false   ← 我那条守卫会 return
  ///   ScaffoldMessenger.maybeOf != null  = true
  ///   showSnackBar 抛了 = null                     ← ★ 其实不抛
  ///   showSnackBar 成功入队 = true
  /// 阴性对照（全树无 Scaffold）：
  ///   showSnackBar 抛了 = '_scaffolds.isNotEmpty'  ← 仪器确实读得到"抛"
  /// ```
  /// ⇒ ★ 那条守卫**把生产里本来能用的提示静默关掉了** ——
  ///    而用户的要求恰恰是「**不能静默**」。
  ///    现象：探针日志里全是 `无 Scaffold，提示改为日志：…`。
  ///
  /// # 正确判据：**别预判，直接试**
  /// ```text
  /// try { showSnackBar(...) } catch { 降级成日志 }
  /// ```
  /// `try/catch` 是**唯一**与 `showSnackBar` 真实前提一致的判据 ——
  /// 它不猜前提，而是让前提自己表态。
  /// ★ 通用教训：**能"试"就不要"猜"**。预判的前提一旦与实际不符，
  ///   要么误伤（本次：静默关掉能用的提示），要么漏判。
  ///
  /// # 改前的问题（仍然成立，是加 `try/catch` 的理由）
  /// ```dart
  /// ScaffoldMessenger.maybeOf(context)?.showSnackBar(...);  // 看着安全（有 ?.）
  /// ```
  /// `maybeOf` 只保证 **messenger 存在**，不保证它**能显示** ——
  /// `MaterialApp` 自带一个 messenger，所以 `maybeOf` 一直非 null。
  ///
  /// # 后果（`t463` 抓到的真 bug）
  /// `_applyEdge` 里 `_toast` 在赋值**之前** ⇒ 异常把 `switch` 的赋值吞掉
  /// ⇒ **只要「+」被夹到边界，值就卡住不动**。
  /// Owner 看到的就是「那四个三角根本不能拖动 / 调不动」。
  ///
  /// # 修法
  /// ```text
  /// ① `_toast` 整个调用包 `try/catch` —— 提示是**尽力而为**的东西，
  ///    任何情况下都不该让调用方崩（测试宿主里确实会抛，见阴性对照）
  /// ② `_applyEdge` 那边**也**改了顺序（先赋值后提示）——
  ///    两层保护：即使将来 `_toast` 又抛，值也已经写进去了
  /// ```
  void _toast(String msg) {
    try {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
    } catch (e) {
      // ★ 提示失败**绝不能**影响功能 —— 降级成一行日志
      //   测试宿主（全树无 Scaffold）会走到这里，生产不会
      debugPrint('[SKIPDLG] 提示失败（已忽略）：$e / 原文：$msg');
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ 四个点的**上下界**（2026-09-25 用户实测：「开始不能超过结束」）
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 用户原话
  //
  // > 这四个按钮，都是**开始不能超过结束**的，**这个逻辑你没做**
  //
  // # 真机实测确认用户说得对（`.probe\dlg\dlg-probe.txt`）
  //
  // 改前把「片头开始」点到 10、「片头结束」留在 5 —— 摘要变成
  // `片头 00:10 - 00:05`，**值真的越界存下来了**。
  // 直到这时底部才冒出一行红字「区间不合法」，保存按钮变灰：
  // ```text
  // 第 6 次后: 摘要=片头 00:06 - 00:05  越界提示=区间不合法：...
  // ★ 最终摘要 = 片头 00:10 - 00:05    越界提示=区间不合法：...
  // ```
  //
  // # 为什么"底部报错 + 置灰"不够（这是用户抱怨的实质）
  //
  // ```text
  // ① 值已经写进去了 —— 用户看到的是"片头 00:10 - 00:05"这种**倒过来的区间**，
  //    时间轴上两个箭头的位置也乱了，画面处于一个"不该存在"的状态
  // ② 报错在**底部**，而行在**中间** —— 用户点第 4 行，提示出现在
  //    400px 以外的地方，视线根本不会过去（"不能静默"至少要做到就近）
  // ③ 用户的原话是「**开始不能超过结束**」—— 他要的是**根本点不过去**，
  //    而不是"点过去以后再告诉他错了"
  // ```
  //
  // # 修法：三层，从"根本不让越界"到"越界了也看得见"
  //
  // ```text
  // ① clamp  ——  −/+ 和拖拽都被夹在该点的合法区间内（值永不越界）
  // ② 置灰   ——  到边界后那个按钮变灰（用户看得出"到头了"）
  // ③ 就近提示 —— 每行右侧显示它自己的约束（如「≤ 01:30」）
  // ```
  //
  // ⚠️ 三层都要有：只 clamp 的话用户会觉得"按钮坏了，点了没反应"；
  //    只提示的话值还是能越界（就是现在的 bug）。

  /// 某个点的**合法区间** `[lo, hi]`
  ///
  /// 规则（就是用户说的"开始不能超过结束"，展开成四个点各自的界）：
  /// ```text
  /// 片头开始   [0,        片头结束-1 或 总长]
  /// 片头结束   [片头开始+1, 片尾开始-1 或 总长]
  /// 片尾开始   [片头结束+1, 片尾结束-1 或 总长]
  /// 片尾结束   [片尾开始+1, 总长]
  /// ```
  ///
  /// ⚠️ 用 `-1`/`+1` 而不是 `<=`：本项目与后端都要求**严格**
  ///    `起点 < 终点`（见 `_canSave` 的 `>=` 判断和后端 `start < end` 校验）。
  ///    允许相等会在保存时被后端打回 —— 那又是一次"点了没反应"。
  ///
  /// ══════════════════════════════════════════════════════════════════════
  /// ★★★ 2026-10-02：修**两个漏洞**（Owner 第三次说"四条互斥"时测试抓到的）
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// # Owner 原话（逐字）
  /// ```text
  /// 「还有这四个是互斥关系,片尾的两个箭头不能跑到片头的两个前面去
  ///   然后 片头的两个,片头的结束不能跑到片头的开始前面去
  ///   片尾的也是同理」
  /// ```
  ///
  /// # 漏洞 ①：`introStart` 的上界**只看 `introEnd`**，不看 `outroStart`
  /// ```text
  /// 改前：introStart.hi = _introEnd != null ? _introEnd-1 : total
  /// 场景：introEnd == null 而 outroStart == 3
  ///   ⇒ introStart.hi = total = 2826
  ///   ⇒ 用户可以把「片头开始」拖到 2648
  ///   ⇒ ★ 它跑到了「片尾开始」(3) 的**右边** —— 片头整对跑到片尾后面了
  /// 实测（t463）：拖 introStart 到 90% ⇒ [2648, null, 3, null]  ✗
  /// ```
  /// ⇒ **上界必须取"所有右侧邻居"里最近的那个**：
  ///    `min(introEnd-1, outroStart-1, outroEnd-1)` 中**存在**的那些。
  ///
  /// # 漏洞 ②：`introEnd` 的上界**只看 `outroStart`** —— 这条是对的，
  /// 但**下界只看 `introStart`** ⇒ `introStart == null` 时下界是 0。
  /// 配合漏洞 ①，就出现了实测里的：
  /// ```text
  /// [2648, 2649, 3, null]   ← introEnd(2649) > outroStart(3) ✗
  /// ```
  /// （那次 `introEnd` 被拖到 5%，但起点位置让它算出 2649 —— 而
  ///   `_boundFor(introEnd)` 的 hi 本该是 `outroStart-1 = 2`，
  ///   所以**这条其实是漏洞 ① 的连锁**：introStart 先跑到 2648，
  ///   然后 introEnd 的下界变成 2649，夹取返回 `lo`（因为 lo > hi）
  ///   ⇒ 落在 2649。见 `_clampTo` 的"区间退化返回 lo"。）
  /// ```
  ///
  /// # 修法：上界取**所有右侧邻居**的最小值
  ///
  /// ★ 关键洞察：**"最近的那个右侧邻居"才是真正的约束**。
  ///   原来每个点只看了"紧挨着的下一个"（按语义顺序），
  ///   但**那个邻居可能是 null**（未设置）—— 而 null 不代表"没有约束"，
  ///   只代表"这个点还没设"。⇒ 必须**继续往右找**。
  (int, int) _boundFor(SkipEdge e) {
    final total = _total.toInt();

    /// 右侧邻居里**最近**的那个值（不存在则 null）
    int? nearestRight(SkipEdge self) {
      final order = [
        (SkipEdge.introStart, _introStart),
        (SkipEdge.introEnd, _introEnd),
        (SkipEdge.outroStart, _outroStart),
        (SkipEdge.outroEnd, _outroEnd),
      ];
      final myIdx = order.indexWhere((p) => p.$1 == self);
      int? best;
      for (var i = myIdx + 1; i < order.length; i++) {
        final v = order[i].$2;
        if (v != null && (best == null || v < best)) best = v;
      }
      return best;
    }

    /// 左侧邻居里**最近**的那个值（不存在则 null）
    int? nearestLeft(SkipEdge self) {
      final order = [
        (SkipEdge.introStart, _introStart),
        (SkipEdge.introEnd, _introEnd),
        (SkipEdge.outroStart, _outroStart),
        (SkipEdge.outroEnd, _outroEnd),
      ];
      final myIdx = order.indexWhere((p) => p.$1 == self);
      int? best;
      for (var i = myIdx - 1; i >= 0; i--) {
        final v = order[i].$2;
        if (v != null && (best == null || v > best)) best = v;
      }
      return best;
    }

    final right = nearestRight(e);
    final hi = right != null ? right - 1 : total;
    final left = nearestLeft(e);
    final lo = left != null ? left + 1 : 0;

    return (lo.clamp(0, total), hi.clamp(0, total));
  }

  /// 把用户想设的值**夹**进该点的合法区间，并在**真的夹到了**时给出提示
  ///
  /// ⚠️ 这是"开始不能超过结束"的执行点 —— `−/+` 和拖拽都走它。
  ///    夹住之后值**永远合法**，底部的红字提示因此不会再出现
  ///    （那是给"加载进来的历史数据本身就非法"兜底的）。
  ///
  /// # 为什么夹到了要 `_toast`（"不能静默"）
  ///
  /// 拖时间轴时箭头**会停在边界不动** —— 如果没有提示，用户的感受是
  /// "箭头卡住了 / 拖不动了"，而不是"到头了，因为不能超过片头结束"。
  /// 一句话的成本换掉一个"功能坏了"的误解，很值。
  void _applyEdge(int? want, SkipEdge e) {
    setState(() {
      final clamped = want == null ? null : _clampTo(want, e);
      /*
       * ══════════════════════════════════════════════════════════════════
       * ★★★ 2026-10-02：**先赋值，再提示**（顺序是 bug 的一部分）
       * ══════════════════════════════════════════════════════════════════
       *
       * # 改前的顺序（赋值在提示**之后**）
       * ```text
       * clamped 算好
       *   ⇒ if (被夹住) _toast(...)     ← ★ 这里会**抛异常**
       *   ⇒ switch (e) { _introEnd = clamped; }   ← 永远执行不到
       * ```
       *
       * # 真 bug（`t463` 抓到的）
       * `_toast` 用 `ScaffoldMessenger.showSnackBar`，而本弹窗**没有
       * `Scaffold` 祖先** ⇒ 抛断言：
       * ```text
       * '_scaffolds.isNotEmpty': ScaffoldMessenger.showSnackBar was called,
       * but there are currently no descendant Scaffolds to present to.
       * ```
       * ⇒ **只要「+」被夹到边界，赋值就被跳过** ⇒ 值卡在原地不动。
       * 实测（点「片头结束」的 +，因为 introStart=1 把下界顶到 2）：
       * ```text
       * _applyEdge(1, introEnd) bound=(2, 2826)
       *   clamped=2
       *   ⇒ ★ 之后再无日志 —— 异常把赋值吞了
       * 最终 introEnd 仍是 null
       * ```
       * ★ Owner 看到的现象就是「**那四个三角根本不能拖动 / 调不动**」。
       *
       * # 修法：两处
       * ```text
       * ① **先赋值**，把提示挪到最后 —— 提示失败不该影响状态正确性
       * ② `_toast` 自己吞掉异常（见它的说明）——
       *    一个"提示"永远不该让功能挂掉
       * ```
       * ★ 顺序这条是通用纪律：**状态变更要放在可能失败的操作之前**。
       */
      switch (e) {
        case SkipEdge.introStart:
          _introStart = clamped;
        case SkipEdge.introEnd:
          _introEnd = clamped;
        case SkipEdge.outroStart:
          _outroStart = clamped;
        case SkipEdge.outroEnd:
          _outroEnd = clamped;
      }
      // ★ 赋值**之后**才提示（提示失败不影响值）
      //   `clamped` 是 `int?`（want == null = 清除），所以两个都要判空；
      //   单独写 `final c = clamped` 才能让下面的 `c` 提升成非空 `int`。
      final c = clamped;
      if (want != null && c != null && c != want) {
        /*
         * ══════════════════════════════════════════════════════════════════
         * ★★★ 2026-10-02：这条提示曾经是**乱码**（probe 日志抓到的）
         * ══════════════════════════════════════════════════════════════════
         *
         * # 实测日志（`.probe/probe_tests/skip_dialog_rows_test.dart`）
         * ```text
         * [SKIPDLG] 无 Scaffold，提示改为日志：片头结束不能超过
         * Closure: (SkipEdge) => String from Function '_peerName@…':.(e)（下限 00:04）
         * ```
         * ⚠️ 前缀 `无 Scaffold，提示改为日志：` 是**当时** `_toast` 里那条
         *    过严守卫打的（已删，见它的说明）—— 现在这里会打成
         *    `提示失败（已忽略）：…` 或直接弹出来。乱码部分才是本条要说的。
         *
         * 用户看到的将是 `Closure: (SkipEdge) => String …` —— 一句话里三个缺陷：
         *
         * ```text
         * ① 花括号漏了：`$` 后面直接跟方法名时，插值**只吃掉标识符**，
         *    于是把**函数对象**打进了字符串，紧跟的括号变成字面量。
         *    ⇒ 必须写成 `${方法名(参数)}`。
         * ② 方向写死成「不能超过」—— 撞**下界**时方向是反的：
         *    用户读到"不能超过"会去改**右边**那个点，改错了地方。
         * ③ 被谁挡住是**猜**的（`_outroStart != null ? '片尾开始' : '片头开始'`）——
         *    `_outroStart == null`（界其实来自总长）时会说出一个**没设的点**；
         *    而且 `_peerName(introStart)` 恒等于「片头结束」，
         *    可它的上界可能来自 `outroStart` / `outroEnd`。
         * ```
         *
         * # 修法：三件事全部**从实际结果反推**，一个都不猜
         * ```text
         * up = clamped < want   ← 被往下夹 = 撞上界（不是拿 want 和 hi 比大小）
         * 挡住它的是谁：上界来自「邻居 - 1」⇒ 谁的值等于 hi + 1，谁就是约束方
         *               下界来自「邻居 + 1」⇒ 谁的值等于 lo - 1，谁就是约束方
         *               反查不到 ⇒ 这条界来自视频本身（总长 / 开头）
         * 报的数字用 clamped（**真正落到的值**），不是 hi/lo
         * ```
         * ★ 反查是**从 `_boundFor` 的输出出发**的 ⇒ 不可能与它不一致。
         *   这正是本文件反复踩的那个坑的解法：「同一条规则两个实现」。
         */
        final up = c < want;
        final (lo, hi) = _boundFor(e);
        final peer = _edgeHolding(up ? hi + 1 : lo - 1);
        final where =
            peer != null ? _edgeName(peer) : (up ? '视频总长' : '视频开头');
        // ★ 两个方向词都必须是**真文案**（不是注释里的字）：
        //   撞下界还说"不能超过"，用户就会去改右边那个点。
        final verb = up ? '不能超过' : '不能小于';
        _toast('${_edgeName(e)}$verb$where（${up ? '上限' : '下限'} ${_fmtSeconds(c)}）');
      }
    });

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ task-57：改完边界**预览跟着走**（修「调完不知道调对没有」）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 改前的问题（用户直接问的那条）
     *
     * `_applyEdge` 只改状态、**不动预览** —— 于是：
     * ```text
     * 用户点「+」把片头结束从 01:09 调到 01:12
     *   ⇒ 行里的数字变了
     *   ⇒ ★ 但上面的预览画面**一动不动**（还停在上一次 seek 的位置）
     * ⇒ 用户只能"设个数字，然后点一下『预览』才知道对不对"
     *   —— 而这正是"调完不知道调对没有"
     * ```
     *
     * # 改后
     *
     * 每次改完边界 ⇒ 预览 seek 到**新的那个点** ⇒ 画面立刻跟上。
     * 用户点一下「+」，上面那张图就换一帧 —— **所见即所得**。
     *
     * ★★ 2026-10-02 补充：跟随的同时**要停住**。
     *    Owner：「在播放的过程中,拖动调整片头片尾,状态应该重置,
     *    不应该继续播放,应该是变回拖动结束后的那一帧预览」
     *    ⇒ `_followPreviewTo` 内部走 `_previewFrame`
     *      （退出区间循环 + `pause()` + seek），不是只 seek。
     *
     * # ⚠️ 为什么要 debounce（250ms）
     *
     * `_applyEdge` 是**高频**调用的：
     * ```text
     * · 点住「+」不放 ⇒ 每 ~50ms 一次
     * · 时间轴上拖动   ⇒ 每帧一次
     * ```
     * 每次都 `_previewSeek` 的话：seek 是异步且要等时长的，
     * 会堆一堆排队请求（虽然 `_seekToken` 保证只有最后一个生效，
     * 但**白解码**很多次，弱网源上尤其浪费）。
     * ⇒ 用 250ms 的 debounce **合并**连续改动，只对"停下来之后的值"seek 一次。
     *   （250ms 对人眼几乎无感，而"停手就看到结果"完全满足）
     *
     * ⚠️ 只 seek **预览播放器**，**不碰主播放器** ——
     *    Owner 的「而不是跟底层的进行联动」照旧满足。
     */
    if (want == null) return; // 清空（长按清除）没什么可定位的
    _followPreviewTo(e);
  }

  /// 「改完某个边界 ⇒ 预览跟到那个点」（250ms debounce）
  ///
  /// ══════════════════════════════════════════════════════════════════════
  /// ★★★ 为什么抽成独立方法（2026-10-01）
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// 这段逻辑原来**内联在 `_applyEdge` 里**（读数行的 +/- 用）。
  /// 而**时间轴拖拽**（`SkipTimeline.onChanged`）是另一条链路，
  /// 它**只改数值、没有这段** ⇒ Owner 报「拖完松手不知道定在哪一帧」
  /// ⇒ 「设置根本没用」。
  ///
  /// ★ 抽出来后两条链路**共用同一个实现** —— 这正是本仓反复吃过的亏：
  ///   「同一个语义在两处各写一遍 ⇒ 只改了一处 ⇒ 另一处静默漂移」
  ///   （见 `skipIntroColor` / `skipOutroColor` 的说明、
  ///     以及 `_arrowW` 与 `kArrowW` 两份常量的旧坑）。
  ///
  /// ⚠️ 只 seek **预览播放器**，**不碰主播放器** ——
  ///    Owner 的「而不是跟底层的进行联动」照旧满足。
  /// 「改完某个边界 ⇒ 预览跟到那个点**并停住**」
  ///
  /// ══════════════════════════════════════════════════════════════════════
  /// ★★★ 为什么抽成独立方法（2026-10-01）
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// 这段逻辑原来**内联在 `_applyEdge` 里**（读数行的 +/- 用）。
  /// 而**时间轴拖拽**（`SkipTimeline.onChanged`）是另一条链路，
  /// 它**只改数值、没有这段** ⇒ Owner 报「拖完松手不知道定在哪一帧」
  /// ⇒ 「设置根本没用」。
  ///
  /// ★ 抽出来后两条链路**共用同一个实现** —— 这正是本仓反复吃过的亏：
  ///   「同一个语义在两处各写一遍 ⇒ 只改了一处 ⇒ 另一处静默漂移」
  ///
  /// ══════════════════════════════════════════════════════════════════════
  /// ★★★ 2026-10-02：**播放中拖动 ⇒ 必须停住**（Owner 第三次反馈）
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// # Owner 原话（逐字）
  /// ```text
  /// 「在播放的过程中,拖动调整片头片尾,状态应该重置,不应该继续播放,
  ///   应该是变回拖动结束后的那一帧预览」
  /// ```
  ///
  /// # 改前的行为（真 bug）
  /// ```text
  /// 用户点了「整段」⇒ _previewRange ⇒ _preview.play()  ← 预览**正在播**
  /// 然后去拖时间轴上的箭头
  ///   ⇒ onChanged ⇒ _followPreviewTo ⇒ _previewSeek(v)
  ///   ⇒ ★ `_previewSeek` **只 seek、不暂停**（见它的文档）
  ///   ⇒ 画面 seek 过去之后**继续往前走**
  ///   ⇒ 用户根本来不及看那一帧 ⇒ 「状态应该重置，不应该继续播放」
  /// ```
  /// ★ 更糟的是 `_loopTimer` **还在跑**：
  ///   区间循环每 200ms 检查一次，发现位置越界就把画面**拽回区间起点**
  ///   ⇒ 用户拖完看到的是"画面自己跳回去了"，比不响应更迷惑。
  ///
  /// # 修法：走 `_previewFrame` 而不是 `_previewSeek`
  /// `_previewFrame` **本来就是**为这个语义写的（见它的文档）：
  /// ```text
  /// _loopTimer?.cancel()  ⇒ 退出区间循环（"状态重置"）
  /// _preview?.pause()     ⇒ 停住（"不应该继续播放"）
  /// await _previewSeek(v) ⇒ 定位到新边界
  /// ⇒ 三件事正好就是 Owner 要的"变回拖动结束后的那一帧预览"
  /// ```
  /// ★ 而 `_applyEdge`（读数行的 +/-）**也**该走同一条路 ——
  ///   它原来也调 `_previewSeek`，同样有"播放中改了不停住"的问题。
  ///   ⇒ 两条链路一起改成 `_previewFrame`，语义统一。
  ///
  /// ⚠️ 只 seek **预览播放器**，**不碰主播放器** ——
  ///    Owner 的「而不是跟底层的进行联动」照旧满足。
  void _followPreviewTo(SkipEdge e) {
    _followTimer?.cancel();
    _followTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      final v = switch (e) {
        SkipEdge.introStart => _introStart,
        SkipEdge.introEnd => _introEnd,
        SkipEdge.outroStart => _outroStart,
        SkipEdge.outroEnd => _outroEnd,
      };
      if (v == null) return;
      debugPrint('[SKIPDLG] 边界已改（${_edgeName(e)} = ${_fmtSeconds(v)}）'
          '→ 预览跟随并**停住**（退出区间循环 + pause + seek）');
      // ★ 不是 `_previewSeek` —— 那个只 seek 不暂停（见上面的说明）
      unawaited(_previewFrame(v));
    });
  }

  String _edgeName(SkipEdge e) => switch (e) {
        SkipEdge.introStart => '片头开始',
        SkipEdge.introEnd => '片头结束',
        SkipEdge.outroStart => '片尾开始',
        SkipEdge.outroEnd => '片尾结束',
      };

  /// 哪个点**正占着** `v` 这个值（没有则 null = 界来自视频本身）
  ///
  /// 提示文案用它反查"是谁挡住了我"，而不是猜邻居：
  /// `_boundFor` 的上界是 `邻居 - 1`、下界是 `邻居 + 1`，
  /// 所以「谁的值等于 `hi + 1` / `lo - 1`」就是真正的约束方。
  ///
  /// ★ 四个点的值**严格递增**（`_boundFor` 保证），所以命中至多一个；
  ///   未设置的点是 null，不会被误认成 0。
  SkipEdge? _edgeHolding(int v) {
    if (_introStart == v) return SkipEdge.introStart;
    if (_introEnd == v) return SkipEdge.introEnd;
    if (_outroStart == v) return SkipEdge.outroStart;
    if (_outroEnd == v) return SkipEdge.outroEnd;
    return null;
  }

  /// 纯夹取（不动状态、不提示）—— 给 `_applyEdge` 和单测用
  int _clampTo(int want, SkipEdge e) {
    final (lo, hi) = _boundFor(e);
    // 区间退化（lo > hi，例如相邻两点已经贴死）时返回边界值，
    // 而不是抛异常 —— 用户拖到头了不该让界面崩。
    if (lo > hi) return lo;
    return want.clamp(lo, hi);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppPalette.of(context);

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 弹窗尺寸必须**跟着窗口自适应**（2026-09-24 真机截图抓到的两个 bug）
     * ══════════════════════════════════════════════════════════════════
     *
     * 原来这里写死 `maxWidth: 720, maxHeight: 640`，两个后果：
     *
     * # bug ① 窄窗口下弹窗塌成一根「白竖条」
     *
     * `Dialog` 自带 `insetPadding: EdgeInsets.symmetric(horizontal: 40)`
     * （Material 默认值），**在 `ConstrainedBox` 之外**生效。
     * 于是窗口宽 120 时可用宽只剩 `120 - 80 = 40`：
     * ```text
     * 窗口宽 120 → Dialog 可用宽 40 → 再减 Sp.x5*2(40) 内边距 = **0**
     * 实测（探针 S120）：白色卡片 = 40 x 640 的**竖条**，
     * 里面所有文字竖着挤成一列，完全不可用。
     * ```
     * 用户原话「还多了一个竖着的不知道是什么的东西」——
     * 就是这根塌掉的卡片。它**不是**某个多余 widget，
     * 而是**整个弹窗在窄宽度下退化**。
     *
     * # bug ② 预览画面**不居中**（用户明确抱怨）
     *
     * 预览是 `ConstrainedBox(maxHeight: 260)` 包 `AspectRatio(16/9)`。
     * `AspectRatio` 拿到 720x260 的约束后，会**按比例反推宽度**：
     * ```text
     * 高被卡到 260 → 宽 = 260 * 16/9 ≈ 462
     * 结果：画面 462x260，**靠左**贴在 720 宽里 → 右边空出 258px
     * ```
     * 实测（探针 S1）：`AspectRatio` 盒子 = `[292,152 462.2x260]`，
     * 而同一列的 `SkipTimeline` = `[292,428 680x64]` —— 右边空 218px。
     * 用户看到的就是"视频没居中"。
     *
     * # 修法
     *
     * ```text
     * ① 宽度取 min(上限, 窗口宽 - 2*外边距)  —— 不再写死
     * ② 高度取 min(上限, 窗口高 - 2*外边距)  —— 窄/矮窗口都不溢出
     * ③ 预览用 Center 包住            —— 反推出来的宽度**水平居中**
     * ```
     * ① 同时解决了竖条：可用宽不再退化成 0（见下面 `_contentW` 的下限）。
     *
     * ⚠️ 上限 720x640 → **820x740**（2026-09-25，用户「中间的预览太小了」）。
     *    真机实测改前预览只有 277x156 —— 那个尺寸看不出画面内容，
     *    而"判断片头设到哪一秒"恰恰是这个弹窗的唯一目的。
     *    上限调大 100px，预览就能从 277x156 长到 526x296（面积 ×3.6）。
     */
    final media = MediaQuery.sizeOf(context);

    /// 外边距 —— 比 `Dialog` 默认的 40 小，给内容留出更多宽度
    const margin = Sp.x4;

    /// 内容可用宽（下限 260 —— 低于这个宽度弹窗就没有意义了）
    final availW = math.max(media.width - margin * 2, 260.0);

    /// 内容可用高（下限 320 —— 同上）
    final availH = math.max(media.height - margin * 2, 320.0);

    final boxW = math.min(kDialogMaxW, availW);
    final boxH = math.min(kDialogMaxH, availH);

    return Dialog(
      backgroundColor: colors.background,
      // 默认 40 的横向内边距正是窄窗口塌成竖条的原因之一 —— 收紧它
      insetPadding: const EdgeInsets.symmetric(
        horizontal: margin,
        vertical: margin,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: boxW, maxHeight: boxH),
        child: _loading
            ? const SizedBox(
                height: 200,
                child: Center(child: CircularProgressIndicator()),
              )
            : Padding(
                padding: const EdgeInsets.all(Sp.x5),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── 固定头（标题行 —— 原版显示时长摘要）──
                    _header(colors),

                    const SizedBox(height: Sp.x4),

                    /*
                     * ══════════════════════════════════════════════════════
                     * ★★★ 中段必须**可滚动**（2026-09-24 真机实测抓到的布局 bug）
                     * ══════════════════════════════════════════════════════
                     *
                     * # 症状
                     *
                     * 真机截图（1280x800）里弹窗**底部被裁掉了**：
                     * ```text
                     * 只看到「片头开始 / 片头结束」两行
                     * 「片尾开始 / 片尾结束 / 自动跳过 / 重置 / 确认设置」
                     * **全部看不到** —— 用户根本没法保存！
                     * ```
                     *
                     * # 根因：高度预算超了，而 `Spacer` 把溢出**静默吃掉**
                     *
                     * ```text
                     * maxHeight 640
                     *   header        ~40
                     *   预览 16:9     720 * 9/16 = 405   ← 这一项就吃掉大半
                     *   时间轴         56
                     *   4 行读数      160
                     *   自动跳过       ~40
                     *   底部按钮       ~50
                     *   ─────────────────────
                     *   合计          约 799  >  640
                     * ```
                     * ⚠️ 而且**没有 RenderFlex overflow 报错** ——
                     *    因为 `Column` 里有 `Spacer()`，它会把剩余空间压成 0
                     *    然后**让后面的子节点溢出**而不报错。
                     *    这类"不报错的溢出"最危险：单测绿、日志干净，
             *    只有真机截图才看得出来。
                     *
                     * # 修法：固定头脚 + 中段滚动
                     *
                     * ```text
                     * Column
                     *  ├ _header          固定（用户始终能看到当前设置摘要）
                     *  ├ Expanded
                     *  │   └ SingleChildScrollView   中段可滚
                     *  │       ├ 预览
                     *  │       ├ 时间轴
                     *  │       ├ 4 行读数
                     *  │       └ 自动跳过
                     *  └ _footer          固定（**保存按钮永远可见**）
                     * ```
                     * 「保存按钮永远可见」是关键 —— 那是这个弹窗的**唯一出口**，
                     * 滚出屏幕等于功能不可用。
                     *
                     * ══════════════════════════════════════════════════════
                     * ⚠️ 待查：弹窗里拖时间轴**偶发失效**（2026-09-24 真机实测，未修）
                     * ══════════════════════════════════════════════════════
                     *
                     * # 症状（截图 + 像素比对，两种结果都复现过）
                     *
                     * ```text
                     * 成功：拖「片头开始」x=214 -> 420  => 读数 00:00 变 00:03，箭头真的动了
                     * 失败：拖「片头结束」x=884 -> 560  => 读数**不变**，
                     *       而弹窗内容**上滚了 80px**（时间轴 y: 440 -> 360）
                     * 失败时**日志完全干净**，看起来就像"拖不动"
                     * ```
                     *
                     * # 为什么暂时不动它（先把事实摆清楚）
                     *
                     * 我原以为是"外层 `SingleChildScrollView` 在手势竞技场里
                     * 抢走了水平拖拽"。但**实测否掉了这个猜测**：
                     * ```text
                     * 在弹窗**非时间轴**的正文区域做同样的水平拖拽
                     *   → 内容**滚动了**
                     * 而那次"拖箭头"失败时也滚动了 80px
                     * ```
                     * 也就是说：滚动手势确实被 ScrollView 拿走了，
                     * 但它拿走的**条件**是什么、为什么有时又让给时间轴，
                     * 我还没测清楚（可能与按下点落在哪个 hit 区、
                     * 或与预览播放器那路纹理的命中测试有关）。
                     *
                     * ⚠️ **所以这里没有做任何"修法"** ——
                     *    不写没验证过的机制解释，也不加猜出来的手势 hack。
                     *    诚实标成待查，比塞一个可能让情况更糟的
                     *    `RawGestureDetector` 要好（那会同时影响滚动手感）。
                     *
                     * # 复现要点（给下一个接手的人）
                     *
                     * ```text
                     * 隔离库 .probe\testdata-a2 的 tyyszy:70260，片头 0-123
                     * 弹窗里时间轴在 y=440，琥珀 ▶ 的 x=[210..218]、◀ 的 x=[880..889]
                     * 用真实 mouse_event 分步拖拽（一次跳到位 Flutter 收不到 update）
                     * ```
                     * ⚠️ 探针里**单独**放 `SkipTimeline`（无外层滚动）时，
                     *    拖拽 100% 成功 —— 所以问题只出在弹窗这个组合里。
                     */
                    Expanded(
                      child: SingleChildScrollView(
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // ── 独立预览画面 ──
                            _previewBox(colors, previewHeightFor(boxH)),

                            const SizedBox(height: Sp.x4),

                            // ── 双区间时间轴 ──
                            SkipTimeline(
                              total: _total,
                              position: _previewPos,
                              introStart: _introStart,
                              introEnd: _introEnd,
                              outroStart: _outroStart,
                              outroEnd: _outroEnd,
                              onSeek: _previewSeek,
                              /*
                               * ★★★ 2026-10-06（task-13 ⑥）：**单击箭头 ⇒ 预览那一帧**
                               *
                               * 改前 hitEdge 命中的分支是**空的** —— 点在箭头上
                               * 什么都不发生（连跳转都没有）。见 _tapEdge。
                               */
                              onTapEdge: _tapEdge,
                              /*
                               * ══════════════════════════════════════════
                               * ★★★ 2026-10-01：拖完松手 ⇒ **预览定格到那一帧**
                               * ══════════════════════════════════════════
                               *
                               * # Owner 原话（逐字）
                               * ```text
                               * 「片头片尾的设置根本没用,那四个箭头是可以拖动的,
                               *   然后拖动松手就应该定格在松手的那一帧才对,
                               *   你自己拟人化操作试试看看到底行不行」
                               * ```
                               *
                               * # 改前：这条链路**只改数值，不碰预览**
                               * ```text
                               * 拖箭头 ⇒ _introStart = value ⇒ 时间轴上箭头动了
                               *        ⇒ ★ 而上面的预览画面**一动不动**
                               * ⇒ 用户拖完**根本不知道拖到哪一帧了**
                               *   —— 这正是他说的"根本没用"
                               * ```
                               *
                               * ★★ 而**同一个弹窗**的另一条链路
                               *    （读数行的 +/- ⇒ `_applyEdge`）**早就做了**这件事
                               *    （见 `_applyEdge` 里"改完边界预览跟着走"那一大段）。
                               *    ⇒ 两条链路行为不一致，拖拽这条**漏了**。
                               *    这是"同一个语义在两处实现、只改了一处"的典型。
                               *
                               * # 修法：与 `_applyEdge` **共用同一套跟随逻辑**
                               * ```text
                               * 拖动中  ⇒ 只改数值（高频，不能每帧都 seek）
                               * 松手后  ⇒ 250ms debounce ⇒ _previewFrame(定格值)
                               * ```
                               * ⚠️ 拖动中**不能**直接 seek：`onHorizontalDragUpdate`
                               *    每帧都调，seek 是异步且要等时长的 ⇒
                               *    会堆一堆排队请求（虽然 `_seekToken` 保证只有
                               *    最后一个生效，但**白解码**很多次）。
                               *    ★ 用与 `_applyEdge` 相同的 250ms debounce ——
                               *      "停手就看到结果"，且拖动过程中不卡。
                               *
                               * ★★ 2026-10-02：`_followPreviewTo` 内部已从
                               *    `_previewSeek`（**只 seek、不暂停**）改成
                               *    `_previewFrame`（**退出区间循环 + pause + seek**）。
                               *    原因见 Owner 原话：「在播放的过程中,拖动调整片头片尾,
                               *    状态应该重置,不应该继续播放,应该是变回拖动结束后的
                               *    那一帧预览」。
                               *
                               * ⚠️ 为什么松手后**还要**再 seek 一次（而不是只靠 debounce）：
                               *    debounce 会在"停止移动 250ms"后触发 ——
                               *    而用户**松手**时往往已经停了一下，debounce 可能
                               *    在松手**之前**就烧掉了（值是对的，seek 也发了）。
                               *    两种情况最终都会 seek 到**同一个值**（读的是
                               *    当前 `_introStart` 等字段），所以重复调用无害
                               *    —— `_seekToken` 会让旧的失效。
                               *    ⇒ 所以这里**只挂 debounce**，不额外加"松手即 seek"：
                               *      那会让同一次拖动 seek 两次（多余）。
                               */
                              onChanged: (which, value) {
                                /*
                                 * ══════════════════════════════════════════
                                 * ★★★ 2026-10-02：**拖拽也必须夹取**
                                 *（Owner：四条互斥，箭头不许互相穿过）
                                 * ══════════════════════════════════════════
                                 *
                                 * # Owner 原话（逐字）
                                 * ```text
                                 * 「还有这四个是互斥关系,片尾的两个箭头不能跑到片头的
                                 *   两个前面去
                                 *   然后 片头的两个,片头的结束不能跑到片头的开始前面去
                                 *   片尾的也是同理」
                                 * ```
                                 * ⇒ 四条约束：
                                 * ```text
                                 * ① introStart <  introEnd      （片头：开始在前）
                                 * ② introEnd   <  outroStart    （片头整对在片尾之前）
                                 * ③ outroStart <  outroEnd      （片尾：开始在前）
                                 * ④ 全部落在 [0, total]
                                 * ```
                                 *
                                 * # 改前：**拖拽这条路根本没夹**
                                 * ```text
                                 * _applyEdge（读数行 +/-）⇒ _clampTo(want, e)  ✅ 夹了
                                 * 拖拽 onChanged          ⇒ 直接赋值            ❌ 没夹
                                 * ```
                                 * ⇒ 用户拖动箭头可以**穿过**别的箭头 ⇒ 四条互斥全失效。
                                 * ★ 又是「同一个语义两条链路、只实现了一处」——
                                 *   本文件里这已经是**第三次**同类问题
                                 *   （前两次：预览跟随、幽灵箭头可拖）。
                                 *
                                 * # 修法：与 `_applyEdge` 共用 `_clampTo`
                                 * ⚠️ 用 `_clampTo` 而**不是** `_applyEdge` ——
                                 *    后者会 `setState` + `_toast`，而拖拽是**高频**调用
                                 *    （每帧一次）⇒ 每帧弹一个 toast 会刷屏。
                                 *    ★ 拖拽时箭头"停在边界不动"本身就是提示，
                                 *      不需要每帧重复一句话。
                                 *    （`_applyEdge` 的 toast 是给**点按**用的 ——
                                 *      点一下被挡住，用户会以为按钮坏了。）
                                 */
                                setState(() {
                                  final v = _clampTo(value, which);
                                  switch (which) {
                                    case SkipEdge.introStart:
                                      _introStart = v;
                                    case SkipEdge.introEnd:
                                      _introEnd = v;
                                    case SkipEdge.outroStart:
                                      _outroStart = v;
                                    case SkipEdge.outroEnd:
                                      _outroEnd = v;
                                  }
                                });
                                // ★ 拖完 ⇒ 预览跟到那个点（与 `_applyEdge` 同一手法）
                                _followPreviewTo(which);
                              },
                            ),

                            const SizedBox(height: Sp.x4),

                            // ── 四条读数 + 微调 ──
                            _rows(colors),

                            const SizedBox(height: Sp.x2),

                            /*
                             * ── ★ task-66：「整段」预览（片头 / 片尾）──
                             *
                             * Owner：「预览还要支持预览片头 片尾**整段**」
                             * ⇒ 与四个"显示该帧"按钮**分开**：
                             *   点 = 那一帧（静止）／段 = 循环播放（看运动）
                             *
                             * ⚠️ 这一行占 `kRowH`(36) + `Sp.x2`(8) = 44px，
                             *    已计入 `kMidRestH`（300 → 340 → 360）。
                             *    漏计会让预览算高 40px ⇒ 第四行被挤出视口
                             *    （= 用户 2026-09-24 报的「只看到片头两行」）。
                             */
                            _rangePreviewRow(colors),

                            const SizedBox(height: Sp.x3),

                            // ── 自动跳过开关 ──
                            _autoSkipRow(colors),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: Sp.x2),

                    // ── 固定脚（保存按钮永远可见）──
                    _footer(colors),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _header(AppPalette colors) {
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 2026-10-02 重做（Owner：「布局和ui再优化优化」「有点丑,要美观」）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 改前的样子（Owner 截图）
     * ```text
     * 片头 未设置 - 未设置　片尾 未设置 - 未设置          [×]
     * ```
     * ★ 两个"未设置 - 未设置"占了**一整行**，但**没有任何信息量** ——
     *   用户打开弹窗时看到的第一行字就是四个"未设置"。
     *
     * # 现在：两个**色块徽章**，只在设了之后才显示
     * ```text
     * 未设置：  ○ 片头未设        ○ 片尾未设          [×]
     * 设了：    ● 片头 00:12-01:03   ● 片尾 45:20-46:00   [×]
     * ```
     * ★ 色点与时间轴上的箭头**同色**（`skipIntroColor` / `skipOutroColor`）
     *   ⇒ 一眼对得上"哪个是片头、哪个是片尾"。
     * ★ 未设时用**淡淡的胶囊**（不是纯文字）—— 视觉上"待填"，
     *   而不是"四个字挤在一起"。
     */
    Widget badge({
      required String label,
      required Color accent,
      required int? from,
      required int? to,
    }) {
      final set = from != null || to != null;
      final text = set
          ? '$label ${from == null ? "—" : _fmtSeconds(from)}'
              '-${to == null ? "—" : _fmtSeconds(to)}'
          : '$label未设';
      return Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Sp.x2,
          vertical: Sp.x1,
        ),
        decoration: BoxDecoration(
          color: set
              ? accent.withValues(alpha: 0.10)
              : colors.secondary.withValues(alpha: 0.5),
          borderRadius: Radii.rSm,
          border: Border.all(
            color: set
                ? accent.withValues(alpha: 0.35)
                : colors.border.withValues(alpha: 0.6),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ★ 色点：与时间轴箭头同色 ⇒ 一眼对得上
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: set ? accent : colors.mutedForeground
                    .withValues(alpha: 0.45),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: Sp.x1),
            Text(
              text,
              style: TextStyle(
                fontSize: FontSizes.sm,
                fontWeight: set ? FontWeight.w600 : FontWeight.w400,
                color: set ? colors.foreground : colors.mutedForeground,
              ),
            ),
          ],
        ),
      );
    }

    return Row(
      children: [
        /*
         * ⚠️ `Flexible` + `Wrap` 而不是 `Row` + `Expanded`：
         *    窄窗口（手机 411dp）下两个徽章放不进一行时**换行**，
         *    而不是被裁掉或溢出（本仓已有 `RenderFlex overflow` 的教训）。
         */
        Expanded(
          child: Wrap(
            spacing: Sp.x2,
            runSpacing: Sp.x1,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              badge(
                label: '片头',
                accent: skipIntroColor(colors.brightness),
                from: _introStart,
                to: _introEnd,
              ),
              badge(
                label: '片尾',
                accent: skipOutroColor(colors.brightness),
                from: _outroStart,
                to: _outroEnd,
              ),
            ],
          ),
        ),
        const SizedBox(width: Sp.x2),
        // ⚠️ 必须外层 `SizedBox` 钉死（`constraints` 单给不够 —— 见 `_StepBtn`）
        SizedBox(
          width: kHeaderBtn,
          height: kHeaderBtn,
          child: IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, size: 20),
            tooltip: '关闭',
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            style: IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              minimumSize: const Size(kHeaderBtn, kHeaderBtn),
              padding: EdgeInsets.zero,
            ),
          ),
        ),
      ],
    );
  }

  Widget _previewBox(AppPalette colors, double maxH) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.sm),
      child: ConstrainedBox(
        /*
         * ⚠️ 限制预览最大高度 —— 值由**高度预算**动态算出
         *    （`previewHeightFor(boxH)`，推导见文件头 `kMidRestH`）
         *
         * 纯 16:9 的 `AspectRatio` 在 720 宽的弹窗里 = **405px 高** ——
         * 一个预览就吃掉弹窗 2/3。限高是为了让"时间轴 + 四行读数"
         * 一屏可见（用户报的「只看到片头两行」）。
         *
         * ⚠️ 260 → **动态**（2026-09-24）：写死 260 时中段总高 560、
         *    视口只有 488，**超 72px** → 第 4 行「片尾结束」被挤出视口。
         *    现在把剩余高度全给预览，640 高时预览 = 156，四行无需滚动。
         *
         * `AspectRatio` 在 `ConstrainedBox` **内部** —— 顺序不能反，
         * 否则宽高比会反过来撑高。
         */
        constraints: BoxConstraints(maxHeight: maxH),
        /*
         * ★★★ `Center` 是**必须**的（2026-09-24 用户截图：视频没居中）
         *
         * # 为什么没有它就会靠左
         *
         * `AspectRatio` 拿到 `720 x 228` 的约束后，会按比例**反推宽度**：
         * ```text
         * 高被卡在 228  →  宽 = 228 * 16/9 ≈ 405
         * 结果 405x228，**左对齐**贴在 720 宽的列里
         * → 右边空出 315px 白边，观感就是"视频没居中"
         * ```
         * 实测（探针 S1，窗口 1280，改前 maxHeight=260）：
         * ```text
         * 预览 AspectRatio  [292.0,152.0 462.2x260.0]
         * SkipTimeline      [292.0,428.0 680.0x64.0]
         *                    ↑ 同一列左边对齐，预览右边空 217.8px
         * ```
         *
         * `Center` 让反推出来的宽度在可用宽里**水平居中** ——
         * 这正是用户要的"视频居中"。
         *
         * ⚠️ 顺序：`Center` 必须在 `AspectRatio` **外面**。
         *    放里面的话 `AspectRatio` 先拿到全宽 720 → 算出 405 高 →
         *    `ConstrainedBox` 再把高裁到 228 → 画面被**压扁**（比例失真）。
         */
        child: Center(
          child: AspectRatio(
            /*
             * ★ task-66 C「预览去黑边」：比例由**视频自己**决定，不再写死 16/9。
             *
             * # 黑边是谁画的（改前实测定性）
             *
             * `Video` 内部已经是 `FittedBox(fit: BoxFit.contain)`，库按 `rect`
             * 给 `SizedBox` 定尺寸（`video_texture.dart` L390-415）。也就是说
             * **库会自己把画面完整装进我们给的框**，装不满的那部分才是黑边。
             * 框是 16:9 而片子是 4:3 ⇒ contain 只用到 3/4 宽度 ⇒ 左右两条黑边
             * 正是我们自己那层 `ColoredBox(Colors.black)` 露出来的。
             *
             * ⇒ 把框改成片子自己的比例，contain 就退化成"刚好铺满"，
             *   黑边消失，且**不裁切、不变形**（仍然是 contain 语义）。
             *
             * 值来自 [_previewAspect]，在 `onRect()` 里由 `VideoController.rect`
             * 读出（`rect.width / rect.height` = 视频原生宽高比）。
             * 首帧出来前它是兜底的 16/9，但那时框里显示的是加载提示、
             * 根本不是画面，所以看不见。
             */
            aspectRatio: _previewAspect,
            child: ColoredBox(
              color: Colors.black,
              /*
               * ══════════════════════════════════════════════════════════
               * ★★★ task-57 的核心修复：loading 判据改成**首帧真的出来了**
               * ══════════════════════════════════════════════════════════
               *
               * # 改前的病（实测，用**用户正在跑的 build**）
               *
               * 每 4 秒量一次预览框：
               * ```text
               *   + 4s  纯黑  99.3%  颜色数      3   黑框   ← ★ 用户看到的
               *   + 9s  纯黑  99.3%  颜色数      3   黑框
               *   +15s  纯黑   0.0%  颜色数  57216   ★ 有画面
               * ```
               * ⇒ **15 秒纯黑、且没有任何提示** ⇒ 用户以为"坏了" ⇒
               *   这就是他说「根本不能用」的直接来源。
               *
               * # 为什么旧的 spinner 不显示
               *
               * ```dart
               * _previewCtrl == null ? 转圈 : Video(...)   // ← 旧写法
               * ```
               * `_previewCtrl` 在 `await p.open(...)` 之后立刻赋值，
               * 而 **`open()` 返回 ≠ 流就绪**（`_previewSeek` 注释里早写了）
               * ⇒ spinner 在**真正需要它的那 15 秒**里被切走。
               *
               * # 现在的判据
               *
               * `_firstFrame`（由 `VideoController.rect` 驱动，见 `_initPreview`）
               * —— 与**库自己**"要不要画 Texture"用的是同一个值。
               *
               * # 而且加载态给的是**文字 + 转圈**，不只是转圈
               *
               * 15 秒的等待，转圈不够 —— 用户需要**明确知道**"在加载，
               * 不是坏了"。⇒ 文案直说"正在加载预览"，并给出**出路**
               * （可以先用下面的时间轴和微调，不必等）。
               */
              child: _previewError != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(Sp.x4),
                        child: Text(
                          // 如实报错 —— 不静默失败（用户会以为"预览坏了"）
                          '预览不可用：$_previewError\n\n'
                          '（不影响设置：可以直接用下面的时间轴和微调按钮）',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    )
                  : _previewCtrl == null
                      /*
                       * ① 控制器都还没建好（播放器还在启动）——
                       *    这个阶段很短，但也要有提示，不能是黑框。
                       */
                      ? _loadingHint('正在启动预览…')
                      : !_firstFrame
                          /*
                           * ② ★★★ 这是**用户实际卡住的那 15 秒**
                           *
                           * 控制器已建好、但**首帧还没渲染出来**。
                           * 改前这里直接画 `Video(...)` ⇒ 纯黑框。
                           */
                          ? _loadingHint('正在加载预览…')
                          : Video(
                              controller: _previewCtrl!,
                              controls: NoVideoControls,
                              fill: Colors.black,
                            ),
            ),
          ),
        ),
      ),
    );
  }

  /// 预览加载中的提示（**文字 + 转圈**，不是黑框）
  ///
  /// ⚠️ 必须有**文字**：15 秒的等待里，一个转圈不足以让用户判断
  ///    "在加载"还是"坏了" —— 而"以为坏了"正是用户报的那个病。
  ///
  /// ⚠️ 文案里给出**出路**（"不影响下面的设置"）——
  ///    用户不必干等，可以直接用时间轴/微调把片头片尾设好。
  Widget _loadingHint(String text) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '（较慢的源可能要十几秒；不影响下面的设置）',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white38,
                fontSize: FontSizes.cap,
              ),
            ),
          ],
        ),
      );

  Widget _rows(AppPalette colors) {
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 四行必须**一屏可见**（2026-09-24 用户截图：只看得到两行）
     * ══════════════════════════════════════════════════════════════════
     *
     * 用户原话「进度条只显示片头设置的两个箭头没有显示片尾的」。
     *
     * # 真因不是时间轴画错，而是**行被挤到滚动区外面**
     *
     * 时间轴的绘制是对的（`drawArrow` 四个端点都画了，单测断言过）。
     * 问题是高度预算：弹窗 `maxHeight 640`，而
     * ```text
     * header 40 + 预览 260 + 时间轴 64 + 四行 4*40=160
     *        + 自动跳过 40 + 底栏 50 ≈ 614  （还没算各段间距 Sp.x4*3=48）
     * ```
     * 实测（探针 S1）：四行分别落在 y=517/557/597/637，
     * 而滚动区底边只到约 y=600 —— **「片尾结束」整行在视口外**，
     * 「片尾开始」也只剩一半。用户只看到「片头开始 / 片头结束」，
     * 于是以为"只有片头的两个箭头"（片尾的箭头确实还没设，也没画）。
     *
     * # 修法：把每行压紧 + 去掉行间多余留白
     *
     * ```text
     * 原来  每行 Padding(bottom: Sp.x2) + IconButton 默认 48 高  → 40/行
     * 现在  IconButton 收紧到 32（visualDensity + constraints）
     *       → 32/行，四行省下 32px，正好把第四行拉进视口
     * ```
     * ⚠️ 只压**垂直**方向，命中区仍 >= 32x32（桌面鼠标够用；
     *    触摸端本来也不该用这么密的四行 —— 那是另一个问题）。
     */
    return Column(
      children: [
        _EdgeRow(
          label: '片头开始',
          // ★ 配对色条：与时间轴上同组箭头**同色**（task㉝）
          accent: skipIntroColor(colors.brightness),
          value: _introStart,
          total: _total,
          colors: colors,
          /*
           * ★ 每个点都有**自己的上下界** —— 见 `_boundFor` 的说明。
           *
           * 「片头开始」只能落在 `[0, 片头结束-1]`：
           * 超过片头结束就不再是"片头"了（区间会倒过来）。
           */
          bound: _boundFor(SkipEdge.introStart),
          onChanged: (v) => _applyEdge(v, SkipEdge.introStart),
          // ★★★ 2026-10-06（task-13 ⑥）：读数文本也能点（见 _tapEdge）
          onTapValue: () => _tapEdge(SkipEdge.introStart),
          previewTip: '预览「片头开始」这一帧',
          /*
           * ══════════════════════════════════════════════════════════
           * ★★★ task-66：四个按钮**统一**改成"显示这一帧"
           * ══════════════════════════════════════════════════════════
           *
           * Owner 原话（逐字）：
           * ```text
           * > 点击片头片尾那四个按钮可以显示出对应的停止的那一帧的画面，
           * > 方便确认自己没有截取错
           * ```
           *
           * ⚠️ 改前是**混用**的：片头结束 / 片尾开始 用 `_previewRange`
           *    （区间循环），另两个用 `_previewSeek`（纯 seek）——
           *    于是"点四个按钮"得到**两种完全不同的行为**，
           *    而 Owner 要的是四个都"显示对应帧"。
           *
           * ⇒ 现在四个一律 `_previewFrame`（seek + 暂停），
           *   "整段"另给**独立按钮**（见下面 `_rangePreviewRow`）。
           */
          onPreview: (v) => _previewFrame(v),
        ),
        _EdgeRow(
          label: '片头结束',
          // ★ 配对色条：与时间轴上同组箭头**同色**（task㉝）
          accent: skipIntroColor(colors.brightness),
          value: _introEnd,
          total: _total,
          colors: colors,
          bound: _boundFor(SkipEdge.introEnd),
          onChanged: (v) => _applyEdge(v, SkipEdge.introEnd),
          // ★★★ 2026-10-06（task-13 ⑥）：读数文本也能点（见 _tapEdge）
          onTapValue: () => _tapEdge(SkipEdge.introEnd),
          previewTip: '预览「片头结束」这一帧',
          onPreview: (v) => _previewFrame(v),
        ),
        _EdgeRow(
          label: '片尾开始',
          // ★ 配对色条：与时间轴上同组箭头**同色**（task㉝）
          accent: skipOutroColor(colors.brightness),
          value: _outroStart,
          total: _total,
          colors: colors,
          bound: _boundFor(SkipEdge.outroStart),
          onChanged: (v) => _applyEdge(v, SkipEdge.outroStart),
          // ★★★ 2026-10-06（task-13 ⑥）：读数文本也能点（见 _tapEdge）
          onTapValue: () => _tapEdge(SkipEdge.outroStart),
          previewTip: '预览「片尾开始」这一帧',
          onPreview: (v) => _previewFrame(v),
        ),
        _EdgeRow(
          label: '片尾结束',
          // ★ 配对色条：与时间轴上同组箭头**同色**（task㉝）
          accent: skipOutroColor(colors.brightness),
          value: _outroEnd,
          total: _total,
          colors: colors,
          bound: _boundFor(SkipEdge.outroEnd),
          onChanged: (v) => _applyEdge(v, SkipEdge.outroEnd),
          // ★★★ 2026-10-06（task-13 ⑥）：读数文本也能点（见 _tapEdge）
          onTapValue: () => _tapEdge(SkipEdge.outroEnd),
          previewTip: '预览「片尾结束」这一帧',
          onPreview: (v) => _previewFrame(v),
        ),
      ],
    );
  }

  /// 「整段」预览两个按钮（片头整段 / 片尾整段）
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ task-66：Owner 要求「预览片头 片尾**整段**」
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// # Owner 原话（逐字）
  /// ```text
  /// > 片头片尾这里预览还要支持预览片头 片尾整段，
  /// > 以确保自己没截取错误
  /// ```
  ///
  /// # 为什么要**独立按钮**（而不是复用四个行内的预览）
  ///
  /// Owner 这一句里其实是**两个不同诉求**，必须各有入口：
  /// ```text
  /// 「点击四个按钮显示对应的**那一帧**」  ⇒ 静止，看"切点准不准"
  /// 「预览片头/片尾**整段**」            ⇒ 播放，看"这段是不是都是片头"
  /// ```
  /// 前者是**点**、后者是**段**。混在一个按钮上必然二选一，
  /// 而那正是改前的状态（四个按钮行为不一致）。
  ///
  /// # 零额外高度的做法（高度预算是硬约束，见文件头 `kMidRestH`）
  ///
  /// 两个按钮**并排一行**，高度取 `kRowH`（= 36，与 `−/+` 同高）——
  /// 与"四行 × 40px"那笔预算里每行的高度一致 ⇒ **不突破预算**。
  /// ⚠️ 但它**确实**占了一行 36px。所以 `kMidRestH` 必须 +36，
  ///    否则预览会算高 36px 而把最后一行挤出视口
  ///    （那正是用户 2026-09-24 报的「只看到片头两行」）。
  Widget _rangePreviewRow(AppPalette colors) {
    /// 一个「整段」按钮 —— **播放 / 暂停 切换**
    ///
    /// ══════════════════════════════════════════════════════════════════
    /// ★★★ 2026-10-02 重做（Owner 两条反馈）
    /// ══════════════════════════════════════════════════════════════════
    ///
    /// # ① 「预览的时候不支持暂停」
    /// 改前：点了就循环播，**没有任何办法停**（再点还是 `_previewRange`）。
    /// 现在：
    /// ```text
    /// 没在播       ⇒ 「▶ 片头整段」 点 ⇒ 循环播（图标变 ⏸，文字变「暂停」）
    /// 正在播这段   ⇒ 「⏸ 暂停」     点 ⇒ **停在这一帧**
    /// 正在播另一段 ⇒ 本按钮仍是「▶」 点 ⇒ 切到这一段
    /// ```
    ///
    /// # ② 「整段」未设置时也能点（自动给默认值）
    /// 改前：`from`/`to` 有 null 就**置灰**，而用户打开弹窗时四个点都没设
    /// ⇒ 两个按钮全是灰的 ⇒ 他**根本没法预览**（截图里就是这样）。
    /// 现在：未设置时**自动填一个合理的默认区间**再播：
    /// ```text
    /// 片头：from = introStart ?? 0        to = introEnd ?? min(30, 总长)
    /// 片尾：from = outroStart ?? max(0, 总长-30)   to = outroEnd ?? 总长
    /// ```
    /// ★ 30 秒是"典型片头/片尾长度"—— 够看清是不是广告/主题曲，
    ///   又不至于把整片都算进去。用户拖箭头后区间就变成他自己的了。
    ///
    /// # ③ 美观
    /// ```text
    /// · 播放中 ⇒ 按钮**实心填充**（accent 色）+ 图标 ⏸ ⇒ 一眼看出"正在播"
    /// · 未播放 ⇒ 描边 + 图标 ▶ ⇒ 安静地待着
    /// · 未设置时按钮**不置灰**（可点），但文字后面带一个淡淡的「默认」
    /// ```
    Widget btn({
      required String label,
      required SkipEdge which,
      required Color accent,
      required int? from,
      required int? to,
      required (int, int) fallback,
    }) {
      final playing = _playingRange == which;
      /*
       * ★ 未设置 ⇒ 用 fallback（不是置灰）。
       * ⚠️ fallback 也要夹进 [0, 总长] —— 否则总长 < 30 秒时
       *    `to` 会超过总长，`_previewRange` 里 `to <= from` 直接 return
       *    ⇒ 点了没反应（比置灰更糟）。
       */
      final total = _total.toInt();
      var lo = from ?? fallback.$1;
      var hi = to ?? fallback.$2;
      lo = lo.clamp(0, total);
      hi = hi.clamp(0, total);
      final ok = hi > lo;
      final usingDefault = from == null || to == null;

      return Expanded(
        child: Tooltip(
          message: playing
              ? '正在循环播放$label整段 —— 点一下**暂停在这一帧**'
              : ok
                  ? '循环播放$label整段${usingDefault ? "（未设置，用默认范围）" : ""}'
                  : '$label区间还没设，或长度不足 1 秒',
          child: SizedBox(
            height: kRowH,
            child: OutlinedButton.icon(
              onPressed: ok ? () => _toggleRange(which, lo, hi) : null,
              icon: Icon(
                playing ? Icons.pause : Icons.play_arrow_rounded,
                size: 17,
                color: ok ? accent : null,
              ),
              label: Text(
                playing ? '暂停' : '$label整段',
                style: const TextStyle(fontSize: FontSizes.sm),
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, kRowH),
                padding: const EdgeInsets.symmetric(horizontal: Sp.x2),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: ok ? accent : null,
                /*
                 * ★ 播放中 ⇒ 实心填充（`accent` 的低透明度底 + accent 边）。
                 *   ⚠️ 用 `withValues(alpha:)` 而不是 `withOpacity` ——
                 *      后者在新版 Flutter 已弃用（本仓统一用前者）。
                 */
                backgroundColor:
                    playing ? accent.withValues(alpha: 0.14) : null,
                side: BorderSide(
                  color: ok
                      ? (playing
                          ? accent
                          : accent.withValues(alpha: 0.45))
                      : colors.border,
                ),
              ),
            ),
          ),
        ),
      );
    }

    /*
     * ★ 默认区间：片头从 0 开始、片尾到末尾结束。
     * ```text
     * 片头 (0, 30)                    —— 广告/主题曲通常在前 30 秒
     * 片尾 (总长-30, 总长)             —— 片尾曲通常在最后 30 秒
     * ```
     * ⚠️ `_total` 为 0（时长还没到）时两个 fallback 会相等
     *    ⇒ `ok == false` ⇒ 按钮禁用 —— 那是**正确**的（还不知道多长，
     *    没法给默认区间）。时长一到就会自动可用。
     */
    final total = _total.toInt();
    const span = 30;
    final tailFrom = (total - span).clamp(0, total);

    return Row(
      children: [
        btn(
          label: '片头',
          which: SkipEdge.introStart,
          accent: skipIntroColor(colors.brightness),
          from: _introStart,
          to: _introEnd,
          fallback: (0, span.clamp(0, total)),
        ),
        const SizedBox(width: Sp.x2),
        btn(
          label: '片尾',
          which: SkipEdge.outroStart,
          accent: skipOutroColor(colors.brightness),
          from: _outroStart,
          to: _outroEnd,
          fallback: (tailFrom, total),
        ),
      ],
    );
  }

  Widget _autoSkipRow(AppPalette colors) {
    return Row(
      children: [
        Switch(
          value: _autoSkip,
          onChanged: (v) => setState(() => _autoSkip = v),
        ),
        const SizedBox(width: Sp.x2),
        Expanded(
          child: Text(
            '自动跳过（关掉则只在到达时提示，需手动点）',
            style: TextStyle(
              fontSize: FontSizes.sm,
              color: colors.mutedForeground,
            ),
          ),
        ),
      ],
    );
  }

  Widget _footer(AppPalette colors) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (!_canSave)
          Padding(
            padding: const EdgeInsets.only(right: Sp.x3),
            child: Text(
              // 说清为什么不给保存（不给原因的话用户会以为按钮坏了）
              '区间不合法：需要 起点 < 终点，且片头在片尾之前',
              style: TextStyle(fontSize: FontSizes.cap, color: colors.error),
            ),
          ),
        TextButton(onPressed: _reset, child: const Text('重置')),
        const SizedBox(width: Sp.x2),
        FilledButton(
          onPressed: _canSave ? _save : null,
          child: Text(_saving ? '保存中…' : '确认设置'),
        ),
      ],
    );
  }
}

/// 把一个秒数格式化成 `HH:MM:SS`
String _fmtSeconds(int sec) {
  final h = sec ~/ 3600;
  final m = (sec % 3600) ~/ 60;
  final s = sec % 60;
  String p(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '${p(h)}:${p(m)}:${p(s)}' : '${p(m)}:${p(s)}';
}

/// 用**真实字体**量一段文字要占多宽（逻辑像素）
///
/// ══════════════════════════════════════════════════════════════════
/// ★★★ 为什么必须"量"而不是"猜"（2026-10-02，真机缺陷）
/// ══════════════════════════════════════════════════════════════════
///
/// 真机（1080x2400 @420dpi）实测：四行标签全部渲染成 `片…` ——
/// 只画出了第一个字，后三个字连同省略号一起被挤掉。
/// 像素取证：标签列墨迹宽 **144px → 68px**（-52.8%）。
///
/// ⚠️⚠️ 这个数被**算错过两次**，原因值得记下来：
/// ```text
/// lib\ui\tokens.dart 里有**两个 `sm`**
///   :79   abstract final class Radii    { static const double sm = 12; }
///   :104  abstract final class FontSizes{ static const double sm = 14; }
/// ```
/// 按 `12` 算会得出"只差 2.3px"的结论；按真机像素反推是
/// `144 ÷ 2.625 = 54.86` ⇒ 四个汉字 ≈ 4 × **14** ⇒ 实际差 **17.9px**。
/// ⇒ 所以这里**不写任何字号常量**，直接把真实的 `TextStyle` 交给
///   `TextPainter` —— 字号、字重、monospace 回退、系统字体缩放
///   全部自动算对，永远不会再和 `tokens.dart` 脱钩。
double _textWidthOf(BuildContext context, String text, TextStyle style) {
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    maxLines: 1,
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  return tp.width;
}

/// 时间轴上的四个端点
enum SkipEdge { introStart, introEnd, outroStart, outroEnd }

/// ── 一行读数 + 微调按钮 ──
///
/// 原版特意加了两组 −/+ 微调：
/// > 两组 −/+ 微调按钮（手机上拖滑块到不了秒级 —— 草稿 §二的原话）
class _EdgeRow extends StatelessWidget {
  const _EdgeRow({
    required this.label,
    required this.value,
    required this.total,
    required this.colors,
    required this.onChanged,
    required this.onPreview,
    this.bound,
    this.accent,
    this.onTapValue,
    this.previewTip,
  });

  final String label;
  final int? value;
  final double total;
  final AppPalette colors;
  final ValueChanged<int?> onChanged;
  final ValueChanged<int> onPreview;

  /// ★★★ 2026-10-06（task-13 ⑥）：**点这一行的读数文本 ⇒ 预览这一帧**
  ///
  /// Owner 原话（逐字）：「片头片尾的片头 片尾 的开始与结束，单独点击预览
  ///   没有反应，点击后应该预览这一帧的画面才对」。
  ///
  /// # 改前的实测（就是"没有反应"的来源）
  /// ```text
  /// 四个读数文本 00:05 —— **一点手势都没有**（纯 Text）
  /// 唯一入口是右边那个 36x36 的 ▶ 按钮
  /// ⇒ 用户点读数（那是行里最显眼的数字）⇒ 什么都不发生
  /// ```
  ///
  /// ⚠️ 传 null 时行为与改前**完全一致**（读数不可点、▶ 未设置时置灰）——
  ///    单测宿主不传这个参数，旧断言不受影响。
  final VoidCallback? onTapValue;

  /// 预览按钮的 tooltip（null ⇒ 沿用旧的「预览这一点」）
  final String? previewTip;

  /// 这一行属于哪一对（片头 / 片尾）—— 用**同色**把它和时间轴上的箭头连起来
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// # 用户原话（2026-09-25 任务㉝）
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// > 应该是片头的设置，开始与结束都在最前面 **是一对的**，
  /// > 然后。片尾。的设置 都在最后面，**并且是一对的**
  ///
  /// # ★ 为什么光靠"位置分开"还不够
  ///
  /// 位置能把**片头一对**和**片尾一对**分开（左 vs 右），
  /// 但**组内**两行（片头开始 / 片头结束）颜色完全一样时，
  /// 用户仍然只能靠**读文字**分辨 —— 而用户明确说"违反操作直觉"。
  ///
  /// 加一条与时间轴箭头**同色**的色条后，用户不需要读字：
  /// ```text
  /// ▌片头开始   ← 琥珀色（= 时间轴上片头那两个箭头的颜色）
  /// ▌片头结束   ← 琥珀色
  /// ▌片尾开始   ← 蓝色（= 时间轴上片尾那两个箭头的颜色）
  /// ▌片尾结束   ← 蓝色
  /// ```
  /// ⇒ 眼睛顺着颜色就能把"行"和"轴上的箭头"对上。
  ///
  /// # ★★ 为什么必须"零高度"（这是硬约束，不是偏好）
  ///
  /// 实测（`.probe/probe_tests/skip_dialog_rows_test.dart`）：
  /// ```text
  /// 中段内容总高 = 596.0   视口高 = 596.0   **剩余 = 0.0**
  /// ```
  /// 四行 y = 499 / 535 / 571 / 607，视口底边 694 —— **一点余量都没有**。
  /// 而 `skip_marker_dialog.dart` L1195-1224 记着用户上次的抱怨
  /// 「只看到片头两行」。
  ///
  /// ⇒ 所以色条**不能**用 `SizedBox(height: ...)` 或 `Padding` 包一层
  ///   （那会加高），而是作为 `Row` 的**一个子项**放进**已有的一行**里 ——
  ///   `Row` 的高度由最高的子项决定，一个 4px 宽的 `Container`
  ///   **不改变行高**。这是"零额外高度"的关键。
  final Color? accent;

  /// 这一点的合法区间 `[lo, hi]`（null = 不限制）
  ///
  /// # 为什么**必须**传进来（而不是行内自己算）
  ///
  /// 每个点的界依赖**别的三个点**（片头开始的界是片头结束），
  /// 而 `_EdgeRow` 是 `StatelessWidget`、只看得到自己的 `value` ——
  /// 它算不出界。所以由 `_SkipMarkerDialogState._boundFor()` 算好传进来。
  ///
  /// 用途有两个，**缺一不可**：
  /// ```text
  /// ① −/+ 到边界时**置灰**（用户看得出"到头了"，而不是以为按钮坏了）
  /// ② 行内显示约束（如「≤ 01:30」）—— 「不能静默」的就近体现
  /// ```
  final (int, int)? bound;

  @override
  Widget build(BuildContext context) {
    final v = value;
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 每行的按钮尺寸必须显式收紧（2026-09-24 用户截图：只看到两行）
     * ══════════════════════════════════════════════════════════════════
     *
     * 原来这行里的 `IconButton` 用**默认**尺寸：Material 的 IconButton
     * 最小 48x48（`kMinInteractiveDimension`），即使 `icon size: 16`
     * 也照样撑出 48 高。四行 = 192px，直接把第四行顶出滚动视口。
     *
     * 实测（探针 S1，窗口 1280）：
     * ```text
     * 四行的 y = 517 / 557 / 597 / 637   （每行 40px）
     * 滚动视口底边 ≈ 600  → 「片尾结束」整行在视口外
     * ```
     * 用户只看到前两行 → 以为"只有片头的两个箭头"。
     *
     * ★ 修法：显式收紧按钮的尺寸约束 —— 尺寸取共享常量 `kRowH`
     *   （与文件头的高度预算同源，改一处两处都跟着变）。
     *   演进：默认 48 → 40 → **32**（2026-09-24 塞进四行）
     *         → **36**（task-66 D，Owner 要求「四行 +/− 加大」）。
     *   每行**实际占高** = `kRowH` + 行底 `Padding(bottom: Sp.x1)`；
     *   `kMidRestH` 里按 4×40 计（见文件头），两者必须同步改。
     *
     * ⚠️ 不能用 `SizedBox(height: kRowH)` 硬包后不管命中区 —— 那会把
     *    命中区也压小，鼠标点在边缘会点不到。这里给按钮一个
     *    `kRowH × kRowH` 的**固定**尺寸，命中区仍有 `kRowH` 见方。
     */
    const stepSize = kRowH;

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★ 窄宽度也要活：用 LayoutBuilder 量**真实可用宽**，不猜窗口宽
     * ══════════════════════════════════════════════════════════════════
     *
     * ⚠️ 我第一版用「窗口宽 < 300」判紧凑 —— **错了**：
     *    那是**窗口**宽，不是这一行能用的宽。
     *    实测窗口 300 时：卡片 268，减 `Sp.x5*2`(40) 后每行只有 **228**，
     *    而完整形态需要 72+76+64+8+72 = **292** → RenderFlex overflow。
     *    判据用窗口宽就永远差着 72px 的账。
     *
     * `LayoutBuilder` 拿到的 `constraints.maxWidth` 才是这一行**真正**
     * 能用的宽 —— 弹窗边距、窗口宽、内边距怎么变都对。
     *
     * 两档降级：
     * ```text
     * 可用宽 >= 300  完整（标签 72 + 读数 76 + 「预览」文字）
     * 可用宽 <  300  紧凑（标签 52 + 读数 62 + 预览只留图标）
     * ```
     * 紧凑形态标称 = 52+62+36+36+8+36 = 230 —— 比 228 多 2px。
     * ★ 但**不会溢出**：下面那套「显式分配」会把两个文字列各缩 1px
     *   （`labelW + valueW <= textSpace` 恒成立，与按钮真实宽度无关）。
     *   这正是当初把「挑阈值」改成「算预算」的原因。
     *
     * ⚠️ 只降**宽度**，不降高度 —— 高度预算（`kMidRestH`）依赖每行 40px，
     *    这里改动高度会让四行又挤出视口（那正是用户报的 bug）。
     */
    return LayoutBuilder(
      builder: (context, box) {
        final compact = box.maxWidth < 300;

        /*
         * ══════════════════════════════════════════════════════════════
         * ★ 宽度**显式分配** —— 让溢出在数学上不可能
         * ══════════════════════════════════════════════════════════════
         *
         * 我第一版只把标签/读数在两档之间切换，以为够用 —— 实测
         * 窗口 300 时**仍溢出 14px**（`RenderFlex overflowed by 14 pixels`）。
         * 原因是按钮的**实际**宽度不总等于我以为的值（`IconButton` 的
         * `visualDensity` / `padding` / 文字宽度都会影响），
         * 靠"估一估再挑个阈值"永远差着几像素的账。
         *
         * 改成**先算固定开销、再把剩下的分给两个文字列**：
         * ```text
         * textSpace = maxWidth - 固定开销
         * labelW    = min(上限, textSpace * 72/148)     ← 保持原设计比例
         * valueW    = min(上限, textSpace - labelW)
         * ```
         * 于是 `labelW + valueW <= textSpace` **恒成立**，
         * 与按钮真实宽度无关 —— 溢出不可能发生。
         *
         * ⚠️ 宽松时结果与原来**完全一致**（72 / 76）：
         *    1280 窗口下 textSpace ≈ 500，`min(72, ...)` = 72。
         *    所以这个改动只在窄宽度下生效，不影响正常观感。
         */
        /*
         * ══════════════════════════════════════════════════════════════
         * ★★★ 2026-10-02：从「按比例瓜分」改成「**按实测需要**分配」
         * ══════════════════════════════════════════════════════════════
         *
         * # 真机缺陷（task-96 取证，我亲眼看过截图）
         *
         * 手机（1080x2400 @420dpi）上四行标签全部渲染成 `片…` ——
         * 只画出第一个字。像素取证：标签列墨迹 **144px → 68px**。
         *
         * # 根因
         *
         * 下面原来是 `labelW = textSpace * 72/(72+76)` —— **按比例**分。
         * 值一设上，`fixedW` 变大 ⇒ `textSpace` 变小 ⇒ `labelW` 被压到
         * 45px，而四个汉字要 **56px**（`FontSizes.sm = 14`）。
         *
         * ⚠️⚠️ 这个数**算错过两次**，因为 `lib\ui\tokens.dart` 里有
         *     **两个 `sm`**：`:79 Radii.sm = 12` 与 `:104 FontSizes.sm = 14`。
         *     按 12 算 ⇒ 得出"只差 2.3px"（错，会以为改改比例就够）；
         *     按真机像素反推 144÷2.625 = 54.86 ⇒ 4 × **14** ⇒ 实差 **17.9px**。
         *
         * ⇒ 所以这里**不再依赖任何字号常量**：用 `_textWidthOf` 拿真实
         *   `TextStyle` 去量。字体回退、字重、系统缩放全部自动算对，
         *   永远不会再和 `tokens.dart` 脱钩。
         *
         * # 新规则（四条，见下面 `=== 分配 ===`）
         *
         * ```text
         * ① 标签先拿到它**实测需要**的宽（含色条）
         * ② 读数再拿到它**实测需要**的宽
         * ③ 还有富余 ⇒ 按 72:76 的比例分掉（桌面下结果与改前**逐像素相同**）
         * ④ 约束提示挤不下 ⇒ **让位**（它是四行里唯一纯提示性的东西；
         *    越界时仍会 toast + 底部红字，所以"不静默"没有丢）
         * ```
         *
         * 下面这四个常量现在的角色是「**富余部分的分配上限**」，
         * 不再是分配本身 —— 所以它们偏小也不再能把标签截断。
         */
        const labelMax = 72.0;
        const valueMax = 76.0;
        const compactLabelMax = 52.0;
        const compactValueMax = 62.0;

        /*
         * 这一点的**约束提示**（值的右边那条小字）—— 见下面用到处的说明。
         *
         * ```text
         * 只设了上限  → 「≤ 00:19」
         * 只设了下限  → 「≥ 00:46」
         * 上下都有    → 「00:05-00:19」
         * 等于没约束（0..total）→ null（不显示，避免噪音）
         * ```
         *
         * ⚠️ **必须在算 `fixedW` 之前算出来** —— 它占宽（约 52px），
         *    漏掉它就会把文字列撑出边界（我第一版就是这么溢出的）。
         */
        String? hint;
        if (bound != null) {
          final (lo, hi) = bound!;
          final full = lo <= 0 && hi >= total.toInt();
          if (!full) {
            if (lo <= 0) {
              hint = '≤ ${_fmtSeconds(hi)}';
            } else if (hi >= total.toInt()) {
              hint = '≥ ${_fmtSeconds(lo)}';
            } else {
              hint = '${_fmtSeconds(lo)}-${_fmtSeconds(hi)}';
            }
          }
        }

        /// 除**三个文字列**外必须占掉的宽（按钮类，宽度是钉死的）
        ///
        /// ⚠️ 提示的宽**不在这里** —— 它是可让位的，见下面的分配。
        final fixedCore = stepSize * 2 // − / +
            +
            Sp.x2 // 与预览之间的间距
            +
            (compact ? stepSize : 68.0) // 预览（紧凑时只留图标）
            +
            (v != null ? stepSize : 0.0); // 清除按钮（只有设过值才有）

        /// 配对色条 + 它与文字之间的间距（task㉝）
        ///
        /// ⚠️ 我第一版漏了它 ⇒ 文字列多占了 `kAccentW + Sp.x1` 的宽，
        ///    而"文字列之和 <= 可用宽"的前提是固定开销完整。
        ///    少算就会**溢出**（"RenderFlex overflowed by 14 pixels"）。
        final accentCost = accent != null ? kAccentW + Sp.x1 : 0.0;

        final lMax = compact ? compactLabelMax : labelMax;
        final vMax = compact ? compactValueMax : valueMax;

        /*
         * ══════════════════════════════════════════════════════════════
         * ★★★ 实测三个文字列**各自需要多少**（不再猜字号）
         * ══════════════════════════════════════════════════════════════
         *
         * `labelStyle` / `valueStyle` / `hintStyle` 必须与下面
         * `Text(...)` 用的 style **逐字一致** —— 否则量出来的宽
         * 又不是真实占宽，等于把"猜字号"换成"猜 style"。
         */
        final labelStyle = TextStyle(
          fontSize: FontSizes.sm,
          color: colors.foreground,
        );
        final valueStyle = TextStyle(
          fontSize: FontSizes.sm,
          fontFamily: 'monospace',
          color: v == null ? colors.mutedForeground : colors.foreground,
        );
        final hintStyle = TextStyle(
          fontSize: FontSizes.cap,
          color: colors.mutedForeground,
        );

        final labelNeed = _textWidthOf(context, label, labelStyle) + accentCost;
        final valueNeed = _textWidthOf(
          context,
          v == null ? '— — —' : _fmtSeconds(v),
          valueStyle,
        );
        // 提示左边有 Sp.x1 的内边距，所以它要 `文字宽 + Sp.x1` 才不省略
        final hintNeed = hint == null
            ? 0.0
            : math.min(_textWidthOf(context, hint, hintStyle) + Sp.x1, kHintMaxW);

        final budget = math.max(box.maxWidth - fixedCore, 0.0);

        /*
         * ══════════════════════════════════════════════════════════════
         * ★★★ 分配（四条规则，按优先级）
         * ══════════════════════════════════════════════════════════════
         *
         * ```text
         * ① 三者都放得下 ⇒ 各拿"够用的"，富余按 72:76 分给标签/读数
         *                   （桌面 1280 下结果与改前**逐像素相同**）
         * ② 放不下       ⇒ 提示**让位**（它是唯一纯提示性的）
         * ③ 还是放不下   ⇒ 标签与读数按"需要的比例"缩
         * ④ 标签永远优先于读数 —— 标签是"这是哪一点"，
         *                   读数旁边就是它自己的值，读不出还能点预览
         * ```
         *
         * ⚠️ `lMax` / `vMax` 现在**只管富余的分配**，不再管"够不够"。
         *    这正是原缺陷的根因：原来 `labelW = textSpace * 72/148`，
         *    值一设上 `textSpace` 变小 ⇒ 标签被按比例压到 45px，
         *    而四个汉字要 56px ⇒ 渲染成 `片…`。
         */
        double labelW;
        double valueW;
        double hintW;

        if (labelNeed + valueNeed + hintNeed <= budget) {
          // ① 都够 —— 富余按原设计比例分
          var surplus = budget - labelNeed - valueNeed - hintNeed;
          hintW = hintNeed;
          final labelExtra = math.max(
            math.min(lMax - labelNeed, surplus * lMax / (lMax + vMax)),
            0.0,
          );
          labelW = labelNeed + labelExtra;
          surplus -= labelExtra;
          valueW = valueNeed + math.max(math.min(vMax - valueNeed, surplus), 0.0);
        } else {
          final twoNeed = labelNeed + valueNeed;
          if (twoNeed <= budget) {
            // ② 标签与读数够，提示让位（越界时仍会 toast + 底部红字）
            labelW = labelNeed;
            valueW = valueNeed;
            hintW = budget - twoNeed;
          } else {
            // ③ 极窄：按需要的比例缩，二者都还能看见一部分
            labelW = budget * labelNeed / twoNeed;
            valueW = budget - labelW;
            hintW = 0.0;
          }
        }

        return Padding(
          // 行间距 Sp.x2(8) → Sp.x1(4)：四行再省 16px
          padding: const EdgeInsets.only(bottom: Sp.x1),
          child: Row(
            children: [
              /*
               * ── ★ 配对色条（task㉝：让"一对"看得出来）──
               *
               * 与时间轴上同组箭头**同色**（片头=琥珀、片尾=蓝），
               * 用户不用读字就能把"行"和"轴上的箭头"对上。
               *
               * ★★ 零额外高度的关键：它是 `Row` 的**一个子项**，
               *    不是包在外面的 `Padding`/`SizedBox`。
               *    `Row` 的高度由最高的子项决定 —— 一个 3px 宽、
               *    撑满行高的 `Container` **不改变行高**。
               *    （实测验证见报告里的 [ROWS] 前后对比）
               *
               * ⚠️ 宽度固定 3px 且**从 labelW 里扣**（见下面 `- kAccentW`），
               *    否则会把文字列挤出边界 —— 那正是之前
               *    "RenderFlex overflowed by 14 pixels" 的成因。
               */
              if (accent != null)
                Container(
                  width: kAccentW,
                  height: stepSize,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(kAccentW / 2),
                  ),
                ),
              if (accent != null) const SizedBox(width: Sp.x1),
              SizedBox(
                width: labelW - (accent != null ? kAccentW + Sp.x1 : 0),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: labelStyle,
                ),
              ),
              // 当前值（未设置时显示占位）
              //
              // ★★★ 2026-10-06（task-13 ⑥）：**读数本身也能点**（见 onTapValue）
              //
              // ⚠️ 结构上只是把 Text 换成 MouseRegion > GestureDetector > Text，
              //    **仍是 Row 的一个子项** ⇒ 行高由 Row 决定，**零新增高度**
              //    （accent 那条"零高度"硬约束同样适用在这里：
              //     实测中段总高 596.0 == 视口 596.0，一点余量都没有）。
              SizedBox(
                width: valueW,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onTapValue,
                    child: Text(
                      v == null ? '— — —' : _fmtSeconds(v),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: valueStyle,
                    ),
                  ),
                ),
              ),
              /*
               * ★★ 就近显示这一点的**约束**（2026-09-25 用户：「不能静默」）
               *
               * # 为什么必须有（"底部红字不够"）
               *
               * 用户原话「这四个按钮，都是开始不能超过结束的，这个逻辑你没做」。
               * 真机实测确认：改前值**真的能越界**（片头 00:10 - 00:05），
               * 只在**底部**冒一行红字。而行在中间、提示在底部 ——
               * 相差 400px，用户点第 4 行时视线根本不会过去。
               *
               * 这里在**值的右边**贴一条小字，说明这一点能设到哪：
               * ```text
               * 片头开始  00:05   ≤ 00:19     − +  ▶预览      ← 上限来自「片头结束」
               * 片头结束  00:20   ≤ 00:44     − +  ▶预览      ← 上限来自「片尾开始」
               * 片尾结束  01:10   ≥ 00:46     − +  ▶预览      ← 下限来自「片尾开始」
               * ```
               * 于是**不用点就知道**边界在哪 —— 这才是"不静默"。
               *
               * ⚠️ 只在**有对应邻居**时才显示：全都未设置时显示四个
               *    `≥ 00:00` 是纯噪音（那本来就是显然的）。
               */
              if (hint != null)
                // ⚠️ 显式限宽（= 分配到的 `hintW`）—— 让宽度预算与真实占宽**相等**。
                //    不限宽的话文字会按内容撑，预算又对不上（会溢出）。
                //
                // ★ 2026-10-02：从固定 `kHintW` 改成**分配值** `hintW` ——
                //   挤不下时它会小于 `kHintW`（标签与读数优先），
                //   此时提示自身省略，而不是把标签压成 `片…`。
                SizedBox(
                  width: math.max(hintW - Sp.x1, 0.0),
                  child: Padding(
                    padding: const EdgeInsets.only(left: Sp.x1),
                    child: Text(
                      hint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: hintStyle,
                    ),
                  ),
                ),
            // ── 微调 ──
            _StepBtn(
              icon: Icons.remove,
              colors: colors,
              size: stepSize,
              // 未设置时先落一个合理默认（0 或末尾）
              onTap: () {
                final cur = v ?? 0;
                onChanged(cur - 1);
              },
              enabled: bound == null || (v ?? 0) > bound!.$1,
            ),
            _StepBtn(
              icon: Icons.add,
              colors: colors,
              size: stepSize,
              onTap: () {
                final cur = v ?? 0;
                onChanged(cur + 1);
              },
              enabled: bound == null || (v ?? 0) < bound!.$2,
            ),
            const SizedBox(width: Sp.x2),
            // ── 预览这一处（窄宽度下只留图标，省下 ~44px）──
            //
            // ⚠️ 两种形态都套 `SizedBox` 钉死宽度 —— 理由同 `_StepBtn`：
            //    `TextButton` / `IconButton` 的内部约束层会让实际宽度
            //    偏离预算值，只有父级 `SizedBox` 能保证"预算 = 实际"。
            if (compact)
              SizedBox(
                width: stepSize,
                height: stepSize,
                child: IconButton(
                  /*
                   * ★ task-13 ⑥：未设置时**不再置灰** —— 改走 onTapValue
                   *   （定格到默认位置，见 _defaultAt）。
                   *   ⚠️ 没传 onTapValue 时仍是 null ⇒ 旧行为不变。
                   */
                  onPressed: v == null ? onTapValue : () => onPreview(v),
                  icon: const Icon(Icons.play_arrow, size: 18),
                  tooltip: previewTip ?? '预览这一点',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    minimumSize: Size(stepSize, stepSize),
                    padding: EdgeInsets.zero,
                  ),
                ),
              )
            else
              /*
               * ⚠️ 必须限宽：`TextButton.icon` 在窄宽度下会按内容
               *    撑到 ~68px，而上面的 `fixedW` 预算假设的就是 68。
               *    不限的话实际宽度可能更大 → 又溢出（实测 14px）。
               *    这里显式钉死，让预算与实际一致。
               */
              SizedBox(
                width: 68,
                height: stepSize,
                child: TextButton.icon(
                  // ★ task-13 ⑥：同紧凑形态 —— 未设置时改走 onTapValue
                  onPressed: v == null ? onTapValue : () => onPreview(v),
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('预览'),
                  style: TextButton.styleFrom(
                    // 同样收紧 —— 默认 48 高会撑起整行
                    minimumSize: Size(0, stepSize),
                    padding: const EdgeInsets.symmetric(horizontal: Sp.x1),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            // ⚠️ `Spacer` 吃掉的正是 `textSpace` 里没分完的余量 ——
            //    它 `flex: 1` 会先让 `Row` 把固定宽的子节点放好，
            //    再把剩下的给它。所以 `textSpace` 的算法必须**保守**
            //    （宁可少分给文字，也不要让 Spacer 被压成 0 后溢出）。
            const Spacer(),
            // ── 清除这一点 ──
            if (v != null)
              SizedBox(
                width: stepSize,
                height: stepSize,
                child: IconButton(
                  onPressed: () => onChanged(null),
                  icon: const Icon(Icons.backspace_outlined, size: 18),
                  tooltip: '清除这一点',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    minimumSize: Size(stepSize, stepSize),
                    padding: EdgeInsets.zero,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StepBtn extends StatelessWidget {
  const _StepBtn({
    required this.icon,
    required this.colors,
    required this.onTap,
    this.size = kRowH,
    this.enabled = true,
  });

  final IconData icon;
  final AppPalette colors;
  final VoidCallback onTap;

  /// 按钮的**命中区**边长（默认 32 —— 见 `_EdgeRow` 里为什么必须收紧）
  final double size;

  /// 是否可点（false → 置灰）
  ///
  /// ★ 用来体现「**开始不能超过结束**」（2026-09-25 用户要求）：
  /// 到了该点的合法边界就置灰，用户一眼看出"到头了"，
  /// 而不是点了没反应（那会被理解成按钮坏了）。
  ///
  /// ⚠️ 即使 `false`，`onTap` 仍然保留 —— 因为 `onChanged` 那边还有
  ///    一道 `_applyEdge` 的 clamp 兜底（双保险：UI 拦住 + 数据夹住）。
  final bool enabled;

  @override
  Widget build(BuildContext context) => SizedBox(
        /*
         * ⚠️ 必须用 `SizedBox` **从外面**钉死宽高，不能只给
         *    `IconButton.constraints`（2026-09-24 实测踩到）
         *
         * # 症状
         *
         * 窗口 300 时 `_EdgeRow` 的 `Row` 溢出 14px，而我的宽度预算
         * （`fixedW = stepSize*2 + ...`）算出来是**放得下**的。
         * 也就是说 `IconButton` 的**实际**宽度比 `constraints` 说的大。
         *
         * # 为什么 `constraints` 不够
         *
         * `IconButton` 内部还会叠 `visualDensity`、`padding`、
         * `tapTargetSize`（`MaterialTapTargetSize.padded` 会强行把
         * 命中区撑到 48）等多层约束 —— 传进去的 `constraints`
         * 只是其中一层，最终尺寸由它们共同决定，**不等于**传入值。
         *
         * # 修法
         *
         * 外面套 `SizedBox` —— 它在**父级**给死宽高，
         * 内部怎么算都越不出去。于是"预算 = 实际"，溢出不可能发生。
         */
        width: size,
        height: size,
        child: IconButton(
          onPressed: enabled ? onTap : null,
          icon: Icon(icon, size: 18, color: enabled ? null : colors.border),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          // 关掉 48 的强制命中区扩展（那正是宽度失控的来源）
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            minimumSize: Size(size, size),
            padding: EdgeInsets.zero,
          ),
          tooltip: enabled
              ? (icon == Icons.add ? '加 1 秒' : '减 1 秒')
              : '已到边界（开始不能超过结束）',
        ),
      );
}
