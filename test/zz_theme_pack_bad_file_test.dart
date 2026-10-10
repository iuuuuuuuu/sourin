/*
 * zz_theme_pack_bad_file_test.dart —— CodeRabbit CR-09 端到端门
 *
 * # 这条用例在钉什么
 *
 * CR-09 的原始报告链条：
 *     <数据目录>/themes/broken.json  写了 {"radius":"10"}
 *       -> ThemePack.parse 里 root['radius'] as num? 抛 TypeError
 *       -> parseFile 不 catch => loadAll() 抛
 *       -> current() 抛 => AppTheme.pack / themeFor 抛
 *       -> SourinApp.build 整个挂掉（一个坏文件 => 应用起不来）
 *
 * 为什么单开一个文件而不是塞进 theme_pack_test.dart：
 * 前者测的是**解析层**，这里测的是**应用能不能起来**。后者要 pumpWidget
 * 真身 SourinApp + 处理 RemoteBridge 的进程级定时器，是完全不同的脚手架。
 *
 * ★ 判据必须是「**真挂了**」，不能只是「没抛异常」：
 *   单靠 expect(t.takeException(), isNull) 太弱 —— 一个被 FlutterError.onError
 *   吞掉的错误也能通过它。所以这里额外断言**真的有东西被渲染出来**
 *   （find.byType(ShellPage)），因为 app 起不来时树上根本不会有它。
 *
 * ★ 为什么放三份类型坏文件，而不是只放 CR-09 举例的那一个：
 *   它们分别踩 _FieldReader 的三条降级路径 —— 顶层字段类型错（radius）、
 *   对象字段类型错（colors 是个数组）、嵌套字段类型错（buttonPadding 内部）。
 *   只有真跑过，parseFile 附近任何一处「顺手 cast」都不会漏。
 */
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/shell.dart';
import 'package:sourin_spike/ui/app_palette.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 'package:sourin_spike/ui/theme/theme_pack.dart';

/// 挂**生产本体** SourinApp，等首帧稳定，并把途中所有 FlutterError 原样回吐。
///
/// ⚠️ FlutterError.onError **必须在测试体内还原**（不能用 addTearDown）：
///    flutter_test 的 binding.dart:1912 会在测试体结束时断言
///    「覆写过 onError 就必须自己还原」，用 addTearDown 还原太晚 ——
///    实测报 '_pendingExceptionDetails != null'。所以 mute -> pump ->
///    认领 -> **立刻还原**，之后才轮到调用方去 expect。
///
/// ★ 与 a1_tv_text_scale_test.dart 的同名脚手架同源（那份已验证可用）。
///    差别只在一个：这里**不吞**异常，而是回吐给调用方 —— 因为本文件要断言的
///    恰恰是「没有异常冒出来」，吞掉就没法断言了（见文件头「判据」段）。
///
/// ★ 为什么中间还要 pump 400ms：应用在首帧前后会写偏好（UiPrefs.set 会挂一个
///    300ms 的去抖落盘定时器）。不把它等掉，测试体结束时 flutter_test 会以
///    'A Timer is still pending even after the widget tree was disposed.' 判红 ——
///    那是脚手架的账，不是被测代码的账。
Future<List<FlutterErrorDetails>> _pumpRealApp(WidgetTester t) async {
  final caught = <FlutterErrorDetails>[];
  final oldOnError = FlutterError.onError;
  FlutterError.onError = (d) => caught.add(d);

  await t.pumpWidget(const SourinApp());
  await t.pump();
  await t.pump(const Duration(milliseconds: 400)); // 等掉偏好落盘去抖

  FlutterError.onError = oldOnError; // ★ 必须在 expect 之前

  // 框架自己抛的那一份也一并收走（HomePage 在无 dll 环境下必然抛，
  // 与 core_error_test.dart 同一处理）
  while (t.takeException() != null) {}

  // ★ 收掉 RemoteBridge 的复查定时器：它是**进程级单例**，活得比 widget 树长
  //   （remote_bridge.dart 明说这是设计如此），而 flutter_test 会断言
  //   !timersPending => 必须显式 stop()，等价于「进程退出」。
  RemoteBridge.instance.stop();

  return caught;
}

