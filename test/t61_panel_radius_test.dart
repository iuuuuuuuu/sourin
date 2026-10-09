// ═══════════════════════════════════════════════════════════════════════
//  详情面板的圆角（Owner：「播放详情页右边也应该圆角，直角看起来不协调」）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
//
// > 播放详情页右边也应该圆角，直角看起来不协调
//
// # 逐像素实测（Owner 截图 1280×800）
//
// ```text
// 面板占 x[896,1279] y[40,799]
// 左上 ★ 直角（每行都是 896）   右上 ★ 直角（每行都是 1279）
// 左下 ★ 直角（每行都是 896）   右下   圆角（那是**窗口自己**的裁剪）
// ⇒ 三个直角 + 一个圆角 = 「不协调」
// ```
//
// # ★ 本文件最重要的一条：只加 `ClipRRect` **不够**
//
// ```text
// 面板后面是 `Scaffold.backgroundColor`，窗口态 = surface（#eef0f6）
// ⇒ 切掉的那块露出的**还是同色 surface**
// ⇒ ★ 像素上**什么都不会变** —— 代码里有圆角，用户看不见
// ```
// ⇒ 必须**同时**铺黑底。所以本文件有两条**成对**的断言：
// ```text
// ① 有圆角（ClipRRect + 正确的 BorderRadius）
// ② 圆角后面是**黑的**（紧邻视频那一侧）
// ```
// ★ 缺任何一条，这条修复都是**无效**的 —— 而"只做①"是最容易犯的错。
//
// ═══════════════════════════════════════════════════════════════════════
// ★★★ 2026-09-27 task-68：Owner 报「浅色模式下右上角有漏出的黑色」
// ═══════════════════════════════════════════════════════════════════════
//
// # 上一轮的断言**不够** —— 它只查"树里有没有一块黑"
//
// 上一版 ② 写的是：
// ```dart
// final black = boxes.where((b) => d is BoxDecoration && d.color == Colors.black);
// expect(black, isNotEmpty);
// ```
// ⇒ 那只能证明"**某处**有黑底"，**证明不了它在哪**。
// 于是"整块面板都铺黑"也能通过 —— 而那正是 task-68 的 bug：
// ```text
// 逐像素实测（Owner 截图 1280×800）
//   黑色区 x[1263..1279] y[40..55]  ← 16×16 的黑色四分之一圆
//   标题栏 (600,20) = #E7EAF2       ← ★ 浅色（合并页的标题栏不是黑的！）
// ⇒ 右上角切掉的那块露出黑底，而它的邻居是浅色标题栏
// ⇒ 用户看到的就是"漏出来的一块黑"
// ```
//
// # 根因：黑底的理由只在**播放页**成立
//
// 上一轮铺整块黑的理由是「面板左/上侧紧邻的正是黑色（播放器 + 标题栏）」。
// ✗ 其中「标题栏是黑的」**只对播放页成立**（`titleBarDark` 只在
//   `player_page.dart` 设）—— 合并页的标题栏是**浅色液态玻璃**。
//
// # ⇒ 断言必须**几何化**（本仓铁律⑲：断言结构，不要断言符号存在）
//
// ```text
// 黑底必须**邻接视频那一侧**的圆角（否则圆角隐形）
// 黑底**不得**侵入标题栏那一侧的圆角（否则漏黑）
// ```
// ★ 所以下面两条**成对**的几何断言：
// ```text
// ③ 视频侧的角（宽档=左上 / 窄档=右上）背后**必须**有黑
// ④ 标题栏侧的角（宽档=右上）背后**必须没有**黑
// ```
// ⚠️ 且必须带**阳性对照**：若树里一块黑都没有，
//    ④ 会**空真**通过（"找不到黑" ≠ "那里没黑"）。
//
// ⚠️ 本文件用**真 widget 树**验证（不是只读源码）：
//    `pumpWidget` 一个真的 `MediaPage`，然后读它渲染出来的
//    `ClipRRect` / `ColoredBox` 的**实际几何**。
//    源码文本断言只作为补充（本仓铁律：静态断言容易被注释/影子副本骗过）。
import 'dart:io';

