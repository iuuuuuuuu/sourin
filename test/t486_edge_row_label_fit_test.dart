// ═══════════════════════════════════════════════════════════════════════
//  t486 行为级：四行标签在手机宽度下**不得**被省略
// ═══════════════════════════════════════════════════════════════════════
//
// # 这条测试要钉住的真机缺陷（task-96 取证）
//
// 手机（1080x2400 @420dpi，逻辑宽 411）上，四个端点一旦设了值，
// 四行标签**全部**渲染成 `片…` —— 只画出第一个字。
// 像素取证：标签列墨迹宽 **144px → 68px**（-52.8%）。
//
// 根因：`_EdgeRow` 里 `labelW = textSpace * 72/(72+76)` —— **按比例**分。
// 值一设上，`fixedW` 变大 ⇒ `textSpace` 变小 ⇒ `labelW` 被压到 45px，
// 而四个汉字要 56px（`FontSizes.sm = 14`）。
//
// # 为什么不能只断言"源码里改成按需分配了"
//
// 那是**语法层**断言（lesson #562：一次让功能变强的重构会把它判红，
// 而真正的回归它又抓不住）。这里断言的是**渲染层**的性质：
// 标签的 `RenderParagraph.didExceedMaxLines` —— 这正是驱动
// `TextOverflow.ellipsis` 画那三个点的**同一个**布尔量。
//
// ★ 仪器自检（本文件必须自己证明尺子灵敏）：
//   最后一组在**极窄**宽度下断言标签**确实**被省略 ——
//   若那里也报"没省略"，说明这条测试永远会绿，等于没有守卫。
//
// ⚠️ 本仓纪律：断言必须与证据**同层**。
//    真机像素是最终证据（`.probe\t471_label_truncate.txt`）；
//    这里用 `didExceedMaxLines` 把同一条性质搬进自动化测试，
//    这样下次谁再把分配改回"按比例"，`flutter test` 就会红。
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/widgets/skip_marker_dialog.dart';

/// 与 `t462` 同构的宿主 —— 生产外壳的**最小**复刻
Widget _host(Widget child) {
  final theme = FTheme.neutral.light.desktop;
  return MaterialApp(
    theme: theme.toApproximateMaterialTheme(),
    builder: (context, c) => FTheme(data: theme, child: c ?? const SizedBox()),
    home: child,
  );
}

const _labels = ['片头开始', '片头结束', '片尾开始', '片尾结束'];

/// 在**捕获窗口**内执行 [body]：把渲染异常正文记进 [sink]，并照旧转发
///
/// ★ 为什么必须从 `FlutterError.onError` 取正文：
///   同一个 `pump` 里抛出**多条**时，`takeException()` 只给一句
///   ```text
///   Multiple exceptions (2) were detected during the running of the current
///   test, and at least one was unexpected.
///   ```
///   —— 正文全丢（第一次改完就是这样：sink 里只有这一句，
///   而我们要断言的恰恰是正文里的 `overflowed by N pixels` 与出错位置）。
///
/// ★ 转发给 `prev` 是**刻意**的：flutter_test 自己的异常账本不受影响，
///   本文件只是"顺带记一份"。
Future<void> _guard(
  List<String> sink,
  Future<void> Function() body,
) async {
  final prev = FlutterError.onError;
  FlutterError.onError = (details) {
    sink.add(details.exceptionAsString().split('\n').first);
    prev?.call(details);
  };
  try {
    await body();
  } finally {
    FlutterError.onError = prev;
  }
}

/// 泵帧，并把**被吞掉的异常**逐条记进 [sink]
///
/// # 为什么不能写 `while (tester.takeException() != null) {}`
///
/// `takeException()` 是**取走即清除** —— 写成一个空循环等于把整条
/// 渲染异常通道静音。这不是理论问题：本文件第一次跑的时候，
/// 极窄 300 那一组抛了
/// ```text
/// A RenderFlex overflowed by 37 pixels on the right.
///   Row Row:...skip_marker_dialog.dart:2203:16   ← 顶部徽章
/// ```
/// 而测试**照绿**（读数见 `.probe\t486_run.txt`）。
/// ⇒ 一个吞异常的 helper 就是**掩盖布局回归的通道**：
///   将来谁再引入一个溢出，同样不会红。
Future<void> _pumpDrain(WidgetTester tester, int frames, List<String> sink) =>
    _guard(sink, () async {
      for (var i = 0; i < frames; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        // 取走 = 不再让 flutter_test 在收尾时重复报；断言由本文件自己做
        while (tester.takeException() != null) {}
      }
    });

/// `pumpWidget` 也要进捕获窗口 —— 首帧的异常同样会进 flutter_test 的账本
Future<void> _pumpWidgetDrain(
  WidgetTester tester,
  Widget w,
  List<String> sink,
) =>
    _guard(sink, () => tester.pumpWidget(w));

