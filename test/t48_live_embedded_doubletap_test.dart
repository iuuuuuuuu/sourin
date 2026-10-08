// ═══════════════════════════════════════════════════════════════════════
//  task-48【B】直播页内嵌播放器 —— 双击进入全屏
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（task-48 第 2 条）
//
// ```text
// 「直播删除掉节目单,左侧固定,右侧就一个播放器也固定,
//   **还要支持双击进入全屏播放**」
// ```
//
// # 判据（三条正向 + 一条阴性对照）
//
// ```text
// ① 阳性对照：PC/TV（isTouchOnly=false）+ 有全屏回调
//    ⇒ 双击**恰好**触发一次 onToggleFullscreen
// ② ★ 触摸端（isTouchOnly=true）双击 ⇒ **不**触发全屏
//    理由：触摸端的双击是"左右快进快退"的语义位（**既有功能**）
//          ⇒ 本次改动**不许夺走**
//          （用户 2026-09-24 明确要求「pc端不应该双击左右快进快退」
//            ⇒ PC 那边才是空档，让给"全屏"零冲突）
// ③ 没有全屏回调（onToggleFullscreen == null）⇒ 双击**不炸**
//    直播页在"还没选中频道"时传的就是 null
//    （`live_page.dart:1627 onToggleFullscreen: _selected == null ? null : _watchLive`）
// ④ 阴性对照：**单击**中心 ⇒ 回调**不变**
//    ⇒ 证明回调来自 DoubleTapGestureRecognizer，
//      而不是"任何一次点击"（否则 ① 可能被别的东西凑出来）
// ```
//
// # ★★ 为什么本文件**不加** `@Tags(['native-media'])`
//
// ```text
// 同目录的 `t74_embed_visibility_gate_test.dart` 必须加那个 tag，因为它
// 会跑满 380ms 让 `_create()` 真的构造 `Player(...)` ⇒ 加载 libmpv-2.dll
// ⇒ flutter_tester 偶发访问违例 c0000005（实测 6/25，见 `dart_test.yaml`）。
//
// 本文件**只验手势**，全程停在 `_createDelay`（380ms）**之内**：
//     pumpWidget(0ms) + pump(60ms) + pump(120ms) = 180ms < 380ms
//   ⇒ `_createTimer` 从未触发 ⇒ `Player` / `VideoController` 从未构造
//   ⇒ 不加载 libmpv ⇒ 可以进默认套件，不引入 native 崩溃面。
//
// ★ 这个前提**不是**注释里说说而已 —— 每个用例都用
//   `hasPlayerForTest == false`（`live_embedded_player.dart:461`）
//   **当场证明**它成立（点击前 + 点击后各一次）。
//   若将来有人把 `_createDelay` 调短、或在窗口内多 pump 几帧，
//   这条断言会**先变红**，而不是变成偶发 native 崩溃。
// ```
//
// # ★ 仪器来源（不是我发明的）
//
// ```text
// 双击手法照抄 `test/zz_t42_player_keys_test.dart:246-265`（PC 双击 = 全屏，
// 触摸端双击 = 不变）—— 那两条测的是 **PlayerPage**，本文件测的是
// **LiveEmbeddedPlayer**（另一个控件，此前**零覆盖**）。
// ⇒ 两处用同一套手法 ⇒ 结论可以互相印证。
// ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/widgets/live_embedded_player.dart';

// ═══════════════════════════════════════════════════════════════════════
//  仪器 1：双击
// ═══════════════════════════════════════════════════════════════════════

/// 在控件**中心**连点两次。
///
/// ```text
/// 间隔 60ms —— 必须 > kDoubleTapMinTime(40ms) 且 < kDoubleTapTimeout(300ms)。
/// ★ 不能用 `tap()` + `pump(kDoubleTapTimeout)`：那样两次点击间隔超过
///   双击窗口，会被判成**两次单击**（判据就失效了，而且是"静默"失效）。
/// ```
Future<void> _doubleTap(WidgetTester t, Finder target) async {
  final center = t.getCenter(target);
  await t.tapAt(center);
  await t.pump(const Duration(milliseconds: 60));
  await t.tapAt(center);
  await t.pump(const Duration(milliseconds: 120));
}

/// 单击一次（阴性对照用）
Future<void> _singleTap(WidgetTester t, Finder target) async {
  await t.tapAt(t.getCenter(target));
  await t.pump(const Duration(milliseconds: 120));
}

