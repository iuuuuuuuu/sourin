@Tags(['native-media'])
library;

// ═══════════════════════════════════════════════════════════════════════
//  ★ 本文件被标记为 `native-media`（默认不跑）—— 原因见下
// ═══════════════════════════════════════════════════════════════════════
//
// 本文件调用 `MediaKit.ensureInitialized()`（:268），它会加载 **libmpv-2.dll**。
// 实测：在 `flutter test` 的 flutter_tester 进程里加载该原生库，
// 会**偶发 native 崩溃**（访问违例 c0000005，进程退出码 79）。
//
// ```text
// 失败形态：整文件用例一起 `did not complete`（不是单用例失败）
// 实测崩溃率：加载 libmpv 6/25；不加载 0/25（干净交错 A/B）
// 与并发无关：串行 8 次里红 5 次；单文件串行也红（1/5）
// ```
//
// ★ 完整证据链与已排除清单：`.probe/native-media-tests.md`
// ★ 标签配置：`dart_test.yaml`
//
// 手动跑：
// ```powershell
// flutter test test/ --run-skipped --tags native-media --concurrency=1
// ```
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/widgets/live_embedded_player.dart';

String _url() =>
    Uri.file(File('.probe/tv-sample.mp4').absolute.path).toString();

// ---------------------------------------------------------------------------
// 平台通道 mock：`com.alexmercerind/media_kit_video`
//
// 为什么必须有这个 mock（实测过的因果链，不是猜的）：
//   `VideoController(p)` 在 `LiveEmbeddedPlayerState._create()` 里同步构造，
//   它内部的 async 块会 `invokeMethod('VideoOutputManager.Create')`。
//   `flutter test` 没有平台侧实现 ⇒ 抛 MissingPluginException ⇒
//   media_kit_video 在 catch 里 `platform.completeError(exception)`
//   （video_controller.dart:131），而那个 Completer **没有任何监听者** ⇒
//   变成 Zone 级 unhandled error ⇒ flutter_test 的 `handleUncaughtError`
//   **直接判定整条测试失败**，而且**不经过** `FlutterError.onError` 的正常
//   路径 ⇒ `tester.takeException()` 吞不掉它。
//   实测证据：加了 takeException drain 之后仍然是 `[E]`，00:02 判失败，
//   而测试体一直跑到 00:12 才打出 VERDICT。
//
// mock 掉 Create 之后还有第二个坑：`NativeVideoController.create` 会
// `await completer.future` 等**首个 texture id**（real.dart:190），而 id 只有
// 平台侧主动推 `VideoOutput.Resize` 才会到（real.dart:265-287）⇒ 必须伪造
// 那条入站消息，否则 `videoControllerCompleter` 永不完成、`Player.open()` 死锁。
// ---------------------------------------------------------------------------
const _videoChannelName = 'com.alexmercerind/media_kit_video';
const _videoChannel = MethodChannel(_videoChannelName);

final List<String> _createdHandles = <String>[];
var _pushedTextureId = false;

void _installVideoChannelMock() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_videoChannel, (call) async {
    if (call.method == 'VideoOutputManager.Create') {
      final h = call.arguments['handle'];
      if (h is String) _createdHandles.add(h);
    }
    return null; // Create / Dispose 一律当成功
  });
}

/// 必须在 `runAsync` 的真实事件循环里跑 —— 入站消息的 handler 是 async 的，
/// 纯 fake-async 里它的 Future 不会推进。
Future<void> _pushTextureIdIfNeeded() async {
  if (_pushedTextureId || _createdHandles.isEmpty) return;
  _pushedTextureId = true;
  final handle = int.tryParse(_createdHandles.first);
  if (handle == null) return;
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    _videoChannelName,
    _videoChannel.codec.encodeMethodCall(
      MethodCall('VideoOutput.Resize', <String, dynamic>{
        'handle': handle,
        'rect': <String, dynamic>{
          'left': 0.0,
          'top': 0.0,
          'width': 1280.0,
          'height': 720.0,
        },
        'id': 7,
      }),
    ),
    null,
  );
}

/// 任何走 `FlutterError.onError` 的异常都必须 fail —— 这条测试里**没有**
/// 任何"预期内的异常"了（平台通道那条已从源头 mock 掉）。
/// ★ 绝不能无脑吞异常，否则这条测试就成了永远绿的假门禁。
void _failOnAnyException(WidgetTester t) {
  for (var i = 0; i < 16; i++) {
    final e = t.takeException();
    if (e == null) return;
    fail('测试期间出现了未预期的异常（平台通道已 mock，不该再有）：$e');
  }
  fail('未取走的异常超过 16 条 —— 多半不止一个问题，别再往下走了');
}

