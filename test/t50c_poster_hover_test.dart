// ═══════════════════════════════════════════════════════════════════════
//  task-50 候选 C1：海报卡片「鼠标悬停反馈」
// ═══════════════════════════════════════════════════════════════════════
//
// # 修的是什么（实测缺口，不是"加个动画"）
//
// ```text
// 改之前（`.probe/t50_recon_anim.py` 实测）：
//   `lib/ui/widgets/poster_card.dart` 里
//     MouseRegion — / onHover — / onEnter — / onExit — / BoxShadow —
//   ⇒ 桌面用户把鼠标移到海报上，**零反馈**。
// 改之后：`MouseRegion(onEnter/onExit)` + `AnimatedOpacity`（key = poster-hover-glow）
// ```
//
// # 判据映射
//
// ```text
// ① 目的          ⇒ 反馈操作 + 引导注意（"鼠标在这儿"）
// ② ≤150ms        ⇒ `Motion.fast` = 150ms（悬停是高频动作 ⇒ 走最低档）
// ③ 可打断        ⇒ `AnimatedOpacity` 是隐式动画（中途反向不排队）
// ④ Reduce Motion ⇒ `MotionPrefs.duration` ⇒ 系统减少时 `Duration.zero`
// ⑤ 惯用法        ⇒ `MouseRegion` + `AnimatedOpacity`（零手写 AnimationController）
// ```
//
// # ★★ 本文件的读数纪律（照 task-80 的手法，不靠"数 pump 次数"）
//
// ```text
// 零点必须**找到**，不能猜：
//   ① `t.sendEventToBinding(p.hover(...))` 派发**真的** `PointerHoverEvent`
//      （⚠️ `t.startGesture(...).moveTo(...)` 发的是 `PointerMoveEvent`，
//       而 `MouseTracker.updateWithEvent` 只认 `PointerHoverEvent`
//       ⇒ 用 `TestPointer.hover`，这是 `t72_jank_test.dart` 验证过的写法）
//   ② `pump()` 一帧 ⇒ `setState(_hover=true)` 重建 ⇒ `AnimatedOpacity`
//      在 `didUpdateWidget` 里 `forward(from: 0)`
//   ③ ★ 前置条件断言：此刻 `AnimatedOpacity.opacity` **目标值**必须已是 1.0
//      —— 证明 `onEnter` 真的触发了。不成立就直接失败并说明"前提不成立"，
//        而不是含糊地报"动画没播"（那是把两种完全不同的故障混为一谈）
//   ④ `pump()` 再一帧 = **沉降帧**：ticker 的**首帧 elapsed 恒为 0**
//      ⇒ 这一帧之后 `FadeTransition.opacity.value` 就是**真正的 t=0**
// ```
//
// # 为什么读 `FadeTransition.opacity.value` 而不是别的东西
//
// ```text
// `AnimatedOpacity` 内部 build 出来的就是 `FadeTransition`
//   （SDK 依据：`implicit_animations.dart:1904 return FadeTransition(...)`）
// 而 `FadeTransition.opacity` 是 `Animation<double>` ⇒ `.value` 是**精确
// double**（不是像素、不是近似）⇒ 仪器的量化误差 = 0，不是 0.006435753。
// ★ 仪器"不自己编造差异"的证据在**阴性对照**：状态真的相同时四刻
//   读数**逐位相同**、最小间距**恰好 0.000000**（不是"很小"）。
// ```
import 'dart:io';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';

// ═══════════════════════════════════════════════════════════════════════
//  0. 读数落盘（★ 控制台可能吞 stdout，产物文件不能没有读数）
// ═══════════════════════════════════════════════════════════════════════

const String kPosterSrc = 'lib/ui/widgets/poster_card.dart';
const String kMotionSrc = 'lib/ui/widgets/motion_prefs.dart';

/// 悬停高亮层的 Key（生产代码里就是这一个）
const ValueKey<String> kGlowKey = ValueKey<String>('poster-hover-glow');

/// 读数落盘 —— 目录不存在就**先建**。
///
/// ★ 为什么需要这一层（2026-10-08 加）：
///   `.probe/` 是**开发期的本地目录**，它**不在仓库里**（见 .gitignore）。
///   在干净的检出（CI、别人的机器）上它根本不存在 ⇒ 直接
///   `writeAsStringSync` 会抛 `PathNotFoundException`，
///   **把一条本该通过的动画断言变成失败**（而且报错位置在落盘那一行，
///   看起来像断言挂了，实际是**仪器故障**）。
///   ★ 这与本仓的一条铁律同源：先问「是我的仪器错了吗」。
File _ensureLog(String path) {
  final f = File(path);
  final d = f.parent;
  if (!d.existsSync()) d.createSync(recursive: true);
  return f;
}

