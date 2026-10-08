// ═══════════════════════════════════════════════════════════════════════
//  窗口背景必须推**透明**给 window_manager（任务㉗⑤）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（2026-09-25）
//
// > 客户端假圆角,四个角都有图1这个直角边,这个需要优化
//
// # 真凶（读 `window_manager` 插件源码定位，不是猜的）
//
// `window_manager-0.5.2/windows/window_manager.cpp:662` 的
// `SetBackgroundColor()` 内部**就是**在调 `SetWindowCompositionAttribute`：
// ```cpp
// bool isTransparent = (A == 0 && R == 0 && G == 0 && B == 0);
// int32_t accent_state = isTransparent ? ACCENT_ENABLE_TRANSPARENTGRADIENT
//                                      : ACCENT_ENABLE_GRADIENT;
// ACCENTPOLICY policy = {accent_state, 2, (A<<24)+(B<<16)+(G<<8)+R, 0};
// SetWindowCompositionAttribute(hWnd, &data);
// ```
// 推**不透明**色 ⇒ `ACCENT_ENABLE_GRADIENT` ⇒ DWM 把
// "被 `SetWindowRgn` 裁掉 / Flutter swapchain 没覆盖"的那块填成那个色
// ⇒ 圆角处是**一圈同色方块** = 用户说的「四个角都有这个直角边」。
//
// 推**全 0**（`Color(0x00000000)`）⇒ `ACCENT_ENABLE_TRANSPARENTGRADIENT`
// ⇒ `nColor = 0` ⇒ DWM **不再着色** ⇒ 方块消失，只剩 Dart `ClipRRect`
// 的抗锯齿圆弧。
//
// # 为什么必须用测试锁住（这个 bug 真的回来过一次）
//
// 修好之后，`window_frame.dart` 在 **08:48** 被改回推 `widget.backdrop`
// （而同一文件的注释仍写着"修法：推 `Colors.transparent`"）——
// **注释说 A，代码做 B**，静态阅读完全看不出来。
// 是代理用受控 A/B（PrintWindow 量窗口背景色：`#000000` vs `#EEF0F6`）
// 才抓到的。那次回退会**静默地**把假圆角带回来。
//
// ⇒ 这条测试就是这个"静默回退"的守卫：它断言**推给插件的值 alpha 必须是 0**。
//
// ⚠️ 它只锁"推什么值"，不锁"插件怎么处理"（那是 C++ 的事，widget 测试
//    到不了）。但**回退的形态恰恰就是"推的值变了"**，所以这条能抓住。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/widgets/window_frame.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// `window_manager` 的方法通道（见插件 `window_manager_plugin.cpp`）
  const channel = MethodChannel('window_manager');

  /// 抓到的 `setBackgroundColor` 调用参数
  final pushed = <Map<Object?, Object?>>[];

  setUp(() {
    pushed.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setBackgroundColor') {
        pushed.add(Map<Object?, Object?>.from(call.arguments as Map));
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('任务㉗⑤ 窗口背景必须推透明（否则 DWM 画出"假圆角"方块）', () {
    testWidgets('推给 window_manager 的 alpha 必须是 0', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SizedBox(
            width: 200,
            height: 200,
            child: WindowFrame(
              // ★ 故意传一个**不透明**的 backdrop：
              //   若实现把 backdrop 原样推给插件，这条就会失败 ——
              //   而那正是"假圆角"回来的形态。
              backdrop: Color(0xFFEEF0F6),
              child: ColoredBox(color: Color(0xFFEEF0F6)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        pushed,
        isNotEmpty,
        reason: 'WindowFrame 必须调用 windowManager.setBackgroundColor —— '
            '一次都没调说明这条链断了',
      );

      final last = pushed.last;
      final a = last['backgroundColorA'] as int?;
      final r = last['backgroundColorR'] as int?;
      final g = last['backgroundColorG'] as int?;
      final b = last['backgroundColorB'] as int?;

      expect(
        a,
        0,
        reason: 'alpha 必须是 0。实测：alpha != 0 ⇒ 插件走 '
            'ACCENT_ENABLE_GRADIENT ⇒ DWM 给窗口背景着色 ⇒ '
            '圆角外出现一圈 #EEF0F6 方块（用户报的"假圆角"）。'
            '实际推的是 ARGB($a, $r, $g, $b)',
      );
      expect(
        [r, g, b],
        [0, 0, 0],
        reason: 'RGB 也必须是 0 —— 插件判据是 '
            '`A==0 && R==0 && G==0 && B==0` 四个**同时**为 0 才算透明。'
            '实际推的是 ARGB($a, $r, $g, $b)',
      );
    });

    testWidgets('backdrop 换成任何颜色，推给 DWM 的仍然是全 0', (tester) async {
      // # 为什么这条断言"不同 backdrop 推同样值"
      //
      // `WindowFrame.backdrop` 是给 **Flutter 层**用的（`Stack` 里那层
      // `ColoredBox`），而推给 `window_manager` 的值是给 **DWM 层**用的。
      // 两层**要求相反**：
      // ```text
      // Flutter 层（backdrop）      → 必须**不透明**（AA 边缘要合成到它）
      // DWM 层（setBackgroundColor）→ 必须**透明**（否则画出"假圆角"方块）
      // ```
      // 原来两层用了同一个值（`backdrop`），这就是 bug 的根源。
      // 所以这条测试锁的是：**DWM 层不受 backdrop 影响，恒为全 0**。
      //
      // ⚠️ 我第一版写的是「backdrop 恰好是全 0 时也必须至少推一次」，
      //    那条**是错的**，理由见下。
      //
      // # 我第一版为什么错（记下来，它很隐蔽）
      //
      // `_pushedBg` 是 **`static`**（`window_frame.dart:208`），
      // 且现在推的是**常量**全 0 ⇒ 语义就是"**每个进程只推一次**"。
      // 所以第二条测试**单独跑会过、跟在第一条后面跑就失败**：
      // ```text
      // Expected: non-empty
      // Actual: []
      // ```
      // 我一开始差点把它当成"去重键有 bug"去改**产品代码** ——
      // 实际是**测试依赖了上一个测试留下的全局状态**（静态污染）。
      // `--plain-name` 单跑通过就是铁证。
      // ⇒ 断言"每次挂载都要推"是**我自己发明的需求**，产品并不需要它：
      //    值是常量，推一次就永远正确。
      await tester.pumpWidget(
        const MaterialApp(
          home: SizedBox(
            width: 200,
            height: 200,
            child: WindowFrame(
              // ★ 故意传一个**不透明**色：若实现把它原样推出去，这条就红
              backdrop: Color(0xFF123456),
              child: ColoredBox(color: Color(0xFF123456)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // ★ 注意：不能断言 `pushed` 非空 —— `_pushedBg` 是静态的，
      //   本文件里前面那条测试可能已经推过、把去重键设好了。
      //   这里只断言"**凡是推过的**，值都是全 0"，与测试顺序无关。
      for (final args in pushed) {
        expect(
          [
            args['backgroundColorA'],
            args['backgroundColorR'],
            args['backgroundColorG'],
            args['backgroundColorB'],
          ],
          [0, 0, 0, 0],
          reason: '不管 backdrop 传什么，推给 DWM 的必须是全 0（透明）',
        );
      }
    });
  });
}
