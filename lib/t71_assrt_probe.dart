// t71 探针入口：给 task-29⑤「射手字幕 assrt.net 接入」出截图证据。
//
// 用法（桌面）：
//   flutter build windows --release -t lib/t71_assrt_probe.dart \
//     --dart-define=DATA_DIR_OVERRIDE=D:\...\_probe_data
//   .\build\windows\x64\runner\Release\sourin_spike.exe
//
// 这个文件只 import 本任务新增的文件 + material_ui，不 import 播放页，也不碰任何既有文件。
// 自动化：打开后自动「搜索 -> 按面板顺序逐个试下载直到成功 -> 挂到当前播放」，每步留可见时间。
//   --dart-define=PROBE_AUTO=0 关掉自动化，改手动点。
//
// ★ 关键词为什么是「进击的巨人」：实测「火影」15/15 条都是 rar（本实现明确不支持 rar），
//   用它做演示面板里只会是报错框。「进击的巨人」15 条里 14 条非 rar。
// ★ 面板会按语言偏好重排结果，所以探针不假设「第几条能下载」——它按顺序逐条试，
//   把每条的结果都打进 [PROBE] 日志（哪条成功、哪条是 rar 被拒），截图里也看得到。
// ★ --dart-define=PROBE_RAR=true 只试 rar 那几条，**故意**把「不支持 rar」的报错框截下来。
//   ⚠️ 必须写 true（不是 1）：bool.fromEnvironment('PROBE_RAR', ...) 解析的是
//   bool.parse 语义，'1' 不是合法 bool ⇒ 会静默取默认值 false（实测踩过）。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import 'core/assrt/archive.dart';
import 'core/assrt/assrt_api.dart';
import 'core/assrt/subtitle_store.dart';
import 'ui/subtitle/subtitle_panel.dart';

const bool kProbeAuto = bool.fromEnvironment('PROBE_AUTO', defaultValue: true);
const bool kProbeRar = bool.fromEnvironment('PROBE_RAR', defaultValue: false);
const String kProbeKeyword = '进击的巨人';
// 自绘截图输出目录（构建时 --dart-define=SHOT_DIR=... 指定；缺省写当前工作目录下 probe_shots）
const String kProbeShotDir =
    String.fromEnvironment('SHOT_DIR', defaultValue: 'probe_shots');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _ProbeApp());
}

// ── 探针日志（同时打到 stdout 与屏幕，截图里也能看到读数） ────────────────
final List<String> _probeLogLines = <String>[];
final List<String> _probeTexts = <String>[];
final List<Element> _probeButtons = <Element>[];

// 让屏幕上的日志框跟着刷新（_plog 是顶层函数，拿不到 State）
VoidCallback? _probeRepaint;

void _plog(String s) {
  final line = '${DateTime.now().toIso8601String().substring(11, 19)} $s';
  _probeLogLines.add(line);
  if (_probeLogLines.length > 60) _probeLogLines.removeAt(0);
  _probeRepaint?.call();
  // ignore: avoid_print
  print('[PROBE] $line');
}

class _ProbeApp extends StatelessWidget {
  const _ProbeApp();
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 't71 assrt probe',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const _ProbeHome(),
    );
  }
}

class _ProbeHome extends StatefulWidget {
  const _ProbeHome();
  @override
  State<_ProbeHome> createState() => _ProbeHomeState();
}