import 'package:flutter/rendering.dart' show RenderClipRRect;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/ui/theme_bridge.dart';
import 'package:sourin_spike/ui/media_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 'package:sourin_spike/ui/tokens.dart';

/// 挂一个真的 `MediaPage` 并返回渲染树
///
/// ⚠️ 必须让 `MediaKit` 就绪 —— `MediaPage` 的第 0 个 child 是 `PlayerPage`，
///    它 `initState` 里就 `Player()` ⇒ 未初始化会抛
///    `MediaKit.ensureInitialized must be called before using any API`
///    （★ 实测：不初始化时**每个**用例都被这个异常打断，
///     报错文本是 `_elements.contains(element) is not true` ——
///     那是**次生**异常，会掩盖真正的原因）。
///    与 `t58_media_page_layout_test.dart` 的 `setUpAll` 同一手法。
Future<void> _pump(WidgetTester t, {required Size size}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);

  await t.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: const MediaPage(
        provider: 'cycani',
        id: '3862',
        title: '无题',
      ),
    ),
  );
  await t.pump(const Duration(milliseconds: 50));
}

/// 收集树里所有指定类型的 RenderObject
List<T> _renders<T extends RenderObject>(WidgetTester t) {
  final out = <T>[];
  void walk(RenderObject ro) {
    if (ro is T) out.add(ro);
    ro.visitChildren(walk);
  }

  walk(t.binding.renderViews.first.child!);
  return out;
}

/// `RenderClipRRect.borderRadius` 的静态类型是 `BorderRadiusGeometry`
/// （`BorderRadius.only(...)` 实际是 `BorderRadius`，但要**显式**解析）
BorderRadius _radiusOf(RenderClipRRect c) =>
    c.borderRadius.resolve(TextDirection.ltr);

// ══════════════════════════════════════════════════════════════════════════
//  libmpv 夹具：跨平台探测 + 缺夹具时**跳过**（不是假红）
// ══════════════════════════════════════════════════════════════════════════
//
// ★ 为什么必须给**显式路径**：`media_kit` 的
//   `NativeLibrary.ensureInitialized()` 只按**默认名**搜系统路径 ——
//   Windows 找 `libmpv-2.dll`、macOS 找 `Mpv.framework/Mpv`
//   （`media_kit-1.2.6/lib/src/player/native/core/native_library.dart:49-69`）
//   —— 而 `flutter test` 的进程里两者都**不在**搜索路径上 ⇒ 不传路径
//   就是 `Cannot find libmpv-2.dll in your system %PATH%`。
//
// ★ 为什么是**两套**路径：libmpv 由 media_kit 的 libs 包在**构建期**下载，
//   两端落点不同：
//     · Windows：CMake 下到 `build/windows/x64/libmpv/libmpv-2.dll`
//     · macOS  ：Makefile 下 `Mpv.xcframework`，构建后进 app 包的
//                `Contents/Frameworks/libmpv-2.dylib`
//   ⇒ 只认 Windows 那条路径的话，macOS 上永远探不到（即使夹具真的在）。
//
// ★ 为什么缺夹具是 **skip** 而不是 fail：`build/` 被 `.gitignore:36`
//   忽略、从不入库，而 CI 的 `flutter test` 排在
//   `flutter build windows|macos` **之前** ⇒ 没跑过构建的机器上夹具
//   **必然缺席**。那是环境前提，不是本文件的缺陷。
//
// ⚠️ 不是「放宽断言」：夹具在的机器上（例如本地跑过
//   `flutter build windows`）下面的断言一条都不会少跑。
// ⚠️ **不能**改成 `@Tags(['native-media'])`：`dart_test.yaml` 把该标签
//   默认 skip ⇒ 本文件的 ★★★ 契约守卫会从默认套件里**整个消失**
//   —— 那是移除覆盖，不是加守卫。
//
// ★ 本文件 **6 条**用例全都挂 `MediaPage` ⇒ 全都依赖播放器。
// ══════════════════════════════════════════════════════════════════════════

