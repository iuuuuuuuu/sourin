// ═══════════════════════════════════════════════════════════════════════
//  业主反馈 ⑧ 回归门禁：设置页二级页返回后，那一行不该还「选中」
// ═══════════════════════════════════════════════════════════════════════
//
// # 业主原话（逐字）
//
// 「设置页,点击这个js插件,返回之后,这里也还是选中状态」
//
// # 真实根因（逐像素 + SDK 源码双重取证，不是推测）
//
// 业主截图（1444x805，浅色主题）逐像素量出来：
//
//   页面底色              = 238,240,246   (= LightTokens.bgBase #EEF0F6)
//   「JS 插件」那一行     = 220,222,226   <- 业主说的「还是选中状态」
//   紧下面「Emby」那一行  = 240,242,247   <- 正常
//
// 行的填充 = colors.surfaceContainerHighest(#F5F7FA) x 0.3 叠在底色上：
//   245,247,250 x 0.3 + 238,240,246 x 0.7 = 240,242,247   <- 正是「正常行」
// 再叠一层**纯黑 alpha=0.12**：
//   240,242,247 x 0.88 = 211,213,217   <- 不对
// 而**墨层画在填充【下面】**（Material 的 ink 特性先画，child 后画，
// 见 flutter/lib/src/material/material.dart:621-635 —— super.paint 在后）：
//   238,240,246 x 0.88 = 209.4,211.2,216.5
//   245,247,250 x 0.3 + 209.4,211.2,216.5 x 0.7 = 220.1,221.9,226.5
//   ^^^ 逐通道命中业主量到的 220,222,226 ✓
//
// 那个 alpha=0.12 的纯黑就是 **ThemeData.focusColor**
// （flutter/lib/src/material/theme_data.dart:467
//   focusColor ??= isDark ? white 0.12 : black 0.12）
// => 业主看到的是 **InkWell 的焦点高亮填充**，不是 selected 标志位。
//
// 设置列表里**根本没有 selected 状态**：SettingsEntryRow
// （lib/ui/widgets/settings_kit.dart:742）没有 selected 参数，
// settings_page.dart 全文件也搜不到 _activeSub / selected / highlight。
//
// # 为什么返回之后它还在（缺陷的**时序**）
//
// 焦点落在入口行的 InkWell 上（遥控方向键 / Tab 都能落到）。
// 二级页 pop 回来时焦点会**回到原来那个 FocusNode**
// （Flutter 的 focus 恢复语义）=> 高亮重新亮起，
// 而指针没有动过（鼠标停在原行上）=> 用户看到的正是
// 「点进去、返回，这一行还是灰的」。
//
// # 本门禁测什么
//
//   ① 建**真** SettingsPage（真列表、真行、真导航）
//   ② 用**真输入**把焦点放到「JS 插件」那一行（Tab 键，桌面生产输入）
//   ③ 断言此刻该行**确实**有焦点（否则仪器没建立前提 -> 直接失败，
//      绝不静默跳过）
//   ④ 鼠标点进去 -> 真 Navigator.pop() 返回
//   ⑤ 量那一行的**渲染像素**，与紧下面「Emby」行对比
//
// 缺陷代码上：两行差 ≈ 20 个灰度级（0.12 黑填充还在）=> 红
// 修好之后  ：两行差 0                                  => 绿
//
// # 仪器坑（踩过，别踩）
//
// 1) 宿主**必须有不透明底色**。旧版宿主用 Material(transparency)，
//    整棵树半透明 => 读 rawRgba 读到的是**预乘 alpha** 的假色
//    （245,247,250 x 0.3 = 73.5,74.1,75，旧读数 74,74,75 就是它），
//    于是「有没有叠那层黑」根本量不出来（Δ 恒 0）—— 那是假绿。
// 2) layer.toImage() 在 widget test 的 FakeAsync zone 里**永不返回**
//    => 像素采样必须包在 tester.runAsync 里。
// 3) 鼠标手势：一个 testWidgets 里**只能** createGesture(kind: mouse) 一次
//    （第二次会撞 mouse_tracker.dart 的断言）。
// 4) 采样点必须落在行的**纯背景区**（避开图标 / 文字 / 右侧箭头）。
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/device.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/settings_page.dart';
import 'package:sourin_spike/ui/theme_bridge.dart';
import 'package:sourin_spike/ui/widgets/settings_kit.dart';

