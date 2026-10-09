@Tags(['native-media'])
// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 2026-10-08（Owner 追加）顶栏与底栏的**显隐联动**
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话（逐字，附截图）：
// > 现在下面的底栏的会遵循我说的逻辑隐藏了,但是上面的这个也是一样的规则,
// > 而且上面的这个跟下面的 是要联动的,隐藏一起隐藏,
// > 我说的触发条件 触发了,然后也要显示,知道吧
//
// # 改前的两个缺陷（两个都要修，只修一个仍然不联动）
// ```text
// ① 顶栏**从不消失** —— 外层判据是
//      `if (_controlsVisible || _canUseFloatingBack)`
//    而 `_canUseFloatingBack`（player_page.dart:6992）=
//      `Device.isDesktop && _error == null && !_anySheetOpen`
//    ⇒ 桌面端正常播放时**恒为 true** ⇒ 顶栏无条件渲染。
//
// ② 就算把它卸下来，那条渐变条也**不会淡** ——
//    `_applyControlsMotion()` 原来只在 `_showControls()` 里被调，
//    隐藏路径（_armHideTimer 的 Timer 回调）里没人调它
//    ⇒ `_controlsFade.value` 恒 = 1.0
//    ⇒ `Opacity(opacity: 1.0)` 画得和"显示"时**一模一样**。
// ```
//
// # 修法与「联动」的实现
// ```text
// ① `_armHideTimer()` 的隐藏回调里补上 `_applyControlsMotion()`
//    ⇒ 隐藏时动画真的往 0 走；
// ② 顶栏**常挂**（去掉外层 `if`），渐变条的 `visible` 改成
//    `_controlsVisible && _error == null` —— 与底栏**同一个真源**；
// ③ 两条读的是**同一个** `_controlsFade` 实例（宿主传下去）
//    ⇒ 数值必然相等 ⇒ 「隐藏一起隐藏、显示一起显示」是**结构性**保证，
//      不是靠两处各写一遍判据碰巧一致。
// ```
//
// # 为什么「悬浮返回键」不参与联动（有意，不是漏了）
// ```text
// 它是为另一个缺陷加的：控制条藏起来后屏幕上**没有返回口**
// （见 `_FloatingBackButton` 的长注释）。
// ⇒ 它的显隐由 `if (!visible && onFloatingBack != null)` **单独**决定，
//   与那条渐变条解耦 —— 否则「藏了就没法返回」会立刻回归。
// ```
//
// ⚠️ 本文件用**探针**驱动（`debugPlayerHoverControlsForProbe` /
//    `debugPlayerAutoHideControlsForProbe`）而不是 `t.tap`：
//    flutter_tester 里 PlayerPage 整棵树的指针回调都不被调用
//    （见 test/t98 文件头），tap 驱动不了这条路径。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

/// 挂一个真实 `PlayerPage`（与 t72_jank_test.dart 逐字同源）
Future<void> _mount(WidgetTester t, {bool playing = true}) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  const eps = <Episode>[
    Episode(id: 'ep1', title: '第1集', url: 'https://x.invalid/1.m3u8'),
    Episode(id: 'ep2', title: '第2集', url: 'https://x.invalid/2.m3u8'),
  ];
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: '联动测试',
        episodes: eps,
        episodeIndex: 0,
        episodeId: eps.first.id,
        episodeTitle: eps.first.title,
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
  await t.pump();
  await t.pump();
  /*
   * ★ 必须显式置 `_playing = true`。
   *
   * `_autoHideNow()` 的第一条判据就是 `_playing`（暂停时不该收控制条，
   * 那是**对**的）；而 flutter_tester 里没有真网络 ⇒ 起播必然失败
   * ⇒ 不置位的话「自动隐藏」这条路径在测试里**根本走不到**，
   * 而那正是本文件要验的东西。
   */
  if (playing) debugPlayerSetPlayingForProbe(true);
  await t.pump();
}

/// 把淡出/淡入动画跑到停（260ms 的 token 值，多给一帧余量）
Future<void> _settleMotion(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 40));
  }
}