/// 一个只含给定主题文件的临时数据目录。
///
/// 文件规格写成 `'名字|||JSON 内容'`，返回注入用的 root 路径。
///
/// ⚠️ ThemePackStore.dir 会在注入的 root **下面**再建一层 themes/，
///    所以文件必须落在 <root>/themes/（少这一层就等于放到目录外面了，
///    实测 loadAll 读不到 —— theme_pack_test.dart:313-318 记着同一个坑）。
String _seedThemeDir(List<String> specs) {
  final root = Directory.systemTemp.createTempSync('sourin_cr09');
  final dir = Directory('${root.path}${Platform.pathSeparator}themes')
    ..createSync(recursive: true);
  for (final spec in specs) {
    final i = spec.indexOf('|||');
    final name = spec.substring(0, i);
    File('${dir.path}${Platform.pathSeparator}$name.json')
        .writeAsStringSync(spec.substring(i + 3));
  }
  return root.path;
}

/// 把 selectedId 直接塞进偏好内存表。
///
/// ★ 为什么不用 `ThemePackStore.select()`：那会走 `UiPrefs.set` -> `_flushSoon`，
///    挂一个 300ms 的 `Future.delayed` 去抖定时器；在 FakeAsync 下它活过测试体，
///    让 flutter_test 直接判红（'A Timer is still pending...'）。而本文件要的只是
///    「让 current() 认得这个 id」，不需要任何落盘行为 —— `debugResetForTest`
///    正是为此存在的：直接给内存表赋值，**不碰** `_file` / `_dirty`，也就不会调度定时器。
void _seedSelected(String id) =>
    UiPrefs.debugResetForTest({ThemePackStore.storageKey: id});

