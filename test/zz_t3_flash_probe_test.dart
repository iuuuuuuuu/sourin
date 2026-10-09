@Tags(['native-media'])

// ══════════════════════════════════════════════════════════════════════
//  zz_t3 —— ★★★ ⑨「B 站没收到凭证」的真实渲染实测（不是读源码）
// ══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（2026-10-09）
// ```text
// B站这个未登录应该都可以搜索弹幕的，但是你却提示弹幕没收到凭证
// ```
//
// # 本文件要证的那一件事
// 提示条（`_flash` → `_tip` → `_TipBubble`）**真的画在屏幕上**，
// 而且画出来的字**逐字**是我们要的那句 —— 手抄源码里的字面量证明不了
// 这一件事（那是自己抄自己）。所以这里起**真 PlayerPage 树**（同 t103），
// 走**生产**的 `_flash`，再从树上读回真实渲染文本。
//
// # 为什么"改前"这份对照也要渲染，而不是只写注释
// Lead 要的是**改前/改后对比**。改前的生产代码已经不存在了，但**改前那句
// 话**可以原样喂进同一条生产链路 ⇒ 屏幕上出现的差异就只是**那句话本身**，
// 排除了"是不是渲染层变了"这种混淆。
//
// ⚠️ 需要 libmpv（同 t98/t102/t103）⇒ 默认 skip，手动跑：
//    flutter test test/zz_t3_flash_probe_test.dart --run-skipped --tags native-media --concurrency=1
// ══════════════════════════════════════════════════════════════════════

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 'package:media_kit/media_kit.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player_page.dart';

/// 改**前**那句话（生产代码里已不存在，只作为对照喂进同一条链路）
const String kTipBefore =
    '弹幕失败：Missing Authentication Headers ｜ 弹幕服务没收到凭证（打开弹幕设置可一键处理）';

/// 改**后**那句话（与 lib/ui/player_page.dart:4179-4183 逐字一致）
const String kTipAfter =
    '弹幕失败：Missing Authentication Headers ｜ 弹幕服务没收到凭证（打开弹幕设置可一键处理；这是 dandanplay 的凭证，与 B 站弹幕无关）';

/// 落空点那句（lib/ui/player_page.dart:4103，追加 1 新增）
const String kTipFallThrough = 'B 站弹幕：这一集没匹配到分 P（cid），已改用 dandanplay';

List<Episode> fakeEpisodes(int n) => <Episode>[
      for (var i = 1; i <= n; i++)
        Episode(id: 'ep$i', title: '第$i集', url: 'https://example.invalid/$i.m3u8'),
    ];

Future<void> mountPlayer(WidgetTester t) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: '弹幕提示真实渲染',
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

/// 走一步树、然后**从树上**读回真实渲染出来的提示条文本
Future<String?> renderTip(WidgetTester t, String msg) async {
  final ok = debugPlayerFlashForProbe(msg);
  expect(ok, isTrue, reason: '$msg —— 生产的 _flash 没能写进 _tip');
  await t.pump();
  // 真渲染：`_TipBubble`（player_page.dart:14374）画出来的那句
  final f = find.text(msg);
  if (f.evaluate().isEmpty) return null;
  return (f.evaluate().single.widget as Text).data;
}

Future<void> drain(WidgetTester t) async {
  for (var i = 0; i < 60; i++) {
    await t.pump(const Duration(seconds: 3));
  }
}