/// 交替 [runAsync + pump] —— 真实起播必须让真事件循环跑起来，
/// 纯 fake-async 里 Player.open() 永远不完成。
Future<int> _settle(
  WidgetTester t,
  GlobalKey<LiveEmbeddedPlayerState> key, {
  int rounds = 40,
  required String tag,
}) async {
  for (var i = 0; i < rounds; i++) {
    await t.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await _pushTextureIdIfNeeded();
    });
    await t.pump(const Duration(milliseconds: 50));
    _failOnAnyException(t);
    final st = key.currentState;
    final playing = st?.isPlaying ?? false;
    if (playing) {
      // ignore: avoid_print
      print('$tag i=$i hasPlayer=${st?.hasPlayerForTest} isPlaying=$playing');
      return i;
    }
  }
  return -1;
}

Future<void> _teardown(WidgetTester t) async {
  await t.pumpWidget(const SizedBox.shrink());
  // media_kit 的 real.dart 里有 `Future.delayed(5s, () => file.delete_())`，
  // 必须先卸载再走完这个假时钟定时器，否则报 "A Timer is still pending"。
  await t.pump(const Duration(seconds: 6));
  _failOnAnyException(t);
}

Widget _mount(GlobalKey<LiveEmbeddedPlayerState> key, ValueListenable<bool> v) =>
    MaterialApp(
      home: Scaffold(
        body: LiveEmbeddedPlayer(
          key: key,
          visible: v,
          stream: StreamCandidate(url: _url(), label: 'probe'),
          title: 'probe',
        ),
      ),
    );

String _readFile(String rel) {
  final f = File(rel);
  if (f.existsSync()) return f.readAsStringSync();
  return File('${Directory.current.path}/$rel').readAsStringSync();
}

/// 剥掉注释（`//` 行注释 **和** `/* */` 块注释，支持嵌套）
///
/// ★ 必须剥 —— 本项目踩过多次"断言匹配到注释文本 ⇒ 假通过"。
///   （本文件里那段解释"为什么传 visible"的注释就含 `visible:` 字样。）
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

