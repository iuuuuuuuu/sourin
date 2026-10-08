// t436 —— 把**真实产品**渲染树里的每一个裁剪点量出来（arm64 vs x86_64 逐行 diff）
//
// ════════════════════════════════════════════════════════════════════
// 这个探针要回答的唯一问题
// ════════════════════════════════════════════════════════════════════
//
//   「arm64 上，内容区那条链里到底嵌套了几层 `Clip.hardEdge`？分别在哪？」
//
// 背景（全部已实测，不是推测；来源 `.probe\t434_negative_result.txt`）：
//   · 交付阻塞项：arm64 包在 `emulator-5556` 上内容区全空白、底栏正常；
//     x86_64 同车同会话完整渲染。
//   · t429 的最小对把变量钉到 `clipBehavior == Clip.hardEdge`
//     （2x2 四格：canvas+hardEdge 死 / layer+hardEdge 死 /
//      canvas+antiAlias 活 / layer+antiAlias 活）。
//   · Lead 据此把 `lib\shell.dart` 内容区那次 `ClipRect` 改成 `antiAlias`，
//     **重建 arm64 交付包 → 装机 → 实测 ⇒ 逐字节相同**（t20/t30 sha16 都是
//     `E978F71D38702923`，109 色，px00=`#0A0A0A`）⇒ **这一处不是凶手**。
//   · 修正后的假设：不是"某一处"，而是**嵌套层数**（≥2 层 hardEdge 才死）。
//     ★★ 但"层数"到目前为止**是推理，不是读数** —— 本探针就是去把它量出来。
//
// ════════════════════════════════════════════════════════════════════
// 与任务书规格**刻意不同的两处**（都是为了让读数更可判，理由在下面）
// ════════════════════════════════════════════════════════════════════
//
// ① ★★ **裁剪点不再靠"类型名单"枚举，改成靠"有没有公开的 `clipBehavior`
//    getter"来发现。** 理由：
//      · 任务书给了一份名单（`RenderClipRect` / `RenderClipRRect` /
//        `RenderClipPath` / `RenderViewport` / `_RenderTheater` / `RenderStack`）。
//        名单**必然漏**：`RenderClipOval`、`RenderClipRSuperellipse`、
//        `RenderShrinkWrappingViewport`、`RenderAnnotatedRegion`… 都不在名单里，
//        而它们**都**能裁。漏一个就可能把"层数"数少。
//      · 更关键：**私有类**（`_RenderCustomClip` 的子类、`_RenderTheater`、
//        `_RenderColoredBox`…）没法用 `is` 判。名单法对私有类只能靠
//        `runtimeType.toString()` 字符串比对 —— 那是**脆**的（改个名就静默失效，
//        且失效表现为"少一行输出"，看起来像"这里没有裁剪点"）。
//      · 而 `Clip get clipBehavior` 是 `_RenderCustomClip:1536`、
//        `RenderViewportBase:676`、`RenderStack:474`、`_RenderTheater:1283` 上的
//        **公开 getter** ⇒ 用 `dynamic` 访问 `clipBehavior` 就能**把私有子类一起
//        抓到**（Dart 的 `dynamic` 调用按运行时名字解析，不要求静态可见）。
//        ⇒ 本探针用它当**主判据**，名单法只作为**交叉核对**（两法都印，可比对）。
//
// ② ★ **多印一列 `approxClip`（`describeApproximatePaintClip`）**。
//    它是 SDK 自己用来回答"这个子树被裁到哪儿"的公开 API
//    （`RenderObject:3762`，被 `RenderStack:742` / `RenderViewport:886` /
//     `RenderProxyBox:1560` 覆写）。它**不**等于真实裁剪（`Stack` 只在
//     `_hasVisualOverflow` 时才真裁，而它**总是**返回那个 rect）⇒
//    它回答的是"**如果**裁，会裁到哪儿"，是**上界**。
//    多这一列的价值：t434 的假设里"页面滚动 Viewport 是第 3 层"需要被证实，
//    而 Viewport 的裁剪受 `_hasVisualOverflow` 门控 —— 有了这列才能看出
//    "有裁剪意图但没触发"与"根本没裁剪意图"的区别。
//
// ════════════════════════════════════════════════════════════════════
// ★★ 一条**必须写进报告**的仪器局限（先说清楚，免得后面误读）
// ════════════════════════════════════════════════════════════════════
//
// **`RenderObject` 树上数出来的 hardEdge 层数，与"Skia/合成器实际收到几个
//   scissor"不是同一个量。** 两个已知的缺口：
//   (a) `RenderStack` / `RenderViewport` 只在 `_hasVisualOverflow` 时才真裁；
//       本探针**读不到**那个私有布尔（`stack.dart:392 bool _hasVisualOverflow`）
//       ⇒ 它们只能按"意图"记，不能按"事实"记。本探针用 `approxClip` 列
//       （`describeApproximatePaintClip` 返回 null ⇒ 该节点认为不需要裁）
//       作为**代理判据**，并在报告里标明这是代理。
//   (b) `clipBehavior != none` 在 `needsCompositing` 不同时会走 canvas 或
//       layer 两条不同路径（`object.dart:571-595 pushClipRect`），
//       两条路径在引擎侧的表现**可能不同**（t429 的 2x2 就是为了分辨这个）。
//       ⇒ 所以每行都印 `needsCompositing`，报告按"路径 × clipBehavior"分列。
//   ⇒ 因此本报告的措辞一律是"**树上有几层**"，不是"**引擎收到几个 scissor**"。
//
// ════════════════════════════════════════════════════════════════════
// ★★★ 第三件仪器：**layer 树**（t434 §4① 点名的"决定性仪器"）
// ════════════════════════════════════════════════════════════════════
//
// 上面 (a) 那个缺口有解：**`ClipRectLayer` 只在真的裁了的时候才存在**
// （`stack.dart:718 if (clipBehavior != Clip.none && _hasVisualOverflow)`、
//  `viewport.dart:973 if (hasVisualOverflow && clipBehavior != Clip.none)`）。
// ⇒ **数 layer 树里的 `ClipRectLayer`，数到的就是"真的裁了几次"**，
//   不需要知道任何私有布尔。这正是 t434 §4① 说的那条路。
//
// 可行性已逐条核过（都是公开 API）：
//   · `RenderObject.layer`（`object.dart:3159`）标了 `@protected`，但**不是**
//     debug-only（对比 `debugLayer:3184`，那个体被 `assert(() {...}())` 包着
//     ⇒ release 下**永远返回 null**）。跨类调用只需一行 `// ignore:`。
//   · `ContainerLayer.firstChild:1092` / `Layer.nextSibling:565` ⇒ 可以自己走树。
//   · `ClipRectLayer.clipRect:1617` / `clipBehavior:1636`、
//     `ClipRRectLayer` / `ClipRSuperellipseLayer` / `ClipPathLayer` 同形。
//   · `OffsetLayer`（`RenderView.layer` 就是它）是 `ContainerLayer` 的子类。
//
// ★ 为什么还要**同时**保留 RO 树那份读数：两份读数回答**不同**的问题 ——
//   RO 树 = "有几处**打算**裁"（含被 `_hasVisualOverflow` 挡住的），
//   layer 树 = "**真的**裁了几次"。两边的差就是"意图 vs 事实"。
//   报告里两份都印、并做差集，比只印一份更能定位。
//
// ⚠️⚠️ **但 layer 树**不是**完整的"事实"** —— 这条是写完才逐字读出来的，
//   必须写进报告，否则会把"layer 树里没有"误读成"没有裁剪"：
//
//   `PaintingContext.pushClipRect`（`rendering\object.dart:571-595`）分两支：
//   ```dart
//   if (clipBehavior == Clip.none) { painter(this, offset); return null; }
//   final Rect offsetClipRect = clipRect.shift(offset);
//   if (needsCompositing) {
//     final ClipRectLayer layer = oldLayer ?? ClipRectLayer();
//     layer..clipRect = offsetClipRect..clipBehavior = clipBehavior;
//     pushLayer(layer, painter, offset, childPaintBounds: offsetClipRect);
//     return layer;                      // ← 建 layer
//   } else {
//     clipRectAndPaint(offsetClipRect, clipBehavior, offsetClipRect,
//                      () => painter(this, offset));
//     return null;                       // ★★ 不建 layer！
//   }
//   ```
//   ⇒ **canvas 路径的裁剪在 layer 树里完全不存在**（它进了 `PictureLayer` 的
//     picture 里，成为一条 `canvas.clipRect` 记录，不是 layer）。
//   ⇒ 所以三份读数各自的覆盖面是：
//   ```text
//     RO 树     ：全部裁剪点（含 Clip.none / 含被 _hasVisualOverflow 挡住的）
//     layer 树  ：只有 needsCompositing == true 且**真的执行了**的那些
//     PictureLayer 的 picture ：canvas 路径那些（本探针**没有**解析它）
//   ```
//   ⇒ 本报告一律用"**树上有几处打算裁**"/"**层上有几处真的裁了**"两种措辞，
//     **绝不**说"引擎收到了 N 个 scissor" —— 那第三个量本探针**没有测**。
//   ★ 交叉核对的价值正在于此：RO 树里 `needsCompositing=Y` 的那些**应该**在
//     layer 树里找到对应层；找不到 ⇒ 它被 `_hasVisualOverflow` 挡住了
//     （"有意图、无事实"）。这就是 diff 那一段的判据。
//
// ════════════════════════════════════════════════════════════════════
// 段法（5 段）
// ════════════════════════════════════════════════════════════════════
//
// ```text
// 段 0  PREINIT canary   纯色满屏（阳性对照：前置做完引擎还能画）
// 段 1  ★ 产品本体 runApp(SourinApp(coreError:null, coreDataDir:_preDataDir))
//        —— 与 t429 段 7 逐字相同；等首帧 + ≥8s 让 getHome 完成、内容区稳定
// 段 2  ★★ 遍历渲染树，把每个裁剪点落盘（本探针的主体）
// 段 3  再读一次 _inProc()/_engineState()（"这时内容区到底画没画"的判据）
// 段 4  恢复 canary（证明跑到最后进程/引擎仍活）
// ```
//
// ★ 为什么段 1 与段 2 要分开：段 1 停 8 秒是给 `getHome` 用的（网络）；
//   段 2 的树遍历必须在**内容区稳定之后**做，否则量到的是骨架屏的树。
//   两段都各自写段号 + 停 `kHold`，进程外驱动能分别截图。
//
// ⚠️ 文件名的坑（照抄 t429 的结论）：`.probe\t422_drive.py` 靠**文件名**
//   同步（`t421_stage.txt` / `t421_report.txt`），这两个名字**不能改**。
//
// 运行（必须单独 build，因为要改入口）：
// ```powershell
// flutter build apk --release --target-platform android-arm64 -t lib/t436_clip_tree_probe.dart
// $env:T422_ABI_TAG='t436_arm64'; $env:T422_LAST_STAGE='4'
// $env:T422_STAGE_NAMES='PREINIT_canary,PRODUCT_settle,CLIP_TREE_DUMP,PRODUCT_measure,FINAL_canary'
// $env:T422_STAGE_COLORS='1E63C8,8C4A1E,C81EC8,B85C1E,6B2E8C'
// python .probe\t422_drive.py <apk绝对路径> emulator-5556 arm64-v8a
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
// ★ 段 1 的复现锚点要用产品自己的根 widget。这是**只读引用**，不改产品代码。
import 'shell.dart';

