// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 超长错误文本不得把面板撑破（macOS CI 逼出来的真缺陷）
// ═══════════════════════════════════════════════════════════════════════
//
// # 怎么发现的
// ```text
// macOS CI 上 t59 有 6 条 ★★★、t97 有 1 条全红，而**断言本身是通过的**：
//   [T60] embedded ColoredBox colors = [… surface]      ← 打印且通过
//   embedded Scaffold 层数 = 0（期望 0）                 ← 打印且通过
// 红在同一次 pump 抛的溢出异常上：
//   A RenderFlex overflowed by 580 pixels on the bottom.
//   creator: Column ← Padding ← Center ← _ErrorView ← Stack ← …
//   constraints: BoxConstraints(0.0<=w<=320.0, 0.0<=h<=736.0)
// ```
//
// # 为什么只有 macOS 红（真因不在主题/布局）
// ```text
// macOS 上缺 libsourin_core.dylib ⇒ DetailPage 落进 _ErrorView，
// 而 dlopen 失败文本是**平台相关**的：
//   Windows : Failed to load dynamic library … (error code: 126)
//             ≈100 字符 ⇒ 塞得下 ⇒ 同组在 Windows 绿
//   macOS   : dlopen(…, 0x0001): tried: '…' (no such file), …
//             ≈1500 字符（一长串候选路径）⇒ 必然溢出
// ```
// ⇒ 这是**真的产品缺陷**：任何一条足够长的错误信息（插件报错、
//   HTTP 报错体、路径很长的加载失败）在窄面板下都会溢出。
//   macOS 只是把它逼出来了。
//
// # 本文件怎么测（不依赖任何平台差异）
// ```text
// 用 debugSetError() 注入**等长的文本**，于是本地也能复现 ——
// 不必等 CI，也不必真的让某个库加载失败。
// ★ 与 debugSetDetail / debugSetResume 同一手法（本仓既有先例）。
// ```
//
// # 反向验证（本文件真能抓到缺陷吗）
// ```text
// 把 _ErrorView 里的 Flexible(child: SingleChildScrollView(…))
// 换回裸 Text(message, …) ⇒ 本文件必须转红（已实测）。
// ★ 这是本仓铁律：新测试必须证明它**能失败**，否则只是装饰。
// ```
//
// 跑法（纯 widget 测试，不需要 native-media）：
//   flutter test test/t119_error_view_overflow_test.dart --reporter expanded

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/detail_page.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';

/// macOS 那条 dlopen 失败文本的**形状**（实测 ≈1500 字符）
///
/// ★ 逐字对齐真实形状：tried: 后面跟一长串候选路径，每条都是
///   '<路径>' (no such file), 。
///   这里用等长近似 —— 要复现的是**长度**，不是具体路径。
String _macosStyleMessage() {
  final buf = StringBuffer();
  buf.write("Failed to load dynamic library 'libsourin_core.dylib': ");
  buf.write('dlopen(libsourin_core.dylib, 0x0001): tried: ');
  for (var i = 0; i < 14; i++) {
    buf.write(
      "'/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/"
      "libsourin_core.dylib' (no such file), ",
    );
  }
  return buf.toString();
}

/// Windows 那条（≈100 字符）—— 阳性对照
const _windowsStyleMessage =
    'Failed to load dynamic library sourin_core.dll (error code: 126)';

/// macOS CI 报错时的真实约束：0.0 <= w <= 320.0
const _panelW = 320.0;

