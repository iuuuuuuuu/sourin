// ══════════════════════════════════════════════════════════════════════════
// t464 —— 夹到边界时，提示**真的送到用户眼前**吗？
// ══════════════════════════════════════════════════════════════════════════
//
// # 为什么单独一条（前面已有 t463 测互斥）
//
// `t463` 的宿主是**裸** `SkipMarkerDialog`（树里一个 `Scaffold` 都没有），
// 在那里 `showSnackBar` 会抛 `_scaffolds.isNotEmpty` 断言。
// ⇒ 它能测「值被夹住了」，但**测不到**「提示能不能显示」——
//   因为在它那个宿主里，提示**本来**就显示不出来。
//
// 本条补的正是这一层：**生产同构**的宿主（页面有 `Scaffold` + `showDialog`），
// 断言 SnackBar **真的出现**且文案是**人话**。
//
// # 它守的是三个真出现过的缺陷
// ```text
// ① 提示是**乱码**：`$_peerName(e)` 漏了花括号 ⇒ 插进了**函数对象**
//    [SKIPDLG] …：片头结束不能超过
//    Closure: (SkipEdge) => String from Function '_peerName@…':.(e)（下限 00:04）
// ② 方向说反：撞**下界**也说「不能超过」⇒ 用户去改**右边**那个点
// ③ 提示被**静默关掉**：我曾用 `Scaffold.maybeOf(context) == null` 当守卫，
//    而 `showSnackBar` 的真实前提是 messenger 的 `_scaffolds` 非空 ——
//    弹窗路由是页面的**兄弟**，往上找不到 Scaffold，**但**页面的 Scaffold
//    已注册进同一个 messenger ⇒ 生产里**本来能用**，被那条守卫关掉了。
//    （用户要求恰恰是「**不能静默**」）
// ```
//
// # ⚠️ 两个必须遵守的坑（我都踩过）
// ```text
// ① 必须 `import 'package:material_ui/material_ui.dart'`，
//    **不是** `package:flutter/material.dart` ——
//    `material_ui` 是本仓用的**独立 fork**（自带 src/scaffold.dart 3626 行、
//    自己的 ScaffoldMessenger / MaterialApp / showDialog）。
//    用 flutter/material 搭宿主 ⇒ 弹窗去另一个类里找 messenger ⇒ 拿不到
//    ⇒ `?.` 静默短路 ⇒ **既没有 SnackBar 也没有异常**，
//      看起来像"产品不弹提示"（我第一次就这么误判了）。
//    `grep "package:flutter/material.dart" lib` = 0 命中。
// ② 断言别写成 `expect(bool?, isNotNull)` —— 对 `false` 也通过（假绿）。
// ```

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/widgets/skip_marker_dialog.dart';
import 'package:sourin_spike/ui/widgets/skip_timeline.dart';

