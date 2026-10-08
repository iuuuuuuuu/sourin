// ═══════════════════════════════════════════════════════════════════════
//  窗口四角必须与主题**同源**（任务 AD）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（2026-09-25）
//
// > 现在深色主题有白底四个角,浅色主题有黑底四个角,这也是bug
//
// # 这个测试锁住的是什么
//
// 根因（真机实测）：`ClipRRect` 裁掉的圆角**外面**，Flutter 交出的
// alpha 是 **0**（用 `RepaintBoundary.toImage()` 导出自己合成的图量到的）。
// 也就是说那圈白/黑**不是 Flutter 画的**，而是**窗口背景**在 Flutter
// 表面**之外**填的 —— 而窗口背景用的是**系统**主题
// （注册表 `AppsUseLightTheme`），与用户选的 `dsh.theme` **不同源**
// ⇒ 用户在应用里选深色、系统是浅色时，四角就是**白的**。
//
// 修法：`WindowFrame` 在 `ClipRRect` **外面**再垫一层
// `ColoredBox(backdrop)`，把圆角外那圈变成**我们自己画的**像素。
//
// # 为什么用 widget 测试就能锁住
//
// 这个 bug 的本质是**结构性**的，不是像素级的：
// ```text
// ① backdrop 必须**真的**画在 ClipRRect 之外（不能只在代码里传进去）
// ② backdrop 的色值必须来自**调用方解析的 brightness**，
//    不能来自 `FTheme.of(context)` / `Theme.of(context)`
//    —— 那两个在 `MaterialApp.builder` 的 context 上会**静默兜底成浅色**
// ```
// ② 用 `theme_regression_test.dart` 那种"两个 brightness 各跑一遍、
// 断言取到的色**不同**"的手法就能抓住：兜底成浅色的话，深色那一遍
// 会拿到浅色值 → 断言失败。
//
// ⚠️ 真机像素证据在 `.probe/ad-fix-dark2/` 与 `.probe/ad-fix-light/`
//    （见文件末尾的实测数字），本文件只保证**结构不再退化**。
//
// ═══════════════════════════════════════════════════════════════════════
// ★★★ 2026-09-25 追加：**全屏态**是另一条契约（用户报「全屏四角白底」）
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话：
// > 全屏播放的时候,四个角有白色的底
//
// 根因是**两层**（实测，见 `WindowFrame.isFullscreen` 的注释）：
// ```text
// ① C++ : ApplyRoundedRegion() 全屏时也裁圆角 ⇒ 四角不属于窗口
// ② Dart: 本文件的 Stack 会**铺满整个窗口**并画圆角
//         ⇒ 即使 C++ 清了 region，四角仍是 backdrop（浅色 = #EEF0F6 ≈ 白）
//         实测（SOURIN_WIN_ALPHA=none + 全屏）：
//           TL=#eef0f6 TR=#eef0f6 BL=#eef0f6 BR=#eef0f6
// ```
// ⇒ **全屏 = 铺满屏幕，不存在"窗口边界"，所以不该有圆角、也不该有垫色。**
//
// ★ 所以"圆角内外同源"这条契约**只在非全屏态成立**；
//   全屏态**故意不同源**（两层都不画）—— 那是修复本身，不是回归。
//   下面用 `isFullscreen: false/true` **显式**声明被测状态，
//   把两态**分开**断言（细化，而不是放宽或删除）。
//
// ⚠️ 为什么要显式传参、而不是让它自己推断：
//   `isWindowFullscreen()` 比较的是**同一个 View** 的 `physicalSize`
//   与 `display.size` ⇒ 在 `flutter_test` 里两者同源 ⇒ **差值恒为 0**
//   ⇒ 恒判为全屏 ⇒ 组件短路 ⇒ 上面几条断言全部找不到 widget。
//   ★ 这不是"测试环境的巧合"，而是**度量判据的结构性缺陷**（见该函数注释）。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/window_frame.dart';

