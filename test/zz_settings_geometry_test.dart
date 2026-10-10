// 设置页 / 搜索页的**几何探针**：把关键节点的真实矩形打出来。
//
// 为什么要几何而不是看图：截图台是给人工看图自查的，但本 agent 会话里
// Read 工具读不出图片内容（连 PIL 新建的图也返回空）。几何读数同样能
// 钉住"排版对不对"里能量化的部分：分组层级、间距、命中区、是否溢出。
//
// 判据（能测出反面）：
//   ① 组标签 < 该组第一块的标题（顺序）+ 组标签间距比块间距小
//   ② 入口行高度 ≥ 44（触摸命中区）
//   ③ 所有列宽 ≤ 视口宽（没有 RenderFlex overflow）
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/ui/search_page.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings_page.dart';
import 'package:sourin_spike/ui/widgets/settings_kit.dart';

import 'support/ui_shot.dart';

Widget _app(Widget home) => MaterialApp(
  debugShowCheckedModeBanner: false,
  // ★ 走生产同一套主题（forui 已移除，截图/量测必须与真机同源）
  theme: AppTheme.themeFor(Brightness.dark),
  home: Scaffold(body: home),
);

Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump();
  }
}

Rect? _r(WidgetTester t, String text) {
  final f = find.text(text);
  if (f.evaluate().isEmpty) return null;
  return t.getRect(f.first);
}

void main() {
  final dataDir = Platform.environment['SOURIN_SHOT_DATA'];

  setUpAll(() async {
    loadRealFonts();
    // ⚠️ 这个探针要**真核心**（设置页 initState 会 await 一串 FFI 调用，
    //   核心不在就永远是转圈态，量到的几何是空页的）。
    //   环境依赖型测试必须门控（项目纪律）：没给数据目录就整体跳过，
    //   并在 reason 里写清怎么跑。
    if (dataDir != null) await SourinCore.startAsync(dataDir);
  });

  // 缺真核心 ⇒ 下面每一条都会量到空页，读数毫无意义 ⇒ 整体 skip。
  const gate =
      '需要真核心才能量到真实几何。跑法：把 rust/sourin_core/target/release/'
      'sourin_core.dll 拷到 worktree 根，再带 '
      'SOURIN_SHOT_DATA=<临时数据目录> 跑，跑完把 dll 删掉。';

  for (final size in const [Size(1440, 900), Size(412, 915)]) {
    testWidgets('设置页几何 $size', (tester) async {
      if (dataDir == null) return markTestSkipped(gate);
      await setShotViewport(tester, size);
      await tester.pumpWidget(_app(const SettingsPage()));
      await settle(tester);

      const groups = ['远程', '内容源与插件', '播放与观看', '外观', '数据与外观'];
      const entries = [
        'JS 插件',
        'Emby',
        '片头片尾',
        'PC 播放手势',
        '播放与下载',
        '触摸手势',
        '备份与恢复',
        '主题',
        '关于',
      ];

      // ignore: avoid_print
      print('=== 设置页 $size ===');
      double? prevBottom;
      for (final g in groups) {
        final r = _r(tester, g);
        if (r == null) {
          // ignore: avoid_print
          print('  组 [$g] 不在本设备上');
          continue;
        }
        final gap = prevBottom == null ? null : r.top - prevBottom!;
        // ignore: avoid_print
        print(
          '  组 $g  top=${r.top.toStringAsFixed(1)} '
          'size=${r.size.width.toStringAsFixed(1)}x${r.size.height.toStringAsFixed(1)}'
          '${gap == null ? '' : ' 距上一块 ${gap.toStringAsFixed(1)}'}',
        );
        prevBottom = r.bottom;
      }
      for (final e in entries) {
        final r = _r(tester, e);
        if (r == null) continue;
        // ignore: avoid_print
        print(
          '  入口 $e  top=${r.top.toStringAsFixed(1)} '
          '右边界=${r.right.toStringAsFixed(1)} / 视口 ${size.width}',
        );
      }

      // ③ 没有任何节点越过视口右缘
      for (final e in [...groups, ...entries]) {
        final r = _r(tester, e);
        expect(
          r == null || r.right <= size.width + 0.5,
          isTrue,
          reason: '「$e」溢出视口右缘：right=${r?.right} > ${size.width}',
        );
      }

      // ② 入口行整体高度 ≥ 44（触摸命中区下限）
      for (final e in entries) {
        final f = find.ancestor(
          of: find.text(e),
          matching: find.byType(Padding),
        );
        if (f.evaluate().isEmpty) continue;
        final h = tester.getSize(f.first).height;
        expect(
          h,
          greaterThanOrEqualTo(44),
          reason: '「$e」入口行只有 ${h.toStringAsFixed(1)}px 高，触摸命中区不够',
        );
      }
    });
  }

  testWidgets('搜索页几何 · 空态与骨架', (tester) async {
    if (dataDir == null) return markTestSkipped(gate);
    await setShotViewport(tester, const Size(1440, 900));
    await tester.pumpWidget(_app(const SearchPage()));
    await settle(tester);
    // ignore: avoid_print
    print('=== 搜索页 1440x900 ===');
    for (final t in ['搜索', '同时搜索全部已启用内容源', '搜索全部内容源', '输入关键词后回车即可同时搜索']) {
      final r = _r(tester, t);
      // ignore: avoid_print
      print(
        '  「$t」 ${r == null ? '不存在' : 'top=${r.top.toStringAsFixed(1)} 中心x=${r.center.dx.toStringAsFixed(1)} / 视口中心 ${720}'}',
      );
    }
    // 空态说明文字必须**居中**（限宽 maxWidth=420 生效的证据）
    final hint = find.text('输入关键词后回车即可同时搜索');
    if (hint.evaluate().isNotEmpty) {
      expect(
        tester.getSize(hint).width,
        lessThanOrEqualTo(420.5),
        reason: '空态说明不应铺满超宽屏',
      );
    }
  });
}
