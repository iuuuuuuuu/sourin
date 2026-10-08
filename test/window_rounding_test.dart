// ═══════════════════════════════════════════════════════════════════════
//  静态审计：窗口圆角必须**同时**去掉非客户区，光设透明不够
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要有这条测试（2026-09-24 实测抓到的真 bug）
//
// 用户报「四个角是黑色」。前几轮都在**Dart 侧**找原因
//（`Colors.transparent`、`ClipRRect`、Impeller 玻璃），全都不对。
//
// 实测「窗口度量」才抓到真根因：
//
// ```text
// WINDOW  1280x800
// CLIENT  1264x792
// ★ 非客户区 = 16 x 8          ← 左8 右8 下8
// GWL_STYLE = 0x14CF0000 → WS_CAPTION=True WS_THICKFRAME=True
// ```
//
// 逐像素（整屏 `CopyFromScreen`）：
// ```text
// 左边 x=0..7   = (10,10,10)   ← 纯黑
// 底边 y=780..791 = (10,10,10) ← 纯黑
// 对角线 +0..+6  = (10,10,10)  ← 纯黑
// ```
//
// **那圈 8px 是 DWM 画的非客户区边框**：不透明、而且**是方的**。
// Dart 的 `ClipRRect` 只能裁到**客户区**，管不到它 ——
// 所以是"圆角内容 + 外面一圈方框"，深色主题下就是**黑角**。
//
// # 关键认识（这条测试要钉住的）
//
// ```text
// 设透明（DwmEnableBlurBehindWindow / WS_EX_LAYERED）  → 改的是**客户区像素**
// 去非客户区（WM_NCCALCSIZE 返回 0 + 去 WS_CAPTION）  → 改的是**窗口框架**
// ```
// **两件事在不同的层**。只做前者，四角永远是黑的。
//
// # 为什么用静态审计而不是 widget 测试
//
// 这是纯粹的 **Win32 行为**，widget 测试里没有真实窗口 ——
// 在测试里 `ClipRRect` 永远是"对的"，测不出真实黑角。
// 能兜住它的只有：把"C++ 侧必须有的那几条"钉死在源码里。
//
// 真实验证另有一条（不在单测里，因为它要求真机+真窗口）：
// 整屏截图 + 四角像素扫描 —— 见报告里的实测数据。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final cppFile = File('windows/runner/win32_window.cpp');

  /// 去掉 `//` 行注释后的代码
  String stripLineComments(String s) {
    final idx = s.indexOf('//');
    return idx >= 0 ? s.substring(0, idx) : s;
  }

  /// 整个 .cpp 的**真代码**（去行注释）
  ///
  /// ⚠️ 必须去注释：本文件里大段注释**引用**了
  ///    `WM_NCCALCSIZE` / `DwmEnableBlurBehindWindow` 这些标识符。
  ///    不去注释的话，即使代码被删掉测试也照样绿（空测试）。
  String codeOnly() {
    final src = cppFile.readAsStringSync();
    return src
        .split('\n')
        .map(stripLineComments)
        // 块注释（/* ... */）里也大量出现这些标识符，一并去掉
        .join('\n')
        .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  }

  group('窗口圆角（runner 侧）审计', () {
    test('前置：win32_window.cpp 存在且带 UTF-8 BOM', () {
      expect(cppFile.existsSync(), isTrue,
          reason: 'windows/runner/win32_window.cpp 不见了？');

      final bytes = cppFile.readAsBytesSync();
      /*
       * ★ BOM 不是洁癖，是**构建能不能过**的问题：
       * `windows/CMakeLists.txt` 有 `/W4 /WX`，MSVC 在中文机器上
       * 默认按代码页 936(GBK) 读源文件 → `warning C4819`
       * → `/WX` 升级为 `error C2220` → **10 个代理一起构建失败**。
       * 本轮已经真实发生过，所以钉进测试。
       *
       * ⚠️ `edit` / `write` 工具保存时会丢 BOM —— 这是最容易复发的一条。
       */
      expect(
        bytes.length >= 3 &&
            bytes[0] == 0xEF &&
            bytes[1] == 0xBB &&
            bytes[2] == 0xBF,
        isTrue,
        reason: '★ win32_window.cpp 丢了 UTF-8 BOM。\n'
            '  MSVC 会按 GBK 读 → C4819 → /WX → error C2220 → 构建全挂。\n'
            '  修复：& powershell -NoProfile -ExecutionPolicy Bypass '
            '-File .probe\\aa_bom.ps1',
      );
    });

    test('★ ① 必须有 WM_NCCALCSIZE 处理，并返回 0 归零非客户区', () {
      final code = codeOnly();

      expect(code.contains('WM_NCCALCSIZE'), isTrue,
          reason: '★ 找不到 `WM_NCCALCSIZE` 处理 ——\n'
              '  实测非客户区 16x8 是四角黑框的**根因**，\n'
              '  必须让它归零（返回 0），客户区才等于整个窗口。');

      // 该分支里必须真的 `return 0`
      final idx = code.indexOf('case WM_NCCALCSIZE');
      expect(idx, greaterThanOrEqualTo(0),
          reason: 'WM_NCCALCSIZE 只出现在别处（比如注释）—— 需要有 case 分支');

      final branch = code.substring(idx, (idx + 1600).clamp(0, code.length));
      expect(branch.contains('return 0'), isTrue,
          reason: '★ `WM_NCCALCSIZE` 分支里没有 `return 0` ——\n'
              '  不返回 0 就等于没归零，非客户区（那圈 8px 黑框）会保留。');
    });

    test('★ ② 必须有 WM_NCHITTEST 自己做缩放热区', () {
      final code = codeOnly();

      expect(code.contains('WM_NCHITTEST'), isTrue,
          reason: '★ 找不到 `WM_NCHITTEST` ——\n'
              '  非客户区归零后，系统认为没有边框，鼠标移到边缘**不再出现缩放光标**、\n'
              '  拖边也缩不了。那等于"为了圆角丢掉缩放"，是不能接受的交互倒退。\n'
              '  必须自己做边缘热区返回 HTLEFT/HTRIGHT/…。');

      // 至少要覆盖四个边 + 四个角
      for (final ht in ['HTLEFT', 'HTRIGHT', 'HTTOP', 'HTBOTTOM']) {
        expect(code.contains(ht), isTrue,
            reason: '★ `WM_NCHITTEST` 里缺少 `$ht` —— 那条边的缩放会失效。');
      }
    });

    test('★ ③ 必须去掉 WS_CAPTION，但**保留** WS_THICKFRAME', () {
      final code = codeOnly();

      /*
       * 实测：只让 WM_NCCALCSIZE 返回 0 **不够** ——
       * `GWL_STYLE` 里的 `WS_CAPTION` 还在，系统仍会为标题栏留空间。
       * 所以必须显式去掉 WS_CAPTION。
       */
      expect(code.contains('WS_CAPTION'), isTrue,
          reason: '★ 找不到对 `WS_CAPTION` 的处理 ——\n'
              '  实测"只让 WM_NCCALCSIZE 返回 0"不生效（非客户区仍 16x8），\n'
              '  因为 WS_CAPTION 还在，系统照样为标题栏保留空间。');

      expect(
        // 清除形式：`style &= ~kDecorationMask`（mask 里含 WS_CAPTION）
        // 或直接 `&= ~WS_CAPTION`
        code.contains('~kDecorationMask') ||
            code.contains('~static_cast<LONG_PTR>(WS_CAPTION)') ||
            code.contains('~WS_CAPTION'),
        isTrue,
        reason: '★ 需要**清除** WS_CAPTION（`style &= ~WS_CAPTION`）——\n'
            '  它才是"要画非客户区"的开关。',
      );

      // 那个 mask 必须**真的**包含 WS_CAPTION（否则清了个寂寞）
      expect(
        RegExp(r'kDecorationMask\s*=\s*[^;]*WS_CAPTION').hasMatch(code) ||
            code.contains('&= ~static_cast<LONG_PTR>(WS_CAPTION)'),
        isTrue,
        reason: '★ 清除用的 mask 里必须含 `WS_CAPTION`。',
      );

      /*
       * ★ 反过来：**不能**把 WS_THICKFRAME 也去掉（默认必须保留）。
       *
       * 去掉它就没有 Aero Snap 了。实测（`.probe/aa-ab1`）：
       * 即便 `WS_CAPTION` 和 `WS_THICKFRAME` **都**去掉，
       * 非客户区**仍然**是 16x8 —— 说明去掉它换不来透明，
       * 却白白丢掉 Snap，所以默认不这么做。
       *
       * ⚠️ 唯一的例外：`SOURIN_WIN_DROP_THICKFRAME=1` 的**对照实验**路径。
       *    那条必须是显式 opt-in（环境变量），不能是默认。
       */
      expect(
        code.contains('g_drop_thickframe'),
        isTrue,
        reason: '★ 去掉 `WS_THICKFRAME` 必须是**环境变量门控的对照实验**\n'
            '  （`SOURIN_WIN_DROP_THICKFRAME`），不能是无条件执行 ——\n'
            '  无条件去掉会丢掉 Aero Snap，而实测收益为零。',
      );

      // 默认值必须是 false（保留 THICKFRAME）
      expect(
        RegExp(r'bool\s+g_drop_thickframe\s*=\s*false').hasMatch(code),
        isTrue,
        reason: '★ `g_drop_thickframe` 的默认值必须是 `false`\n'
            '  （默认保留 WS_THICKFRAME / Aero Snap）。',
      );
    });

    test('★ ④ 必须在"框架重算"时**无条件**重新应用（不能早退）', () {
      final code = codeOnly();

      /*
       * 实测（`.probe/aa-fl1/out.txt`）：
       * ```text
       * #1 nonclient=0x0   changed=1   ← 对了
       * #3 nonclient=0x0   changed=0   ← 还对
       * #4 nonclient=16x8  changed=0   ← ★ window_manager 重算后又回来了
       * ```
       * 根因：`window_manager` 自己会 `SetWindowPos(SWP_FRAMECHANGED)`
       * 触发非客户区重算，把归零结果冲掉。
       * 如果我们的函数"样式位没变就早退"，就再也不会补一次强制重算，
       * 错误状态被**固化**。
       */
      final fnIdx = code.indexOf('ApplyFramelessStyle(');
      expect(fnIdx, greaterThanOrEqualTo(0),
          reason: '找不到 `ApplyFramelessStyle` —— 无边框化必须封装成可重复调用的函数。');

      // 函数体里必须**无条件**调用 SetWindowPos(SWP_FRAMECHANGED)
      final bodyStart = code.indexOf('ApplyFramelessStyle(HWND');
      expect(bodyStart, greaterThanOrEqualTo(0),
          reason: '找不到 `ApplyFramelessStyle(HWND ...)` 的定义');

      final body = code.substring(bodyStart, (bodyStart + 2200).clamp(0, code.length));

      expect(body.contains('SWP_FRAMECHANGED'), isTrue,
          reason: '★ `ApplyFramelessStyle` 里没有 `SWP_FRAMECHANGED` ——\n'
              '  那样式改了也不会让非客户区重算，等于没改。');

      /*
       * ★ 关键：`SetWindowPos(SWP_FRAMECHANGED)` 不能被"是否变了"包住。
       * 检查方式：那句 SetWindowPos 之前不能紧跟一个只改样式位的 if-return 早退。
       * 简化判定：函数体里不允许出现 `if ((style & WS_CAPTION) == 0) return`。
       */
      expect(
        RegExp(r'if\s*\(\s*\(?\s*style\s*&\s*WS_CAPTION\s*\)?\s*==\s*0\s*\)\s*\{?\s*return')
            .hasMatch(body),
        isFalse,
        reason: '★ `ApplyFramelessStyle` 里有"WS_CAPTION 已经没了就 return"的早退。\n'
            '  实测这是**错的**：window_manager 会重新触发非客户区重算把它们变回 16x8，\n'
            '  早退之后我们再也不会补一次强制重算 → 黑框固化。\n'
            '  必须每次被叫到都无条件 SetWindowPos(SWP_FRAMECHANGED)。',
      );
    });

    test('★ ⑤ 必须有重入保护（SWP_FRAMECHANGED 会再次触发窗口消息）', () {
      final code = codeOnly();

      /*
       * `SetWindowPos(SWP_FRAMECHANGED)` → `WM_WINDOWPOSCHANGED`
       * → 我们又调 `ApplyWindowAlpha` → 无限递归。
       * 项目实测过一次递归（另一处），这里必须挡住。
       */
      expect(
        code.contains('g_applying'),
        isTrue,
        reason: '★ 找不到重入保护标志 `g_applying`。\n'
            '  `SetWindowPos(SWP_FRAMECHANGED)` 会触发 `WM_WINDOWPOSCHANGED`，\n'
            '  而我们在那条消息里又调 `ApplyWindowAlpha` → **无限递归**。',
      );
    });

    test('★ ⑥ 最大化时必须放过（否则内容溢出屏幕/盖住任务栏）', () {
      final code = codeOnly();

      /*
       * 最大化时 Windows 会把窗口撑到比工作区大一圈（用来藏边框）。
       * 如果我们强行把非客户区归零，窗口会溢出屏幕、内容被裁掉，
       * 而且会把任务栏盖住 —— 这是无边框窗口最经典的坑。
       */
      expect(
        code.contains('SW_SHOWMAXIMIZED'),
        isTrue,
        reason: '★ 找不到 `SW_SHOWMAXIMIZED` 判定。\n'
            '  最大化时必须走系统默认的非客户区处理，否则窗口溢出屏幕、\n'
            '  内容被裁掉并盖住任务栏。',
      );
    });

    test('★ 反向验证：上面这些判据真的能抓到"只设透明、不去非客户区"的版本', () {
      /*
       * 空测试比没有测试更危险。这里用**修复前**的真实状态验证：
       * 那时只有 Dart 侧的 `Colors.transparent`，runner 侧
       * `WS_EX_LAYERED`/`SetLayeredWindowAttributes`/`DwmEnableBlurBehindWindow`/
       * `SetWindowRgn` 全都是 **0 处**（实测 grep 结果）。
       */
      const beforeFix = '''
LRESULT Win32Window::MessageHandler(HWND hwnd, UINT const message,
                                    WPARAM const wparam,
                                    LPARAM const lparam) noexcept {
  switch (message) {
    case WM_DESTROY:
      return 0;
    case WM_SIZE:
      return 0;
  }
  return DefWindowProc(window_handle_, message, wparam, lparam);
}
''';
      expect(beforeFix.contains('WM_NCCALCSIZE'), isFalse,
          reason: '修复前确实没有 WM_NCCALCSIZE —— 判据①会正确报错');
      expect(beforeFix.contains('WM_NCHITTEST'), isFalse,
          reason: '修复前确实没有 WM_NCHITTEST —— 判据②会正确报错');
      expect(beforeFix.contains('WS_CAPTION'), isFalse,
          reason: '修复前确实没处理 WS_CAPTION —— 判据③会正确报错');
      expect(beforeFix.contains('g_applying'), isFalse,
          reason: '修复前确实没有重入保护 —— 判据⑤会正确报错');

      // 而修复后的形态必须能通过同样的 contains 检查
      final code = codeOnly();
      expect(code.contains('WM_NCCALCSIZE'), isTrue);
      expect(code.contains('WM_NCHITTEST'), isTrue);
      expect(code.contains('WS_CAPTION'), isTrue);
      expect(code.contains('g_applying'), isTrue);
    });

    test('★ ⑦ Dart 侧：WindowFrame 的 ClipRRect 必须保留', () {
      /*
       * 圆角的**可见边缘**由 Dart 画（Skia/Impeller 光栅化器做抗锯齿）。
       * runner 侧的 `SetWindowRgn` 只决定"**哪些像素属于窗口**"。
       * 两者是**不同的层**，缺一不可 —— 见 ⑧ 的说明。
       */
      final frame = File('lib/ui/widgets/window_frame.dart');
      expect(frame.existsSync(), isTrue,
          reason: 'lib/ui/widgets/window_frame.dart 不见了？');

      final src = frame.readAsStringSync();
      expect(src.contains('ClipRRect'), isTrue,
          reason: '★ WindowFrame 必须用 `ClipRRect` 画圆角 ——\n'
              '  那是**抗锯齿**的圆角边缘（Skia/Impeller 光栅化）。\n'
              '  `SetWindowRgn` 是**二值裁剪**，不负责画平滑的边。\n'
              '  两者分工：region 决定"像素属不属于窗口"，\n'
              '            ClipRRect 决定"内容画到哪儿、边缘多平滑"。');
    });

    test('★★ ⑧ 默认必须是 `kRegion`（物理裁圆角）', () {
      final code = codeOnly();

      /*
       * ══════════════════════════════════════════════════════════════════
       * ★★★ 本条曾写反，2026-09-25 任务㉑① 纠正 —— 纠正过程必须留档
       * ══════════════════════════════════════════════════════════════════
       *
       * ## 原先写的（**错的**）
       *
       * ```text
       * expect(code.contains('kDefaultAlphaMode = AlphaMode::kNone'), isTrue,
       *   reason: 'region 是 SetWindowRgn 硬边，项目已否决')
       * ```
       * 理由引用了原版实测「有 SetWindowRgn 时 0 个过渡像素（硬边）」，
       * 于是断定"项目已经否决了它"。
       *
       * ## ★ 真相：**原版选的就是 `SetWindowRgn`**
       *
       * `D:\WishProject\cctv_to_client\src-tauri\src\rounded_window.rs`
       * 文件头白纸黑字：
       * ```text
       * //! 圆角窗口（Windows）—— 用 `SetWindowRgn` **物理裁角**
       * //! **Windows 10 上没有"让窗口局部透明"的通用办法。**
       * //! 既然圆角外那圈透不出桌面，就**别让那块像素属于窗口**
       * //!
       * //! | ① transparent + CSS 圆角      | ❌ 没有 WS_EX_LAYERED，圆角外只能是窗口底色 |
       * //! | ② DwmExtendFrameIntoClientArea | ❌ Win10 用【不透明白】填充 → 更糟        |
       * //! | ③ SetWindowRgn 物理裁角        | ✅ 区域外像素**根本不属于窗口**            |
       * ```
       * 而且原版**明确权衡过**这个代价（L77-79）：
       * ```text
       * //! 这是**当前方案固有**的代价，不是 bug。权衡过：
       * //!   · 有台阶但**没有黑框/白底**（选了这个）
       * //!   · 圆角平滑但**外面套着一圈底色**（实际观感更差，Owner 也否了）
       * ```
       * **被否决的是 ① 和 ②，不是 ③。** 原版"接受硬边台阶"换"不套底色"。
       *
       * ## 我们这边的实测（`.probe/corner_raw.py` + `corner_atomic.py`）
       *
       * ```text
       * mode=none    WindowFromPoint(左上角) = OURS     ← 方角**属于我们**（缺陷）
       *              角像素 = #eef0f6（WindowFrame 的 ColoredBox backdrop）
       * mode=region  WindowFromPoint(左上角) = behind   ← 方角**不属于窗口**
       *              GetWindowRgn 有区域，包围盒 (0,0)-(1280,800)
       *              连续 3 轮一致（`.probe/corner_atomic.py` 3/3 PASS）
       * ```
       * `kNone` 正是用户报的「四个角多出来**直角阴影**」——
       * 那圈 `#eef0f6` 方块就是我们的 `ColoredBox(backdrop)`。
       *
       * ## 结论
       *
       * ```text
       * kRegion  = 角是"桌面透出来"，没有方块   ← 用户要的
       * kNone    = 角是"我们的 backdrop 方块"    ← 用户报的缺陷
       * ```
       * ⚠️ 顺带纠正一处**测量错误**（写在这里防止后人重犯）：
       *    我曾用"屏幕截图的角像素颜色"判断，但**背景恰好有个同色窗口**
       *    （另一个 Tauri 应用 #eef0f6），导致 none/region 两轮看起来一样。
       *    **唯一可靠的判据是"那个像素属不属于我们的窗口"**
       *    （`WindowFromPoint` / `PtInRegion`），不是颜色。
       */
      expect(
        code.contains('kDefaultAlphaMode = AlphaMode::kRegion'),
        isTrue,
        reason: '★ 默认必须是 `kRegion`（物理裁圆角）。\n'
            '  原版选的就是它（`rounded_window.rs` 文件头）；\n'
            '  Owner 明确否掉的是"圆角外**套一圈底色**"那个方案 ——\n'
            '  而那正是 `kNone` 的效果（= 用户报的"直角阴影"）。',
      );
      expect(
        code.contains('kDefaultAlphaMode = AlphaMode::kNone'),
        isFalse,
        reason: '★ **不得退回 `kNone`** —— 那会重现用户报的'
            '「四个角多出来直角阴影」（角像素属于窗口、被 backdrop 填成方块）。',
      );

      // 保留原有的形态要求：SetWindowRgn 仍须被环境变量门控（可复测）
      if (code.contains('SetWindowRgn')) {
        expect(code.contains('"region"'), isTrue,
            reason: '`SetWindowRgn` 必须仍然可以被环境变量开关复测 ——\n'
                '（A/B 对照是本次定位根因的关键手段）');
      }
    });

    test('★★ ⑧b 实测无效的方案**仍然不能**当默认（保留那条真原则）', () {
      final code = codeOnly();

      /*
       * ★ 这条是原 ⑧ 里**真正成立**的那半句，必须保留：
       *
       * > 把一个"其实是 no-op"的方案写成默认值是**误导**。
       *
       * 实测（同位置 none vs blur 的客户区像素**逐字节一致**）：
       * ```text
       * blur        ❌ 无效（Flutter 的 D3D11 swapchain 不给 per-pixel alpha）
       * blurframe   ❌ 无效（Win10 的扩展框架区**不是**逐像素透明，
       *                     DWM 用不透明白填充 → 四角从黑框变白底，更糟）
       * colorkey    ❌ 无效（不是分层窗口，LWA_COLORKEY 无从生效）
       * ```
       * 这三个**依旧不能**是默认值。
       *
       * ⚠️ 与 `kRegion` 的区别：`kRegion` **不是** no-op ——
       *    它的效果可实测（`GetWindowRgn` 有区域、角像素不再属于窗口）。
       *    判断标准是"**有没有可观测的效果**"，不是"名字听起来像不像 hack"。
       */
      for (final bad in <String>[
        'kDefaultAlphaMode = AlphaMode::kBlur',
        'kDefaultAlphaMode = AlphaMode::kBlurFrame',
        'kDefaultAlphaMode = AlphaMode::kColorKey',
      ]) {
        expect(
          code.contains(bad),
          isFalse,
          reason: '★ `$bad` 不能当默认 —— 实测该方案是 **no-op**，\n'
              '  把 no-op 写成默认值会让后人以为"已经在处理透明了"，\n'
              '  实际上是**误导**（DWM 调用返回成功但毫无视觉效果）。',
        );
      }

      // 默认值必须恰好是一个（防止出现两个 constexpr 定义）
      final defaults =
          RegExp(r'kDefaultAlphaMode = AlphaMode::(\w+)').allMatches(code);
      expect(defaults.length, 1,
          reason: '★ `kDefaultAlphaMode` 必须**只有一个**定义 —— '
              '出现多个会让"当前默认是什么"变得不确定');
    });

    test('★ ⑨ 无边框化必须**默认关闭**（实测零收益且有风险）', () {
      final code = codeOnly();

      /*
       * 实测（DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)）：
       * ```text
       * 无边框化 关  可见非客户区 = 左1 上0 右1 下1
       * 无边框化 开  可见非客户区 = 左2 上0 右2 下2
       * ```
       * 去掉 WS_CAPTION **没有减小可见边框** —— 那个"16x8"里绝大部分
       * 是 Win10 的**隐形**缩放边框（本来就不显示）。
       * 零收益 + 自实现热区/最大化特判的风险 ⇒ 默认必须关。
       */
      expect(
        RegExp(r'bool\s+g_frameless\s*=\s*false').hasMatch(code),
        isTrue,
        reason: '★ `g_frameless` 默认必须是 `false`。\n'
            '  实测：开与关的**可见**非客户区几乎一样（1px vs 2px），\n'
            '  而开启要付出"自实现缩放热区 + 最大化特判"的代价。',
      );
    });

    test('★ ⑩ 采样四角必须用 DWM 可见矩形（不能用 GetWindowRect）', () {
      /*
       * ★ 这是我本轮**最大的测量错误**，必须钉住防止后人重犯。
       *
       * `GetWindowRect` 比窗口的**可见**区域大一圈：
       * ```text
       * GetWindowRect               (300,200) 1280x800
       * DWM EXTENDED_FRAME_BOUNDS   (307,200) 1266x793
       * 隐形边框 = 左7 上0 右7 下7
       * ```
       * 那 7px 是 Win10 给可缩放窗口预留的**隐形抓取边框**
       *（不显示、不参与视觉）。
       *
       * 拿 `GetWindowRect` 做起点逐像素扫四角 → 前 7 个样本其实
       * 落在**窗口之外**（桌面/阴影），于是得出"四角是黑的"
       * 这种**采样错误**的结论。
       *
       * 这条测试无法直接验证 PowerShell 脚本（不在 lib/ 里），
       * 所以改为**记录结论**：验证 probe 脚本里确实用了
       * DwmGetWindowAttribute。
       */
      final probe = File('.probe/aa_probe.ps1');
      if (!probe.existsSync()) {
        // 探针脚本是可选的交付物；不存在就跳过（不制造假失败）
        return;
      }
      final src = probe.readAsStringSync();
      expect(
        src.contains('DwmGetWindowAttribute'),
        isTrue,
        reason: '★ 四角取样的探针必须用 `DwmGetWindowAttribute`\n'
            '  （`DWMWA_EXTENDED_FRAME_BOUNDS`）拿**可见**边界。\n'
            '  用 `GetWindowRect` 会让前 7px 采到窗口外的桌面，\n'
            '  得出"四角全黑"的错误结论 —— 本轮真实踩过。',
      );
      expect(
        src.contains(r'$Tag-visible.rect') || src.contains('-visible.rect'),
        isTrue,
        reason: '★ 探针要把**可见矩形**单独写一份供四角分析使用。',
      );
    });
  });
}
