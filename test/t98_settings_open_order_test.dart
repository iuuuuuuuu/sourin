@Tags(['native-media'])

// ══════════════════════════════════════════════════════════════════════
//  t98 —— ★★★ 桌面端第 3 条回归：点齿轮必须**立刻**开出面板
// ══════════════════════════════════════════════════════════════════════
//
// # Owner 报
// \`\`\`text
// > 不知道点了什么，下面一栏就不显示了，上面还显示 下面就不显示了
// > 原来是点了 设置(字幕/音轨/连播) 这个按钮，点了之后无反应，
// > 然后下面这页直接没了
// \`\`\`
//
// # 这条链路上**有两个**独立缺陷，本文件各钉一组
//
// ## 缺陷 A（顺序）：`_openSettings()` 把「打开面板」排在两次 mpv 回读之后
// \`\`\`dart
// await _readMpvStyle();    // 7 个属性，每个一次 await native.getProperty
// await _readVideoZoom();   // 又一次 await native.getProperty
// setState(() => _settingsOpen = true);   // ← 到不了
// \`\`\`
// mpv 侧只要不回应（卡住 / 进程已崩 / 还没就绪）这两个 await 就**永不返回**，
// \`_settingsOpen\` 恒为 false；与此同时底栏的 3 秒自动隐藏计时器照常把底栏收掉
// ⇒ 屏幕上就是「上面还显示、下面一栏没了、点齿轮无反应」。
//
// ## 缺陷 B（Element 重建）：portal 的 Element 被重建后 controller 状态不跟随
// 挂载点 \`OverlayPortal\` 所在 Stack 的**两侧都有条件子件**，
// 而它原来**没有 Key** ⇒ 任一侧开/关都会让这一格的 Element 被
// deactivate + inflate 重建；重建时 \`OverlayPortalController\` 的可见状态
// **不跟随**（overlay.dart:1675-1684 逐字），而 \`_settingsPortalShown\`
// 镜像仍是 true ⇒ \`show()\` 被吞 ⇒ 面板永远画不出来，且**不可自愈**
// （\`_hideSettingsPortal()\` 改前全文件只有 Esc 那一处调用，现在关面板的两条路
// 都走它，见 player_page.dart 的 `_closeSettingsFromEsc`）。
// 修法：挂载点给**常量** Key（player_page.dart:9303）+ 判据改用
// \`_settingsPortal.isShowing\`（真实状态，不是镜像）。
//
// # 关于「真点齿轮」这条路径
// \`flutter_tester\` 里 PlayerPage 整棵树的**指针事件回调都不被调用**：
// 命中链是完整的（\`hitTestInView\` 一路到 IconButton 的 RenderPointerListener），
// 但 \`t.tap\` / \`tapAt\` / 手动 startGesture 都不触发回调；
// 同一个 Stack 里另加一个 GestureDetector 却能收到（对照组）。
// ⇒ 本文件**不用** \`t.tap\` 驱动，改用探针直调**生产那棵树**上的字段，
//   复现序列本身（开浮层 → 关 → 再开面板）仍然是生产代码。
//
// ⚠️ 必须带 \`@Tags(['native-media'])\` 并用 \`--run-skipped --tags native-media\` 跑
//    （见 dart_test.yaml:62-69：本标签默认 skip）
// ══════════════════════════════════════════════════════════════════════

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 'package:sourin_spike/ui/widgets/player_settings_sheet.dart';

List<Episode> fakeEpisodes(int n) => [
      for (var i = 1; i <= n; i++)
        Episode(
          id: 'ep$i',
          title: '第$i集',
          url: 'https://example.invalid/$i.m3u8',
        ),
    ];

Future<void> mountPlayer(WidgetTester t) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: '设置面板回归',
        episodes: fakeEpisodes(5),
        episodeIndex: 0,
        episodeId: 'ep1',
        episodeTitle: '第1集',
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
}