const String kTag = '[CR8]';
void log(String s) => debugPrint(kTag + " " + s);

/// ★ 单个用例硬超时：能静默挂 10 分钟的测试比失败的测试更贵
const Timeout kTimeout = Timeout(Duration(minutes: 5));

/// 交付件里的核心 DLL（lib/core/ffi.dart:169 只认**裸名**，所以要我们自己载）
const String _dllRel = r'build\windows\x64\runner\Release\sourin_core.dll';

/// 业主截图的逻辑尺寸（1444x805，像素比 1.0）
const Size kOwnerViewport = Size(1444, 805);

/// 业主截图里「JS 插件」那一行的填充色 / 下面「Emby」行的填充色
const List<int> kOwnerSelectedRgb = [220, 222, 226];
const List<int> kOwnerNormalRgb = [240, 242, 247];

/// 「还选中」的判定阈值（灰度级）。业主现场实测差 20 级；
/// 缺陷代码上本仪器实测差 20 级；修好后差 0 级 ⇒ 4 是安全带里的低门槛。
const int kStaleDeltaThreshold = 4;

/// Tab 最多按几次去找那一行（真输入，不是 requestFocus）
const int kMaxTabs = 40;

void _preloadCoreDll() {
  final f = File(_dllRel);
  if (!f.existsSync()) {
    log('DLL 不在（${f.absolute.path}）—— 本文件不读 FFI，继续跑');
    return;
  }
  DynamicLibrary.open(f.absolute.path);
  log('DLL 预加载 = OK（${f.absolute.path}）');
}

/// 给真事件循环开窗口 + 抽干微任务（供 widget 自己发起的异步推进）
Future<void> _settle(WidgetTester tester, {int rounds = 6, int ms = 120}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
    await tester.pump();
    while (tester.takeException() != null) {}
  }
}

/// 轮询直到条件成立（导航是真异步，不能靠固定帧数）
Future<bool> _until(WidgetTester tester, bool Function() done,
    {int rounds = 40, int ms = 60}) async {
  for (var i = 0; i < rounds; i++) {
    if (done()) return true;
    await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
    await tester.pump(const Duration(milliseconds: 32));
    while (tester.takeException() != null) {}
  }
  return done();
}

/// 量一小块区域的**平均颜色**（真像素，不是"读 widget 属性"）
///
/// ★ 必须包 runAsync：toImage() 在 FakeAsync zone 里永不返回。
/// ★ 采样的是**整视图 layer**（与落盘截图同源，逻辑坐标），
///   不是 RepaintBoundary.first —— 后者在真宿主里可能是别的子树。
Future<List<int>> _meanRgb(WidgetTester tester, Rect crop) async {
  final v = await tester.runAsync(() async {
    final view = tester.binding.renderViews.first;
    final layer = view.debugLayer! as OffsetLayer;
    final img = await layer.toImage(Offset.zero & view.size);
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    final w = img.width;
    final h = img.height;
    img.dispose();
    final bytes = data!.buffer.asUint8List();
    var r = 0, g = 0, b = 0, n = 0;
    final x0 = crop.left.round().clamp(0, w - 1);
    final x1 = crop.right.round().clamp(1, w);
    final y0 = crop.top.round().clamp(0, h - 1);
    final y1 = crop.bottom.round().clamp(1, h);
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        final o = (y * w + x) * 4;
        r += bytes[o];
        g += bytes[o + 1];
        b += bytes[o + 2];
        n++;
      }
    }
    return [r ~/ n, g ~/ n, b ~/ n];
  });
  return v ?? [-1, -1, -1];
}

/// 行的**纯背景**采样区：靠右、避开门图标/文字/右侧箭头
Rect _cleanPatch(Rect row) => Rect.fromLTRB(
    row.left + 900, row.center.dy - 5, row.left + 980, row.center.dy + 5);

