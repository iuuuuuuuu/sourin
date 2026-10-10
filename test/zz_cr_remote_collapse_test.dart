// ═══════════════════════════════════════════════════════════════════════
//  OPS-15 回归门禁：局域网遥控「收起」点了没反应 + 收起态要持久记忆
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
//
// > 「这个局域网遥控这里的 收齐点击也没效果,这个要持久记忆的,下次重新打开也要记住」
//
// # 缺陷（两条，同一个根因族）
//
// ① 运行中点「收起」毫无反应
// `lib/ui/settings_page.dart` 的 `class _RemoteBlockState`：
//
// ```dart
// bool _open = false;                                // 纯内存，不落盘
// bool get _shouldOpen => _open || widget.running;   // 缺陷
// ```
//
// 截图里遥控正在运行（展开态画的是地址 / 配对码），点「收起」只把
// `_open` 置 false，而 `widget.running` 为 true ⇒ `_shouldOpen` 立刻又变
// true ⇒ 视觉上完全没反应。这就是 Owner 说的「点击也没效果」。
//
// ② 收起态不落盘 ⇒ 每次进设置页都回默认收起
// `_open` 是 State 字段，进程一退就没了。
//
// # 本文件钉住的四条行为
//
//   ① running=true 时点「收起」⇒ 真的收起（RED 就是这条）
//   ② 重建 state（模拟重开客户端：偏好落盘 → 清内存 → 重新 load）
//      ⇒ 仍是收起
//   ③ 从未手动操作过 + running=true ⇒ 默认展开（否则用户以为功能没了）
//   ④ 收起态那一行要显示当前状态（写死「没开启」在 running 时是错的）
//
// # 判据口径：行为级，不做源码文本扫描
//
// ★ 断言一律落在「展开/收起两棵不同的子树」上：
//     展开态 = 「收起」按钮 + `child` 的正文标记；
//     收起态 = 没有按钮、没有正文标记、有一行状态副标题。
//   「点了没反应」这种缺陷只有这样才测得出来 —— 断言按钮文案或
//   `_shouldOpen` 的返回值都会漏过它。
//
// ★ 持久化走仓库既有通道 `UiPrefs`（<数据目录>/ui-prefs.json），
//   key 名由本文件钉死为 'dsh.settings.remoteBlockOpen'
//   （与 `dsh.danmaku.*` / `dsh.download.*` 同一套命名习惯）。
//
// # ⚠️ 测试自身的两个坑（第一版就是栽在这里，别改回去）
//
// 1. `UiPrefs.flush()` / `load()` 是**真文件 I/O**。`testWidgets` 的 body
//    跑在 FakeAsync 里，真实 I/O 的 Future 永远不会在假时钟下完成 ⇒
//    必须用 `tester.runAsync(...)` 把真 I/O 放回真实事件循环。
// 2. `UiPrefs.set()` 会起一个 300ms 的 `_flushSoon` 定时器。测试结束时
//    它还挂着 ⇒ flutter_test 直接判「A Timer is still pending even after
//    the widget tree was disposed」。这不是产品缺陷，是测试写法缺陷：
//    每次写偏好后都要 `_drainPrefs()` 把它排干。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings_page.dart' show RemoteBlock;

/// 持久化 key —— 钉死它，防止哪天悄悄换键导致「记忆丢失」
const String kOpenKey = 'dsh.settings.remoteBlockOpen';

/// 展开态才渲染的正文标记（子 widget）
const String kBodyMark = '遥控正文标记-不该在收起态出现';