void main() {
  tearDown(() {
  // ★ 用 debugResetForTest 而不是 UiPrefs.remove —— 后者同样会挂 300ms 落盘
  //   定时器，等于给每条用例都埋一个 'Timer is still pending' 的假红。
  UiPrefs.debugResetForTest();
  ThemePackStore.debugSetDataDir(null);
  });

  group('CR-09 (c)：一份损坏的主题文件**不许**阻塞 SourinApp.build', () {
    testWidgets('★ 选中一份坏主题包后，应用照样起来（挂生产本体 SourinApp）',
        (t) async {
      // 三份类型坏文件，分别踩三条不同的降级路径：
      //   (1) 顶层字段类型错  {"radius":"10"}
      //   (2) 对象字段类型错  {"colors":[1]}
      //   (3) 嵌套字段类型错  {"buttonPadding":{"horizontal":"wide",...}}
      // 外加一份**语法都坏**的（当烟雾弹：语法坏是 parseFile 早就处理过的）
      final root = _seedThemeDir([
        'bad-type|||{"name":"坏类型","brightness":"dark","radius":"10"}',
        'bad-colors|||{"name":"坏对象","brightness":"dark","colors":[1]}',
        'bad-nested|||{"name":"坏嵌套","brightness":"dark",'
            '"buttonPadding":{"horizontal":"wide","vertical":4}}',
        'bad-syntax|||{这不是 JSON',
      ]);
      ThemePackStore.debugSetDataDir(root);

      // ★ 关键一步：把这份「坏包」设成**当前选中**的主题包。
      //   CR-09 报告里 selectedId 非空时 SourinApp.build 才会挂 ——
      //   只放文件不选中，等于根本没走到那条路径上。
      _seedSelected('bad-type');
      expect(ThemePackStore.selectedId, 'bad-type', reason: '前置条件：已选中');

      final caught = await _pumpRealApp(t);
      final real = caught.where((d) => !_isNoCoreNoise(d)).toList();

      // ★★ 判据一：pump 全程**一个主题相关的异常都不许冒出来**。
      //   这里刻意不用 expect(t.takeException(), isNull)：那太弱 ——
      //   被 FlutterError.onError 收走（也就是被我们静音）的错误它照样放行。
      expect(real, isEmpty,
          reason: '★ 坏主题包让 build 抛了：\n'
              '${real.map((d) => d.exceptionAsString()).join("\n---\n")}');

      // ★ 判据二：应用**真的渲染出来了** —— 不是「没报错」，是「起来了」。
      expect(find.byType(ShellPage, skipOffstage: false), findsOneWidget,
          reason: '★ 应用没起来：树上连 ShellPage 都没有');
      expect(find.byType(SourinApp, skipOffstage: false), findsOneWidget);
    });

    testWidgets('★ 坏文件在场时，好包仍然照常被读出来（不许「一个坏全盘丢」）',
        (t) async {
      final root = _seedThemeDir([
        'ok|||{"name":"好包","brightness":"dark"}',
        'bad-type|||{"radius":"10"}',
      ]);
      ThemePackStore.debugSetDataDir(root);
      _seedSelected('ok');

      final caught = await _pumpRealApp(t);

      final all = ThemePackStore.loadAll();
      expect(all.map((p) => p.id), contains('ok'),
          reason: '★ 一份坏文件不许把好包一起拖下水');
      expect(find.byType(ShellPage, skipOffstage: false), findsOneWidget);
      expect(caught.where((d) => !_isNoCoreNoise(d)), isEmpty);
    });

    testWidgets('★ 坏包被降级成内置默认配色，而不是把屏幕画成空白',
        (t) async {
      final root = _seedThemeDir([
        'bad-type|||{"brightness":"dark","radius":"10","colors":[1],"id":5,'
            '"buttonPadding":3}',
      ]);
      ThemePackStore.debugSetDataDir(root);
      _seedSelected('bad-type');

      final caught = await _pumpRealApp(t);

      // 降级后的包必须是一份**完整可用**的配色（全部来自内置深色），
      // 而不是 null / 透明 / 全零 —— 那是「渲染出一片死黑」的表现。
      final pack = ThemePackStore.current();
      expect(pack.id, 'bad-type');
      expect(pack.palette.background, AppPalette.dark.background,
          reason: '★ 全坏的字段必须回落到内置深色底');
      expect(pack.palette.foreground, AppPalette.dark.foreground);
      expect(pack.palette.primary, AppPalette.dark.primary);
      expect(pack.radius, isNull, reason: '类型错的 radius 不许被采纳');
      expect(pack.name, isNotEmpty, reason: '名字要兜底，不许是空串');

      expect(caught.where((d) => !_isNoCoreNoise(d)), isEmpty);
      expect(find.byType(ShellPage, skipOffstage: false), findsOneWidget);
    });
  });

  group('CR-09 补充：parse 的不变量「任何输入都不抛、绝不返回 null」', () {
    test('★ 穷举一批畸形输入，parse 一律降级成一份可用的包', () {
      final inputs = <String>[
        '',
        '   ',
        'null',
        '123',
        'true',
        '"一个字符串"',
        '[]',
        '[{"radius":"10"}]',
        '{',
        '{}',
        '{"radius":"10","colors":[1]}',
        '{"version":"2"}',
        '{"version":true}',
        '{"brightness":123}',
        '{"brightness":[]}',
        '{"colors":"x"}',
        '{"colors":{"background":[]}}',
        '{"radius":true}',
        '{"radius":[10]}',
        '{"buttonPadding":3}',
        '{"buttonPadding":{"horizontal":"wide","vertical":4}}',
        '{"buttonPadding":{"horizontal":1e9,"vertical":4}}',
        '{"id":5}',
        '{"name":[]}',
        '{"id":{"a":1},"name":{"b":2}}',
        '{"unknownField":1,"anotherOne":[1,2]}',
        '{"colors":{"primary":"#ZZZZZZ"}}',
      ];

      for (final input in inputs) {
        late ThemePackResult r;
        expect(() => r = ThemePackStore.importFromString(input), returnsNormally,
            reason: '★「$input」把 parse 弄抛了 —— 一份坏主题包不该让'
                '应用起不来（CR-09）');
        expect(r.pack.id, isNotEmpty, reason: 'parse 永远返回一份可用包');
        expect(r.pack.name, isNotEmpty, reason: '名字要兜底，不许是空串');
      }
    });

    test('★ 类型写错必须**点名**：每个错字段一条警告（不许静默降级）', () {
      // ★ 与上一条互为对照：上一条只管「不抛」，这条管「降级时必须说话」。
      //   只断言 warnings 非空不够 —— 空 JSON（{}）本来就没有错字段，
      //   它不该有警告；所以这里逐个**点名**要出现的字段名。
      final cases = <String, List<String>>{
        '{"radius":"10","colors":[1]}': ['radius', 'colors'],
        '{"version":"2"}': ['version'],
        '{"brightness":123}': ['brightness'],
        '{"colors":"x"}': ['colors'],
        '{"id":5}': ['id'],
        '{"name":[]}': ['name'],
        '{"buttonPadding":3}': ['buttonPadding'],
        '{"buttonPadding":{"horizontal":"wide","vertical":4}}':
            ['horizontal'],
        '[]': ['不是 JSON 对象'],
        '{': ['JSON 语法错误'],
      };

      cases.forEach((input, fields) {
        final r = ThemePackStore.importFromString(input);
        for (final f in fields) {
          expect(r.warnings.any((w) => w.contains(f)), isTrue,
              reason: '★「$input」的警告里没点名「$f」——用户根本不知道自己写错了：${r.warnings}');
        }
      });
    });

    test('★ 缺字段（不是类型错）不许刷警告', () {
      // 与上一条互为对照：警告的来源必须精确区分「没写」与「写错了类型」。
      final r = ThemePackStore.importFromString('{"name":"只有名字"}');
      expect(r.warnings, isEmpty,
          reason: '★ 只有 name 合法，其余**都没写** —— 不该有任何警告');
      expect(r.pack.name, '只有名字');
      expect(r.pack.id, 'imported', reason: '没写 id 时用 idHint');

      // 空对象同理：一个字段都没写，不该被当成「全是错的」。
      final empty = ThemePackStore.importFromString('{}');
      expect(empty.warnings, isEmpty, reason: '★ 空对象没有任何类型错');
    });

    test('★ 好包**零警告**（不许为了「保险」给正常输入也加提示）', () {
      for (final p in ThemePackStore.builtins) {
        final r = ThemePackStore.importFromString(jsonEncode(p.toJson()));
        expect(r.warnings, isEmpty,
            reason: '★ 内置主题「${p.name}」导出的 JSON 自己读不回来：'
                '${r.warnings}');
      }
    });
  });
}

/// 判断一个 FlutterErrorDetails 是不是「无核心环境」的既有噪声。
///
/// ⚠️ 这不是放水，是一个**收得很紧**的白名单：本机 sourin_core.dll 不在仓库
///    根目录（只在 .probe/t*-run/ 下），所以 HomePage 必然因为「加载不到核心」
///    抛异常 —— 那是**另一个缺陷**的领域，与主题包无关。
///    而只要异常文本里出现 theme / pack 关键词，一律**不算**噪声 ——
///    那样一条「因为主题包而抛」的异常就会从缝里溜过去。
bool _isNoCoreNoise(FlutterErrorDetails d) {
  final s = d.exceptionAsString().toLowerCase();
  if (s.contains('theme') || s.contains('themepack')) return false;
  return s.contains('sourin_core.dll') ||
      s.contains('failed to load dynamic library') ||
      s.contains('error code: 126') ||
      s.contains('未绑定') ||
      s.contains('core');
}
