// ═══════════════════════════════════════════════════════════════════════
//  task-5【缺陷 5】真机闭环：插件「来源标识 + 上游链接」端到端
// ═══════════════════════════════════════════════════════════════════════
//
// # 这条探针要证的两件事（Owner 缺陷 5 逐字）
//
// ```text
// 「你既然已经支持了 tvbox，那么就应该把所有的 tvbox 插件都还原成原本
//   的链接，而不是现在转换后的插件，而且要加上标识，自己平台的插件
//   还是 tvbox 的兼容」
//
//   ① 上游链接   22 个 tvbox-convert 插件的**原始接口地址**要能看见
//   ② 来源标识   卡片上要能区分「TVBox 兼容」/「源影自研」
// ```
//
// # 为什么必须是**真 FFI + 真控件**（而不是静态断言）
//
// ```text
// 静态断言只能证「源码里有这个字符串」。本缺陷的失败模式恰恰是
// 「字符串在、数据没到」：
//   Rust 解析 → JSON 序列化 → Dart fromJson → 宿主 _pluginOf
//   → 卡片 _sourceLine → 真正渲染成 Text
// 中间任何一环断了，静态断言全绿而用户什么都看不见。
// ```
//
// # 环境前提（不满足就 skip，不假装通过）
//
// `build\windows\x64\runner\Release\sourin_core.dll` 必须存在。
//
// ⚠️ 绝不碰 `%APPDATA%\app.sourin.player`：只**读**那里的 28 个插件
//    拷进 `.probe/t5_live_data/plugins`，`start()` 指向隔离目录。

// ★ 只取 `DynamicLibrary` —— `dart:ffi` 与 `dart:ui` 都导出 `Size`
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/settings_page.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

const String kTag = '[T5]';
void log(String s) => debugPrint('$kTag $s');

const Timeout kTimeout = Timeout(Duration(minutes: 5));

const String _dllRel = r'build\windows\x64\runner\Release\sourin_core.dll';
final bool _dllReady = File(_dllRel).existsSync();

void _preloadCoreDll() {
  if (!_dllReady) return;
  DynamicLibrary.open(File(_dllRel).absolute.path);
  log('DLL 预加载 = OK（${File(_dllRel).absolute.path}）');
}

Widget _host(Widget child, {Size size = const Size(1280, 900)}) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    builder: (context, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: Builder(
      builder: (context) {
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(size: size),
          child: Material(
            type: MaterialType.transparency,
            child: Scaffold(body: child),
          ),
        );
      },
    ),
  );
}

Future<T> _ffi<T>(WidgetTester tester, Future<T> Function() body) async {
  final r = await tester.runAsync(body);
  return r as T;
}

Future<void> _realWait(WidgetTester tester, int ms) async {
  await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
}

/// 收走异常并**分类计数** —— 溢出是要专门盯的一类（卡片只有 211px 正文宽）
class Exceptions {
  int total = 0;
  int overflow = 0;
  final List<String> first = <String>[];
}

final Exceptions _seen = Exceptions();

void _claim(WidgetTester tester, String where) {
  while (true) {
    final e = tester.takeException();
    if (e == null) break;
    _seen.total++;
    final s = e.toString().split('\n').first;
    if (s.contains('overflowed')) _seen.overflow++;
    if (_seen.first.length < 3) {
      _seen.first.add('$where| $s');
      log('$where| ★ 收走异常: $s');
    }
  }
}

Future<void> _settle(WidgetTester tester, {int rounds = 8, int ms = 300}) async {
  for (var i = 0; i < rounds; i++) {
    await _realWait(tester, ms);
    await tester.pump();
    _claim(tester, 'settle$i');
  }
}

Finder? _safe(Finder f) {
  try {
    if (f.evaluate().isEmpty) return null;
  } catch (_) {
    return null;
  }
  return f.first;
}

int _count(Finder f) {
  try {
    return f.evaluate().length;
  } catch (_) {
    return -1;
  }
}

List<String> _textsContaining(WidgetTester tester, String needle) {
  final out = <String>[];
  for (final e in find.byType(Text).evaluate()) {
    final t = (e.widget as Text).data;
    if (t != null && t.contains(needle)) out.add(t);
  }
  return out;
}

List<String> _cardNames(WidgetTester tester) {
  final cards = find.byWidgetPredicate(
    (w) => w.runtimeType.toString() == '_ProviderCard',
  );
  final out = <String>[];
  for (final c in cards.evaluate()) {
    String? name;
    void visit(Element e) {
      final w = e.widget;
      if (w is Text && w.data != null && w.data!.trim().isNotEmpty) {
        name ??= w.data;
      }
      e.visitChildren(visit);
    }

    c.visitChildren(visit);
    out.add(name ?? '(无名)');
  }
  return out;
}

