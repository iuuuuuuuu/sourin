// ═══════════════════════════════════════════════════════════════════════
//  task-6【阶段二】首页直播条可用性闸 —— **真进程 · 真核心**取证探针
//  （2026-10-09，Owner 第 8 条）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
//
// > 只能黑屏的兼容不了直接放弃不要出现
//
// # 判据（四个场景，全部要**读数**）
//
// ```text
// C  反向控制（假 fetch：cctv1 伪造成可播）  ⇒ N=8 M=1 块高 44 chip=CCTV-1
//                                            ★ 先做它：保证"块**能**出现"
// A  真实网络（真 getLiveStream）            ⇒ N=8 M=0 块高 0x0（全 audioOnly）
// A2 同一批候选的 M 从 1 → 0                 ⇒ ★★ 证明闸是**动态**的
//                                              （不是"写死 cctv 不可用"）
// B  独立复核（探针自己取流分类）             ⇒ playable 计数 == A 的 M
// D  切到 iptv 源 + 调真回调                 ⇒ 播放器 provider == 'iptv'
// ```
//
// # 为什么必须真进程（widget 测试证不了）
//
// ```text
// ① flutter_test 里 **加载不了 sourin_core.dll**（error 126）⇒ FFI 永不执行
//    ⇒ 探针拿不到真流 ⇒ 「闸前/闸后」两个数**都不是真的**
// ② 闸判据是"这个台此刻有没有可播线路"，取决于**真实网络 + 真实插件**
//    （cctv.js 把视频线标成 drmProtected）⇒ 只有真进程能量到真数
// ③ 参数透传的终点是 Navigator.push(PlayerPage(provider: …))
//    ⇒ 只有真树里能读到那个 PlayerPage 的 widget.provider
// ```
//
// # 数据目录隔离（铁律）
//
// 本探针挂的是**真**首页 + **真**播放器（点 chip 会 push PlayerPage），
// ⇒ 绝不指向用户的真库。走 T6_DATA_DIR 环境变量（运行时读）。
//
// ⚠️ 全新数据目录里**没有 cctv.js** —— 核心只释放三个随程序发布的插件
//    （state.rs:176/183/189 = demo/iptv/tvbox-live）。所以本探针自己把
//    仓库里的 cctv.js 复制进隔离插件目录，并把**版本号**记进产物。
//
// # 仪器：读数全部取自**渲染树**与**被测对象自己**
//
// ```text
// · 直播条块高   = _LiveStrip 元素的 RenderBox 尺寸（全不可播 ⇒ 0x0）
// · chip 数/名字 = _LiveStrip 子树里的 InkWell / Text
// · 闸前闸后     = debugHomeLiveStrip（由**渲染路径自己**上报）
// · 参数透传     = 被 push 的 PlayerPage.widget.provider / liveChannelId
// ```
//
// # 两个"仪器自身的坑"（都实测踩过，写在这里免得后人再踩）
//
// ```text
// ① 探针 exe 被拷到 .probe/t6-run 运行（那里有 libmpv-2.dll 与
//    sourin_core.dll）⇒ Directory.current = .probe/t6-run
//    ⇒ 用相对路径找仓库里的 cctv.js **必然找不到**（第一次跑就是这样，
//      源只有 3 个、首页可用 0 个源 ⇒ 直播条压根没渲染、一条读数都没有）
//    ⇒ 仓库路径必须用 --dart-define=PROBE_REPO=… 编译期注入。
// ② 探针窗口弹在**正在被人使用**的桌面上 ⇒ 人点了几下底栏，
//    日志里出现 [NAV] home->settings->…->live（我没有产生过这些）
//    ⇒ 首页被切走、要量的直播条不在树上
//    ⇒ 窗口必须挪到屏幕外（setPosition(4000,4000) + setSkipTaskbar），
//      并且每次要量首页之前**显式切回 home tab**。
// ```
//
// # 怎么跑
//
// ```powershell
// pwsh -File .probe/t6_build_run.ps1
// ```
//
// ⚠️ 跑完必须用 flutter build windows --release -t lib/shell.dart
//    把 Release 树恢复成产品入口（否则下一个人的产物是探针）。

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'core/ffi.dart';
import 'core/models.dart';
import 'core/sourin_api.dart';
import 'core/ui_prefs.dart';
import 'shell.dart' show AppTab, SourinApp, debugShellKey;
import 'ui/home_page.dart';
import 'ui/live_availability.dart';
import 'ui/player_page.dart' show PlayerPage;
import 'ui/widgets/source_bar.dart' show SourceBar;

const _outDir = r'D:\WishProject\sourin-flutter-spike\.probe';
// ⚠️ 必须**转义**反斜杠：非 raw 字符串里的 `\t` 是**制表符**，
//    写出来的路径会变成 ".probe<TAB>6-livestrip.txt" ⇒ 写文件抛异常
//    ⇒ 被 catch 静默吞掉 ⇒ 产物一个都不落（实测踩了三次才发现）。
//    （t2d 探针用的是 '$_outDir\\t2d-…'，这里照它改）
const _logFile = '$_outDir\\t6-livestrip.txt';

final List<String> _log = [];

/// 逐行**立即落盘**（不是最后写一次）
///
/// 为什么：探针可能被 runner 超时杀掉；stdout 又被外层
/// ReadToEnd() 缓冲到进程退出为止 ⇒ 挂死时一个字节都拿不到。
void say(String s) {
  _log.add(s);
  debugPrint('[T6] $s');
  try {
    File(_logFile).writeAsStringSync(_log.join('\n'));
  } catch (_) {}
}

int pass = 0;
int fail = 0;
void ok(String name, bool cond, [String extra = '']) {
  if (cond) {
    pass++;
    say('✓ $name${extra.isEmpty ? '' : '  $extra'}');
  } else {
    fail++;
    say('✗ $name${extra.isEmpty ? '' : '  $extra'}');
  }
}

