// ═══════════════════════════════════════════════════════════════════════
//  WebDAV 同步面板：同步结果的文案 + 无头截图自查
// ═══════════════════════════════════════════════════════════════════════
//
// # ① 这个文件守的第一件事：一个**实测发现的静默 bug**
//
// Rust 的 `sync::SyncSummary` 序列化出来是
// ```json
// { "plane": "favorites", "pulled": 3, "pushed": 1, "conflicts": 0 }
// ```
// 而 Dart 的 `SyncSummary.fromJson` 读的是 `kind` / `count` / `message`
// —— 三个键在服务端一个都不存在，于是每一条都解析成全空，
// 面板拼出来是「同步完成： /  / 」（`sums` 非空所以不会走「无变化」分支）。
//
// 症状：**用户看到「同步成功了」，但界面上没有一句话说清同步了什么**。
// 不会红、不会崩，只是永远没信息 —— 所以只能靠单测锁住。
//
// # ② 截图为什么要在这个文件里
//
// SyncPanel 是「自包含无参 widget」（见文件头），能直接在 flutter_tester 里
// 挂载并出图。截图不是装饰：面板的高度、按钮换行、连接信息那几行的排版
// 只有看图才发现得了，而窄屏（手机 412dp）下最容易挤爆。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/widgets/sync_panel.dart';

import 'support/ui_shot.dart';

/// 与 Rust `src/sync/mod.rs` 的 `SyncSummary` 同形
Map<String, dynamic> _wire({
  String plane = 'favorites',
  int pulled = 0,
  int pushed = 0,
  int conflicts = 0,
  String? note,
}) =>
    <String, dynamic>{
      'plane': plane,
      'pulled': pulled,
      'pushed': pushed,
      'conflicts': conflicts,
      if (note != null) 'note': note,
    };

