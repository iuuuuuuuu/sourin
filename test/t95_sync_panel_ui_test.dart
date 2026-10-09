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
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/theme/theme_pack.dart';
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
  /// [brightness] 走**生产本体**的主题（`AppTheme.themeFor`），
  /// 不再自造 `ThemeData`。
  ///
  /// ★ 为什么必须用真的那个：原先这里用 `ThemeData(brightness: dark)` 自搭壳，
  ///   于是截图与真机的主题**完全不是一回事** —— 主题 agent 换掉 forui、
  ///   改色板，我这条测试照样全绿（实测：合并前后四张 PNG **字节完全相同**，
  ///   说明它对主题改动是瞎的）。自造壳的测试等于没测视觉。
  Future<void> pumpPanel(WidgetTester tester,
      {Brightness brightness = Brightness.dark}) async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeFor(brightness),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(child: const SyncPanel()),
          ),
        ),
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

  // ─────────────────────────────────────────────
  // ★ 「已连接」形态 —— 面板里**大部分** UI 只在这时存在
  // ───────────────────────────────���─────────────
  //
  // 前面所有用例都在「未配置」态，因为测试环境加载不了核心库。
  // 可那样一来，下面这些**一条都渲染不出来**：
  //
  // ```text
  // 连接详情（服务/地址/账号/目录/上次同步/上次备份）
  // 四个动作按钮（测试连接/立即同步/立即备份/断开）
  // 自动同步设置区（开关 + 两个间隔 + 保留份数）
  // 云端备份列表（含逐份删除按钮）
  // ```
  //
  // ⇒ 靠 `SourinApi.installSyncDebugFetchers`（只读三接口的注入点，
  //   见 sourin_api.dart 的注释）造出这个形态，把用户真正会看到的界面
  //   渲染出来并量它。
  tearDown(() => SourinApi.installSyncDebugFetchers());

  /// 造一个「已连上坚果云、开了自动同步、云端有 3 份备份」的形态
  void installConnected() {
    final when = DateTime(2026, 9, 29, 10, 11).millisecondsSinceEpoch;
    SourinApi.installSyncDebugFetchers(
      status: () async => const SyncStatus(
        connected: true,
        backend: 'WebDAV（坚果云 / Nextcloud / 群晖）',
        deviceId: 'dev-a',
      ),
      settings: () async => SyncSettings(
        connected: true,
        baseUrl: 'https://dav.jianguoyun.com/dav/',
        username: 'someone@example.com',
        remoteDir: 'sourin',
        retainCount: 10,
        autoEnabled: true,
        autoIntervalMinutes: 30,
        autoBackupIntervalMinutes: 1440,
        lastSyncAt: when,
        lastBackupAt: when,
      ),
      backups: () async => const [
            SyncBackupEntry(
                name: 'dsh-backup-客厅电视-20260929-101112.zip',
                bytes: 12 * 1024 * 1024,
                modified: 1759234272000),
            SyncBackupEntry(
                name: 'dsh-backup-书房台式机-20260928-080000.zip',
                bytes: 3 * 1024 * 1024,
                modified: 1759147872000),
            SyncBackupEntry(
                name: 'dsh-backup-客厅电视-20260927-203000.zip',
                bytes: 11 * 1024 * 1024,
                modified: 1759061400000),
          ],
    );
  }

  /// 挂「已连接」形态的面板
  Future<void> pumpConnected(WidgetTester tester, Size size,
      {Brightness brightness = Brightness.dark}) async {
    installConnected();
    await setShotViewport(tester, size);
    await pumpPanel(tester, brightness: brightness);
  }

  testWidgets('⑦ ★ 已连接态：连接详情 + 四个动作按钮 + 设置区 + 备份列表都在',
      (tester) async {
    await pumpConnected(tester, const Size(1440, 900));

    // 仪器自检：注入点真的生效（否则下面全是假绿）
    expect(find.text('已连接'), findsOneWidget, reason: '必须真处在已连接态');

    // ① 连接详情 —— 用户靠这几行确认自己没连错地方
    expect(find.textContaining('someone@example.com'), findsOneWidget);
    expect(find.textContaining('https://dav.jianguoyun.com/dav/'), findsOneWidget);
    expect(find.textContaining('sourin'), findsWidgets);
    expect(find.textContaining('上次同步'), findsOneWidget);
    expect(find.textContaining('上次备份'), findsOneWidget);

    // ② 四个动作
    for (final label in ['测试连接', '立即同步', '立即备份', '断开']) {
      expect(find.text(label), findsOneWidget, reason: '「$label」按钮必须渲染出来');
    }

    // ③ 自动同步设置区
    expect(find.text('自动同步'), findsWidgets);
    expect(find.text('数据变动就同步'), findsOneWidget);
    expect(find.textContaining('云端最多保留'), findsOneWidget);

    // ④ 云端备份列表：三份都在，且删除按钮逐份都有
    expect(find.textContaining('云端备份（3 份）'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsNWidgets(3));

    // ⑤ 中文设备名 + 大小被还原成人话（不是原始文件名）
    expect(find.textContaining('客厅电视'), findsWidgets);
    expect(find.textContaining('2026-09-29 10:11:12'), findsOneWidget);
    expect(find.textContaining('12.0 MB'), findsOneWidget);
  });

  testWidgets('⑧ ★ 已连接态：默认配色下无异常、无溢出、截图非空',
      (tester) async {
    for (final size in const [Size(1440, 900), Size(412, 915), Size(1920, 1080)]) {
      await pumpConnected(tester, size);
      expect(tester.takeException(), isNull, reason: '$size 下不得有布局异常');
      expect(find.byType(ErrorWidget), findsNothing, reason: '$size 下不能是 ErrorWidget');

      // 逐个量：每一行备份、每一个按钮都在面板内
      final panel = tester.getRect(find.byType(SyncPanel));
      for (final label in ['测试连接', '立即同步', '立即备份', '断开']) {
        final r = tester.getRect(find.text(label));
        expect(panel.left - 0.5 <= r.left && r.right <= panel.right + 0.5, true,
            reason: '$size 下「$label」${r.size} 溢出面板 ${panel.size}');
      }

      final f = await saveViewShot(tester, 'sync_panel_connected_${size.width.toInt()}');
      expect(f.lengthSync(), greaterThan(4000),
          reason: '$size 的截图只有 ${f.lengthSync()} 字节，疑似空图');
    }
  });

  testWidgets('⑨ ★ 已连接态在每套内置配色下都渲染得出来', (tester) async {
    installConnected();
    for (final pack in ThemePackStore.builtins) {
      await setShotViewport(tester, const Size(1440, 900));
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeForPack(pack.brightness, pack),
        home: const Scaffold(
          body: Padding(
            padding: EdgeInsets.all(24),
            child: SingleChildScrollView(child: SyncPanel()),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.takeException(), isNull, reason: '配色「${pack.name}」下不得有异常');
      expect(find.text('已连接'), findsOneWidget, reason: '配色「${pack.name}」下必须还是已连接态');
      expect(find.text('立即同步'), findsOneWidget, reason: '配色「${pack.name}」下按钮必须渲染');

      final f = await saveViewShot(tester, 'sync_panel_connected_pack_${pack.id}');
      expect(f.lengthSync(), greaterThan(4000),
          reason: '配色「${pack.name}」的已连接态截图只有 ${f.lengthSync()} 字节');
    }
  });

  testWidgets('⑩ ★ 已连接态在明暗两种模式下都能渲染', (tester) async {
    for (final b in Brightness.values) {
      await pumpConnected(tester, const Size(1440, 900), brightness: b);
      expect(tester.takeException(), isNull, reason: '$b 下不得有异常');
      expect(find.text('已连接'), findsOneWidget);
      final f = await saveViewShot(tester, 'sync_panel_connected_${b.name}');
      expect(f.lengthSync(), greaterThan(4000));
    }
  });

  testWidgets('⑪ ★ 阴性对照：注入点撤掉后回到未配置态（证明注入是有效的）',
      (tester) async {
    // 上面每一条都建立在「注入点生效」这个前提上。
    // 这里把它拆掉，确认面板真的回到未配置形态 ——
    // 否则「已连接态的断言全绿」可能只是因为它们在未配置态也成立。
    SourinApi.installSyncDebugFetchers();
    await setShotViewport(tester, const Size(1440, 900));
    await pumpPanel(tester);

    expect(find.text('已连接'), findsNothing, reason: '拆掉注入点后不该还是已连接');
    expect(find.text('立即同步'), findsNothing, reason: '未配置时不该有「立即同步」');
    expect(find.byIcon(Icons.delete_outline), findsNothing);
    expect(find.textContaining('someone@example.com'), findsNothing);
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

  testWidgets('⑤b ★ 每一套内置配色下都渲染得出来（多主题是 Owner 第 4 条）',
      (tester) async {
    // 同步面板是二级页，用户会在**任何一套**配色下打开它
    //（主题页能换 6 套内置 + 外部 JSON 包）。
    // 判据只有两条：不出错、真的画出了东西（截图字节下限）。
    for (final pack in ThemePackStore.builtins) {
      await setShotViewport(tester, const Size(1440, 900));
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeForPack(pack.brightness, pack),
        home: const Scaffold(
          body: Padding(
            padding: EdgeInsets.all(24),
            child: SingleChildScrollView(child: SyncPanel()),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.takeException(), isNull, reason: '配色「${pack.name}」下不得有异常');
      expect(find.byType(ErrorWidget), findsNothing, reason: '配色「${pack.name}」下不能是 ErrorWidget');
      expect(find.text('云盘同步'), findsOneWidget, reason: '配色「${pack.name}」下块头必须渲染出来');

      final f = await saveViewShot(tester, 'sync_panel_pack_${pack.id}');
      expect(f.existsSync(), isTrue);
      expect(f.lengthSync(), greaterThan(4000),
          reason: '配色「${pack.name}」的截图只有 ${f.lengthSync()} 字节，疑似空图');
    }
  });

  testWidgets('⑥ ★ 明暗两套主题下都渲染得出来（面板是二级页，两种都得能用）',
      (tester) async {
    for (final b in Brightness.values) {
      for (final size in const [Size(1440, 900), Size(412, 915)]) {
        await setShotViewport(tester, size);
        await pumpPanel(tester, brightness: b);
        expect(tester.takeException(), isNull,
            reason: '$b / $size 下不得有异常');
        expect(find.byType(ErrorWidget), findsNothing, reason: '$b 下不能是 ErrorWidget');
        expect(find.text('云盘同步'), findsOneWidget, reason: '$b 下块头必须渲染出来');

        final f = await saveViewShot(
            tester, 'sync_panel_${b.name}_${size.width.toInt()}');
        expect(f.existsSync(), isTrue);
        // 像素级自检：真渲染出的图不能是一张纯色（那就等于「什么都没画」）
        expect(f.lengthSync(), greaterThan(4000),
            reason: '$b / $size 的截图只有 ${f.lengthSync()} 字节，疑似空图');
      }
    }
  });
}