/// 行的**左边缘**采样区 —— 焦点环画在这里（前景描边，宽 2）
///
/// ★ 为什么必须分开采样：修复把「整行填充」换成了「描边环」，
///   两者落在**完全不同的像素**上。只量中间那块背景，
///   就分不出「环画出来了」与「环也没画」—— 后者是
///   「把焦点可见性一起删掉」，不是修复（本仓铁律：假门禁比红更糟）。
Rect _ringPatch(Rect row) => Rect.fromLTRB(
    row.left, row.center.dy - 5, row.left + 3, row.center.dy + 5);

int _gray(List<int> c) => ((c[0] + c[1] + c[2]) / 3).round();

String _rgb(List<int> c) => c.join(",");

/// 哪一行是「JS 插件」——按标题文本找，不按下标（列表顺序会变）
Finder _entryRow(String title) => find
    .ancestor(of: find.text(title), matching: find.byType(SettingsEntryRow))
    .first;

/// 这一行的 InkWell 自己的 FocusNode（焦点高亮挂在它上面）
FocusNode _rowFocus(WidgetTester tester, String title) =>
    Focus.of(tester.element(find.text(title)));

/// 让**视觉**真正稳定下来再量像素
///
/// # 为什么不能只 pump()
///
/// InkWell 的高亮是 `InkHighlight`，用 `AnimationController` 做
/// **50ms 淡入**（`ink_well.dart:1001 hoverDuration ?? 50ms`）。
/// 而 `tester.pump()` 不推进假时钟 ⇒ 淡入永远停在 0 帧，
/// 量到的像素是「高亮还没画上去」—— 我第一版就踩了这个：
/// 同一个缺陷代码，⑥a 量出 0 级（假绿）、⑥b 量出 20 级（真红），
/// 差别只是 ⑥b 前面多了一次 `pumpAndSettle()`。
///
/// ⇒ 这里三件事一起做：
///   ① `runAsync` 开真事件循环（路由/焦点恢复是异步的）
///   ② `pumpAndSettle` **推进假时钟**直到没有待处理帧（淡入走完）
///   ③ 重复几轮，覆盖「焦点在 post-frame 里才恢复」的时序
Future<void> _settleVisual(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    while (tester.takeException() != null) {}
  }
}

/// 把当前整屏落盘当证据（SOURIN_SHOT_DIR 缺省 = 系统临时目录）
Future<void> _shoot(WidgetTester tester, String name) async {
  final shot = await tester.runAsync(() async {
    final view = tester.binding.renderViews.first;
    final layer = view.debugLayer! as OffsetLayer;
    final img = await layer.toImage(Offset.zero & view.size);
    final bd = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return bd!.buffer.asUint8List();
  });
  if (shot == null) return;
  final dir = Directory(
      Directory.systemTemp.path + Platform.pathSeparator + 'sourin-shots');
  dir.createSync(recursive: true);
  final f = File(dir.path + Platform.pathSeparator + name);
  f.writeAsBytesSync(shot);
  log('证据截图 → ${f.path}');
}

