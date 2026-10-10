// OPS-8 开关样式改版的**看图台**（自用，不是断言型测试）。
//
// # 为什么要有它
//
// 业主两次反馈「这个 switch 开关样式还是很难看」——「难不难看」写不成断言。
// 断言只能拦住其中**可量化**的那部分（对比度 / 拇指位移 / 颜色来源），
// 那部分在 zz_cr_switch_style_test.dart；这里只负责把改前 / 改后各出一张图，
// 给人眼看。
//
// # 跑法
//
// ```powershell
//   $env:SOURIN_SHOT_DIR = '.probe\shots'
//   flutter test test/zz_cr_switch_shots_test.dart --concurrency=1
// ```
//
// 改前跑一次 → 产物改名 ops8_switch_before_{dark,light}.png；
// 改完再跑一次 → ops8_switch_after_{dark,light}.png。
// 两次**必须是同一个源文件**，否则「改前/改后」不可比。
//
// ⚠️ 本文件故意**不 import 任何产品页面**：页面依赖 FFI 核心，
//    flutter_tester 里跑不起来（worktree 根没有 sourin_core.dll）。
//    开关只吃主题，主题不依赖核心 ⇒ 只 pump 一个 Switch 就够。
//
// ⚠️ 开关很小（52x32 逻辑像素），整屏截图里看不清接缝 ⇒
//    这里对局部 RepaintBoundary 按 3 倍像素比出图，同时把
//    「拇指色 / 轨道色 到底画在哪」用像素扫描打印出来（见 _diag）。
// ignore_for_file: avoid_print — 这个文件的产出就是打印出来的诊断行
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_theme.dart';

import 'support/ui_shot.dart';

bool _noop(bool v) => true;

String _hex(Color c) =>
    '#${c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

/// 一行：左边标签，右边开关。标签用主题前景色（不写死颜色）。
Widget _row(String label, Widget sw, Color fg) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 4),
  child: Row(
    children: [
      SizedBox(
        width: 108,
        child: Text(label, style: TextStyle(fontSize: 13, color: fg)),
      ),
      sw,
    ],
  ),
);

Widget _bench(Brightness b) {
  final c = AppTheme.colorsFor(b);
  final title = b == Brightness.dark ? '深色（午夜）' : '浅色（日间）';
  return Center(
    child: RepaintBoundary(
      key: const ValueKey('bench'),
      // ⚠️ 用 Material 而不是 Container(color:) —— 里面那个 SwitchListTile 的
      //    「背景/水波纹可能不可见」断言会在中间夹一个 ColoredBox 时开火。
      child: Material(
        color: c.background,
        child: Padding(
        padding: const EdgeInsets.all(20),
        child: SizedBox(
          width: 340,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('开关样式 · $title',
                  style: TextStyle(fontSize: 15, color: c.foreground)),
              const SizedBox(height: 6),
              _row('关（OFF）',
                  const RepaintBoundary(
                    key: ValueKey('rb_off'),
                    child: Switch(value: false, onChanged: _noop),
                  ),
                  c.foreground),
              _row('开（ON）',
                  const RepaintBoundary(
                    key: ValueKey('rb_on'),
                    child: Switch(value: true, onChanged: _noop),
                  ),
                  c.foreground),
              _row('禁用 · 关', const Switch(value: false, onChanged: null),
                  c.foreground),
              _row('禁用 · 开', const Switch(value: true, onChanged: null),
                  c.foreground),
              const SizedBox(height: 6),
              // 真机上的样子：列表行里的开关（设置页「开机自动开启」就是它）
              Material(
                type: MaterialType.transparency,
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: true,
                  onChanged: _noop,
                  title: Text('列表里的开关',
                      style: TextStyle(fontSize: 13, color: c.foreground)),
                  subtitle: Text('开启后每次启动程序都自动挂上遥控。',
                      style: TextStyle(fontSize: 12, color: c.mutedForeground)),
                ),
              ),
            ],
          ),
        ),
        ),
      ),
    ),
  );
}

Widget _app(Brightness b) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: AppTheme.themeFor(b),
  home: Scaffold(body: _bench(b)),
);

/// 把某个 RepaintBoundary 光栅化成 RGBA 像素
Future<({Uint8List px, int w, int h})> _raster(
  WidgetTester tester,
  Key key, {
  double pixelRatio = 1.0,
}) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  late Uint8List px;
  late int w;
  late int h;
  await tester.runAsync(() async {
    final img = await boundary.toImage(pixelRatio: pixelRatio);
    w = img.width;
    h = img.height;
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    px = bd!.buffer.asUint8List();
    img.dispose();
  });
  return (px: px, w: w, h: h);
}

