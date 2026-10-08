// t435 —— 判定「同一子树里嵌套 ≥2 层 Clip.hardEdge ⇒ arm64 上整棵子树不画」
//
// ════════════════════════════════════════════════════════════════════
// 为什么要写这个探针：一次**被否证的修复**
// ════════════════════════════════════════════════════════════════════
//
// t429（本文件的前身）证明了：**在一个简单子树里加一层 hardEdge `ClipRect`
// 会让子树整个不画**（段1 活 / 段2 死；2x2 四格齐全）。这条**成立**。
//
// 但 Lead 把 `lib\shell.dart` 内容区那次 `ClipRect` 从默认 `Clip.hardEdge`
// 改成 `Clip.antiAlias` 后，重建 arm64 交付包 → 装机 → 跑 t427 驱动，
// 结果是**逐字节相同**（sha16 `E978F71D38702923` / 34825 B / 109 色 /
// `#0A0A0A`）⇒ **内容区仍然一个像素都没画**。
// 并且已证明改动**确实进了二进制**（`.filecache` md5 相符 + 时间序 + APK sha 变了）。
// ⇒ **不是「没编进去」，是这一处不充分。**
//
// ════════════════════════════════════════════════════════════════════
// 待验假设：不是「某一层」，而是「**层数**」
// ════════════════════════════════════════════════════════════════════
//
// Lead 的读数（本探针**已逐条复核**，见下）：
//   · `Navigator` 自带 `Overlay` 的裁剪也是 `Clip.hardEdge`
//     （`widgets\navigator.dart:1601 this.clipBehavior = Clip.hardEdge`）
//   · `Overlay` 的 `_Theatre.paint` **无条件**裁剪
//     （`widgets\overlay.dart:1532 if (clipBehavior != Clip.none) {` —— 没有
//      `_hasVisualOverflow` 那种前置条件）
//   · 真滚动视图那一层：`rendering\viewport.dart:973`
//     `if (hasVisualOverflow && clipBehavior != Clip.none) {`，默认 hardEdge
//     （`widgets\viewport.dart:79` / `widgets\scroll_view.dart:129`）
//
// ⇒ 假设：**arm64 上，同一子树里嵌套 ≥2 层 `Clip.hardEdge` ⇒ 该子树整个不画。**
//
// ★ 与「修复无效」自洽：产品内容区原本 3 层（① Overlay ② shell 内容区 ClipRect
//   ③ 页面滚动 Viewport）⇒ 拿掉②后仍剩 ①+③ = 2 层 ⇒ 仍然死。
//
// ★★ 但我**复核 SDK 时发现 Lead 的模型里有一处需要修正**（本探针要判的就是它）：
//
//   `widgets\app.dart:1696` —— `WidgetsApp` 给它的 `Navigator` 传的是
//   ```dart
//   child: Navigator(
//     clipBehavior: Clip.none,      // ← 不是 hardEdge！
//   ```
//   ⇒ **走 `WidgetsApp`/`MaterialApp` 的 App，其 Overlay 那一层是 `Clip.none`，
//     压根不裁。**（`Overlay.wrap` 的 `clipBehavior = Clip.hardEdge` 默认值
//     ——`overlay.dart:503`—— 只在**手动**用 `Overlay.wrap` 时才生效。）
//   ⇒ 「每个用 Navigator 的 App 至少已有 1 层 hardEdge」这句话
//     **对 `MaterialApp` 不成立**。产品用的是 `MaterialApp`（`shell.dart:1100`）。
//   ⇒ 所以「① Overlay」那一层要**减掉**：产品原本的 hardEdge 层数可能是
//     **2**（shell ClipRect + 滚动 Viewport），拿掉②后剩 **1** ⇒ 按"≥2"假设
//     应当**活**，但实测**死**。
//   ⇒ **这正好是要用探针判定的分歧点。** 段 1/4/5/6/7/8 就是为它设计的。
//
// ════════════════════════════════════════════════════════════════════
// 刀法：只动「hardEdge 层数」这一个自变量
// ════════════════════════════════════════════════════════════════════
//
// ```text
// 段 0  PREINIT canary                     阳性对照
// 段 1  Stack + Positioned.fill(段色)      **零层**自己加的裁剪（基线）
// 段 2  段1 + ClipRect(hardEdge)           +1 层（= t429 段2，回归确认）
// 段 3  段2 但 antiAlias                    +1 层但非 hardEdge
// 段 4  段1 + SingleChildScrollView(高内容)  +1 层（真 Viewport，hardEdge）
// 段 5  ★★ 段3 + SingleChildScrollView      hardEdge×1（Viewport）+ antiAlias×1
//                                            = 复刻「Lead 修复后的产品内容区」
// 段 6  段5 但滚动视图 antiAlias             0 层 hardEdge
// 段 7  段5 但滚动视图 Clip.none             0 层 hardEdge
// 段 8  ★ 3 层嵌套 ClipRect(hardEdge)        hardEdge×3（把「≥2」变成一条线）
// 段 9  恢复 canary                          证明进程/引擎仍活
// 段 10 ★ Overlay.wrap(默认 hardEdge)       判「Overlay 算不算一层」
// 段 11 ★ Overlay.wrap(Clip.none)           段 10 的对照
// 段 12 ★ Overlay(hardEdge)+antiAlias+滚动(hardEdge)  按 Lead 模型 = 修复后产品
// 段 13 恢复 canary                          第二次
// ```
//
// ★★ 段 10..12 为什么必须有（这是我对 Lead 模型的**复核结论**）：
//   Lead 的假设里「每个用 `Navigator` 的 App 至少已有 1 层 hardEdge」是**承重**的
//   —— 去掉它，产品只剩 1 层，按「≥2 死」应当**活**，与实测（死）矛盾。
//   但我复核 SDK 时发现：
//     · `widgets\app.dart:1696` —— `WidgetsApp` 给它自己的 `Navigator` 传的是
//       `clipBehavior: Clip.none`（**不是** hardEdge）⇒ 走 `MaterialApp` 的 App
//       那一层**根本不裁**；产品用的正是 `MaterialApp`（`shell.dart:1100`）。
//     · `Overlay.wrap` 的默认 `Clip.hardEdge`（`overlay.dart:503`）只在**手动**
//       调用时才生效 —— `FToaster` 那类正是手动用的（t424 先例）。
//   ⇒ 「Overlay 算不算一层」这件事，**读代码两边都能自圆其说**，只能靠实验分开。
//     段 10 vs 段 11 的差就是那一层；段 12 则是「按 Lead 模型算出来的修复后产品」。
//
// ★ 关键设计：段 1/4/5/6/7 都**不含 `Overlay`/`Navigator`**（本探针用
//   `runApp(RepaintBoundary(...))`，不走 `MaterialApp`）⇒ 段号里数出来的
//   hardEdge 层数**就是**该子树真实的层数，不会被 Overlay 那一层污染。
//   这正是为了让「层数」这个自变量干净可数。
//
// ★★ 段 5 为什么最关键：
//   它是**唯一**逐字复刻「Lead 修复后产品内容区」的一臂
//   （外层 `ClipRect(antiAlias)` + 内层真滚动 `Viewport(hardEdge)`）。
//     段 5 **死** ⇒ 探针**解释了**产品的负结果 ⇒ 假设成立，修法是消掉滚动那一层
//     段 5 **活** ⇒ 凶手在别处，不是裁剪嵌套 ⇒ 如实写出来（同样有价值）
//
// ★★ 段 8 为什么必须有：本探针里「hardEdge 层数 > 1」的点只有段 5（1 层 hardEdge
//   + 1 层 antiAlias）与段 12（Overlay + 滚动）—— 而这两个点各自还夹着别的
//   变量（段 5 有 antiAlias、段 12 有 Overlay）。**两个点连不成一条线。**
//   段 8 用**纯** 3 层嵌套 hardEdge（不含任何别的变量）把「层数越多越坏」
//   这条趋势变成可判的读数，也给「≥2」一个不含混杂变量的独立证据。
//
// ════════════════════════════════════════════════════════════════════
// 仪器纪律（沿用 t429 已验证的那套，并把 t429 踩过的两个坑写死）
// ════════════════════════════════════════════════════════════════════
//
// * **两台仪器都印**：进程内 `RenderRepaintBoundary.toImage()`（色数 + px00 +
//   **alpha**）与屏幕 `screencap`（色数 + px00 + pxC）。两列必须逐段一致。
//   ★ 必须读 alpha：t423 的旧尺子只取 RGB，把「全透明」与「不透明白」都读成
//     `#000000`，而这两者归属意义相反。
// * ★ 坑①（t429 犯过）：**陈旧截图覆盖**。驱动复用输出目录，旧一轮的
//   `sN_extra_*.png` 会留在盘上。报告脚本**只认规范名**
//   `s<N>_<kStageNames[N]>.png`，被拒收的**列出来**而不是悄悄忽略。
// * ★ 坑②（t429 犯过）：**判据把成功印成失败**。段 5/6/7 的内容外面可能有
//   半透明层 ⇒ 屏幕上**本来就不该**是段色而是合成值。判据必须先算
//   「该段**应当**出现什么颜色」再查，不能直接查段色。
// * 每段颜色**互不相同**，一个像素就能分辨是哪一段。
//
// ⚠️ `.probe\t422_drive.py` 靠**文件名**同步（`t421_stage.txt` /
//    `t421_report.txt`）—— 这两个名字**不能改**，改了驱动就瞎了。
//
// 运行：
// ```powershell
// flutter build apk --release --target-platform android-arm64 -t lib/t435_clip_depth_probe.dart
// $env:T422_ABI_TAG='t435_arm64'; $env:T422_LAST_STAGE='13'
// $env:T422_STAGE_NAMES='PREINIT_canary,S1_no_clip,S2_clip_hardedge,S3_clip_antialias,S4_scroll_hardedge,S5_antialias_plus_scroll_hardedge,S6_scroll_antialias,S7_scroll_none,S8_three_hardedge,S9_final_canary,S10_overlay_hardedge,S11_overlay_none,S12_overlay_hardedge_plus_anti_plus_scroll,S13_final_canary'
// $env:T422_STAGE_COLORS='1E63C8,E8001E,1EC863,C81EC8,E8C81E,1EC8C8,C81E63,8C4A1E,2E8C6B,6B2E8C,8C2E2E,2E5C8C,8C8C2E,4A8C2E'
// python .probe\t422_drive.py <apk绝对路径> emulator-5556 arm64-v8a
//
// ★ `T422_STAGE_COLORS` 必须给满 **14** 项：`t422_drive.py:354` 只对
//   `STAGE_COLORS[i] != 0x000000` 的段印 verdict。
// ```

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
// ★★ 必须用 `material_ui` 的 `MaterialApp`，**不是** `flutter/material` 的！
//    本项目是「双 Material 拆分」：两者各有一套 `Theme` InheritedWidget，
//    `Theme.of` 不能跨包（`lib\shell.dart:1338-1339` 记着这个坑）。
import 'package:material_ui/material_ui.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'core/device.dart';
import 'core/ffi.dart';
import 'core/ui_prefs.dart';