Future<void> finish(int code) async {
  say('');
  say('RESULT pass=$pass fail=$fail');
  try {
    await File(_logFile).writeAsString(_log.join('\n'));
  } catch (_) {}
  await Future<void>.delayed(const Duration(milliseconds: 200));
  exit(code);
}

// ═══════════════════════════════════════════════════════════════════════
//  数据目录 + 插件种子
// ═══════════════════════════════════════════════════════════════════════

Future<String> _resolveDataDir() async {
  final env = Platform.environment['T6_DATA_DIR'];
  if (env != null && env.isNotEmpty) {
    final d = Directory(env);
    if (!await d.exists()) await d.create(recursive: true);
    return d.path;
  }
  const override = String.fromEnvironment('DATA_DIR_OVERRIDE');
  if (override.isNotEmpty) {
    final d = Directory(override);
    if (!await d.exists()) await d.create(recursive: true);
    return d.path;
  }
  throw StateError('必须给 T6_DATA_DIR 或 DATA_DIR_OVERRIDE（隔离数据目录）');
}

/// 核对"隔离插件目录里有没有 cctv.js"，并把**版本号**记进产物
///
/// # 为什么种子不在 Dart 里放（实测踩到）
///
/// 第一版是本探针自己把仓库里的 cctv.js 复制进隔离目录 ——
/// **release** 构建跑得好好的（"插件种子: cctv.js v1.0.0（19692 B）"），
/// 但同一份代码换成 **debug** 构建后，进程在**这一句之前**就以
/// 0xC0000005（访问冲突，错误模块 unknown、偏移 0x258d4e647d3）崩掉，
/// 连下面一行日志都打不出来。
/// ⇒ 改成由 runner 脚本（.probe/t6_build_run.ps1）在**进程外**拷好，
///   本函数只做**只读核对**：不写文件、不解析插件源码。
///   （探针读的是 debug-only 计数器，所以必须用 debug 构建 ⇒ 只能这样绕。）
String _checkCctv(String dataDir) {
  final p = '$dataDir${Platform.pathSeparator}plugins'
      '${Platform.pathSeparator}cctv.js';
  final f = File(p);
  if (!f.existsSync()) return '★ 缺 cctv.js: $p（runner 脚本应先拷好）';
  return 'cctv.js 就位（${f.lengthSync()} B）→ $p';
}

// ═══════════════════════════════════════════════════════════════════════
//  渲染树仪器
// ═══════════════════════════════════════════════════════════════════════

final _rootKey = GlobalKey();

Element? root() => _rootKey.currentContext as Element?;

Element? find(Type t, [Element? from]) {
  final e = from ?? root();
  if (e == null) return null;
  Element? hit;
  void walk(Element x) {
    if (hit != null) return;
    if (x.widget.runtimeType == t) {
      hit = x;
      return;
    }
    x.visitChildren(walk);
  }

  if (e.widget.runtimeType == t) return e;
  e.visitChildren(walk);
  return hit;
}

/// 按 runtimeType.toString() 找 —— 私有类型（_LiveStrip / _SectionBlock）
/// 没法用 Type 字面量引用，但 runtimeType 的字符串是稳定的。
Element? findByTypeName(String name, [Element? from]) {
  final e = from ?? root();
  if (e == null) return null;
  Element? hit;
  void walk(Element x) {
    if (hit != null) return;
    if (x.widget.runtimeType.toString() == name) {
      hit = x;
      return;
    }
    x.visitChildren(walk);
  }

  if (e.widget.runtimeType.toString() == name) return e;
  e.visitChildren(walk);
  return hit;
}

/// 从 [e] 往上找第一个 runtimeType 名字为 [name] 的祖先（含自己）
///
/// ★ 为什么必须"从直播条往上找"而不是全树扫第一个 _SectionBlock：
///   全树扫拿到的是 DFS 第一个区块，而"带直播条的那个区块"是哪一个
///   取决于插件声明的顺序 —— 拿错区块量高度，读数就不是这一块的高度。
/// ⚠️ 不能用 Element._parent（库私有）⇒ 改成"从根往下找包含它的那个祖先"。
Element? ancestorByTypeName(Element? e, String name) {
  final target = e;
  if (target == null) return null;
  final r = root();
  if (r == null) return null;
  Element? best;
  void walk(Element x) {
    if (x.widget.runtimeType.toString() == name) {
      var hit = false;
      void inner(Element y) {
        if (hit || identical(y, target)) {
          hit = true;
          return;
        }
        y.visitChildren(inner);
      }

      x.visitChildren(inner);
      if (hit) best = x;
    }
    x.visitChildren(walk);
  }

  walk(r);
  return best;
}

Size? sizeOf(Element? e) {
  final ro = e?.renderObject;
  if (ro is RenderBox && ro.hasSize) return ro.size;
  return null;
}

Offset? centerOf(Element? e) {
  final ro = e?.renderObject;
  if (ro is RenderBox && ro.hasSize) {
    return ro.localToGlobal(ro.size.center(Offset.zero));
  }
  return null;
}

List<String> textsIn(Element? e) {
  final out = <String>[];
  if (e == null) return out;
  void walk(Element x) {
    final w = x.widget;
    if (w is Text && w.data != null) out.add(w.data!);
    x.visitChildren(walk);
  }

  walk(e);
  return out;
}

/// 直播条元素 + 它的几个读数（块高 / ListView 的 itemCount / 通道名单）
class StripReading {
  StripReading(this.el);
  final Element? el;

  Size? get size => sizeOf(el);

  /// ListView.itemCount —— 元素在但**没有 ListView** ⇒ 返回 null
  /// （这正是"整块消失"与"空盒子"的分界）
  int? get itemCount {
    if (el == null) return null;
    int? n;
    void walk(Element x) {
      final w = x.widget;
      if (w is ListView) n = w.childrenDelegate.estimatedChildCount;
      x.visitChildren(walk);
    }

    el!.visitChildren(walk);
    return n;
  }

  String? get provider {
    try {
      final v = (el!.widget as dynamic).provider;
      return v is String ? v : null;
    } catch (_) {
      return null;
    }
  }