/// 扫出「等于某个颜色」的像素簇：数量 + 重心（用于判断拇指到底在哪边）
({int n, double cx, double cy}) _scan(
  ({Uint8List px, int w, int h}) r,
  Color target, {
  int tol = 6,
}) {
  final tr = (target.toARGB32() >> 16) & 0xFF;
  final tg = (target.toARGB32() >> 8) & 0xFF;
  final tb = target.toARGB32() & 0xFF;
  var n = 0;
  var sx = 0.0;
  var sy = 0.0;
  for (var y = 0; y < r.h; y++) {
    for (var x = 0; x < r.w; x++) {
      final i = (y * r.w + x) * 4;
      if ((r.px[i] - tr).abs() <= tol &&
          (r.px[i + 1] - tg).abs() <= tol &&
          (r.px[i + 2] - tb).abs() <= tol) {
        n++;
        sx += x;
        sy += y;
      }
    }
  }
  return (n: n, cx: n == 0 ? -1 : sx / n, cy: n == 0 ? -1 : sy / n);
}

/// 把主题里 switchTheme 对每个状态解析出来的颜色打出来
/// —— 这是「改前/改后到底变了什么」最直接的证据
void _diag(Brightness b) {
  final t = AppTheme.themeFor(b);
  final st = t.switchTheme;
  const off = <WidgetState>{};
  const on = <WidgetState>{WidgetState.selected};
  const offDis = <WidgetState>{WidgetState.disabled};
  const onDis = <WidgetState>{WidgetState.disabled, WidgetState.selected};
  String r(WidgetStateProperty<Color?>? p, Set<WidgetState> s) {
    final c = p?.resolve(s);
    return c == null ? 'null' : _hex(c);
  }

  print('[diag] brightness=${b.name}');
  print('[diag]   colorScheme.primary=${_hex(t.colorScheme.primary)} '
      'surface=${_hex(t.colorScheme.surface)} '
      'onSurface=${_hex(t.colorScheme.onSurface)}');
  for (final e in <String, Set<WidgetState>>{
    'off': off,
    'on': on,
    'off.disabled': offDis,
    'on.disabled': onDis,
  }.entries) {
    print('[diag]   ${e.key.padRight(13)} '
        'thumb=${r(st.thumbColor, e.value)} '
        'track=${r(st.trackColor, e.value)} '
        'outline=${r(st.trackOutlineColor, e.value)} '
        'outlineW=${st.trackOutlineWidth?.resolve(e.value)}');
  }
}

void main() {
  setUpAll(loadRealFonts);

  for (final b in Brightness.values) {
    testWidgets('开关样式看图 · ${b.name}', (tester) async {
      _diag(b);
      await setShotViewport(tester, const Size(520, 460));
      await tester.pumpWidget(_app(b));
      await tester.pumpAndSettle();

      final c = AppTheme.colorsFor(b);
      // 关 / 开 两态各扫一次：拇指色与轨道色分别落在哪个位置
      // 关态槽 = foreground 压 22% 到 background（theme_bridge 里同一个公式）
      final offSlot =
          Color.alphaBlend(c.foreground.withValues(alpha: 0.22), c.background);
      for (final probe in <({Key key, String name, Color thumb, Color track})>[
        (key: const ValueKey('rb_off'), name: 'off', thumb: c.foreground, track: offSlot),
        (key: const ValueKey('rb_on'), name: 'on', thumb: c.primaryForeground, track: c.primary),
      ]) {
        final r = await _raster(tester, probe.key);
        final ts = _scan(r, probe.thumb);
        final ks = _scan(r, probe.track);
        print('[diag]   raster ${probe.name.padRight(3)} '
            'size=${r.w}x${r.h} '
            'thumb(${_hex(probe.thumb)}) n=${ts.n} cx=${ts.cx.toStringAsFixed(1)} | '
            'track(${_hex(probe.track)}) n=${ks.n} cx=${ks.cx.toStringAsFixed(1)}');
      }

      final f = await saveBoundaryShot(
        tester,
        find.byKey(const ValueKey('bench')),
        'ops8_switch_after_${b.name}',
        pixelRatio: 3.0,
      );
      print('[shot] ${f.path} (${f.lengthSync()} B)');
    });
  }
}