const String kTag = '[T435]';

/// 每段停多久，留给进程外截图。
const Duration kHold = Duration(seconds: 7);

/// 底栏高度（**逻辑**像素；本车 devicePixelRatio == 2.0 ⇒ 屏幕上是 160 物理 px）。
const double kBarHeight = 80.0;

/// 底栏色 —— **固定白**，不随段变化。
/// 理由：段色表里没有白 ⇒「底栏在不在」能用同一个值在**全部 10 段**上比对。
const int kBarColor = 0xFFFFFFFF;

/// 外层背景色 —— 固定中性灰。
/// ★ 为什么必须有：没有它，「内容被裁没了」与「整棵 Stack 都没画」都表现为纯黑，
///   **两种性质完全相反的结论共用同一个读数**。有了它：
///     见段色   ⇒ 内容画出来了
///     见中性灰 ⇒ Stack 画了（底栏也在），**只有被裁的那支子树没了**
///     见纯黑   ⇒ 连外层背景都没画（引擎/合成层整体失败）
const int kVoidColor = 0xFF7F7F7F;

/// 滚动内容的**内容高度**（逻辑 px）。
/// ★ 必须**大于**视口高度，否则 `hasVisualOverflow == false` ⇒
///   `rendering\viewport.dart:973` 那个 `if` 不成立 ⇒ **根本不裁** ⇒
///   这一臂就不是「+1 层 hardEdge」了，而是「0 层」。这是本探针最容易写错的地方。
const double kScrollContentHeight = 4000.0;

