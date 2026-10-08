// t429 —— arm64「内容区全空白」归属：内容区那次 ClipRect 是不是凶手
//
// ════════════════════════════════════════════════════════════════════
// 背景（全部已实测，不是推测）
// ════════════════════════════════════════════════════════════════════
//
// **交付阻塞项**：arm64 产品包（44.9 MB）在 Android TV 车 `emulator-5556`
// 上内容区全空白、底栏正常；同车同会话 x86_64 包完整渲染。
//
//   * t427 交付包本体：arm64 四张截图 t=12/20/30s **同为** 34825 B /
//     109 colours / px00=`#0A0A0A`（sha16 `E978F71D38702923`）⇒ 稳态非竞态；
//     x86_64 包四张全同 111405 B / 198 colours（sha16 `62C6A8CC28C8488B`）。
//   * 两臂 logcat 里 flutter 行各 26 行，剥前缀归一化后 `Compare-Object`
//     **唯一差异**是 `[HOME] getHome 返回: 0 个分组，耗时 8ms`(arm64) vs
//     `311ms`(x64ctl) ⇒ **不是 Dart 层差异**，是合成/绘制层。
//   * **已证同族先例**：t424 里 `FToaster` 内部 `Overlay.wrap` 的默认
//     `Clip.hardEdge`（forui-0.27.0\lib\src\widgets\toast\toaster.dart:410）
//     在 arm64 上让整棵树**全透明**（t424 段 4 进程内 `colors=1 px00=#000000
//     a00=00 alphas=1[00]`），而同构但 `Clip.none` 的段 5 读 580 色。
//     ⇒ **arm64 对 clip layer 极其敏感，这是已证事实不是猜测。**
//
// ════════════════════════════════════════════════════════════════════
// 待验假设
// ════════════════════════════════════════════════════════════════════
//
// 内容区在 `lib\shell.dart:3045 Positioned.fill(child: ClipRect(` **之内**，
// 底栏在 `:3332 Positioned(left: 0, right: 0, bottom: 0)` **之外**
// （同一 `Stack`，`:3035`）⇒ 与「底栏可见、内容不可见」精确吻合。
//
//   假设：**内容区那次 `ClipRect` 在 arm64 上把它整棵子树裁没了。**
//
// ════════════════════════════════════════════════════════════════════
// 刀法：最小对（每段只动**一个**自变量）
// ════════════════════════════════════════════════════════════════════
//
// ```text
// 段 0  PREINIT canary      纯色满屏（阳性对照：前置做完后引擎还能画）
// 段 1  Stack，内容**无** ClipRect          ← 基线
// 段 2  同 1，内容包 ClipRect(默认 hardEdge) ← 待验假设
// 段 3  同 2，唯一差别 clipBehavior: Clip.none
// 段 4  同 2，唯一差别 clipBehavior: Clip.antiAlias
// 段 5  同 2，但子树里放**需要合成**的后代（Opacity 0.5）⇒ layer 路径 + hardEdge
// 段 6  恢复 canary（证明进程/引擎仍活）
// 段 7  runApp(SourinApp(...))  ← **复现锚点**：不复现则前面各段什么也没证明
// 段 8  ★ 反混淆臂：Opacity(0.5) **无** ClipRect（段 5 的对照组）
// 段 9  ★ 2x2 最后一格：ClipRect(antiAlias) + Opacity ⇒ layer 路径 + antiAlias
// 段 10 恢复 canary（第二次，证明跑到最后进程仍活）
// ```
//
// ★★ 为什么非要凑齐 2x2（**这是本探针最要紧的一步**）：
//   `pushClipRect`（`flutter\...\rendering\object.dart:571-595`）按
//   `needsCompositing` 分两支，而 `clipBehavior` 又各有两个非 none 取值。
//   段 2/5 都灰、段 3/4 都彩，若只看这四段，"灰"既可归因于
//   **clipBehavior==hardEdge**，也可归因于**别的**；而段 5 同时改了
//   `needsCompositing`（加 Opacity）⇒ 它**一个变量都没隔离**。
//   只有把 (路径 × clipBehavior) 四格都测了，才能说清是哪一维在决定生死：
//   ```text
//                      canvas 路径        layer 路径
//     hardEdge         段2 = 灰           段5 = 灰
//     antiAlias        段4 = 彩           段9 = ?   ← 就缺这一格
//   ```
//   段 9 若**彩** ⇒ 决定生死的是 `clipBehavior`，与路径无关；
//   段 9 若**灰** ⇒ 决定生死的是 layer 路径，与 `clipBehavior` 无关。
//   ★ 顺带说明为什么段 3（`Clip.none`）**不能**当作 2x2 的一格：
//     `pushClipRect:579-582` 里 `Clip.none` **提前 return**，压根没进
//     `clipRectAndPaint`，也没进 layer 分支 —— 它是"第三支"，不是
//     canvas 路径的一个取值。把它混进 2x2 会把表读错。
// ```
//
// ★ 段 2/3/4/5 的**唯一**差别就是那一个 `clipBehavior` / 那一个后代：
//   其它一切（Stack、内容色、底栏色与高度、外层背景）逐字相同。
//
// ★ 段 5 为什么是关键：
//   `PaintingContext.pushClipRect`（flutter\...\rendering\object.dart）分两支：
//   ```dart
//   if (needsCompositing) {           // ← 建 ClipRectLayer（引擎级裁剪层）
//     final ClipRectLayer layer = oldLayer ?? ClipRectLayer();
//     layer..clipRect = offsetClipRect..clipBehavior = clipBehavior;
//     pushLayer(layer, painter, offset, childPaintBounds: offsetClipRect);
//   } else {                          // ← canvas.save()/clipRect()/restore()
//     clipRectAndPaint(offsetClipRect, clipBehavior, offsetClipRect,
//                      () => painter(this, offset));
//   }
//   ```
//   `ClipRect(child: ColoredBox)` 里没有 layer ⇒ `needsCompositing == false`
//   ⇒ 走 **canvas 路径**；`ClipRect(child: Opacity(0.5, ColoredBox))` 里
//   `RenderOpacity.alwaysNeedsCompositing == true` ⇒ `needsCompositing == true`
//   ⇒ 走 **ClipRectLayer 路径**。
//   ⇒ 段 2 与段 5 的对比直接回答「哪条路径坏」。
//
// ════════════════════════════════════════════════════════════════════
// 仪器纪律
// ════════════════════════════════════════════════════════════════════
// * 每段**都**有进程内读数（`_rootKey` 包一层 `RepaintBoundary`）—— 三个
//   本探针专有的读数点：`px00`（内容区左上）、`pxC`（屏幕正中）、
//   `a00`（**alpha**）。
//   ★ 必须读 alpha：t423 的旧尺子只取 RGB，把「全透明」与「不透明白」
//     都读成 `#000000`，而这两者在归属上意义完全相反。
// * 每段颜色**互不相同**，一个像素就能分辨是哪一段。
// * 段名同时写进设备侧报告与屏幕（canary 段），两个独立读数。
//
// ★★ 与 lead 的规格**刻意不同的两处**（都是为了仪器更可判，理由写在下面）：
//   ① 底栏用**固定白色** `0xFFFFFFFF`，不用「绿」。
//      lead 把段 1 的底栏写成「绿」，但段色表里 `1EC863`（绿）是**段 2 的
//      内容色**。若底栏也用绿，段 2 就会出现「内容被裁掉后露出的底栏绿」与
//      「内容绿」同色 ⇒ 这一段**无法区分**「内容在」与「内容没了」。
//      底栏改用一个**不在段色表里**的颜色（白），"底栏在不在" 就能在
//      **全部 7 段**上用同一个值比对。
//   ② 内容之外多一层**固定中性灰**外层背景（`ColoredBox` 包住整个 `Stack`）。
//      没有它，「内容被 ClipRect 裁没了」与「整棵 Stack 都没画」都表现为
//      纯黑，**两种性质完全相反的结论共用同一个读数**。有了它：
//        见段色   ⇒ 内容画出来了
//        见中性灰 ⇒ Stack 画了（底栏也在），**只有 ClipRect 那支子树没了**
//        见纯黑   ⇒ 连外层背景都没画（引擎/合成层整体失败）
//      它是**全部 5 段逐字相同**的常量，不破坏最小对。
//
// ⚠️ `.probe\t422_drive.py` 靠**文件名**同步（`t421_stage.txt` / `t421_report.txt`）
//    —— 这两个名字**不能改**，改了驱动就瞎了。段号/段名的映射由环境变量传。
//
// 运行（必须单独 build，因为要改入口）：
// ```powershell
// flutter build apk --release --target-platform android-arm64 -t lib/t429_arm64_probe.dart
// $env:T422_ABI_TAG='t429_arm64'; $env:T422_LAST_STAGE='10'
// $env:T422_STAGE_NAMES='PREINIT_canary,S1_no_clip,S2_clip_hardedge,S3_clip_none,S4_clip_antialias,S5_clip_compositing,S6_recovery_canary,S7_product_anchor,S8_opacity_no_clip,S9_layer_antialias,S10_final_canary'
// $env:T422_STAGE_COLORS='1E63C8,E8001E,1EC863,C81EC8,E8C81E,1EC8C8,C81E63,8C4A1E,2E8C6B,B85C1E,6B2E8C'
// python .probe\t422_drive.py <apk绝对路径> emulator-5556 arm64-v8a
//
// ★ `T422_STAGE_COLORS` 必须给满 **11** 项：`t422_drive.py:354` 只对
//   `STAGE_COLORS[i] != 0x000000` 的段印 verdict。段 7 是产品段，我给它一个
//   非零值（橙棕）**不是**为了断言它应该是橙棕，而是为了让驱动把它的屏幕读数
//   （色数 / px00 / pxC）打出来 —— 那正是本任务要看的「产品包内容区是什么颜色」。
//
// ★★ 注意：`lib\shell.dart:1194` 的注释里提到「段 4 逐字同构」等，那是
//    **t424 的段号**，与本文件的段号无关 —— 别把两套编号混起来读。
// ```

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
// ★★ 必须用 `material_ui` 的 `MaterialApp`，**不是** `flutter/material` 的！
//    本项目是「双 Material 拆分」：`flutter/material` 与 `material_ui`
//    各自有一套 `Theme` InheritedWidget，`Theme.of` 不能跨包
//    （`lib\shell.dart:1338-1339` 记着这个坑）。
//    产品用的是 `material_ui` 那套（`lib\shell.dart:35`）⇒ 本探针同源。
import 'package:material_ui/material_ui.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'core/device.dart';
import 'core/ffi.dart';
import 'core/ui_prefs.dart';
// ★ 段 7 的复现锚点要用产品自己的根 widget。这是**只读引用**，不改产品代码。
import 'shell.dart';