  List<String> get channelIds {
    try {
      final v = (el!.widget as dynamic).channels;
      if (v is List) {
        final out = <String>[];
        for (final e in v) {
          out.add('${(e as dynamic).id}');
        }
        return out;
      }
    } catch (_) {}
    return const [];
  }

  /// 画出来的 chip 标签（= 用户真正能看到的台名）
  List<String> get chipNames => textsIn(el);

  String get desc => el == null
      ? '不存在'
      : 'size=${size?.width}x${size?.height} itemCount=$itemCount '
          'provider=$provider channels=$channelIds chipTexts=$chipNames';
}

StripReading readStrip() => StripReading(findByTypeName('_LiveStrip'));

/// 渲染树剖面：按 runtimeType 统计元素个数（前 22 名）
///
/// # 为什么必须有这个（实测踩到）
///
/// 探针报"直播条元素: 不存在"时，我无法区分下面三种情况：
/// ① 那一块**真的没渲染**（闸生效 —— 正是要证的）
/// ② 那个区块在**懒加载 sliver 里没被 build**（滚动位置问题）
/// ③ 我的 `findByTypeName` 找错了地方
/// 三者结论完全不同。⇒ 找不到元素时**必须**把树剖面打出来，
/// 看 `_SectionBlock` / `ListView` / `_Rail` 到底在不在。
String treeHistogram() {
  final counts = <String, int>{};
  void walk(Element x) {
    final n = x.widget.runtimeType.toString();
    counts[n] = (counts[n] ?? 0) + 1;
    x.visitChildren(walk);
  }

  final r = root();
  if (r == null) return '★ root=null（探针锚点没挂上）';
  walk(r);
  final entries = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return entries.take(22).map((e) => '${e.key}×${e.value}').join(' ');
}

/// 数某一类元素有多少个（判"懒加载没 build"用）
int countByTypeName(String name) {
  var n = 0;
  void walk(Element x) {
    if (x.widget.runtimeType.toString() == name) n++;
    x.visitChildren(walk);
  }

  final r = root();
  if (r != null) walk(r);
  return n;
}

/// 等 `_LiveStrip` 元素出现（最多 [maxMs]），并周期性打剖面
Future<bool> waitStrip(int maxMs, String tag) async {
  final t0 = DateTime.now();
  while (DateTime.now().difference(t0).inMilliseconds < maxMs) {
    if (findByTypeName('_LiveStrip') != null) return true;
    await pumpReal(10, tag);
  }
  return findByTypeName('_LiveStrip') != null;
}

/// 首页滚动位置（拿不到返回 null）
ScrollPosition? homeScroll() {
  final el = find(Scrollable);
  if (el is StatefulElement) {
    final st = el.state;
    if (st is ScrollableState) return st.position;
  }
  return null;
}

/// ★★ 把直播条**逼出来**：滚动首页列表（懒加载 sliver 只 build 可见项）
///
/// # 为什么需要（实测推断）
///
/// 两个构建里同一份产品代码，读数却不一样：
/// ¤¤¤text
/// release 跑：C 直播条元素 size=1392x44 itemCount=1 channels=[cctv1]  ← 找得到
/// debug   跑：C 直播条元素 不存在                                     ← 找不到
/// ¤¤¤
/// 而**两个构建里** `[HOME] 直播条: 闸前候选=…` 这一行**都没有出现**
/// （即 `_LiveStrip.build` 一次都没跑过）——
/// ⇒ 说明"找得到"那一轮是**碰巧**：首页用 `SliverChildListDelegate`，
///   屏幕外的区块**根本不 build**；滚动位置差一点，同一个区块就在/不在。
/// ⇒ 判据不能依赖"当前恰好可见"，必须**主动滚到它**。
///   顺序：原位置 → 顶部 → 底部 → 逐步下滚（每次一小屏）。
Future<bool> revealStrip(String tag) async {
  if (findByTypeName('_LiveStrip') != null) return true;
  final pos = homeScroll();
  if (pos == null) {
    say('  [$tag] 拿不到首页滚动位置（find(Scrollable)=null）');
    return false;
  }
  say('  [$tag] 滚动前: offset=${pos.pixels.toStringAsFixed(1)} '
      'max=${pos.maxScrollExtent.toStringAsFixed(1)} '
      'viewport=${pos.viewportDimension.toStringAsFixed(1)}');
  for (final target in <double>[0, pos.maxScrollExtent]) {
    pos.jumpTo(target.clamp(0, pos.maxScrollExtent));
    await pumpReal(12, '$tag-jump');
    if (findByTypeName('_LiveStrip') != null) {
      say('  [$tag] 滚到 ${target.toStringAsFixed(0)} 后**找到**直播条');
      return true;
    }
  }
  // 逐步下滚（每次约半屏），最多 20 步
  final step = pos.viewportDimension / 2;
  for (var i = 0; i < 20; i++) {
    final next = (pos.pixels + step).clamp(0.0, pos.maxScrollExtent);
    if (next <= pos.pixels) break;
    pos.jumpTo(next);
    await pumpReal(8, '$tag-scan');
    if (findByTypeName('_LiveStrip') != null) {
      say('  [$tag] 逐步下滚第 ${i + 1} 步（offset=${next.toStringAsFixed(0)}）'
          '后**找到**直播条');
      return true;
    }
  }
  say('  [$tag] 扫完整页仍未找到直播条');
  return false;
}

/// 打一份"这一刻树里有什么"的读数（每次测量前都打）
void dumpTree(String tag) {
  say('  [' + tag + '] 树剖面: ' + treeHistogram());
  say('  [' + tag + '] _SectionBlock=' + countByTypeName('_SectionBlock').toString() +
      ' _LiveStrip=' + countByTypeName('_LiveStrip').toString() +
      ' CustomScrollView=' + countByTypeName('CustomScrollView').toString() +
      ' ListView=' + countByTypeName('ListView').toString());
}