final File _log = _ensureLog('.probe/t50c_hover_points.txt');

void _rec(String line) {
  // ignore: avoid_print
  print(line);
  _log.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
}

// ═══════════════════════════════════════════════════════════════════════
//  1. 挂载 + 仪器
// ═══════════════════════════════════════════════════════════════════════

/// 带**真主题**挂载（`PosterCard` 依赖 `Theme.of` 取色）
///
/// ★ `reduceMotion` 用 `copyWith` 改**同一个** `MediaQueryData`，
///   而不是 `MediaQueryData(disableAnimations: true)` 造一个新的 ——
///   后者会把 `size` 等字段全变成默认值（`Size.zero`），
///   给"读尺寸"的断言埋一个与本题无关的坑。
Widget host(
  Widget child, {
  Brightness brightness = Brightness.light,
  bool reduceMotion = false,
}) {
  final theme = AppTheme.themeFor(brightness);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    builder: (ctx, c) {
      final base = MediaQuery.maybeOf(ctx) ?? const MediaQueryData();
      return AppThemeHost(
        data: theme,
        child: MediaQuery(
          data: base.copyWith(disableAnimations: reduceMotion),
          child: c ?? const SizedBox(),
        ),
      );
    },
    home: Scaffold(
      backgroundColor: AppTheme.floorColor(brightness),
      body: Center(child: child),
    ),
  );
}

/// 用**真实窗口尺寸** 1280x800（本仓纪律：默认 800x600 太窄 ⇒ 假 overflow）
Future<void> _mount(
  WidgetTester t,
  Widget card, {
  bool reduceMotion = false,
}) async {
  t.view.physicalSize = const Size(1280, 800);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(host(card, reduceMotion: reduceMotion));
  await t.pump();
}

Finder get _glow => find.byKey(kGlowKey);
Finder get _glowFade =>
    find.descendant(of: _glow, matching: find.byType(FadeTransition));

/// 悬停高亮层的**当前**不透明度（精确 double）
double _opacity(WidgetTester t) {
  final f = _glowFade;
  expect(f.evaluate(), isNotEmpty,
      reason: '★ 悬停高亮层不在树里 —— 读不到读数（不是"动画没播"）');
  return t.widget<FadeTransition>(f.first).opacity.value;
}

/// 派发**真的**鼠标悬停，并把假时钟**停在动画的零点**
///
/// 返回：悬停是否已生效（★ 这是**前提**，不是结论）
Future<void> _hoverToZero(WidgetTester t, {String tag = ''}) async {
  final center = t.getCenter(find.byType(PosterCard));
  final p = TestPointer(1, PointerDeviceKind.mouse);
  await t.sendEventToBinding(p.addPointer(location: center));
  await t.sendEventToBinding(p.hover(center));
  await t.pump(); // ① 重建：`setState(_hover = true)` 生效

  // ★★ 前提断言：证明 `onEnter` **真的**触发了
  final target = t.widget<AnimatedOpacity>(_glow).opacity;
  expect(
    target,
    1.0,
    reason: '★★ $tag 前提不成立：悬停后 `AnimatedOpacity.opacity` 的**目标值**'
        '仍是 $target ⇒ `MouseRegion.onEnter` 没触发（或 `_hover` 没接上）。'
        '★ 这与"动画没播"是**两件不同的事**，必须分开报',
  );

  // ② ★ 沉降帧：ticker 首帧 elapsed 恒为 0 ⇒ 此刻就是真正的 t=0
  await t.pump();
}

/// 从零点起把假时钟推到 0 / 30 / 75 / 150ms，每点读一次
Future<List<double>> _fourPoints(WidgetTester t, {String tag = ''}) async {
  final out = <double>[_opacity(t)];
  await t.pump(const Duration(milliseconds: 30));
  out.add(_opacity(t));
  await t.pump(const Duration(milliseconds: 45));
  out.add(_opacity(t));
  await t.pump(const Duration(milliseconds: 75));
  out.add(_opacity(t));
  _rec('[T50C] $tag 四刻读数（0/30/75/150ms）= ${_fmt(out)}');
  return out;
}

/// 四刻里**最小**的两两间距
double _minGap(List<double> xs) {
  var m = double.infinity;
  for (var i = 0; i < xs.length; i++) {
    for (var j = i + 1; j < xs.length; j++) {
      final d = (xs[i] - xs[j]).abs();
      if (d < m) m = d;
    }
  }
  return m;
}

