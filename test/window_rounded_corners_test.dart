// ═══════════════════════════════════════════════════════════════════════
//  任务㉑① 四角"直角阴影"：窗口必须物理裁圆角
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话
//
// > 现在阴影没了,但是**四个角多出来直角阴影**
//
// # 根因（实测，`.probe/corner_atomic.py`）
//
// 窗口是**直角矩形**，四角那块像素**属于我们的窗口**，被
// `window_frame.dart` 的 `ColoredBox(backdrop)` 填成 `#eef0f6`。
// 于是圆角**外面**露出一个方块色 —— 用户看到的"直角阴影"。
//
// ```text
// BEFORE (alpha=none)   四角 owner=OURS   ×3 轮     <-- 方块属于我们（缺陷）
// AFTER  (alpha=region) 四角 owner=behind ×3 轮     <-- 方块不属于窗口（修好）
//                       (8,8) owner=OURS            <-- 没裁过头
// ```
//
// # 为什么必须是 `SetWindowRgn`（而不是"把四角涂透明"）
//
// Win10 上**没有**让窗口局部透明的通用办法，三条路实测：
// ```text
// transparent + 自绘圆角              ❌ Flutter 的 D3D11 swapchain 不给 per-pixel alpha
// DwmExtendFrameIntoClientArea(-1)   ❌ Win10 用【不透明白】填那块 → 变成白角，更糟
// SetWindowRgn                       ✅ 区域外像素【根本不属于窗口】→ 桌面直接透出
// ```
// 原版 `src-tauri/src/rounded_window.rs` 把这三条都试过并得出同样结论，
// 最终选的就是 `SetWindowRgn`（原话：「有台阶但**没有黑框/白底**（选了这个）；
// 圆角平滑但**外面套着一圈底色**（实际观感更差，Owner 也否了）」）。
//
// # 这个测试锁什么
//
// 运行时行为由 `.probe/corner_atomic.py` 实测覆盖（那需要真实窗口）。
// 这里锁**代码形态**，防止后人把默认值改回 `kNone`（= 用户报的缺陷复活），
// 或把 `SetWindowRgn` 的返回值/坐标细节改错。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String stripComments(String s) {
  final noBlock = s.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  return noBlock
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');
}

void main() {
  group('任务㉑① 窗口必须物理裁圆角（否则四角是方块）', () {
    late String raw;
    late String code;

    setUpAll(() {
      raw = File('windows/runner/win32_window.cpp').readAsStringSync();
      code = stripComments(raw);
    });

    test('★★ 默认方案必须是 kRegion（不能是 kNone）', () {
      /*
       * `kNone` = 什么都不做 = 直角窗口 = 用户报的"四个角多出来直角阴影"。
       * 这条断言就是那个缺陷的**回归哨兵**。
       */
      expect(
        code.contains('kDefaultAlphaMode = AlphaMode::kRegion'),
        isTrue,
        reason: '★ 默认必须是 `kRegion`（物理裁圆角）。'
            '改回 `kNone` 会让四角重新变成不透明方块 —— 那正是用户报的缺陷。',
      );
      expect(
        code.contains('kDefaultAlphaMode = AlphaMode::kNone'),
        isFalse,
        reason: '★ 不能默认 `kNone` —— 那等于没修',
      );
    });

    test('★ `SetWindowRgn` 的返回值必须检查（否则 GDI 句柄泄漏）', () {
      /*
       * `SetWindowRgn` 成功 → 区域归系统所有，**不能**删除；
       * 失败 → 区域仍归我们，**必须**删除。
       * 漏掉失败分支的话，每次 resize 泄漏一个 GDI 句柄
       * （`WM_SIZE` 会反复调用这个函数）。
       */
      expect(
        code.contains('if (::SetWindowRgn(window, region, TRUE) == 0)'),
        isTrue,
        reason: '必须检查 SetWindowRgn 的返回值',
      );
      expect(
        code.contains('::DeleteObject(region)'),
        isTrue,
        reason: '★ 失败时必须自己释放 region，否则句柄泄漏',
      );
    });

    test('★ 右/下边界要 +1（CreateRoundRectRgn 是开区间）', () {
      /*
       * 不 +1 会少掉最右一列/最下一行 —— 表现为"窗口右边漏进 1px"。
       * 原版踩过并把结论写进了注释。
       */
      expect(
        code.contains('w + 1') && code.contains('h + 1'),
        isTrue,
        reason: '★ `CreateRoundRectRgn(0, 0, w + 1, h + 1, ...)` —— '
            '右/下是开区间，不 +1 会少一列/一行',
      );
    });

    test('★ 半径要按 DPI 缩放（SetWindowRgn 收物理像素）', () {
      expect(
        code.contains('g_corner_radius * scale * 2.0'),
        isTrue,
        reason: '★ `CreateRoundRectRgn` 的椭圆参数是【直径】，所以要 ×2；'
            '且 SetWindowRgn 用物理坐标，必须先乘 DPI 缩放',
      );
    });

    test('★ 尺寸变化后必须重新应用（否则圆角停在旧尺寸）', () {
      /*
       * region 坐标是**绝对像素**：窗口一大，旧区域就错位了。
       * `WM_SIZE` 里必须重新算。
       */
      final wmSize = code.indexOf('case WM_SIZE');
      expect(wmSize, greaterThan(-1), reason: '找不到 WM_SIZE');
      final seg = code.substring(wmSize, wmSize + 2000);
      expect(
        seg.contains('ApplyWindowAlpha(hwnd)'),
        isTrue,
        reason: '★ `WM_SIZE` 里必须重新应用（region 是绝对坐标，'
            '窗口改尺寸后必须重算，否则圆角区域错位）',
      );
    });
  });

  group('任务㉑① Dart 侧：圆角外那层不要画成不透明方块', () {
    test('★ `WindowFrame` 必须仍然裁内容圆角（与窗口区域半径一致）', () {
      /*
       * 两侧都要圆：
       * ```text
       * 窗口区域（SetWindowRgn）  → 决定【哪些像素属于窗口】
       * ClipRRect               → 决定【内容画到哪儿】
       * ```
       * 只做一样都会在角上露出破绽：
       *   · 只裁窗口  → 内容仍是方的，角上被硬切出直角边（难看）
       *   · 只裁内容  → 角上露出窗口底色（就是用户报的"直角阴影"）
       */
      final src = File('lib/ui/widgets/window_frame.dart').readAsStringSync();
      expect(
        src.contains('ClipRRect('),
        isTrue,
        reason: '内容必须裁圆角',
      );
      expect(
        src.contains('kWindowCornerRadius'),
        isTrue,
        reason: '半径必须走同一个常量 —— 与 C++ 侧保持一致',
      );
    });

    test('★ 半径常量两边必须一致（Dart 10 ↔ C++ 10）', () {
      final src = File('lib/ui/widgets/window_frame.dart').readAsStringSync();
      final cpp = File('windows/runner/win32_window.cpp').readAsStringSync();

      expect(
        RegExp(r'kWindowCornerRadius = (\d+)').firstMatch(src)?.group(1),
        '10',
        reason: 'Dart 侧半径应为 10',
      );
      expect(
        RegExp(r'kDefaultCornerRadius = ([\d.]+)').firstMatch(cpp)?.group(1),
        '10.0',
        reason: '★ C++ 侧半径必须与 Dart 侧一致 —— '
            '不一致会在角上露出"内容圆角"与"窗口圆角"之间的缝',
      );
    });
  });
}
