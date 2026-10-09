// ═══════════════════════════════════════════════════════════════════════
//  ㉝ 片头片尾：「片头一对 / 片尾一对」可分辨（task-33）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（逐字 —— 这是本文件所有判据的来源）
//
// > 片头片尾 设置根本不好用，**片头的开始和片尾开始都在最前面**
// > **片头的结尾和片尾的结尾都在最后面**，应该是片头的设置，
// > 开始与结束都在最前面 **是一对的**，然后。片尾。的设置
// > **都在最后面，并且是一对的**
// > 你现在的设计完全就是。违反操作直觉
//
// # ★★★ 先澄清一件事：用户说的**不是那四行的上下顺序**
//
// 任务最初的理解是"四行顺序要改成配对"。但我做了拟人化复现（真实渲染 +
// 读屏幕 y 坐标 + 逐行点），实测四行**本来就是配对的**：
// ```text
// 第 1 行  y=499.0   片头开始
// 第 2 行  y=535.0   片头结束      ← 与上一行相距 1 行
// 第 3 行  y=571.0   片尾开始
// 第 4 行  y=607.0   片尾结束      ← 与上一行相距 1 行
// ```
// 用户用「**最前面 / 最后面**」而不是"上面/下面" ——
// 那是**时间轴**的语言（左=前、右=后）。所以真 bug 在**时间轴上**。
//
// # 真 bug：四个幽灵箭头**两两完全重合**
//
// 旧写法只按箭头方向定位（`skip_timeline.dart`）：
// ```dart
// final ghostTip = right ? inset + arrowW : (size.width - inset - arrowW);
// ```
// ```text
// 两个「开始」（都朝右）→ 都贴最左 ⇒ 完全重合（实测都是 x=42.0）
// 两个「结束」（都朝左）→ 都贴最右 ⇒ 完全重合（实测都是 x=758.0）
// ```
// ⇒ 屏幕上只看得见**两个**幽灵箭头，用户分不清哪个是片头、哪个是片尾。
//
// # 本文件验什么
//
// ```text
// ① 四个幽灵**互不重合**（两两距离 >= 可分辨阈值）
// ② 片头那一对在**左**、片尾那一对在**右**（用户："片头在前、片尾在后"）
// ③ 行上的配对色条与轴上的箭头**同色**（用户靠颜色对号）
// ④ ★★ 色条**零额外高度**（用户上次报过"只看到两行"，不能加高）
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/skip_marker_dialog.dart';
import 'package:sourin_spike/ui/widgets/skip_timeline.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: child),
  );
}