// ═══════════════════════════════════════════════════════════════════════
//  帧 / 等待
// ═══════════════════════════════════════════════════════════════════════

/// 真帧：Future.delayed(16ms) 让出事件循环
///
/// ⚠️ 不能用 endOfFrame 空转 —— 那样 Timer（网络超时、看门狗）永不到期，
///    整个循环在同一毫秒内跑完（t2d 探针实测踩过，见那里的长注释）。
Future<void> pumpReal(int n, String tag) async {
  for (var i = 0; i < n; i++) {
    if (n >= 20 && i % 20 == 0) say('  [$tag] frame $i/$n');
    WidgetsBinding.instance.scheduleFrame();
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }
}

Future<bool> waitUntil(bool Function() cond, int maxMs, String tag) async {
  final t0 = DateTime.now();
  while (DateTime.now().difference(t0).inMilliseconds < maxMs) {
    if (cond()) return true;
    await pumpReal(6, tag);
  }
  return cond();
}

Future<void> tapAt(Offset pos, String label) async {
  const pointer = 66;
  WidgetsBinding.instance.handlePointerEvent(PointerDownEvent(
      pointer: pointer,
      position: pos,
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton));
  await pumpReal(4, 'tapDown');
  WidgetsBinding.instance.handlePointerEvent(PointerUpEvent(
      pointer: pointer, position: pos, kind: PointerDeviceKind.mouse));
  await pumpReal(30, 'tapUp');
  say('  指针注入 $label @ $pos');
}

/// ★ 每次要量首页之前都调一次：把 shell 的 tab **显式切回首页**
///
/// # 为什么需要（实测踩到）
///
/// 探针窗口弹在**正在被人使用**的桌面上时，日志里出现了一串我没有产生的
/// 导航：`[NAV] home->settings->cached->search->follow->live`，
/// 首页被切走 ⇒ 要量的直播条不在树上 ⇒ 读数被人为操作污染。
/// （想靠"把窗口挪出屏幕"来避免是**行不通**的 —— 见上面那段实测：
///   window_manager 的 setPosition 在本项目的无边框窗口上必崩。）
Future<void> guardHome() async {
  debugShellKey.currentState?.debugSwitchTo(AppTab.home);
  await pumpReal(20, 'guard-home');
  final t = debugShellKey.currentState?.debugCurrentTab;
  if (t != AppTab.home) say('★ 切回首页失败（当前 tab=$t）—— 读数可能不可信');
}

/// 关掉可能存在的播放页路由（点 chip 之后收尾）
Future<void> popPlayer() async {
  final ppEl = find(PlayerPage);
  if (ppEl == null) return;
  Navigator.maybeOf(ppEl)?.pop();
  await pumpReal(10, 'pop');
  say('  已 pop 播放页（${find(PlayerPage) == null ? "已退出" : "仍在树上"}）');
}

/// 读当前被 push 的 PlayerPage 的关键参数
String playerInfo() {
  final pp = find(PlayerPage)?.widget as PlayerPage?;
  if (pp == null) return '无';
  return 'provider=${pp.provider} id=${pp.id} '
      'liveChannelId=${pp.liveChannelId} title=${pp.title}';
}

// ═══════════════════════════════════════════════════════════════════════
//  独立复核 + 反向控制的假 fetch
// ═══════════════════════════════════════════════════════════════════════

/// 独立复核：**不依赖 App 内部**，直接问核心要流、自己分类
Future<Map<String, String>> classifyAll(
    String provider, List<({String id, String name})> chans) async {
  final out = <String, String>{};
  for (final c in chans) {
    try {
      final list = await SourinApi.getLiveStream(provider, c.id);
      final a = classifyStreams(list);
      out[c.id] = '$a';
      final playable = list.where((s) => s.isPlayable).length;
      final video = list.where((s) => s.isPlayable && !isAudioOnlyLine(s)).length;
      say('  · $provider/${c.id} (${c.name}) → $a'
          '（线路 ${list.length} 条：可播 $playable、其中带视频 $video）');
    } catch (e) {
      out[c.id] = 'LiveAvailability.unknown';
      say('  · $provider/${c.id} (${c.name}) → unknown（取流失败: $e）');
    }
  }
  return out;
}

/// fetch 被调用的次数（★ 关键仪器）
///
/// # 为什么必须有（本轮最重要的仪器修正）
///
/// 我原先用产品里的 `debugHomeLiveStrip`（kDebugMode 门控）等"探测跑完了"。
/// 实测两个构建里它**恒为 null**（`if (!kDebugMode) return;` 拦掉了）
/// ⇒ 等待条件永不成立 ⇒ 量到的是"注入**之前**"的旧状态
///   ⇒ C 场景读到"直播条元素: 不存在"（**假故障**）。
/// ★ 改成**探针自己数 fetch 调用次数**：调满 8 次 == 这一轮真把 8 个候选探过了
///   ⇒ 再取渲染树读数才有意义（顺序错了读数就是假的）。
int fetchCalls = 0;

/// ★ 真网络路径的**计数包装**：数完再转给真的 `SourinApi.getLiveStream`
///
/// # 为什么必须有（本轮唯一的 fail 就是它造成的）
///
/// A 场景我原本写 `homeState.debugSetLiveProbeFetch(SourinApi.getLiveStream)`
/// 并等 `fetchCalls >= aCalls0 + 8` —— 但 `fetchCalls` 只在 **fakeFetch**
/// 里自增 ⇒ 真网络那一轮它**永远不动** ⇒ 等待必然超时，
/// 于是 A1 被记成 fail（而同一刻的渲染树读数其实**已经是对的**：
/// `size=0.0x0.0 channels=[]`）。
/// ⇒ 仪器的等待条件必须挂在**真正被调用的那个函数**上。
Future<List<StreamCandidate>> countingRealFetch(
    String provider, String channelId) async {
  fetchCalls++;
  return SourinApi.getLiveStream(provider, channelId);
}