/// 认领一次 pump 期间积压的环境异常（无核心库的 FFI 异常等）
///
/// ⚠️ 不认领会报 `Multiple exceptions were detected` ——
///    ★ 那不是被测对象的失败，是本环境**加载不了 `sourin_core.dll`**
///      导致的副作用（弹窗读跳过点 / 起预览都会抛）。
///    本仓既有测试（`t463_mutual_exclusion_test.dart` 等）用同一个手法。
void _claim(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

/// 生产同构的壳：`FTheme` 挂 `MaterialApp.builder`（照 `shell.dart:1379`）
///
/// ⚠️ `home:` 里**必须**有一个 `Scaffold` —— 那是"生产里提示能显示"的来源
///    （`PlayerPage.build` 返回 `Scaffold(...)`，见 `player_page.dart:6613`）。
Widget _host({required Widget Function(BuildContext) body}) {
  final theme = FTheme.neutral.light.desktop;
  return MaterialApp(
    theme: theme.toApproximateMaterialTheme(),
    builder: (_, c) => FTheme(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: Builder(builder: body)),
  );
}

/// 打开真实弹窗（走真实 `showDialog` 路由）
///
/// ⚠️ **不能**用 `pumpAndSettle()` —— 弹窗里有 `CircularProgressIndicator`
///    （预览起不来时的加载态），它是**无限循环动画**，会一直等到超时。
Future<void> _openDialog(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(_host(
    body: (ctx) => ElevatedButton(
      onPressed: () => showDialog<void>(
        context: ctx,
        barrierDismissible: false,
        builder: (_) => const SkipMarkerDialog(
          provider: 'probe',
          id: 't464',
          title: 't464 夹边界提示',
          streamUrl: '',
          duration: Duration(seconds: 60),
        ),
      ),
      child: const Text('open'),
    ),
  ));
  await tester.tap(find.text('open'));
  for (var i = 0; i < 14; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    _claim(tester);
  }
}

/// 点某一行的「+」`times` 次
///
/// ★ 用 `tapAt(坐标)` 而不是 `find.byIcon`：四个行用的是同一个
///   `const Icon(Icons.add)` 实例，`find.byWidget` 会匹配到四个。
Future<void> _tapPlusIn(WidgetTester tester, String label, int times) async {
  for (var i = 0; i < times; i++) {
    final rowY = tester.getRect(find.text(label)).center.dy;
    Offset? hit;
    for (final e in find.byIcon(Icons.add).evaluate()) {
      final ro = e.renderObject as RenderBox;
      final c = ro.localToGlobal(ro.size.center(Offset.zero));
      if ((c.dy - rowY).abs() < 24) {
        hit = c;
        break;
      }
    }
    if (hit == null) return;
    await tester.tapAt(hit);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    _claim(tester);
  }
}

/// 让 SnackBar 的入场动画跑完，并取回它的文字
List<String> _snackTexts(WidgetTester tester) {
  final snack = find.byType(SnackBar);
  if (snack.evaluate().isEmpty) return const [];
  return find
      .descendant(of: snack.first, matching: find.byType(Text))
      .evaluate()
      .map((e) => (e.widget as Text).data ?? '')
      .toList();
}

void main() {
  group('t464 夹边界的提示必须真的送到用户眼前', () {
    testWidgets('★★★ 阳性对照：宿主里 SnackBar 通道是通的（用「重置」的无条件提示）',
        (tester) async {
      /*
       * ⚠️ 这条是**仪器自检**，不是被测对象。
       *
       * 没有它的话，下面那条"撞边界后应该有 SnackBar"可能因为
       * **宿主根本弹不出提示**而失败 —— 那是宿主的问题，不是产品的，
       * 而我会误判成"产品不提示"（我第一次就误判了，见文件头坑①）。
       * 「重置」里的 `_toast('已重置')` 是**无条件**的 ⇒ 拿它当阳性对照。
       */
      await _openDialog(tester);
      expect(find.byType(SkipTimeline), findsOneWidget,
          reason: '★ 弹窗没打开 ⇒ 后面全是恒真（假绿）');

      await tester.tap(find.text('重置'), warnIfMissed: false);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        _claim(tester);
      }

      expect(find.byType(SnackBar), findsWidgets,
          reason: '★★★ 连无条件的「已重置」都弹不出来 ⇒ 本宿主测不了提示可见性。'
              '★ 检查 import 是不是 `material_ui`（不是 `flutter/material`）—— '
              '两个库各有自己的 ScaffoldMessenger，混用会静默拿不到');
    });

    testWidgets('★★★ 撞下界：SnackBar 出现、方向说「不能小于」、文案不是 Closure',
        (tester) async {
      await _openDialog(tester);
      expect(find.byType(SkipTimeline), findsOneWidget,
          reason: '★ 弹窗没打开 ⇒ 后面全是恒真（假绿）');

      // ── 造一次**必然被夹**的操作 ──
      // 片头开始 0 → 3（下界 0，不夹）；再点片头结束 1 次：
      // 它的下界是 `片头开始 + 1 = 4`，而 want = 0 + 1 = 1 < 4 ⇒ 被夹到 4
      await _tapPlusIn(tester, '片头开始', 3);
      await _tapPlusIn(tester, '片头结束', 1);

      final tl = tester.widget<SkipTimeline>(find.byType(SkipTimeline));
      // ★ 前置闸：**必须真的被夹过**。没夹住 ⇒ SnackBar 本来就不该出现，
      //   下面的断言测的就变成了别的东西（假红）
      expect(tl.introStart, 3, reason: '★ 片头开始应为 3');
      expect(tl.introEnd, 4,
          reason: '★ 片头结束被夹到 4（= 片头开始 + 1）—— '
              '这里不对说明这次点击没触发 clamp，后面的断言就没有意义');

      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        _claim(tester);
      }

      final texts = _snackTexts(tester);
      expect(texts, isNotEmpty,
          reason: '★★★ 撞边界后必须弹出提示 —— Owner 的要求是「**不能静默**」。'
              '找不到 ⇒ 提示没送到用户眼前');

      final msg = texts.join(' ');
      expect(msg.contains('Closure'), isFalse,
          reason: '★★★ 文案里不许出现 `Closure:` —— '
              // ★ 这里必须写成 `r'...'`：普通字符串里的 `$_peerName`
              //   会被**我自己**插值成函数对象，正好复现被测的那个 bug
              r'那是插值漏花括号（`$_peerName(e)` 应为 `${_peerName(e)}`）'
              '把**函数对象**打进字符串的痕迹');
      expect(msg.contains('片头结束'), isTrue,
          reason: '★ 文案要说清是**哪个点**被夹住了');
      expect(msg.contains('不能小于'), isTrue,
          reason: '★★★ 撞的是**下界**，方向词必须是「不能小于」—— '
              '说「不能超过」用户会去改**右边**那个点（改错了地方）');
      expect(msg.contains('不能超过'), isFalse,
          reason: '★★★ 撞下界还说「不能超过」就是方向说反了');
      expect(msg.contains('片头开始'), isTrue,
          reason: '★★ 挡住它的是**片头开始**（下界来自 `片头开始 + 1`）—— '
              '文案里的人名必须是**反查**出来的，不是猜的');
    });

    testWidgets('★★★ 撞上界：`+` 会**先灰掉** ⇒ 走不到提示（上界分支是防御性的）',
        (tester) async {
      /*
       * ══════════════════════════════════════════════════════════════════
       * ★ 这条本来是"测另一个方向"，实测发现**那个方向走不到** —— 于是改成
       *   把"走不到"这件事本身钉住。
       * ══════════════════════════════════════════════════════════════════
       *
       * # 为什么走不到（算术，不是猜）
       * `_EdgeRow` 的 `+`：
       * ```text
       * onTap  : onChanged((v ?? 0) + 1)
       * enabled: (v ?? 0) < hi          ← 到上限就灰
       * ```
       * 要"按 + 且被夹到上界"就必须同时满足：
       * ```text
       * (v ?? 0) < hi   且   (v ?? 0) + 1 > hi
       * ⇒ hi - 1 < (v ?? 0) < hi   ⇒ 整数无解
       * 若 v == null：0 < hi 且 1 > hi ⇒ hi == 0，但那时 0 < 0 为假 ⇒ 灰
       * ```
       * ⇒ **上界方向按不出来**。同理 `-` 的下界方向也走不到。
       *   真正能触发 clamp 的只有一条路：
       * ```text
       * 某点**未设置**（v == null ⇒ 默认按 0 算）而它的下界 lo > 1
       * ⇒ 按 + 送 want=1 ⇒ 夹到 lo ⇒ 提示「不能小于…」
       * ```
       * 这也解释了上一条测试为什么要先设片头开始=3 再点片头结束：
       * 那时 `lo = 3 + 1 = 4 > 1`。
       *
       * # 这条测试守什么
       * ```text
       * ① `+` 到上限**确实灰掉**（设计如此）—— 钉在**行为层**，
       *    而 `skip_history_dialog_test.dart` 只在**源码文本层**断言过它
       * ② 灰掉时**不会**冒出提示（没改动就不该打扰）
       * ③ 若将来有人把灰掉去掉 ⇒ 这条红 ⇒ 逼他重新审视
       *    上界方向的文案（`up` 分支就变成"活的"了）
       * ```
       */
      await _openDialog(tester);
      expect(find.byType(SkipTimeline), findsOneWidget,
          reason: '★ 弹窗没打开 ⇒ 后面全是恒真（假绿）');

      // 片头结束 = 5 ⇒ 片头开始的上界 = 5 - 1 = 4
      await _tapPlusIn(tester, '片头结束', 5);
      await _tapPlusIn(tester, '片头开始', 9);

      final tl = tester.widget<SkipTimeline>(find.byType(SkipTimeline));
      expect(tl.introEnd, 5, reason: '★ 片头结束应为 5');
      expect(tl.introStart, 4,
          reason: '★ 片头开始停在 4（= 片头结束 - 1）—— '
              '若它 > 4 说明夹取失效（四条互斥破了）');

      // ★ 关键读数：那一行的 `+` **必须是禁用的**
      final rowY = tester.getRect(find.text('片头开始')).center.dy;
      bool? plusEnabled;
      for (final e in find.byType(IconButton).evaluate()) {
        final w = e.widget as IconButton;
        final ro = e.renderObject as RenderBox;
        if (ro is! RenderBox) continue;
        final c = ro.localToGlobal(ro.size.center(Offset.zero));
        if ((c.dy - rowY).abs() > 24) continue;
        if (w.icon is Icon && (w.icon as Icon).icon == Icons.add) {
          plusEnabled = w.onPressed != null;
          break;
        }
      }
      expect(plusEnabled, isNotNull,
          reason: '★ 没找到「片头开始」那一行的 `+` ⇒ 下面恒真（假绿）');
      expect(plusEnabled, isFalse,
          reason: '★★★ 到上限时 `+` 必须**灰掉**（「开始不能超过结束」的就地体现）。'
              '★ 若这里红了 ⇒ 上界方向的提示文案变成**活代码**，'
              '必须补一条"撞上界说不能超过"的断言');

      // 灰掉时不该有提示（没改动就不打扰）
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        _claim(tester);
      }
      expect(_snackTexts(tester), isEmpty,
          reason: '★ 按钮灰掉 = 没改动 ⇒ 不该弹提示（弹了就是噪音）');
    });
  });
}
