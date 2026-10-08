@Tags(['native-media'])

// ══════════════════════════════════════════════════════════════════════
//  t102 —— ★★★ 桌面端第 9 条回归：mpv 报错不许把正在看的画面盖掉
// ══════════════════════════════════════════════════════════════════════
//
// # Owner 报（截图 u9_1c91d6a6.png）
// ```text
// 播放失败
// Failed to open http://127.0.0.1:63534/s/18dc2c90fcf9b1f03f3446afdd80/.
// ```
//
// # 根因（代码级）
// `lib/ui/player_page.dart` 的 `_bindPlayerStreams()` 里**只有一条**错误处理：
// ```dart
// _player.stream.error.listen((e) {
//   if (mounted) setState(() => _error = e);   // ← 一律走全屏 _ErrorOverlay
// });
// ```
// 而 `stream.error` 在**整条生命周期**里都会发（换清晰度重开、缓冲重试、
// 单帧解码报错…），不只是起播那一次。于是**播放中**来一条错误，
// 全屏遮罩立刻盖住画面 ⇒ 用户看到的就是「看着看着突然播放失败」。
//
// # 修法
// 用 `_sawFirstFrame`（`stream.width` 首次非空 = 真的有画面）把错误**分两类**：
// ```text
// 从未出画面 ⇒ 全屏 _ErrorOverlay（用户什么都没看到，必须解释 + 给出口）
// 已出画面   ⇒ 底部非阻断横幅 _PlaybackFailureBanner（画面继续 + 一键重试）
// ```
//
// # 关于夹具
// 起播需要真网络 + 真解码，widget 测试里做不到 ⇒ 用探针直调
// （`debugPlayerInjectStreamErrorForProbe` / `debugPlayerMarkFirstFrameForProbe`）。
// 两个探针**逐字复刻**生产闭包体，判据读的是 `_sawFirstFrame` / `_playbackFailure`
// 这些**真实字段**，不是测试自己记的副本。
//
// ⚠️ 必须 `--run-skipped --tags native-media`（见 dart_test.yaml:62-69）
// ══════════════════════════════════════════════════════════════════════

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

const kMpvMessage = 'Failed to open '
    'http://127.0.0.1:63534/s/18dc2c90fcf9b1f03f3446afdd80/.';

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
        title: '播放中断回归',
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

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });

  setUp(() => RemoteBridge.instance.stop());
  tearDown(() => RemoteBridge.instance.stop());

  testWidgets('① 起手：没出过画面、没有横幅（夹具自检）', (t) async {
    await mountPlayer(t);
    final st = debugPlayerPlaybackFailureState();
    expect(st.contains('hasFrame=false'), isTrue, reason: '★ 起手不能有画面：$st');
    expect(st.contains('failure=-'), isTrue, reason: '★ 起手不能有横幅：$st');
    await drain(t);
  });

  testWidgets('② ★★★ 没出过画面时来的错误 ⇒ 仍然走全屏错误层（不能静默）', (t) async {
    await mountPlayer(t);
    expect(debugPlayerInjectStreamErrorForProbe(kMpvMessage), isFalse,
        reason: '★ 返回的是「注入前是否已出画面」，此刻应为 false');
    await t.pump();
    final st = debugPlayerPlaybackFailureState();
    expect(st.contains('failure=-'), isTrue,
        reason: '★★ 起播阶段**不该**走非阻断横幅（用户什么都没看到，必须解释）：$st');
    expect(st.contains('error=$kMpvMessage'), isTrue,
        reason: '★★★ 起播阶段的错误必须进 `_error`（全屏 _ErrorOverlay）：$st');
    expect(find.text(kMpvMessage), findsWidgets,
        reason: '★ 全屏错误层要把 mpv 原文显示出来');
    await drain(t);
  });

  testWidgets('③ ★★★ 出过画面后的错误 ⇒ 非阻断横幅，`_error` 保持为空', (t) async {
    await mountPlayer(t);
    expect(debugPlayerMarkFirstFrameForProbe(), isTrue, reason: '★ 先要有画面');
    await t.pump();

    expect(debugPlayerInjectStreamErrorForProbe(kMpvMessage), isTrue,
        reason: '★ 返回的是「注入前是否已出画面」，此刻应为 true');
    await t.pump();

    final st = debugPlayerPlaybackFailureState();
    expect(st.contains('error=-'), isTrue,
        reason: '★★★ 播放中来的错误**不许**写进 `_error` —— '
            '写进去就会弹全屏 _ErrorOverlay，正在看的画面被整块盖掉（Owner 报的就是这个）：$st');
    expect(st.contains('failure=$kMpvMessage'), isTrue,
        reason: '★★★ 播放中的错误要进非阻断横幅字段：$st');

    expect(find.text('播放中断了（画面还在，可以重试）'), findsOneWidget,
        reason: '★★★ 非阻断横幅必须在树上（底部一条，画面继续）');
    expect(find.text('重试'), findsWidgets, reason: '★ 这条是**可恢复**的，必须给重试');
    expect(find.text(kMpvMessage), findsWidgets,
        reason: '★ mpv 原文照抄显示（诊断价值全在那句话上）');
    await drain(t);
  });

  testWidgets('④ ★★ 恢复后横幅自动收掉（已经好了就不该继续吓用户）', (t) async {
    await mountPlayer(t);
    debugPlayerMarkFirstFrameForProbe();
    await t.pump();
    debugPlayerInjectStreamErrorForProbe(kMpvMessage);
    await t.pump();
    expect(find.text('播放中断了（画面还在，可以重试）'), findsOneWidget);

    // 画面回来（mpv 重连成功 ⇒ stream.width 再发一次非空）
    debugPlayerMarkFirstFrameForProbe();
    await t.pump();
    expect(debugPlayerPlaybackFailureState().contains('failure=-'), isTrue,
        reason: '★★ 画面回来了，横幅必须收掉');
    expect(find.text('播放中断了（画面还在，可以重试）'), findsNothing);
    await drain(t);
  });

  testWidgets('⑤ ★ 静态审计：分流判据 + 新一轮起播会复位 + 错误已落盘', (t) async {
    final src = File('lib/ui/player_page.dart').readAsStringSync();

    expect(src.contains('bool _sawFirstFrame = false;'), isTrue,
        reason: '★★★ 判据字段必须在 —— 它是「出过画面」这个事实的唯一记录');
    expect(src.contains('_playbackFailure = e;'), isTrue,
        reason: '★★★ error 监听里必须把错误分流到非阻断字段');
    expect(src.contains('if (_sawFirstFrame) {'), isTrue,
        reason: '★★★ 分流必须按 `_sawFirstFrame` 判，不能一律写 `_error`');
    expect(src.contains('class _PlaybackFailureBanner extends StatelessWidget'),
        isTrue);
    expect(src.contains('onRetry: () => unawaited(_load()),'), isTrue,
        reason: '★★ 横幅的「重试」必须真的重新起播（`_load`），不能只关横幅');
    expect(src.contains('AppLog.write('), isTrue,
        reason: '★ 错误必须落盘 —— 端口随进程退出失效，事后只能靠日志');

    // 新一轮起播（_load 与 _startPlayback 两处）都要复位判据
    final resets = RegExp('_sawFirstFrame = false;').allMatches(src).length;
    expect(resets, greaterThanOrEqualTo(2),
        reason: '★★★ `_load` 与 `_startPlayback` 都必须复位「出过画面」—— '
            '否则换了条根本打不开的流，错误会被当成「可恢复中断」而**不弹全屏**'
            '（用户对着黑屏什么都没有）');
  });
}
