// ═══════════════════════════════════════════════════════════════════════
//  CR-20 回归门禁：屏蔽词输入框不能每帧重建 controller
// ═══════════════════════════════════════════════════════════════════════
//
// # 缺陷（CR-20）
//
// danmaku_settings_dialog.dart 的 _blockWordsField() 原来每次 build 都：
//   final ctl = TextEditingController(text: DanmakuConfig.blockWords.join('\n'));
//   return TextField(controller: ctl, …);
// 并把文本**回填成规范化后的偏好值**
//  ⇒ 敲第一个字符 → onChanged → setBlockWords → 宿主 onChanged 重建对话框
//  ⇒ build 又 new 一个 controller，文本被刷回 blockWords.join('\n')
//  ⇒ **每敲一个字符就被重置一次**，第二个屏蔽词根本输不进去。
//
// # 机制（已在 SDK 里核对过，不是猜的）
//
// EditableText._value 就是 widget.controller.value（editable_text.dart:4028）
// ⇒ controller 换人，显示文本立刻跟着换。
// didUpdateWidget（editable_text.dart:3437-3441）在 controller 变化时
// removeListener/addListener + _updateRemoteEditingValueIfNeeded()
// ⇒ 框里显示的永远是偏好里的规范化文本。
//
// # 判据（行为级，不是文本扫描）
//
// 宿主每次收到 onChanged 就**真的重建**整棵对话框（ValueNotifier 驱动，
// 就是 player_page 那条路径），然后逐段输入，断言**框里的 controller.text**
// 与输入同步增长。
//
// ★ 为什么断言 controller.text 而不是 find.text：
//   find.text 走 _TextWidgetFinder.matchesText，是 textToMatch == text
//   （C:/Users/iuuuuuuuu/flutter/packages/flutter_test/lib/src/finders.dart:1587-1589）
//   ——**整串相等**才命中。多行输入框 EditableText.RichText 里每行各是独立
//   TextSpan，没有任何 Text widget 的 text 恰好等于单个词，
//   所以 find.text('前方高能') 在**正确代码上也永远为 0** —— 那是假门禁。
//   （RED 那轮它确实红了，但红的原因不是缺陷，是判据本身写错了。）
//
// ★ 缺陷版本的关键症状：setBlockWords 会把行尾换行规范化掉
//   （blockWords 逐行 trim/drop-empty），重建后框里变回 '剧透' ——
//   用户刚敲下的换行没了，**第二行永远开不了头**。

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

void main() {
  // 屏蔽词偏好是**全局静态**的 ⇒ 每次回到干净初值，
  // 否则上个用例的词会漏进来（假绿/假红都从这里来）。
  setUp(() {
    UiPrefs.debugResetForTest();
  });

  const state = DanmakuSettingsState(
    enabled: true,
    appId: '',
    appSecret: '',
    fontScale: 1.0,
    opacity: 1.0,
    speed: 8.0,
    area: 1.0,
  );

  /// 屏蔽词那个 TextField（在 AppId/AppSecret 之后）
  Finder blockWordsField() => find.byType(TextField).last;

  String boxText(WidgetTester t) =>
      t.widget<TextField>(blockWordsField()).controller?.text ?? '';

  /// UiPrefs.set() 会排一个 300ms 去抖落盘定时器（ui_prefs.dart:107-113），
  /// 每改一次屏蔽词就多一个；不抽干它，flutter_test 收尾会报 pending timers。
  Future<void> settle(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(milliseconds: 450));
  }

  /// 宿主：onChanged 每来一次就重建一次对话框（player_page 的真实路径）。
  /// 返回收尾闭包；Element 被复用 ⇒ state 不被 dispose，
  /// 所以测的正是"同一个 state 内部重建"这条路径。
  Future<void Function()> pumpDialog(WidgetTester t) async {
    t.view.physicalSize = const Size(1200, 1600);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final rebuild = ValueNotifier<int>(0);
    addTearDown(rebuild.dispose);
    var changed = 0;
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Stack(
          children: <Widget>[
            ValueListenableBuilder<int>(
              valueListenable: rebuild,
              builder: (context, _, __) => DanmakuSettingsDialog(
                state: state,
                onSetEnabled: (_) {},
                onSetAppId: (_) {},
                onSetAppSecret: (_) {},
                onSetFontScale: (_) {},
                onSetOpacity: (_) {},
                onSetSpeed: (_) {},
                onSetArea: (_) {},
                onClearCredentials: () {},
                onReload: () {},
                onClose: () {},
                onChanged: () {
                  changed++;
                  rebuild.value++;
                },
              ),
            ),
          ],
        ),
      ),
    ));
    await t.pump();
    return () {
      expect(changed, greaterThan(0), reason: '改屏蔽词必须通知宿主');
    };
  }

  testWidgets('★ 第二个词必须输得进去（连敲两行不丢）', (t) async {
    await pumpDialog(t);
    await t.showKeyboard(blockWordsField());

    await t.enterText(blockWordsField(), '剧透');
    await settle(t);
    expect(DanmakuConfig.blockWords, orderedEquals(<String>['剧透']),
        reason: '第一个词应当落进偏好');
    expect(boxText(t), '剧透', reason: '框里应当是刚敲的那个词');

    // ★ 换行 —— buggy 版就在这里把换行吃掉
    await t.enterText(blockWordsField(), '剧透\n');
    await settle(t);
    expect(boxText(t), '剧透\n',
        reason: '★ 刚敲下的换行不能被重建刷掉，否则第二行永远开不了头');

    await t.enterText(blockWordsField(), '剧透\n前方高能');
    await settle(t);
    expect(DanmakuConfig.blockWords, orderedEquals(<String>['剧透', '前方高能']),
        reason: '★ 第二个屏蔽词必须真的落进偏好');
    expect(boxText(t), '剧透\n前方高能',
        reason: '★ 框里必须同时留着两个词（buggy 版只剩第一个）');
  });

  testWidgets('★ 逐字敲入时不能被重建冲掉', (t) async {
    await pumpDialog(t);
    await t.showKeyboard(blockWordsField());

    var step = '';
    for (final next in <String>['剧', '剧透', '剧透\n', '剧透\n前', '剧透\n前方']) {
      step = next;
      await t.enterText(blockWordsField(), next);
      await settle(t);
      expect(boxText(t), next,
          reason: '★ 宿主每收到一次 onChanged 就重建对话框；输入到 '
          '这一段时框里的内容被刷掉了');
    }
    expect(step, '剧透\n前方', reason: '前提：循环确实跑到了最后一段');
    expect(
      DanmakuConfig.blockWords,
      orderedEquals(<String>['剧透', '前方']),
      reason: '★ 偏好里应是两个完整的词',
    );
  });

  testWidgets('屏蔽词改完：宿主回调必须被触发（面板自己会重建）', (t) async {
    final assertRebuilt = await pumpDialog(t);
    await t.enterText(blockWordsField(), '剧透');
    await settle(t);
    assertRebuilt();
  });
}