// ═══════════════════════════════════════════════════════════════════════
//  仪器 2：`[LIVE] 双击` 日志探针（**第二条独立读数**）
// ═══════════════════════════════════════════════════════════════════════
//
// ```text
// 只数"回调被调了几次"是**一条**读数 —— 若回调恰好被别处调了一次，
// 计数照样是 1。再加一条**来源不同**的读数（控件自己打的日志），
// 两条同时成立才排除"凑巧"。
//
// ⚠️⚠️ 必须**显式还原** `debugPrint`（本项目已踩过）：
//   flutter_test 在**每个测试结束时**断言"框架全局变量已复原"，
//   `debugPrint` 是其中之一 ⇒ 不还原就**每个测试都失败**。
//   ★ `addTearDown(restore)` **太晚**（断言在 teardown 之前跑）
//     ⇒ 必须在测试体内（本文件用 try/finally）还原。
// ```
class _TapLogProbe {
  final List<String> logs = <String>[];
  void Function(String?, {int? wrapWidth})? _orig;

  void install() {
    _orig = debugPrint;
    debugPrint = (String? msg, {int? wrapWidth}) {
      if (msg != null && msg.contains('[LIVE] 双击')) logs.add(msg);
    };
  }

  void restore() {
    final o = _orig;
    if (o != null) debugPrint = o;
  }

  int get fullscreenLines =>
      logs.where((l) => l.contains('[LIVE] 双击 ⇒ 进入全屏')).length;
}

// ═══════════════════════════════════════════════════════════════════════
//  挂载 / 卸载
// ═══════════════════════════════════════════════════════════════════════

/// 只挂 `LiveEmbeddedPlayer`，**不**挂 `LivePage`
/// （本文件测的是控件自身的手势，不测接线；接线由下面的静态契约守）。
Widget _mount({
  required GlobalKey<LiveEmbeddedPlayerState> key,
  required bool isTouchOnly,
  VoidCallback? onToggleFullscreen,
}) {
  return MaterialApp(
    home: Scaffold(
      body: LiveEmbeddedPlayer(
        key: key,
        // ★ 这个 URL **永远不会被打开** —— 用例全程停在 380ms 窗口内，
        //   `_create()` 从未跑（由 hasPlayerForTest 断言证明）。
        stream: const StreamCandidate(
          url: 'file:///t48-doubletap-probe-never-opened.mp4',
          label: 'probe',
        ),
        title: 'probe',
        isTouchOnly: isTouchOnly,
        onToggleFullscreen: onToggleFullscreen,
      ),
    ),
  );
}

/// 卸载 ⇒ `dispose()` 取消 `_createTimer`（否则 flutter_test 会报
/// "A Timer is still pending even after the widget tree was disposed"）。
Future<void> _unmount(WidgetTester t) async {
  await t.pumpWidget(const SizedBox.shrink());
  await t.pump();
}

/// ★ 前置断言：确认"还没建播放器"（= 没加载 libmpv = 本文件可进默认套件）
void _expectNoPlayerYet(GlobalKey<LiveEmbeddedPlayerState> key, String when) {
  expect(key.currentState, isNotNull, reason: '★ 控件必须挂上了（$when）');
  expect(
    key.currentState!.hasPlayerForTest,
    isFalse,
    reason: '★★★ $when：`Player` **已经**被构造了 ⇒ 本用例已经越过 380ms '
        '窗口 ⇒ 会去加载 libmpv-2.dll ⇒ 本文件就不再是"无原生"的了'
        '（偶发 c0000005）。要么本用例 pump 的总时长被改长了，'
        '要么 `_createDelay` 被改短了 —— 两种都必须先处理，'
        '不能把这条断言删掉。',
  );
}