final GlobalKey _rootKey = GlobalKey();

String _workDir = '';

/// 每段的颜色 —— **必须彼此差得远**，这样一个像素就能分辨是哪一段。
const List<int> kStageColors = <int>[
  0xFF1E63C8, // 0  蓝     PREINIT canary
  0xFFE8001E, // 1  红     零层自加裁剪（基线）
  0xFF1EC863, // 2  绿     + ClipRect(hardEdge)      = 1 层
  0xFFC81EC8, // 3  洋红   + ClipRect(antiAlias)     = 1 层（非 hardEdge）
  0xFFE8C81E, // 4  黄     + 滚动 Viewport(hardEdge) = 1 层（真 Viewport）
  0xFF1EC8C8, // 5  青     ★★ antiAlias + 滚动(hardEdge) = 复刻修复后产品
  0xFFC81E63, // 6  玫红   同段5 但滚动 antiAlias    = 0 层 hardEdge
  0xFF8C4A1E, // 7  橙棕   同段5 但滚动 Clip.none     = 0 层 hardEdge
  0xFF2E8C6B, // 8  青绿   3 层嵌套 hardEdge          = 3 层
  0xFF6B2E8C, // 9  紫     恢复 canary
  0xFF8C2E2E, // 10 暗红   ★ Overlay.wrap 默认(hardEdge) —— 判「Overlay 算不算一层」
  0xFF2E5C8C, // 11 暗蓝   ★ Overlay.wrap(Clip.none) —— 段 10 的对照
  0xFF8C8C2E, // 12 橄榄   ★ Overlay(hardEdge) + antiAlias + scroll(hardEdge) = 2 层
  0xFF4A8C2E, // 13 草绿   恢复 canary（第二次）
];