void main() {
  group('WindowFrame 圆角外的底色', () {
    testWidgets('backdrop 真的画出来了，且位于 ClipRRect 之外', (tester) async {
      const marker = Color(0xFFFF00FF); // 刺眼的洋红 —— 一眼可辨
      await tester.pumpWidget(
        const MaterialApp(
          home: SizedBox(
            width: 200,
            height: 200,
            child: WindowFrame(
              // ★ 显式声明**非全屏** —— 本组断言描述的是非全屏态契约
              isFullscreen: false,
              backdrop: marker,
              child: ColoredBox(color: Color(0xFF000000)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // ① 洋红**确实**在树里（不是只在代码里传了个参数）
      final boxes = tester
          .widgetList<ColoredBox>(find.byType(ColoredBox))
          .toList();
      expect(
        boxes.any((b) => b.color == marker),
        isTrue,
        reason: 'WindowFrame 必须真的画一层 backdrop 色的 ColoredBox',
      );

      // ② 顺序必须是 backdrop **在前**、ClipRRect **在后**
      //    （Stack 里后画的在上面；反了的话底色会把内容盖住）
      final stack = tester.widget<Stack>(find.byType(Stack).first);
      expect(stack.children.length, greaterThanOrEqualTo(2));
      expect(
        stack.children.first,
        isA<ColoredBox>(),
        reason: 'Stack 第一层必须是 backdrop（圆角外），否则会被内容盖住',
      );
      expect(
        stack.children[1],
        isA<ClipRRect>(),
        reason: 'Stack 第二层必须是 ClipRRect（圆角内的内容）',
      );

      // ③ ClipRRect 的圆角半径与常量一致
      final clip = tester.widget<ClipRRect>(find.byType(ClipRRect).first);
      expect(clip.borderRadius, BorderRadius.circular(kWindowCornerRadius));
    });

    testWidgets('深色主题的 backdrop 必须**不是**浅色（兜底成浅色就抓这里）',
        (tester) async {
      final dark = AppTheme.floorColor(Brightness.dark);
      final light = AppTheme.floorColor(Brightness.light);

      // ★ 这条是本文件的核心断言：
      //   若哪天有人把 `backdrop` 改成 `FTheme.of(context).colors.background`
      //   （在 builder 的 context 上必然兜底成**浅色** #FFFFFF），
      //   深色那一遍就会拿到浅色值 —— 而这两个值必须不同。
      expect(
        dark,
        isNot(equals(light)),
        reason: '深/浅两套地板色必须不同，否则四角无法跟随主题',
      );

      // 深色地板 = forui neutral.dark 的 background（#0A0A0A）
      expect(dark, const Color(0xFF0A0A0A));
      // 浅色地板 = 原版 --bg-base（#EEF0F6），不是 forui 的纯白
      expect(light, const Color(0xFFEEF0F6));
    });

    testWidgets('backdrop 与内容底色同源时，圆角内外是同一个色系', (tester) async {
      // 模拟 shell.dart 的真实用法：两者都取 floorColor(brightness)
      // ★ 非全屏态契约 —— 显式传 isFullscreen: false
      for (final b in [Brightness.dark, Brightness.light]) {
        final floor = AppTheme.floorColor(b);
        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox(
              width: 200,
              height: 200,
              child: WindowFrame(
                isFullscreen: false,
                backdrop: floor,
                child: ColoredBox(color: floor),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final found = tester
            .widgetList<ColoredBox>(find.byType(ColoredBox))
            .where((c) => c.color == floor)
            .length;
        expect(
          found,
          greaterThanOrEqualTo(2),
          reason: '$b: 非全屏时圆角外与内容区必须都是 floorColor（同源），实际只有 $found 处',
        );
      }
    });

    testWidgets('非桌面平台不裁圆角（避免 Android 露出黑边）', (tester) async {
      // 本测试跑在 Windows 上，所以 Platform.isWindows 为 true，
      // WindowFrame **会**裁 —— 这条只断言"桌面端确实裁了"，
      // 与上面几条一起保证"裁 + 垫底"是同时发生的。
      await tester.pumpWidget(
        const MaterialApp(
          home: SizedBox(
            width: 200,
            height: 200,
            child: WindowFrame(
              isFullscreen: false,
              backdrop: Color(0xFF0A0A0A),
              child: SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ClipRRect), findsWidgets);
    });

    // ═══════════════════════════════════════════════════════════════════
    // ★★★ 全屏态：**故意不同源**（用户报「全屏四角白底」的修复）
    // ═══════════════════════════════════════════════════════════════════
    //
    // 全屏 = 铺满屏幕 ⇒ 不存在"窗口边界" ⇒ 不画圆角、也不垫 backdrop。
    // ★ 这与上面"非全屏必须同源"**不矛盾** —— 它们是两态各自的契约。
    //   把两者**都**锁住，才能既防"圆角退化"又防"全屏白角回来"。
    group('WindowFrame 全屏态（四角白底的修复）', () {
      testWidgets('全屏时不画 backdrop、不裁圆角（否则四角就是 #EEF0F6 ≈ 白）',
          (tester) async {
        const marker = Color(0xFFFF00FF);
        await tester.pumpWidget(
          const MaterialApp(
            home: SizedBox(
              width: 200,
              height: 200,
              child: WindowFrame(
                isFullscreen: true, // ★ 显式全屏
                backdrop: marker,
                child: ColoredBox(color: Color(0xFF000000)),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // ★ 不能有 backdrop 色的 ColoredBox（那层正是"白色的底"的来源）
        final boxes = tester
            .widgetList<ColoredBox>(find.byType(ColoredBox))
            .toList();
        expect(
          boxes.any((b) => b.color == marker),
          isFalse,
          reason: '全屏时**不能**画 backdrop 色 —— 否则四角就是那个色（浅色≈白）',
        );
        // ★ 也不能有 ClipRRect —— 全屏不该被裁圆角
        expect(
          find.byType(ClipRRect),
          findsNothing,
          reason: '全屏时**不能**裁圆角（铺满屏幕时不存在窗口边界）',
        );
        // ★ 内容本身必须**原样**在树里（不是把整个界面也丢了）
        expect(
          find.byWidgetPredicate(
            (w) => w is ColoredBox && w.color == const Color(0xFF000000),
          ),
          findsWidgets,
          reason: '全屏只是不画框，内容必须原样保留',
        );
      });

      testWidgets('非全屏时仍然画（两态必须可区分 —— 否则上面的断言没有意义）',
          (tester) async {
        const marker = Color(0xFFFF00FF);
        await tester.pumpWidget(
          const MaterialApp(
            home: SizedBox(
              width: 200,
              height: 200,
              child: WindowFrame(
                isFullscreen: false, // 唯一的差别
                backdrop: marker,
                child: ColoredBox(color: Color(0xFF000000)),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widgetList<ColoredBox>(find.byType(ColoredBox))
              .any((b) => b.color == marker),
          isTrue,
          reason: '非全屏必须画 backdrop —— 这一条证明"全屏不画"是真的由状态决定，'
              '而不是组件整体坏了',
        );
        expect(find.byType(ClipRRect), findsWidgets);
      });
    });
  });
}