const String kTag = '[T429]';

/// 每段停多久，留给进程外截图。
const Duration kHold = Duration(seconds: 7);

/// 底栏高度（**逻辑**像素；本车 devicePixelRatio == 2.0 ⇒ 屏幕上是 160 物理 px）。
const double kBarHeight = 80.0;

/// 底栏色 —— **固定**，不随段变化。理由见文件头 ★★ ①。
const int kBarColor = 0xFFFFFFFF;

/// 外层背景色 —— 固定中性灰。理由见文件头 ★★ ②。
/// 刻意选一个**既不是任何段色、也不是底栏白、也不是纯黑**的值。
const int kVoidColor = 0xFF7F7F7F;

final GlobalKey _rootKey = GlobalKey();

String _workDir = '';

/// 每段的颜色 —— **必须彼此差得远**，这样一个像素就能分辨是哪一段。
///
/// 顺序与下面 `main()` 的刀法一一对应。
/// ★ 段 0/6 是满屏 canary；段 1..5 是**内容区**的颜色（底栏恒为白）。
const List<int> kStageColors = <int>[
  0xFF1E63C8, // 0  蓝     PREINIT canary
  0xFFE8001E, // 1  红     Stack，内容无 ClipRect
  0xFF1EC863, // 2  绿     + ClipRect(默认 hardEdge)
  0xFFC81EC8, // 3  洋红   + ClipRect(Clip.none)
  0xFFE8C81E, // 4  黄     + ClipRect(Clip.antiAlias)
  0xFF1EC8C8, // 5  青     + ClipRect(需要合成的后代)
  0xFFC81E63, // 6  玫红   恢复 canary
  0xFF8C4A1E, // 7  橙棕   复现锚点 runApp(SourinApp)（本段颜色只是"没画出来时"的兜底）
  0xFF2E8C6B, // 8  青绿   ★ 反混淆臂：Opacity(0.5) **无** ClipRect
  0xFFB85C1E, // 9  赭石   ★ 补齐 2x2 最后一格：ClipRect(antiAlias) + Opacity ⇒ layer 路径 + antiAlias
  0xFF6B2E8C, // 10 紫     恢复 canary（第二次，证明跑到最后进程仍活）
];