class _ProbeHomeState extends State<_ProbeHome> {
  bool _open = true;
  String _mounted = '（还没挂载）';
  String _mountedName = '';
  String _mountedBytes = '';
  bool _drove = false;
  Timer? _tick;
  final GlobalKey _shotKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // ★ 关键：面板自己的状态变化**不会**重建本页，所以不能只在 build 里收集 ——
    //   必须用定时器持续刷新「当前屏幕上有哪些文字/按钮」，否则永远看到的是第一帧。
    _probeRepaint = () {
      if (mounted) setState(() {});
    };
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) => _collect());
    if (kProbeAuto) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _drive());
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _probeRepaint = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF101216),
      body: RepaintBoundary(
        key: _shotKey,
        child: Stack(
          children: <Widget>[
          Positioned(
            left: 4,
            top: 6,
            width: 264,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('t71 字幕面板探针',
                    style: TextStyle(fontSize: 15, color: Colors.white)),
                const SizedBox(height: 4),
                Text(
                    _mountedName.isEmpty
                        ? '已挂载：$_mounted'
                        : '已挂载：$_mountedName（$_mountedBytes）',
                    key: const Key('probe_mounted'),
                    style: const TextStyle(fontSize: 11, color: Colors.amber)),
                const SizedBox(height: 6),
                FilledButton(
                  key: const Key('probe_open'),
                  onPressed: () => setState(() => _open = true),
                  child: const Text('打开字幕面板'),
                ),
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  height: 420,
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.85),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      _probeLogLines.isEmpty ? '（等待）' : _probeLogLines.join('\n'),
                      key: const Key('probe_log'),
                      style: const TextStyle(
                          fontSize: 10,
                          height: 1.3,
                          fontFamily: 'monospace',
                          color: Colors.lightGreenAccent),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_open)
            SubtitlePanel(
              key: const Key('probe_panel'),
              videoTitle: '探针视频 第一季',
              episodeTitle: '第1集',
              videoUrl: 'http://127.0.0.1:1/probe.m3u8',
              initialKeyword: kProbeKeyword,
              onClose: () => setState(() => _open = false),
              onMount: (SubtitleFileRef f) {
                setState(() {
                  _mounted = f.path;
                  _mountedName = f.name;
                  _mountedBytes = '${f.bytes} B';
                  _open = false;
                });
                _plog('ONMOUNT 面板回调收到 name=${f.name} bytes=${f.bytes}');
              },
            ),
          ],
        ),
      ),
    );
  }

  // ── 每 250ms 刷新一次「屏幕上有什么」 ──────────────────────────────
  void _collect() {
    if (!mounted) return;
    final panel = _findFirst(context, (w) => w is SubtitlePanel);
    _probeTexts.clear();
    _probeButtons.clear();
    if (panel == null) return;
    _walk(panel);
  }

  Element? _findFirst(BuildContext ctx, bool Function(Widget) test) {
    Element? found;
    void visit(Element e) {
      if (found != null) return;
      if (test(e.widget)) {
        found = e;
        return;
      }
      e.visitChildren(visit);
    }
    (ctx as Element).visitChildren(visit);
    return found;
  }

  void _walk(Element e) {
    final w = e.widget;
    if (w is Text && w.data != null) _probeTexts.add(w.data!);
    // ★ 面板的报错框用的是 SelectableText（可复制），不是 Text ——
    //   只收 Text 会漏掉所有错误文案，把「1 秒就报错」记成「40 秒无终态」。
    if (w is SelectableText && w.data != null) _probeTexts.add(w.data!);
    if (w is FilledButton || w is TextButton || w is IconButton) {
      _probeButtons.add(e);
    }
    e.visitChildren(_walk);
  }

  String? _labelOf(Widget w) {
    if (w is FilledButton) {
      final c = w.child;
      if (c is Text) return c.data;
    }
    if (w is TextButton) {
      final c = w.child;
      if (c is Text) return c.data;
    }
    if (w is IconButton) return w.tooltip;
    return null;
  }

  VoidCallback? _cbOf(Widget w) {
    if (w is FilledButton) return w.onPressed;
    if (w is TextButton) return w.onPressed;
    if (w is IconButton) return w.onPressed;
    return null;
  }

  // 从按钮往上找到最近的 Row，把 Row 里那个「短 ASCII 串」取出来 —— 就是结果行右侧的扩展名提示。
  String _rowHint(Element e) {
    Element? row;
    e.visitAncestorElements((Element a) {
      if (a.widget is Row) {
        row = a;
        return false;
      }
      return true;
    });
    final r = row;
    if (r == null) return '';
    var found = '';
    void visit(Element x) {
      final w = x.widget;
      final d = w is Text ? w.data : null;
      if (d != null && RegExp(r'^[A-Za-z0-9]{1,6}$').hasMatch(d)) found = d;
      x.visitChildren(visit);
    }
    r.visitChildren(visit);
    return found;
  }

  List<Element> _buttons(String label) {
    final out = <Element>[];
    for (final e in List<Element>.of(_probeButtons)) {
      if (_cbOf(e.widget) == null) continue;
      if (_labelOf(e.widget) != label) continue;
      out.add(e);
    }
    return out;
  }

  Future<bool> _call(String label, {int waitMs = 1500}) async {
    for (var i = 0; i < 40; i++) {
      final hits = _buttons(label);
      if (hits.isNotEmpty) {
        _plog('CALL 面板按钮「$label」');
        _cbOf(hits.first.widget)!();
        await Future<void>.delayed(Duration(milliseconds: waitMs));
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    _plog('MISS 找不到可用按钮「$label」');
    return false;
  }

  bool _hasText(String needle) => _probeTexts.any((t) => t.contains(needle));

  Future<bool> _waitText(String needle, {int tries = 80, int gapMs = 250}) async {
    for (var i = 0; i < tries; i++) {
      await Future<void>.delayed(Duration(milliseconds: gapMs));
      if (_hasText(needle)) {
        _plog('SEEN 「$needle」');
        return true;
      }
    }
    _plog('TIMEOUT 等不到「$needle」');
    return false;
  }

  static const List<String> _kTerminal = <String>[
    '原始格式',
    '不支持',
    // ★ rar 分支的报错文案是「这个版本的字幕打包成了 rar4」——
    //   首轮漏了这个词，导致明明 1 秒内就报错，却被记成「40 秒无终态」。
    '打包成了',
    '失效',
    '认不出',
    '没有 .srt',
    '下载失败',
  ];

  bool get _busy => _hasText('处理中') || _hasText('正在下载') || _hasText('正在读取详情');

  // 按面板顺序逐条点「下载」，直到有一条成功（或全部试完）。
  // ★ 用「第几个下载按钮」当身份（列表索引），因为面板重排/插入错误框后 Element 会重建。
  Future<String> _downloadFirstWorking({int maxAttempts = 6}) async {
    final tried = <int>{};
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      Element? target;
      var idx = -1;
      for (var i = 0; i < 80; i++) {
        if (!_busy) {
          final list = _buttons('下载');
          for (var k = 0; k < list.length; k++) {
            if (tried.contains(k)) continue;
            // rar 模式：跳过非 rar 行，故意去踩「不支持 rar」那条分支
            if (kProbeRar && _rowHint(list[k]) != 'rar') {
              tried.add(k);
              continue;
            }
            target = list[k];
            idx = k;
            break;
          }
        }
        if (target != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (target == null) {
        _plog('MISS 没有更多可点的「下载」按钮（已试 ${tried.length} 条，当前可见 ${_buttons('下载').length} 条）');
        return 'none';
      }
      tried.add(idx);
      final hint = _rowHint(target);
      _plog('CALL 第 $idx 行「下载」（ext=${hint.isEmpty ? '?' : hint}，已试 ${tried.length}/${_buttons('下载').length}）');
      _cbOf(target.widget)!();
      // 等一个终态：成功是「原始格式」，失败是各种错误文案
      var hit = '';
      for (var i = 0; i < 160 && hit.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        for (final t in _kTerminal) {
          if (_hasText(t)) {
            hit = t;
            break;
          }
        }
      }
      if (hit == '原始格式') {
        _plog('OK 第 $idx 行能走通（ext=${hint.isEmpty ? '?' : hint}）');
        return hint;
      }
      if (kProbeRar) {
        // rar 模式只要这一条读数：面板到底怎么报的
        final dump = _probeTexts
            .where((t) => t.contains('压缩包') || t.contains('失败') || t.contains('不支持'))
            .take(2)
            .map((t) => t.length > 120 ? t.substring(0, 120) : t)
            .join(' | ');
        _plog('RAR-REJECT 第 $idx 行读数=${hit.isEmpty ? '40 秒无终态' : hit}');
        _plog('RAR-REJECT 现场文案=${dump.isEmpty ? '（没有含「压缩包/失败/不支持」的文案）' : dump}');
        return 'rarreject';
      }
      if (hit.isEmpty) {
        _plog('TIMEOUT 第 $idx 行 40 秒没出结果，换下一条');
      } else {
        _plog('REJECT 第 $idx 行被拒（命中「$hit」），换下一条');
      }
    }
    return 'exhausted';
  }

  // ★ 自绘截图：把本页真实的 widget 树渲染成 PNG 落盘。
  //   为什么需要它：取证时本机处于**锁屏**，屏幕像素（CopyFromScreen）和
  //   PrintWindow(PW_RENDERFULLCONTENT) 都只能拿到纯黑 —— 这两条路都走不通。
  //   toImage 是 Flutter 自己把 layer 树重新光栅化，不受窗口遮挡影响。
  //   ⚠️ 它是**应用自绘渲染**，不是屏幕像素；报告里必须如实标注。
  Future<void> _saveShot(String name) async {
    try {
      final ctx = _shotKey.currentContext;
      if (ctx == null) {
        _plog('SHOT $name FAIL 拿不到 RepaintBoundary 的 context');
        return;
      }
      final ro = ctx.findRenderObject();
      if (ro is! RenderRepaintBoundary) {
        _plog('SHOT $name FAIL renderObject=${ro.runtimeType}');
        return;
      }
      final dpr = MediaQuery.of(ctx).devicePixelRatio;
      ui.Image? img;
      for (var i = 0; i < 20 && img == null; i++) {
        try {
          img = await ro.toImage(pixelRatio: dpr);
        } catch (e) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
      if (img == null) {
        _plog('SHOT $name FAIL toImage 一直失败');
        return;
      }
      final bd = await img.toByteData(format: ui.ImageByteFormat.png);
      final w = img.width;
      final h = img.height;
      img.dispose();
      if (bd == null) {
        _plog('SHOT $name FAIL toByteData=null');
        return;
      }
      final bytes = Uint8List.view(bd.buffer);
      final dir = Directory(kProbeShotDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final f = File('${dir.path}${Platform.pathSeparator}$name.png');
      f.writeAsBytesSync(bytes, flush: true);
      _plog('SHOT $name OK ${bytes.length} B $w x $h dpr=$dpr -> ${f.path}');
    } catch (e) {
      _plog('SHOT $name FAIL $e');
    }
  }

  Future<void> _drive() async {
    if (_drove) return;
    _drove = true;
    _plog('START 自动探针 keyword=$kProbeKeyword rar模式=$kProbeRar');
    final root = await SubtitleStore.root();
    _plog('dataDir=$root');
    _plog('base=$kAssrtBase  存储=<dataDir>/subtitles/<videoKey>/');
    await Future<void>.delayed(const Duration(milliseconds: 800));
    _plog('步骤1 点「搜索」');
    await _call('搜索', waitMs: 800);
    final ok = await _waitText('找到', tries: 120, gapMs: 250);
    if (!ok) {
      _plog('步骤1 FAIL 搜索结果没出现');
      return;
    }
    _plog('步骤1 OK 结果列表已出现，停 10 秒给截图');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await _saveShot('s1_results');
    await Future<void>.delayed(const Duration(seconds: 10));
    _plog('步骤2 逐条试「下载」');
    final used = await _downloadFirstWorking();
    if (used == 'rarreject') {
      _plog('步骤2 RAR 分支已取证（面板上的报错就是证据），停 12 秒给截图');
      await _saveShot('s2_rar_unsupported');
      await Future<void>.delayed(const Duration(seconds: 12));
      _plog('DONE 只拿到「不支持」分支的截图');
      await Future<void>.delayed(const Duration(seconds: 40));
      exit(0);
    }
    if (used == 'none' || used == 'exhausted') {
      _plog('步骤2 FAIL 前几条都不行，最后一条的报错留在面板上，停 10 秒给截图');
      await _saveShot('s2_fail');
      await Future<void>.delayed(const Duration(seconds: 10));
      _plog('DONE 只拿到「不支持」分支的截图');
      await Future<void>.delayed(const Duration(seconds: 60));
      exit(0);
    }
    _plog('步骤2 OK 已保存字幕，停 15 秒给截图');
    await _saveShot('s2_saved');
    await Future<void>.delayed(const Duration(seconds: 15));
    _plog('步骤3 点「挂到当前播放」');
    await _call('挂到当前播放', waitMs: 2000);
    _plog('步骤3 ${_mountedName.isEmpty ? "FAIL 挂载回调没触发" : "OK 挂载回调已触发"}');
    await _saveShot('s3_mounted');
    _plog('DONE 探针结束（面板已关闭，挂载路径在左上角，日志在左下）');
    await Future<void>.delayed(const Duration(seconds: 60));
    exit(0);
  }
}

// 让 analyzer 知道 archive.dart 的符号确实被用到（探针里做一次自检）
String probeSelfCheck() {
  final kind = sniffKind(const <int>[0x50, 0x4B, 0x03, 0x04]);
  return kind.name;
}
