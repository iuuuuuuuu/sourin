// 无头截图辅助（test/support/ui_shot.dart）的自测
//
// 判据：真字体加载后，拉丁文字宽度必须**明显小于** Ahem（Ahem 每个字形都是
// 1em 见方 ⇒ 20px 的 "Hello" 恰好 100px 宽）。不调 loadRealFonts 时这条必红，
// 所以它测得出反面。非 Windows（没有微软雅黑）时跳过该判据。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/ui_shot.dart';

void main() {
  setUpAll(loadRealFonts);

  testWidgets('真字体生效 + 整页截图落盘', (tester) async {
    await setShotViewport(tester, const Size(480, 240));
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          fontFamily: 'Microsoft YaHei UI',
        ),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Hello', style: TextStyle(fontSize: 20)),
                const Text('源影 · 截图自测 0123', style: TextStyle(fontSize: 20)),
                const Row(children: [
                  Icon(Icons.settings),
                  Icon(Icons.play_arrow),
                  Icon(Icons.download),
                ]),
                FilledButton(onPressed: () {}, child: const Text('确定')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final f = await saveViewShot(tester, 'ui_shot_selftest');
    expect(f.existsSync(), isTrue);
    expect(f.lengthSync(), greaterThan(1000));

    if (Platform.isWindows) {
      final w = tester.getSize(find.text('Hello')).width;
      expect(w, lessThan(80), reason: 'Ahem 下恰为 100px；<80 才说明真字体生效（实测 $w）');
    }
  });
}
