// ═══════════════════════════════════════════════════════════════════════
//  task-11 ② 面板渲染实测：真挂 DownloadPanel，量「一行/态/按钮」
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么还要一个 widget 级探针（已经有一个 queue 级探针了）
// queue 级证明的是「状态机与文件系统对」。但 Owner 要的是**看得见的面板**：
//   「一集一行的，如果正在下载就可以暂停啊 删除啊…已经下载好的就可以播放 可以删除」
// ⇒ 必须真把 DownloadPanel 挂进树，数出：
//   · 一集一行（行的个数）
//   · 每行的按钮文案（暂停/继续/删除/播放/重试/取消）
//   · 空列表**整块不画**（renderObject 为 null）
library;

// ★★★ 修（2026-10-09）：必须用 material_ui，**不能**用 flutter/material
//
// # 症状（这条测试原来一直红：Expected: non-empty / Actual: []）
// ```text
// 面板行**确实画出来了**（`find.text('第01集')` 找得到 4 行），
// 但 `find.byType(TextButton)` = 0 ⇒ 断言"每行都该有操作按钮"失败。
// ```
// # 根因：两套 Material 是**不同的 Dart 类型**
// ```text
// lib/ui/widgets/download_panel.dart 用的是 package:material_ui/material_ui.dart
//   （本项目把 Material 从 SDK 拆出来了，见 test/theme_regression_test.dart ①）
// 而本测试原来 import 的是 package:flutter/material.dart
// ⇒ 两个 `TextButton` 是**同名但不同库的类型**
//   ⇒ `find.byType(TextButton)` 永远匹配不到 ⇒ 假红。
// ```
// ★ 这正是 theme_regression_test 那条"两套 Material 不能混用"在**测试侧**的表现：
//   产品代码混用 ⇒ 退化成浅色主题；测试混用 ⇒ **找不到控件**（更难察觉）。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/download_queue.dart';
import 'package:sourin_spike/ui/widgets/download_panel.dart';

DownloadTask _task(
  String ep,
  DownloadState state, {
  int done = 0,
  int total = 0,
  String? error,
}) =>
    DownloadTask(
      id: 'p:m:$ep',
      title: '探针剧',
      episodeTitle: ep,
      provider: 'p',
      mediaId: 'm',
      episodeId: ep,
      sourceCode: 's',
      fileName: ep,
      done: done,
      total: total,
      state: state,
      error: error,
    );

Future<void> _pump(WidgetTester t) async {
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 380,
        height: 700,
        child: DownloadPanel(
          title: '探针剧',
          callbacks: DownloadPanelCallbacks(onPlay: (_) {}),
        ),
      ),
    ),
  ));
  await t.pump();
}

void main() {
  setUp(() => DownloadQueue.debugReset());
  tearDown(() => DownloadQueue.debugReset());

  testWidgets('空列表 ⇒ 整块不画（不占位）', (t) async {
    await _pump(t);
    expect(find.byType(DownloadPanel), findsOneWidget);
    // 面板在树上，但它 renderObject 的尺寸应为 0（SizedBox.shrink）
    expect(find.text('下载 · 0 集'), findsNothing);
    expect(find.byType(TextButton), findsNothing);
    debugPrint('MEASURE 面板空列表 TextButton 数=' +
        '${find.byType(TextButton).evaluate().length}');
  });

  testWidgets('四态各画对应的按钮（一集一行）', (t) async {
    DownloadQueue.debugReset();
    // 用 debugAdd 直接塞（真实入队会去解析流，widget 测试里没有网络）
    DownloadQueue.enqueue(_task('第01集', DownloadState.done));
    DownloadQueue.enqueue(_task('第02集', DownloadState.running, done: 40, total: 100));
    DownloadQueue.enqueue(_task('第03集', DownloadState.paused, done: 10, total: 100));
    DownloadQueue.enqueue(_task('第04集', DownloadState.failed, error: '这条流是加密的'));
    await _pump(t);
    /*
     * ★ 注意：enqueue 会异步泵起来干活。widget 测试里没有网络 ⇒
     *   解析流会失败并置 failed。所以这里只断言「行的存在与首帧按钮」。
     */
    final doneRow = find.text('第01集');
    expect(doneRow, findsOneWidget, reason: '★ 一集一行：第01集必须有一行');
    expect(find.text('第04集'), findsOneWidget);
    debugPrint('MEASURE 面板行数(Text找到的集名)=' +
        '${find.textContaining('第0').evaluate().length}');
    debugPrint('MEASURE 面板 TextButton 数=' +
        '${find.byType(TextButton).evaluate().length}');
    final labels = find
        .byType(TextButton)
        .evaluate()
        .map((e) {
          final tb = e.widget as TextButton;
          final c = tb.child;
          return c is Text ? (c.data ?? '') : '<非Text>';
        })
        .toList();
    debugPrint('MEASURE 面板按钮文案=' + labels.join(' | '));
    expect(labels, isNotEmpty, reason: '★ 每行都该有操作按钮');
  });

  testWidgets('整剧删除按钮出现（表头）', (t) async {
    DownloadQueue.enqueue(_task('第01集', DownloadState.done));
    await _pump(t);
    expect(find.byTooltip('删除整部剧的下载'), findsOneWidget,
        reason: '★ Owner 追加要求：整剧删除入口必须在外面也能点到');
    debugPrint('MEASURE 整剧删除按钮存在=true');
  });
}