/// libmpv 的候选路径（**跨平台** —— 别只写 Windows 那一条）
List<String> _libmpvCandidates() {
  if (Platform.isWindows) {
    return <String>[
      r'build\windows\x64\libmpv\libmpv-2.dll',
      r'build\windows\x64\runner\Release\libmpv-2.dll',
    ];
  }
  if (Platform.isMacOS) {
    final out = <String>[
      // pod 的 vendored framework（`pod install` 之后）
      'macos/Pods/media_kit_libs_macos_video/Frameworks/'
          'Mpv.xcframework/macos-arm64_x86_64/libmpv-2.dylib',
      'macos/Pods/media_kit_libs_macos_video/Frameworks/'
          'Mpv.xcframework/macos-arm64/libmpv-2.dylib',
    ];
    // `flutter build macos` 之后 libmpv 就在 app 包里
    // （★ app 名不一定是 `sourin_spike` —— 发布版是中文「源影」⇒ 扫目录）
    for (final cfg in const <String>['Release', 'Debug', 'Profile']) {
      final dir = Directory('build/macos/Build/Products/$cfg');
      if (!dir.existsSync()) continue;
      for (final e in dir.listSync()) {
        if (e is Directory && e.path.endsWith('.app')) {
          out.add('${e.path}/Contents/Frameworks/libmpv-2.dylib');
        }
      }
    }
    return out;
  }
  // Linux / 其它：libmpv 由系统包管理器提供
  return <String>[
    '/usr/lib/x86_64-linux-gnu/libmpv.so.2',
    '/usr/lib/libmpv.so.2',
  ];
}

/// 探测到的 libmpv **绝对**路径；`null` = 夹具缺失
String? _libmpv;

/// 夹具准备（`setUpAll` 用）：探到就初始化 MediaKit，探不到**什么都不做**。
///
/// ⚠️ 探不到时这里**绝不 fail** —— 理由见文件头；守卫下沉到
///   `_requireLibmpv()`，由每个**依赖播放器**的用例自己调。
void _prepareLibmpvFixture() {
  for (final rel in _libmpvCandidates()) {
    final f = File(rel);
    if (f.existsSync()) {
      _libmpv = f.absolute.path;
      MediaKit.ensureInitialized(libmpv: _libmpv);
      // ignore: avoid_print
      print('[LIBMPV] 夹具 = $_libmpv');
      return;
    }
  }
  // ignore: avoid_print
  print('[LIBMPV] 夹具**缺失** ⇒ 依赖播放器的用例将 markTestSkipped；'
      '候选 = ${_libmpvCandidates()}');
}

/// 依赖播放器的用例开头调用：`if (!_requireLibmpv()) return;`
///
/// 返回 `true` = 夹具就绪可继续；`false` = **已标记跳过，调用方必须 return**
/// （`markTestSkipped` 只打标记，**不会**中断当前函数 —— 本地实测：标记之后
/// 的代码照常执行，所以必须紧跟 `return`）。
bool _requireLibmpv() {
  if (_libmpv != null) return true;
  markTestSkipped('libmpv 夹具缺失 ⇒ 播放器建不起来，本条无从断言。'
      '手动跑：先 `flutter build windows`（或 macOS 上 `flutter build macos`）'
      '；候选路径 = ${_libmpvCandidates()}');
  return false;
}