const List<String> kStageNames = <String>[
  'PREINIT_canary',
  'S1_no_clip',
  'S2_clip_hardedge',
  'S3_clip_antialias',
  'S4_scroll_hardedge',
  'S5_antialias_plus_scroll_hardedge',
  'S6_scroll_antialias',
  'S7_scroll_none',
  'S8_three_hardedge',
  'S9_final_canary',
  'S10_overlay_hardedge',
  'S11_overlay_none',
  'S12_overlay_hardedge_plus_anti_plus_scroll',
  'S13_final_canary',
];

/// 每段一句话说明 —— 直接抄进报告，免得报告与代码走散。
const List<String> kStageWhat = <String>[
  '纯色满屏 canary（阳性对照：前置做完后引擎还能画）',
  'Stack + Positioned.fill(段色) + Positioned(bottom,白底栏)；**自己不加任何裁剪**（0 层）',
  '同段1 + ClipRect()（默认 Clip.hardEdge）⇒ 1 层 hardEdge（= t429 段2，回归确认）',
  '同段2，唯一差别 clipBehavior: Clip.antiAlias ⇒ 1 层但**非** hardEdge（= t429 段4）',
  '同段1 + SingleChildScrollView(内容 4000 高) ⇒ 真 Viewport(hardEdge) 1 层',
  '★★ 同段3 + SingleChildScrollView(hardEdge) = 复刻「Lead 修复后的产品内容区」',
  '同段5，唯一差别：滚动视图 clipBehavior: Clip.antiAlias ⇒ 0 层 hardEdge',
  '同段5，唯一差别：滚动视图 clipBehavior: Clip.none ⇒ 0 层 hardEdge',
  'ClipRect(hardEdge) 套 ClipRect(hardEdge) 套 ClipRect(hardEdge) ⇒ 3 层',
  '纯色满屏 canary（证明跑到最后进程/引擎仍活）',
  '★ 段1 外面套 Overlay.wrap(默认 hardEdge) ⇒ 判「Overlay 那一层算不算 1 层」',
  '★ 段10 的对照：Overlay.wrap(clipBehavior: Clip.none) ⇒ 若 10 死 11 活，则 Overlay 那层确实在裁',
  '★★ Overlay(hardEdge) + ClipRect(antiAlias) + 滚动(hardEdge) = 2 层 hardEdge；'
      '这是**按 Lead 的模型**算出来的「修复后产品内容区」（含 Overlay 那一层）',
  '纯色满屏 canary（第二次：证明跑到最后进程/引擎仍活）',
];

/// 每段「该子树里自己加的 hardEdge 层数」—— 报告里要和实测并排印，
/// 这样「层数 → 生死」的对应关系是**摆在纸面上**的，不靠读者心算。
///
/// ★ 段 10..12 的层数**取决于「Overlay 算不算一层」**这个待判问题，
///   所以那里填的是「自己加的层数」，Overlay 那一层单列（见 kHasOverlay）。
const List<int> kHardEdgeDepth = <int>[0, 0, 1, 0, 1, 1, 0, 0, 3, 0, 0, 0, 1, 0];

