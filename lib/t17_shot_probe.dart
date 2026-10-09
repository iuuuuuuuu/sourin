// ═══════════════════════════════════════════════════════════════════════
//  task-17 ① 真机截图探针：把**真缓存页**画出来，证明 Owner 的目录有真封面
//
// # 为什么还要一个截图探针（真机读数已经有了）
// ```text
// t17_cover_probe 证的是"数据层找到了 cover"（pass=11）。
// 但 Owner 的诉求是**看得见**的封面 —— 数据对 ≠ 画出来了。
// ⇒ 这里把真 CachePage 挂进真树，扫真目录，然后截屏。
// ```
//
// ⚠️ 判据（两级，缺一不可）：
// ```text
// ① 状态读数：works[0].cover 非空 + 卡片树里真的有 Image widget（不是占位）
// ② 像素读数：截屏非空且不是纯灰（有封面的卡片与灰底占位在像素上必然不同）
// ```
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:sourin_spike/core/ffi.dart' show SourinCore;
import 'package:sourin_spike/ui/cache_page.dart';

final List<String> _lines = <String>[];
void say(String s) {
  debugPrint('[T17S] $s');
  _lines.add(s);
}

int _pass = 0;
int _fail = 0;
void ok(String name, bool cond, [String extra = '']) {
  final tail = extra.isEmpty ? '' : '  $extra';
  if (cond) {
    _pass++;
    say('✓ $name$tail');
  } else {
    _fail++;
    say('✗ $name$tail');
  }
}

/// 数出树里所有 Image widget（= 真封面被画出来的硬证据）
int _countImages(Element root) {
  var n = 0;
  void walk(Element e) {
    if (e.widget is Image) n++;
    e.visitChildren(walk);
  }
  walk(root);
  return n;
}

/// 数出「首字占位」的个数（= 降级路径的证据）
int _countPlaceholders(Element root) {
  var n = 0;
  void walk(Element e) {
    final s = e.widget.toString();
    if (s.contains('_InitialPlaceholder') || s.contains('InitialPlaceholder')) n++;
    e.visitChildren(walk);
  }
  walk(root);
  return n;
}

final GlobalKey _rootKey = GlobalKey();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final dataDir = Platform.environment['T17_DATA_DIR'];
  final out = Platform.environment['T17_OUT'];
  if (dataDir == null || dataDir.isEmpty) {
    say('★ 必须给 T17_DATA_DIR');
    _flush(out);
    return;
  }
  say('数据目录: $dataDir');

  final boot = await SourinCore.startAsync(dataDir);
  say('核心已启动: $boot');
  ok('★ 前置条件：核心起来了', boot['ok'] == true, '$boot');

  // ★ 扫**真的**下载根（Owner 那个无旁文件的目录）
  const realRoot = 'C:\\Users\\iuuuuuuuu\\Videos\\源影';
  CachePage.debugScanRootOverride = realRoot;
  say('扫描根（注入）: $realRoot');

  // ── 先看数据层（同 t17_cover_probe 的判据）──
  debugClearCacheMetaMemo();
  final works = await scanCacheWorks(realRoot);
  say('扫到 ${works.length} 部作品');
  for (final w in works) {
    say('  · 「${w.dirName}」 cover=${w.cover} provider=${w.provider}');
  }
  ok('★★ 数据层：Owner 目录拿到真封面',
      works.isNotEmpty && (works.first.cover ?? '').trim().isNotEmpty,
      works.isEmpty ? 'no works' : 'cover=${works.first.cover}');

  // ── 把真 CachePage 挂进真树 ──
  const page = CachePage();
  runApp(
    WidgetsApp(
      color: const Color(0xFF101014),
      builder: (c, child) => MediaQuery(
        data: const MediaQueryData(size: Size(1440, 900)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: KeyedSubtree(key: _rootKey, child: page),
        ),
      ),
    ),
  );

  // 等页面扫盘 + 首帧
  for (var i = 0; i < 90; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final el = _rootKey.currentContext as Element?;
    if (el != null && _countImages(el) > 0) break;
  }
  await Future<void>.delayed(const Duration(seconds: 2));

  final rootEl = _rootKey.currentContext as Element?;
  ok('★ 前置条件：CachePage 挂上了', rootEl != null, '$rootEl');
  if (rootEl != null) {
    final imgs = _countImages(rootEl);
    final phs = _countPlaceholders(rootEl);
    say('树读数: Image 个数=$imgs  首字占位个数=$phs');
    ok('★★★ 主判据：卡片里**真的画出了 Image**（真封面，不是占位）',
        imgs > 0, 'Image=$imgs');
  }

  // ── 截图 ──
  say('');
  say('（截图由外层脚本用 PrintWindow 抓，见 .probe/t17_shot.ps1）');

  // 保持窗口存活，等外层截图
  say('WAITING_FOR_SHOT');
  await Future<void>.delayed(const Duration(seconds: 25));
  say('RESULT pass=$_pass fail=$_fail');
  _flush(out);
  await Future<void>.delayed(const Duration(seconds: 2));
  exit(0);
}

void _flush(String? out) {
  if (out == null || out.isEmpty) return;
  try {
    File(out).writeAsStringSync(_lines.join('\n'));
  } catch (e) {
    debugPrint('[T17S] 写产物失败: $e');
  }
}
