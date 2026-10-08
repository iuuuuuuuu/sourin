@Tags(['native-media'])
library;

// ═══════════════════════════════════════════════════════════════════════
//  ★ 本文件被标记为 `native-media`（默认不跑）—— 与
//    `zz_t42_player_keys_test.dart` / `pc_arrow_keys_test.dart` 同因
// ═══════════════════════════════════════════════════════════════════════
//
// 本文件挂**真** `PlayerPage`，而它在 `initState` 里 `Player(...)`
// 创建 media_kit 播放器 ⇒ 需要 libmpv-2.dll。实测在 `flutter_tester` 进程里
// 加载该原生库会**偶发 native 崩溃**（访问违例 c0000005，退出码 79），
// 失败形态是整文件用例一起 `did not complete`。详见 `.probe/native-media-tests.md`。
//
// 手动跑：
// ```powershell
// flutter test test/t458_hints_entry_ui_test.dart --tags native-media --concurrency=1
// ```
//
// ═══════════════════════════════════════════════════════════════════════
//  task-20 真行为测试：顶栏「快捷键」图标在触摸端**不存在**、在 PC/TV 端**存在**
// ═══════════════════════════════════════════════════════════════════════
//
// ★★ 为什么必须有一个「阳性对照」用例（PC 端 findsOneWidget）：
//   只断言「触摸端 findsNothing」是**不够**的 —— 若顶栏因为别的原因压根没渲染，
//   该断言同样会通过，于是「隐藏成功」和「什么都没渲染」无法区分。
//   PC 端那条 findsOneWidget 才是证明仪器有效的对照。
import 'dart:io';

// ★ 不要 import 'package:flutter/material.dart'：material_ui 也导出 `Icons`，
//   两个 `Icons` 会 ambiguous_import。二者 `keyboard_outlined` 的 codepoint
//   都是 0xf144 / fontFamily 'MaterialIcons'（已核 material_ui-1.4.0/lib/src/icons.dart:13770
//   与 flutter sdk icons.dart:13760）⇒ 取哪一个图标都一样，只用 material_ui。
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

/// 挂载**真实** PlayerPage（照抄 `zz_t42_player_keys_test.dart:76-95`）。
Future<void> mount(
  WidgetTester t, {
  required bool isTv,
  required bool isTouchOnly,
}) async {
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: 'task-20 快捷键入口',
        isTv: isTv,
        isTouchOnly: isTouchOnly,
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// 把挂起的定时器推完（否则用例结束报 "A Timer is still pending"）。
///
/// ★ 照抄 `zz_t42_player_keys_test.dart:97-106` 的做法与理由：有
///   `sourin_core.dll` 时会多一个 `resolveStream` 的 120s timeout。
Future<void> drain(WidgetTester t) async {
  for (var i = 0; i < 60; i++) {
    await t.pump(const Duration(seconds: 3));
  }
  RemoteBridge.instance.stop();
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

  testWidgets('★★ 阳性对照：PC 端**必须**有 1 个键盘图标', (t) async {
    await mount(t, isTv: false, isTouchOnly: false);
    expect(
      find.byIcon(Icons.keyboard_outlined),
      findsOneWidget,
      reason: '★★ 若这条不过 ⇒ 说明顶栏根本没渲染出来（仪器问题），'
          '下面「触摸端没有」就毫无意义 —— 那可能是「什么都没渲染」而不是「被隐藏」',
    );
    await drain(t);
  });

  testWidgets('★★ 触摸端**不许**有键盘图标（task-20 的核心判据）', (t) async {
    await mount(t, isTv: false, isTouchOnly: true);
    expect(
      find.byIcon(Icons.keyboard_outlined),
      findsNothing,
      reason: '★★ 触摸端没有键盘 ⇒ 这个入口点开只能是空面板，必须隐藏',
    );
    expect(
      find.byTooltip('快捷键'),
      findsNothing,
      reason: '★ 换一种 finder 再确认一遍（防「图标换了但按钮还在」）',
    );
    await drain(t);
  });

  testWidgets('★ TV 端仍有键盘图标（`kTvHints` 非空，不许被顺手改坏）', (t) async {
    await mount(t, isTv: true, isTouchOnly: false);
    expect(
      find.byIcon(Icons.keyboard_outlined),
      findsOneWidget,
      reason: '★ `kTvHints` 有 4 条 ⇒ TV 端这个入口是有内容的，不许一起关掉',
    );
    await drain(t);
  });
}