/// 把四个端点都设上值 —— 这是缺陷的**触发条件**
///
/// ⚠️ 未设置时 `labelW` 会触到上限 72，四行完好；
///    一设值 `fixedW` 变大（多了清除按钮），缺陷才现形。
///    所以测试**必须**先设值，否则它会假绿。
///
/// ⚠️⚠️ **每一次 pump 都必须走 `_pumpDrain`**。
///    溢出是在点 `+` 之后的那一帧抛的；第一版把 4 次 tap 的 pump
///    写在外面（用裸 `tester.pump`），异常就被 flutter_test 记进
///    待处理账本，随后被 `takeException()` 悄悄取走 ⇒ sink 里 0 条，
///    断言 `ovf isNotEmpty` 反而红。**捕获窗口要覆盖异常真正发生的那一帧。**
Future<void> _setAllFour(WidgetTester tester, List<String> sink) async {
  final plus = find.byIcon(Icons.add);
  for (var i = 0; i < 4; i++) {
    await tester.tap(plus.at(i), warnIfMissed: false);
    await _pumpDrain(tester, 1, sink);
  }
  await _pumpDrain(tester, 8, sink);
}

/// 溢出类异常（`RenderFlex overflowed by N pixels`）
List<String> _overflows(List<String> caught) =>
    caught.where((e) => e.contains('overflowed')).toList();

/// 打印本组捕获到的全部异常 —— 让"没有异常"和"没在量"可区分
void _reportCaught(String group, List<String> caught) {
  if (caught.isEmpty) {
    // ignore: avoid_print
    print('T486|$group 捕获异常 0 条');
    return;
  }
  // ignore: avoid_print
  print('T486|$group 捕获异常 ${caught.length} 条：');
  for (final e in caught) {
    // ignore: avoid_print
    print('T486|    $e');
  }
}

/// 读出每个标签的「可用宽 / 实际需要宽 / 是否被省略」
///
/// 这是本文件的**尺子**。三个读数一起报，是为了让失败时能直接看出
/// 是"宽度不够"还是"根本没量到"。
List<String> _probeLabels(WidgetTester tester) {
  final out = <String>[];
  for (final label in _labels) {
    final f = find.text(label);
    if (f.evaluate().isEmpty) {
      out.add('$label MISSING');
      continue;
    }
    final rp = tester.renderObject<RenderParagraph>(f);
    final avail = rp.constraints.maxWidth;
    final need = rp.getMaxIntrinsicWidth(double.infinity);
    final clipped = rp.didExceedMaxLines;
    out.add('$label avail=${avail.toStringAsFixed(1)} '
        'need=${need.toStringAsFixed(1)} '
        '${clipped ? "CLIPPED" : "fits"}');
  }
  return out;
}

/// 手机逻辑宽 411（1080 / 2.625）—— 真机缺陷就是在这个宽度上出现的
const _phone = Size(1080 / 2.625, 2400 / 2.625);