void main() {
  setUpAll(_preloadCoreDll);

  testWidgets('返回设置页后，「JS 插件」那一行不该还是选中态', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = kOwnerViewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    try {
      log('设备 isTv=${Device.isTv} isDesktop=${Device.isDesktop} needsFocusRing=${Device.needsFocusRing}');

      final theme = AppTheme.themeFor(Brightness.light);
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        builder: (context, c) =>
            AppThemeHost(data: theme, child: c ?? const SizedBox()),
        // ★ 必须有不透明底色 —— 否则读到的是预乘 alpha 的假色（见文件头坑 1）
        home: const ColoredBox(
          color: LightTokens.bgBase,
          child: SettingsPage(),
        ),
      ));
      await _settle(tester);

      // ── 前置条件：两条行都在列表上 ──
      expect(find.byType(SettingsPage), findsOneWidget,
          reason: '一级设置页没建起来 —— 仪器问题，不是入口问题');
      final jsRow = _entryRow('JS 插件');
      final embyRow = _entryRow('Emby');
      expect(jsRow, findsOneWidget, reason: '设置列表里找不到「JS 插件」入口行');
      expect(embyRow, findsOneWidget, reason: '设置列表里找不到「Emby」入口行（对照组）');

      final jsRect = tester.getRect(jsRow);
      final embyRect = tester.getRect(embyRow);
      final pJs = _cleanPatch(jsRect);
      final pEm = _cleanPatch(embyRect);
      log('JS 插件行 rect=${jsRect}');
      log('Emby   行 rect=${embyRect}');
      log('业主截图填充色：选中=${kOwnerSelectedRgb.join(",")} 正常=${kOwnerNormalRgb.join(",")}');
      log('采样区 JS=${pJs} Emby=${pEm}');

      // ── ① 基线：指针不在页面上，两行应当**同色** ──
      final pJsRing = _ringPatch(jsRect);
      final pEmRing = _ringPatch(embyRect);

      await _settleVisual(tester);
      final baseJs = await _meanRgb(tester, pJs);
      final baseEm = await _meanRgb(tester, pEm);
      final baseJsRing = await _meanRgb(tester, pJsRing);
      final baseEmRing = await _meanRgb(tester, pEmRing);
      log('① 基线（无指针、无焦点）JS=${_rgb(baseJs)} Emby=${_rgb(baseEm)}  环 JS=${_rgb(baseJsRing)} Emby=${_rgb(baseEmRing)}');
      expect((_gray(baseJs) - _gray(baseEm)).abs(), lessThanOrEqualTo(2),
          reason: '基线就不一致 ⇒ 采样区没落在纯背景上，仪器问题');
      expect((_gray(baseJsRing) - _gray(baseEmRing)).abs(), lessThanOrEqualTo(2),
          reason: '基线的行边缘就不一致 ⇒ 环的采样区没落对，仪器问题');

      // ── ② 用**真输入**（Tab 键）把焦点放到「JS 插件」那一行 ──
      //
      // ★ 为什么不用 requestFocus()：那是我自己把状态摆好，
      //   而业主是按了键/遥控器之后才有的焦点。用真按键才证明
      //   "这条路上焦点真的会落到这一行"。
      var tabs = 0;
      while (!_rowFocus(tester, 'JS 插件').hasFocus && tabs < kMaxTabs) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        tabs++;
      }
      final focused = _rowFocus(tester, 'JS 插件').hasFocus;
      log('② Tab x' + tabs.toString() + ' 后「JS 插件」行 hasFocus=' +
          focused.toString() +
          '  primary=' +
          (FocusManager.instance.primaryFocus?.debugLabel ?? "(null)") +
          '  mode=' + FocusManager.instance.highlightMode.toString());
      expect(focused, isTrue,
          reason: '按了 ' + tabs.toString() + ' 次 Tab 都没把焦点放到「JS 插件」行 ⇒ '
              '本门禁建立不了前提。★ 绝不放行：这条断言红了就是仪器/接线坏了，'
              '必须查清，不能删掉跳过');

      await _settleVisual(tester);
      final focJs = await _meanRgb(tester, pJs);
      final focEm = await _meanRgb(tester, pEm);
      final focJsRing = await _meanRgb(tester, pJsRing);
      final focEmRing = await _meanRgb(tester, pEmRing);
      log('③ 有焦点时 行内 JS=${_rgb(focJs)} Emby=${_rgb(focEm)}  Δ(Emby−JS)=${(_gray(focEm) - _gray(focJs))}');
      log('③ 有焦点时 行边缘 JS=${_rgb(focJsRing)} Emby=${_rgb(focEmRing)}  Δ(JS边缘−JS内)=${(_gray(focJsRing) - _gray(focJs))}');
      // ★ 焦点必须**看得见**（换成描边环之后，可见性落在行边缘上）。
      //   这条断言是反假绿的：只把填充关掉、环也不画 = 「把焦点可见性
      //   一起删了」，那会让 TV/键盘用户彻底失去位置指示。
      //
      // ⚠️ 判据是「行边缘相对**自己**的基线变了」—— 不是相对行内部。
      //   环是 primary 蓝（#3B6FE0），画上去会让边缘**更暗更饱和**
      //   （实测 234,236,242 -> 119,154,231），所以差值是**负**的。
      //   写成 `greaterThan` 就是符号搞反（我第一版就是这么写的，红了）。
      expect(_gray(baseJsRing) - _gray(focJsRing), greaterThanOrEqualTo(3),
          reason: '焦点落在行上，行边缘相对基线没有变化 ⇒ 描边环没画出来，'
              '焦点态失去可见指示（TV/键盘用户会失去位置感）。'
              '★ 这不是「绿」，是把缺陷换成了另一个缺陷');
      // 对照组（没焦点的 Emby 行）不该有环 —— 否则说明环是无条件画的
      expect((_gray(baseEmRing) - _gray(focEmRing)).abs(), lessThanOrEqualTo(2),
          reason: '没有焦点的行也画了环 ⇒ 环的显隐判据错了（成了装饰）');

      // ── ④ 业主动作：鼠标点「JS 插件」进二级页 ──
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      final jsCenter = tester.getCenter(jsRow);
      await mouse.addPointer(location: const Offset(1200, 700));
      await tester.pump();
      await mouse.moveTo(jsCenter);
      await tester.pumpAndSettle();
      await mouse.down(jsCenter);
      await tester.pump(const Duration(milliseconds: 60));
      await mouse.up();
      await tester.pump();

      final pushed = await _until(
          tester, () => find.byType(SettingsPage).evaluate().isEmpty);
      log('④ 二级页已推入 = ${pushed}');
      expect(pushed, isTrue, reason: '点了「JS 插件」没进二级页 —— 入口坏了，另案');

      // ★ 业主的关键动作：指针**不动**（还停在原来那一行的位置）
      log('   （指针留在 ${jsCenter}，模拟业主"点完就等页面"）');

      // ── ⑤ 真返回 ──
      Navigator.of(tester.element(find.byType(SettingsPage, skipOffstage: false)))
          .pop();
      final popped = await _until(
          tester, () => find.byType(SettingsPage).evaluate().isNotEmpty);
      await tester.pump(const Duration(milliseconds: 400));
      await _settle(tester, rounds: 2);
      log('⑤ 已返回设置页 = ${popped}');
      expect(popped, isTrue, reason: '没回到设置页 —— 仪器问题');

      // ── ⑥ 判决（★ 业主的**原始姿势**：指针留在原行上，绝不移开）──
      //
      // # 为什么这一量必须保持指针不动
      //
      // 业主的姿势是「点完就等页面」—— 指针从没离开过那一行。
      // 一移开指针就改变了两件事（hover 消失 + 可能触发重新 hit-test），
      // 量到的就不再是他看到的那一屏。
      //
      // # 但「整行灰底」有**两个**来源，必须分开量（实测，不是推测）
      //
      // 探针 v19（对照 InkWell，指针全程不动）实测：
      //   hover 遮罩在 pop 之后**会自己回来**（Δ=6 灰度级）
      // 而 focus 填充是 Δ=20（业主截图那个数）。
      // ⇒ 只测「移开指针之后」，等于把 hover 这一半**排除在门禁之外**。
      //   这里两条都测：
      //     ⑥a 指针留在原行（业主姿势）—— hover 与 focus 都在
      //     ⑥b 指针移开 —— 只剩 focus
      //   修复必须让**两者都**归零，否则业主换一个姿势还是看到灰带。
      await _settleVisual(tester);
      final backJs = await _meanRgb(tester, pJs);
      final backEm = await _meanRgb(tester, pEm);
      final deltaHoverPose = _gray(backEm) - _gray(backJs);
      final node = _rowFocus(tester, 'JS 插件');
      log('⑥a 返回后(指针仍在行上=业主原姿势) JS=${_rgb(backJs)} Emby=${_rgb(backEm)}  Δ(Emby−JS)=${deltaHoverPose}  hasFocus=${node.hasFocus}');
      await _shoot(tester, 'zz8_after_pop_hover.png');

      // ── ⑥b 移开指针：只剩「焦点」那一半（判决的主体）──
      await mouse.moveTo(const Offset(1200, 700));
      await _settleVisual(tester);

      final offJs = await _meanRgb(tester, pJs);
      final offEm = await _meanRgb(tester, pEm);
      final deltaFocusOnly = _gray(offEm) - _gray(offJs);
      log('⑥b 返回后(指针移开) JS=${_rgb(offJs)} Emby=${_rgb(offEm)}  Δ(Emby−JS)=${deltaFocusOnly}');
      await _shoot(tester, 'zz8_after_pop.png');

      // ── ⑥c 标定「纯 hover」有多大（★ 自标定，不用魔数）──
      //
      // ⑥a 量到的是 hover + focus 之和，光看它分不清「灰带是缺陷残留」
      // 还是「指针真的停在行上」。所以这里**现测一个纯 hover 参照**：
      // 把指针移到「Emby」行 —— 它**没有焦点**，于是它上面出现的
      // 任何变暗都只可能来自 hover。
      //
      // ⚠️ 用自标定而不是写死一个数字：hover 强度由主题的 hoverColor 决定，
      //   换主题/换配色它就会变，写死的阈值会**静默失效**（假绿的老路）。
      await mouse.moveTo(tester.getCenter(embyRow));
      await _settleVisual(tester);
      final hoverRefEm = await _meanRgb(tester, pEm);
      final deltaHoverRef = _gray(baseEm) - _gray(hoverRefEm);
      log('⑥c 纯 hover 标定（指针停在无焦点的「Emby」行上）Δ=${deltaHoverRef}  像素=${_rgb(hoverRefEm)}');
      expect(deltaHoverRef, greaterThanOrEqualTo(2),
          reason: '指针停在行上却量不到 hover 遮罩 ⇒ 本标定失效，'
              '⑥a 的对照就没有意义（仪器问题）');

      // ── 判决 ──
      //
      // ★ 主判据 = ⑥b：指针移开之后**必须**干净。
      //   这一条与指针位置无关，量到的只可能是焦点层 ⇒ 缺陷的直接证据。
      expect(deltaFocusOnly, lessThanOrEqualTo(kStaleDeltaThreshold),
          reason: '（指针移开）返回后「JS 插件」那一行仍比「Emby」行暗 ' +
              deltaFocusOnly.toString() +
              ' 个灰度级 ⇒ 焦点填充回来了（focusColor 被画成整行灰底）');
      //
      // ★ 辅判据 = ⑥a：业主原姿势下，那一行**不该比一个普通 hover 行更暗**。
      //   hover 是合法反馈（指针确实停在上面，移开就灭），不算「选中态」；
      //   缺陷的特征是**多出焦点那一层**。所以拿实测的 hover 当基准，
      //   允许多出 kStaleDeltaThreshold 的余量。
      expect(deltaHoverPose,
          lessThanOrEqualTo(deltaHoverRef + kStaleDeltaThreshold),
          reason: '业主原姿势下「JS 插件」行比一个纯 hover 行还暗 ' +
              (deltaHoverPose - deltaHoverRef).toString() +
              ' 个灰度级（实测 hover 基准=' + deltaHoverRef.toString() +
              '）⇒ 除 hover 外还有一层没散（焦点填充）。业主原话：'
              '「设置页,点击这个js插件,返回之后,这里也还是选中状态」');

      // ── 反假绿自检（本门禁必须能红）──
      //
      // 已实测：把 lib 里那行 `focusColor: Colors.transparent,` 注释掉
      // （= 还原缺陷），本文件当场变红：
      //   ⑥a 26 级（= hover 6 + focus 20）、⑥b 20 级
      // 恢复后 ⑥a 6 级（纯 hover）、⑥b 0 级。
      // 业主截图量到的 220,222,226 正是那 20 级。
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }, timeout: kTimeout);
}