/// 该段是否**自带 `Overlay`**（自带则它可能再贡献一层 hardEdge）。
/// 段 10/12 用 `Overlay.wrap` 的默认（hardEdge）；段 11 用 `Clip.none`。
const List<int> kOverlayLayer = <int>[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0];

/// 每段「预期」—— 假设是「≥2 层 hardEdge ⇒ 死」。
/// ★ 0=预期活 / 1=预期死 / -1=待判（不下预测）
/// ★ 段 4 与段 5 是**待判**：段 4 单独看 Viewport 是 1 层（预期活），
///   段 5 是 1 层 hardEdge + 1 层 antiAlias —— 按"≥2 层 hardEdge"应当是**活**，
///   但 Lead 的模型认为产品里 ①Overlay 也算一层 ⇒ 段 5 该**死**。
///   这正是分歧点，所以标 -1 让它如实读出来，而不是被我预设。
/// ★ 段 10..12 也全部标 -1：它们是用来**判定 Overlay 那一层算不算**的，
///   预设答案就等于把要测的东西当成已知。
const List<int> kPredicted = <int>[
  0, 0, 1, 0, -1, -1, 0, 0, 1, 0, -1, -1, -1, 0,
];

void _log(String line) {
  debugPrint('$kTag $line');
}

/// ⚠️ 文件名 `t421_report.txt` **不能改** —— 进程外驱动按这个名字拉报告。
Future<void> _append(String line) async {
  try {
    await File('$_workDir/t421_report.txt').writeAsString(
      '${DateTime.now().toIso8601String()}  $line\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {}
}

/// 把段号落盘 —— 这是进程外驱动脚本的**同步信号**。
Future<void> _writeStage(int stage) async {
  try {
    await File('$_workDir/t421_stage.txt').writeAsString('$stage', flush: true);
  } catch (_) {}
}

/// 让出若干帧。
///
/// ⚠️ `endOfFrame` 必须带 timeout —— 否则引擎不出帧时这里**静默挂死**，
///    而挂死看起来和「黑屏」一模一样（都只是"没有画面"）。
Future<void> _settle() async {
  for (int i = 0; i < 3; i++) {
    try {
      SchedulerBinding.instance.scheduleFrame();
      await SchedulerBinding.instance.endOfFrame
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // 超时/异常都不致命：继续，读数会如实反映。
    }
  }
}

/// 进程内读回像素（仪器一）。
///
/// ★ 三个读数点：`px00`（左上）、`pxC`（正中）、`a00`（**alpha**）。
///   `px00`/`pxC` 都落在**内容区**（底栏在最底部），所以它们直接回答
///   「内容那支子树画出来没有」；`a00` 区分「全透明（什么都没画）」与
///   「不透明白/黑（画了一层）」——这两者归属意义相反。
Future<String> _inProc() async {
  try {
    final ctx = _rootKey.currentContext;
    if (ctx == null) return 'no-context';
    final ro = ctx.findRenderObject();
    if (ro is! RenderRepaintBoundary) return 'not-boundary:${ro.runtimeType}';
    final ui.Image img = await ro.toImage(pixelRatio: 1.0);
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    final iw = img.width;
    final ih = img.height;
    img.dispose();
    if (bd == null) return 'no-bytes';
    final bytes = bd.buffer.asUint8List();

    final rgb = <int>{};
    final alpha = <int>{};
    int n = 0;
    for (int i = 0; i + 3 < bytes.length; i += 4 * 7) {
      rgb.add((bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2]);
      alpha.add(bytes[i + 3]);
      n++;
    }

    String hex6(int v) =>
        '#${v.toRadixString(16).padLeft(6, '0').toUpperCase()}';

    int center = -1;
    if (iw > 0 && ih > 0) {
      final off = ((ih ~/ 2) * iw + (iw ~/ 2)) * 4;
      if (off + 3 < bytes.length) {
        center = (bytes[off] << 16) | (bytes[off + 1] << 8) | bytes[off + 2];
      }
    }

    final top = rgb.take(4).map(hex6).join(',');
    final corner = bytes.length >= 4
        ? hex6((bytes[0] << 16) | (bytes[1] << 8) | bytes[2])
        : 'n/a';
    final a0 = bytes.length >= 4 ? bytes[3] : -1;
    final aList = (alpha.toList()..sort())
        .take(4)
        .map((a) => a.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(',');

    return 'img=${iw}x$ih colors=${rgb.length} sampled=$n '
        'px00=$corner pxC=${center < 0 ? "n/a" : hex6(center)} '
        'a00=${a0.toRadixString(16).padLeft(2, '0').toUpperCase()} '
        'alphas=${alpha.length}[$aList] top=[$top]';
  } catch (e) {
    return 'ERR:$e';
  }
}

/// 引擎状态读数（仪器三）。
Future<String> _engineState() async {
  try {
    final views = RendererBinding.instance.renderViews;
    final rv = views.isNotEmpty ? views.first : null;
    final size = rv?.size;
    // ⚠️ 只写一个 `?.`：Dart 的流程分析在同一条 null-aware 链里会把
    //    `size?.width` 的续段提升为非空 ⇒ 第二个 `?.` 会被判
    //    `invalid_null_aware_operator`。
    return 'renderViews=${views.length} '
        'size=${size?.width.toStringAsFixed(0)}x${size?.height.toStringAsFixed(0)} '
        'frames=$_frameCount '
        'hasScheduledFrame=${SchedulerBinding.instance.hasScheduledFrame}';
  } catch (e) {
    return 'ERR:$e';
  }
}

int _frameCount = 0;
bool _timingsHooked = false;

void _hookTimings() {
  if (_timingsHooked) return;
  _timingsHooked = true;
  SchedulerBinding.instance.addTimingsCallback((List<FrameTiming> t) {
    _frameCount += t.length;
  });
}

/// 画一段金丝雀、读一次进程内像素、停 `kHold` 让外面截图。
Future<void> _canary(int stage) async {
  runApp(
    RepaintBoundary(
      key: _rootKey,
      child: _Canary(stage: stage),
    ),
  );
  await _settle();

  final read = await _inProc();
  final eng = await _engineState();
  _log('STAGE $stage (${kStageNames[stage]}) INPROC $read | $eng');
  await _append('STAGE $stage (${kStageNames[stage]}) INPROC $read | $eng');
  await _append('STAGE $stage WHAT ${kStageWhat[stage]}');
  await _append('STAGE $stage DEPTH ${kHardEdgeDepth[stage]}');

  await _writeStage(stage);
  _log('STAGE $stage HOLD-BEGIN');
  await Future<void>.delayed(kHold);
  _log('STAGE $stage HOLD-END');
}

/// 装一段结构（段 1..8）—— 每段只有**一个**自变量不同。
Future<void> _mountSubject(int stage) async {
  runApp(
    RepaintBoundary(
      key: _rootKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: ColoredBox(
          color: const Color(kVoidColor),
          child: _subject(stage),
        ),
      ),
    ),
  );
  await _settle();

  final read = await _inProc();
  final eng = await _engineState();
  _log('STAGE $stage (${kStageNames[stage]}) INPROC $read | $eng');
  await _append('STAGE $stage (${kStageNames[stage]}) INPROC $read | $eng');
  await _append('STAGE $stage WHAT ${kStageWhat[stage]}');
  await _append('STAGE $stage DEPTH ${kHardEdgeDepth[stage]}');

  await _writeStage(stage);
  _log('STAGE $stage HOLD-BEGIN');
  await Future<void>.delayed(kHold);
  _log('STAGE $stage HOLD-END');
}

/// 真滚动视图 —— **必须**用它，不能手搓 `ClipRect` 冒充。
///
/// ★ 为什么：产品里那一层是 `RenderViewport` 自己在
///   `rendering\viewport.dart:973` 裁的，而它**有条件**：
///   ```dart
///   if (hasVisualOverflow && clipBehavior != Clip.none) { pushClipRect(...) }
///   ```
///   内容比视口矮 ⇒ `hasVisualOverflow == false` ⇒ **根本不裁**。
///   所以内容高度必须 > 视口高度（本探针用 4000 > 540）。
Widget _scrollView(int color, Clip clip) {
  return SingleChildScrollView(
    clipBehavior: clip,
    child: SizedBox(
      height: kScrollContentHeight,
      child: ColoredBox(color: Color(color)),
    ),
  );
}

/// 被测结构本体。
///
/// 三层，各段**逐字相同**，只有 `branch` 那一个变量不同：
/// ```text
///   [0] 外层背景（在 Stack 之外，常量）—— 见 kVoidColor 的说明
///   [1] Positioned.fill(branch)          ← 内容区（对应产品的内容区）
///   [2] Positioned(left/right/bottom)    ← 底栏（对应产品底栏，在裁剪之外）
/// ```
Widget _subject(int stage) {
  final int c = kStageColors[stage];
  final Widget content = ColoredBox(
    color: Color(c),
    child: const SizedBox.expand(),
  );

  // ★ 全段唯一变化的那个自变量：hardEdge 层数。
  final Widget branch;
  switch (stage) {
    case 2:
      branch = ClipRect(child: content); // 1 层 hardEdge（默认）
      break;
    case 3:
      branch = ClipRect(clipBehavior: Clip.antiAlias, child: content); // 非 hardEdge
      break;
    case 4:
      // 真 Viewport(hardEdge)：默认 clipBehavior 就是 hardEdge。
      branch = _scrollView(c, Clip.hardEdge);
      break;
    case 5:
      // ★★ 关键臂：复刻「Lead 修复后的产品内容区」
      //    外层 antiAlias（= Lead 的修复）+ 内层滚动 Viewport(hardEdge)
      branch = ClipRect(
        clipBehavior: Clip.antiAlias,
        child: _scrollView(c, Clip.hardEdge),
      );
      break;
    case 6:
      branch = ClipRect(
        clipBehavior: Clip.antiAlias,
        child: _scrollView(c, Clip.antiAlias),
      );
      break;
    case 7:
      branch = ClipRect(
        clipBehavior: Clip.antiAlias,
        child: _scrollView(c, Clip.none),
      );
      break;
    case 8:
      // 3 层嵌套 hardEdge —— 把「≥2」从两个点变成一条线
      branch = ClipRect(child: ClipRect(child: ClipRect(child: content)));
      break;
    default:
      branch = content; // 段 1：自己不加任何裁剪
      break;
  }

  return Stack(
    children: <Widget>[
      Positioned.fill(child: branch),
      const Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        height: kBarHeight,
        child: ColoredBox(color: Color(kBarColor)),
      ),
    ],
  );
}

/// 段 10..12 的被测结构 —— 这几段**自带 `Overlay`**，用来判定
/// 「`Overlay` 那一层到底算不算一层 hardEdge」。
///
/// ★ 为什么必须单独测这一条：
///   Lead 的模型里「每个用 `Navigator` 的 App 至少已有 1 层 hardEdge」是**承重**的
///   —— 去掉它，产品就只剩 1 层，按"≥2 死"应当**活**，与实测（死）矛盾。
///   但我复核 SDK 时发现 `widgets\app.dart:1696` 里 `WidgetsApp` 给它自己的
///   `Navigator` 传的是 **`clipBehavior: Clip.none`** ⇒ 走 `MaterialApp` 的 App
///   那一层**根本不裁**。而 `Overlay.wrap` 的默认值 `Clip.hardEdge`
///   （`overlay.dart:503`）只在**手动**调用时才生效。
///   ⇒ 两种说法必须用**实验**分开，不能靠读代码互相说服。
///
/// 段 10 = `Overlay.wrap(默认 hardEdge)` + 段1 的内容（自己 0 层）
/// 段 11 = `Overlay.wrap(Clip.none)`      + 段1 的内容（段 10 的对照）
/// 段 12 = `Overlay.wrap(默认 hardEdge)` + `ClipRect(antiAlias)` + 滚动(hardEdge)
///         ⇒ 按 Lead 的模型这是「修复后的产品内容区」（Overlay + 滚动 = 2 层）
Widget _overlaySubject(int stage) {
  final int c = kStageColors[stage];

  Widget inner;
  if (stage == 12) {
    // Overlay(hardEdge) + antiAlias + 滚动(hardEdge) —— 复刻「修复后产品内容区」
    inner = ClipRect(
      clipBehavior: Clip.antiAlias,
      child: _scrollView(c, Clip.hardEdge),
    );
  } else {
    // 段 10/11：自己不加任何裁剪 ⇒ 该子树里唯一的裁剪层就是 Overlay 那一层
    inner = ColoredBox(color: Color(c), child: const SizedBox.expand());
  }

  // ★ 段 11 是段 10 的**唯一**差别：Overlay 的 clipBehavior。
  final Clip overlayClip =
      stage == 11 ? Clip.none : Clip.hardEdge;

  return Stack(
    children: <Widget>[
      Positioned.fill(
        child: Overlay.wrap(
          clipBehavior: overlayClip,
          child: inner,
        ),
      ),
      const Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        height: kBarHeight,
        child: ColoredBox(color: Color(kBarColor)),
      ),
    ],
  );
}

