@Tags(['native-media'])
library;

// ══════════════════════════════════════════════════════════════════════
//  t92 行为级：底栏按钮行在「单行真放得下」之前**必须**换形，不许画出边界
// ══════════════════════════════════════════════════════════════════════
//
// # 这条测试要钉住的缺陷（task-33 真渲染探针取证，不是静态推断）
//
// 播放页底栏的按钮行是二选一：宽屏 `row`（14 项，行内带 `Spacer`）/
// 窄屏 `compactRow`（三行，第三行自带横向滚动兜底）。选谁由
// `player_page.dart` 里的 `fits` 决定。
//
// 缺陷期判据是 `fits = 约束有界 && 约束宽 >= _kBottomBarFitWidth(480)`：
// 它只回答「约束有界吗」，**不回答「单行真放得下吗」**。
// 900 dp 视口（媒体页在 900 处切左右分栏 ⇒ 底栏可用宽只剩 528 dp）
// 走的是 `row`：`Spacer`（`Expanded`）被压到 0，行仍按**固有宽 771.43**
// 布局并**画出边界**，超出的按钮被祖先 `Stack` 裁掉 —— 用户看到的是
// 按钮凭空消失，而且没有滚动条可滑。
//
// 读数（`.probe/android_fix/diag_bar11.txt`，真渲染探针，textScale 1.0）：
// ```text
// 视口    底栏可用宽   行固有宽   溢出
//  800      768.00     771.43     3.4 px
//  900      528.00     771.43   243   px   ← 最窄（媒体页在 900 处切分栏）
//  960      588.00     771.43   183   px
// 1024      652.00     771.43   119   px
// 1152      774.40     771.43     0
// 1280      864.00     771.43     0
// ```
// ⇒ 死区是「底栏可用宽 ∈ [528, 771.43)」，对应视口约 [900, 1152) dp。
// ★ 溢出量**不单调**：1024 的 119 < 960 的 183（因为可用宽在 900 处
//   反而被分栏压到最小）—— 所以只测一个宽度是不够的。
//
// # 为什么这一条以前抓不到
// `RenderFlex` 的溢出**只是 debug 诊断**（release 里静默裁切、无任何提示），
// 而当时所有测试都跑在 1280x800（可用 864 > 771.43）⇒ 永远不触发。
// ⇒ 本文件是**唯一**覆盖 [528, 830) 这一段的守卫。
//
// # 断言与证据同层（不用语法层断言）
// 不写「源码里阈值改成 830 了」那种断言（lesson #562：一次让功能变强的
// 重构会把它判红，而真正的回归它又抓不住）。这里断言渲染层的三件事：
// ```text
// ① FlutterError.onError 里没有 overflowed（Flutter 自己的溢出诊断）
// ② 按钮行 maxRight <= avail（真几何：最右子项右缘不出行宽）
// ③ 换形确实发生了（compactRow 专属的 Icons.more_vert 在、
//    宽屏专属的 Icons.tune 不在）
// ```
//
// ★ 仪器自检（本文件必须自己证明尺子灵敏）：
//   ① 那一组在 1280 dp 断言走的是**宽屏**那一支（`Icons.tune` 在、
//   `Icons.more_vert` 不在）—— 若它报「换形了」，说明 finder 判据写错，
//   ② 的几何断言也就失去了意义。
// ★ 红度证明：把 `_kBottomBarRowWidth` 改回 480 ⇒ 900/1024 两组的
//   ① 与 ② 一起红（读数见上表）。
//
// ⚠️ 视口必须用 `tester.view.physicalSize` / `devicePixelRatio`，
//    **不能**用 `setSurfaceSize` —— 后者只改布局约束、不改 FlutterView
//    的 metrics，两者打架会让修好的代码也报红（bottom_bar_fit_test.dart:71-87
//    用 3 个假红换来的铁律）。
import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/media_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

/// 底栏某一根**横向** `RenderFlex` 的真几何
class _BarRow {
  _BarRow(this.avail, this.size, this.maxRight, this.kids);

  /// 它拿到的约束上限（`constraints.maxWidth`）
  final double avail;

  /// 它自己的宽度
  final double size;

  /// 最右子项的右缘（`offset.dx + size.width` 的最大值）
  final double maxRight;

  /// 子项个数
  final int kids;

  @override
  String toString() => 'avail=' +
      avail.toStringAsFixed(2) +
      ' size=' +
      size.toStringAsFixed(2) +
      ' maxRight=' +
      maxRight.toStringAsFixed(2) +
      ' kids=' +
      kids.toString();
}