/// 某张源卡片里的文本读数（用于证明"标识与链接长在**同一张卡**上"）
List<String> _cardTexts(WidgetTester tester, String providerName) {
  final card = _safe(find.ancestor(
    of: find.text(providerName),
    matching: find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_ProviderCard',
    ),
  ));
  if (card == null) return const <String>[];
  final out = <String>[];
  for (final e in find.descendant(of: card, matching: find.byType(Text)).evaluate()) {
    final t = (e.widget as Text).data;
    if (t != null && t.trim().isNotEmpty) out.add(t);
  }
  return out;
}

// ═══════════════════════════════════════════════════════════════════════

void main() {
  final dataDir = Directory('.probe/t5_live_data');
  var copied = 0;

  setUpAll(() async {
    if (!_dllReady) {
      log('★★ $_dllRel 不存在 ⇒ 跳过（先构建 Windows 版）');
      return;
    }
    _preloadCoreDll();
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    dataDir.createSync(recursive: true);

    // ── 把**真实**的 28 个插件拷进隔离目录（只读源目录，绝不写）──
    final src = Directory(
        '${Platform.environment['APPDATA']}\\app.sourin.player\\plugins');
    final dst = Directory('${dataDir.path}/plugins')..createSync(recursive: true);
    if (src.existsSync()) {
      for (final e in src.listSync()) {
        if (e is File && e.path.toLowerCase().endsWith('.js')) {
          final name = e.uri.pathSegments.last;
          e.copySync('${dst.path}/$name');
          copied++;
        }
      }
    }
    log('拷入真实插件 $copied 个 → ${dst.absolute.path}');

    final started = await SourinApi.start(dataDir.absolute.path);
    log('start() = $started');
    log('reloadPlugins() = ${await SourinApi.reloadPlugins()}');
  });

  tearDownAll(() async {
    if (dataDir.existsSync()) {
      try {
        dataDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  // ═══════════════════════════════════════════════════════════════════

  testWidgets('A. listPlugins 带回 author + upstream（真 FFI 读数）',
      (tester) async {
    final r = await _ffi(tester, () => SourinApi.listPlugins());
    log('A| 插件 ${r.plugins.length} 个 / 加载失败 ${r.failed.length} 个');

    final byAuthor = <String, int>{};
    for (final p in r.plugins) {
      byAuthor[p.author.isEmpty ? '(空)' : p.author] =
          (byAuthor[p.author.isEmpty ? '(空)' : p.author] ?? 0) + 1;
    }
    final withUp = r.plugins.where((p) => p.upstream.isNotEmpty).toList();
    log('A| ★ author 分布 = $byAuthor');
    log('A| ★ upstream 非空 = ${withUp.length} / ${r.plugins.length}');

    for (final p in r.plugins) {
      log('A|   ${p.file.padRight(22)} author=${p.author.padRight(15)} '
          'upstream=${p.upstream.isEmpty ? "(无)" : p.upstream}');
    }

    // ── ★★ 断言：缺陷 5 的两个诉求在**数据层**成立 ──
    expect(r.plugins.length, copied, reason: '每个拷进来的 .js 都应出现在列表里');
    expect(byAuthor['tvbox-convert'], 22,
        reason: '★ 实测本机 22 个 tvbox-convert 插件（少一个说明 @author 没读出来）');
    for (final p in r.plugins.where((p) => p.author == 'tvbox-convert')) {
      expect(p.upstream, isNotEmpty,
          reason: '★ 转换器生成的 ${p.file} 必须带原始接口地址');
    }
    final ty = r.plugins.firstWhere((p) => p.file == 'tyyszy.js');
    expect(ty.upstream, 'http://tyyszy.com/api.php/provide/vod',
        reason: '★ 原始链接必须**逐字节**还原（这是缺陷 5 的原话）');
    final cctv = r.plugins.firstWhere((p) => p.file == 'cctv.js');
    expect(cctv.author, 'dsh', reason: '内置源模板的作者名');
    expect(cctv.upstream, '', reason: '内置源没有上游链接 ⇒ 空，不编一个');
    /*
     * ★★★ 2026-10-09 修正：手写插件**不能**拿正文 `const API` 当上游。
     *
     * 这条断言原先是 `expect(bili.upstream, 'https://api.bilibili.com')`
     * —— 它锁住的正是那个 bug：`const API` 是**接口地址**，不是安装来源。
     * 后果：编辑对话框据此把手写的 bilibili 判成「按链接安装」⇒
     * 预填接口地址 + 类型锁死 ⇒ 点保存走 installPlugin(接口地址)
     * ⇒ **把本地插件覆盖坏**（Owner 2026-10-09 截图报的就是这个）。
     *
     * 现在 `upstream_of` **只**认头部注释里的「上游接口」——
     * 手写插件没有那段注释 ⇒ 如实返回空串（"它的来源就是用户自己写的"）。
     * 真·按链接安装的来源在 `plugins/.meta/<id>.json` 的 `source_url`。
     */
    final bili = r.plugins.firstWhere((p) => p.file == 'bilibili.js');
    expect(bili.upstream, '',
        reason: '★ 接口地址不是安装来源 —— 编一个会让编辑框误判成链接型');
  }, timeout: kTimeout);

  // ═══════════════════════════════════════════════════════════════════

  testWidgets('B. 卡片真的画出「标识 chip + 上游链接」（真控件）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_host(const SettingsPage()));
    _claim(tester, 'B|pump1');
    await _settle(tester);
    log('B| 加载后 ListView = ${_count(find.byType(ListView))}');

    // ── 进二级页（「JS 插件」入口，默认 tab 就是内容源）──
    final entry = _safe(find.text('JS 插件'));
    if (entry == null) {
      log('B| ★★ 一级页没找到「JS 插件」入口 ⇒ 读数无效');
      fail('设置页没有「JS 插件」入口');
    }
    await tester.ensureVisible(entry!);
    await tester.pump();
    await tester.tap(entry, warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    _claim(tester, 'B|nav');
    await _settle(tester, rounds: 4);

    final names = _cardNames(tester);
    log('B| 卡片 ${names.length} 张: ${names.take(8).toList()}…');

    final badges = _textsContaining(tester, 'TVBox 兼容');
    final own = _textsContaining(tester, '源影自研');
    final urls = _textsContaining(tester, 'http://tyyszy.com/api.php/provide/vod');
    log('B| ★ 「TVBox 兼容」chip = ${badges.length} 个');
    log('B| ★ 「源影自研」chip = ${own.length} 个');
    log('B| ★ 含 tyyszy 原始链接的 Text = ${urls.length} 个 → $urls');

    // ── 同一张卡上的三项读数（证明"标识与链接长在这张卡上"）──
    final cardTexts = _cardTexts(tester, '影视天涯');
    log('B| 「影视天涯」卡片全部文本 = $cardTexts');

    expect(badges.length, greaterThan(0),
        reason: '★★ 22 个转换插件必须有「TVBox 兼容」标识（缺陷 5 的第二个诉求）');
    expect(cardTexts, contains('TVBox 兼容'),
        reason: '★★ 标识要长在**这张卡**上，不是别处');
    expect(cardTexts.any((t) => t.contains('tyyszy.com')), isTrue,
        reason: '★★ 原始链接要长在**这张卡**上（缺陷 5 的第一个诉求）');

    // ── ★ 点一下链接：必须真的复制（宿主 `_copy` 的「已复制」toast）──
    final link = _safe(find.textContaining('tyyszy.com'));
    if (link != null) {
      await tester.ensureVisible(link);
      await tester.pump();
      await tester.tap(link, warnIfMissed: false);
      await tester.pump();
      await _settle(tester, rounds: 2);
      final toast = _textsContaining(tester, '已复制');
      log('B| ★ 点击链接后「已复制」toast = ${toast.length} 个');
      expect(toast, isNotEmpty, reason: '★★ 链接必须可点击复制（缺陷 5 的落点）');
    } else {
      log('B| ★★ 没找到链接 Text ⇒ 复制那条测不到');
    }

    log('B| ★★ 溢出异常 = ${_seen.overflow} / 总异常 = ${_seen.total}');
    expect(_seen.overflow, 0,
        reason: '★★ 211px 正文预算不得溢出（卡片只有 299px 宽 / 4 列）');

    /*
     * ⚠️ 收尾：把树拆掉并把假时钟推过 `_flash` 那个 3 秒 toast 定时器
     *
     * 上面点了链接 ⇒ 宿主 `_copy` → `_flash('已复制')` 起了一个
     * `Future.delayed(3s)`（`settings_page.dart:582`）。
     * 测试框架在拆树后检查 `!timersPending` —— 那个**产品行为本来就该有**
     * 的定时器会被判成"泄漏"：
     * ```text
     * A Timer is still pending even after the widget tree was disposed.
     * ```
     * ★ 这不是产品缺陷（`_flash` 的设计就是 3 秒后自动消失），
     *   是**仪器**要自己把时间推过去（同 `zz_t53s` 的收尾写法）。
     */
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
    _claim(tester, 'B|teardown');
  }, timeout: kTimeout);
}