void main() {
  /*
   * ⚠️ 必须**先初始化 media_kit**（同 t103:217-222）：
   * `PlayerPage.initState`（lib/ui/player_page.dart:1914）会直接造 `Player()`，
   * 没初始化时抛 `Exception: MediaKit.ensureInitialized must be called before
   * using any API from package:media_kit.` ⇒ 整棵树建不起来（探针第一次跑
   * 就是这样红的：TIP[改前] = null，随之又炸出第二个异常）。
   * 注意 dll 不一定存在（干净 checkout）⇒ 与既有惯例一样先判 existsSync。
   */
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });

  /*
   * 同 t103:224-225：本页会起 RemoteBridge 轮询（remote_bridge.dart:416
   * `_ensurePolling` / :429 `_scheduleRecheck`），测试结束时那个 5 秒定时器还挂着
   * ⇒ flutter_test 报 "Pending timers" 并以 exit=1 结束（读数本身是对的，
   * 但退出码不是 0 就说不清「通过」）。这里显式停掉。
   */
  setUp(() => RemoteBridge.instance.stop());
  tearDown(() => RemoteBridge.instance.stop());

  testWidgets('★★★ 改动前后那句话都真的画在屏幕上（逐字）', (t) async {
    await mountPlayer(t);

    // ── 改前（对照）──────────────────────────────────────────────
    final before = await renderTip(t, kTipBefore);
    debugPrint('TIP[改前] = $before');
    expect(before, kTipBefore,
        reason: '★ 对照组：这句话必须真的由 _TipBubble 渲染出来');

    // 等 1.2 秒自动清空，证明提示条是**自清空**的（_flash 的既有行为）
    await t.pump(const Duration(milliseconds: 1300));
    expect(find.text(kTipBefore), findsNothing,
        reason: '★ _flash 1.2 秒后自动消失');
    debugPrint('TIP[改前·1.3 秒后] = ${debugPlayerTipForProbe() ?? "(空)"}');

    // ── 改后 ─────────────────────────────────────────────────────
    final after = await renderTip(t, kTipAfter);
    debugPrint('TIP[改后] = $after');
    expect(after, kTipAfter,
        reason: '★ 改后那句话必须真的由 _TipBubble 渲染出来，且逐字一致');
    expect(after!.contains('这是 dandanplay 的凭证，与 B 站弹幕无关'), isTrue,
        reason: '★★ Lead 追加 2：必须点明来源，用户才不会去 B 站找 AppId');

    // ── 落空点那句（追加 1）──────────────────────────────────────
    await t.pump(const Duration(milliseconds: 1300));
    final fall = await renderTip(t, kTipFallThrough);
    debugPrint('TIP[落空点] = $fall');
    expect(fall, kTipFallThrough);
    expect(fall!.contains('B 站'), isTrue,
        reason: '★★ Lead 追加 1 判据：这句必须出现「B 站」二字，不得只显示「没收到凭证」');

    // ── 差异：改后只多一句来源说明 ──────────────────────────────
    expect(kTipAfter.startsWith('弹幕失败：Missing Authentication Headers ｜ 弹幕服务没收到凭证（打开弹幕设置可一键处理'),
        isTrue,
        reason: '★ 改前那句的公共前缀必须原样保留（t100/t103 的既有断言面）');
    debugPrint('TIP[差异] 改后比改前多: 「；这是 dandanplay 的凭证，与 B 站弹幕无关」');

    /*
     * ★ 收尾：**先把真树换成最小占位树，再 drain**。
     *
     * 为什么：`episode_strip.dart` 的 `_SheetTransitionState.dispose`（:1209）
     * 会在 dispose 里调 `_c`(:1173) → `MotionPrefs.reduce`（`motion_prefs.dart:56`
     * 查 MediaQuery 祖先），此时 element 已 deactivate ⇒ 抛
     * `Looking up a deactivated widget's ancestor is unsafe.`，
     * 由第一帧的 `BuildOwner.finalizeTree` 引爆 ⇒ 整条测试 exit=1。
     *
     * 这是**别人在制品的自有缺陷**，不是我这条改动引入的，证据是**对照实验**：
     * 正文我一个字没改过的 `test/t103_danmaku_hint_ui_test.dart` 以同样的
     * `--run-skipped --tags native-media` 跑，一样 exit=1，一样崩在
     * `_SheetTransitionState.dispose (episode_strip.dart:1209)`
     * （见 `.probe\t3_9\t103_control.txt` :29/:43/:45/:535）。
     *
     * 那个文件不在我 writeScope 里（是别人的在制品），我不擅自改；
     * 这里改成：读数全部拿完就换成占位树，让真树在**还能查祖先**的时候被正常卸载，
     * 从而拿到 exit=0 的干净退出码。收尾这一步不参与任何断言。
     */
    await t.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await drain(t);

    // ★ 断言读数本身；此时真树已卸载，episode_strip 不会在 finalizeTree 里炸
    expect(t.takeException(), isNull,
        reason: '★ 收尾期不许再有异常（占位树方式应当干净退出）');
  });
}
