// OPS-12 回归闸门：从播放页返回时，**标题栏本体不得在返回帧上重建**。
//
// # 缺陷形态（本闸门要挡住的）
// lib/ui/player_page.dart 的 _exitPlayer() 里有一行
//     titleBarDark.value = false;
// 它在**返回帧同步**触发 _TitleBarHostState._onVisibleChanged
// （lib/shell.dart:5221）的 setState —— 而 _TitleBarHost 挂在
// MaterialApp.builder 上、**在 Navigator 之上**，于是返回帧要多付
// 一次「深色 → 浅色」的标题栏重建（浅色那支是液态玻璃子树
// GlassContainer / LiquidRoundedRectangle，见 lib/shell.dart:5473-5497）。
//
// # 判据（为什么不是「不抛异常就算过」）
//   ① 前置条件必须成立：播放页真的活着、标题栏真的被压暗过
//      —— 否则「返回帧没有重建」是**假阳性**；
//   ② 返回帧上**不得**出现标题栏本体的重建
//      （= _TitleBarHost 之下、Navigator 之上的元素；Navigator 自身
//        因 pop 被弄脏属框架固有成本，必须排除）；
//   ③ 深色态**必须**在返回后若干帧内被复位
//      —— 否则「干脆不复位」也能骗过 ②（标题栏会一直是黑的）；
//   ④ 同一个探针必须**看得见**一次人为的标题栏重建（阳性对照）
//      —— 否则 ② 可能只是因为探针根本没装上。
//
// ⚠️ 全程**不得**用 pumpAndSettle：首页有一批常驻循环动画
//    （v9 实测第 1–29 帧恒定 60 个 HomePage 动画元素在烧），
//    永远 settle 不了 ⇒ 测试会「did not complete」卡死。
//    一律用固定 pump(Duration)。
// ignore_for_file: avoid_print
@Tags(['native-media'])
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/app_tray.dart';
import 'package:sourin_spike/shell.dart';
import 'package:sourin_spike/ui/media_page.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 'package:sourin_spike/ui/titlebar_visibility.dart';

/// 挂点定位用的同步落盘标记（绕过 print 缓冲）—— 万一又挂住，看这个文件就知道挂在哪一行。
///
/// ★ 跨平台（2026-10-10 预检）：路径**不许**写成 `r'.probe\ops\…'`。
///   `.probe/` 不在仓库里（.gitignore），干净检出（CI / 别人的机器）上它不存在，
///   而 POSIX 会把反斜杠当成**文件名字符** ⇒ 那是「一个名叫 `.probe\ops\…` 的文件」
///   而不是一个目录，父目录根本不存在。
///   这里用 `${Platform.pathSeparator}` 拼，并由 [_ensureLog] 先建父目录；
///   两平台都是「同一个来源拼路径 + 先建目录」，所以同一份断言在两边都成立。
File _ensureLog(String path) {
  final f = File(path);
  final d = f.parent;
  if (!d.existsSync()) d.createSync(recursive: true);
  return f;
}

final File _log = _ensureLog(<String>['.probe', 'ops', '_jank_gate_trace.txt']
    .join(Platform.pathSeparator));

void mark(String s) {
  final ms = DateTime.now().millisecondsSinceEpoch % 1000000;
  try {
    _log.writeAsStringSync('[' + ms.toString() + '] ' + s + '\n',
        mode: FileMode.append, flush: true);
  } catch (_) {}
}

// ═══════════════════════════════════════════════════════════════════════
// ★★ 本文件**禁止**往仓库根目录写任何文件（2026-10-10 JANKFIX 实测定论）
// ═══════════════════════════════════════════════════════════════════════
//
// 这里原来有一个 `_stageCoreDll()`：它把 `sourin_core.dll` 从
// `build\windows\x64\runner\Release`（或 rust target 目录）**拷进仓库根**，
// 好让 `DynamicLibrary.open('sourin_core.dll')` 能成功。它已删除。
//
// # ① 本闸门**不需要**核心库（实测依据，不是推断）
//
// 把三个候选源 dll 全部改名、且仓库根也没有 dll 的前提下跑
// ```text
// flutter test --no-pub --concurrency=1 --run-skipped --tags native-media \
//   --reporter expanded test/zz_cr_jank_titlebar_flip_test.dart
// ```
// 得到 `00:02 +1: All tests passed!`，读数：
// ```text
// 返回帧标题栏本体 = 0 / 返回帧全量 = 313 / 阳性对照 = 33 / 返回后 dark = false
// ```
// ⇒ ④ 要求的**阳性对照（33）照样成立**，探针确实装上了。也就是说本闸门的
//   判据（返回帧上「`_TitleBarHost` 之下、`Navigator` 之上」的元素重建计数）
//   只看 **widget 树怎么被弄脏**，**与核心库是否加载完全无关**：
//   核心不可用时那批 `[SHELL]/[SHELF]/[HOME]` 取数只是各自失败、保留旧值，
//   既不产生标题栏重建，也不影响 `titleBarDark` 的翻转与复位。
//   （这些失败路径在 ① 的前置条件与 ② 的返回帧观测里都只贡献噪声。）
//
// # ② 往仓库根拷贝 dll 会**污染同一次 `flutter test` 进程里的其它文件**
//
// `flutter test` 在**同一个进程**里按顺序跑多个测试文件，而仓库根又落在
// `DynamicLibrary.open` 的搜索路径上 ⇒ 一个文件往根目录放 dll，
// 会**同时**把其它文件的运行环境从「核心不可用」改成「核心可用」。
// 实测（Lead 已用因果实验定论）这条路径可让
// `test/skip_pair_grouping_test.dart`（4 例）、
// `test/t36_cache_refresh_test.dart`（4 例）、
// `test/t450_drag_humanlike_test.dart`（1 例）从绿变红 —— 那是**环境假红**，
// 不是产品缺陷。反向也一样：本文件**不许**依赖「根目录恰好有 dll」这种
// 本机状态来让自己变绿。
//
// # ③ 规则
//
// 本文件**不得**创建 / 拷贝 / 删除仓库根下的任何文件。
// 需要外部资源时一律放在 `build\` 或 `.probe\` 之下。

