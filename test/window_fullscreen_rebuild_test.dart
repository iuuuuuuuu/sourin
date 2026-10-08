// ═══════════════════════════════════════════════════════════════════════
//  task-54：WindowFrame 必须在**窗口尺寸变化时重建**
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户报的现象（第二次报；第一次"修了"但没修好）
//
// > 3.播放器页面进入全屏,四个角还是白色的底
//
// # 根因（同一个二进制的 A/B 实测确证，`.probe/t54_dep_ab.py`）
//
// ```text
// 组 dep0（不读 MediaQuery）：[WINDOWFRAME#] 行数 = 1
//     #1 physical=1280x800 => fullscreen=false
//     真实屏幕四角 TL=#eef0f6 TR=#eef0f6  ⇒ ★ 白角 2/4（复现用户现象）
// 组 dep1（读  MediaQuery）：[WINDOWFRAME#] 行数 = 2
//     #2 physical=2560x1440 => fullscreen=true
//     真实屏幕四角 TL=#202023 TR=#735945 ⇒ 白角 0/4（正常）
// ```
//
// ★ **build 次数 1 vs 2 就是铁证** —— 它把"值对不对"与"**有没有被重新求值**"
//   分开了：
// ```text
// `View.of(context)`           = 静态查表 ⇒ **不注册 InheritedWidget 依赖**
//                              ⇒ 窗口 resize **不会**调度本 widget 重建
// `MediaQuery.sizeOf(context)` = dependOnInheritedWidgetOfExactType
//                              ⇒ ★ 注册依赖 ⇒ resize **会**重建
// ```
// 而 `isWindowFullscreen()` **只在 build 时**被求值一次
// ⇒ **判据的数学一直是对的，但它从未在全屏之后被重新调用过**。
//
// # 为什么用 `debugBuildCount`（而不是"看界面变没变"）
//
// 本 bug 的本质是 **`build()` 没被重新调用** —— 而"没被调用"**没有行为差异**
// （界面就停在旧状态）。所以必须有**计数器**才能区分：
// ```text
// ① 重建了、但判据仍 false  ⇒ 判据/来源的问题
// ② 根本没重建              ⇒ ★ 依赖注册的问题（本次的真根因）
// ```
//
// ⚠️ 铁律 204：**诊断代码必须与被测路径等价**。
//    我加的第一版诊断**读了 MediaQuery** ⇒ 自己注册了依赖 ⇒ **把 bug 掩盖了**。
//    这正是"带诊断时正常、去掉诊断就坏"的指纹。
//    `debugBuildCount` 只自增、**不注册任何依赖** ⇒ 它不改变被测行为 ✓
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/widgets/window_frame.dart';

/// 屏幕尺寸（`display`）与窗口尺寸分开设置，才能造出"窗口 != 屏幕"。
///
/// ⚠️ `flutter_test` 里 `TestFlutterView.displaySize` **不可设**
///    （`display` 是引擎侧只读视图）⇒ 无法伪造"屏幕 2560x1440 + 窗口 1280x800"。
///    ⇒ 所以本测试**不测"判据的真假"**（那需要真机，见 `t54_dep_ab.py`），
///      而是测**"尺寸变化会不会触发重建"** —— 那正是本次根因所在，
///      而且它**不依赖 display 与 physicalSize 的差异**。
const Size kA = Size(1280, 800);
const Size kB = Size(2560, 1440);

void main() {
  group('task-54 WindowFrame 必须随窗口尺寸重建（全屏四角白底的修复）', () {
    setUp(() => WindowFrame.debugBuildCount = 0);

    Future<void> pump(WidgetTester tester, Size window) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = window;
      await tester.pumpWidget(
        const MaterialApp(
          home: SizedBox(
            width: 200,
            height: 200,
            child: WindowFrame(
              backdrop: Color(0xFFEEF0F6),
              child: ColoredBox(color: Color(0xFF000000)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('前置：首帧必须 build 至少一次', (tester) async {
      await pump(tester, kA);
      expect(
        WindowFrame.debugBuildCount,
        greaterThan(0),
        reason: '首帧必须建立并 build 一次',
      );
    });

    testWidgets('★★★ 决定性：只改**窗口尺寸** ⇒ 必须再次 build（锁住依赖注册）',
        (tester) async {
      // ① 以"窗口态"渲染
      await pump(tester, kA);
      final before = WindowFrame.debugBuildCount;
      expect(before, greaterThan(0), reason: '前置：首帧应 build');

      // ② ★ 只改窗口尺寸（模拟进入全屏）——**不改 widget 树**
      //
      //    ⚠️ 注意：这里**不**重新 pumpWidget，只改 view 的 metrics 再 pump，
      //       所以树的身份不变 ⇒ 唯一能让 build 再跑的原因就是
      //       **组件注册了尺寸依赖**。
      tester.view.physicalSize = kB;
      await tester.pump();
      await tester.pumpAndSettle();

      expect(
        WindowFrame.debugBuildCount,
        greaterThan(before),
        reason: '★★ 窗口尺寸变化后**必须重新 build**。'
            '若计数没增加 ⇒ WindowFrame 没有注册尺寸依赖 ⇒ '
            '`isWindowFullscreen()` 不会被重新求值 ⇒ task-54 的根因复发。'
            '修法是 `build()` 里那次 `MediaQuery.maybeSizeOf(context)` 读取，'
            '⚠️ 它看起来冗余（`View.of` 已能拿尺寸）但**不能删**。',
      );
    });

    testWidgets('★ 反向：尺寸变回去也必须再次 build', (tester) async {
      await pump(tester, kB);
      final before = WindowFrame.debugBuildCount;

      tester.view.physicalSize = kA;
      await tester.pump();
      await tester.pumpAndSettle();

      expect(
        WindowFrame.debugBuildCount,
        greaterThan(before),
        reason: '退出全屏（尺寸变小）同样必须重新求值，否则内容会被永久裁掉',
      );
    });

    testWidgets('★ 尺寸**没变**时不该反复 build（防"每次都重建"的过度修复）',
        (tester) async {
      await pump(tester, kA);
      final before = WindowFrame.debugBuildCount;

      await tester.pump();
      await tester.pump();

      expect(
        WindowFrame.debugBuildCount,
        before,
        reason: '尺寸没变时不该重复 build（否则是过度重建，白耗性能）',
      );
    });

    testWidgets('窗口态：有 ClipRRect + backdrop（圆角观感不能退化）',
        (tester) async {
      await pump(tester, kA);
      expect(find.byType(ClipRRect), findsWidgets, reason: '窗口态必须裁圆角');
      expect(
        tester
            .widgetList<ColoredBox>(find.byType(ColoredBox))
            .any((b) => b.color == const Color(0xFFEEF0F6)),
        isTrue,
        reason: '窗口态必须画 backdrop（圆角外的垫色）',
      );
    });
  });
}
