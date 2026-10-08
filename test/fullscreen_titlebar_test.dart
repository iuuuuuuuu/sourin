// ═══════════════════════════════════════════════════════════════════════
//  播放页标题栏的三态 —— 窗口 / 全屏 / 退出
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户先后提了三条，看起来矛盾其实不矛盾（2026-09-24）
//
// ```text
// ① 「详情页和播放页都没有操作条，无法拖动」
//    → 详情页修好了（挂到 MaterialApp.builder）
//
// ② 「播放器页面没有顶部的可拖动 缩小 放大 关闭 的操作条，
//    在桌面端播放页面 无法拖动窗口」
//    → 我上一轮给播放页加了"主动隐藏"，做反了 → 去掉隐藏
//
// ③ 「全屏的时候不能显示哪个顶部的操作条啊」
//    → 全屏时**要**隐藏
// ```
//
// # 归纳成一张表（这才是真正的要求）
//
// ```text
// 场景              标题栏   理由
// 首页/详情页       显示     窗口拖动区
// 播放页（窗口模式） 显示     ★ 桌面端唯一拖动区，少了就拖不动
// 播放页（全屏）     隐藏     画面占满；全屏下没有"拖窗口"需求
// 退出播放器         恢复显示 否则回到详情页拖不动（= 重现 bug ②）
// ```
//
// ⚠️ ②③ 的差别只在**全屏与否** —— 我第一版把"播放页"和"全屏"
//    当成了同一件事，所以每次都只做对一半。
//
// # 另一个必须成对的动作：OS 全屏
//
// `titleBarVisible` 只管**界面**；窗口是否真的全屏由
// `windowManager.setFullScreen()` 管。两者必须同步，
// 而且**退出播放器时必须一起还原** —— 否则
// 「全屏看片 → 点返回 → 详情页仍是全屏且没标题栏」= 用户被困住。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('播放页标题栏三态（静态断言真实路径）', () {
    late String player;

    setUpAll(() {
      player = File('lib/ui/player_page.dart').readAsStringSync();
    });

    test('★ 播放页**窗口模式**不得隐藏标题栏（桌面端唯一拖动区）', () {
      /*
       * 这条对应 bug ②。`initState` 里若出现 `titleBarVisible.value = false`
       * 就是把用户的拖动区拿掉了。
       */
      final initStateIdx = player.indexOf('void initState()');
      final disposeIdx = player.indexOf('void dispose()');
      expect(initStateIdx, greaterThan(0));
      expect(disposeIdx, greaterThan(initStateIdx));

      final initBody = player.substring(initStateIdx, disposeIdx);
      expect(
        initBody.contains('titleBarVisible.value = false;'),
        isFalse,
        reason: '★ `initState` 里**不得**隐藏标题栏 —— '
            '播放页在窗口模式下必须留可拖动区。'
            '用户明确反馈过「在桌面端播放页面 无法拖动窗口」。',
      );
    });

    test('★ 全屏时**必须**隐藏标题栏', () {
      expect(
        player.contains('titleBarVisible.value = !next;'),
        isTrue,
        reason: '`_toggleFullscreen` 里必须按全屏状态同步标题栏 —— '
            '全屏(true) → 隐藏(false)；退出全屏(false) → 显示(true)。'
            '用户明确说过「全屏的时候不能显示哪个顶部的操作条啊」。',
      );
    });

    test('★ 全屏必须真的调 OS 全屏（不能只改标志位）', () {
      expect(
        player.contains('windowManager.setFullScreen('),
        isTrue,
        reason: '桌面全屏必须调 `windowManager.setFullScreen()` —— '
            '只 `setState` 改标志位的话窗口纹丝不动'
            '（原版用浏览器 Fullscreen API 是页内全屏，Flutter 没等价物）。',
      );
    });

    test('★ 退出播放器必须走统一出口（否则全屏状态会残留）', () {
      /*
       * 播放器有 3 条退出路径（返回按钮 / 错误浮层 / 键盘返回键）。
       * 必须都走 `_exitPlayer` —— 它会在 pop 前 await 退出全屏。
       * 直接 `Navigator.pop` 会让用户回到"全屏的详情页"。
       */
      expect(
        player.contains('Future<void> _exitPlayer() async'),
        isTrue,
        reason: '必须有统一的退出方法（含"先退全屏再 pop"的逻辑）',
      );
      expect(
        player.contains('if (_fullscreen) {\n      await _toggleFullscreen();'),
        isTrue,
        reason: '`_exitPlayer` 必须**先 await 退出全屏**再 pop —— '
            'fire-and-forget 会在页面销毁后才生效，中间用户看到全屏的详情页。',
      );

      /*
       * ⚠️ 必须**先去掉注释行**再数（第一版没去，结果数到了注释里
       *    那句「我原来三处都直接写 `Navigator.of(context).maybePop()`」
       *    —— 它把 1 处真实调用数成了 2 处，测试假失败）。
       *
       * 教训：静态断言里做文本匹配时，**注释也会被匹配到**。
       * 这类假失败会让人去改本来正确的代码。
       */
      final codeOnly = player
          .split('\n')
          .where((l) {
            final t = l.trimLeft();
            return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
          })
          .join('\n');

      final directPops =
          RegExp(r'Navigator\.of\(context\)\.maybePop\(\)').allMatches(codeOnly).length;
      expect(
        directPops,
        1,
        reason: '源码里应只剩 `_exitPlayer` 内部那一处 `maybePop()` —— '
            '其它地方若还有，说明某条退出路径绕过了全屏还原'
            '（实测有 3 条路径：返回按钮 / 错误浮层 / 键盘返回键）。'
            '当前发现 $directPops 处。',
      );
    });

    test('★ dispose 必须兜底退出全屏 + 恢复标题栏', () {
      /*
       * ⚠️ 取 `dispose` 的方法体**必须用结束标记定界**，不能用固定长度窗口。
       *
       * # 真机实测踩到的（2026-09-27，task-63）
       *
       * 第一版写的是 `player.substring(disposeIdx, disposeIdx + 2200)`。
       * 而 `titleBarVisible.value = true;` 原本落在 **+2017**，安全；
       * 我在 `dispose` 里新增了一段"注销两个 MediaSession 回调"的注释后，
       * 它被推到 **+2363** ⇒ **刚好看不见** ⇒ 这条断言**假红**：
       * ```text
       * Expected: true / Actual: <false>
       * reason: `dispose` 必须恢复标题栏（幂等）
       * ```
       * ★ 而生产代码**完全正确** —— 被"改坏"的是**判据的取样窗口**。
       *
       * # 为什么固定窗口一定会出事
       * ```text
       * 窗口大小是**猜**的（"2200 应该够"）⇒
       * 而 `dispose` 的长度会随**任何**合理改动变化（加注释、加清理、加 await）
       * ⇒ 判据的取样范围与"被测事实"**无关地漂移**
       * ⇒ 它的失败不表示"功能坏了"，只表示"我猜的窗口小了"
       * ```
       * ⇒ 用**下一个成员声明**当结束标记（`build`），并在取到后**断言**标记存在：
       *   ```text
       *   若将来 `build` 改名/被移动 ⇒ 立刻报"找不到结束标记"
       *   —— 而不是静默退回一个错误窗口（那会变成上面那种假红）
       *   ```
       */
      final disposeIdx = player.indexOf('void dispose()');
      expect(disposeIdx, greaterThan(0), reason: '找不到 `void dispose()`');

      // ★ 结束标记：`dispose` 之后的下一个成员 `build`
      final endMarker = '\n  @override\n  Widget build(BuildContext context) {';
      final endIdx = player.indexOf(endMarker, disposeIdx);
      expect(endIdx, greaterThan(disposeIdx),
          reason: '★★ 找不到 `dispose` 的结束标记（`build`）—— '
              '说明该方法的后续成员变了。**不要**退回固定长度窗口，'
              '请更新这个标记（见本用例上方长注释）');
      final disposeBody = player.substring(disposeIdx, endIdx);

      expect(
        disposeBody.contains('windowManager.setFullScreen(false)'),
        isTrue,
        reason: '`dispose` 要兜底退全屏 —— 万一将来加了新 pop 路径'
            '忘了走 `_exitPlayer`，至少不会留下困住用户的窗口。',
      );
      expect(
        disposeBody.contains('titleBarVisible.value = true;'),
        isTrue,
        reason: '`dispose` 必须恢复标题栏（幂等）',
      );
    });

    test('★ Esc 语义：全屏时先退全屏，不直接返回', () {
      expect(
        player.contains('} else if (_fullscreen) {'),
        isTrue,
        reason: '返回键分支里必须先判断全屏 —— '
            '否则「全屏 → Esc → 回详情页但窗口还是全屏的」用户会被困住。'
            '这是所有播放器的通行约定（浏览器 Fullscreen API 同款）。',
      );
      expect(
        player.contains('unawaited(_toggleFullscreen());'),
        isTrue,
        reason: '全屏时 Esc 应退全屏（fire-and-forget，因为 _onKey 是同步的）',
      );
    });
  });
}