/// 收集渲染树里所有「横向 `RenderFlex` 且 creator 链含 `_BottomBar`」的行
///
/// 判据与 `.probe/android_fix/zz_diag_bar11_test.dart:50-99` 逐字同源：
/// 只看 `debugCreator` 链，不看 widget 类型（`_BottomBar` 是私有的）。
///
/// ⚠️ 必须在**首帧**量：`_load()` 挂在 `addPostFrameCallback` 上，
///    flutter_tester 里 `sourin_core.dll` 加载不了 ⇒ `_load()` 必失败
///    ⇒ `_error` 置上 ⇒ **底栏整条消失**（`t63_shot_ui_test.dart:99-110`
///    记过同一件事）。
List<_BarRow> _barRows(WidgetTester t) {
  final out = <_BarRow>[];

  void walk(RenderObject ro, int depth) {
    if (ro is RenderFlex && ro.direction == Axis.horizontal) {
      final dc = ro.debugCreator;
      if (dc is DebugCreator &&
          dc.element.debugGetCreatorChain(30).contains('_BottomBar')) {
        var maxRight = 0.0;
        var kids = 0;
        ro.visitChildren((RenderObject c) {
          if (c is RenderBox) {
            final pd = c.parentData;
            final off = pd is FlexParentData ? pd.offset.dx : 0.0;
            final r = off + c.size.width;
            if (r > maxRight) maxRight = r;
            kids++;
          }
        });
        out.add(_BarRow(ro.constraints.maxWidth, ro.size.width, maxRight, kids));
      }
    }
    if (depth < 45) {
      ro.visitChildren((RenderObject c) => walk(c, depth + 1));
    }
  }

  for (final rv in t.binding.renderViews) {
    walk(rv, 0);
  }
  return out;
}

/// 在**捕获窗口**内执行 [body]：渲染异常正文记进 [sink]，并照旧转发
///
/// ★ 逐字照抄 `t486_edge_row_label_fit_test.dart:49-76`（连同它踩过的坑）：
///   同一个 pump 抛**多条**时 `takeException()` 只给一句
///   `Multiple exceptions (2) were detected…` —— 正文全丢，
///   而我们要断言的恰恰是正文里的 `overflowed by N pixels`。
/// ★ 转发给 prev 是**刻意**的：flutter_test 自己的异常账本不受影响。
Future<void> _guard(List<String> sink, Future<void> Function() body) async {
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

/// 认领一次 pump 期间积压的环境异常（无核心环境下的 FFI 异常等）
void _claim(WidgetTester t) {
  while (t.takeException() != null) {}
}

/// 挂载**真实** `MediaPage`（⇒ 真实 `PlayerPage` ⇒ 真实 `_BottomBar`）
///
/// ★ 用 `MediaPage` 而不是直接挂 `PlayerPage`：底栏最窄的那一刻就是
///   `media_page.dart:703` 的 `final wide = mq.size.width >= 900;` 把视口
///   切成分栏之后（视频列只剩 视口−32−detailW）—— 直接挂 PlayerPage 会
///   漏掉这个「越宽反而越窄」的拐点（900 的可用宽 528 < 800 的 768）。
Future<void> _mountMedia(WidgetTester t, double w, double h) async {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = Size(w, h);
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildLightMaterialTheme(AppTheme.themeFor(Brightness.light)),
    home: const MediaPage(provider: 'cycani', id: '3862', title: '无题'),
  ));
}

/// 推帧，把后续的渲染异常也收进 [sink]（首帧之后的都算补充证据）
Future<void> _moreFrames(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 200));
  }
}

/// 首帧的 widget 层判据（**必须**与 `_barRows` 同一时刻取）
///
/// ⚠️ 这些计数**不能**等 `_moreFrames` 之后再取：`_load()` 挂在
///    `addPostFrameCallback` 上，flutter_tester 里 `sourin_core.dll`
///    加载不了 ⇒ `_load()` 必失败 ⇒ `_error` 置上 ⇒ 底栏整条消失
///    （`t63_shot_ui_test.dart` 的 `frames: 1` 就是为同一件事）。
///    第一版 t92 正是在 8 帧之后才做 finder 断言 ⇒ 五条全红在
///    「Found 0 widgets」—— 那是**仪器**问题，不是被测代码的问题。
class _Ui {
  _Ui(this.shot, this.cam, this.gear, this.tune, this.more);

  /// `tooltip '截图'`：宽屏支与 compactRow **都有** ⇒ 通用阳性对照
  final int shot;

  /// `Icons.photo_camera`：两支都有
  final int cam;

  /// `Icons.settings`：两支都有
  final int gear;

  /// `Icons.tune`：**只有**宽屏支有（compactRow 的 t68 E③ 要求它是 0）
  final int tune;

  /// `Icons.more_vert`：**只有** compactRow 有（`player_page.dart:11630`）
  final int more;

  @override
  String toString() =>
      'shot=' + shot.toString() + ' cam=' + cam.toString() + ' gear=' +
          gear.toString() + ' tune=' + tune.toString() + ' more=' +
          more.toString();
}