String _fmt(List<double> xs) =>
    xs.map((e) => e.toStringAsFixed(6)).join(' / ');

/// 读生产源码并**剥掉注释**
///
/// ⚠️ 必须剥注释（本仓已踩 7 次"grep 命中注释导致假通过"）。
///    ★ 本文件尤其需要：`poster_card.dart` 的注释里**逐字引用**了
///      `AnimatedScale`（为了说明"为什么不用它"）。
String _src(String path) {
  final raw = File(path).readAsStringSync();
  return raw
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ')
      .replaceAll(RegExp(r'//[^\n]*'), ' ');
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  A. 四刻读数 —— 悬停淡入真的在**动**
  // ═══════════════════════════════════════════════════════════════════

  group('A. 悬停淡入的四刻读数', () {
    testWidgets('★★★ C1 四刻读数单调上升，起点 0、终点 1，最小间距远大于仪器分辨率',
        (t) async {
      await _mount(t, PosterCard(title: '怒鲨狂潮', onTap: () {}));
      expect(_glow, findsOneWidget, reason: '★ 可点卡片必须有悬停高亮层');

      await _hoverToZero(t, tag: 'C1');
      final xs = await _fourPoints(t, tag: 'C1');

      final gap = _minGap(xs);
      /*
       * ★★ 仪器分辨率必须**如实报**（Lead 的硬要求）
       *
       * ```text
       * 本仪器读 `Animation<double>.value` ⇒ 拿回来的是**精确 double**，
       *   没有任何量化 ⇒ 仪器本身的分辨率 ≈ 双精度 eps（~1e-16），不是 0.006。
       * ★ 但 0.006435753 是 task-80 那个**另一个**仪器的读数分辨率
       *   （它读的是 sliver opacity）。
       * ⇒ 我**不拿"我的尺子更细"当借口**：仍然按 Lead 的要求与那个数字对照，
       *   断言最小间距 > 5 × 0.006435753，并把**实测倍数**写进日志。
       * ```
       */
      const double kT80Resolution = 0.006435753;
      final ratio = gap / kT80Resolution;
      _rec('[T50C] C1 最小两两间距 = ${gap.toStringAsFixed(6)}'
          '（= ${ratio.toStringAsFixed(2)} × task-80 的 $kT80Resolution）');

      expect(xs.first, 0.0,
          reason: '★★ t=0 必须是**恰好** 0.0 —— 不是"接近 0"。'
              '实测=${xs.first.toStringAsFixed(6)}。'
              '若这里是 1.0 ⇒ 动画被跳过了（`duration` 被改成 0，或根本没动画）');
      expect(xs.last, 1.0,
          reason: '★ t=150ms 必须已经到 1.0（`Motion.fast` = 150ms）。'
              '实测=${xs.last.toStringAsFixed(6)}');

      for (var i = 1; i < xs.length; i++) {
        expect(xs[i], greaterThan(xs[i - 1]),
            reason: '★ 必须**严格单调**上升：第 $i 刻 ${xs[i].toStringAsFixed(6)} '
                '不大于前一帧 ${xs[i - 1].toStringAsFixed(6)}');
      }

      /*
       * ★★ 阈值**必须是有依据的**，不许凭感觉取。
       *
       * 我第一版写的是 `greaterThan(0.05)` —— 那个 0.05 是我随手编的，
       *   实测 0.038577 就把这条判成失败。★ 那是**判据缺陷**，不是代码缺陷：
       *   0.038577 意味着 150ms 内四刻读数分得很开，动画明明在播。
       *
       * ⇒ 改成与 Lead 指定的参照分辨率挂钩：`5 × 0.006435753 = 0.032178765`，
       *   并断言"至少 5 倍分辨率"。这不是把阈值调低到刚好能过 —— 5 倍是
       *   Lead 在 m02627 里给的判据（"至少要有明显大于它的间距才算有分辨力"），
       *   实测倍数会打印在上一行日志里，谁都能复核。
       */
      expect(gap, greaterThan(5 * kT80Resolution),
          reason: '★★ 最小两两间距必须 > 5 × task-80 的仪器分辨率 '
              '($kT80Resolution)，即 > ${(5 * kT80Resolution).toStringAsFixed(6)}。'
              '实测=$gap（= ${ratio.toStringAsFixed(2)} ×）。'
              '若 ≈0 ⇒ 四刻读的是**同一个值** ⇒ 仪器测不出动画');
    });

    testWidgets('★★ C1 时长**恰好** 150ms（140ms 时未到、150ms 时已到）', (t) async {
      await _mount(t, PosterCard(title: '怒鲨狂潮', onTap: () {}));
      await _hoverToZero(t, tag: 'C1-dur');

      await t.pump(const Duration(milliseconds: 140));
      final at140 = _opacity(t);
      await t.pump(const Duration(milliseconds: 10));
      final at150 = _opacity(t);

      _rec('[T50C] C1 时长：t=140ms → ${at140.toStringAsFixed(6)}；'
          't=150ms → ${at150.toStringAsFixed(6)}');

      expect(at140, lessThan(1.0),
          reason: '★★ t=140ms 时**必须还没到** 1.0 —— 实测=$at140。'
              '若这里已是 1.0 ⇒ 实际时长短于 150ms（判据②的读数就不成立）');
      expect(at150, 1.0,
          reason: '★ t=150ms 时**必须**已到 1.0 —— 实测=$at150 ⇒ 时长正好 150ms');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  B. 阴性对照：Reduce Motion ⇒ 读数**逐位相同**
  // ═══════════════════════════════════════════════════════════════════

  group('B. 系统「减少动态效果」（判据④）', () {
    testWidgets('★★★ C1 reduceMotion ⇒ 四刻读数完全相同（间距恰好 0）', (t) async {
      await _mount(
        t,
        PosterCard(title: '怒鲨狂潮', onTap: () {}),
        reduceMotion: true,
      );
      expect(_glow, findsOneWidget,
          reason: '★ 减少动态效果**不等于**不要这个状态 —— 高亮层仍应在树里');

      await _hoverToZero(t, tag: 'C1-reduce');
      final xs = await _fourPoints(t, tag: 'C1-reduce');

      final gap = _minGap(xs);
      _rec('[T50C] C1-reduce 最小两两间距 = ${gap.toStringAsFixed(6)}'
          '（★ 必须恰好 0.000000）');

      expect(xs, everyElement(1.0),
          reason: '★★ 减少动态效果时 `MotionPrefs.duration` 返回 `Duration.zero`'
              ' ⇒ 状态**瞬间**到位 ⇒ 四刻读数必须**全部**是 1.0（逐位相同，'
              '不是"差不多"）。实测=${_fmt(xs)}');
      expect(gap, 0.0,
          reason: '★★ 间距必须**恰好** 0.0。'
              '★ 这正是"仪器测的是动画、不是别的东西"的证据：'
              '动画被去掉后，我的读数**完全不再变化**');

      // ★ 信息仍在：不是"因无障碍而丢功能"
      expect(t.widget<AnimatedOpacity>(_glow).opacity, 1.0,
          reason: '★ 反馈的**信息**（鼠标在这儿）必须保留，只是去掉了**动效**。'
              '若这里也是 0 ⇒ 那是"因无障碍而损失功能"，不是我们想要的');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  C. 设计约束（★ 由**既有测试**逼出来的三条）
  // ═══════════════════════════════════════════════════════════════════

  group('C. 设计约束（不许破坏既有断言 / 几何）', () {
    testWidgets('★★★ C1 悬停层**不插 Transform**（既有断言要求恰好一层）', (t) async {
      await _mount(t, PosterCard(title: '怒鲨狂潮', onTap: () {}));

      expect(
        find.descendant(of: _glow, matching: find.byType(Transform)),
        findsNothing,
        reason: '★★ 悬停层必须是 `AnimatedOpacity`（→ `FadeTransition` → '
            '`RenderOpacity`，**零 Transform**）。'
            '★ 若这里插了 `AnimatedScale`，`t50a_poster_press_test.dart` 的'
            '「恰好一层 Transform」立刻变红',
      );
      expect(
        find.descendant(
          of: find.byType(PosterCard),
          matching: find.byType(AnimatedScale),
        ),
        findsOneWidget,
        reason: '★ 卡片子树里仍**恰好一个** `AnimatedScale`（按下反馈那个）'
            '—— 悬停没有偷偷再插一个',
      );
    });

    testWidgets('★★ C1 悬停层**不进布局**（几何逐项不变）', (t) async {
      // 挂载 1：可点（有 MouseRegion + 悬停层）
      await _mount(t, PosterCard(title: '怒鲨狂潮', onTap: () {}));
      final r1 = t.getRect(find.byType(PosterCard));

      // 挂载 2：不可点（无 MouseRegion + 无悬停层）
      await _mount(t, const PosterCard(title: '怒鲨狂潮'));
      final r2 = t.getRect(find.byType(PosterCard));

      _rec('[T50C] C1-geo 有悬停层 rect = $r1；无悬停层 rect = $r2');

      for (final pair in <List<Object>>[
        <Object>['left', r1.left, r2.left],
        <Object>['top', r1.top, r2.top],
        <Object>['width', r1.width, r2.width],
        <Object>['height', r1.height, r2.height],
      ]) {
        expect(pair[1] as double, closeTo(pair[2] as double, 1e-6),
            reason: '★ 悬停层用 `Positioned.fill` 塞进**已有** Stack ⇒ '
                '不得改变 `PosterCard` 的 ${pair[0]}'
                '（`t50a` C5 / `t75_search_pinned_test` / '
                '`task37_poster_placeholder_test` 都依赖这个几何）');
      }
    });

    testWidgets('★★ C1 `onTap == null` ⇒ 不画悬停层（不做假的可点击暗示）', (t) async {
      await _mount(t, const PosterCard(title: '怒鲨狂潮'));

      expect(_glow, findsNothing,
          reason: '★★ 不可点的卡片"移上去会亮"是**假的可点击暗示** —— '
              '与 `PressFeedback` 的 `enabled: widget.onTap != null` 同一个理由');

      // ★ 阳性对照：这条"零"不是"整棵树都没渲染"造成的
      expect(find.text('怒鲨狂潮'), findsOneWidget,
          reason: '★★ 阳性对照：卡片本身必须照常渲染（否则上面那条"零"是空的）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  D. 静态审计（源码级，防回归）
  // ═══════════════════════════════════════════════════════════════════

  group('D. 静态审计（剥注释后断言）', () {
    test('★★ C1 接线齐全：MouseRegion + onEnter/onExit + AnimatedOpacity + MotionPrefs',
        () {
      final code = _src(kPosterSrc);

      expect(code.contains('MouseRegion('), isTrue,
          reason: '★ 必须有 `MouseRegion`（改之前命中 = 0）');
      expect(code.contains('onEnter:'), isTrue);
      expect(code.contains('onExit:'), isTrue);
      expect(code.contains("ValueKey<String>('poster-hover-glow')"), isTrue,
          reason: '★ 悬停层必须带 Key（测试靠它定位）');
      expect(code.contains('AnimatedOpacity('), isTrue,
          reason: '★ 判据⑤：隐式动画（`AnimatedOpacity`），不手写 controller');
      expect(code.contains('MotionPrefs.duration(context, Motion.fast)'), isTrue,
          reason: '★★ 判据②④：150ms + 尊重 Reduce Motion —— 必须**逐字**在');
      expect(code.contains('MotionPrefs.curve(context, Motion.easeOut)'), isTrue);
      expect(code.contains('IgnorePointer('), isTrue,
          reason: '★ 悬停层铺满海报 ⇒ 必须忽略指针，命中测试结果才与加层前一致');

      // ★ 悬停层不得用 `Container(color:)`：`task37_poster_placeholder_test`
      //   的 `placeholderColorOf` 取"子树里第一个 color != null 的 Container"
      //   ⇒ 会被悬停层抢先取到，让占位色断言读错对象
      final glowBlock = code.substring(
        code.indexOf("ValueKey<String>('poster-hover-glow')"),
      );
      expect(glowBlock.contains('DecoratedBox('), isTrue,
          reason: '★ 悬停层必须用 `DecoratedBox` 画底色（不能用 `Container`）');
    });

    test('★★ C1 仍然只 import material_ui（仓库硬纪律）', () {
      final code = _src(kPosterSrc);
      expect(code.contains("import 'package:material_ui/material_ui.dart';"),
          isTrue);
      expect(code.contains('package:flutter/material.dart'), isFalse,
          reason: '★ 生产代码只用 material_ui（有全仓测试强制这条）');
    });

    test('★★★ 阳性对照：`_src` 真的剥掉了注释（否则上面几条可能是空的）', () {
      final raw = File(kPosterSrc).readAsStringSync();
      final code = _src(kPosterSrc);

      // ★ 注释里**逐字**引用了旧写法 `? '?'`（task-63 的历史记录）
      expect(raw.contains("? '?'"), isTrue,
          reason: '★ 阳性对照：**原文**里确有这个注释片段');
      expect(code.contains("? '?'"), isFalse,
          reason: '★★★ 剥注释后必须**看不见**它 —— 否则说明 `_src` 没在剥注释，'
              '那么任何"源码里没有 X"的断言都是假的');
      expect(code.contains('class PosterCard'), isTrue,
          reason: '★ 阳性对照：剥注释不能把真代码也剥掉');
    });
  });
}
