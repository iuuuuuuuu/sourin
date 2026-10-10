// ═══════════════════════════════════════════════════════════════════════
//  ★★★ OPS-10 ④ D：「没有弹幕」角标不该**常驻**
// ═══════════════════════════════════════════════════════════════════════
//
//  # Owner 报（第 4 条，逐字）
//  ```text
//  > 没有弹幕的那个标识,不用一直显示,跟随一起消失就行了
//  ```
//  截图上那句「没有弹幕」一直挂在左上角，控制条都自动隐藏了它还在。
//
//  # 改前是什么样（逐字抄自改前的 getter）
//  ```dart
//  if (_danmakuComments.isEmpty) {
//    return _danmakuStatus.isEmpty ? null : '没有弹幕';
//  }
//  ```
//  这一支既**没有计时器**，也**不看 _controlsVisible**
//  ⇒ 取数成功但 0 条时，角标永远画着，控制条隐藏了它还在。
//
//  # 本文件钉住三件事
//  ```text
//  ① 成功但 0 条 ⇒ 起一个**一次性**计时器（到点自己消失）
//  ② 角标**跟控制条一起淡出**（控制条藏了 ⇒「没有弹幕」这句也不画）
//  ③ 反向：控制条回来 ⇒ 这句也得回来（不能被误清掉）
//  ```
//
//  # ★★★ 这里为什么**不断言 find.text('没有弹幕')**（第一版就红在这）
//  ```text
//  本用例挂的是**真播放页**，而弹幕层拿到的 _displayAspect 是
//  _player.state.width/height（player_page.dart:9132-9137）——
//  **没起播时是 null**（那是刻意的，见 :9111-9131 那段说明）。
//  DanmakuOverlay 的 LayoutBuilder 拿到 null aspect ⇒
//  danmakuContainRect 返回 null ⇒ 整层 SizedBox.shrink()
//  （danmaku_overlay.dart:639-643）⇒ 角标**根本不在树上**。
//  第一版在这里断言 find.text 就恒红（改前改后都红）——那是**仪器假红**，
//  不是产品缺陷：真机上用户在**播放中**，aspect 是有值的。
//  ⇒ 本文件只钉「该不该画」这个判据（探针读的就是生产那个 getter），
//     「画得出来」由 test/zz_cr_dmk_c_import_test.dart 的
//     find.text(tip) 那条（真导入路径上气泡确实在树上）负责。
//  ```
//
//  ⚠️ 走的是**真棵树上真的那个 getter**（探针读 _danmakuBadge），
//     不许在测试里手抄一份判据 —— 那样测的就不是生产路径了。
//
//  必备运行参数（同其它 native-media 用例）：
//    --run-skipped --tags native-media --concurrency=1

@Tags(['native-media'])

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

List<Episode> fakeEpisodes(int n) => [
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
        title: '弹幕空角标回归',
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

Future<void> drain(WidgetTester t) async {
  for (var i = 0; i < 60; i++) {
    await t.pump(const Duration(seconds: 3));
  }
}

/// ★★★ 收尾配方（与 test/zz_t3_flash_probe_test.dart:171-176 同款，
///     少了这一步整个进程 exit=1）
/// episode_strip.dart:1209 的 dispose 会从已失活元素上找 MediaQuery
/// ⇒ "Looking up a deactivated widget's ancestor is unsafe."
Future<void> finish(WidgetTester t) async {
  await t.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
  await drain(t);
  expect(t.takeException(), isNull);
}

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });

  setUp(() {
    RemoteBridge.instance.stop();
    UiPrefs.debugResetForTest();
  });
  tearDown(() => RemoteBridge.instance.stop());

  testWidgets('★★ 有状态但 0 条 ⇒ 角标先出现，随后**自己**消失',
      (t) async {
    await mountPlayer(t);

    // 制造"取数成功但一条都没有"：status 非空 + comments 为空
    expect(debugPlayerSetDanmakuEmptyResultForProbe('某番 第 1 集 · 0 条弹幕'),
        isTrue,
        reason: '★ 探针写的是真字段');
    await t.pump();

    expect(debugPlayerDanmakuBadgeForProbe(), '没有弹幕',
        reason: '★ 该显示的时候必须真的显示（这不是缺陷）');

    // ★★★ 缺陷所在：改前这里永远是 '没有弹幕'
    await t.pump(const Duration(seconds: 4));
    expect(debugPlayerDanmakuBadgeForProbe(), isNull,
        reason: '★★★ 成功但 0 条的提示必须会自己消失，而不是常驻');

    await finish(t);
  });

  testWidgets('★★ 角标跟着控制条走：控制条藏了 ⇒ 「没有弹幕」也不画',
      (t) async {
    await mountPlayer(t);

    expect(debugPlayerSetDanmakuEmptyResultForProbe('某番 第 1 集 · 0 条弹幕'),
        isTrue);
    await t.pump();
    expect(debugPlayerDanmakuBadgeForProbe(), '没有弹幕');

    // 生产那条隐藏路径：_playing 必须先置位（_autoHideNow 的判据）
    debugPlayerSetPlayingForProbe(true);
    expect(debugPlayerAutoHideControlsForProbe(), isTrue,
        reason: '★ 走生产那条 _autoHideNow()，不是测试自己置位');
    await t.pump();

    expect(debugPlayerControlsVisibleForProbe(), isFalse,
        reason: '★ 前置条件：控制条确实藏了');
    expect(debugPlayerDanmakuBadgeForProbe(), isNull,
        reason: '★★★ 「没有弹幕」必须随控制条一起淡出 —— 这就是 Owner 报的那句');

    await finish(t);
  });

  testWidgets('★★ 反向：控制条回来 ⇒ 「没有弹幕」回来（不能被误清掉）',
      (t) async {
    await mountPlayer(t);

    expect(debugPlayerSetDanmakuEmptyResultForProbe('某番 第 1 集 · 0 条弹幕'),
        isTrue);
    await t.pump();

    debugPlayerSetPlayingForProbe(true);
    debugPlayerAutoHideControlsForProbe();
    await t.pump();
    expect(debugPlayerDanmakuBadgeForProbe(), isNull);

    // 鼠标一动 ⇒ 走生产 _showControls()
    expect(debugPlayerHoverControlsForProbe(), isTrue);
    await t.pump();
    expect(debugPlayerDanmakuBadgeForProbe(), '没有弹幕',
        reason: '★ 控制条回来时这句还得在，否则用户以为"什么都没有"');

    await finish(t);
  });
}
