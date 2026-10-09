// ═══════════════════════════════════════════════════════════════════════
//  task-17：底部黑条回归测试 —— MaterialApp 每帧发 dark，我们每帧最后一刀
// ═══════════════════════════════════════════════════════════════════════
//
// 有两个发送者，位于帧内两个不同阶段：
//
//   ① build 阶段 —— material_ui-1.4.0/lib/src/app.dart:1041-1043
//      MaterialApp._themeBuilder 每次 build 都发：
//        SystemChrome.setSystemUIOverlayStyle(
//          theme.brightness == Brightness.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark);
//
//   ② compositeFrame 阶段 —— packages/flutter/lib/src/rendering/view.dart:347-359
//      RenderView.compositeFrame() 里 `if (automaticSystemUiAdjustment) _updateSystemChrome();`
//      而 _updateSystemChrome()（:387-489）读的是**层树**里的
//      AnnotatedRegion<SystemUiOverlayStyle>，那个 region 是 forui 的 FScaffold 挂的
//      （forui-0.27.0/lib/src/widgets/scaffold.dart:109-110），浅色下值为 dark
//      （forui-0.27.0/lib/src/theme/colors.dart:146）。
//
// compositeFrame 是 **persistent frame callback**（rendering/binding.dart:61）⇒ **每帧都跑**，
// 与 SystemUiHost 有没有 rebuild 无关；而 addPostFrameCallback 只在它 rebuild 的那帧排得上队。
// ⇒ 光靠 postFrame 补发，滚动/动画/播放进度这些帧的最后一刀仍然是 forui 的 dark。
//
// 两条内置常量都把导航栏写成纯黑（packages/flutter/lib/src/services/system_chrome.dart:316-330）：
// SystemUiOverlayStyle.dark.systemNavigationBarColor == Color(0xFF000000)；
// 注意它的 statusBarColor 是 **null** ⇒ PlatformPlugin 跳过 setStatusBarColor，
// 所以只有底栏变黑、状态栏没事 —— 这正是真机上观测到的现象。
//
// ★ 为什么必须记账**平台通道**而不是只看 SystemChrome.latestStyle：
//   setSystemUIOverlayStyle 是「待发槽位」语义（system_chrome.dart:746-780）：
//   `if (_pendingStyle != null) { _pendingStyle = style; return; }`。
//   首帧时我们的 initState 排在 MaterialApp._themeBuilder 之后，
//   天然就能覆盖槽位 —— 所以**首帧永远是对的**，bug 只在后续 rebuild：
//   那时 initState 不再跑，只有 dark 写槽位，平台侧就收到 0xFF000000。
//   因此本文件的决定性用例是「重 build 之后」。

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/system_ui.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';

const int kBlack = 0xFF000000;
const int kFloorLight = 0xFFEEF0F6;