const String kTag = '[T436]';

/// 每段停多久，留给进程外截图。
const Duration kHold = Duration(seconds: 7);

/// 段 1 额外等多久让 `getHome` 完成（网络）。
/// ★ t427 实测两臂 getHome 耗时 8ms(arm64) vs 311ms(x64) ⇒ 8s 有 25 倍余量。
const Duration kSettleForHome = Duration(seconds: 8);

final GlobalKey _rootKey = GlobalKey();

String _workDir = '';

/// 每段的颜色 —— 段 0..6 各不同，一个像素就能分辨是哪一段。
const List<int> kStageColors = <int>[
  0xFF1E63C8, // 0 蓝     PREINIT canary
  0xFFE8C81E, // 1 黄     ★ 校准臂（画面就是校准树自己的纯色底）
  0xFF2E5C8C, // 2 靛     ★★ 裸 MaterialApp（打破 add-remote-order 的模型简并）
  0xFF8C4A1E, // 3 橙棕   产品本体（本段颜色只是"没画出来时"的兜底）
  0xFFC81EC8, // 4 洋红   树遍历（画面仍是产品，本段色同样只是兜底）
  0xFFB85C1E, // 5 赭石   产品读数
  0xFF6B2E8C, // 6 紫     恢复 canary
];

const List<String> kStageNames = <String>[
  'PREINIT_canary',
  'CALIBRATION_known_clips',
  'BARE_MATERIALAPP',
  'PRODUCT_settle',
  'CLIP_TREE_DUMP',
  'PRODUCT_measure',
  'FINAL_canary',
];