/// 剥注释（本仓铁律⑤：contains 必须先剥注释）
///
/// ★ 逐字节复用 t97_resume_chip_fit_test.dart:65-112 的状态机 ——
///   不自己写正则版（正则版会把字符串里的 // 当注释，本仓已有教训）。
String _stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote;
  while (i < src.length) {
    final c = src[i];
    final n = i + 1 < src.length ? src[i + 1] : '';
    if (quote != null) {
      if (c == r'\') {
        out.write(c);
        if (n.isNotEmpty) {
          out.write(n);
          i += 2;
          continue;
        }
      }
      if (c == quote) quote = null;
      out.write(c);
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && n == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && n == '*') {
      i += 2;
      while (i < src.length &&
          !(src[i] == '*' && i + 1 < src.length && src[i + 1] == '/')) {
        if (src[i] == '\n') out.write('\n');
        i++;
      }
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 真主题 + 定宽面板里挂 DetailPage（embedded: true = 合并页右侧面板）
Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: child,
  );
}

/// 在**捕获窗口**内执行 body：把渲染异常正文记进 sink，并照旧转发
///
/// ★ 为什么必须从 FlutterError.onError 取正文：同一个 pump 里抛出**多条**时，
///   takeException() 只给一句 "Multiple exceptions (2) were detected…"
///   —— 正文全丢，而我们要断言的恰恰是正文里的 overflowed by N pixels。
///   （抄自 test/t97_resume_chip_fit_test.dart:152-163。）
Future<void> _guard(List<String> sink, Future<void> Function() body) async {
  final prev = FlutterError.onError;
  FlutterError.onError = (details) {
    sink.add(details.exceptionAsString().split('\n').first);
    prev?.call(details);
  };
  try {
    await body();
  } finally {
    FlutterError.onError = prev;
  }
}

Future<void> _pumpDrain(WidgetTester t, int frames, List<String> sink) =>
    _guard(sink, () async {
      for (var i = 0; i < frames; i++) {
        await t.pump(const Duration(milliseconds: 250));
        while (t.takeException() != null) {}
      }
    });

/// 溢出类异常（RenderFlex overflowed by N pixels）
List<String> _overflows(List<String> caught) =>
    caught.where((e) => e.contains('overflowed')).toList();

/// 挂载 DetailPage 并返回 state（不注入数据 ⇒ 它会自己落进 _ErrorView）
Future<State<DetailPage>> _mount(
  WidgetTester t,
  double panelW,
  List<String> sink,
) async {
  await t.binding.setSurfaceSize(Size(panelW, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));

  final key = GlobalKey<State<DetailPage>>();
  await _guard(sink, () async {
    await t.pumpWidget(
      _host(
        Scaffold(
          body: DetailPage(
            key: key,
            provider: 'cycani',
            id: 't119',
            embedded: true,
          ),
        ),
      ),
    );
  });
  await _pumpDrain(t, 2, sink);
  return key.currentState!;
}

/// 注入一条错误信息，然后跑几帧
Future<void> _inject(
  WidgetTester t,
  State<DetailPage> st,
  String msg,
  List<String> sink,
) async {
  // ignore: avoid_dynamic_calls
  (st as dynamic).debugSetError(msg);
  await _pumpDrain(t, 3, sink);
}