/// 一次「返回帧」的观测：哪些元素被重建、其中哪些属于标题栏本体。
class _FrameWatch {
  final List<String> rebuilt = <String>[];
  final List<String> titleBar = <String>[];
  bool armed = false;
}

final _FrameWatch watch = _FrameWatch();

/// 标题栏**本体** = _TitleBarHost 之下、**Navigator 之上**的那部分。
///
/// 为什么必须排除 Navigator 之下：_TitleBarHost 挂在 MaterialApp.builder
/// 上（包住 Navigator），所以返回帧里框架自带的 pop 级联
/// （Overlay / _ModalScope / MediaPage / DetailPage …）**全都**以
/// _TitleBarHost 为祖先 —— 那部分不是本缺陷，缺陷是标题栏本体
/// （深色支 ↔ 浅色支）被重建。
bool _inTitleBarProper(Element e) {
  final self = e.widget.runtimeType.toString();
  // Navigator 是 _TitleBarHost 的**直接子节点**，但 pop 本身就会
  // 弄脏它（_cancelActivePointers / _didChangeEntryOpacity）——
  // 那是框架固有成本，不是本缺陷，必须排除它自己。
  if (self == 'Navigator') return false;
  if (self == '_TitleBarHost') return true;
  var hit = false;
  e.visitAncestorElements((a) {
    final n = a.widget.runtimeType.toString();
    if (n == 'Navigator') {
      hit = false;
      return false;
    }
    if (n == '_TitleBarHost') {
      hit = true;
      return false;
    }
    return true;
  });
  return hit;
}

void _arm() {
  watch.rebuilt.clear();
  watch.titleBar.clear();
  watch.armed = true;
  debugOnRebuildDirtyWidget = (Element e, bool builtOnce) {
    if (!watch.armed) return;
    final name = e.widget.runtimeType.toString();
    watch.rebuilt.add(name);
    if (_inTitleBarProper(e)) watch.titleBar.add(name);
  };
}

void _disarm() {
  watch.armed = false;
  debugOnRebuildDirtyWidget = null;
}

String _hist(List<String> names) {
  final h = <String, int>{};
  for (final n in names) {
    h[n] = (h[n] ?? 0) + 1;
  }
  final rows = h.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  return rows.map((e) => e.key + '×' + e.value.toString()).join(', ');
}

Future<void> _claim(WidgetTester t) async {
  while (t.takeException() != null) {}
}

/// 收尾：**不许** pumpAndSettle（首页动画永不静止）。
Future<void> _drain(WidgetTester t) async {
  mark('D1 shrink');
  await t.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await t.pump(const Duration(milliseconds: 16));
    await _claim(t);
  }
  mark('D2 pumps done');
  for (var i = 0; i < 40; i++) {
    RemoteBridge.instance.stop();
    await t.pump(const Duration(seconds: 3));
  }
  RemoteBridge.instance.stop();
  mark('D3 drain done');
}

/// 按生产路径把「首页 → 播放页」搭起来（与 .probe/ops 里的现场探针同一套）。
Future<void> _mountPlayer(WidgetTester t) async {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = const Size(1280, 800);
  addTearDown(t.view.reset);
  final oldOnError = FlutterError.onError;
  FlutterError.onError = (details) {};
  await t.pumpWidget(const SourinApp());
  await t.pump();
  FlutterError.onError = oldOnError;
  await _claim(t);
  await t.pump(const Duration(milliseconds: 600));
  await _claim(t);
  final nav = AppTray.navigatorKey.currentState;
  nav!.push<void>(
    MaterialPageRoute<void>(
      builder: (_) => const MediaPage(
        provider: 'cctv',
        id: 'cctv1',
        title: 'OPS-12 返回卡顿',
      ),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 60));
    await _claim(t);
  }
}