/// 认领 pump 期间积压的环境异常（无核心环境的 FFI 异常等）
void _claim(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

/// 偏好文件所在的临时「数据目录」
late Directory _dataDir;

void main() {
  setUp(() async {
    _dataDir = Directory.systemTemp.createTempSync('sourin_remote_block');
    addTearDown(() {
      // Windows 上偶尔还会被上一轮未收尾的写句柄占住 —— 临时目录清不掉
      // 与被测行为无关，不该判测试失败。
      try {
        if (_dataDir.existsSync()) {
          _dataDir.deleteSync(recursive: true);
        }
      } catch (_) {}
    });
    // 从干净初值开始（UiPrefs._data 是 static，跨用例共享）
    UiPrefs.debugResetForTest();
    // ★ 必须先 load：set() 只改内存，flush() 需要 _file 才能落盘
    await UiPrefs.load(_dataDir.path);
  });

  Widget host(Widget child) {
    final theme = AppTheme.themeFor(Brightness.dark);
    return mui.MaterialApp(
      theme: theme,
      builder: (context, c) =>
          AppThemeHost(data: theme, child: c ?? const SizedBox()),
      home: mui.Scaffold(
        body: mui.SingleChildScrollView(
          child: mui.Padding(
            padding: const EdgeInsets.all(24),
            child: child,
          ),
        ),
      ),
    );
  }

  /// 挂载遥控区块。key 每次给新的 ⇒ 强制换掉 State（= 重新进入本页）
  Future<void> pumpBlock(
    WidgetTester t, {
    required bool running,
    required Key key,
  }) async {
    await t.pumpWidget(
      host(
        RemoteBlock(
          key: key,
          running: running,
          autoStart: false,
          busy: false,
          child: const Text(kBodyMark),
        ),
      ),
    );
    await t.pumpAndSettle();
    _claim(t);
  }

  /// 排干 UiPrefs 的延迟落盘。
  ///
  /// 顺序**不能反**：
  ///   ① 先在 runAsync 里把待写的偏好真正落盘（FakeAsync 下真 I/O 的
  ///      Future 永不完成，会把文件截成 0 字节 —— 第一版就是这么坏掉的）；
  ///   ② 再推 400ms 假时钟，让 _flushSoon 那个 300ms 定时器**真的到期**
  ///      （此时 _dirty 已是 false，flush 直接返回，不会再起 I/O）；
  ///   ③ 最后 pumpAndSettle 收掉动画。
  /// 漏掉②⇒ flutter_test 报
  /// 「A Timer is still pending even after the widget tree was disposed」。
  Future<void> drainPrefs(WidgetTester t) async {
    await t.runAsync(() => UiPrefs.flush());
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    _claim(t);
  }

  /// 点一下并**只推一帧**（零时长）—— 关键：不能让假时钟走到 300ms，
  /// 否则 _flushSoon 的定时器会在真 I/O 还没落盘前就触发写文件。
  /// 落盘统一交给随后的 [drainPrefs]。
  Future<void> tapNoClock(WidgetTester t, Finder f) async {
    await t.tap(f);
    await t.pump();
    _claim(t);
  }

  /// 偏好文件的绝对路径（`UiPrefs.load` 拼的就是这个名字）
  String prefsPath() =>
      _dataDir.path + Platform.pathSeparator + 'ui-prefs.json';

  /// 直接从磁盘读偏好文件（**不经 UiPrefs 的内存**）——
  /// 「真的写进去了」只有这样才算证明。
  Future<Map<String, dynamic>> readPrefsFromDisk(WidgetTester t) async {
    final raw = await t.runAsync(() async {
      final f = File(prefsPath());
      return f.existsSync() ? await f.readAsString() : null;
    });
    if (raw == null) return <String, dynamic>{};
    final m = jsonDecode(raw);
    return m is Map ? m.map((k, v) => MapEntry(k.toString(), v)) : {};
  }

  /// ★ 模拟「重开客户端」：先把内存里的偏好落盘，
  ///   再把 UiPrefs 的内存整个清掉（debugResetForTest），
  ///   最后从同一个数据目录重新 load —— 与新进程读同一个 ui-prefs.json 一致。
  Future<void> restartClient(WidgetTester t) async {
    await drainPrefs(t);
    await t.runAsync(() async {
      UiPrefs.debugResetForTest();
      await UiPrefs.load(_dataDir.path);
    });
  }

  // ① 运行中点「收起」必须真的收起（本次 RED 的那一条）

  testWidgets('★★① running=true 时点「收起」⇒ 真的收起', (t) async {
    await pumpBlock(t, running: true, key: const ValueKey('a'));

    // 前置：遥控在跑 ⇒ 默认是展开态（画面上能看到地址 / 配对码）
    expect(find.text('收起'), findsOneWidget, reason: '前置：running ⇒ 默认展开');
    expect(find.text(kBodyMark), findsOneWidget, reason: '前置：展开态才画 child');

    await tapNoClock(t, find.text('收起'));

    // ★ 缺陷版本：`widget.running` 为 true ⇒ `_shouldOpen` 仍为 true
    //   ⇒ 按钮和 child 原地不动，这三条全部失败。
    expect(find.text('收起'), findsNothing,
        reason: '★ 点「收起」后不该还有「收起」按钮');
    expect(find.text(kBodyMark), findsNothing,
        reason: '★ 点「收起」后 child 必须从树上消失（真的收起，而不是换个文案）');
    expect(find.textContaining('运行中'), findsOneWidget,
        reason: '★ 收起态那一行要如实显示「运行中」');

    await drainPrefs(t);
  });

  // ② 收起态跨进程持久化（重开客户端仍是收起）

  testWidgets('★★★② 重开客户端后仍是收起（偏好要落盘）', (t) async {
    await pumpBlock(t, running: true, key: const ValueKey('a'));
    await tapNoClock(t, find.text('收起'));
    expect(find.text(kBodyMark), findsNothing, reason: '前置：先收起一次');

    // ★ 真的换进程：落盘 → 清内存 → 重新 load
    await restartClient(t);

    // ★★ 磁盘上的证据（不经内存）：key 必须真的写进 ui-prefs.json
    final onDisk = await readPrefsFromDisk(t);
    expect(onDisk[kOpenKey], '0',
        reason: '★★★ 收起这个事实必须落进 ui-prefs.json（key=$kOpenKey，值 \'0\'）；'
            '否则「下次重新打开也要记住」做不到。文件内容=' +
            jsonEncode(onDisk));
    expect(UiPrefs.get(kOpenKey), '0',
        reason: '★★★ 重新 load 之后内存里也要读得回来');

    await pumpBlock(t, running: true, key: const ValueKey('b'));
    expect(find.text(kBodyMark), findsNothing,
        reason: '★★★ 重开客户端 + 遥控仍在运行 ⇒ 仍保持收起'
            '（用户手动收起过，记忆优先于 running）');
    expect(find.textContaining('运行中'), findsOneWidget,
        reason: '★★★ 收起态如实说「运行中」');

    await drainPrefs(t);
  });

  // ③ 没记忆过 ⇒ 跟随 running（默认展开）

  testWidgets('★★★③ 从未手动操作过 + running=true ⇒ 默认展开', (t) async {
    await pumpBlock(t, running: true, key: const ValueKey('a'));

    expect(UiPrefs.get(kOpenKey), isNull, reason: '前置：本用例不做任何手动操作');
    expect(find.text(kBodyMark), findsOneWidget,
        reason: '★★★ 首次进入本页时遥控已在运行 ⇒ 必须默认展开'
            '（否则用户以为功能没了）');
    expect(find.textContaining('运行中'), findsNothing,
        reason: '前置：这是展开态，不该出现收起态的状态行');
  });

  testWidgets('★ 从未手动操作过 + 没在运行 ⇒ 默认收起', (t) async {
    await pumpBlock(t, running: false, key: const ValueKey('a'));

    expect(find.text(kBodyMark), findsNothing, reason: '低频功能默认收起');
    expect(find.textContaining('没开启'), findsOneWidget,
        reason: '收起态要如实显示「没开启」');
  });

  // 手动点开 ⇒ 记忆成「展开」（下次进入即便没在运行也是展开）

  testWidgets('★★ 手动点开一次后，记忆里是「展开」', (t) async {
    await pumpBlock(t, running: true, key: const ValueKey('a'));
    await tapNoClock(t, find.text('收起'));

    await tapNoClock(t, find.text('局域网遥控')); // 点收起态那一行展开
    expect(find.text(kBodyMark), findsOneWidget, reason: '前置：点开了');

    await restartClient(t);
    final onDisk = await readPrefsFromDisk(t);
    expect(onDisk[kOpenKey], '1',
        reason: '★★ 点开也要记住：磁盘上应是 \'1\'，文件内容=' + jsonEncode(onDisk));

    await pumpBlock(t, running: false, key: const ValueKey('b'));
    expect(find.text(kBodyMark), findsOneWidget,
        reason: '★★ 用户手动点开过 ⇒ 记住展开；重启后即便没在运行也保持展开');

    await drainPrefs(t);
  });

  // ④ 收起态文案随 running 变化

  testWidgets('★★④ 收起态那一行的状态随 running 变化', (t) async {
    await pumpBlock(t, running: false, key: const ValueKey('a'));
    expect(find.textContaining('没开启'), findsOneWidget, reason: '未运行 ⇒ 「没开启」');
    expect(find.textContaining('运行中'), findsNothing, reason: '未运行不该写「运行中」');

    // 记住收起（这样 running=true 时才轮得到「收起态 + 运行中」这一格）
    await tapNoClock(t, find.text('局域网遥控'));
    await tapNoClock(t, find.text('收起'));

    await pumpBlock(t, running: true, key: const ValueKey('b'));
    expect(find.textContaining('运行中'), findsOneWidget,
        reason: '★★★ running 时收起态必须说「运行中」—— '
            '写死「没开启」会让用户以为遥控没开');
    expect(find.textContaining('没开启'), findsNothing,
        reason: 'running 时不该再显示「没开启」');

    await drainPrefs(t);
  });
}
