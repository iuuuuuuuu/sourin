/*
 * zz_ops20_scope_probe_test.dart —— OPS-20 的**范围取证**（决定修法包到哪一层）
 * ═══════════════════════════════════════════════════════════════════════
 *
 * # 要回答的问题
 *
 * 修法是「给标题栏那一支包一层显式 `DefaultTextStyle`」。但
 * `_TitleBarHost.build` 返回的 `Column` 里**装着 Navigator**
 * （`Expanded(child: ClipRect(child: widget.child))`，`lib/shell.dart:5344`）
 * ⇒ 「包整支」= 也改掉**所有路由**的兜底文字样式。
 *
 * 所以先量清楚：树上每个 `RenderParagraph` 真正生效的 decoration 是什么、
 * 它落在哪一支。兜底样式的特征值 = 下划线 + 纯黄 + 48px + monospace
 * （material_ui-1.6.0/lib/src/app.dart:45-54）。
 *
 * # 分组（顺序要紧！）
 *
 * ```text
 * Navigator 在 _TitleBarHost **里面** ⇒ 先判 Navigator 再判 _TitleBarHost，
 * 否则路由里的东西会被全部误判成「标题栏支内」（第一版就踩了这个）。
 *
 * A 标题栏本体 = 有 _TitleBarHost 祖先 **且** 没有 Navigator 祖先
 * B 路由内容   = 有 Navigator 祖先（无论有没有 _TitleBarHost）
 * ```
 *
 * ⚠️ 本文件**不** import package:flutter/material.dart（与 OPS-20 门禁同一纪律）。
 */

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/shell.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

const Color _kFallbackDecorationColor = Color(0xFFFFFF00);

bool _under(Element e, String typeName) {
  var hit = false;
  e.visitAncestorElements((a) {
    if (a.widget.runtimeType.toString() == typeName) {
      hit = true;
      return false;
    }
    return true;
  });
  return hit;
}

void main() {
  testWidgets('★ 取证：每一支的 Text 到底吃到什么样式', (t) async {
    final oldOnError = FlutterError.onError;
    FlutterError.onError = (details) {};
    await t.pumpWidget(const SourinApp());
    await t.pump();
    FlutterError.onError = oldOnError;
    while (t.takeException() != null) {}
    RemoteBridge.instance.stop();

    final bar = <String>[];
    final routes = <String>[];
    var barFallback = 0;
    var routeFallback = 0;

    for (final el in find.byType(RichText, skipOffstage: false).evaluate()) {
      final ro = el.renderObject;
      if (ro is! RenderParagraph) continue;
      final s = ro.text.style;
      var txt = ro.text.toPlainText().replaceAll('\n', '|');
      if (txt.length > 20) txt = txt.substring(0, 20) + '...';
      final bad = s?.decoration == TextDecoration.underline &&
          s?.decorationColor == _kFallbackDecorationColor;
      final row = (bad ? '★兜底 ' : '  ok   ') +
          'deco=${s?.decoration} dStyle=${s?.decorationStyle} ' +
          'dColor=${s?.decorationColor} size=${s?.fontSize} ' +
          'family=${s?.fontFamily} text="$txt"';
      if (_under(el, 'Navigator')) {
        routes.add(row);
        if (bad) routeFallback++;
      } else if (_under(el, '_TitleBarHost')) {
        bar.add(row);
        if (bad) barFallback++;
      }
    }

    print('[OPS-20 范围] == A 标题栏本体（_TitleBarHost 之下、Navigator 之上）' +
        ' = ${bar.length} 个，其中吃到兜底 = $barFallback');
    for (final r in bar) {
      print('[OPS-20 范围][A] $r');
    }
    print('[OPS-20 范围] == B 路由内容（Navigator 之下）' +
        ' = ${routes.length} 个，其中吃到兜底 = $routeFallback');
    for (final r in routes) {
      print('[OPS-20 范围][B] $r');
    }
    print('[OPS-20 范围] 兜底吃到者总数 = ${barFallback + routeFallback}' +
        '（A=$barFallback / B=$routeFallback）');

    expect(
      routeFallback,
      0,
      reason: 'B 支若吃到框架兜底样式，说明「包住整支」会改到路由的观感 —— '
          '那就要把 DefaultTextStyle 缩到标题栏那一层。',
    );
  });
}