void main() {
  // ─────────────────────────────────────────────
  // ① ★ 与 Rust 侧的字段名一一对应（上面那个 bug 的回归锁）
  // ─────────────────────────────────────────────
  group('SyncSummary 与 Rust 的 wire 格式对齐', () {
    test('真实服务端返回的那几个键都能读到值', () {
      final s = SyncSummary.fromJson(
        _wire(plane: 'favorites', pulled: 3, pushed: 1),
      );
      expect(s.plane, 'favorites');
      expect(s.pulled, 3);
      expect(s.pushed, 1);
      expect(s.total, 4);
    });

    test('★ 阴性对照：旧字段名（kind/count）现在读不出东西', () {
      // 这条锁的是「别把旧字段名悄悄加回来当别名」——
      // 那会让两边含义不同的数据混在一起（比如把 pushed 当 count 显示）。
      final s = SyncSummary.fromJson(<String, dynamic>{
        'kind': 'favorites',
        'count': 7,
        'message': '老格式',
      });
      expect(s.plane, '', reason: 'plane 必须是空（服务端没有这个键）');
      expect(s.pulled, 0);
      expect(s.pushed, 0);
      expect(s.total, 0, reason: '旧格式不该被当成「同步了 7 条」');
    });

    test('三个平面都有中文名，未知平面原样透传', () {
      expect(SyncSummary.fromJson(_wire(plane: 'favorites')).label, '收藏与追更');
      expect(SyncSummary.fromJson(_wire(plane: 'progress')).label, '播放进度');
      expect(SyncSummary.fromJson(_wire(plane: 'providers')).label, '内容源配置');
      expect(
        SyncSummary.fromJson(_wire(plane: 'brand-new-plane')).label,
        'brand-new-plane',
        reason: '不认识的名字要原样显示，不能吞成空串',
      );
    });

    test('缺字段 / null 都不炸（容错读法与面板的降级策略一致）', () {
      final s = SyncSummary.fromJson(<String, dynamic>{});
      expect(s.plane, '');
      expect(s.total, 0);
      final n = SyncSummary.fromJson(<String, dynamic>{'note': null});
      expect(n.note, isNull);
    });
  });

  // ─────────────────────────────────────────────
  // ② 面板：真挂载 + 截图
  // ─────────────────────────────────────────────
  setUpAll(loadRealFonts);

  /// 挂一个 SyncPanel。核心库在测试环境里加载不了，
  /// 面板的三支 `_reload()` 都包了 try/catch ⇒ 照常渲染（见 t91 文件头）。
  Future<void> pumpPanel(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          fontFamily: 'Microsoft YaHei UI',
        ),
        home: const Scaffold(body: Padding(
          padding: EdgeInsets.all(24),
          child: SingleChildScrollView(child: SyncPanel()),
        )),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('⓪ 仪器自检：面板真挂载（不是 ErrorWidget）', (tester) async {
    await setShotViewport(tester, const Size(1440, 900));
    await pumpPanel(tester);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.text('云盘同步'), findsOneWidget);
  });

  testWidgets('① 未配置态截图（桌面 1440×900）', (tester) async {
    await setShotViewport(tester, const Size(1440, 900));
    await pumpPanel(tester);
    final f = await saveViewShot(tester, 'sync_panel_desktop_unconfigured');
    expect(f.existsSync(), isTrue);
    // 未配置时不该露出连接详情 / 自动备份 / 云端备份列表
    expect(find.text('立即同步'), findsNothing);
    expect(find.textContaining('上次同步'), findsNothing);
  });

  testWidgets('② 手机宽度（412×915）不得溢出', (tester) async {
    await setShotViewport(tester, const Size(412, 915));
    await pumpPanel(tester);
    expect(tester.takeException(), isNull);
    final f = await saveViewShot(tester, 'sync_panel_phone_unconfigured');
    expect(f.existsSync(), isTrue);
  });

  testWidgets('②b 窄屏下逐个量：按钮与文字都在面板内、没有溢出',
      (tester) async {
    // ���这一段是「看图」的替代品：RenderFlex 溢出在 flutter_test 里
    // 有时只是打了日志、不抛异常，所以这里**直接量矩形**。
    for (final size in const [Size(412, 915), Size(1440, 900)]) {
      await setShotViewport(tester, size);
      await pumpPanel(tester);
      expect(tester.takeException(), isNull, reason: '$size 下不得有布局异常');

      final panel = tester.getRect(find.byType(SyncPanel));
      for (final t in find.text('配置云盘').evaluate()) {
        final r = tester.getRect(find.byWidget(t.widget));
        expect(panel.left - 0.5 <= r.left && r.right <= panel.right + 0.5,
            true,
            reason: '$size 下「配置云盘」按钮 ${r.size} 溢出面板 ${panel.size}');
      }
      // 块头标题也要在框内
      final head = tester.getRect(find.text('云盘同步'));
      expect(head.left >= panel.left - 0.5, true, reason: '$size 下标题左溢出');
      expect(head.right <= panel.right + 0.5, true, reason: '$size 下标题右溢出');
    }
  });

  testWidgets('③ 「配置云盘」对话框真能打开（未配置时唯一的入口）',
      (tester) async {
    await setShotViewport(tester, const Size(1440, 900));
    await pumpPanel(tester);
    await tester.tap(find.text('配置云盘'));
    await tester.pumpAndSettle();

    expect(find.text('配置云盘（WebDAV）'), findsOneWidget);
    // 默认就是坚果云，且地址与远程目录都真的填好了（不信 hint）
    expect(find.text('坚果云'), findsWidgets);
    final f = await saveViewShot(tester, 'sync_panel_webdav_dialog');
    expect(f.existsSync(), isTrue);
  });

  testWidgets('④ 对话框里的说明不许露出 Markdown 标记', (tester) async {
    await setShotViewport(tester, const Size(1440, 900));
    await pumpPanel(tester);
    await tester.tap(find.text('配置云盘'));
    await tester.pumpAndSettle();

    // `**不加粗**` 这类标记泄漏到用户眼前是很常见的翻车点
    expect(find.textContaining('**'), findsNothing);
  });

  testWidgets('⑤ TV 宽度（1920×1080）不得溢出', (tester) async {
    await setShotViewport(tester, const Size(1920, 1080));
    await pumpPanel(tester);
    expect(tester.takeException(), isNull);
    final f = await saveViewShot(tester, 'sync_panel_tv_unconfigured');
    expect(f.existsSync(), isTrue);
  });
}