/// 一条宽度档位的完整取证：首帧几何 + 首帧 widget 判据 + 溢出正文
Future<({List<_BarRow> rows, List<String> ovf, _Ui ui})> _probe(
  WidgetTester t,
  double w,
) async {
  final sink = <String>[];
  late List<_BarRow> rows;
  late _Ui ui;
  await _guard(sink, () async {
    await _mountMedia(t, w, 900);
    // ★ 首帧：底栏一定还在（`_load()` 的 post-frame 回调还没跑）
    rows = _barRows(t);
    ui = _Ui(
      find.byTooltip('截图').evaluate().length,
      find.byIcon(Icons.photo_camera).evaluate().length,
      find.byIcon(Icons.settings).evaluate().length,
      find.byIcon(Icons.tune).evaluate().length,
      find.byIcon(Icons.more_vert).evaluate().length,
    );
    await _moreFrames(t);
  });
  _claim(t);
  return (
    rows: rows,
    ovf: sink.where((s) => s.contains('overflowed')).toList(),
    ui: ui,
  );
}

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });
  setUp(() => RemoteBridge.instance.stop());
  tearDown(() => RemoteBridge.instance.stop());

  testWidgets('t92 ① 仪器自检：1280 dp 走**宽屏**那一支（tune 在 / more_vert 不在）',
      (t) async {
    final r = await _probe(t, 1280);

    expect(r.ui.shot, 1,
        reason: '★★ 阳性对照（首帧）：tooltip 截图 在宽屏支与 compactRow '
            '**都有** —— 若这条不过，说明底栏压根没渲染（仪器问题），'
            '下面所有几何断言都没有意义。实测 ' + r.ui.toString());
    expect(r.ui.tune, 1,
        reason: '★ 宽屏专属：Icons.tune 只在 row 里（compactRow 的 t68 E③ '
            '要求它是 0）⇒ 它在一个就证明走的是宽屏那一支。实测 ' +
            r.ui.toString());
    expect(r.ui.more, 0,
        reason: '★ more_vert 是 compactRow 专属（player_page.dart:11630）。实测 ' +
            r.ui.toString());

    expect(r.ovf, isEmpty, reason: '★ 1280x800 可用 864.00 > 固有 771.43，'
        '修前修后都不该溢出（这是「没修坏」的对照）');
    final wide = r.rows.where((x) => x.kids >= 3 && x.avail.isFinite).toList();
    expect(wide, isNotEmpty, reason: '★ 至少量到一根「有内容的、约束有界的」行');
    for (final x in r.rows.where((x) => x.avail.isFinite)) {
      expect(x.maxRight, lessThanOrEqualTo(x.avail + 0.01),
          reason: '★ 最右子项右缘不得超出行宽：' + x.toString());
    }
    // ignore: avoid_print
    print('[t92] 1280 rows=' + r.rows.map((x) => x.toString()).join(' | '));
  });

  for (final w in <double>[900, 960, 1024, 1152]) {
    testWidgets('t92 ② 视口 ' + w.toInt().toString() + ' dp：换形、不画出边界',
        (t) async {
      final r = await _probe(t, w);
      final tag = '[' + w.toInt().toString() + '] ';

      expect(r.ovf, isEmpty,
          reason: '★ 这一档**不许**有 RenderFlex 溢出（缺陷期读数：900 ⇒ 243 px、'
              '960 ⇒ 183 px、1024 ⇒ 119 px）。实测：' + r.ovf.join(' / '));
      expect(r.ui.shot, 1,
          reason: '★★ 阳性对照（首帧）：截图按钮必须在（两支都有）。实测 ' +
              r.ui.toString());
      expect(r.ui.more, 1,
          reason: '★ 必须换形到 compactRow —— 「更多」是它专属的入口。实测 ' +
              r.ui.toString());
      expect(r.ui.tune, 0,
          reason: '★ 宽屏专属的 tune 不许在（它在「更多」菜单里是**文字**项，'
              '没有图标）。实测 ' + r.ui.toString());

      final measured = r.rows.where((x) => x.avail.isFinite).toList();
      expect(measured, isNotEmpty, reason: '★ 必须量到底栏（否则断言是空转）');
      expect(measured.where((x) => x.kids >= 3).length, greaterThanOrEqualTo(1),
          reason: '★ 至少要有一根有内容的行（0 子项的行是空转）');
      for (final x in measured) {
        expect(x.maxRight, lessThanOrEqualTo(x.avail + 0.01),
            reason: '★ ' + tag + '最右子项右缘不得超出行宽：' + x.toString());
        expect(x.size, lessThanOrEqualTo(x.avail + 0.01),
            reason: '★ ' + tag + '行自身宽度不得超出可用宽：' + x.toString());
      }
      // ignore: avoid_print
      print('[t92] ' + tag + 'rows=' + r.rows.map((x) => x.toString()).join(' | '));
    });
  }
}