/// 装一段「自带 Overlay」的结构（段 10..12）。
Future<void> _mountOverlaySubject(int stage) async {
  runApp(
    RepaintBoundary(
      key: _rootKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: ColoredBox(
          color: const Color(kVoidColor),
          child: _overlaySubject(stage),
        ),
      ),
    ),
  );
  await _settle();

  final read = await _inProc();
  final eng = await _engineState();
  _log('STAGE $stage (${kStageNames[stage]}) INPROC $read | $eng');
  await _append('STAGE $stage (${kStageNames[stage]}) INPROC $read | $eng');
  await _append('STAGE $stage WHAT ${kStageWhat[stage]}');
  await _append('STAGE $stage DEPTH ${kHardEdgeDepth[stage]}');
  await _append('STAGE $stage OVERLAY ${kOverlayLayer[stage]}');

  await _writeStage(stage);
  _log('STAGE $stage HOLD-BEGIN');
  await Future<void>.delayed(kHold);
  _log('STAGE $stage HOLD-END');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _hookTimings();

  try {
    final d = await getExternalStorageDirectory();
    _workDir = d?.path ??
        '/storage/emulated/0/Android/data/app.sourin.sourin_spike/files';
  } catch (_) {
    _workDir = '/data/local/tmp';
  }
  try {
    await Directory(_workDir).create(recursive: true);
  } catch (_) {}

  await _append('================ t435 start ================');
  _log('workdir=$_workDir');

  // ── 前置：与产品 main() 逐字同序的初始化 ──────────────────────
  // 这样各段才有可比性（缺了它们，后面变黑可能只是"没初始化"）。
  String pre = 'ok';
  try {
    MediaKit.ensureInitialized();
    await Device.init();
    final dir = await _resolveDataDir();
    await UiPrefs.load(dir);
    await SourinCore.startAsync(dir);
    await LiquidGlassWidgets.initialize();
  } catch (e) {
    pre = 'ERR:$e';
  }
  _log('PRE-INIT -> $pre  kind=${Device.kind} isTv=${Device.isTv}');
  await _append('PRE-INIT -> $pre  kind=${Device.kind} isTv=${Device.isTv}');

  // 段 0：阳性对照。若它都不上屏，后面所有黑都不可解释。
  await _canary(0);

  // ── 段 1..8：只动 hardEdge 层数 ───────────────────────────────
  for (int s = 1; s <= 8; s++) {
    await _mountSubject(s);
  }

  // ── 段 9：恢复 canary ─────────────────────────────────────────
  await _canary(9);

  // ── 段 10..12：判定「Overlay 那一层算不算一层 hardEdge」────────
  // ★ 这三段自带 `Overlay`，是 Lead 模型里那个承重前提的**直接实验**。
  await _mountOverlaySubject(10);
  await _mountOverlaySubject(11);
  await _mountOverlaySubject(12);

  // ── 段 13：最后再恢复一次 canary ──────────────────────────────
  await _canary(13);

  _log('DONE');
  await _append('================ t435 done ================');
  exit(0);
}