/// 每段一句话说明 —— 直接抄进报告，免得报告与代码走散。
const List<String> kStageWhat = <String>[
  '纯色满屏 canary（阳性对照：前置做完后引擎还能画）',
  '★★ 校准臂：合成一棵**已知裁剪层数**的树（预测 ClipRectLayer=2 / ClipRRectLayer=1 / '
      'maxHardChain=2 / RO 裁剪点=3）⇒ 自证 layer 走树器活着，'
      '并给"计数=0"提供可判据的对照',
  '★★ 裸 MaterialApp（home 只放一个纯色 ColoredBox，**零显式裁剪**）'
      '⇒ 直接数出"MaterialApp 自带那套 Overlay/Navigator 到底贡献几层 ClipRectLayer"，'
      '用来打破 add-remote-order 的模型简并（A: Overlay 是 Clip.none ⇒ 阈值≥1 层 / '
      'B: 是 hardEdge ⇒ 阈值≥2 层）',
  'runApp(SourinApp(coreError:null, coreDataDir:_preDataDir)) —— 与 t429 段 7 逐字相同；'
      '首帧 + 等 8s 让 getHome 完成',
  '★★ 遍历**两棵树**：RO 树（有几处"打算"裁）+ layer 树（"真的"裁了几次）'
      '（clipBehavior + size + approxClip + needsCompositing + layer 链长）',
  '再读一次 _inProc()/_engineState()：这时内容区到底画没画',
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

// ══════════════════════════════════════════════════════════════════
// 段 2 的主体：遍历渲染树，把每一个裁剪点量出来
// ══════════════════════════════════════════════════════════════════

/// 一个裁剪点的读数。
class _ClipSite {
  _ClipSite({
    required this.depth,
    required this.path,
    required this.typeName,
    required this.viaGetter,
    required this.viaName,
    required this.behavior,
    required this.size,
    required this.approxClip,
    required this.needsCompositing,
    required this.hardDepth,
    required this.isLayer,
  });

  final int depth;

  /// 从根到它的类型路径（最近 6 层），用 `>` 连。
  final String path;

  /// `runtimeType` 的字符串名（私有类也能拿到）。
  final String typeName;

  /// ★ 主判据：有没有**公开的** `clipBehavior` getter（用 dynamic 访问）。
  final bool viaGetter;

  /// 交叉核对：名字是否在任务书那份名单里。
  final bool viaName;

  /// `clipBehavior` 的字符串值；取不到写 `n/a`。
  final String behavior;

  final String size;

  /// `describeApproximatePaintClip` —— "**如果**裁，会裁到哪儿"（上界）。
  final String approxClip;

  final bool needsCompositing;

  /// 从根累积到**本节点**的 hardEdge 计数（含本节点）。
  final int hardDepth;

  /// `needsCompositing` 决定 `pushClipRect` 走 canvas 还是 layer 分支。
  final bool isLayer;

  String get key =>
      '$typeName|$behavior|$size|$approxClip|$needsCompositing';

  String get line => 'CLIP|d=$depth|hard=$hardDepth|$typeName|'
      'getter=${viaGetter ? "Y" : "n"}|name=${viaName ? "Y" : "n"}|'
      'cb=$behavior|size=$size|approx=$approxClip|'
      'comp=${needsCompositing ? "Y" : "n"}|path=$path';
}

/// 任务书给的那份名单 —— **只用作交叉核对**，不作为发现裁剪点的主判据。
///
/// ★ 它**必然不全**（漏 `RenderClipOval` / `RenderClipRSuperellipse` /
///   `RenderShrinkWrappingViewport` 等），也**够不到私有子类**
///   （`_RenderCustomClip` 的具体子类、`_RenderTheater`）。
///   保留它只为在报告里能说"名单法与 getter 法各抓到几个、差在哪"。
///
/// ★★ 修正（写探针时发现的原设计缺陷）：任务书这份名单里**混进了两个
///   `clipBehavior` 字段的类** —— `RenderOpacity` 与 `RenderRepaintBoundary`。
///   它们**没有** `clipBehavior`（它们只有 `alwaysNeedsCompositing`），
///   任务书要它们是为了记 `needsCompositing`（决定 canvas/layer 分支）。
///   若把它们算进"裁剪点"，会**把裁剪点的计数抬高**，而那个计数正是本报告
///   的核心产出 ⇒ 会把"链上第一个裁剪点是哪个"指错。
///   ⇒ 本探针把它们**移到单独的 `COMP|` 记录**里（信息不丢，但不污染裁剪计数）。
const Set<String> kNameList = <String>{
  'RenderClipRect',
  'RenderClipRRect',
  'RenderClipPath',
  'RenderClipOval',
  'RenderClipRSuperellipse',
  'RenderViewport',
  'RenderShrinkWrappingViewport',
  'RenderStack',
  '_RenderTheater',
};

/// 只记 `needsCompositing`、**不是**裁剪点的那些类型。
/// ★ 单列出来，避免它们混进裁剪点计数（见上面 ★★）。
const Set<String> kCompositingOnlyNames = <String>{
  'RenderOpacity',
  'RenderRepaintBoundary',
};

/// 走树时收集的 `COMP|` 行（`RenderOpacity` / `RenderRepaintBoundary`）。
/// ★ 用顶层列表而不是返回值，是为了不改 `_walkClips` 的签名（它已经被
///   校准臂用 `_lastRoClipSites` 快照取数）。
final List<String> _compLines = <String>[];

/// 用 `dynamic` 读 `clipBehavior` —— 这是**主判据**。
///
/// 为什么能抓到私有类：`dynamic` 调用按**运行时名字**解析，不要求静态可见。
/// `Clip get clipBehavior` 是 `_RenderCustomClip:1536`、
/// `RenderViewportBase:676`、`RenderStack:474`、`_RenderTheater:1283` 上的公开
/// getter ⇒ 连它们的**私有子类**也一并命中。
///
/// ★ 返回 `null` 表示"这个节点没有 clipBehavior"，与"有但读失败"要能区分：
///   后者返回 `Clip.none` 之外的哨兵字符串 `'ERR:...'`。
String? _readClipBehavior(RenderObject ro) {
  try {
    final dynamic d = ro;
    final Object? v = d.clipBehavior;
    if (v == null) return null;
    // `Clip` 是 enum ⇒ `toString()` 给 `Clip.hardEdge` 这种形态。
    return v.toString();
  } catch (_) {
    // NoSuchMethodError（没有这个 getter）也算 null —— 与"读失败"无关。
    return null;
  }
}

/// `describeApproximatePaintClip` 需要一个 child；本节点若有唯一子节点就用它。
///
/// ★ 为什么这么取：`RenderStack:742` / `RenderViewport:886` /
///   `RenderProxyBox:1560` 的实现都是"算一个 rect 返回"，**不依赖 child 的实际
///   几何**（`RenderStack` 用 `_hasVisualOverflow` + size；`RenderProxyBox`
///   用 child 的 `paintBounds`）。所以传唯一子节点（没有就传自己）是安全的；
///   若某实现真的用了 child，读数会在该行体现为 `ERR`，不会静默变成 null。
String _approxClipOf(RenderObject ro) {
  RenderObject? child;
  ro.visitChildren((RenderObject c) {
    child ??= c;
  });
  final RenderObject arg = child ?? ro;
  try {
    final Rect? r = ro.describeApproximatePaintClip(arg);
    if (r == null) return 'null';
    return '${r.left.toStringAsFixed(0)},${r.top.toStringAsFixed(0)},'
        '${r.right.toStringAsFixed(0)},${r.bottom.toStringAsFixed(0)}';
  } catch (e) {
    return 'ERR';
  }
}

/// 递归遍历，收集所有裁剪点。
///
/// ★ 只遍历 `RenderObject` 树（`visitChildren` 是公开 API，release 下可用）。
///   **不用** `toStringDeep()` / `debugDumpRenderTree()` —— 那是 debug-only，
///   而且本探针要的是**结构化字段**，不是打印字符串。
List<_ClipSite> _walkClips(RenderObject root) {
  final List<_ClipSite> out = <_ClipSite>[];
  _compLines.clear();
  int visited = 0;
  int skipped = 0;

  void visit(RenderObject ro, int depth, int hardSoFar, List<String> path) {
    visited++;
    // ★ 防御性上限：真的撞上时**必须计数**，否则"少了很多裁剪点"会被
    //   误读成"这棵树本来就没几个裁剪点"（0 分不出"没有"与"没测到"）。
    if (depth > 200) {
      skipped++;
      return;
    }
    final String typeName = ro.runtimeType.toString();
    final String? cb = _readClipBehavior(ro);
    final bool viaGetter = cb != null;
    final bool viaName = kNameList.contains(typeName);
    // 路径尾（最近 6 层）—— 两个分支都要用，先算出来。
    final List<String> p = <String>[...path, typeName];
    final String tail = (p.length <= 6 ? p : p.sublist(p.length - 6)).join('>');
    final String sizeStr = ro is RenderBox && ro.hasSize
        ? '${ro.size.width.toStringAsFixed(0)}x'
            '${ro.size.height.toStringAsFixed(0)}'
        : '-';

    // 本节点的 hardEdge 是否计入"从根累积"。
    // ★ 只有**真的会裁**的取值才计数：`Clip.none` 不裁。
    //   `hardEdge` 与 `antiAlias` 都会裁，但只有 `hardEdge` 进 hard 计数
    //   （这正是 t429 二分出来的那个变量）。
    final bool isHard = cb == 'Clip.hardEdge';
    final int hardHere = hardSoFar + (isHard ? 1 : 0);

    if (viaGetter || viaName) {
      // ★ `hasSize` / `size` 是 **`RenderBox`** 上的，不在 `RenderObject` 上。
      //   遍历拿到的静态类型是 `RenderObject` ⇒ 必须先判 `is RenderBox`。
      //   不是 box 的（理论上本树里没有，但防御性写）记 `notBox`，
      //   而**不是**静默写 noSize —— 两者含义不同（后者会被读成"没布局"）。
      final String size;
      if (ro is RenderBox) {
        size = ro.hasSize
            ? '${ro.size.width.toStringAsFixed(0)}x'
                '${ro.size.height.toStringAsFixed(0)}'
            : 'noSize';
      } else {
        size = 'notBox';
      }
      final List<String> p = <String>[...path, typeName];
      final List<String> tail =
          p.length <= 6 ? p : p.sublist(p.length - 6);
      out.add(_ClipSite(
        depth: depth,
        path: tail.join('>'),
        typeName: typeName,
        viaGetter: viaGetter,
        viaName: viaName,
        behavior: cb ?? 'n/a',
        size: size,
        approxClip: _approxClipOf(ro),
        needsCompositing: ro.needsCompositing,
        hardDepth: hardHere,
        isLayer: ro.needsCompositing,
      ));
    } else if (kCompositingOnlyNames.contains(typeName)) {
      // ★★ `RenderOpacity` / `RenderRepaintBoundary`：**没有** `clipBehavior`，
      //    它们不是裁剪点（见 kCompositingOnlyNames 的说明）。
      //    但它们的 `needsCompositing` 决定 `pushClipRect` 走 canvas 还是 layer
      //    ⇒ 信息要留，单独记 `COMP|`，**不进裁剪点计数**。
      _compLines.add('COMP|d=$depth|$typeName|'
          'comp=${ro.needsCompositing ? "Y" : "n"}|size=$sizeStr|path=$tail');
    }

    int n = 0;
    ro.visitChildren((RenderObject c) {
      n++;
      if (n > 400) {
        skipped++; // ★ 必须计数：见上面 depth 那条同族理由
        return;
      }
      visit(c, depth + 1, hardHere, <String>[...path, typeName]);
    });
  }

  visit(root, 0, 0, <String>[]);
  _lastRoVisited = visited;
  _lastRoSkipped = skipped;
  return out;
}

/// 段 2 的主读数：遍历 + 落盘。
Future<String> _dumpClipTree() async {
  try {
    final views = RendererBinding.instance.renderViews;
    if (views.isEmpty) return 'no-render-view';
    final RenderObject root = views.first;

    final List<_ClipSite> sites = _walkClips(root);
    final int nGetter = sites.where((s) => s.viaGetter).length;
    final int nNameOnly = sites.where((s) => !s.viaGetter && s.viaName).length;
    final int nHard = sites.where((s) => s.behavior == 'Clip.hardEdge').length;
    final int maxHard =
        sites.isEmpty ? 0 : sites.map((s) => s.hardDepth).reduce((a, b) => a > b ? a : b);

    _lastRoClipSites = sites.length;

    // ★ Lead 要求的"跳过/拒收计数"：证明走树器**确实走完了整棵树**，
    //   而不是在某个地方静默停了（那样会给出"裁剪点很少"的假读数）。
    await _append('CLIPSUM sites=${sites.length} viaGetter=$nGetter '
        'nameOnly=$nNameOnly hardEdgeSites=$nHard maxHardDepth=$maxHard '
        'visited=$_lastRoVisited skipped=$_lastRoSkipped');

    // ★ `COMP|` 行（不是裁剪点，见 kCompositingOnlyNames 的说明）。
    for (final String s in _compLines) {
      await _append(s);
    }

    // ★ 按"从根累积的 hardEdge 计数"排序 —— 这样"哪条链上有几层"一眼可见。
    //   同 hard 值时按深度，便于还原树的形状。
    final List<_ClipSite> sorted = <_ClipSite>[...sites]
      ..sort((a, b) {
        final c = a.hardDepth.compareTo(b.hardDepth);
        if (c != 0) return c;
        return a.depth.compareTo(b.depth);
      });
    for (final _ClipSite s in sorted) {
      await _append(s.line);
    }

    return 'sites=${sites.length} viaGetter=$nGetter nameOnly=$nNameOnly '
        'hardEdgeSites=$nHard maxHardDepth=$maxHard';
  } catch (e) {
    return 'ERR:$e';
  }
}

// ══════════════════════════════════════════════════════════════════
// 像素仪器（照抄 t429，三个读数点：px00 / pxC / a00）
// ══════════════════════════════════════════════════════════════════

/// ★★★ 第三件仪器：走 **layer 树**，数"**真的**裁了几次"。
///
/// 与 RO 树那份读数的关系（两份回答不同问题）：
///   RO 树   = 有几处**打算**裁（含被 `_hasVisualOverflow` 挡住的）
///   layer 树 = **真的**裁了几次
/// 依据：`ClipRectLayer` 只在真裁时才被 `pushClipRect` 建出来
/// （`stack.dart:718`、`viewport.dart:973` 都有 `hasVisualOverflow` 前置条件）。
///
/// ★ 遍历用公开 API：`ContainerLayer.firstChild:1092` + `Layer.nextSibling:565`。
///   **不用** `toStringDeep()`（那是打印字符串，且 debug-only 成分多）。
///
/// ★ 入口取 `RenderView.layer`：`RenderView` 是 repaint boundary，
///   框架会自动给它建 `OffsetLayer`（`object.dart:3154-3157` 的文档明说）。
Future<String> _dumpLayerTree() async {
  try {
    final views = RendererBinding.instance.renderViews;
    if (views.isEmpty) return 'no-render-view';
    final rv = views.first;
    // `layer` 是 @protected（静态 lint），但**不是** debug-only ——
    // 对比 `debugLayer:3184` 那个被 assert 包住、release 下恒 null 的。
    // ignore: invalid_use_of_protected_member
    final ContainerLayer? root = rv.layer;
    if (root == null) return 'root-layer-null';

    final List<String> clipLines = <String>[];
    int nClipRect = 0, nClipRRect = 0, nClipPath = 0, nClipSuper = 0;
    int nOpacity = 0, nPicture = 0, nOffset = 0, nTotal = 0;
    int maxHardChain = 0;
    int skipped = 0;
    // 从根累积的 hardEdge 链长（layer 树上"真的裁"的那条链）。

    void walk(Layer l, int depth, int hardSoFar, List<String> path) {
      nTotal++;
      // ★ 防御性上限**必须计数** —— 否则"层很少"分不出"真的少"与"提前停了"。
      if (depth > 200 || nTotal > 20000) {
        skipped++;
        return;
      }
      final String t = l.runtimeType.toString();
      final List<String> p = <String>[...path, t];
      final List<String> tail = p.length <= 8 ? p : p.sublist(p.length - 8);

      int hardHere = hardSoFar;
      if (l is ClipRectLayer) {
        nClipRect++;
        final String cb = l.clipBehavior.toString();
        if (cb == 'Clip.hardEdge') hardHere++;
        final Rect? r = l.clipRect;
        clipLines.add('LAYERCLIP|kind=ClipRectLayer|d=$depth|hard=$hardHere|'
            'cb=$cb|rect=${r == null ? "null" : "${r.left.toStringAsFixed(0)},${r.top.toStringAsFixed(0)},${r.right.toStringAsFixed(0)},${r.bottom.toStringAsFixed(0)}"}'
            '|path=${tail.join(">")}');
      } else if (l is ClipRRectLayer) {
        nClipRRect++;
        final String cb = l.clipBehavior.toString();
        if (cb == 'Clip.hardEdge') hardHere++;
        clipLines.add('LAYERCLIP|kind=ClipRRectLayer|d=$depth|hard=$hardHere|'
            'cb=$cb|path=${tail.join(">")}');
      } else if (l is ClipPathLayer) {
        nClipPath++;
        final String cb = l.clipBehavior.toString();
        if (cb == 'Clip.hardEdge') hardHere++;
        clipLines.add('LAYERCLIP|kind=ClipPathLayer|d=$depth|hard=$hardHere|'
            'cb=$cb|path=${tail.join(">")}');
      } else if (l.runtimeType.toString() == 'ClipRSuperellipseLayer') {
        nClipSuper++;
        clipLines.add('LAYERCLIP|kind=ClipRSuperellipseLayer|d=$depth|'
            'hard=$hardHere|path=${tail.join(">")}');
      } else if (l is OpacityLayer) {
        nOpacity++;
      } else if (l is PictureLayer) {
        nPicture++;
      } else if (l is OffsetLayer) {
        nOffset++;
      }

      if (hardHere > maxHardChain) maxHardChain = hardHere;

      if (l is ContainerLayer) {
        for (Layer? c = l.firstChild; c != null; c = c.nextSibling) {
          walk(c, depth + 1, hardHere, p);
        }
      }
    }

    walk(root, 0, 0, <String>[]);

    // ★ 快照给校准臂比对用（**不解析文本** —— 解析自己刚写的文本 =
    //   又一个可能说谎的中间层）。
    _lastLayerClipRect = nClipRect;
    _lastLayerClipRRect = nClipRRect;
    _lastLayerMaxHard = maxHardChain;
    _lastLayerVisited = nTotal;
    _lastLayerSkipped = skipped;

    await _append('LAYERSUM total=$nTotal clipRect=$nClipRect '
        'clipRRect=$nClipRRect clipPath=$nClipPath clipSuperellipse=$nClipSuper '
        'opacity=$nOpacity picture=$nPicture offset=$nOffset '
        'maxHardChain=$maxHardChain skipped=$skipped '
        'rootType=${root.runtimeType}');
    for (final String s in clipLines) {
      await _append(s);
    }

    return 'total=$nTotal clipRect=$nClipRect clipRRect=$nClipRRect '
        'clipPath=$nClipPath clipSuper=$nClipSuper opacity=$nOpacity '
        'picture=$nPicture offset=$nOffset maxHardChain=$maxHardChain '
        'skipped=$skipped';
  } catch (e) {
    return 'ERR:$e';
  }
}

/// ★★★ 有序路径清单（Lead 收紧后的**核心产出**）。
///
/// 目标：回答「**从根走到内容区，遇到的第一个裁剪点是哪个？它的 `clipBehavior`
/// 是什么？在哪个 widget 上？**」
///
/// 为什么是"第一个"而不是"层数"（Lead 拿到 t435 后的修正）：
///   t435 的 13 段给出：段 5 = 最外层 antiAlias（里面套 hardEdge）⇒ **活**；
///   段 12 = 最外层 hardEdge（里面是 antiAlias）⇒ **死**。
///   ⇒ 决定生死的是**最先遇到的那个裁剪**的 `clipBehavior`，不是层数。
///   这条同时解释了 t429 的 7 段与 t435 的 11 段（18/18）。
///
/// ⇒ 所以本函数按 **paint 顺序**（即 `visitChildren` 的遍历顺序，也就是
///   `RenderObject.paint` 的递归顺序）列出从根到目标的**每一个节点**，
///   并高亮**第一个带裁剪的节点**。
///
/// ★ 目标怎么定：用**几何**判定，不用 key（产品代码不许改，加不了 key）。
///   内容区 = 最大的那个 `RenderViewport`（滚动视图）；
///   底栏   = `localToGlobal` 之后落在屏幕底部那条带里的、面积最大的节点。
///   两个目标各自的定位依据都**打印出来**，便于人工核对选对没有。
///
/// ★★ 一条诚实的局限：`visitChildren` 的顺序是**框架的挂载顺序**，对
///   `RenderObject` 来说它**就是 paint 顺序**（`RenderStack` 按 children 顺序
///   paint、`RenderViewport` 按 sliver 顺序）—— 但这不是 SDK 的**契约**，
///   是当前实现的顺序。若某节点的 paint 顺序与挂载顺序不同，本清单的
///   "第一个"会指错。⇒ 报告里标明这条依赖。
List<String> _orderedPathTo(RenderObject root, RenderObject target) {
  // ① 先找从根到 target 的节点链（深度优先，取第一条命中的路径）。
  List<RenderObject>? chain;
  void dfs(RenderObject ro, List<RenderObject> acc) {
    if (chain != null) return;
    acc.add(ro);
    if (identical(ro, target)) {
      chain = List<RenderObject>.from(acc);
    } else {
      ro.visitChildren((RenderObject c) {
        if (chain == null) dfs(c, acc);
      });
    }
    acc.removeLast();
  }

  dfs(root, <RenderObject>[]);
  if (chain == null) return <String>['(未在树中找到目标节点)'];

  final List<RenderObject> path = chain!;
  final List<String> out = <String>[];
  bool foundFirst = false;
  bool foundFirstEffective = false;
  for (int i = 0; i < path.length; i++) {
    final RenderObject ro = path[i];
    final String t = ro.runtimeType.toString();
    final String? cb = _readClipBehavior(ro);
    final bool isClip = cb != null;
    final String size;
    if (ro is RenderBox && ro.hasSize) {
      size = '${ro.size.width.toStringAsFixed(0)}x'
          '${ro.size.height.toStringAsFixed(0)}';
    } else {
      size = '-';
    }
    // ★ `approxClip` 一起印进 PATH 行 —— 因为对 **`RenderStack`** 它是个
    //   **有效**的"到底裁没裁"判据：`stack.dart:749` 是
    //   `_hasVisualOverflow ? rect : null`，所以 **null ⟺ 没真裁**。
    //   ⚠️ 对 **`RenderViewport`** 它**不是**（`viewport.dart:886-902` 看的是
    //   child 的 geometry，`Clip.none` 才 null）⇒ 报告里必须分开说。
    final String approx = _approxClipOf(ro);

    // ★ 高亮**第一个**裁剪点 —— 这就是 Lead 要的那个字段。
    String mark = '';
    if (isClip && !foundFirst) {
      foundFirst = true;
      mark = '   <<<<<< ★★★ 第一个裁剪点 ★★★ cb=$cb';
    }
    // ★★ 另给一个**候选**：第一个"**可能真生效**"的裁剪点。
    //   判据（保守，只在能判的类型上判）：
    //     · cb == Clip.none            ⇒ 一定不裁（pushClipRect:579 提前 return）
    //     · RenderStack 且 approx=null ⇒ 一定不裁（_hasVisualOverflow == false）
    //     · 其它                        ⇒ **判不了**，按"可能生效"算并标 `?`
    //   ⇒ 这个候选**不是结论**，是给读者缩小范围用的；报告里标明它的不确定处。
    if (isClip && !foundFirstEffective) {
      final bool defNo = cb == 'Clip.none' ||
          (t == 'RenderStack' && approx == 'null');
      if (!defNo) {
        foundFirstEffective = true;
        final bool unsure = !(t == 'RenderStack');
        mark += '   <<<<<< ◆◆◆ 第一个**可能生效**的裁剪（'
            '${unsure ? "判不了，按可能生效算" : "RenderStack 且 approx≠null ⇒ 真裁"}'
            '）';
      }
    }
    out.add('PATH|i=$i|d=$i|$t|cb=${cb ?? "-"}|size=$size|approx=$approx|'
        'comp=${ro.needsCompositing ? "Y" : "n"}$mark');
  }
  if (!foundFirst) {
    out.add('PATH|NOTE 该路径上**没有任何**裁剪点（cb 全为 "-"）');
  }
  return out;
}

/// 在树里找"最大的 `RenderViewport`"（= 内容区滚动视图）与
/// "屏幕底部那条带里面积最大的节点"（= 底栏）。
///
/// ★ 两个目标都返回 `null` 时**不是错误** —— 报告要照写"没找到"，
///   因为"没找到"与"找到了但没有裁剪"是两件完全不同的事。
class _PathTargets {
  _PathTargets(this.content, this.bar, this.note);
  final RenderObject? content;
  final RenderObject? bar;
  final String note;
}

_PathTargets _findTargets(RenderObject root) {
  final List<RenderObject> viewports = <RenderObject>[];
  final List<RenderObject> boxes = <RenderObject>[];
  int visited = 0;

  void walk(RenderObject ro, int depth) {
    visited++;
    if (depth > 200 || visited > 60000) return;
    final String t = ro.runtimeType.toString();
    if (t == 'RenderViewport' || t == 'RenderShrinkWrappingViewport') {
      viewports.add(ro);
    }
    if (ro is RenderBox && ro.hasSize && ro.size.width > 40 && ro.size.height > 10) {
      boxes.add(ro);
    }
    ro.visitChildren((RenderObject c) => walk(c, depth + 1));
  }

  walk(root, 0);

  // 内容区：面积最大的 viewport。
  RenderObject? content;
  double best = -1;
  for (final RenderObject v in viewports) {
    if (v is RenderBox && v.hasSize) {
      final double a = v.size.width * v.size.height;
      if (a > best) {
        best = a;
        content = v;
      }
    }
  }

  // 底栏：`localToGlobal` 后 top 落在屏幕下 1/4 内、且高度 < 屏幕 1/3 的
  // 最靠下（top 最大）的那个 box。
  RenderObject? bar;
  double barTop = -1;
  // ★★ 屏幕尺寸**不能**用 `root is RenderBox` 取 —— 实测两臂都得到
  //    `screen=unknown`（⇒ 底栏定位整段被跳过 ⇒ `bar=null`）。原因：
  //    `RenderView` **不是** `RenderBox`（`rendering/view.dart:134`：
  //    `class RenderView extends RenderObject with RenderObjectWithChildMixin<RenderBox>`）
  //    ⇒ `root is RenderBox` 判 false。
  //    改用 `RenderView.size`（`view.dart:153` 是**公开** getter）。
  Size? screen;
  if (root is RenderView) {
    screen = root.size;
  } else if (root is RenderBox && root.hasSize) {
    screen = root.size;
  }
  String barNote = 'screen=unknown';
  if (screen != null && screen.width > 0 && screen.height > 0) {
    barNote = 'screen=${screen.width.toStringAsFixed(0)}x'
        '${screen.height.toStringAsFixed(0)}';
    for (final RenderObject b in boxes) {
      final RenderBox rb = b as RenderBox;
      double top;
      try {
        top = rb.localToGlobal(Offset.zero).dy;
      } catch (_) {
        continue;
      }
      final double h = rb.size.height;
      if (top > screen.height * 0.75 && h < screen.height / 3) {
        if (top > barTop) {
          barTop = top;
          bar = rb;
        }
      }
    }
  }

  final String note = '$barNote viewports=${viewports.length} '
      'boxes=${boxes.length} visited=$visited '
      'content=${content?.runtimeType ?? "null"} '
      'bar=${bar?.runtimeType ?? "null"} barTop=${barTop.toStringAsFixed(0)}';
  return _PathTargets(content, bar, note);
}

/// 段 4 的路径清单落盘：内容区一份、底栏一份。
Future<String> _dumpOrderedPaths() async {
  try {
    final views = RendererBinding.instance.renderViews;
    if (views.isEmpty) return 'no-render-view';
    final RenderObject root = views.first;

    final _PathTargets t = _findTargets(root);
    await _append('PATHTARGET|${t.note}');

    final List<String> contentLines = t.content == null
        ? <String>['PATH|NOTE 未找到内容区目标（无 RenderViewport）']
        : _orderedPathTo(root, t.content!);
    final List<String> barLines = t.bar == null
        ? <String>['PATH|NOTE 未找到底栏目标']
        : _orderedPathTo(root, t.bar!);

    await _append('PATHSECTION|CONTENT (从根到内容区，paint 顺序)');
    for (final String s in contentLines) {
      await _append(s);
    }
    await _append('PATHSECTION|BOTTOMBAR (从根到底栏，paint 顺序)');
    for (final String s in barLines) {
      await _append(s);
    }

    // ★ 两条清单的**差集**：第一个裁剪点的类型/cb 是否相同 —— 这就是答案。
    String firstClipOf(List<String> ls) {
      for (final String s in ls) {
        if (s.contains('第一个裁剪点')) {
          final int i = s.indexOf('|cb=');
          final String cb = i < 0 ? '?' : s.substring(i + 4).split('|').first;
          final List<String> seg = s.split('|');
          final String ty = seg.length > 3 ? seg[3] : '?';
          return '$ty/$cb';
        }
      }
      return '(无裁剪点)';
    }

    final String fc = firstClipOf(contentLines);
    final String fb = firstClipOf(barLines);
    await _append('PATHDIFF|content_first=$fc bar_first=$fb '
        'same=${fc == fb ? "YES" : "NO"}');

    return 'content_first=$fc bar_first=$fb same=${fc == fb ? "YES" : "NO"} '
        '${t.note}';
  } catch (e) {
    return 'ERR:$e';
  }
}

/// 批量落盘 —— 全树普查会写几千行，逐行 `_append`（每行一次 fsync）
/// 会慢到影响探针时序。这里一次写完。
Future<void> _appendBatch(List<String> lines) async {
  if (lines.isEmpty) return;
  try {
    final String ts = DateTime.now().toIso8601String();
    final StringBuffer sb = StringBuffer();
    for (final String l in lines) {
      sb.writeln('$ts  $l');
    }
    await File('$_workDir/t421_report.txt').writeAsString(
      sb.toString(),
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {}
}

/// ★★★ 全树普查（Lead 收紧后的第 2、3 问）。
///
/// 回答：
///   ② **有没有哪个节点的 `size` 是 0 或退化？**
///      —— 因为"三个内容不同的状态像素逐字节相同"更像**布局退化**或
///         **子树被完全跳过**，而不是裁剪。
///   ③ **两臂的树 diff 里，除了 clip 还有什么不同？**
///      （`size`、`needsCompositing`、节点数量、`RenderOffstage.offstage`）
///
/// ★ 为什么要**全量**打印而不是只打"可疑的"：
///   若只打可疑的，那么"两臂可疑集合相同"就无法区分
///   「真的没有可疑节点」与「我的可疑判据没覆盖到」——
///   又是「0 分不出『没有』与『没测到』」。
///   全量打印后，两臂的 NODE| 行**可以逐行 diff**，差异自己会浮出来。
///
/// ★ `RenderOffstage.offstage` 是**公开 getter**（`proxy_box.dart:3845`），
///   所以能直接读。产品用 `Offstage(offstage: t != _tab)` 保活 5 个 tab ——
///   若 arm64 上那个布尔算错，内容区会空而底栏正常（与症状吻合）。
///
/// ★ `TickerMode` **没有**对应的 RenderObject（它是个 `InheritedWidget`，
///   `ticker_provider.dart:25`）⇒ 本普查**没有** `TickerMode` 字段可读。
///   这一条如实写进报告，不要假装测过。
Future<String> _dumpNodeCensus() async {
  try {
    final views = RendererBinding.instance.renderViews;
    if (views.isEmpty) return 'no-render-view';
    final RenderObject root = views.first;

    final List<String> lines = <String>[];
    final Map<String, int> typeCount = <String, int>{};
    int visited = 0;
    int skipped = 0;
    int degenerate = 0;
    int offstageTrue = 0;

    void walk(RenderObject ro, int depth) {
      visited++;
      if (depth > 200 || visited > 60000) {
        skipped++;
        return;
      }
      final String t = ro.runtimeType.toString();
      typeCount[t] = (typeCount[t] ?? 0) + 1;

      String size = '-';
      double w = -1, h = -1;
      if (ro is RenderBox && ro.hasSize) {
        w = ro.size.width;
        h = ro.size.height;
        size = '${w.toStringAsFixed(0)}x${h.toStringAsFixed(0)}';
        // ★ 退化判据：宽或高 <= 0。**只算真的零/负**，不算"小" ——
        //   因为"小"是正常的（图标、分隔线），把它算进来会把信号淹掉。
        if (w <= 0 || h <= 0) {
          degenerate++;
          lines.add('DEGEN|d=$depth|$t|size=$size|'
              'comp=${ro.needsCompositing ? "Y" : "n"}');
        }
      }

      // ★ `RenderOffstage.offstage`（公开 getter）。
      String off = '';
      if (t == 'RenderOffstage') {
        try {
          final dynamic d = ro;
          final Object? v = d.offstage;
          off = '|offstage=$v';
          if (v == true) offstageTrue++;
        } catch (_) {
          off = '|offstage=ERR';
        }
      }

      lines.add('NODE|d=$depth|$t|size=$size|'
          'comp=${ro.needsCompositing ? "Y" : "n"}$off');

      ro.visitChildren((RenderObject c) => walk(c, depth + 1));
    }

    walk(root, 0);

    // 汇总行（放最前，便于人眼先看总账）。
    final List<String> keys = typeCount.keys.toList()..sort();
    final StringBuffer census = StringBuffer();
    census.write('CENSUS|nodes=$visited skipped=$skipped '
        'degenerate=$degenerate offstageTrue=$offstageTrue '
        'distinctTypes=${typeCount.length}');
    for (final String k in keys) {
      census.write('|$k=${typeCount[k]}');
    }
    await _append(census.toString());
    await _appendBatch(lines);

    return 'nodes=$visited skipped=$skipped degenerate=$degenerate '
        'offstageTrue=$offstageTrue distinctTypes=${typeCount.length}';
  } catch (e) {
    return 'ERR:$e';
  }
}

/// 进程内读回像素（仪器一）。
///
/// ★ 三个读数点：`px00`（左上）、`pxC`（正中）、`a00`（alpha）。
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

/// ★★ 校准臂（段 1）：合成一棵**已知裁剪层数**的树，用来给走树器做自证。
///
/// 为什么必须有它（Lead 明确要求，理由极硬）：
///   如果 `dynamic` 访问 `clipBehavior` 在 release 下静默失败（被 tree-shake、
///   或字段名变了），两份清单会**都**是空的 ⇒ 两臂 diff 是"完全相同" ⇒
///   报告会得出"层数不是判据"这个**看起来是结论、实际是仪器死了**的读数。
///   这正是本项目「**0 分不出『没有』与『没测到』**」那条教训。
///
/// 所以这一段用一棵**构造出来的**树，它的裁剪层数是**可以手算预测**的：
///
/// ```text
///   RepaintBoundary(_rootKey)          ← repaint boundary ⇒ 这里是 OffsetLayer 根
///     ClipRect(hardEdge)               ← ① ClipRectLayer, hardEdge
///       ClipRect(antiAlias)            ← ② ClipRectLayer, antiAlias
///         ClipRRect(hardEdge)          ← ③ ClipRRectLayer, hardEdge
///           Opacity(0.5)               ← ★★ 必须在**最里面**（见下面那条修正）
///             ColoredBox(纯色)         ← 叶子，保证有东西画
/// ```
///
/// **预测（手算，写死成断言）：**
///   · `ClipRectLayer` 数 = **2**（① hardEdge + ② antiAlias）
///   · `ClipRRectLayer` 数 = **1**（③ hardEdge）
///   · layer 树上从根累积的 hardEdge 链长 = **2**（①→③，②是 antiAlias 不计数）
///   · RO 树上裁剪点数 = **3**（三个 Clip widget）
///
/// ★★ **第一版把 `Opacity` 放在三个 Clip 的【外面】，结果实测 `clipRect=0`**
///    （`CALIB_MISMATCH`，两臂都一样）。**那不是走树器坏了，是我的预测错了。**
///    原因（逐字核过 `rendering/object.dart:3244-3258`）：
///    ```dart
///    void _updateCompositingBits() {
///      _needsCompositing = false;
///      visitChildren((child) {
///        child._updateCompositingBits();
///        if (child.needsCompositing) _needsCompositing = true;   // ← 向上传播
///      });
///      if (isRepaintBoundary || alwaysNeedsCompositing) _needsCompositing = true;
///    }
///    ```
///    ⇒ **`needsCompositing` 是从【后代】向【祖先】传播的**：
///      一个节点需要合成，当且仅当**它的某个后代**需要合成（或它自己是
///      repaint boundary / alwaysNeedsCompositing）。
///    ⇒ 把 `Opacity` 放在**外面**，三个 Clip 自己 `needsCompositing == false`
///      ⇒ `pushClipRect`（`object.dart:584`）走 **canvas 分支**、`return null`
///      ⇒ **一个 ClipRectLayer 都不建** ⇒ 数到 0。**这是正确行为。**
///    ⇒ 所以 `Opacity` 必须放在**所有 Clip 的里面**，才能把三个 Clip 都顶成
///      layer 分支。★ 这一条对**理解产品**也关键：产品树里某个 Clip 会不会
///      建层，取决于**它下面**有没有合成后代，**不是**上面。
///
/// ★ 校准臂的作用：**若这里 MISMATCH ⇒ 后面两臂的裁剪层读数都不可信**
///   （仪器有问题），必须先修仪器再看两臂 diff。判词由报告解释。
Future<void> _calibrationArm(int stage) async {
  runApp(
    RepaintBoundary(
      key: _rootKey,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: ColoredBox(
          color: Color(kStageColors[stage]),
          child: ClipRect(
            clipBehavior: Clip.hardEdge,
            child: ClipRect(
              clipBehavior: Clip.antiAlias,
              child: ClipRRect(
                clipBehavior: Clip.hardEdge,
                borderRadius: BorderRadius.circular(8),
                // ★★ `Opacity` 在**最里面** —— 理由见上面那段修正：
                //    `needsCompositing` 从后代向祖先传播（`object.dart:3244-3258`），
                //    放外面则三个 Clip 自己都是 false ⇒ 全走 canvas ⇒ 数到 0。
                child: const Opacity(
                  opacity: 0.5,
                  child: SizedBox.expand(
                    child: ColoredBox(color: Color(0xFFFFFFFF)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await _settle();

  // ★ 先跑两个走树器（它们会各自 `_append` 明细行），再把**判词**落盘。
  final roDump = await _dumpClipTree();
  final layerDump = await _dumpLayerTree();

  // 从两个走树器最近一次的自报里取数 —— 直接调 `_lastXxx` 快照，
  // 避免去解析自己刚写的文本（解析文本 = 又一个可能说谎的中间层）。
  const int wantRect = 2, wantRRect = 1, wantHard = 2, wantRo = 3;
  final bool ok = _lastLayerClipRect == wantRect &&
      _lastLayerClipRRect == wantRRect &&
      _lastLayerMaxHard == wantHard &&
      _lastRoClipSites == wantRo;

  final String verdict = ok ? 'CALIB_OK' : 'CALIB_MISMATCH';
  // ★ 覆盖率计数一起落盘（Lead 要求）：证明走树器**确实走完了整棵树**。
  _log('STAGE $stage (${kStageNames[stage]}) $verdict '
      'want(rect=$wantRect,rrect=$wantRRect,hard=$wantHard,ro=$wantRo) '
      'got(rect=$_lastLayerClipRect,rrect=$_lastLayerClipRRect,'
      'hard=$_lastLayerMaxHard,ro=$_lastRoClipSites) '
      'cov(roVisited=$_lastRoVisited roSkipped=$_lastRoSkipped '
      'layerVisited=$_lastLayerVisited layerSkipped=$_lastLayerSkipped) '
      '| RO $roDump | LAYER $layerDump');
  await _append('STAGE $stage (${kStageNames[stage]}) $verdict '
      'want(rect=$wantRect,rrect=$wantRRect,hard=$wantHard,ro=$wantRo) '
      'got(rect=$_lastLayerClipRect,rrect=$_lastLayerClipRRect,'
      'hard=$_lastLayerMaxHard,ro=$_lastRoClipSites) '
      'cov(roVisited=$_lastRoVisited roSkipped=$_lastRoSkipped '
      'layerVisited=$_lastLayerVisited layerSkipped=$_lastLayerSkipped)');
  await _append('STAGE $stage WHAT ${kStageWhat[stage]}');

  final read = await _inProc();
  await _append('STAGE $stage INPROC $read');

  await _writeStage(stage);
  _log('STAGE $stage HOLD-BEGIN');
  await Future<void>.delayed(kHold);
  _log('STAGE $stage HOLD-END');
}

/// 两个走树器最近一次的自报数（供校准臂比对；**不解析文本**）。
int _lastLayerClipRect = -1;
int _lastLayerClipRRect = -1;
int _lastLayerMaxHard = -1;
int _lastRoClipSites = -1;

/// 走树器的**覆盖率**计数（Lead 要求）：证明"走完了整棵树"，
/// 而不是在某处静默停下 —— 后者会给出"裁剪点很少"的假读数。
int _lastRoVisited = -1;
int _lastRoSkipped = -1;
int _lastLayerVisited = -1;
int _lastLayerSkipped = -1;

/// ★★ 段 2：裸 `MaterialApp` —— 直接回答 add-remote-order 的模型简并。
///
/// 他的问题（原话）：他的 14 段全在 `MaterialApp` 里，而
/// 「`MaterialApp` 自带那个 `Overlay` 算不算一层 hardEdge」有两种模型，
/// **在他的 14 段上完全简并**（两种模型对每一段的预测都一样）：
///   · 模型 A：`MaterialApp` 的 `Overlay` 是 `Clip.none`（不裁）⇒ 阈值 ≥1 层
///   · 模型 B：它是 `hardEdge`                                  ⇒ 阈值 ≥2 层
///
/// ⇒ 本段把 `MaterialApp` 单独跑起来、`home` 只放一个**纯色**
///   `ColoredBox`（零显式裁剪），然后数 layer 树里的 `ClipRectLayer`：
///   · 数到 **0** 个 ⇒ 模型 A 成立（`MaterialApp` 不自带硬边裁剪层）
///   · 数到 **≥1** 个 ⇒ 模型 B 成立
///
/// ★ 这是"读数"不是"读代码"：`widgets\app.dart:1696` 读起来像 A
///   （`WidgetsApp` 给 `Navigator` 传 `clipBehavior: Clip.none`），
///   但读代码两边都能自圆其说 ⇒ 必须量。
///
/// ★ 注意本段与校准臂的**区别**：校准臂是我**自己构造**的树（预测值手算），
///   本段是**框架自己**搭的树（预测值未知，正是要量的那个）。
///   两段一起给出"仪器准不准"与"框架贡献几层"两个独立读数。
Future<void> _bareMaterialAppArm(int stage) async {
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: ColoredBox(color: Color(0xFF2E5C8C)),
    ),
  );
  await _settle();

  final roDump = await _dumpClipTree();
  final layerDump = await _dumpLayerTree();

  _log('STAGE $stage (${kStageNames[stage]}) BARE '
      'clipRect=$_lastLayerClipRect clipRRect=$_lastLayerClipRRect '
      'maxHard=$_lastLayerMaxHard roSites=$_lastRoClipSites '
      'cov(roVisited=$_lastRoVisited roSkipped=$_lastRoSkipped '
      'layerVisited=$_lastLayerVisited layerSkipped=$_lastLayerSkipped) '
      '| RO $roDump | LAYER $layerDump');
  await _append('STAGE $stage (${kStageNames[stage]}) BARE '
      'clipRect=$_lastLayerClipRect clipRRect=$_lastLayerClipRRect '
      'maxHard=$_lastLayerMaxHard roSites=$_lastRoClipSites '
      'cov(roVisited=$_lastRoVisited roSkipped=$_lastRoSkipped '
      'layerVisited=$_lastLayerVisited layerSkipped=$_lastLayerSkipped)');
  await _append('STAGE $stage WHAT ${kStageWhat[stage]}');

  final read = await _inProcRoot();
  await _append('STAGE $stage INPROC $read');

  await _writeStage(stage);
  _log('STAGE $stage HOLD-BEGIN');
  await Future<void>.delayed(kHold);
  _log('STAGE $stage HOLD-END');
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

/// 给产品段用的读数 + 停留：**不 runApp**，只读 + 落段号 + 停。
Future<void> _holdStage(int stage, String what) async {
  await _settle();
  final read = await _inProcRoot();
  final eng = await _engineState();
  _log('STAGE $stage (${kStageNames[stage]}) INPROC $read | $eng  [$what]');
  await _append('STAGE $stage (${kStageNames[stage]}) INPROC $read | $eng  [$what]');
  await _append('STAGE $stage WHAT $what');

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

  await _append('================ t436 start ================');
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

  // ── 段 0：阳性对照。若它都不上屏，后面所有黑都不可解释。 ──────
  await _canary(0);

  // ── ★★ 段 1：校准臂（走树器的自证）────────────────────────────
  // ★ 为什么放在产品之前：后面所有"裁剪层数"的读数都依赖走树器活着。
  //   先证明它能在一棵**已知层数**的树上数对，再看产品那棵树。
  //   若这里 MISMATCH ⇒ 两臂的裁剪层读数**都不可信**，先修仪器。
  await _calibrationArm(1);

  // ── ★★ 段 2：裸 MaterialApp（打破 add-remote-order 的模型简并）──
  await _bareMaterialAppArm(2);

  // ── 段 3：★ 产品本体（复现锚点）────────────────────────────────
  // ★ 为什么必须有这一段：本探针的**全部**意义是"把产品包的黑屏归因到
  //   某一层裁剪"。如果这一跑里产品本身**不黑**，那么段 4 量到的树就
  //   不能代表"坏的那棵树" —— 那时本报告只能写"未复现"，
  //   **不能**写"层数不是原因"。与 t429 段 7 逐字相同的调用。
  _log('CALL runApp(SourinApp) begin');
  await _append('CALL runApp(SourinApp) begin');
  runApp(SourinApp(coreError: null, coreDataDir: _preDataDir));
  _log('CALL runApp(SourinApp) done');

  await _settle();
  // ★ 段 3 不能包 RepaintBoundary（要逐字复刻产品）⇒ 走 RenderView 那条读数路
  //   （`_holdStage` 内部用的就是 `_inProcRoot()`）。
  await _holdStage(3, kStageWhat[3]);

  // ── ★★ 段 3b：等 getHome 完成，内容区稳定 ─────────────────────
  // ★ 为什么单独等：t427 实测 getHome 8ms(arm64)/311ms(x64)，但内容区
  //   真正稳定还要等骨架→内容的切换。树遍历必须在**稳定之后**做，
  //   否则量到的是骨架屏的树，与"内容区空白"那个现象对不上。
  //   ★ 这一段**不写段号**（不占驱动的段），只是等待。
  _log('SETTLE begin ${kSettleForHome.inSeconds}s');
  await _append('SETTLE begin ${kSettleForHome.inSeconds}s');
  await Future<void>.delayed(kSettleForHome);
  _log('SETTLE end');

  // ── 段 4：★★ 树遍历（本探针的主体）────────────────────────────
  // ★ 三件读数一次做完：
  //   ① `_dumpClipTree()`  —— RO 树：有几处**打算**裁（含被挡住的）
  //   ② `_dumpLayerTree()` —— layer 树：**真的**裁了几次（t434 §4① 的决定性仪器）
  //   ③ 像素读数（`_holdStage` 内部）—— 这时内容区到底画没画
  //   两份树读数的差 = "意图 vs 事实"，报告里做差集。
  final dump = await _dumpClipTree();
  final layerDump = await _dumpLayerTree();
  final e4 = await _engineState();
  _log('STAGE 4 (${kStageNames[4]}) DUMP $dump | LAYER $layerDump | $e4');
  await _append('STAGE 4 (${kStageNames[4]}) DUMP $dump | $e4');
  await _append('STAGE 4 (${kStageNames[4]}) LAYER $layerDump');

  // ── ★★★ 有序路径清单（Lead 收紧后的核心产出）──────────────────
  // 从根到**内容区**、从根到**底栏**，各打一份有序清单，
  // 高亮各自的**第一个裁剪点**。两条清单的差集就是答案。
  await _dumpOrderedPaths();

  // ── ★★★ 全树普查（Lead 第 2、3 问：退化 size / Offstage / 节点差异）──
  final census = await _dumpNodeCensus();
  _log('STAGE 4 (${kStageNames[4]}) CENSUS $census');
  await _append('STAGE 4 (${kStageNames[4]}) CENSUS $census');
  await _holdStage(4, kStageWhat[4]);

  // ── 段 5：产品读数（这时内容区到底画没画）─────────────────────
  await _holdStage(5, kStageWhat[5]);

  // ── 段 6：恢复 canary（证明整跑结束时进程仍活）────────────────
  await _canary(6);

  _log('DONE');
  await _append('================ t436 done ================');
  exit(0);
}

String _preDataDir = '';

/// 进程内读数（**不需要** `_rootKey` 的版本）—— 给产品段用。
///
/// ★ 产品段必须**逐字复刻**产品（`runApp(SourinApp(...))`），不能再包一层
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
    //      而它看起来和「真的没有 layer」一模一样。
    //
    //   ② `layer` 标了 `@protected`，跨类调用会被 analyze 判
    //      `invalid_use_of_protected_member`。这是**静态 lint**，不是运行时
    //      限制：getter 体就是 `return _layerHandle.layer;`，在 release 里
    //      照常工作。本探针**不是** `RenderObject` 的子类，所以只能显式忽略。
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