const List<String> kStageNames = <String>[
  'PREINIT_canary',
  'S1_no_clip',
  'S2_clip_hardedge',
  'S3_clip_none',
  'S4_clip_antialias',
  'S5_clip_compositing',
  'S6_recovery_canary',
  'S7_product_anchor',
  'S8_opacity_no_clip',
  'S9_layer_antialias',
  'S10_final_canary',
];

/// 每段一句话说明 —— 直接抄进报告，免得报告与代码走散。
const List<String> kStageWhat = <String>[
  '纯色满屏 canary（阳性对照：前置做完后引擎还能画）',
  'Stack + Positioned.fill(段色) + Positioned(bottom,白底栏)；内容**无** ClipRect',
  '同段1，内容包 ClipRect()（默认 Clip.hardEdge；needsCompositing=false ⇒ canvas 路径）',
  '同段2，唯一差别 clipBehavior: Clip.none（pushClipRect 直接 painter，不裁）',
  '同段2，唯一差别 clipBehavior: Clip.antiAlias（仍是 canvas 路径，只是开抗锯齿）',
  '同段2，唯一差别：后代是 Opacity(0.5) ⇒ needsCompositing=true ⇒ ClipRectLayer 路径',
  '纯色满屏 canary（证明黑过之后进程/引擎还活着、还能画）',
  'runApp(SourinApp(coreError:null, coreDataDir:_preDataDir)) —— 与 t424 段 E / t421 段 6 逐字相同',
  '★ 反混淆臂：内容 = Opacity(0.5, ColoredBox) 但**无** ClipRect（段 5 的对照组）',
  '★★ 补齐 2x2 最后一格：ClipRect(antiAlias) + Opacity ⇒ **layer 路径 + antiAlias**。'
      '与段 4（canvas+antiAlias）比 ⇒ 路径是否重要；与段 5（layer+hardEdge）比 ⇒ clipBehavior 是否重要',
  '纯色满屏 canary（第二次：证明跑到最后进程/引擎仍活）',
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
///
/// ⚠️ 同样复用 t421 的文件名（`t421_stage.txt`），驱动不用改就能驱动本探针。
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
/// ★ 三个读数点：`px00`（左上）、`pxC`（正中）、`a00`（alpha）。
///   `px00`/`pxC` 都落在**内容区**（底栏在最底部），所以它们直接回答
///   「内容那支子树画出来没有」；`a00` 区分「全透明（什么都没画）」与
///   「不透明白/黑（画了一层）」——这两者归属意义相反。
///
/// ★ 同时报 `alphas` 集合：alpha 通常只有 1~3 个值，全列出来比只报角落可信。
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

    // 正中像素（内容区）—— 与 px00 互为独立采样点。
    int center = -1;
    if (iw > 0 && ih > 0) {
      final off = ((ih ~/ 2) * iw + (iw ~/ 2)) * 4;
      if (off + 3 < bytes.length) {
        center = (bytes[off] << 16) | (bytes[off + 1] << 8) | bytes[off + 2];
      }
    }

    final top = rgb.take(4).map(hex6).join(',');
    final corner = bytes.length >= 4 ? hex6((bytes[0] << 16) | (bytes[1] << 8) | bytes[2]) : 'n/a';
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

/// 引擎状态读数（仪器三）：`renderViews` / `size` / `frames` / `hasScheduledFrame`。
///
/// 这不是像素，但能回答「Dart 侧是否还在出帧」这个二分问题的**一半**。
Future<String> _engineState() async {
  try {
    // ⚠️ `renderViews` 在 `RendererBinding` 上，不在 `WidgetsBinding` 上。
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

  await _writeStage(stage);
  _log('STAGE $stage HOLD-BEGIN');
  await Future<void>.delayed(kHold);
  _log('STAGE $stage HOLD-END');
}

/// 给结构段（1..5）用的读数 + 停留：**不 runApp**，只读 + 落段号 + 停。
Future<void> _holdStage(int stage, String what) async {
  await _settle();
  final read = await _inProc();
  final eng = await _engineState();
  _log('STAGE $stage (${kStageNames[stage]}) INPROC $read | $eng  [$what]');
  await _append('STAGE $stage (${kStageNames[stage]}) INPROC $read | $eng  [$what]');
  await _append('STAGE $stage WHAT $what');

  await _writeStage(stage);
  _log('STAGE $stage HOLD-BEGIN');
  await Future<void>.delayed(kHold);
  _log('STAGE $stage HOLD-END');
}

/// 装一段结构（段 1..5）—— 每段只有**一个**自变量不同。
Future<void> _mountSubject(int stage, String what) async {
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
  await _holdStage(stage, what);
}

/// 被测结构本体。
///
/// 三层，段 1..5 **逐字相同**，只有 `branch` 那一个变量不同：
/// ```text
///   [0] 外层背景（在 Stack 之外，常量）—— 见文件头 ★★ ②
///   [1] Positioned.fill(branch)          ← 内容区（对应 shell.dart:3044）
///   [2] Positioned(left/right/bottom)    ← 底栏（对应 shell.dart:3332）
/// ```
Widget _subject(int stage) {
  final Widget content = ColoredBox(
    color: Color(kStageColors[stage]),
    child: const SizedBox.expand(),
  );

  // ★ 全段唯一变化的那个自变量。
  final Widget branch;
  switch (stage) {
    case 2:
      branch = ClipRect(child: content); // 默认 Clip.hardEdge
      break;
    case 3:
      branch = ClipRect(clipBehavior: Clip.none, child: content);
      break;
    case 4:
      branch = ClipRect(clipBehavior: Clip.antiAlias, child: content);
      break;
    case 5:
      // ★ 关键：Opacity 让 needsCompositing == true ⇒ 走 ClipRectLayer 分支。
      branch = ClipRect(child: Opacity(opacity: 0.5, child: content));
      break;
    case 8:
      // ★★ 反混淆臂。段 5 同时动了**两个**东西（加了 ClipRect、又加了 Opacity），
      //    所以段 5 灰掉**不能**单独归因给"裁剪层"。这一段保留 Opacity、
      //    去掉 ClipRect —— 与段 5 的最小对：
      //      段 8 也灰 ⇒ 凶手是 Opacity（合成层），跟裁剪无关；
      //      段 8 彩 ⇒ 凶手是 ClipRect + needsCompositing 的**组合**（ClipRectLayer）。
      branch = Opacity(opacity: 0.5, child: content);
      break;
    case 9:
      // ★★ 补齐 2x2 的最后一格。
      //    已有：canvas+hardEdge(段2 灰) / layer+hardEdge(段5 灰) /
      //          canvas+antiAlias(段4 彩) / none(段3 彩) / 无裁剪(段1 彩)
      //    缺：  **layer + antiAlias** ← 这一段
      //    ⇒ 若本段"彩"，则灰的条件是 **clipBehavior==hardEdge**，与走哪条路径无关；
      //      若本段"灰"，则灰的条件是 **layer 路径**，与 clipBehavior 无关。
      branch = ClipRect(
        clipBehavior: Clip.antiAlias,
        child: Opacity(opacity: 0.5, child: content),
      );
      break;
    default:
      branch = content; // 段 1：无 ClipRect
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

  await _append('================ t429 start ================');
  _log('workdir=$_workDir');

  // ── 前置：与产品 main() 逐字同序的初始化 ──────────────────────
  // 这样各段才有可比性（缺了它们，后面变黑可能只是"没初始化"）。
  String pre = 'ok';
  try {
    MediaKit.ensureInitialized();
    await Device.init();
    final dir = await _resolveDataDir();
    _preDataDir = dir;
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

  // ── 段 1..5：最小对 ───────────────────────────────────────────
  await _mountSubject(1, kStageWhat[1]);
  await _mountSubject(2, kStageWhat[2]);
  await _mountSubject(3, kStageWhat[3]);
  await _mountSubject(4, kStageWhat[4]);
  await _mountSubject(5, kStageWhat[5]);

  // ── 段 6：恢复 canary —— 证明「黑」之后进程还活着、还能画 ──────
  await _canary(6);

  // ── 段 7：复现锚点 ────────────────────────────────────────────
  // ★ 为什么必须有这一段：本探针的**全部**意义是「把产品包的黑屏
  //   归因到某一个 widget」。如果这一跑里产品本身**不黑**，那么
  //   前面 5 段的绿/红/黄就什么也没证明 —— 它们只说明「这些结构能画」，
  //   而产品本来就画得出来，于是「凶手是谁」这个问题**根本没被问到**。
  //   ⇒ 复现失败时，本报告只能写「未复现」，**不能**写「假设被推翻」。
  //   与 t424 段 E / t421 段 6 逐字相同的调用（同一个 `_preDataDir`）。
  _log('CALL runApp(SourinApp) begin');
  await _append('CALL runApp(SourinApp) begin');
  runApp(SourinApp(coreError: null, coreDataDir: _preDataDir));
  _log('CALL runApp(SourinApp) done');

  await _settle();
  // ★ 段 7 不能包 RepaintBoundary（要逐字复刻产品）⇒ 走 RenderView 那条读数路。
  final a7 = await _inProcRoot();
  final e7 = await _engineState();
  _log('STAGE 7 (${kStageNames[7]}) INPROC $a7 | $e7');
  await _append('STAGE 7 (${kStageNames[7]}) INPROC $a7 | $e7');
  await _append('STAGE 7 WHAT ${kStageWhat[7]}');
  await _writeStage(7);
  _log('STAGE 7 HOLD-BEGIN');
  await Future<void>.delayed(kHold);
  _log('STAGE 7 HOLD-END');

  // ── 段 8：反混淆臂（Opacity 无 ClipRect）──────────────────────
  // 段 5 同时动了两个自变量，单独看它无法归因。段 8 保留 Opacity、去掉
  // ClipRect，与段 5 构成最小对。
  await _mountSubject(8, kStageWhat[8]);

  // ── 段 9：补齐 2x2 最后一格（layer + antiAlias）───────────────
  await _mountSubject(9, kStageWhat[9]);

  // ── 段 10：最后再恢复一次 canary（证明整跑结束时进程仍活）─────
  await _canary(10);

  _log('DONE');
  await _append('================ t429 done ================');
  exit(0);
}

String _preDataDir = '';

/// 进程内读数（**不需要** `_rootKey` 的版本）—— 给段 7 用。
///
/// ★ 段 7 必须**逐字复刻**产品（`runApp(SourinApp(...))`），不能再包一层
///   `RepaintBoundary`，所以 `_inProc()` 的 `_rootKey` 那条路走不通。
///   改从 `RenderView` 自己的 layer 取图：`OffsetLayer.toImage()` 是
///   `package:flutter/rendering.dart` 的公开 API，读像素**不改**控件树。
Future<String> _inProcRoot() async {
  try {
    final views = RendererBinding.instance.renderViews;
    if (views.isEmpty) return 'no-render-view';
    final rv = views.first;
    // ★★ 这里**必须**用 `layer`，而它有两个坑，两个都踩过：
    //
    //   ① 不能用 `debugLayer`：它的实现是
    //      `assert(() { result = _layerHandle.layer; ... }())`
    //      ⇒ **release 构建里整个 assert 体被剥掉，永远返回 null**。
    //      本探针是 release APK ⇒ 用 `debugLayer` 会得到一句 `layer:Null`，
    //      而它看起来和「真的没有 layer」一模一样（又一个 #516 同族）。
    //
    //   ② `layer` 标了 `@protected`，跨类调用会被 analyze 判
    //      `invalid_use_of_protected_member`。这是**静态 lint**，不是运行时
    //      限制：getter 体就是 `return _layerHandle.layer;`，在 release 里
    //      照常工作。本探针**不是** `RenderObject` 的子类，所以只能显式忽略。
    //      代价（一行 ignore）远小于收益（段 7 唯一能区分
    //      「Dart 没画」与「画了没上屏」的读数）。
    // ignore: invalid_use_of_protected_member
    final ContainerLayer? layer = rv.layer;
    if (layer is! OffsetLayer) {
      return 'layer:${layer?.runtimeType ?? "null"}';
    }
    final ui.Image img = await layer.toImage(rv.paintBounds, pixelRatio: 1.0);
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
    String hex6(int v) => '#${v.toRadixString(16).padLeft(6, '0').toUpperCase()}';
    int at(int x, int y) {
      final off = (y * iw + x) * 4;
      if (off + 3 >= bytes.length) return -1;
      return (bytes[off] << 16) | (bytes[off + 1] << 8) | bytes[off + 2];
    }

    final corner = at(0, 0);
    final center = at(iw ~/ 2, ih ~/ 2);
    final a0 = bytes.length >= 4 ? bytes[3] : -1;
    final aList = (alpha.toList()..sort())
        .take(4)
        .map((a) => a.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(',');

    return 'img=${iw}x$ih colors=${rgb.length} sampled=$n '
        'px00=${corner < 0 ? "n/a" : hex6(corner)} '
        'pxC=${center < 0 ? "n/a" : hex6(center)} '
        'a00=${a0.toRadixString(16).padLeft(2, '0').toUpperCase()} '
        'alphas=${alpha.length}[$aList] top=[${rgb.take(4).map(hex6).join(',')}]';
  } catch (e) {
    return 'ERR:$e';
  }
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
                  Shadow(offset: Offset(3, 3), blurRadius: 6, color: Color(0xFF000000)),
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