/// 金丝雀：纯色底 + 一行大字。颜色和文字**都**编码了段号 ⇒ 两个独立读数。
class _Canary extends StatelessWidget {
  const _Canary({required this.stage});

  final int stage;

  @override
  Widget build(BuildContext context) {
    final int c = kStageColors[stage];
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: Color(c),
        child: SizedBox.expand(
          child: Center(
            child: Text(
              'S$stage ${kStageNames[stage]}',
              textAlign: TextAlign.center,
              softWrap: true,
              style: const TextStyle(
                fontSize: 64,
                fontWeight: FontWeight.bold,
                color: Color(0xFFFFFFFF),
                shadows: <Shadow>[
                  Shadow(
                      offset: Offset(3, 3),
                      blurRadius: 6,
                      color: Color(0xFF000000)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 产品数据目录。Android 上 `getApplicationSupportDirectory()` 就是
/// `/data/user/0/<pkg>/files` —— 与产品自己用的私有目录同址。
///
/// ★★ **不要**传显式数据目录给 `SourinCore.startAsync`：会报
///    `SourinCoreException: 建数据目录失败 ./app.sourin.player:
///     Read-only file system (os error 30)`。
Future<String> _resolveDataDir() async {
  final d = await getApplicationSupportDirectory();
  if (!await d.exists()) await d.create(recursive: true);
  return d.path;
}
