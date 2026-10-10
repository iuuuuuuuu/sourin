// ═══════════════════════════════════════════════════════════════════════
//  task-17 ① 真机探针：用**真库 + 真磁盘目录**证明封面能找回来
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须真机（widget/unit 测试证不了）
// ```text
// flutter_test 里**加载不了 sourin_core.dll**（error 126）⇒ SourinApi.listHistory()
//   必然抛 ⇒ 我的 _lookupMeta 走 catch ⇒ 恒返回 null。
// ⇒ 单测只能证明"匹配/排序/memo 逻辑对"（已证，10 条全绿），
//   **证不了**"真库里的那条记录能被读出来并配上封面"。
// ```
//
// # 这份探针做的事（全程真数据，零 mock）
// ```text
// ① 起真核心（隔离数据目录 T17_DATA_DIR —— 铁律：绝不碰用户真库）
// ② 扫**真的**下载根（Owner 那个目录：无旁文件）
// ③ 打印：命中几条、选中谁、cover URL 是什么
// ④ ★ 负面对照：库里没有的目录 ⇒ 必须仍是首字占位
// ```
//
// ⚠️ 判据：Owner 的目录必须拿到 cover；负面对照必须为 null。
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/widgets.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ffi.dart' show SourinCore;
import 'package:sourin_spike/ui/cache_page.dart';

final List<String> _lines = <String>[];
void say(String s) {
  debugPrint('[T17] $s');
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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final dataDir = Platform.environment['T17_DATA_DIR'];
  if (dataDir == null || dataDir.isEmpty) {
    say('★ 必须给 T17_DATA_DIR（隔离数据目录）—— 绝不碰用户真库');
    _flush();
    return;
  }
  say('数据目录: $dataDir');
  say('══════════════════════════════════════════════════════════');

  // ── 起核心 ──
  final boot = await SourinCore.startAsync(dataDir);
  say('核心已启动: $boot');
  ok('★ 前置条件：核心起来了', boot['ok'] == true, '$boot');

  // ── 真实数据来源：库 ──
  final hist = await SourinApi.listHistory();
  final favs = await SourinApi.listFavorites();
  say('库读数: 历史 ${hist.length} 条 / 收藏 ${favs.length} 条');
  ok('★ 前置条件：库里**真的有**历史记录（否则本探针无从判起）',
      hist.isNotEmpty, '历史=${hist.length}');

  final target = hist.where((h) => h.title.contains('无职转生')).toList();
  say('目标标题在库里的条数: ${target.length}');
  for (final t in target) {
    say('  · ${t.provider}:${t.nativeId} title=${t.title}');
    say('    cover=${t.cover}');
  }
  ok('★ 前置条件：库里能找到「无职转生」这条（lead 扫 WAL 找到的那条）',
      target.isNotEmpty, '命中=${target.length}');
  ok('★ 前置条件：这条**有封面 URL**（否则找回来也没用）',
      target.any((t) => (t.cover ?? '').trim().isNotEmpty),
      '有封面的=${target.where((t) => (t.cover ?? '').trim().isNotEmpty).length}');

  // ── 真磁盘目录 ──
  final rootPath = CachePage.debugScanRootOverride ??
      'C:\\Users\\iuuuuuuuu\\Videos\\源影';
  say('');
  say('下载根: $rootPath');
  final rootDir = Directory(rootPath);
  ok('★ 前置条件：下载根存在', rootDir.existsSync(), rootPath);
  if (rootDir.existsSync()) {
    final subs = rootDir.listSync().whereType<Directory>().toList();
    say('子目录 ${subs.length} 个:');
    for (final d in subs) {
      final name = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final sc = File('${d.path}${Platform.pathSeparator}$kCacheSidecarName');
      say('  · 「$name」 旁文件=${sc.existsSync()}');
    }
  }

  // ── ★ 主判据：真扫盘 + 真查库 ──
  say('');
  say('── ★ 主判据：扫真目录（无旁文件）⇒ 封面找回来 ──');
  debugClearCacheMetaMemo();
  final works = await scanCacheWorks(rootPath);
  say('扫到 ${works.length} 部作品');
  for (final w in works) {
    say('  · 目录=「${w.dirName}」');
    say('    displayTitle=${w.displayTitle}');
    say('    provider=${w.provider} id=${w.mediaId}');
    say('    cover=${w.cover}');
    say('    集数=${w.completedCount} 字节=${w.bytes}');
  }
  ok('★ 扫盘有结果', works.isNotEmpty, '作品数=${works.length}');

  final owner = works.where((w) => w.dirName.contains('无职转生')).toList();
  ok('★ 找到 Owner 那个目录', owner.isNotEmpty,
      owner.map((w) => w.dirName).toList().toString());
  if (owner.isNotEmpty) {
    final w = owner.first;
    ok('★★★ 主判据：Owner 的目录拿到了**真封面**',
        (w.cover ?? '').trim().isNotEmpty,
        'cover=${w.cover}');
    ok('★★ 同时拿到了 provider/id（详情页来源要用，不是 local）',
        (w.provider ?? '').isNotEmpty && (w.mediaId ?? '').isNotEmpty,
        'provider=${w.provider} id=${w.mediaId}');
  }

  // ── ★ 负面对照：库里没有的目录 ──
  say('');
  say('── ★ 负面对照：库里没有的目录 ⇒ 必须仍是首字占位 ──');
  debugClearCacheMetaMemo();
  final ghost = await resolveCacheMetaByDirName('这个剧库里绝对没有-17-负面对照');
  say('负面对照读数: $ghost');
  ok('★★ 负面对照：库里查不到的目录名 ⇒ 返回 null（走首字占位，不编造封面）',
      ghost == null, '$ghost');

  // ── memo 读数 ──
  say('');
  say('── memo（滚动列表不许每帧查库）──');
  final t0 = DateTime.now();
  for (var i = 0; i < 50; i++) {
    await resolveCacheMetaByDirName('这个剧库里绝对没有-17-负面对照');
  }
  final ms = DateTime.now().difference(t0).inMilliseconds;
  say('50 次同一目录名查询耗时 = ${ms}ms（全部命中 memo ⇒ 0 次 IPC）');
  ok('★ memo 生效：50 次查询 < 50ms（若每次都查库，50 次 IPC 至少数百 ms）',
      ms < 50, '实测 ${ms}ms');

  say('');
  final ownerCover = owner.isEmpty ? 'N/A' : '${owner.first.cover}';
  final ownerProv = owner.isEmpty ? 'N/A' : '${owner.first.provider}';
  say('VERDICT | 库里「无职转生」条数=${target.length} '
      '| Owner 目录 cover=$ownerCover '
      '| provider=$ownerProv '
      '| 负面对照=${ghost == null ? "null(正确)" : "非空(错)"} '
      '| 50次memo=${ms}ms');
  say('RESULT pass=$_pass fail=$_fail');
  _flush();
}

void _flush() {
  final out = Platform.environment['T17_OUT'];
  if (out == null || out.isEmpty) return;
  try {
    File(out).writeAsStringSync(_lines.join('\n'));
  } catch (e) {
    debugPrint('[T17] 写产物失败: $e');
  }
}