void main() {
  group('systemUiOverlayStyleFor —— 纯函数', () {
    test('浅色：两条栏都等于 floorColor(light)，都不是黑', () {
      final s = systemUiOverlayStyleFor(Brightness.light);
      final floor = AppTheme.floorColor(Brightness.light);

      expect(floor, const Color(kFloorLight));
      expect(s.systemNavigationBarColor, floor);
      expect(s.systemNavigationBarColor, isNot(const Color(kBlack)));
      expect(s.systemNavigationBarDividerColor, floor);
      expect(s.statusBarColor, floor);
      expect(s.statusBarIconBrightness, Brightness.dark);
      expect(s.systemNavigationBarIconBrightness, Brightness.dark);
      expect(s.statusBarBrightness, Brightness.light);
      expect(s.systemNavigationBarContrastEnforced, isFalse);
      expect(s.systemStatusBarContrastEnforced, isFalse);
    });

    test('深色：两条栏都等于 floorColor(dark)，也不是黑', () {
      final s = systemUiOverlayStyleFor(Brightness.dark);
      final floor = AppTheme.floorColor(Brightness.dark);

      expect(s.systemNavigationBarColor, floor);
      expect(s.systemNavigationBarColor, isNot(const Color(kBlack)));
      expect(s.statusBarColor, floor);
      expect(s.systemNavigationBarDividerColor, floor);
      expect(s.statusBarIconBrightness, Brightness.light);
      expect(s.systemNavigationBarIconBrightness, Brightness.light);
      expect(s.statusBarBrightness, Brightness.dark);
    });

    test('内置常量确实把导航栏写成纯黑（前提断言，SDK 改了就该红）', () {
      expect(SystemUiOverlayStyle.dark.systemNavigationBarColor, const Color(kBlack));
      expect(SystemUiOverlayStyle.light.systemNavigationBarColor, const Color(kBlack));
    });
  });

  group('SystemUiHost —— 平台通道上不许再出现黑色导航栏', () {
    late List<int?> navCalls;

    void installRecorder(WidgetTester tester) {
      navCalls = <int?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'SystemChrome.setSystemUIOverlayStyle') {
            final m = (call.arguments as Map).cast<Object?, Object?>();
            final v = m['systemNavigationBarColor'];
            navCalls.add(v is int ? v : null);
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
    }

    // SystemChrome 的去重状态是**进程级**的，会跨测试残留：
    // 若 _latestStyle 已经是 floor，我们的下一次发送会被去重掉、
    // 通道上一条记录都没有。先打脏再清账，用例才确定。
    Future<void> dirty(WidgetTester tester) async {
      SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
        systemNavigationBarColor: Color(0xFF123456),
      ));
      await tester.pump();
      navCalls.clear();
    }

    Widget tree({int homeKey = 1, Brightness brightness = Brightness.light}) =>
        MaterialApp(
          theme: brightness == Brightness.light ? ThemeData.light() : ThemeData.dark(),
          builder: (context, child) => SystemUiHost(
            brightness: brightness,
            child: child ?? const SizedBox.shrink(),
          ),
          home: SizedBox(key: ValueKey<int>(homeKey)),
        );

    testWidgets('首帧就把 floor 色发下去', (tester) async {
      installRecorder(tester);
      await dirty(tester);
      await tester.pumpWidget(tree());
      await tester.pump();

      expect(navCalls, isNotEmpty, reason: '首帧必须至少发过一次导航栏颜色');
      expect(navCalls, isNot(contains(kBlack)));
      expect(navCalls.last, kFloorLight);
    });

    testWidgets('★ 重 build（换 home key）之后，平台侧收到的是 floor 而不是黑', (tester) async {
      installRecorder(tester);
      await dirty(tester);
      await tester.pumpWidget(tree());
      await tester.pump();
      expect(navCalls.last, kFloorLight);

      // 这一步会让 MaterialApp._themeBuilder 再跑一次（它会发 dark），
      // 但 SystemUiHost 的 didUpdateWidget 不会触发（亮度没变）。
      // 去掉 build() 里的 postFrame 补发，这里就会收到 0xFF000000。
      navCalls.clear();
      await tester.pumpWidget(tree(homeKey: 2));
      await tester.pump();

      expect(navCalls, isNot(contains(kBlack)),
          reason: '平台通道上出现了黑色导航栏 —— 这就是用户看到的底部黑条');
      expect(SystemChrome.latestStyle!.systemNavigationBarColor, const Color(kFloorLight),
          reason: 'rebuild 后最终生效的样式必须是 floor；变回 0xFF000000 就是那条黑底栏');
    });

    testWidgets('★ 媒体查询变化（重 build）之后，平台侧收到的是 floor 而不是黑', (tester) async {
      installRecorder(tester);
      await dirty(tester);
      await tester.pumpWidget(tree());
      await tester.pump();

      navCalls.clear();
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpAndSettle();

      expect(navCalls, isNot(contains(kBlack)),
          reason: '媒体查询变化会逼 MaterialApp 重发 dark；补发必须赢');
      expect(SystemChrome.latestStyle!.systemNavigationBarColor, const Color(kFloorLight));
    });

    testWidgets('深色主题下也不发黑', (tester) async {
      installRecorder(tester);
      await dirty(tester);
      await tester.pumpWidget(tree(brightness: Brightness.dark));
      await tester.pump();

      expect(navCalls, isNot(contains(kBlack)));
      expect(navCalls.last, AppTheme.floorColor(Brightness.dark).toARGB32());
    });

    testWidgets('亮度切换会重新发对应颜色', (tester) async {
      installRecorder(tester);
      await dirty(tester);
      await tester.pumpWidget(tree(brightness: Brightness.light));
      await tester.pump();
      expect(navCalls.last, kFloorLight);

      navCalls.clear();
      await tester.pumpWidget(tree(brightness: Brightness.dark));
      await tester.pump();

      expect(navCalls, isNot(contains(kBlack)));
      expect(navCalls.last, AppTheme.floorColor(Brightness.dark).toARGB32());
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ★★ 决定性用例：空闲帧（没有任何 widget rebuild）
  // ═══════════════════════════════════════════════════════════════════
  //
  // 前面 5 条用例只覆盖了 **build 阶段**的发送者（MaterialApp._themeBuilder）。
  // 但真机上底栏纹丝不动的那个发送者在 **compositeFrame 阶段**：
  //
  //   RenderView.compositeFrame()            rendering/view.dart:347
  //     → if (automaticSystemUiAdjustment) _updateSystemChrome()   :357-359
  //     → layer!.find<SystemUiOverlayStyle>(...)                    :429/:434
  //
  // 而 FScaffold 挂了一个 AnnotatedRegion<SystemUiOverlayStyle>，浅色下值为 dark
  // （scaffold.dart:109-110 + theme/colors.dart:146）—— 它的导航栏是纯黑。
  //
  // 所以「空闲帧」才是正确的测试形状：树是干净的，没有任何 widget 需要 rebuild，
  // 但 compositeFrame() 照样执行。修复前这一帧会把导航栏刷回 0xFF000000。
  group('★ 空闲帧 —— compositeFrame 的层通道不得再刷黑导航栏', () {
    late List<int?> navCalls;

    void installRecorder(WidgetTester tester) {
      navCalls = <int?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'SystemChrome.setSystemUIOverlayStyle') {
            final m = (call.arguments as Map).cast<Object?, Object?>();
            final v = m['systemNavigationBarColor'];
            navCalls.add(v is int ? v : null);
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
    }

    Future<void> dirty(WidgetTester tester) async {
      SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
        systemNavigationBarColor: Color(0xFF123456),
      ));
      await tester.pump();
      navCalls.clear();
    }

    /// 与生产同形：`SystemUiHost` 在 `MaterialApp.builder` 里（shell.dart:1881-1885），
    /// `FScaffold` 在它下面的页面里（shell.dart:3330）。
    Widget scaffoldTree({int homeKey = 1}) {
      final theme = AppTheme.themeFor(Brightness.light);
      return MaterialApp(
        theme: ThemeData.light(),
        builder: (context, child) => SystemUiHost(
          brightness: Brightness.light,
          child: child ?? const SizedBox.shrink(),
        ),
        home: AppThemeHost(
          data: theme,
          child: AppScaffold(
            key: ValueKey<int>(homeKey),
            child: const SizedBox.expand(),
          ),
        ),
      );
    }

    /*
     * ★ 这条的前提在移除 forui 之后**反转**了
     *
     * 原来这里断言"外壳（forui 的 FScaffold）挂了 `systemNavigationBarColor: 黑`
     * 的 region" —— 因为只有存在这个**竞争者**，下面那几条才能测出
     * 「我们的最后一刀有没有赢」。
     *
     * 现在那层 region 随 forui 一起没了：`AppScaffold` 刻意**不**发
     * `AnnotatedRegion<SystemUiOverlayStyle>` —— 系统 UI 的唯一真相来源
     * 是 `SystemUiHost`，多一个 region 就是多一个静默抢写的可能。
     *
     * ⚠️ 所以判据从「必须有竞争的 region」翻成「**绝不能**有」：
     *    在旧的 forui 外壳下这条会红（那里确实挂了一个），因此它测得出反面。
     */
    testWidgets('★ 外壳不再挂自己的 SystemUiOverlayStyle region（唯一的真相来源是 SystemUiHost）',
        (tester) async {
      await tester.pumpWidget(scaffoldTree());
      await tester.pump();

      final regions = tester
          .widgetList<AnnotatedRegion<SystemUiOverlayStyle>>(
              find.byType(AnnotatedRegion<SystemUiOverlayStyle>))
          .toList();
      expect(
        regions.where((r) =>
            r.value.systemNavigationBarColor == const Color(kBlack)),
        isEmpty,
        reason: '外壳里出现了一条把导航栏按黑的 region —— 系统 UI 必须只有'
            'SystemUiHost 一个真相来源，多写者会在每帧的层通道上互相抢写',
      );
    });

    testWidgets('★ 空闲帧：automaticSystemUiAdjustment 必须是关的（框架文档指定的开关）',
        (tester) async {
      await tester.pumpWidget(scaffoldTree());
      await tester.pump();

      final views = WidgetsBinding.instance.renderViews.toList();
      expect(views, isNotEmpty);
      for (final v in views) {
        expect(
          v.automaticSystemUiAdjustment,
          isFalse,
          reason: 'rendering/view.dart:226-227 —— 「If you want to imperatively set the '
              'system ui style instead, it is recommended that automaticSystemUiAdjustment '
              'is set to false.」没关掉它，层通道每帧都会把 forui 的 dark 推上去',
        );
      }
    });

    testWidgets('★ 空闲帧：平台通道上一条消息都不该有（去重生效，零开销）', (tester) async {
      installRecorder(tester);
      await dirty(tester);
      await tester.pumpWidget(scaffoldTree());
      await tester.pump();
      expect(SystemChrome.latestStyle!.systemNavigationBarColor, const Color(kFloorLight));

      // 关键：强制一帧，且树完全干净（没有任何 widget 需要 rebuild）。
      navCalls.clear();
      tester.binding.scheduleFrame();
      await tester.pump();

      expect(
        navCalls,
        isEmpty,
        reason: '空闲帧出现了平台流量 —— 层通道（forui 的 dark）没被关掉，'
            '或者我们的样式与 _latestStyle 不一致。真机底栏黑条就是这个形状',
      );
      expect(SystemChrome.latestStyle!.systemNavigationBarColor, const Color(kFloorLight),
          reason: '空闲帧之后最终生效的必须是 floor，不能是 0xFF000000');
    });

    testWidgets('★ 空闲帧：即使强制层通道开着，我们的最后一刀也必须赢', (tester) async {
      installRecorder(tester);
      await dirty(tester);
      await tester.pumpWidget(scaffoldTree());
      await tester.pump();

      // 故意把通道重新打开，模拟「关不掉」的最坏情况：
      // compositeFrame 会在本帧先发 forui 的 dark，我们的 persistent 回调随后覆盖槽位。
      // 若哪天有人删掉每帧补发，这条用例会红。
      for (final v in WidgetsBinding.instance.renderViews) {
        v.automaticSystemUiAdjustment = true;
      }
      addTearDown(() {
        for (final v in WidgetsBinding.instance.renderViews) {
          v.automaticSystemUiAdjustment = false;
        }
      });

      navCalls.clear();
      tester.binding.scheduleFrame();
      await tester.pump();

      expect(SystemChrome.latestStyle!.systemNavigationBarColor, const Color(kFloorLight),
          reason: '层通道开着时被 forui 的 dark 抢走了 —— 每帧最后一刀没生效');
      expect(navCalls, isNot(contains(kBlack)),
          reason: '平台通道上出现了黑色导航栏 —— 用户看到的底部黑条');
    });
  });
}