void main() {
  setUpAll(_prepareLibmpvFixture);

  setUp(() => RemoteBridge.instance.stop());

  group('① 圆角真的画出来了（真 widget 树，不是读源码）', () {
    testWidgets('★★★ 宽档（1280×800）⇒ 上边两角 + 左下角都圆，右下角不圆', (t) async {
      if (!_requireLibmpv()) return;
      await _pump(t, size: const Size(1280, 800));

      final clips = _renders<RenderClipRRect>(t);
      // ignore: avoid_print
      print('[RADIUS] RenderClipRRect 个数 = ${clips.length}');

      /*
       * ★★★ 正确的四角判据（逐角写清"它紧邻谁"）
       *
       * ```text
       * 合并页：标题栏（黑，通栏）在上，下面是 Row([视频(黑), 面板])
       *
       * 角          紧邻                        宽档  窄档
       * topLeft     上=标题栏(黑) 左=视频(黑)    圆    圆
       * topRight    上=标题栏(黑)               圆    圆   ← ★ 曾经漏掉
       * bottomLeft  左=视频(黑)                 圆    不圆（它是窗口左下角）
       * bottomRight 右=窗口边缘 下=窗口边缘      不圆  不圆
       * ```
       *
       * ⚠️ 这条断言第一版只检查"左圆右直" —— 那**恰好**把
       *    `topRight` 该圆而没圆的情况放过去了（Owner 第二次投诉的正是它）。
       *    ⇒ 现在**四个角逐个断言**，不留下"没被检查的角"。
       */
      final panel = clips.where((c) {
        final r = _radiusOf(c);
        return r.topLeft.x > 0 || r.topRight.x > 0;
      }).toList();

      expect(panel, isNotEmpty,
          reason: '★★★ 找不到详情面板的 ClipRRect —— 修前这里是 **0**，'
              '面板四个角全是直角（Owner：「直角看起来不协调」）');

      final r = _radiusOf(panel.first);
      // ignore: avoid_print
      print('[RADIUS] 宽档四角 = TL:${r.topLeft.x} TR:${r.topRight.x} '
          'BL:${r.bottomLeft.x} BR:${r.bottomRight.x}');

      expect(r.topLeft.x, Radii.lg,
          reason: '★★★ 左上角必须圆 —— 它紧邻标题栏(黑) + 视频(黑)');
      expect(r.topRight.x, Radii.lg,
          reason: '★★★ 右上角**也必须圆** —— Owner 第二次投诉：'
              '「右边详情右上角还是直角」。'
              '★ 它属于**上边**（紧邻标题栏），不属于右边；'
              '我上一版误以为"面板右边 = 窗口边缘 ⇒ 右上角在窗口边缘上" ⇒ 漏了它');
      expect(r.bottomLeft.x, Radii.lg,
          reason: '★★ 宽档下左下角紧邻视频(黑) ⇒ 必须圆');
      expect(r.bottomRight.x, 0,
          reason: '★★ 右下角**必须保持直角** —— 它落在窗口边缘上，'
              '在那里加圆角会变成"窗口边缘上的一个黑色缺口"（像渲染瑕疵）');
    });

    testWidgets('★★★ 窄档（800×800）⇒ 上边两角圆，下边两角不圆', (t) async {
      if (!_requireLibmpv()) return;
      await _pump(t, size: const Size(800, 800));

      final clips = _renders<RenderClipRRect>(t);
      final panel = clips.where((c) {
        final r = _radiusOf(c);
        return r.topLeft.x > 0 || r.topRight.x > 0;
      }).toList();

      expect(panel, isNotEmpty, reason: '找不到详情面板的 ClipRRect');

      final r = _radiusOf(panel.first);
      // ignore: avoid_print
      print('[RADIUS] 窄档四角 = TL:${r.topLeft.x} TR:${r.topRight.x} '
          'BL:${r.bottomLeft.x} BR:${r.bottomRight.x}');

      expect(r.topLeft.x, Radii.lg, reason: '★ 窄档：上边紧邻视频(黑) ⇒ 圆');
      expect(r.topRight.x, Radii.lg, reason: '★ 窄档：上边紧邻视频(黑) ⇒ 圆');
      expect(r.bottomLeft.x, 0,
          reason: '★★ 窄档下面板是**下半屏** ⇒ 左下角落在窗口边缘上 ⇒ 不圆');
      expect(r.bottomRight.x, 0, reason: '★★ 右下角永远不圆（窗口边缘）');
    });
  });

  group('② ★★★ 圆角背后必须是黑 —— 且**只在视频那一侧**（task-68）', () {
    /// 找面板的 rect（= 那个 ClipRRect 的边界）
    Rect panelRect(WidgetTester t) {
      final clips = _renders<RenderClipRRect>(t);
      final panel = clips.where((c) {
        final r = _radiusOf(c);
        return r.topLeft.x > 0 || r.topRight.x > 0;
      }).toList();
      expect(panel, isNotEmpty, reason: '找不到详情面板的 ClipRRect');
      final b = panel.first;
      return b.localToGlobal(Offset.zero) & b.size;
    }

    /// 收集树里所有**不透明黑**的盒子（`ColoredBox` / `DecoratedBox` 都算）
    ///
    /// ⚠️ 必须两种都收：task-68 把整块 `DecoratedBox(black)` 换成了
    ///    `Positioned(ColoredBox(black))` —— 只查 `DecoratedBox` 会漏。
    ///
    /// ══════════════════════════════════════════════════════════════════
    /// ★★★ 必须**限定在面板矩形内** —— 否则仪器有一个致命假阳性
    /// ══════════════════════════════════════════════════════════════════
    ///
    /// # 我第一版没限定，红度证明当场抓到了它
    ///
    /// 合并页的第 0 个 child 是**播放器**（整块纯黑，占 x[0..896]）。
    /// 于是"树里有没有黑"**永远为真** —— 与面板有没有黑底**无关**。
    /// ⇒ "黑底被删掉"这种变异**测不出来**（我实测：M2 该红却是绿的）。
    ///
    /// ★ 这正是本仓铁律"**阳性对照必须能失败**"的一个实例：
    ///   一个永远为真的判据 = 没有判据。
    ///
    /// ⇒ 只收**与面板矩形真正相交**的黑盒（`width>0 && height>0`，
    ///   `Rect.intersect` 在不重叠时会返回**负宽**，不能只判 `isNotEmpty`）。
    List<Rect> blackRects(WidgetTester t, Rect panel) {
      final out = <Rect>[];
      void consider(Rect r) {
        final i = r.intersect(panel);
        // ★ 不重叠时 intersect 返回**负宽** —— 必须显式判正
        if (i.width <= 0 || i.height <= 0) return;
        out.add(r);
      }

      for (final e in find.byType(ColoredBox).evaluate()) {
        final ro = e.findRenderObject();
        if (ro is! RenderBox || !ro.hasSize) continue;
        if ((e.widget as ColoredBox).color != Colors.black) continue;
        consider(ro.localToGlobal(Offset.zero) & ro.size);
      }
      for (final e in find.byType(DecoratedBox).evaluate()) {
        final ro = e.findRenderObject();
        if (ro is! RenderBox || !ro.hasSize) continue;
        final d = (e.widget as DecoratedBox).decoration;
        if (d is! BoxDecoration || d.color != Colors.black) continue;
        consider(ro.localToGlobal(Offset.zero) & ro.size);
      }
      return out;
    }

    testWidgets('★★★ 宽档：黑底盖住**左上**角（视频侧）—— 否则圆角隐形',
        (t) async {
      if (!_requireLibmpv()) return;
      await _pump(t, size: const Size(1280, 800));

      final pr = panelRect(t);
      final blacks = blackRects(t, pr);
      // ignore: avoid_print
      print('[RADIUS] 面板 rect = $pr');
      // ignore: avoid_print
      print('[RADIUS] 黑盒 rect = $blacks');

      // ★ 阳性对照：必须**有**黑（否则下面的几何断言可能空真通过）
      expect(blacks, isNotEmpty,
          reason: '★★★ 圆角**必须**靠黑底才看得见 —— '
              '面板后面是 `surface`(#EEF0F6)，切掉那块露出的还是同色 '
              '⇒ 只加 ClipRRect 而不铺黑底 ⇒ **像素上什么都没变**'
              '（最容易犯的错：改了代码但用户看不见）');

      // ★ 左上角（宽档 = 视频侧）那个**四分之一圆缺口**必须被黑盖住。
      //   缺口 ≈ 面板左上角起、边长 Radii.lg 的方块。
      final corner = Rect.fromLTWH(pr.left, pr.top, Radii.lg, Radii.lg);
      final covered = blacks.any((b) => b.intersect(corner).width >= Radii.lg - 1 &&
          b.intersect(corner).height >= Radii.lg - 1);
      expect(covered, isTrue,
          reason: '★★★ 宽档下**左上角**（紧邻视频=黑）的缺口必须有黑底 —— '
              '否则圆角切掉那块露出的还是 surface，圆角**隐形**。'
              '实测黑盒 = $blacks，左上缺口 = $corner');
    });

    testWidgets('★★★ 宽档：黑底**不得**盖住右上角（标题栏侧）—— task-68 的漏黑',
        (t) async {
      if (!_requireLibmpv()) return;
      await _pump(t, size: const Size(1280, 800));

      final pr = panelRect(t);
      final blacks = blackRects(t, pr);
      final corner = Rect.fromLTWH(
          pr.right - Radii.lg, pr.top, Radii.lg, Radii.lg);

      // ★ 阳性对照：整棵树必须有黑底，否则"找不到黑"会空真通过
      expect(blacks, isNotEmpty,
          reason: '★ 阳性对照：树里必须**有**黑底（左侧两角要用）—— '
              '一块都没有的话下面那条断言是空真的');

      // ★ 右上角（紧邻**浅色**标题栏）不许有黑。
      //   有 ⇒ 圆角切掉那块露出黑色 ⇒ Owner 报的「漏出的黑色」。
      final intruders =
          blacks.where((b) => b.intersect(corner).width > 1 && b.intersect(corner).height > 1);
      expect(intruders, isEmpty,
          reason: '★★★ task-68：右上角紧邻的是**浅色标题栏**（实测 #E7EAF2），'
              '不是黑 —— 那里铺黑底就会"漏出一块黑"（Owner 原话）。'
              '实测侵入右上角 $corner 的黑盒 = ${intruders.toList()}');
    });

    testWidgets('★★★ 窄档：黑底改铺**上边**（视频在上），且不碰下边', (t) async {
      if (!_requireLibmpv()) return;
      await _pump(t, size: const Size(800, 800));

      final pr = panelRect(t);
      final blacks = blackRects(t, pr);
      // ignore: avoid_print
      print('[RADIUS] 窄档 面板 rect = $pr，黑盒 = $blacks');

      expect(blacks, isNotEmpty, reason: '★ 窄档也要有黑底（上边两角要用）');

      // 窄档：视频在**上** ⇒ 上边两角要圆 ⇒ 黑必须盖住**上边**
      final topBand = Rect.fromLTWH(pr.left, pr.top, pr.width, Radii.lg);
      final coversTop =
          blacks.any((b) => b.intersect(topBand).width > 1 && b.intersect(topBand).height > 1);
      expect(coversTop, isTrue,
          reason: '★★★ 窄档视频在**上** ⇒ 黑底必须铺**上边** —— '
              '否则上方两个圆角隐形（Owner 上一轮为"圆角看不见"投诉过两次）');

      // ★ 且**不得**铺到下边（下边两角是窗口边缘，不圆 ⇒ 铺了就是多余的黑）
      final bottomBand =
          Rect.fromLTWH(pr.left, pr.bottom - Radii.lg, pr.width, Radii.lg);
      final intruders = blacks.where((b) =>
          b.intersect(bottomBand).width > 1 && b.intersect(bottomBand).height > 1);
      expect(intruders, isEmpty,
          reason: '★★ 窄档下边两角**不圆**（它们落在窗口边缘上）⇒ '
              '那里不该有黑底。实测侵入下边的黑盒 = ${intruders.toList()}');
    });

    testWidgets('★★★ 冻结契约：Scaffold 底色窗口态仍是 surface（**不许**变黑）',
        (t) async {
      if (!_requireLibmpv()) return;
      await _pump(t, size: const Size(1280, 800));

      final sc = t.widget<Scaffold>(find.byType(Scaffold).first);
      final surface = buildAppTheme(Brightness.light)
          .colorScheme
          .surface;

      // ignore: avoid_print
      print('[RADIUS] Scaffold.backgroundColor = ${sc.backgroundColor} '
          '(surface = $surface)');

      expect(sc.backgroundColor, equals(surface),
          reason: '★★★ 冻结契约（`t58_media_page_layout_test.dart`）：'
              '窗口态底色必须是 `surface`，**不许**是黑的 —— '
              '那是上一轮「进来之后只有黑色」那个缺陷的防回归。'
              '⇒ 黑底必须是**局部**的（只铺在紧邻视频的那一侧）');
    });
  });
}
