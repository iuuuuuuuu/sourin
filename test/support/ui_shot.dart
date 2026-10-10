// ═══════════════════════════════════════════════════════════════════════
//  无头 UI 截图：在 flutter_tester 里用**真字体**把页面画成 PNG
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要它（2026-10-10）
//
// ```text
// 真机截图要靠「窗口切前台 + 屏幕拷贝」（PrintWindow 抓 ANGLE 画面恒为全黑），
// 而这台机器夜里是锁屏状态 ⇒ 屏幕拷贝拿到的是锁屏壁纸，不是应用。
// 多个 agent 并行时，前台窗口也只有一个，会互相抢。
// ```
// ⇒ 改在 flutter_tester 里渲染：不碰屏幕、不抢焦点、锁屏照样能跑。
//
// # 和真机差在哪（如实说明）
//
// ```text
// 字体  flutter_tester 默认只有 Ahem（每个字都是方块）⇒ 这里把系统的
//       微软雅黑注册成主题用到的那几个族名，再加载资产清单里的字体
//       （Material 图标等）⇒ 文字与图标和真机基本一致。
// 网络图  测试环境里 HttpClient 一律 400 ⇒ 网络封面会落到占位图。
// 着色器  液态玻璃等自定义 shader 在 tester 里可能画不出（以实际产物为准）。
// ```
// 非 Windows（CI 的 macOS）上没有 C:\Windows\Fonts ⇒ 自动退回 Ahem，不报错。
//
// # 用法
//
// ```dart
// setUpAll(loadRealFonts);
// testWidgets('...', (tester) async {
//   await setShotViewport(tester, const Size(1440, 900));
//   await tester.pumpWidget(...);
//   await tester.pumpAndSettle();
//   await saveViewShot(tester, 'settings_home');   // => <shotDir>/settings_home.png
// });
// ```
// 输出目录：环境变量 `SOURIN_SHOT_DIR`，缺省 `<系统临时目录>/sourin-shots`。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

bool _fontsLoaded = false;

/// 主题与各页面里实际出现过的字族名 —— 全部指向系统微软雅黑
///
/// `lib/ui/app_theme.dart` 在 Windows 上用 `Microsoft YaHei UI`，回退链是
/// `Microsoft YaHei` / `Noto Sans SC` / `Segoe UI`；其它端用 `Noto Sans CJK SC`。
/// `Roboto` 是 Material 组件不显式给字族时的默认值。
const List<String> _cjkFamilies = <String>[
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'Noto Sans CJK SC',
  'Noto Sans SC',
  'Segoe UI',
  'Roboto',
];

/// 加载真字体（幂等）。放在 `setUpAll` 里调用。
Future<void> loadRealFonts() async {
  if (_fontsLoaded) return;
  _fontsLoaded = true;

  // ① 系统中文字体：常规 + 粗体两个集合（引擎按字重自动挑面）
  const dir = r'C:\Windows\Fonts';
  final files = <File>[
    File('$dir\\msyh.ttc'),
    File('$dir\\msyhbd.ttc'),
  ].where((f) => f.existsSync()).toList();
  if (files.isNotEmpty) {
    final blobs = [
      for (final f in files) ByteData.sublistView(f.readAsBytesSync()),
    ];
    for (final family in _cjkFamilies) {
      final loader = FontLoader(family);
      for (final b in blobs) {
        loader.addFont(Future<ByteData>.value(b));
      }
      await loader.load();
    }
  }

  // ② 资产清单里的字体（MaterialIcons 等）—— 与产物里打包的是同一份
  try {
    final raw = await rootBundle.loadString('FontManifest.json');
    final manifest = json.decode(raw) as List<dynamic>;
    for (final entry in manifest) {
      final m = entry as Map<String, dynamic>;
      final family = m['family'] as String;
      final loader = FontLoader(family);
      for (final font in (m['fonts'] as List<dynamic>)) {
        final asset = (font as Map<String, dynamic>)['asset'] as String;
        loader.addFont(rootBundle.load(asset));
      }
      await loader.load();
    }
  } catch (_) {
    // 清单读不到（极少见）时只缺图标字形，不影响截图本身
  }
}

/// 把测试视口设成指定的**逻辑尺寸**（像素比 1.0，截图像素 = 逻辑像素）
Future<void> setShotViewport(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 截图输出目录（`SOURIN_SHOT_DIR`，缺省系统临时目录下的 sourin-shots）
Directory shotDir() {
  final env = Platform.environment['SOURIN_SHOT_DIR'];
  final path = (env != null && env.trim().isNotEmpty)
      ? env.trim()
      : '${Directory.systemTemp.path}${Platform.pathSeparator}sourin-shots';
  return Directory(path)..createSync(recursive: true);
}

/// 整个视口截图 ⇒ `<shotDir>/<name>.png`，返回落盘的文件
Future<File> saveViewShot(WidgetTester tester, String name) async {
  final view = tester.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  final size = view.size;
  late Uint8List png;
  await tester.runAsync(() async {
    final img = await layer.toImage(Offset.zero & size);
    final bd = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    png = bd!.buffer.asUint8List();
  });
  return _write(name, png);
}

/// 只截某个 `RepaintBoundary`（[finder] 必须命中一个 RepaintBoundary）
Future<File> saveBoundaryShot(
  WidgetTester tester,
  Finder finder,
  String name, {
  double pixelRatio = 1.0,
}) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(finder);
  late Uint8List png;
  await tester.runAsync(() async {
    final img = await boundary.toImage(pixelRatio: pixelRatio);
    final bd = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    png = bd!.buffer.asUint8List();
  });
  return _write(name, png);
}

File _write(String name, Uint8List png) {
  final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  final f = File('${shotDir().path}${Platform.pathSeparator}$safe.png');
  f.writeAsBytesSync(png);
  return f;
}
