// ═══════════════════════════════════════════════════════════════════════
//  task-53【#4b】接线守卫：全屏直播 ↑/↓ 切台
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个测试防的是**哪一类**事故
//
// ```text
// 用户第 4 条（**强调过两次**）：「直播进入全屏播放的状态下,然后可以上下切换」
// ★ 而这条功能的成立**依赖三个环节同时在位**：
//     ① `shell.dart` 每个直播 `PlayerPage(` 都要传 `onLiveChannelStep`
//     ② 播放页 `_onKey`（焦点在页内）要有切台分支
//     ③ 播放页 `_onHardwareKey`（焦点**不在**页内）也要有 —— ★ 真机实测抓到的缺口
// ⇒ 任何一环被删/被改，功能就**静默失效**（按键退化成调音量，不报错）。
// ```
//
// # ★ 为什么必须"按块"检查，而不是 grep
//
// ```text
// `onLiveChannelStep:` 在 `shell.dart` 里只出现 **3 次**，
// 而 `PlayerPage(` 出现 **6 次** ⇒ 必须判断"它落在**哪个**块的参数表里"。
// ★ 而我在 L3168-3198 插了 **31 行注释** ⇒ 参数距 `PlayerPage(` 有 36 行，
//   只扫"紧邻十来行"会**漏判** —— lead 正是这样数错的（判成"6 处全没传"）。
// ⇒ 本测试按**括号配对**取块，与注释长度无关。
// ```
//
// # ★ 为什么"能编译"不等于"接线了"
//
// ```text
// `onLiveChannelStep` 是**可选具名参数**（`this.onLiveChannelStep`）⇒
// 不传**照样编译通过**、`analyze` 也是 0 error
// ⇒ ★ 静态类型系统**管不到**这个缺口，只能靠本测试钉住。
// ```
//
// 铁律 126：判据必须能**变红**。本文件的红度证明见文件末的 `main()` 说明。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '_support/strip_comments.dart';

/// 仓库根（`flutter test` 的 cwd 就是它）
const _shellPath = 'lib/shell.dart';
const _playerPath = 'lib/ui/player_page.dart';

/// 从 [src] 里第 [start] 个字符处的 `(` 起，返回配对 `)` 的下标
int _matchParen(String src, int openIdx) {
  var depth = 0;
  for (var i = openIdx; i < src.length; i++) {
    final c = src[i];
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
      if (depth == 0) return i;
    }
  }
  throw StateError('括号不配对（从 $openIdx 起）');
}

/// 取每个 `PlayerPage(` 的**参数表原文**
List<String> _playerPageArgLists(String src) {
  final out = <String>[];
  var from = 0;
  while (true) {
    final i = src.indexOf('PlayerPage(', from);
    if (i < 0) break;
    final open = i + 'PlayerPage'.length;
    final close = _matchParen(src, open);
    out.add(src.substring(open, close + 1));
    from = close;
  }
  return out;
}