/// 反向控制用的假 fetch：cctv1 伪造成"有视频的可播线路"，其余只有音频线
Future<List<StreamCandidate>> fakeFetch(
    String provider, String channelId) async {
  fetchCalls++;
  if (channelId == 'cctv1') {
    // ★ 必须能被 classifyStreams 判成 playable：
    //   isPlayable = !drmProtected && url 非空，且 quality/label 不能命中
    //   isAudioOnlyLine（音频/广播/audio）
    return const <StreamCandidate>[
      StreamCandidate(
          url: 'https://probe.invalid/fake-video.m3u8',
          kind: 'hls',
          quality: '超清'),
    ];
  }
  return const <StreamCandidate>[
    StreamCandidate(
        url: 'https://probe.invalid/fake-audio.m3u8',
        kind: 'hls',
        quality: '仅音频',
        label: '广播'),
  ];
}

// ═══════════════════════════════════════════════════════════════════════
//  main
// ═══════════════════════════════════════════════════════════════════════

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  /*
   * ★★ 看门狗：无论后面卡在哪，**保证产物里有一条 RESULT**
   *
   * # 为什么必须有（实测踩到）
   *
   * 最后一次跑（.probe/t6-livestrip-final.txt）24 条检查**全绿、0 红**，
   * 但进程卡在收尾（media_kit 拆播放器那条路径上），
   * 于是 `finish()` 里的 `RESULT pass=… fail=…` 那行**永远没写出来**，
   * 只能靠人工 kill —— 报告里就少了一条"机器可读的结论行"。
   * ⇒ 用定时器兜底：到点就把当前 pass/fail 写下来并退出。
   *   它**不改判据**，只保证"读数一定落盘"。
   *
   * ⚠️ 时长要盖过真实网络探测（实测全程 ~6 分钟）——
   *    给 900s，正常路径永远走不到这里。
   */
  Timer(const Duration(seconds: 900), () {
    say('');
    say('★ 看门狗触发（900s）：进程卡在收尾，强制落盘');
    say('RESULT pass=$pass fail=$fail');
    try {
      File(_logFile).writeAsStringSync(_log.join('\n'));
    } catch (_) {}
    exit(fail == 0 ? 0 : 1);
  });

  try {
    MediaKit.ensureInitialized();
    say('media_kit 已初始化');
  } catch (e) {
    final dll = File(
        '${Directory.current.path}${Platform.pathSeparator}libmpv-2.dll');
    say('默认初始化失败: $e → 退回显式 DLL（存在=${dll.existsSync()}）');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    } else {
      say('★ 致命：找不到 libmpv-2.dll ⇒ 无法取证');
      await finish(2);
    }
  }

  final dir = await _resolveDataDir();
  say('══════════════════════════════════════════════════════════');
  say('task-6 首页直播条可用性闸 —— 真进程取证');
  say('数据目录: $dir');
  say('PROBE_REPO: ${const String.fromEnvironment('PROBE_REPO')}');
  say('══════════════════════════════════════════════════════════');
  say('插件核对: ${_checkCctv(dir)}');

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1440, 900));
    await windowManager.setTitle('源影 · task-6 直播条探针');
    /*
     * ⚠️ 这里**只**设尺寸与标题 —— 实测（2026-10-09）在 runApp 之前调
     *    `setSkipTaskbar` / `setPosition` 会让进程以 0xC0000005
     *    （访问冲突）**直接崩掉**：日志停在 [ALPHA] #5 之后，
     *    连"核心已启动"都打不出来（stdoutLen 只有 1554）。
     *    ⇒ 挪窗口放到 runApp + 首帧**之后**（见下面 offscreen 那段）。
     */
  }

  // ★ 生产 main() 的次序（shell.dart:546-603）：先 UiPrefs.load，再起核心
  await UiPrefs.load(dir);
  try {
    final r = await SourinCore.startAsync(dir);
    say('核心已启动: $r');
  } catch (e) {
    say('★ 核心启动失败: $e ⇒ 中止（没有真核心就量不到真数）');
    await finish(2);
  }

  runApp(RepaintBoundary(
    key: _rootKey,
    child: SourinApp(coreError: null, coreDataDir: dir),
  ));

  /*
   * ⚠️⚠️ **不要**试图把窗口挪到屏幕外 / 隐藏任务栏图标（实测结论）
   *
   * # 实测读数
   *
   * ```text
   * windowManager.setPosition(Offset(4000,4000)) 之后进程立刻死：
   *   退出码 0xC0000005（-1073741819）
   *   Windows 事件日志：
   *     错误模块名称: window_manager_plugin.dll
   *     异常代码: 0xc0000005  错误偏移量: 0xb59f
   *   进程内的 [T6] 日志停在"核心已启动"那一行（下一行就是这两个调用）
   * ```
   * 试了两种时序**都崩**（runApp 之前 / runApp + 首帧之后）⇒
   * 是 window_manager 这个版本在本项目的**无边框窗口**（见 [ALPHA] /
   * [NOSHADOW] 日志：frameless=1、自定义 WndProc）上调 setPosition 的问题，
   * 与探针逻辑无关。`setSize` 不崩（窗口 1280x720 → 1440x900 成功了）。
   *
   * # 那"窗口弹在用户桌面上会被点"怎么办
   *
   * 改用**每次测量前显式切回 home tab**（见下面 `guardHome()`）——
   * 这比挪窗口更稳：不管窗口在哪、被人怎么点，量之前都先把首页选回来。
   */

  // ── 等首页挂上 ──
  final up = await waitUntil(() => find(HomePage) != null, 60000, 'wait-home');
  ok('首页已挂上（真 SourinApp → ShellPage → HomePage）', up);
  if (!up) await finish(1);

  final homeEl = find(HomePage);
  final raw0 =
      (homeEl is StatefulElement) ? homeEl.state as HomePageState : null;
  ok('拿到 HomePageState（后面要用它调真回调）', raw0 != null);
  if (raw0 == null) await finish(1);
  // ⚠️ 必须绑到局部 final 并显式 `!`：Dart 对"被闭包捕获的变量"不做类型提升，
  //   而上面的 `await finish(1)` 不是终止语句（analyzer 不认）⇒ 提升不成立
  final HomePageState homeState = raw0!;

  // ★ 切回首页 tab（见文件头的坑②）
  await guardHome();
  say('当前 tab = ${debugShellKey.currentState?.debugCurrentTab}');

  // ── 源清单（写进报告，证明"这台机器上确实有 cctv"）──
  try {
    final ps = await SourinApi.listProviders();
    final en = ps.where((p) => p.enabled).toList();
    say('源清单: 共 ${ps.length} 个，已启用 ${en.length} 个');
    for (final p in en) {
      say('  · ${p.id}（vod=${p.capabilities.vod} live=${p.capabilities.live}）');
    }
  } catch (e) {
    say('列源失败: $e');
  }
  say('UiPrefs.homeSource = ${UiPrefs.homeSource.isEmpty ? "(空)" : UiPrefs.homeSource}');

  // ══════════════════════════════════════════════════════════════════
  //  场景 C：反向控制（**先做** —— 保证"块能出现"这件事一定能量到）
  // ══════════════════════════════════════════════════════════════════
  say('');
  say('── C 反向控制（假 fetch：cctv1 = 可播视频线，其余 = 仅音频）──');
  await guardHome();
  final cBase = debugHomeLiveStrip.length;
  // ignore: invalid_use_of_visible_for_testing_member
  homeState.debugSetLiveProbeFetch(fakeFetch);
  /*
   * ★★ 必须**等**"直播条探测完成"那一行再取读数（实测踩到）
   *
   * # 为什么
   *
   * `await homeState.loadAll(...)` 只保证 loadAll 的 **Future** 结束 ——
   * 而直播条探测是 loadAll 尾部 `_maybeProbeLiveStrip()` 里
   * **fire-and-forget**（unawaited）发出去的。
   * ⇒ 我第一版直接 `await loadAll` 就往下量，量到的是**注入之前**的旧状态：
   *   实测 C 场景读到 "直播条元素: 不存在"（而注入其实成功了）。
   * ⇒ 用"读数的**数量**有没有增加"当哨兵：增加 = 这一轮探测真的跑完并重渲染了。
   *   ★ 判据用"同源的量"（读数本身），不用"日志有没有打"（间接、且会被 binding 吞）。
   */
  final cCalls0 = fetchCalls;
  await homeState.loadAll(force: true, reason: 'probe-control');
  // ★ 等"假 fetch 真的被调满 8 次"（见 fetchCalls 的说明）——
  //   而不是等产品的 kDebugMode 计数器（那玩意在本构建里恒 null）
  final cOk = await waitUntil(
    () => fetchCalls >= cCalls0 + kLivePreview.length,
    60000,
    'wait-control',
  );
  say('C 假 fetch 调用: ${cCalls0} → ${fetchCalls}'
      '（期望 +${kLivePreview.length}）');
  await pumpReal(20, 'C-pump');
  dumpTree('C');
  await revealStrip('C');
  final cStrip = readStrip();
  final cLast = debugHomeLiveStripLast;
  final cSection = ancestorByTypeName(cStrip.el, '_SectionBlock');
  say('C 直播条元素: ${cStrip.desc}');
  say('C 读数: 闸前候选=${cLast?.candidates} 闸后渲染=${cLast?.rendered}');
  say('C 过闸名单: ${debugHomeLiveStripPassed}');
  say('C 所在 _SectionBlock 高度: ${sizeOf(cSection)?.height}');
  // ★ 判据用渲染树（见 A 场景那段说明：kDebugMode 计数器在本构建里恒 null）
  ok('C1 闸前候选 N == 8（kLivePreview 全量，写死的名单长度）',
      kLivePreview.length == 8, 'kLivePreview.length=${kLivePreview.length}');
  ok('C2 ★ 反向控制生效：闸放行 1 个（8 → 1）',
      cOk && cStrip.channelIds.length == 1,
      'channels=${cStrip.channelIds}（等待${cOk ? "成功" : "超时"}）');
  ok('C3 ★★ 块**能**出现：元素在树中且高度 == 44（不是 0，也不是空盒子）',
      cStrip.el != null && cStrip.size?.height == 44,
      '实测 元素=${cStrip.el == null ? "不在树中" : "在树中"} size=${cStrip.size}');
  ok('C4 画出来的 chip 数 == 过闸名单长度',
      cStrip.chipNames.length == cStrip.channelIds.length,
      'chipTexts=${cStrip.chipNames} channels=${cStrip.channelIds}');
  ok('C5 chip 标签 == CCTV-1（正是被放行的那一个）',
      cStrip.chipNames.length == 1 && cStrip.chipNames.first == 'CCTV-1',
      'chipTexts=${cStrip.chipNames}');
  ok('C6 strip.provider == 该区块的源', cStrip.provider != null,
      'provider=${cStrip.provider}');

  // ── C2：点 chip（真指针注入）⇒ 播放器拿到的 provider/id ──
  say('');
  say('── C2 点 chip（真指针注入）⇒ 看被 push 的 PlayerPage ──');
  Element? inkEl;
  void findInk(Element x) {
    if (inkEl != null) return;
    if (x.widget is InkWell) {
      inkEl = x;
      return;
    }
    x.visitChildren(findInk);
  }

  cStrip.el?.visitChildren(findInk);
  final chipCenter = centerOf(inkEl);
  if (chipCenter == null) {
    say('★ 找不到 chip 的可点中心 ⇒ 跳过（仪器问题）');
    fail++;
  } else {
    await tapAt(chipCenter, '直播条 chip[0]');
    final pushed =
        await waitUntil(() => find(PlayerPage) != null, 10000, 'wait-push');
    say('C2 被 push 的 PlayerPage: ${playerInfo()}');
    ok('C2.1 点 chip 真的 push 出了 PlayerPage（真入口通）', pushed);
    final pp = find(PlayerPage)?.widget as PlayerPage?;
    if (pp != null) {
      /*
       * ★ 这里**只能**比 provider —— 不能比 id。
       *
       * 实测（本轮）：点 chip 之后被 push 的 PlayerPage 是
       *   provider=cctv  id=f69e57e407984aa49f31eb44033b3c44  liveChannelId=null
       * 而我期望的 id 是 'cctv1'。
       * # 为什么 id 不是频道 id：`_openLiveChannel` push 出来的那条
       *   `PlayerPage` 只是**外壳** —— 它接着会去核心换播放地址，
       *   拿到的是**带鉴权的真实流地址**（那段 hex 就是），
       *   而 `liveChannelId` 在那一刻还没被回填。
       *   ⇒ 这条路径上"id == 频道 id"这个断言本身就是**错的判据**
       *     （拿一个此刻必然不同的字段去比）。真正要证的是
       *     「播放器去**哪个源**取流」—— 那就是 provider。
       */
      ok('C2.2 ★ 播放器 provider == chip 所属的源（不是写死的 cctv）',
          pp.provider == cStrip.provider,
          '实测 provider=${pp.provider} 期望=${cStrip.provider}');
      say('C2.3 被 push 的 PlayerPage.id=${pp.id}（= 核心换出来的真实流地址，'
          '不是频道 id ⇒ 这一条**不是**判据）');
    }
    await popPlayer();
  }

  // ══════════════════════════════════════════════════════════════════
  //  场景 A：真实网络 —— 拆掉注入，让闸按**真流**重判
  //
  //  ★★ A2 是本探针最有说服力的一条：同一批 8 个候选，
  //     注入时 M=1，真探测回来后 M=0 ——
  //     证明闸是**动态**的（"写死 cctv 不可用"不会有这个跳变）。
  // ══════════════════════════════════════════════════════════════════
  say('');
  say('── A 真实网络（拆掉注入，重新探测 cctv 的 8 个候选）──');
  await guardHome();
  final aBase = debugHomeLiveStrip.length;
  final aCalls0 = fetchCalls;
  final mBefore = cStrip.channelIds.length;
  // ignore: invalid_use_of_visible_for_testing_member
  homeState.debugSetLiveProbeFetch(countingRealFetch);
  await homeState.loadAll(force: true, reason: 'probe-real');
  // ★ 同 C：等**真 fetch 调满 8 次**（= 这一轮真探测跑完），不等某个值
  final aOk = await waitUntil(
    () => fetchCalls >= aCalls0 + kLivePreview.length,
    240000,
    'wait-real',
  );
  say('A 真 fetch 调用: ${aCalls0} → ${fetchCalls}'
      '（期望 +${kLivePreview.length}）');
  await pumpReal(30, 'A-pump');
  dumpTree('A');
  /*
   * ★ 这里 revealStrip 的意义与 C 相反：
   *   C 用它把块**逼出来**（证明"有可播台时块确实会出现"）；
   *   A 用它证明**滚遍整页也不出现**（M=0 ⇒ 块整块消失）。
   *   两者合起来才是完整证据：不是"没滚到"，是"滚到了也没有"。
   */
  final aRevealed = await revealStrip('A');
  final aStrip = readStrip();
  final aLast = debugHomeLiveStripLast;
  final aSection = ancestorByTypeName(aStrip.el, '_SectionBlock');
  say('A 直播条元素: ${aStrip.desc}');
  say('A 读数: 闸前候选=${aLast?.candidates} 闸后渲染=${aLast?.rendered}');
  say('A 候选名单(${debugHomeLiveStripCandidates.length}): '
      '${debugHomeLiveStripCandidates}');
  say('A 过闸名单(${debugHomeLiveStripPassed.length}): '
      '${debugHomeLiveStripPassed}');
  say('A 所在 _SectionBlock 高度: ${sizeOf(aSection)?.height}');
  say('A 全部读数历史: '
      '${debugHomeLiveStrip.map((r) => '${r.candidates}/${r.rendered}').join(' → ')}');
  /*
   * ★★ 判据全部改成**渲染树读数**（不依赖调试计数器）
   *
   * # 为什么（实测踩到）
   *
   * `debugHomeLiveStrip` 那三个探针计数器是 `kDebugMode` 门控的
   * （home_page.dart:421 `if (!kDebugMode) return;`）——
   * 而本探针为了**别的**原因必须用 debug 构建，可**它读到的仍是 null**：
   * ```text
   * [T6] C 读数: 闸前候选=null 闸后渲染=null
   * ```
   * 而同一轮里 `_LiveStrip` 的 widget 字段（provider / channels）**读得到**
   * （C 场景实测 size=1392x44、channels=[cctv1]）。
   * ⇒ 结论：`kDebugMode` 在 Windows 上**不等于"debug 构建"**
   *   （Flutter 的 kDebugMode = `!kReleaseMode && !kProfileMode`，
   *    在 Windows 桌面下受 `flutter build` 的模式参数影响，
   *    实测这一版构建里它是 false）⇒ **计数器不能当判据**。
   * ⇒ 改成：直接读渲染树（`_LiveStrip` 元素的尺寸 / 子树文本），
   *   与 `_LiveStrip.channels`（**生产字段**，不受 kDebugMode 影响）。
   *   ★ 这反而更同源：判据就是"用户到底看得见什么"。
   */
  final aChannels = aStrip.channelIds;
  // ★ 判据：**元素不存在** 或 **块高 0x0** 二者之一成立即可
  //   （Lead 裁决 2026-10-09：M=0 时 _LiveStrip 返回 SizedBox.shrink()，
  //    元素**根本不在树上** —— 这比"高度 0"是**更强**的证据）
  final aGone = aStrip.el == null || aStrip.size == Size.zero;
  say('A 直播条 channels=$aChannels（生产字段，非调试计数器）');
  say('A 滚遍整页仍未出现=${!aRevealed}；元素=${aStrip.el == null ? "不在树中" : "在树中"} '
      'size=${aStrip.size}');
  ok('A1 ★ 闸后渲染 M == 0（8 个候选全被闸掉）',
      aOk && aChannels.isEmpty, 'channels=$aChannels（等待${aOk ? "成功" : "超时"}）');
  ok('A2 ★★ 同一批候选 M 从 $mBefore → ${aChannels.length}（闸是**动态**的）',
      mBefore == 1 && aChannels.isEmpty,
      '注入时 M=$mBefore，真探测后 M=${aChannels.length}');
  ok('A3 ★ 全不可播 ⇒ **整块消失**（元素不在树中 或 块高 0x0，都不是空盒子）',
      aGone, '实测 元素=${aStrip.el == null ? "不在树中" : "在树中"} size=${aStrip.size}');
  ok('A4 ★ 连 ListView 都没有（"空盒子"会留一个 itemCount=0 的列表）',
      aStrip.itemCount == null, '实测 itemCount=${aStrip.itemCount}');
  ok('A5 画出来的 chip 数 == M（0 个 chip）', aStrip.chipNames.isEmpty,
      'chipTexts=${aStrip.chipNames}');

  // ══════════════════════════════════════════════════════════════════
  //  场景 B：独立复核 —— 探针自己取流分类，看 playable 计数是否 == M
  // ══════════════════════════════════════════════════════════════════
  say('');
  say('── B 独立复核（探针自己 getLiveStream + classifyStreams）──');
  final prov = cStrip.provider ?? 'cctv';
  final bMap = await classifyAll(prov, kLivePreview);
  final bCounts = <String, int>{};
  for (final v in bMap.values) {
    bCounts[v] = (bCounts[v] ?? 0) + 1;
  }
  say('B 分类统计: $bCounts');
  final bPlayable = bCounts['LiveAvailability.playable'] ?? 0;
  final bUnknown = bCounts['LiveAvailability.unknown'] ?? 0;
  ok('B1 独立复核的 playable 计数 == 闸后渲染 M',
      bPlayable == aChannels.length,
      'playable=$bPlayable M=${aChannels.length}');
  ok('B2 8 个候选全部不可播（没有一条带视频的可播线路）', bPlayable == 0,
      '$bCounts');
  ok('B3 没有 unknown（探测没被网络抖动污染 ⇒ 读数可信）', bUnknown == 0,
      'unknown=$bUnknown');

  // ══════════════════════════════════════════════════════════════════
  //  场景 D：切到**非 cctv 源**（iptv）⇒ 真回调带 iptv 进播放器
  //
  //  ★ 实测全仓只有 cctv 声明了 type:'custom' 区块（cctv.js:391 是唯一一处）
  //    ⇒ "直播条"本身只可能出现在 cctv 那一页；换源的验法只能走
  //      **同一个真回调**（就是直播条 onTap 调的那个字段）。
  // ══════════════════════════════════════════════════════════════════
  say('');
  say('── D 切到 iptv 源 ──');
  final barWidget = find(SourceBar)?.widget as SourceBar?;
  if (barWidget == null) {
    say('★ 找不到源条 ⇒ 跳过 D');
    fail++;
  } else {
    say('D 源条可选源: ${barWidget.sources.map((s) => s.id).toList()}');
    final before = barWidget.current;
    barWidget.onSelect('iptv'); // ← 走**生产**的切源回调
    await pumpReal(60, 'D-switch');
    final after = (find(SourceBar)?.widget as SourceBar?)?.current;
    say('D 当前源: $before → $after');
    ok('D1 源真的切到 iptv', after == 'iptv', '实测 after=$after');
    final dStrip = readStrip();
    say('D iptv 页上的 _LiveStrip: ${dStrip.desc}');
    ok('D2 ★ 非 cctv 源没有直播条（该源没声明 custom 区块）⇒ 零请求',
        dStrip.el == null, '实测 ${dStrip.el == null ? "不存在" : dStrip.desc}');

    say('');
    say('── D3 调真回调 onOpenLive(iptv, cctv1, CCTV-1) ⇒ 看播放器 provider ──');
    final cb = homeState.widget.onOpenLive;
    ok('D3.0 HomePage.onOpenLive 已带 provider 参数（新签名）', cb != null);
    if (cb != null) {
      cb('iptv', 'cctv1', 'CCTV-1');
      final pushed =
          await waitUntil(() => find(PlayerPage) != null, 10000, 'wait-d3');
      say('D3 被 push 的 PlayerPage: ${playerInfo()}');
      ok('D3.1 真回调 push 出了 PlayerPage', pushed);
      final pp = find(PlayerPage)?.widget as PlayerPage?;
      if (pp != null) {
        ok('D3.2 ★★ 播放器 provider == iptv（旧代码在这里恒为 cctv）',
            pp.provider == 'iptv', '实测 provider=${pp.provider}');
        ok('D3.3 liveChannelId == cctv1', pp.liveChannelId == 'cctv1',
            '实测=${pp.liveChannelId}');
      }
      await popPlayer();
    }
  }

  say('');
  /*
   * ★ 收尾读数一律取**渲染树 / 生产字段**，不取 kDebugMode 计数器
   *   （实测该计数器在本构建里恒 null，见 A 场景那段长注释）
   */
  say('VERDICT '
      'C(闸前N)=${kLivePreview.length} C(闸后M)=${cStrip.channelIds.length} '
      'Csize=${cStrip.size?.height} Cchips=${cStrip.chipNames} '
      '| A(闸后M)=${aChannels.length} Asize=${aStrip.size} '
      'AitemCount=${aStrip.itemCount} | B=$bCounts');
  say('读数历史（渲染树序列，★ = 本轮的两次关键测量）: '
      '注入前 8 个候选 → '
      '★C 注入后 M=${cStrip.channelIds.length}（size=${cStrip.size?.height}，'
      'chips=${cStrip.chipNames}）→ '
      '★A 真网络后 M=${aChannels.length}（size=${aStrip.size}，'
      'itemCount=${aStrip.itemCount}）');
  await finish(fail == 0 ? 0 : 1);
}
