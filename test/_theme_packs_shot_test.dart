// 里程碑 2 的视觉自查：把**每一套内置主题**的门面铺开，
// 供 ASCII 渲染 / 像素直方图核对。
//
// ⚠️ 为什么不用真实页面：页面依赖 FFI 核心，跑不起来；
//    而「一套主题长什么样」只需要这些组件就够了。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_palette.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/theme/theme_pack.dart';
import 'support/ui_shot.dart';

bool _noop(bool v) => true;

Widget _gallery(AppPalette p) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('主题门面组件 · 源影',
            style: TextStyle(fontSize: 22, color: p.foreground)),
        const SizedBox(height: 16),
        Text('正文 14px —— 目视字重与行高',
            style: TextStyle(fontSize: 14, color: p.foreground)),
        const SizedBox(height: 4),
        Text('次要文字 mutedForeground',
            style: TextStyle(fontSize: 14, color: p.mutedForeground)),
        const SizedBox(height: 16),
        Row(children: [
          FilledButton(onPressed: () {}, child: const Text('实心')),
          const SizedBox(width: 12),
          ElevatedButton(onPressed: () {}, child: const Text('浮起')),
          const SizedBox(width: 12),
          OutlinedButton(onPressed: () {}, child: const Text('描边')),
          const SizedBox(width: 12),
          TextButton(onPressed: () {}, child: const Text('文字')),
          const SizedBox(width: 12),
          const FilledButton(onPressed: null, child: Text('禁用')),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Container(
            width: 150,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: p.card,
              borderRadius: const BorderRadius.all(Radius.circular(10)),
              border: Border.all(color: p.border),
            ),
            child: Text('Card 描边',
                style: TextStyle(fontSize: 14, color: p.foreground)),
          ),
          const SizedBox(width: 12),
          const SizedBox(
              width: 220,
              child: TextField(
                  decoration: InputDecoration(
                      hintText: '输入框', isDense: true))),
          const SizedBox(width: 12),
          const Switch(value: true, onChanged: _noop),
          const SizedBox(width: 12),
          SizedBox(width: 140, child: Slider(value: 0.6, onChanged: (_) {})),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Chip(
            label: Text('Chip',
                style: TextStyle(fontSize: 14, color: p.foreground)),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: p.card,
              borderRadius: const BorderRadius.all(Radius.circular(10)),
              border: Border.all(color: p.border),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.check_circle_outline,
                  size: 18, color: p.primary),
              const SizedBox(width: 10),
              Text('已加入下载队列',
                  style: TextStyle(fontSize: 14, color: p.foreground)),
              const SizedBox(width: 10),
              Icon(Icons.close,
                  size: 16,
                  color: p.mutedForeground.withValues(alpha: 0.7)),
            ]),
          ),
        ]),
        const Spacer(),
        Text('页脚说明文字',
            style: TextStyle(fontSize: 12, color: p.mutedForeground)),
      ],
    );

void main() {
  setUpAll(loadRealFonts);

  for (final pack in ThemePackStore.builtins) {
    testWidgets('主题 ${pack.id}', (tester) async {
      await setShotViewport(tester, const Size(1440, 900));
      final b = pack.brightness;
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeForPack(b, pack),
        home: Scaffold(
          backgroundColor: pack.palette.background,
          body: Padding(padding: const EdgeInsets.all(28), child: _gallery(pack.palette)),
        ),
      ));
      await tester.pumpAndSettle();
      await saveViewShot(tester, 'theme_${pack.id}');
    });
  }
}