/// 取某次调用的**实参表**（从 `(` 到配平的 `)`）
///
/// ★ 用配平括号而不是正则 —— 实参里有 `(msg) => …` 这种内嵌括号，
///   正则会在第一个 `)` 处截断 ⇒ 断言可能匹配到**别的**调用。
String _callArgs(String code, String callPrefix) {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ═══════════════════════════════════════════════════════════════════════
  //  静态契约：**接线**那一环（行为测试覆盖不到）
  //
  //  ★ 为什么必须有 —— 这是我实测发现的**覆盖缺口**，不是补文档：
  //    下面那条行为测试直接挂 `LiveEmbeddedPlayer(visible: …)`，
  //    而 `live_page.dart` 里那个**唯一构造点**是否真的把可见性传下来，
  //    **不在**它的路径上 ⇒ 把 `visible: widget.visible` 改成 `visible: null`
  //    （= 门控彻底失效，正是 task-74 ⑤ 要修的那个回归）
  //    行为测试**照样全绿**。
  //    ⇒ 用静态契约兜住（先例：`test/zz_t42_gate_verification_test.dart:451-478`，
  //      那里也是"行为层有结构墙 ⇒ 静态契约兜住"）。
  //
  //  ★ 注册在 DLL 检查**之前** —— 它是纯静态的，不该因缺原生库被 SKIP 掉。
  // ═══════════════════════════════════════════════════════════════════════
  group('task-74 ⑤ ★ 接线静态契约（行为测试覆盖不到的那一环）', () {
    test('★★★ LivePage 必须把 widget.visible 传给内联播放器', () {
      final raw = _readFile('lib/ui/live_page.dart');
      expect(raw, isNotEmpty, reason: '★ 前置：必须读得到 live_page.dart');
      final args = _callArgs(_codeOnly(raw), 'LiveEmbeddedPlayer(');

      // ★★ 阳性对照：先证明**提取到的确实是那个构造点**
      //    （否则"没有 visible:"可能只是"根本没提取到实参表"）
      expect(args, isNotEmpty,
          reason: '★ 前置：必须能定位 `LiveEmbeddedPlayer(` 的实参表。\n'
              '  若为空 ⇒ 下面的断言全是空的（假绿）。');
      expect(args, contains('stream: _stream'),
          reason: '★★ 阳性对照：提取到的必须是**直播页那个**构造点\n'
              '  （它一定传 `stream: _stream`）。\n'
              '  若这里就失败 ⇒ 提取逻辑错了 ⇒ 后面的断言无效。');
      expect(args, contains('key: _embedKey'),
          reason: '★★ 阳性对照：同一个构造点（它一定带 `key: _embedKey`）');

      // ★★★ 被验的那一条
      expect(args, contains('visible: widget.visible'),
          reason: '★★★ task-74 ⑤：内联播放器必须拿到**本页的可见性**。\n'
              '  缺了它（或写成常量）⇒ 380ms 窗口内切走时，'
              '播放器会在后台把流播起来（有声音）。\n'
              '  ★ 这是**接线**契约：行为测试直接挂播放器，覆盖不到这里。');
    });
  });

  // 缺原生库就 SKIP（只打印），绝不让环境问题把整套 flutter test 变红。
  final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
  if (!dll.existsSync()) {
    test('直播内嵌播放器：不可见时不起播（SKIP：缺 libmpv-2.dll）', () {
      // ignore: avoid_print
      print('SKIP: 未找到 libmpv-2.dll —— 这条需要原生依赖。'
          '先跑一次 flutter build windows --release 再跑测试。');
    });
    return;
  }
  MediaKit.ensureInitialized(libmpv: dll.absolute.path);

  testWidgets('不可见时不自动起播；恢复可见后补起播', (t) async {
    _createdHandles.clear();
    _pushedTextureId = false;
    _installVideoChannelMock();

    final key = GlobalKey<LiveEmbeddedPlayerState>();
    final visible = ValueNotifier<bool>(false);
    var pausedByHide = false;

    // 逐字复刻 lib/ui/live_page.dart:369-394 的外层监听器（**改后**语义）。
    // ★ 改前这里是 `if (st.isPlaying) { … }` —— 而 `_player == null` 时
    //   `isPlaying` 恒 false，洞就出在这：RED 实测「起播在途时切走 ⇒
    //   第 16 轮 ≈2062ms 隐藏页仍在播，pausedByHide 全程保持 false」。
    //   改后是**无条件** pause + 置位：置位记录「是**我们**暂停的」这个
    //   事实，切回时据此续播（task-41 保活）。
    visible.addListener(() {
      final st = key.currentState;
      if (st == null) return;
      if (!visible.value) {
        unawaited(st.pause());
        pausedByHide = true;
      } else if (pausedByHide) {
        pausedByHide = false;
        unawaited(st.resume());
      }
    });

    // ---- 阶段 1：一开始就不可见 ----------------------------------------
    await t.pumpWidget(_mount(key, visible));
    await t.pump(const Duration(milliseconds: 400)); // 越过 380ms 建播放器
    _failOnAnyException(t);
    final iHidden = await _settle(t, key, tag: 'HIDDEN');
    final st1 = key.currentState;
    // ignore: avoid_print
    print('PHASE1 hiddenPlaying=${st1?.isPlaying} '
        'hasPlayer=${st1?.hasPlayerForTest} reachedAt=$iHidden '
        'pausedByHide=$pausedByHide');

    expect(st1?.hasPlayerForTest, isTrue,
        reason: '380ms 后播放器应该已经建好（重活照旧延后，只是不起播）');
    expect(st1?.isPlaying, isFalse,
        reason: '本页不可见 ⇒ 绝不能开始播放（否则切走的页面会有声音）');
    expect(pausedByHide, isFalse,
        reason: '阶段 1 里可见性**从未变化**（一直是 false）⇒ 外层监听器'
            '根本没被调用过，pausedByHide 只能是 false。\n'
            '  ★ 改后外层是**无条件**置位 ⇒ 这条不再证明「外层没触发」；'
            '「不可见绝不起播」由上面那条 isPlaying 断言负责。');

    // ---- 阶段 2：恢复可见 ⇒ 补起播（阳性对照）--------------------------
    visible.value = true;
    await t.pump();
    _failOnAnyException(t);
    final iVisible = await _settle(t, key, tag: 'VISIBLE');
    final st2 = key.currentState;
    // ignore: avoid_print
    print('PHASE2 visiblePlaying=${st2?.isPlaying} reachedAt=$iVisible');
    // ignore: avoid_print
    print('VERDICT holeClosed=${iHidden < 0} instrumentAlive=${iVisible >= 0}');

    expect(iVisible >= 0, isTrue,
        reason: '恢复可见后必须能补起播 —— 否则无法区分"修好了"和"仪器死了"');

    visible.dispose();
    await _teardown(t);

    // 收尾：拆掉 mock（handler 本来也会在每条测试后清掉，这里显式写出来）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_videoChannel, null);
  }, timeout: const Timeout(Duration(seconds: 240)));
}