void main() {
  late String shellRaw;
  late String shell; // 剥注释后的 shell.dart
  late String playerRaw;
  late String player; // 剥注释后的 player_page.dart

  setUpAll(() {
    shellRaw = File(_shellPath).readAsStringSync();
    playerRaw = File(_playerPath).readAsStringSync();
    /*
     * ★ 必须**剥注释**后再做"有没有传参"的判断 ——
     *   否则我写的说明注释里出现 `onLiveChannelStep` 会让断言**假绿**。
     *   这是本仓既有纪律：注释里的名字不算数。
     */
    shell = stripComments(shellRaw);
    player = stripComments(playerRaw);
  });

  group('task-53【#4b】① shell.dart 的直播 PlayerPage 必须接线', () {
    test('★★ 每个带 liveChannelId 的 PlayerPage( 都必须传 onLiveChannelStep', () {
      final blocks = _playerPageArgLists(shell);
      expect(blocks, isNotEmpty, reason: '一个 PlayerPage( 都没找到 ⇒ 文件结构变了');

      final live = blocks.where((b) => b.contains('liveChannelId')).toList();
      expect(live, isNotEmpty,
          reason: '★ 没有带 liveChannelId 的 PlayerPage ⇒ 直播播放页的构造方式变了，'
              '本测试的前提失效，必须重新审视');

      final missing = live.where((b) => !b.contains('onLiveChannelStep')).toList();
      expect(
        missing,
        isEmpty,
        reason: '★★★ 有 ${missing.length} 个**直播** PlayerPage 没传 `onLiveChannelStep` '
            '⇒ `widget.onLiveChannelStep` 为 null ⇒ 播放页永远走音量分支 '
            '⇒ ★ 用户第 4 条（全屏直播里 ↑/↓ 切台）**静默失效**。\n'
            '缺的那几个块的参数表：\n${missing.join('\n---\n')}',
      );
    });

    test('★★★ 每个带 liveChannelId 的 PlayerPage( 也必须传 onLiveChannels', () {
      /*
       * ★ 用户第 3 条：「我无法在直播的播放器页面，查看所有的直播，就跟选集一样」
       * ★ 与 #4b 同一个坑：`onLiveChannels` 是**可选具名参数**
       *   ⇒ 不传照样编译、analyze 也是 0 error ⇒ 只能靠本测试钉住。
       *   ★ 而"少接一处"的表现是**那条路径没有入口**（按钮根本不显示），
       *     不是报错 —— 极难发现。
       */
      final live = _playerPageArgLists(shell)
          .where((b) => b.contains('liveChannelId'))
          .toList();
      expect(live, isNotEmpty, reason: '前提失效：找不到直播 PlayerPage');

      final missing =
          live.where((b) => !b.contains('onLiveChannels')).toList();
      expect(
        missing,
        isEmpty,
        reason: '★★★ 有 ${missing.length} 个直播 PlayerPage 没传 `onLiveChannels` '
            '⇒ `hasLiveChannels` 为 false ⇒ **「所有直播」按钮不显示** '
            '⇒ ★ 用户第 3 条（像选集一样查看所有直播）在那条路径上**不存在**。\n'
            '缺的那几个块的参数表：\n${missing.join('\n---\n')}',
      );

      final missingPick =
          live.where((b) => !b.contains('onLiveChannelPick')).toList();
      expect(
        missingPick,
        isEmpty,
        reason: '★★★ 有 ${missingPick.length} 个直播 PlayerPage 没传 `onLiveChannelPick` '
            '⇒ 列表能打开但**点不动**（点了没反应）—— 比不显示按钮更糟。',
      );
    });

    test('★ 直播块数 ≥ 3（全屏按钮 / 回看 / 遥控 三条路）', () {
      final live = _playerPageArgLists(shell)
          .where((b) => b.contains('liveChannelId'))
          .length;
      /*
       * ⚠️ 用 `>=` 而不是 `==`：将来新增直播入口是**好事**，
       *    不该让测试变红；但**变少**说明有人删了入口，必须知道。
       */
      expect(live, greaterThanOrEqualTo(3),
          reason: '★ 直播 PlayerPage 只剩 $live 个（应 ≥3：onWatchLive / onWatchReplay / _openLiveChannel）'
              '⇒ 有人删了入口，请确认是否有意为之');
    });

    test('★ 非直播块（点播/追更）**不应**接线（避免语义漂移）', () {
      final nonLive = _playerPageArgLists(shell)
          .where((b) => !b.contains('liveChannelId'))
          .toList();
      for (final b in nonLive) {
        expect(b.contains('onLiveChannelStep'), isFalse,
            reason: '★ 非直播的 PlayerPage 也接了 onLiveChannelStep ⇒ '
                '点播里按 ↑/↓ 会变成"切频道"（而它没有频道）⇒ 行为错乱');
      }
    });
  });

  group('task-53【#4b】② 播放页两条入口都要有切台分支', () {
    test('★★ `_onKey`（焦点在页内）有直播切台分支', () {
      expect(
        player.contains('_isLive && widget.onLiveChannelStep != null'),
        isTrue,
        reason: '★★ `_onKey` 里少了 `_isLive && widget.onLiveChannelStep != null` '
            '⇒ 焦点正常时按 ↑/↓ 只会调音量',
      );
      expect(player.contains('直播 ↓ ⇒ 下一个台'), isTrue,
          reason: '★ `_onKey` 的下切台分支没了');
      expect(player.contains('直播 ↑ ⇒ 上一个台'), isTrue,
          reason: '★ `_onKey` 的上切台分支没了');
    });

    test('★★★ `_onHardwareKey`（焦点**不在**页内）也有切台兜底', () {
      /*
       * ★★★ 这一条是**真机实测抓到的真缺口**（2026-09-26）：
       * ```text
       * 直播页 → 点播放器全屏按钮 → 按 ↓
       *   [PLAYER-KEY] ⓪ 入口：硬件 handler 收到 Arrow Down   ← 到了
       *   ★ 没有 `⓪ 入口：收到 Arrow Down`（`_onKey` 那条）
       *   ★ 没有切台 ⇒ 因为进全屏后焦点**仍留在直播页**
       * ```
       * ⇒ 只修 `_onKey` 不够，必须两条入口都有。
       */
      expect(
        player.contains('⓪ 硬件兜底：直播 ↓ ⇒ 下一个台'),
        isTrue,
        reason: '★★★ `_onHardwareKey` 里少了直播 ↓ 兜底 ⇒ '
            '**焦点不在播放页时**（刚进全屏、没点过画面）按 ↓ 不切台 '
            '—— 这正是 lead 真机复现的那个 bug',
      );
      expect(player.contains('⓪ 硬件兜底：直播 ↑ ⇒ 上一个台'), isTrue,
          reason: '★★★ `_onHardwareKey` 里少了直播 ↑ 兜底');
    });

    test('★★ 两条入口**互斥**（靠 `_focusIsInsideThisPage` 防双触发）', () {
      /*
       * ★ 若少了这道门控，焦点在页内时两条路都会跑 ⇒ **一次按键切两个台**。
       *   真机实测过：点画面后按 ↓，`直播 ↓` 只出现 1 行 ✓
       */
      expect(player.contains('_focusIsInsideThisPage(f)) return false;'), isTrue,
          reason: '★★ 少了"焦点已在页内 ⇒ 让给 `_onKey`"的门控 ⇒ '
              '一次按键会**切两个台**（双触发）');
    });

    test('★ 兜底分支必须**只在直播时**生效（非直播 ↑/↓ 仍是音量）', () {
      // 取 `_onHardwareKey` 里直播兜底那段的原文，确认它有 _isLive 前置条件
      final i = player.indexOf('⓪ 硬件兜底：直播 ↓ ⇒ 下一个台');
      expect(i, greaterThan(0), reason: '找不到兜底分支');
      // 往前找最近的 `if (_isLive`（兜底分支的守卫）
      final guard = player.lastIndexOf('if (_isLive', i);
      expect(guard, greaterThan(0),
          reason: '★ 兜底分支前面没有 `if (_isLive` ⇒ '
              '**点播/回看**里按 ↑/↓ 会试图切频道（而它们没有频道）');
      // 守卫与分支之间不能有别的 `if (`（否则可能落在别的分支里）
      final between = player.substring(guard, i);
      expect(between.contains('if (k == LogicalKeyboardKey.space)'), isFalse,
          reason: '★ 守卫与兜底分支之间夹了别的分支 ⇒ 兜底可能不在 _isLive 作用域内');
    });
  });

  group('task-53【#4b】③ 分工不能被改回 ValueNotifier', () {
    test('★★ shell 传的是**直接回调**，不是 `_liveChannelStep.value =`', () {
      /*
       * ★ 原因（Flutter 源码依据）：
       *   `flutter/src/foundation/change_notifier.dart:558-563`
       *       set value(T newValue) { if (_value == newValue) return; ... }
       *   ⇒ 连按两次 ↓（delta 都是 +1）**第二次不通知** ⇒ 只切一个台。
       * ★ 真机实测过：连按 3 次 ↓ 精确前进 3 个台（用直接回调）。
       *
       * ⚠️ 判据**只针对直播 `PlayerPage(` 块的参数表** ——
       *    `shell.dart:804` 那处 `liveChannelStep: (delta) => _liveChannelStep.value = delta`
       *    是**遥控**（task-39）的**脉冲**约定，那里去重是**有意**的
       *    （它的监听者"收到就执行一次"），**不是**本任务的路径。
       *    ⇒ 若用全文件 `contains` 会把那处误判成回归（我第一版就这么错了）。
       */
      final live = _playerPageArgLists(shell)
          .where((b) => b.contains('liveChannelId'))
          .toList();
      expect(live, isNotEmpty, reason: '前提失效：找不到直播 PlayerPage');
      for (final b in live) {
        expect(b.contains('_liveChannelStep.value = delta'), isFalse,
            reason: '★★ 直播 PlayerPage 改回了 `_liveChannelStep.value = delta` ⇒ '
                '连按同方向会**丢按键**（ValueNotifier 去重相等的值）');
        expect(b.contains('stepChannelForFullscreen'), isTrue,
            reason: '★ 直播 PlayerPage 没调 `stepChannelForFullscreen` ⇒ '
                '直播页不再回答"下一个是哪个"');
      }
    });

    test('★★ 直播页侧仍是"只改选中、不起播"（防双声）', () {
      final live = File('lib/ui/live_page.dart').readAsStringSync();
      final body = stripComments(live);
      expect(body.contains('stepChannelForFullscreen'), isTrue,
          reason: '★ `stepChannelForFullscreen` 没了');
      /*
       * ★ 该函数**不许**出现起播调用 —— 否则全屏播放页的 mpv 与
       *   隐藏直播页的 mpv 会**同时出声**（回声/重音）。
       */
      final i = body.indexOf('stepChannelForFullscreen(int delta)');
      expect(i, greaterThan(0), reason: '找不到 stepChannelForFullscreen 定义');
      final seg = body.substring(i, (i + 3000).clamp(0, body.length));
      // 取到函数体结束（下一个顶层 `\n  }` 之前）
      final end = seg.indexOf('\n  }\n');
      final fn = end > 0 ? seg.substring(0, end) : seg;
      expect(fn.contains('_startPlayback'), isFalse,
          reason: '★★★ `stepChannelForFullscreen` 里出现了 `_startPlayback` ⇒ '
              '**两个 mpv 同时出声**（全屏那个 + 隐藏直播页那个）');
      expect(fn.contains('_loadStream'), isFalse,
          reason: '★★★ `stepChannelForFullscreen` 里出现了 `_loadStream` ⇒ 同上，会双声');
    });
  });

  group('task-53【③】「所有直播」列表面板（用户第 3 条）', () {
    test('★★★ 直播页侧：只查询、不起播（与切台同一条纪律）', () {
      final live = stripComments(File('lib/ui/live_page.dart').readAsStringSync());
      final i = live.indexOf('channelsForFullscreen()');
      expect(i, greaterThan(0),
          reason: '★★ `channelsForFullscreen` 没了 ⇒ 播放页拿不到频道列表 '
              '⇒ 「所有直播」面板永远是空的');
      /*
       * ★ 取该函数体 —— 用**括号配对**，不要用 `\n  }\n` 找结尾。
       *
       * ⚠️ 我第一版就是按 `\n  }\n` 找的，结果**测出假红**：
       *    `stripComments` 把注释替换成**等量空白**（保留换行以稳定行号），
       *    所以注释块变成一串 `\n  \n  \n` —— 而函数体之后紧跟的就是它，
       *    `\n  }\n` 在 2000 字窗口里**找不到**（`end = -1`）⇒
       *    退化成"整段 2000 字"，里面当然包含后面别的函数的 `setState(`。
       * ⇒ ★ 这是**测试工具的 bug**，不是生产代码的问题（铁律 153：
       *   判据本身必须先被验证）。
       */
      final open = live.indexOf('{', i);
      expect(open, greaterThan(i), reason: '找不到函数体的开括号');
      final close = _matchParen(live, open);
      final fn = live.substring(open, close + 1);
      for (final bad in ['_startPlayback', '_loadStream', '_select(', 'setState(']) {
        expect(fn.contains(bad), isFalse,
            reason: '★★★ `channelsForFullscreen` 里出现了 `$bad` ⇒ 它不是纯查询 ⇒ '
                '打开列表就会**换台/双声**（面板每帧都调它）');
      }
    });

    test('★★★ 两条切台路（↑/↓ 与点选）必须共用同一个"采纳"实现', () {
      /*
       * ★ 若各写一份，"点选"与"上下键"迟早分叉 ——
       *   典型症状：上下键切台正常，点选切台**双声**或黑屏（少清了线路）。
       */
      expect(player.contains('Future<void> _adoptLiveChannel('), isTrue,
          reason: '★★ `_adoptLiveChannel`（共用实现）没了 ⇒ 两条路各写一份 ⇒ 必然分叉');
      final n = '_adoptLiveChannel(pick)'.allMatches(player).length;
      expect(n, greaterThanOrEqualTo(2),
          reason: '★★ 只有 $n 处调用 `_adoptLiveChannel`（应 ≥2：`_switchLiveChannel` + '
              '`_pickLiveChannel`）⇒ 有一条路没走共用实现');
    });

    test('★★★ 面板打开时 ↑/↓ 必须让给面板（否则"选不了台"）', () {
      /*
       * ★ 不加这条门控：用户想在列表里往下移动，结果**每按一次就换一个台**
       *   ⇒ 完全选不了。与 `live_page.dart::_allChannelsOpen` 同一纪律。
       */
      expect(
        player.contains('_liveChannelsOpen && _arrowKeys.contains(k)'),
        isTrue,
        reason: '★★★ 少了「面板打开 ⇒ 方向键归面板」的门控 ⇒ '
            '用户在列表里按 ↑/↓ 会**不停换台**，根本选不了',
      );
    });

    test('★★ 面板必须计入 `_anySheetOpen`（否则 Enter 会穿透成全屏）', () {
      final i = player.indexOf('bool get _anySheetOpen');
      expect(i, greaterThan(0), reason: '找不到 _anySheetOpen');
      final seg = player.substring(i, (i + 400).clamp(0, player.length));
      expect(seg.contains('_liveChannelsOpen'), isTrue,
          reason: '★★ `_anySheetOpen` 漏了 `_liveChannelsOpen` ⇒ '
              '面板开着按 Enter 会**变成全屏**（用户以为面板坏了）');
    });

    test('★★ 面板能被 Esc 关掉', () {
      /*
       * ⚠️ 断言的是 `player`（**已剥注释**）⇒ 不能把注释文本写进判据。
       *    我第一版写成 `'_liveChannelsOpen) {\n        // ★ task-53【③】'`
       *    —— 那串注释已经被 `stripComments` 替换成空白 ⇒ 永远找不到（假红）。
       * ★ 正确判据：Esc 级联里出现 `else if (_liveChannelsOpen)` 且紧跟
       *    把 `_liveChannelsOpen` 置 false 的语句。
       */
      final m = RegExp(
        r'else if \(_liveChannelsOpen\)\s*\{\s*setState\(\(\) => _liveChannelsOpen = false\)',
      ).firstMatch(player);
      expect(m, isNotNull,
          reason: '★★ Esc 级联里没有"`_liveChannelsOpen` ⇒ 关掉它"的分支 ⇒ '
              '用户按 Esc 关不掉面板（其它浮层都能关 ⇒ 不一致，用户以为 Esc 坏了）');
    });

    test('★ 按钮判据是"直播 + 已接线"（非直播不显示）', () {
      // ⚠️ 同样只断言**代码**（`player` 已剥注释）—— 见上一条的说明。
      final m = RegExp(
        r'hasLiveChannels:\s*_isLive && widget\.onLiveChannels != null',
      ).firstMatch(player);
      expect(m, isNotNull,
          reason: '★ `hasLiveChannels` 的判据变了 ⇒ 可能让**点播**页也出现'
              '「所有直播」按钮（点开是空的），或直播时不显示按钮');
    });
  });
}