void main() {
  setUpAll(() {
    // ★ 跨平台：`_ensureLog` 只保证**构造 `_log` 时**父目录在；
    //   这一步是「本次进程第一次写」，目录可能已被上一次运行/别的 agent 清掉
    //   ⇒ 每次写之前都确认一次，路径来源与 `_log` 完全一致。
    _ensureLog(_log.path).writeAsStringSync(
        '=== GATE RUN ' + DateTime.now().toIso8601String() + '\n',
        mode: FileMode.append,
        flush: true);
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
    // ★ 这里**不得**再往仓库根 stage 核心 dll —— 见上方 _stageCoreDll 删除处的说明。
    mark('setUpAll done');
  });
  setUp(() => RemoteBridge.instance.stop());
  tearDown(() {
    _disarm();
    RemoteBridge.instance.stop();
  });

  testWidgets('返回帧不得重建标题栏本体，且深色态仍被复位', (t) async {
    /*
     * ⚠️ 断言顺序是**刻意的**（这是本文件最容易踩的坑）：
     * 全部观测（含 drain 收尾）做完之后才 expect。
     *
     * 为什么：上一版在「返回帧观测完 → 立刻 expect(标题栏为空)」，
     * 结果测试**挂死**（flutter_test 报 did not complete，00:27~00:55 不等），
     * 落盘 trace 停在 G3（观测完成、断言未过）那一行之后 ——
     * 即**断言失败的处理路径本身**在这个现场里不返回。
     * 所以先把现场收干净（shrink + 固定 pump 排空），再一次性断言。
     */
    mark('G1 mount');
    await _mountPlayer(t);
    mark('G2 mounted, dark=' + titleBarDark.value.toString());

    // ── ① 前置条件（必须成立，否则本闸门是假阳性）──────────────────
    expect(
      titleBarDark.value,
      isTrue,
      reason: '前置条件：播放页活着时标题栏必须是深色态（否则本闸门是假阳性）',
    );

    // ── ② 返回帧观测 ────────────────────────────────────────────────
    _arm();
    final opened = debugPlayerBackForProbe();
    final sw = Stopwatch()..start();
    await t.pump(const Duration(milliseconds: 16)); // ← 这就是「返回帧」
    final wallUs = sw.elapsedMicroseconds;
    _disarm();
    final tbCount = watch.titleBar.length;
    final tbDetail = _hist(watch.titleBar);
    final allCount = watch.rebuilt.length;
    final allDetail = _hist(watch.rebuilt);
    mark('G3 return frame observed: tb=' +
        tbCount.toString() +
        ' all=' +
        allCount.toString());
    print('[OPS-12] 返回帧：重建元素 ' +
        allCount.toString() +
        ' 个 / 墙钟 ' +
        (wallUs / 1000).toStringAsFixed(2) +
        'ms；其中**标题栏本体** ' +
        tbCount.toString() +
        ' 个');
    print('[OPS-12] 返回帧重建明细（全量）：' + allDetail);
    if (tbCount > 0) {
      print('[OPS-12] 返回帧标题栏本体明细：' + tbDetail);
    }
    expect(opened, isTrue, reason: '前置条件：播放页必须真的活着（_livePlayerState != null）');
    mark('G3b printed');

    // ── ③ 深色态仍然被复位（不允许「干脆不复位」骗过 ②）──────────
    for (var i = 0; i < 3; i++) {
      await t.pump(const Duration(milliseconds: 16));
      await _claim(t);
    }
    final darkAfter = titleBarDark.value;
    mark('G4 dark=' + darkAfter.toString());

    // ── ④ 阳性对照：同一个探针必须看得见标题栏重建 ────────────────
    titleBarDark.value = true;
    titleBarDark.value = false;
    _arm();
    final sw2 = Stopwatch()..start();
    await t.pump(const Duration(milliseconds: 16));
    final wallUs2 = sw2.elapsedMicroseconds;
    _disarm();
    final posCount = watch.titleBar.length;
    mark('G5 positive tb=' + posCount.toString());
    print('[OPS-12] 阳性对照：人为翻一次深色态 ⇒ 标题栏本体重建 ' +
        posCount.toString() +
        ' 个元素 / 墙钟 ' +
        (wallUs2 / 1000).toStringAsFixed(2) +
        'ms；明细：' +
        _hist(watch.titleBar));

    await _drain(t);
    mark('G7 drain done, asserting');
    print('[OPS-12] 汇总：返回帧标题栏本体 = ' +
        tbCount.toString() +
        ' / 返回帧全量 = ' +
        allCount.toString() +
        ' / 阳性对照 = ' +
        posCount.toString() +
        ' / 返回后 dark = ' +
        darkAfter.toString());

    // ── 断言（现场已收干净）────────────────────────────────────────
    expect(
      posCount,
      greaterThan(0),
      reason: '阳性对照失败：探针看不见标题栏重建 ⇒ ② 的「空」不能证明任何事',
    );
    expect(
      darkAfter,
      isFalse,
      reason: '返回之后标题栏必须恢复浅色（深色态复位被推迟 ≠ 被删掉）',
    );
    expect(
      tbCount,
      0,
      reason: '返回帧重建了标题栏本体（' +
          tbCount.toString() +
          ' 个元素：' +
          tbDetail +
          '）—— 深色态复位必须在**返回帧之外**发生，'
              '否则这一帧要多付一次液态玻璃标题栏的重建',
    );
    mark('G8 asserts done');
  });
}
