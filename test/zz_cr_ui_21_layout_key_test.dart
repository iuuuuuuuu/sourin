// ═══════════════════════════════════════════════════════════════════════
//  CR-21 回归门禁：屏蔽规则必须进 _layoutKey
// ═══════════════════════════════════════════════════════════════════════
//
// # 缺陷（CR-21）
//
// danmaku_overlay.dart 的 _ensureLayout() 里屏蔽规则**参与了排版**：
//   final visible = <DanmakuComment>[
//     for (final c in widget.comments)
//       if (DanmakuConfig.shouldShow(mode: c.mode, text: c.text)) c,
//   ];
// 但这一轮的排版要不要重算，**只**看 _layoutKey：
//   final key = <Object?>[canvas.width, canvas.height, fontSize, pxPerSecond,
//                     widget.area, widget.comments.length,
//                     identityHashCode(widget.comments)];
//   if (old != null && _sameKey(old, key)) return;   // ← 直接复用旧排版
// _layoutKey 里**没有** showScroll / blockWords / blockRegex …
//  ⇒ 用户勾掉"顶部弹幕"或加一条屏蔽词，画面**不会重新排版**：
//     该消失的弹幕还留在屏幕上（= "改了没反应"）。
//
// # 判据（行为级）
//
// 1. 无屏蔽规则时 pump → debugDanmakuLastStats.placed 应等于总条数
//  2. 只改屏蔽词（或只关一个开关），**comments 列表全程复用同一个实例**
//     ——★ 这正是本门禁的命门：`identityHashCode(list)` 前后相等，
//       所以 key 里既有 7 项全等，唯一变量只剩"规则进没进 key"。
//       【2026-10-10 修正】这里原本每次重建都调 comments() 造新列表，
//       identityHashCode 每帧都变，key 自然失配、重排照跑 —— 于是
//       在**没修的生产代码**上也 3 条全绿（假门禁，已实测复现）。
// 3. 改完再 pump 一帧 → placed 必须变少
//
// ★ 关键前提：改规则必须**真的让 DanmakuOverlay 重建**。
//   规则读的是全局静态偏好，改它不会标脏任何 widget；真实界面是
//   player_page 的 ValueNotifier 驱动重建。这里用同一个套路搭一个
//   极小的宿主（ValueListenableBuilder + bump），只负责逼出重建，
//   排版判断仍在 DanmakuOverlay 自己身上。

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/widgets/danmaku_overlay.dart';

void main() {
  setUp(() {
    UiPrefs.debugResetForTest();
  });

  /// 三条滚动弹幕 + 一条顶部固定，其中一条文本是"剧透"
  List<DanmakuComment> comments() => <DanmakuComment>[
        const DanmakuComment(cid: 1, time: 0, text: '前方高能'),
        const DanmakuComment(cid: 2, time: 0, text: '剧透'),
        const DanmakuComment(cid: 3, time: 0, text: '普通弹幕'),
        const DanmakuComment(cid: 4, time: 0, text: '顶部提示', mode: DanmakuMode.top),
      ];

  /// UiPrefs.set() 会排一个 300ms 去抖落盘定时器（ui_prefs.dart:107-113）；
  /// 改屏蔽词/开关就会多一个，不抽干 flutter_test 收尾会报 pending timers。
  Future<void> settle(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(milliseconds: 450));
  }

  /// 返回 bump 闭包：调用它就会带着新 comments 列表重建一次 overlay。
  Future<void Function()> pumpOverlay(WidgetTester t) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final rebuild = ValueNotifier<int>(0);
    addTearDown(rebuild.dispose);
    // ★ 全程只造这一份列表实例：identityHashCode 固定不变，
    //   于是"只有规则变了"成为重排的唯一变量。若每次重建换新列表，
    //   identityHashCode 会跟着变，key 照样失配 ⇒ 门禁变假绿。
    final list = comments();

    Widget overlay(int n) => Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(
          width: 1280,
          height: 720,
          child: DanmakuOverlay(
            aspect: 16 / 9,
            comments: list,
            position: Duration.zero,
            playing: false,
          ),
        ),
      ),
    );

    await t.pumpWidget(
      ValueListenableBuilder<int>(
        valueListenable: rebuild,
        builder: (context, n, __) => overlay(n),
      ),
    );
    await t.pump();
    return () => rebuild.value++;
  }

  testWidgets('★ 改屏蔽词后必须重新排版（该消失的弹幕消失）', (t) async {
    debugDanmakuResetProbeStats();
    final bump = await pumpOverlay(t);
    final total = comments().length;

    final before = debugDanmakuLastStats;
    expect(before, isNotNull, reason: '第一帧应当已经画过一次（有 stats）');
    expect(before!.placed, total, reason: '无屏蔽规则时四条都该进排版');

    // ★ 只有屏蔽词变了
    DanmakuConfig.setBlockWords('剧透');
    expect(DanmakuConfig.blockWords, orderedEquals(<String>['剧透']),
        reason: '前提：屏蔽词确实写进去了');
    bump();
    await settle(t);

    final after = debugDanmakuLastStats;
    expect(after, isNotNull);
    expect(
      after!.placed,
      lessThan(before.placed),
      reason: '★ 加了屏蔽词之后 placed 必须变少（CR-21：key 里没有规则 ⇒ '
      '旧排版被复用 ⇒ 该消失的弹幕还留着）',
    );
    expect(after.placed, total - 1, reason: '只有"剧透"那一条该被滤掉');
  });

  testWidgets('★ 关掉"顶部弹幕"开关后必须重新排版', (t) async {
    debugDanmakuResetProbeStats();
    final bump = await pumpOverlay(t);
    final total = comments().length;

    final before = debugDanmakuLastStats;
    expect(before, isNotNull);
    expect(before!.placed, total);

    DanmakuConfig.setShowTop(false);
    bump();
    await settle(t);

    final after = debugDanmakuLastStats;
    expect(after, isNotNull);
    expect(
      after!.placed,
      lessThan(before.placed),
      reason: '★ 关掉顶部弹幕后，那条固定弹幕不该再进排版',
    );
  });

  testWidgets('屏蔽词改回来后也要能重新排版（双向都对）', (t) async {
    debugDanmakuResetProbeStats();
    DanmakuConfig.setBlockWords('剧透');
    final bump = await pumpOverlay(t);
    final total = comments().length;

    final blocked = debugDanmakuLastStats;
    expect(blocked, isNotNull);
    expect(
      blocked!.placed,
      total - 1,
      reason: '开局就屏蔽 ⇒ 先确认这条能生效（否则下面测不出"改回来"）',
    );

    DanmakuConfig.setBlockWords('');
    bump();
    await settle(t);

    final back = debugDanmakuLastStats;
    expect(back, isNotNull);
    expect(
      back!.placed,
      total,
      reason: '★ 撤销屏蔽词也要重新排版（key 得能区分"空"和"有"）',
    );
  });
}