void main() {
  late String errView;

  setUpAll(() {
    final src = _stripComments(
      File('lib/ui/detail_page.dart').readAsStringSync(),
    );
    final at = src.indexOf('class _ErrorView extends StatelessWidget {');
    expect(at, greaterThan(-1), reason: '_ErrorView 不见了 —— 锚点失效');
    errView = src.substring(at).replaceAll(RegExp(r'\s+'), ' ');
  });

  group('★ 错误视图：超长文本不得溢出', () {
    testWidgets('① ★★★ 1500 字符的 macOS 形状文本 @320px ⇒ 零溢出', (t) async {
      final sink = <String>[];
      final st = await _mount(t, _panelW, sink);
      sink.clear(); // 清掉挂载期的环境噪声（缺 DLL 之类）

      final msg = _macosStyleMessage();
      await _inject(t, st, msg, sink);

      final ov = _overflows(sink);
      // ignore: avoid_print
      print(
        'T119|① 面板 ${_panelW.toStringAsFixed(0)}px，'
        '消息 ${msg.length} 字符，溢出 ${ov.length} 条',
      );
      expect(
        ov,
        isEmpty,
        reason: '★ 超长错误文本溢出了 —— macOS 上 t59 的 6 条 ★★★ 与 '
            't97 的 1 条就是这么红的。第一条正文：'
            '${ov.isEmpty ? '' : ov.first}',
      );
    });

    testWidgets('② ★★ 信息一个字都没丢（可滚动，不是截断）', (t) async {
      final sink = <String>[];
      final st = await _mount(t, _panelW, sink);
      sink.clear();

      final msg = _macosStyleMessage();
      await _inject(t, st, msg, sink);

      /*
       * ★ 判据是「文本**完整存在于树上**」，不是「肉眼看得见全部」——
       *   后者在窄面板下本来就不可能（1500 字符要滚）。
       *   本仓纪律：不吞错误 ⇒ 必须保留全文，只是让它可滚动。
       */
      final texts = t
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? '')
          .toList();
      final full = texts.any((s) => s == msg);
      // ignore: avoid_print
      print(
        'T119|② 树上 Text 共 ${texts.length} 个，完整消息在树上 = $full',
      );
      expect(
        full,
        isTrue,
        reason: '★ 完整消息不在树上 ⇒ 有人用了 ellipsis/maxLines 把错误吃掉了。'
            '这正是本仓反复强调的「不吞错误」那条纪律。',
      );
      expect(_overflows(sink), isEmpty);
    });

    testWidgets('③ ★★ 阳性对照：短消息（Windows 形状）同样零溢出', (t) async {
      final sink = <String>[];
      final st = await _mount(t, _panelW, sink);
      sink.clear();

      await _inject(t, st, _windowsStyleMessage, sink);

      final ov = _overflows(sink);
      // ignore: avoid_print
      print('T119|③ 短消息溢出 ${ov.length} 条');
      expect(ov, isEmpty, reason: '★ 短消息也溢出了 —— 说明修法本身有问题');
    });

    testWidgets('④ ★★★ 逐宽度扫：320 / 340 / 440 / 620 全零溢出', (t) async {
      for (final w in <double>[320, 340, 440, 620]) {
        final sink = <String>[];
        final st = await _mount(t, w, sink);
        sink.clear();
        await _inject(t, st, _macosStyleMessage(), sink);
        final ov = _overflows(sink);
        // ignore: avoid_print
        print('T119|④ 面板 ${w.toStringAsFixed(0)}px ⇒ 溢出 ${ov.length} 条');
        expect(ov, isEmpty, reason: '★ 面板 ${w.toStringAsFixed(0)}px 时溢出了');
      }
    });

    testWidgets('⑤ ★★★ 源码守卫：修法没被换回截断版', (t) async {
      // ignore: avoid_print
      final hasFlex = errView.contains('Flexible(');
      final hasScroll = errView.contains('SingleChildScrollView(');
      // ignore: avoid_print
      print(
        'T119|⑤ _ErrorView 里 Flexible = $hasFlex，'
        'SingleChildScrollView = $hasScroll',
      );
      expect(
        hasFlex,
        isTrue,
        reason: '★ _ErrorView 里没有 Flexible ⇒ 超长文本会撑破 Column',
      );
      expect(
        hasScroll,
        isTrue,
        reason: '★ _ErrorView 里没有 SingleChildScrollView ⇒ 超长文本滚不动',
      );
      /*
       * ★ 下面两条是**反向**守卫：不许用 ellipsis / maxLines 把错误藏起来。
       *   本仓纪律：不吞错误 —— 宁可让它可滚动，也不许悄悄截断。
       */
      expect(
        errView.contains('TextOverflow.ellipsis'),
        isFalse,
        reason: '★ 有人给错误文本加了 ellipsis ⇒ 用户在排查时看不到真实原因',
      );
      expect(
        errView.contains('maxLines'),
        isFalse,
        reason: '★ 有人给错误文本加了 maxLines ⇒ 同上',
      );
    });
  });
}