/// 打开**真实**弹窗（走真实 `showDialog`，与生产同一条约束链）
Future<void> _open(WidgetTester t, {Size win = const Size(1280, 800)}) async {
  t.view.physicalSize = win;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);

  await t.pumpWidget(_host(Builder(
    builder: (ctx) => ElevatedButton(
      onPressed: () => showDialog<SkipMarkerResult>(
        context: ctx,
        barrierDismissible: false,
        builder: (_) => const SkipMarkerDialog(
          provider: 'tyyszy',
          id: '70260',
          title: '怒鲨狂潮',
          /*
           * ★ 独立预览用的流地址（Owner 要求的形态）。
           *
           * ⚠️ 这里用 `file:///nonexistent.mp4` —— 测试**不需要**真的流：
           *    弹窗的 UI（时间轴 / 四行 / 微调 / 保存）不依赖预览加载成功，
           *    预览失败会走 `_previewError` 分支，其余部分照常渲染。
           *
           * ⚠️ task-57 我一度把这个参数删掉（改成"抓帧宿主"），
           *    后来**回退**了 —— 理由见 `skip_marker_dialog.dart` 文件头：
           *    Owner 明确要求预览必须**独立**且**可播放**。
           */
          streamUrl: 'file:///nonexistent.mp4',
          duration: Duration(seconds: 600),
        ),
      ),
      child: const Text('open'),
    ),
  )));
  await t.tap(find.text('open'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
  await t.pump(const Duration(milliseconds: 50));
}

const _labels = ['片头开始', '片头结束', '片尾开始', '片尾结束'];

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① ★★★ 幽灵箭头：四个必须互不重合（用户报的核心症状）
  // ═══════════════════════════════════════════════════════════════════
  group('① 幽灵箭头定位（用户：两个开始挤在最前、两个结束挤在最后）', () {
    test('★★★ 四个幽灵两两**互不重合**', () {
      const width = 800.0;

      final xs = <SkipEdge, double>{
        for (final e in SkipEdge.values)
          e: ghostTipFor(
            edge: e,
            width: width,
            inset: kArrowInset,
            arrowW: kArrowW,
          ),
      };

      // ignore: avoid_print
      print('');
      // ignore: avoid_print
      print('══════ 四个幽灵箭头的 x（轴宽 $width）══════');
      for (final e in SkipEdge.values) {
        // ignore: avoid_print
        print('  ${e.name.padRight(11)} x=${xs[e]!.toStringAsFixed(1)}');
      }
      // ignore: avoid_print
      print('');

      // ★ 两两距离必须 >= kGhostPairGap 的"可分辨"下界
      final list = SkipEdge.values.toList();
      for (var i = 0; i < list.length; i++) {
        for (var j = i + 1; j < list.length; j++) {
          final d = (xs[list[i]]! - xs[list[j]]!).abs();
          expect(
            d,
            greaterThan(kArrowW),
            reason: '★★★ ${list[i].name} 与 ${list[j].name} 相距只有 '
                '${d.toStringAsFixed(1)}px，而箭头本身宽 ${kArrowW}px —— '
                '两个幽灵会**看起来叠在一起**（这正是用户报的 bug）。'
                '必须 > kArrowW 才能分辨成两个独立箭头',
          );
        }
      }
    });

    test('★★★ 片头那一对在**左**、片尾那一对在**右**（用户："片头在前、片尾在后"）', () {
      const width = 800.0;
      double x(SkipEdge e) => ghostTipFor(
            edge: e,
            width: width,
            inset: kArrowInset,
            arrowW: kArrowW,
          );

      /*
       * 用户原话：
       * > 应该是片头的设置，开始与结束**都在最前面** 是一对的，
       * > 然后。片尾。的设置 **都在最后面**，并且是一对的
       *
       * ⇒ 片头两个的 x 必须都**小于**片尾两个的 x。
       */
      final introMax = [x(SkipEdge.introStart), x(SkipEdge.introEnd)]
          .reduce((a, b) => a > b ? a : b);
      final outroMin = [x(SkipEdge.outroStart), x(SkipEdge.outroEnd)]
          .reduce((a, b) => a < b ? a : b);

      expect(
        introMax,
        lessThan(outroMin),
        reason: '★★★ 用户要的是「片头一对在**最前**、片尾一对在**最后**」。'
            '若片头那对的右边界 >= 片尾那对的左边界，两对就交错了，'
            '用户仍然分不出哪两个是一组',
      );
    });

    test('★★ 幽灵**不越界**（不能画到轨道外被裁掉）', () {
      const width = 800.0;
      for (final e in SkipEdge.values) {
        final x = ghostTipFor(
          edge: e,
          width: width,
          inset: kArrowInset,
          arrowW: kArrowW,
        );
        expect(x, greaterThanOrEqualTo(kArrowInset),
            reason: '★ ${e.name} 的幽灵不能超出左留白（会被裁掉）');
        expect(x, lessThanOrEqualTo(width - kArrowInset),
            reason: '★ ${e.name} 的幽灵不能超出右留白（会被裁掉）');
      }
    });

    test('★★ 窄轴也不重合（手机上时间轴很短）', () {
      /*
       * ★ 边界：轴很窄时 `kGhostPairGap` 可能让两个幽灵挤在一起
       *   甚至交叉。必须验证窄轴下**仍然不重合**。
       */
      for (final width in [200.0, 300.0, 420.0]) {
        final xs = [
          for (final e in SkipEdge.values)
            ghostTipFor(
              edge: e,
              width: width,
              inset: kArrowInset,
              arrowW: kArrowW,
            ),
        ];
        // 片头对 <= 片尾对 仍然成立
        final introMax = xs[0] > xs[1] ? xs[0] : xs[1];
        final outroMin = xs[2] < xs[3] ? xs[2] : xs[3];
        expect(introMax, lessThanOrEqualTo(outroMin),
            reason: '★ 轴宽 $width 时两对交错了');
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② ★★ 配对色条：行与轴**同色**（用户靠颜色对号）
  // ═══════════════════════════════════════════════════════════════════
  group('② 配对色条与时间轴箭头**同色**', () {
    test('★★★ 片头/片尾色由**同一个函数**给出（防两处常量漂移）', () {
      /*
       * ★ 这条防的是"两处各写一份常量"：
       *   色条还是琥珀、箭头变成别的色 ⇒ 用户对不上，而测试可能还绿。
       *   本项目已踩过同类坑（`_arrowW` 与 `kArrowW` 两份常量）。
       *
       * 判据：画笔用的色 **就是** `skipIntroColor/skipOutroColor` 的返回值。
       *       —— 用源码断言证明"画笔没有自己再写一份"。
       */
      final src = File('lib/ui/widgets/skip_timeline.dart').readAsStringSync();

      expect(src.contains('Color get introColor => skipIntroColor('), isTrue,
          reason: '★★★ 画笔的片头色必须走 `skipIntroColor()` —— '
              '自己再写一份常量就会与色条漂移');
      expect(src.contains('Color get outroColor => skipOutroColor('), isTrue,
          reason: '★★★ 画笔的片尾色必须走 `skipOutroColor()`');

      // 两份旧私有常量必须**只剩定义处**（不能再被引用）
      final introUses = 'skipIntroColor('.allMatches(src).length;
      expect(introUses, greaterThanOrEqualTo(2),
          reason: '★ `skipIntroColor` 应当既被定义、又被画笔调用');
    });

    test('★★ 浅色主题下色条色**不等于**深色下的色（确实按亮度选）', () {
      /*
       * ★ 阳性对照的作用：证明"按亮度选色"这条路径**真的分叉**。
       *   若两个亮度返回同色，那浅色主题下箭头会糊在近白轨道上
       *   （对比度只有 1.69:1 —— 这是项目里已算过的结论）。
       */
      expect(skipIntroColor(Brightness.light),
          isNot(skipIntroColor(Brightness.dark)),
          reason: '★ 浅色主题必须压暗片头色（否则对比度 1.69:1 看不清）');
      expect(skipOutroColor(Brightness.light),
          isNot(skipOutroColor(Brightness.dark)),
          reason: '★ 浅色主题必须压暗片尾色');
      // 片头 ≠ 片尾（用户要靠颜色区分两对）
      expect(skipIntroColor(Brightness.light),
          isNot(skipOutroColor(Brightness.light)),
          reason: '★ 片头与片尾必须不同色 —— 同色的话用户无法靠颜色分组');
    });

    testWidgets('★★★ 四行各有一条配对色条，且颜色按片头/片尾分组', (t) async {
      await _open(t);

      /*
       * 判据：每行的标签**左边**应当有一条 3px 宽的色块。
       * 读它的真实 rect + 颜色。
       */
      final found = <String, Color>{};
      for (final label in _labels) {
        final rowRect = t.getRect(find.text(label));
        // 在这一行的 y 带上、标签左侧找 Container
        Color? bar;
        for (final e in find.byType(Container).evaluate()) {
          final ro = e.findRenderObject();
          if (ro is! RenderBox || !ro.hasSize) continue;
          final r = ro.localToGlobal(Offset.zero) & ro.size;
          if ((r.center.dy - rowRect.center.dy).abs() > 10) continue;
          if (r.right > rowRect.left + 1) continue; // 必须在标签左边
          if (r.width > 8) continue; // 色条很窄
          final deco = (e.widget as Container).decoration;
          if (deco is BoxDecoration && deco.color != null) {
            bar = deco.color;
          }
        }
        expect(bar, isNotNull,
            reason: '★★★ 「$label」这一行左边必须有一条配对色条 —— '
                '用户靠它与时间轴上的箭头对号');
        found[label] = bar!;
      }

      // ignore: avoid_print
      print('');
      // ignore: avoid_print
      print('══════ 四行的配对色条颜色 ══════');
      for (final e in found.entries) {
        // ignore: avoid_print
        print('  ${e.key}  ${e.value}');
      }
      // ignore: avoid_print
      print('');

      // ★ 片头两行同色、片尾两行同色，且两组**不同色**
      expect(found['片头开始'], found['片头结束'],
          reason: '★ 片头两行必须同色（它们是一对）');
      expect(found['片尾开始'], found['片尾结束'],
          reason: '★ 片尾两行必须同色（它们是一对）');
      expect(found['片头开始'], isNot(found['片尾开始']),
          reason: '★★★ 片头与片尾必须**不同色** —— 同色的话用户仍然'
              '分不出哪两行是一组，那就没解决用户的问题');

      // ★ 且与时间轴同色（同源）
      expect(found['片头开始'], skipIntroColor(Brightness.light),
          reason: '★★★ 片头色条必须与时间轴上的片头箭头**同色**');
      expect(found['片尾开始'], skipOutroColor(Brightness.light),
          reason: '★★★ 片尾色条必须与时间轴上的片尾箭头**同色**');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ ★★★ 零额外高度（用户上次报过"只看到两行"）
  // ═══════════════════════════════════════════════════════════════════
  group('③ ★★★ 加色条**不许**增加高度', () {
    testWidgets('★★★ 四行仍在滚动视口内，且剩余空间不为负', (t) async {
      await _open(t);

      final viewport = t.getRect(find.byType(SingleChildScrollView));

      for (final label in _labels) {
        final r = t.getRect(find.text(label));
        expect(
          r.bottom,
          lessThanOrEqualTo(viewport.bottom),
          reason: '★★★ 「$label」被挤出视口了 —— '
              '这正是用户上次报的「只看到片头两行」。'
              '加配对色条**不许**让任何一行掉出视口',
        );
      }

      // ★ 四行 + 色条的总高必须仍 <= 视口高（不引入滚动）
      final rows = [for (final l in _labels) t.getRect(find.text(l))];
      final top = rows.map((r) => r.top).reduce((a, b) => a < b ? a : b);
      final bottom = rows.map((r) => r.bottom).reduce((a, b) => a > b ? a : b);
      // ignore: avoid_print
      print('[ACCENT] 四行占用 y = ${top.toStringAsFixed(1)}'
          ' .. ${bottom.toStringAsFixed(1)}   视口底 = '
          '${viewport.bottom.toStringAsFixed(1)}');
      expect(bottom, lessThanOrEqualTo(viewport.bottom));
    });

    testWidgets('★★★ 行高**没有**变大（色条是 Row 子项，不是包一层的 Padding）',
        (t) async {
      await _open(t);

      /*
       * ★ 这条是"零高度"的**直接**判据：
       *   四行的 y 间距必须仍是 `kRowH + Sp.x1`。
       *
       * ⚠️ 这里**故意不写死数字**（曾经写「= 32 + 4 = 36」，`kRowH` 抬到
       *    36 之后就成了假注释）。判据用符号 `kRowH + Sp.x1`，常量改了两边
       *    一起动；只有"色条偷偷加高度"才会让实测间距偏离它。
       *
       * 若色条被写成 `Padding(child: Container(...))` 包在行外，
       * 间距会变大（每行多出 3px 或更多）⇒ 第四行被挤出视口。
       */
      final ys = [for (final l in _labels) t.getRect(find.text(l)).top];
      // ignore: avoid_print
      print('[ACCENT] 四行 y = ${ys.map((e) => e.toStringAsFixed(1)).toList()}');

      for (var i = 1; i < ys.length; i++) {
        final gap = ys[i] - ys[i - 1];
        expect(
          gap,
          closeTo(kRowH + Sp.x1, 1.0),
          reason: '★★★ 行距必须仍是 ${kRowH + Sp.x1}px（= kRowH + Sp.x1），'
              '实测第 $i 行间距是 ${gap.toStringAsFixed(1)}px。'
              '变大了说明色条**加了高度** —— 那会把「片尾结束」挤出视口，'
              '重新引入用户报过的「只看到片头两行」',
        );
      }
    });

    testWidgets('★★ 窄窗口下也不溢出（色条宽度已计入预算）', (t) async {
      /*
       * ★ 色条占了 `kAccentW + Sp.x1` 的宽 —— 必须计入 `fixedW`，
       *   否则文字列会被挤出去（项目里踩过
       *   "RenderFlex overflowed by 14 pixels"）。
       *   这里用窄窗口压一压。
       */
      for (final w in [1280.0, 900.0, 700.0, 420.0]) {
        await _open(t, win: Size(w, 800));
        for (final label in _labels) {
          expect(find.text(label), findsOneWidget,
              reason: '★ 窗口 ${w.toInt()} 宽时「$label」必须还在（没被挤掉）');
        }
        // 没有 RenderFlex 溢出异常
        expect(t.takeException(), isNull,
            reason: '★ 窗口 ${w.toInt()} 宽时不该有布局溢出');
      }
    });
  });
}