void main() {
  final finder = find.byType(LiveEmbeddedPlayer);

  // ═══════════════════════════════════════════════════════════════════
  //  ① 阳性对照：PC 双击 ⇒ 全屏
  // ═══════════════════════════════════════════════════════════════════
  group('task-48【B】双击进入全屏', () {
    testWidgets('① 阳性对照：PC（非触摸端）双击 ⇒ 全屏回调**恰好** +1', (t) async {
      final key = GlobalKey<LiveEmbeddedPlayerState>();
      var calls = 0;
      final probe = _TapLogProbe()..install();
      try {
        await t.pumpWidget(_mount(
          key: key,
          isTouchOnly: false,
          onToggleFullscreen: () => calls++,
        ));
        _expectNoPlayerYet(key, '双击前');
        expect(calls, 0, reason: '★ 前置：挂载本身不能触发全屏');

        await _doubleTap(t, finder);

        // ── 读数 1：回调计数 ──
        expect(
          calls,
          1,
          reason: '★★ 用户要求「还要支持双击进入全屏播放」⇒ '
              'PC/TV 双击画面必须切全屏。\n'
              '  · 若为 0 ⇒ 双击**根本没接上**（用户的原话没实现）\n'
              '  · 若 >1 ⇒ 回调被重复挂/重复触发（一次双击跳两次全屏）',
        );
        // ── 读数 2：控件自己打的日志（来源不同）──
        expect(
          probe.fullscreenLines,
          1,
          reason: '★★ 第二条独立读数（`live_embedded_player.dart:588` 的 '
              '`debugPrint`）必须恰好 1 行。\n'
              '  两条读数都指向"一次双击 = 一次全屏"才排除"凑巧"。',
        );
        _expectNoPlayerYet(key, '双击后');
        debugPrint('VERDICT B1 pc_doubleTap_calls=$calls '
            'logLines=${probe.fullscreenLines}');
      } finally {
        probe.restore();
        await _unmount(t);
      }
    });

    // ═══════════════════════════════════════════════════════════════
    //  ② 触摸端双击 ⇒ **不**触发全屏（不能夺走既有语义）
    // ═══════════════════════════════════════════════════════════════
    testWidgets('② ★ 触摸端双击 ⇒ 全屏回调**不变**（不夺走左右快进快退）',
        (t) async {
      final key = GlobalKey<LiveEmbeddedPlayerState>();
      var calls = 0;
      final probe = _TapLogProbe()..install();
      try {
        await t.pumpWidget(_mount(
          key: key,
          isTouchOnly: true,
          onToggleFullscreen: () => calls++,
        ));
        _expectNoPlayerYet(key, '双击前');

        await _doubleTap(t, finder);

        expect(
          calls,
          0,
          reason: '★★★ 触摸端的双击**必须**保持为"左右快进快退"的语义位。\n'
              '  它现在是空实现（直播是实时流，快进没有意义），\n'
              '  但**语义位**必须留给它 —— 本次改动只许在 PC/TV 上填空档，\n'
              '  不许夺走触摸端的既有手势（用户 2026-09-24 的要求）。\n'
              '  ★ 判据与播放页同源：`PlayerGestures.doubleTapEnabledFor`。',
        );
        expect(
          probe.fullscreenLines,
          0,
          reason: '★ 第二条读数：控件也不该打出"双击 ⇒ 进入全屏"。',
        );
        _expectNoPlayerYet(key, '双击后');
        debugPrint('VERDICT B2 touch_doubleTap_calls=$calls '
            'logLines=${probe.fullscreenLines}');
      } finally {
        probe.restore();
        await _unmount(t);
      }
    });

    // ═══════════════════════════════════════════════════════════════
    //  ③ 没有全屏回调 ⇒ 双击不炸
    // ═══════════════════════════════════════════════════════════════
    testWidgets('③ 无全屏回调（onToggleFullscreen=null）⇒ 双击不抛异常', (t) async {
      final key = GlobalKey<LiveEmbeddedPlayerState>();
      final probe = _TapLogProbe()..install();
      try {
        await t.pumpWidget(_mount(key: key, isTouchOnly: false));
        _expectNoPlayerYet(key, '双击前');

        await _doubleTap(t, finder);

        // ★ 这里守的是 `widget.onToggleFullscreen!()` 那个 `!`：
        //   若判据丢了 `!= null` 那一半，双击会直接抛
        //   `Null check operator used on a null value`。
        expect(
          t.takeException(),
          isNull,
          reason: '★★ 直播页在"还没选中频道"时传的就是 null '
              '（`live_page.dart:1627`）⇒ 这条路径**必须**安全。',
        );
        expect(probe.fullscreenLines, 0,
            reason: '★ 没有回调 ⇒ 不该打"双击 ⇒ 进入全屏"（否则说明它进了分支）');
        _expectNoPlayerYet(key, '双击后');
        debugPrint('VERDICT B3 null_cb_exception=none');
      } finally {
        probe.restore();
        await _unmount(t);
      }
    });

    // ═══════════════════════════════════════════════════════════════
    //  ④ 阴性对照：单击 ⇒ 回调不变
    // ═══════════════════════════════════════════════════════════════
    testWidgets('④ 阴性对照：**单击**中心 ⇒ 全屏回调不变', (t) async {
      final key = GlobalKey<LiveEmbeddedPlayerState>();
      var calls = 0;
      final probe = _TapLogProbe()..install();
      try {
        await t.pumpWidget(_mount(
          key: key,
          isTouchOnly: false,
          onToggleFullscreen: () => calls++,
        ));
        _expectNoPlayerYet(key, '单击前');

        await _singleTap(t, finder);

        expect(
          calls,
          0,
          reason: '★★ 阴性对照：单击**不能**触发全屏。\n'
              '  没有这一条，① 的"回调 +1"可能来自"任何一次点击"\n'
              '  （比如命中路径上别的按钮）⇒ ① 就不再证明"双击"了。',
        );
        expect(probe.fullscreenLines, 0);
        _expectNoPlayerYet(key, '单击后');
        debugPrint('VERDICT B4 single_tap_calls=$calls');
      } finally {
        probe.restore();
        await _unmount(t);
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑤ 静态契约：判据来源必须与播放页**同源**
  // ═══════════════════════════════════════════════════════════════════
  //
  // ```text
  // 控件内部的判据是 `widget.isTouchOnly`（live_embedded_player.dart:577）。
  // 那么直播页**必须**把"是不是触摸端"如实传进来 —— 否则控件的判据
  // 永远拿到默认值 `false` ⇒ 触摸端也会被当成 PC ⇒ **夺走触摸端的手势**。
  //
  // ★ 与播放页同源：PlayerPage 用的也是 `Device.isTouchOnly`
  //   （`live_page.dart:1629-1636` 的注释记着这条纪律）。
  // ```
  group('task-48【B】接线静态契约（判据来源同源）', () {
    test('★★★ 直播页必须把 Device.isTouchOnly 传给内嵌播放器', () {
      final src = _codeOnly(_readFile('lib/ui/live_page.dart'));
      final args = _argsOf(src, 'LiveEmbeddedPlayer(');

      expect(args, isNotEmpty,
          reason: '★ 前置：必须能定位 `LiveEmbeddedPlayer(` 的实参表。\n'
              '  若为空 ⇒ 下面的断言全是空的（假绿，铁律 78）。');
      expect(args, contains('isTouchOnly:'),
          reason: '★ 前置：确实传了这个参数');
      expect(
        args,
        contains('isTouchOnly: Device.isTouchOnly'),
        reason: '★★★ 必须传 `Device.isTouchOnly`。\n'
            '  传成字面量 `false`（或干脆不传）⇒ 触摸端会被判成 PC\n'
            '  ⇒ 双击变成"进全屏"，**夺走**触摸端的既有手势语义。\n'
            '  ★ 与播放页 `PlayerPage` 用的是**同一个来源**（纪律：同源）。',
      );
      expect(args, contains('onToggleFullscreen:'),
          reason: '★ 前置：全屏回调也得传（否则 ① 那条判据在真机上不可达）');
      debugPrint('VERDICT B5 live_page_isTouchOnly=Device.isTouchOnly');
    });
  });
}

// ═══════════════════════════════════════════════════════════════════════
//  静态分析工具（照抄 `zz_t42_gate_verification_test.dart:502-578`）
// ═══════════════════════════════════════════════════════════════════════

String _readFile(String rel) {
  // ★ 相对路径按 `flutter test` 的工作目录（项目根）解析
  final f = File(rel);
  if (f.existsSync()) return f.readAsStringSync();
  final alt = File('${Directory.current.path}/$rel');
  return alt.readAsStringSync();
}

/// 剥掉注释（`//` 行注释 **和** `/* */` 块注释，支持嵌套）
///
/// ★ 必须剥 —— 本项目踩过多次"断言匹配到注释文本 ⇒ 假通过"。
String _codeOnly(String src) {
  final out = StringBuffer();
  var i = 0;
  var depth = 0;
  var inLine = false;
  while (i < src.length) {
    final c = src[i];
    final n = i + 1 < src.length ? src[i + 1] : '';
    if (inLine) {
      if (c == '\n') {
        inLine = false;
        out.write(c);
      }
      i++;
      continue;
    }
    if (depth > 0) {
      if (c == '/' && n == '*') {
        depth++;
        i += 2;
        continue;
      }
      if (c == '*' && n == '/') {
        depth--;
        i += 2;
        continue;
      }
      if (c == '\n') out.write('\n');
      i++;
      continue;
    }
    if (c == '/' && n == '/') {
      inLine = true;
      i += 2;
      continue;
    }
    if (c == '/' && n == '*') {
      depth++;
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 取某次调用的**实参表**（从 `callPrefix` 的第一个 `(` 到配平的 `)`）
///
/// ★ 用配平括号而不是正则 —— 实参里有嵌套括号（`() => setState(...)`），
///   正则必然截错（`zz_t53` 记录过"按 \n  }\n 找结尾"测出假红的教训）。
String _argsOf(String code, String callPrefix) {
  final start = code.indexOf(callPrefix);
  if (start < 0) return '';
  final open = code.indexOf('(', start);
  if (open < 0) return '';
  var depth = 0;
  for (var i = open; i < code.length; i++) {
    if (code[i] == '(') depth++;
    if (code[i] == ')') {
      depth--;
      if (depth == 0) return code.substring(open, i + 1);
    }
  }
  return '';
}
