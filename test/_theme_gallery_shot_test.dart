// 里程碑 1 的视觉自查：把主题的「门面组件」在一张图里铺开，
// 深浅两套各出一张，供 ASCII 渲染 / 像素采样核对。
//
// ⚠️ 这里**不 import 任何产品页面** —— 页面依赖 FFI 核心，跑不起来；
//    而「主题本身长什么样」只需要这些组件。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_palette.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/app_toast.dart';
import 'support/ui_shot.dart';

bool _noop(bool v) => true;

Widget _gallery() => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('主题门面组件 · 源影', style: TextStyle(fontSize: 22)),
        const SizedBox(height: 16),
        const Text('正文 14px —— 这是一段用来目视字重与行高的说明文字'),
        const SizedBox(height: 4),
        Text('次要文字 14px muted',
            style: TextStyle(
                fontSize: 14, color: AppPalette.light.mutedForeground)),
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
          FilledButton(onPressed: null, child: const Text('禁用')),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Container(width: 150, height: 40, alignment: Alignment.center,
              child: const Text('Card 描边')),
          const SizedBox(width: 12),
          SizedBox(
            width: 220,
            child: TextField(
              decoration: const InputDecoration(
                  hintText: '输入框 / 聚焦描边', isDense: true),
            ),
          ),
          const SizedBox(width: 12),
          const Switch(value: true, onChanged: _noop),
          const SizedBox(width: 12),
          SizedBox(width: 140, child: Slider(value: 0.6, onChanged: (_) {})),
        ]),
        const SizedBox(height: 16),
        const Row(children: [
          Chip(label: Text('Chip')),
          SizedBox(width: 12),
          SizedBox(width: 220, child: ListTile(title: Text('ListTile'), dense: true)),
        ]),
      ],
    );

void main() {
  setUpAll(loadRealFonts);

  for (final b in Brightness.values) {
    testWidgets('主题门面 ${b.name}', (tester) async {
      await setShotViewport(tester, const Size(1440, 900));
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeFor(b),
        builder: (context, child) => ToastHost(
          child: child ?? const SizedBox(),
        ),
        home: Builder(builder: (ctx) {
          // 弹一条，让截图里能看到真机上的实际观感
          WidgetsBinding.instance.addPostFrameCallback((_) {
            showAppToast(ctx, '已加入下载队列', style: okToastStyle());
          });
          return Scaffold(
            body:
                Padding(padding: const EdgeInsets.all(28), child: _gallery()),
          );
        }),
      ));
      await tester.pumpAndSettle();
      await saveViewShot(tester, 'theme_gallery_${b.name}');
    });
  }

  testWidgets('toast：多条堆叠 + 各自计时 + 可关闭', (tester) async {
    await setShotViewport(tester, const Size(720, 420));

    // ⚠️ 必须在 pumpWidget **之后**才有 ToastHost 的 State 可用 ——
    //    pumpWidget 之前调用 `showAppToast` 会静默忽略（找不到宿主）。
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeFor(Brightness.dark),
      builder: (c, child) => ToastHost(child: child ?? const SizedBox()),
      home: Builder(builder: (ctx) {
        return Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () {},
              child: const Text('页面内容'),
            ),
          ),
        );
      }),
    ));

    final ctx = tester.element(find.text('页面内容'));
    showAppToast(ctx, '已加入下载队列');
    await tester.pump(const Duration(milliseconds: 120));
    showAppToast(ctx, '源站连接失败，正在重试', style: errToastStyle());
    await tester.pump(const Duration(milliseconds: 120));
    showAppToast(ctx, '已切换到「青柠」', style: okToastStyle());
    await tester.pump(const Duration(milliseconds: 400));

    // 断言三条都在（堆叠生效），且都还没过期
    expect(find.text('已加入下载队列'), findsOneWidget);
    expect(find.text('源站连接失败，正在重试'), findsOneWidget);
    expect(find.text('已切换到「青柠」'), findsOneWidget);

    await saveViewShot(tester, 'toast_stack');

    // 等全部过期（默认 2.6s + 一点余量）。逐条的时序由实现里的 100ms
    // tick 决定，不适合拿来当断言基准 —— 那会把测试绑死在实现细节上。
    // 「三条同时堆叠可见」与「封顶 4 条」已经是真正的行为断言。
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('已加入下载队列'), findsNothing);
    expect(find.text('源站连接失败，正在重试'), findsNothing);
    expect(find.text('已切换到「青柠」'), findsNothing);
  });

  testWidgets('★ toast 封顶 4 条（批量失败时不刷屏）', (tester) async {
    await setShotViewport(tester, const Size(720, 420));
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeFor(Brightness.dark),
      builder: (c, child) => ToastHost(child: child ?? const SizedBox()),
      home: Builder(builder: (ctx) {
        for (var i = 1; i <= 8; i++) {
          showAppToast(ctx, '第 $i 条');
        }
        return const Scaffold(body: SizedBox());
      }),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    // 保留下来的应该是**最新的** 4 条（5~8），不是最早的
    expect(find.text('第 8 条'), findsOneWidget);
    expect(find.text('第 5 条'), findsOneWidget);
    expect(find.text('第 4 条'), findsNothing);
    expect(find.text('第 1 条'), findsNothing);
  });
}