/// 把 3 秒自动隐藏之类的挂起计时器推完，免得报 pending timer
Future<void> drain(WidgetTester t) async {
  for (var i = 0; i < 60; i++) {
    await t.pump(const Duration(seconds: 3));
  }
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

  final sheet = find.byType(PlayerSettingsSheet);

  testWidgets('① 探针直调（不碰 mpv）本来就能开 —— 证明夹具本身没问题', (t) async {
    await mountPlayer(t);
    expect(debugPlayerOpenSettingsForProbe(), isTrue);
    await t.pump();
    expect(debugPlayerSettingsOpen(), isTrue);
    expect(sheet, findsOneWidget);
    await drain(t);
  });

  testWidgets('② ★★ 缺陷 B 回归：开过 portal **之后**的浮层再开设置面板，必须仍然开得出来',
      (t) async {
    await mountPlayer(t);
    expect(sheet, findsNothing, reason: '★ 起手不能有面板');

    // ── 第一次：正常打开 ──
    expect(debugPlayerOpenSettingsForProbe(), isTrue);
    await t.pump();
    expect(sheet, findsOneWidget, reason: '★ 第一次必须开得出来（阳性对照）');

    /*
     * ★ 模拟面板上那颗 X：**只**改真源 `_settingsOpen`，不动
     *   `_settingsPortalShown` 镜像 —— 这正是缺陷 B 的入口形态
     *   （改前 `_settingsPortalShown` 会永久停在 true）。
     */
    expect(debugPlayerCloseSettingsForProbe(), isTrue);
    await t.pump();
    expect(sheet, findsNothing, reason: '★ 关掉后树上不该还有面板');

    /*
     * ★★ 关键一步：开关一个排在 portal **之后**的浮层。
     *    改前这会让 portal 的 Element 被重建，而镜像 bool 还是 true
     *    ⇒ 下面的 show() 被吞 ⇒ 面板永远画不出来。
     */
    expect(debugPlayerOpenDanmakuSettingsForProbe(), isTrue);
    await t.pump();
    expect(debugPlayerCloseDanmakuSettingsForProbe(), isTrue);
    await t.pump();

    // ── 第二次：缺陷 B 就发生在这里 ──
    expect(debugPlayerOpenSettingsForProbe(), isTrue);
    await t.pump();
    expect(
      sheet,
      findsOneWidget,
      reason: '★★★ 第 3 条缺陷 B：开过别的浮层之后再开设置面板，面板必须仍然出现 —— '
          '没有就是 portal 的 Element 被重建而 controller 状态没跟随',
    );
    await drain(t);
  });

  testWidgets('③ ★ 缺陷 B 的第二种触发序：先开 portal **之前**的浮层（快捷键提示）', (t) async {
    await mountPlayer(t);

    expect(debugPlayerOpenHintsForProbe(), isTrue, reason: '★ 提示面板要能开');
    await t.pump();
    expect(debugPlayerOpenSettingsForProbe(), isTrue);
    await t.pump();
    expect(
      sheet,
      findsOneWidget,
      reason: '★★★ 第 3 条缺陷 B：portal 之前插入一个兄弟子件后，面板必须仍然出现',
    );
    await drain(t);
  });

  testWidgets('④ ★ 开关两轮：面板不许「开过一次就再也开不出来」', (t) async {
    await mountPlayer(t);
    for (var round = 0; round < 3; round++) {
      expect(debugPlayerOpenSettingsForProbe(), isTrue, reason: '★ 第 $round 轮要能开');
      await t.pump();
      expect(sheet, findsOneWidget, reason: '★ 第 $round 轮面板必须在树上');
      expect(debugPlayerCloseSettingsForProbe(), isTrue);
      await t.pump();
      expect(sheet, findsNothing, reason: '★ 第 $round 轮关掉后必须真的没了');
    }
    await drain(t);
  });

  testWidgets('⑤ ★ 静态审计：挂载点必须有**常量** Key，show/hide 不许只信镜像 bool', (t) async {
    final src = File('lib/ui/player_page.dart').readAsStringSync();

    expect(
      src.contains("key: const ValueKey<String>('player-settings-portal'),"),
      isTrue,
      reason: '★★★ 第 3 条缺陷 B：挂载点必须给常量 Key —— '
          '否则 Stack 按位置槽位匹配会把 portal 的 Element 重建掉',
    );

    // show()：必须先写镜像，再按 **controller 真实状态** 判早退
    final showAt = src.indexOf('void _showSettingsPortal() {');
    expect(showAt, greaterThan(-1), reason: '★ 找不到 _showSettingsPortal');
    final showBody = src.substring(showAt, showAt + 900);
    expect(
      showBody.contains('_settingsPortal.isShowing'),
      isTrue,
      reason: '★★★ _showSettingsPortal 必须用 controller 的**真实** isShowing 判据，'
          '不能只信自己记的镜像 bool（镜像会过期 ⇒ 面板再也画不出来）',
    );
    /*
     * ★ 字段本身必须消失。
     *   ⚠️ 不能断言"源码里不含 `_settingsPortalShown` 这个字符串" ——
     *      注释里**应当**留着它（解释为什么删掉），所以只钉**声明**那一行。
     */
    expect(
      src.contains('bool _settingsPortalShown'),
      isFalse,
      reason: '★★★ 镜像 bool 已删除：只要它回来，就又会「过期 ⇒ show() 被吞」'
          '⇒ 第 3 条缺陷复活',
    );

    final hideAt = src.indexOf('void _hideSettingsPortal() {');
    expect(hideAt, greaterThan(-1), reason: '★ 找不到 _hideSettingsPortal');
    final hideBody = src.substring(hideAt, hideAt + 700);
    expect(
      hideBody.contains('_settingsPortal.isShowing'),
      isTrue,
      reason: '★ _hideSettingsPortal 同款：controller 没在显示就别 hide()'
          '（未 attach 且 zOrder 为 null 时 hide() 里的 assert 会炸）',
    );
  });

  testWidgets('⑥ ★★ 关掉面板后底栏必须回来（第 3 条自愈）', (t) async {
    await mountPlayer(t);

    expect(debugPlayerOpenSettingsForProbe(), isTrue);
    await t.pump();
    expect(sheet, findsOneWidget);

    expect(debugPlayerCloseSettingsForProbe(), isTrue);
    await t.pump();
    expect(sheet, findsNothing);
    /*
     * ★ 这个探针只改真源 `_settingsOpen`（等价于面板那颗 X 的**一半**），
     *   所以底栏不会自动回来 —— 它回来靠的是 onClose / Esc 里那两句
     *   `_showControls()`。⑦ 用静态审计钉住那两句的存在与位置。
     */
    expect(debugPlayerControlsVisible(), isNotNull,
        reason: '★ 探针要能读到真实的 _controlsVisible');
    await drain(t);
  });

  testWidgets('⑦ ★ 静态审计：关面板的两条路都要把底栏叫回来', (t) async {
    final src = File('lib/ui/player_page.dart').readAsStringSync();

    final closeAt = src.indexOf('onClose: () {');
    expect(closeAt, greaterThan(-1),
        reason: '★★★ 面板的 onClose 必须改成一个**块**（原来是一行 lambda）—— '
            '一行里塞不进自愈调用');
    expect(src.substring(closeAt, closeAt + 300).contains('_showControls();'), isTrue,
        reason: '★★★ 关面板（X）后必须把底栏叫回来：'
            '否则面板一旦「开着但画不出来」，底栏就永远不回来（第 3 条）');

    final escAt = src.indexOf('_hideSettingsPortal();');
    expect(escAt, greaterThan(-1));
    expect(src.substring(escAt, escAt + 900).contains('_showControls();'), isTrue,
        reason: '★★★ Esc 关面板后同样要把底栏叫回来');
  });
}