void main() {
  group('t486 四行标签在手机宽度下不得被省略', () {
    testWidgets('★ 手机宽度（1080x2400 @2.625）设满四个值后，标签全部完整',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);

      final caught = <String>[];
      await tester.pumpWidget(_host(
        const SkipMarkerDialog(
          provider: 'demo',
          id: 't486',
          title: 't486 标签完整性',
          streamUrl: '',
          duration: Duration(minutes: 10),
        ),
      ));
      await _pumpDrain(tester, 14, caught);

      await _setAllFour(tester, caught);

      final rows = _probeLabels(tester);
      // ignore: avoid_print
      print('T486|手机 ${_phone.width.toStringAsFixed(1)} 逻辑宽：');
      for (final r in rows) {
        // ignore: avoid_print
        print('T486|  $r');
      }
      _reportCaught('手机', caught);

      final clipped = rows.where((r) => r.contains('CLIPPED')).toList();
      expect(
        clipped,
        isEmpty,
        reason: '★★★ 真机缺陷：设满四个值后标签被渲染成 `片…`。'
            '四行标签必须完整显示 —— 若这里红了，说明 `_EdgeRow` 的宽度'
            '分配又回到了"按 72:76 比例瓜分"（值一设上就把标签压到 45px，'
            '而四个汉字要 56px）。实测读数见上面 T486| 那几行。',
      );

      // ★ 手机宽度是**真机**宽度 ⇒ 这里不许有任何溢出
      //   （`t471` 真机取证：1080x2400 @420dpi 上四行、徽章都完好）
      expect(
        _overflows(caught),
        isEmpty,
        reason: '★ 手机宽度下不该有 RenderFlex 溢出 —— '
            '真机取证时徽章与四行都是完好的。'
            '若有溢出，说明某个 Row 在 411 逻辑宽下放不下。',
      );
    });

    testWidgets('★ 桌面宽度下结果不变（不许为修手机而改坏桌面）',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final caught = <String>[];
      await tester.pumpWidget(_host(
        const SkipMarkerDialog(
          provider: 'demo',
          id: 't486d',
          title: 't486 桌面',
          streamUrl: '',
          duration: Duration(minutes: 10),
        ),
      ));
      await _pumpDrain(tester, 14, caught);

      await _setAllFour(tester, caught);

      final rows = _probeLabels(tester);
      // ignore: avoid_print
      print('T486|桌面 1280 逻辑宽：');
      for (final r in rows) {
        // ignore: avoid_print
        print('T486|  $r');
      }
      _reportCaught('桌面', caught);

      expect(rows.where((r) => r.contains('CLIPPED')), isEmpty,
          reason: '★ 桌面下标签本来就没问题，改动不许把它弄坏');
      // 桌面下应当**没有任何一行**因为宽度不足而缩水
      expect(rows.where((r) => r.contains('MISSING')), isEmpty,
          reason: '★ 四行都要在（桌面高度足够，不该有行被裁掉）');
      expect(_overflows(caught), isEmpty,
          reason: '★ 桌面 1280 逻辑宽下不该有 RenderFlex 溢出');
    });

    testWidgets('★★ 仪器自检：极窄宽度下标签**确实**会被省略（尺子必须灵敏）',
        (WidgetTester tester) async {
      /*
       * 这一条是**本文件的阳性对照**。
       *
       * 若没有它，上面两条断言有可能只是"永远为真"（比如
       * `find.text` 找不到、或 `didExceedMaxLines` 恒为 false），
       * 那样的话真缺陷回来了测试也不会红。
       *
       * 宽度取 300 逻辑 —— 桌面弹窗最小宽度附近，四行必然挤。
       */
      tester.view.physicalSize = const Size(300, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final caught = <String>[];
      await tester.pumpWidget(_host(
        const SkipMarkerDialog(
          provider: 'demo',
          id: 't486n',
          title: 't486 极窄',
          streamUrl: '',
          duration: Duration(minutes: 10),
        ),
      ));
      await _pumpDrain(tester, 14, caught);

      await _setAllFour(tester, caught);

      final rows = _probeLabels(tester);
      // ignore: avoid_print
      print('T486|极窄 300 逻辑宽（阳性对照，期望看到 CLIPPED）：');
      for (final r in rows) {
        // ignore: avoid_print
        print('T486|  $r');
      }
      _reportCaught('极窄 300', caught);

      // 至少有一个标签被省略 —— 证明 `didExceedMaxLines` 这条尺子会动
      expect(
        rows.where((r) => r.contains('CLIPPED')),
        isNotEmpty,
        reason: '★★ 阳性对照失败：300 逻辑宽下四行**本该**挤到省略，'
            '这里却没量到 CLIPPED ⇒ 说明 `didExceedMaxLines` 这条尺子'
            '在本环境不灵敏，上面两条"没被省略"的断言因此**没有证明力**。'
            '（这正是"阴性读数需要一个已被证明灵敏的仪器"那条纪律。）',
      );

      /*
       * ★★ 已知缺陷（不是本文件引入的，也不是本次修复引入的）：
       *
       * 极窄 300 逻辑宽下，**顶部徽章**那一行的 `Row`
       * （`skip_marker_dialog.dart:2203`，外层是
       * `Row[ Expanded(Wrap(badge, badge)), Sp.x2, SizedBox(32, IconButton) ]`）
       * 会报 `A RenderFlex overflowed by 37 pixels on the right.`
       *
       * 这里**刻意把它钉住**而不是忽略：
       *   · 溢出**只允许**出现在极窄组（手机 411 / 桌面 1280 组已各自断言 0 溢出）
       *   · 且只允许是**这一处**（`:2203` 的徽章 Row）、**这一个数值**
       * ⇒ 将来谁在别处引入溢出，这里会红；谁真把徽章修好了，
       *   这里也会红，提醒把它改成"零溢出"。
       *
       * ⚠️ 判据必须用**正文**（`overflowed by 37 pixels` + `:2203`），
       *    不能用 `takeException()` 的返回值 —— 多条异常时它只给
       *    「Multiple exceptions (2) were detected…」，正文全丢。
       */
      final ovf = _overflows(caught);
      expect(
        ovf,
        isNotEmpty,
        reason: '★ 极窄组的阳性对照（标签 CLIPPED）已成立；'
            '若这里连一条溢出都没有，说明异常通道没接上，'
            '本文件对"手机/桌面零溢出"的两条断言也就没有证明力。',
      );
      for (final e in ovf) {
        expect(
          e.contains('overflowed by 37 pixels'),
          isTrue,
          reason: '★★ 极窄组已知只有「徽章 Row 溢出 37px」这一条。'
              '出现了别的溢出 ⇒ 是**新**的布局回归，必须查。实测：$e',
        );
      }
      expect(
        caught.where((e) => !e.contains('overflowed')).toList(),
        isEmpty,
        reason: '★ 非溢出类异常不该出现在本组。',
      );
    });
  });
}