/// 剥掉注释的最小实现（与 `t68_android_adapt_test.dart` 同算法）
///
/// ★ 为什么需要：本文件有几条判据是「**代码里**不该再有 X」，
///   而历史注释为了解释「改前是什么样」会反复提到 X —— 用原文断言必假红。
String _stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote;
  while (i < src.length) {
    final c = src[i];
    if (quote != null) {
      out.write(c);
      if (c == r'\' && i + 1 < src.length) {
        out.write(src[i + 1]);
        i += 2;
        continue;
      }
      if (c == quote) quote = null;
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    } else {
      fail('libmpv 夹具缺失：${dll.absolute.path} 不存在');
    }
  });
  setUp(() => RemoteBridge.instance.stop());
  tearDown(() => RemoteBridge.instance.stop());

  group('★ 顶栏 / 底栏 显隐联动', () {
    testWidgets('① 两条控制条读的是**同一个**动画值（结构性联动）', (t) async {
      await _mount(t);
      final o = debugPlayerControlBarsOpacity();
      expect(o, isNotNull, reason: '★ 没有播放页 ⇒ 探针拿不到读数');
      expect(
        o!.$1,
        o.$2,
        reason:
            '★★ 顶栏与底栏必须是同一个 _controlsFade —— 两个数不等 '
            '说明有人各开了一条动画（那就不是"联动"了）',
      );
      expect(o.$1, 1.0, reason: '★ 刚挂载时控制条应当是完全显示的');
    });

    testWidgets('② 触发隐藏条件 ⇒ 顶栏与底栏**一起**淡到 0', (t) async {
      await _mount(t);
      expect(debugPlayerControlBarsOpacity()!.$1, 1.0, reason: '前提：先完全显示');

      final hid = debugPlayerAutoHideControlsForProbe();
      expect(
        hid,
        isTrue,
        reason:
            '★ 探针没生效 —— 它要求 _playing==true；'
            '若这里就是 false，后面的读数全部无意义',
      );
      await _settleMotion(t);

      final o = debugPlayerControlBarsOpacity()!;
      expect(o.$1, 0.0, reason: '★★ 顶栏没有淡出 —— 这正是用户报的「上面的不消失」');
      expect(o.$2, 0.0, reason: '★★ 底栏没有淡出');
    });

    testWidgets('③ 触发显示条件 ⇒ 两条**一起**回到 1', (t) async {
      await _mount(t);
      debugPlayerAutoHideControlsForProbe();
      await _settleMotion(t);
      expect(debugPlayerControlBarsOpacity()!.$1, 0.0, reason: '前提：先藏起来');

      final shown = debugPlayerHoverControlsForProbe();
      expect(shown, isTrue, reason: '★ 晃动应当把 _controlsVisible 翻回 true');
      await _settleMotion(t);

      final o = debugPlayerControlBarsOpacity()!;
      expect(o.$1, 1.0, reason: '★★ 顶栏没有回来');
      expect(o.$2, 1.0, reason: '★★ 底栏没有回来');
    });

    testWidgets('④ 来回切换多轮：两条的读数**每一帧都相等**', (t) async {
      await _mount(t);
      for (var round = 0; round < 3; round++) {
        debugPlayerAutoHideControlsForProbe();
        // 不 settle 到底，中途也要采样 —— 抓"一个先动、一个后动"
        for (var i = 0; i < 4; i++) {
          await t.pump(const Duration(milliseconds: 20));
          final o = debugPlayerControlBarsOpacity()!;
          expect(
            o.$1,
            o.$2,
            reason:
                '★ 第 $round 轮隐藏过程中顶/底不一致（$o）—— '
                '说明有人的动画起点或时长不同',
          );
        }
        await _settleMotion(t);
        expect(debugPlayerControlBarsOpacity()!.$1, 0.0);

        debugPlayerHoverControlsForProbe();
        for (var i = 0; i < 4; i++) {
          await t.pump(const Duration(milliseconds: 20));
          final o = debugPlayerControlBarsOpacity()!;
          expect(o.$1, o.$2, reason: '★ 第 $round 轮显示过程中顶/底不一致（$o）');
        }
        await _settleMotion(t);
        expect(debugPlayerControlBarsOpacity()!.$1, 1.0);
      }
    });

    testWidgets('⑤ 联动是**动画**不是硬切（存在中间帧）', (t) async {
      await _mount(t);
      debugPlayerAutoHideControlsForProbe();
      /*
       * ★ 两次 pump 缺一不可：
       *   AnimationController 的 ticker 在**第一次** tick 上取基准时间
       *   （elapsed 从 0 起算）⇒ 只 pump 一次的话读数仍是起始值 1.0，
       *   会被误判成「动画没被驱动」。
       *   （这正是我第一版的红 —— 假红，不是产品缺陷。）
       */
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));
      final mid = debugPlayerControlBarsOpacity()!.$1;
      expect(
        mid,
        greaterThan(0.0),
        reason: '★ 60ms 就归零 ⇒ 这是**硬切**，不是淡出（用户要求"要有动画"）',
      );
      expect(mid, lessThan(1.0), reason: '★ 60ms 还没开始动 ⇒ 动画没被驱动');
      await _settleMotion(t);
      expect(debugPlayerControlBarsOpacity()!.$1, 0.0);
    });

    test('⑪ task-16 定案：独立悬浮返回键已删除（改前它会常驻在画面上）', () {
      final src = File('lib/ui/player_page.dart').readAsStringSync();
      expect(
        src.contains('class _FloatingBackButton'),
        isFalse,
        reason:
            '★★ `_FloatingBackButton` 必须**不存在** —— 它就是 Owner 报的'
            '「全屏左上角这个单独的返回icon,还没消失」那一枚。'
            'lead 定案：控制条收起时它跟着一起淡出；鼠标一动，顶栏连同'
            '**它自己的**返回箭头一起回来。半成品方案 `(1 - f) × 指针在页内` '
            '在全屏下无效（全屏时指针恒在页内）。',
      );
      // ⚠️ 判据对象必须是**剥掉注释后**的源码：那段历史注释里反复提到
      //   `onFloatingBack`（解释「改前是什么样」），用原文断言会假红。
      expect(
        _stripComments(src).contains('onFloatingBack'),
        isFalse,
        reason:
            '★ `onFloatingBack` 是那枚悬浮键的入口，删了它才真的删干净。'
            '（剥注释后仍出现 ⇒ 代码里还有引用没删干净）',
      );
      // ★ 阴性对照：顶栏**自己**的返回箭头必须还在（错误态下还要常显可点）
      expect(
        src.contains('_canUseTopBarBack'),
        isTrue,
        reason:
            '★★ 错误态下顶栏那枚箭头必须仍可用（Owner 专门报过「不能播放时'
            '左上角的返回点不动」）。删悬浮键**不能**连这条一起删掉。',
      );
    });

    test('⑦ 顶栏**不再**被 `|| _canUseFloatingBack` 顶成常显（旧写法已消失）', () {
      final src = File('lib/ui/player_page.dart').readAsStringSync();
      expect(
        src.contains('if (_controlsVisible || _canUseFloatingBack)'),
        isFalse,
        reason:
            '★★ 这就是「上面的这个一直不消失」的那一行 —— 它回来了。'
            '`_canUseFloatingBack` 在桌面端恒 true ⇒ 顶栏无条件渲染。'
            '正确做法：顶栏常挂（去掉外层 if），渐变条看 visible。',
      );
      // 顶栏的挂载点必须**没有**外层 if —— 否则隐藏时它整棵被卸下，
      // 260ms 的淡出根本没机会播（一帧硬切）。
      final i = src.indexOf('                    _TopBar(');
      expect(i, greaterThan(0), reason: '★ `_TopBar(` 的挂载点缩进变了（找不到）');
      final before = src.substring(i - 400, i);
      expect(
        before.contains('if ('),
        isFalse,
        reason:
            '★★ `_TopBar(` 前面又出现了 if —— 那会让顶栏在隐藏时被'
            '整个卸下（硬切，没有淡出动画），用户要求的是要有动画。',
      );
    });

    test('⑧ 顶栏渐变条的 visible 与底栏同源（都是 _controlsVisible）', () {
      final src = File('lib/ui/player_page.dart').readAsStringSync();
      /*
       * ★★★ 2026-10-09 更新（task-7 / Owner 新增缺陷：错误态返回箭头不可点）
       *
       * # 为什么原断言（`visible: _controlsVisible && _error == null,` 单行）必须改
       * ```text
       * 单行形态在错误态下恒 false ⇒ IgnorePointer 挡住顶栏 ⇒ 箭头点不动，
       * 那正是 Owner 报的新缺陷。修法 = 追加一个**互斥**分支：
       *   visible = (_controlsVisible && _error == null) || _canUseTopBarBack
       * 其中 `_canUseTopBarBack` = `_error != null && ...`，与前半段**不可能同时为真**。
       * ```
       * ⇒ 断言改成**等价的多行形态**，判据不变：
       *   ① 顶栏 visible 仍以 `_controlsVisible && _error == null` 为主真源（逐字要求还在）；
       *   ② 追加分支必须是 `_canUseTopBarBack`（**不是**写死 true、不是其它字段）。
       * ⚠️ 若有人把 ① 拿掉（写死 true 或换成别的），本条立刻红 —— 联动保护不丢。
       */
      expect(
        src.contains('(_controlsVisible && _error == null) ||'),
        isTrue,
        reason:
            '★ 顶栏 visible 的主真源必须仍是 `_controlsVisible && _error == null` ——'
            '那是联动的唯一真源；改成别的判据（或写死 true）就不再联动了',
      );
      expect(
        src.contains('_canUseTopBarBack,'),
        isTrue,
        reason:
            '★ task-7 追加的错误态分支必须还是 `_canUseTopBarBack`（互斥分支），'
            '不许换成写死 true 或别的字段',
      );
      final iTop = src.indexOf('bool get _canUseTopBarBack =>');
      expect(iTop, greaterThan(0), reason: '★ `_canUseTopBarBack` 不见了');
      final topDef = src.substring(iTop, iTop + 200);
      expect(
        topDef.contains('_error != null'),
        isTrue,
        reason:
            '★★ `_canUseTopBarBack` 必须与前半段**互斥**（含 `_error != null`）——'
            '否则正常播放时它也会让顶栏常显，顶栏就再也不消失了',
      );
      expect(
        topDef.contains('!_anySheetOpen'),
        isTrue,
        reason: '★★ 浮层打开时不许抢返回（与 `_canUseFloatingBack` 同一条纪律）',
      );
      expect(
        src.contains('if (_controlsVisible &&'),
        isTrue,
        reason: '★ 底栏的门控消失了（两条读的必须是同一个字段）',
      );
    });

    test('⑨ 隐藏路径真的驱动动画（_autoHideNow 里必须调 _applyControlsMotion）', () {
      final src = File('lib/ui/player_page.dart').readAsStringSync();
      final i = src.indexOf('void _autoHideNow() {');
      expect(i, greaterThan(0), reason: '★ `_autoHideNow` 不见了（被改名/删掉）');
      final body = src.substring(i, i + 1600);
      expect(
        body.contains('setState(() => _controlsVisible = false);'),
        isTrue,
        reason: '★ 隐藏动作本身不见了',
      );
      expect(
        body.contains('_applyControlsMotion();'),
        isTrue,
        reason:
            '★★ 隐藏路径没有驱动动画 —— 这正是本次的根因：'
            '`_applyControlsMotion()` 原来只在 `_showControls()` 里调，'
            '⇒ `_controlsFade.value` 恒 1.0 ⇒ 顶栏永远不淡出。',
      );
      expect(
        body.indexOf('_applyControlsMotion();'),
        greaterThan(body.indexOf('setState(() => _controlsVisible = false);')),
        reason:
            '★★ `_applyControlsMotion()` 写在了 setState 之前 ——'
            '它读的是 `_controlsVisible` 的当前值，写在前面会读到旧值 ⇒ 反向。',
      );
    });

    test('⑩ 两条读的是**同一个** _controlsFade 实例（不是各开一条）', () {
      final src = File('lib/ui/player_page.dart').readAsStringSync();
      /*
       * ★★★ 2026-10-09 更新（task-7）：计数口径改成「**引用** `_controlsFade`」
       *
       * # 为什么
       * ```text
       * 改前两处都是裸的 `fade: _controlsFade,`。task-7 后顶栏那两处变成三元：
       *   fade: _canUseTopBarBack ? kAlwaysCompleteAnimation : _controlsFade,
       *   floatingFade: _canUseTopBarBack ? kAlwaysCompleteAnimation : _controlsFade,
       * ⇒ `indexOf('fade: _controlsFade,')` 一处都匹配不到（实测 0，原来断言 2）。
       * ```
       * ★ 判据的**实质**没变：两条必须读**同一个** `_controlsFade` 实例。
       *   现在数的是「`._controlsFade` 的引用次数」= 顶栏 2（fade + floatingFade）
       *   + 底栏 1 = 3；且**声明只有一处**（下一条断言照旧）。
       * ⚠️ 引用次数少于 3 说明有人给某条换了独立动画源 ⇒ 联动失效 ⇒ 本条红。
       */
      final refs = RegExp(r'_controlsFade').allMatches(src).length;
      /*
       * ★★★ 2026-10-10 更新（task-16 定案）：下界从 3 降到 **2**
       * ```text
       * 改前引用点：顶栏 fade + 顶栏 floatingFade + 底栏 fade = 3 处。
       * task-16 定案删掉了「独立悬浮返回键」⇒ floatingFade 那个引用点没了
       * （lead 裁决：控制条收起时悬浮键一起淡出，鼠标一动顶栏连同它自己的
       *   返回箭头一起回来 ⇒ 独立悬浮键已无存在理由）。
       * ⇒ 现在是 顶栏 fade + 底栏 fade = 2 处，**仍然是同一个实例**。
       * ```
       * ★ 判据的**实质**没变：两条必须读**同一个** `_controlsFade` 实例。
       * ⚠️ 红度证明：把顶栏那一处换成 `kAlwaysCompleteAnimation`（或删掉）
       *   ⇒ 引用数掉到 1 ⇒ 本条立刻红。
       */
      expect(
        refs,
        greaterThanOrEqualTo(2),
        reason:
            '★ 顶栏 + 底栏 至少要引用同一个 `_controlsFade` 2 次，'
            '实测 $refs 次。只有同一个实例才能保证两条**每一帧**的不透明度都相等。',
      );
      expect(
        src.contains('fade: _canUseTopBarBack'),
        isTrue,
        reason: '★ task-7 的错误态分支必须仍在（把 fade 钉成常量动画）',
      );
      expect(
        src.contains(': _controlsFade,'),
        isTrue,
        reason:
            '★ 正常态必须**回落到** `_controlsFade`（不是写死常量）——'
            '否则控制条隐藏时顶栏不会淡出，缺陷 2 会回归',
      );
      final decl = RegExp(r'late final Animation<double> _controlsFade =')
          .allMatches(src)
          .length;
      expect(decl, 1, reason: '★ `_controlsFade` 的声明应当只有一处，实测 $decl 处');
    });

    testWidgets('⑥ 静止鼠标**不再**让控制条复活（原缺陷：hover 每帧续命）', (t) async {
      await _mount(t);
      debugPlayerAutoHideControlsForProbe();
      await _settleMotion(t);
      final before = debugPlayerControlBarsOpacity()!.$1;
      // 只推进时间，**不**调用任何 hover 探针
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      final after = debugPlayerControlBarsOpacity()!.$1;
      expect(after, before, reason: '★ 没有任何交互却自己变回来了（$before → $after）');
    });
  });
}
