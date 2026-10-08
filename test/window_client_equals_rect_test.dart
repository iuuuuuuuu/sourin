// ═══════════════════════════════════════════════════════════════════════
//  任务⑪ 源码契约：客户区必须等于窗口（`client == window`）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个 bug 的完整故事（值得记住，因为修了三轮才修掉）
//
// 用户报了**三个**看起来无关的问题：
// ```text
// ②「背景怎么有一圈阴影?」          ~7px 边缘渐变
// ⑪「左右下都有,上没有」+「不能拖动放大小」
// ⑰「关闭那个按钮,他是残缺的,没有完整到边边,多出的那部分就是问题」
// ```
// ★ 它们其实是**同一个** bug。判据 `window=1280x800  client=1264x792`
//   （`nonclient=16x8`：左 8 右 8 下 8 上 0）把它一次解释完 ——
//   左 8px 露窗口底色（"阴影"）、右 8px 挤掉自绘关闭按钮（"残缺"）、
//   上 0px（所以"上没有"）。
//
// # 为什么前两轮修不掉
//
// 消息链：
// ```text
// WndProc
//   └─▶ Win32Window::MessageHandler          ← 我们原来的 WM_NCCALCSIZE 代码在这
//         └─▶ FlutterWindow::MessageHandler
//               └─▶ HandleTopLevelWindowProc
//                     └─▶ ★ window_manager 插件的 top-level proc delegate
// ```
// `window_manager` 是**注册的 top-level window proc delegate**，
// 它**先**拿到 `WM_NCCALCSIZE` 并且**直接 `return 0`**（= 已处理）——
// 于是我们 `MessageHandler` 里那段代码**永远执行不到**。
//
// 而插件在 `window_manager_plugin.cpp:165-184`（`title_bar_style_ == "hidden"`，
// 正是 `shell.dart` 用的 `TitleBarStyle.hidden`）里**故意**收缩客户区：
// ```cpp
// sz->rgrc[0].top    += IsWindows11OrGreater() ? 0 : 1;   // ← "上没有"
// sz->rgrc[0].right  -= 8;                                // ← 右 8
// sz->rgrc[0].bottom -= 8;                                // ← 下 8
// sz->rgrc[0].left   -= -8;                               // ← 左 8
// ```
// 这解释了全部现象，也解释了**自愈为什么必然失败**：
// `SelfHealClientArea()` 调 `SetWindowPos(SWP_FRAMECHANGED)` → 又触发
// `WM_NCCALCSIZE` → 又被插件截走并重新 `-8`。自愈每跑一次，
// 就恰好把那个缩小重新施加一次 —— 是一场**必输**的拉锯战。
//
// # 修法
//
// 在 `WndProc` 里**最先**拦下 `WM_NCCALCSIZE(wParam=TRUE)`，
// 保持 `rgrc[0]`（= 整个窗口矩形）并 `return 0`，插件就收不到它了。
//
// ⚠️ 千万别改成用 `GetWindowRect()` 覆盖 `rgrc[0]`：本消息在窗口真正
//    改尺寸**之前**发出，那时拿到的是**旧尺寸**，客户区会被钉死
//    （我第一版就这么写，被 `.probe/resizeprobe.ps1` 抓出来）。
//
// # 本测试为什么是「源码契约」
//
// 真正的验证是**运行期**的（`client == window` 需要真实窗口，单测起不来），
// 已由 `.probe/cursorthread.ps1` + `.probe/resizeprobe.ps1` 实测覆盖：
// ```text
// client==window            : PASS（含连续 5 次 resize，每次都稳定）
// WM_SETCURSOR 8/8          : PASS（↔ ↕ ⤡ ⤢）
// WM_NCHITTEST 5/5          : PASS（无回归）
// ```
// 这里锁住**代码形态**，防止后人（或以后的 agent）把抢占挪回
// `MessageHandler`、或误加 `GetWindowRect` 覆盖 —— 那会让 bug 原地复活。

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
  group('任务⑪ 客户区必须等于窗口（client == window）', () {
    late String raw;
    late String code;
    late String wndProcBody;

    setUpAll(() {
      raw = File('windows/runner/win32_window.cpp').readAsStringSync();
      code = stripComments(raw);

      // 取 WndProc 的函数体（从定义到 MessageHandler 定义之前）
      final start = code.indexOf('Win32Window::WndProc(');
      final end = code.indexOf('Win32Window::MessageHandler(');
      expect(start, greaterThan(-1), reason: '找不到 WndProc 定义');
      expect(end, greaterThan(start), reason: '找不到 MessageHandler 定义');
      wndProcBody = code.substring(start, end);
    });

    test('★ `WM_NCCALCSIZE` 抢占必须写在 WndProc 里（不能在 MessageHandler）', () {
      expect(
        wndProcBody.contains('WM_NCCALCSIZE'),
        isTrue,
        reason: '`window_manager` 插件的 top-level proc delegate 会**先**拿到 '
            '`WM_NCCALCSIZE` 并 return 0（吞掉消息），所以必须写在 `WndProc` 里 '
            '抢先处理。写在 `MessageHandler` 里等于永远不执行 —— '
            '这正是前两轮修不掉的原因。',
      );
    });

    test('★ 抢占里必须 `return 0`（宣告"非客户区为 0"）', () {
      expect(
        wndProcBody.contains('return 0'),
        isTrue,
        reason: '返回 0 = 我已处理（非客户区为 0）。返回别的值会让系统回到默认边框。',
      );
    });

    test('★★ 抢占里**不得**用 GetWindowRect 覆盖 rgrc[0]', () {
      /*
       * `WM_NCCALCSIZE` 在窗口**真正改尺寸之前**发出，
       * 此刻 `GetWindowRect()` 拿到的是**旧尺寸**。
       * 用它覆盖 `rgrc[0]` → 客户区被钉死在旧值 → resize 后
       * 右侧/底部露出窗口底色（而且窗口越大越明显）。
       *
       * 我第一版就是这么写的；正确做法是**保持入参不变**，
       * 因为 `rgrc[0]` 本来就是系统算出的新窗口矩形。
       */
      final ncc = wndProcBody.substring(
        wndProcBody.indexOf('WM_NCCALCSIZE'),
      );
      // 抢占块里不该出现 GetWindowRect（获取 placement 用的是 GetWindowPlacement）
      final upToHandlerCall = ncc.substring(
        0,
        ncc.indexOf('MessageHandler') > 0
            ? ncc.indexOf('MessageHandler')
            : ncc.length,
      );
      expect(
        upToHandlerCall.contains('GetWindowRect'),
        isFalse,
        reason: '★ 抢占块里出现 `GetWindowRect` 是危险信号：本消息早于尺寸变更，'
            '它会拿到**旧尺寸**并让客户区被钉死（resize 后右下露出底色）。'
            '`rgrc[0]` 入参已是新窗口矩形，保持不变即可。',
      );
    });

    test('★ 自愈函数仍以「dwmMargin 与 client 双判据」为准', () {
      /*
       * 两个判据对应两个**不同的**用户可见症状：
       * ```text
       * dwmMargin 不为 0 → 窗口【外】一圈投影（"阴影"）
       * client != window → 窗口【内】一圈色块（"色块"/"按钮残缺"）
       * ```
       * 只用其中一个都会漏（我改过一次只查 dwmMargin，于是色块复现）。
       */
      expect(
        code.contains('margin_ok') && code.contains('client_ok'),
        isTrue,
        reason: '自愈必须同时检查 dwmMargin 和 nonclient —— 只查一个会漏掉另一类症状',
      );
    });

    test('★ `WM_SETCURSOR` 必须为边缘设置缩放光标', () {
      /*
       * 用户原话：「我鼠标移动到边边,并没有出现 可调节的鼠标状态」
       *
       * `WM_NCHITTEST` 返回 `HTLEFT` 只说明"这是缩放边"，
       * 用户**看得出**能缩放靠的是**光标形状**，而光标由 `WM_SETCURSOR` 决定。
       * 本轮之前全项目没有任何 `SetCursor`，窗口类只注册了 `IDC_ARROW`
       * → 光标永远是箭头 → 用户以为不能缩放。
       */
      expect(
        code.contains('WM_SETCURSOR'),
        isTrue,
        reason: '必须处理 WM_SETCURSOR，否则边缘永远是箭头光标',
      );
      for (final id in <String>[
        'IDC_SIZEWE',
        'IDC_SIZENS',
        'IDC_SIZENWSE',
        'IDC_SIZENESW',
      ]) {
        expect(code.contains(id), isTrue, reason: '缺少缩放光标 $id');
      }
      expect(
        code.contains('SetCursor'),
        isTrue,
        reason: '必须真的调用 SetCursor 去设置光标',
      );
    });

    test('★★ `WM_SETCURSOR` 必须把 `HTCLIENT` 交回（别抢 Flutter 的光标）', () {
      /*
       * Flutter 在客户区里自己管光标（文本上是 I 型、按钮上是手型）。
       * 我们若在 HTCLIENT 也强行设箭头，会把 Flutter 的光标全盖掉。
       */
      /*
       * ⚠️ 2026-10-04 修正（本测试曾**假红**一次）：
       *   旧写法是 indexOf('WM_SETCURSOR') 取**首次**出现，再往后开
       *   1400 字符的固定窗口找 HTCLIENT。当时能过，是因为全文件里
       *   WM_SETCURSOR 第一次出现恰好就是下面那个 case 分支。
       *   后来（子窗口子类化那段）在前面插入了一个**真实代码**分支
       *   「} else if (message == WM_SETCURSOR) {」—— 它只处理**缩放带**
       *   （ResizeCursorFor），本来就**不该**有 HTCLIENT；
       *   而真正的「HTCLIENT 交回」在约 3 万字符之后的 case 分支里
       *   ⇒ 固定窗口必然抓不到 ⇒ 假红（产品代码没变差）。
       *   ⇒ 现在**锚在 case WM_SETCURSOR: 标签**上取窗口（那才是
       *     处理消息映射表的地方），并顺带要求它 break 交回。
       */
      final anchor = code.indexOf('case WM_SETCURSOR:');
      expect(
        anchor,
        greaterThan(-1),
        reason: '找不到 case WM_SETCURSOR: 分支 —— 光标映射表被挪走了？',
      );
      final seg = code.substring(
        anchor,
        anchor + 1400 > code.length ? code.length : anchor + 1400,
      );
      expect(
        seg.contains('HTCLIENT'),
        isTrue,
        reason: 'HTCLIENT 必须被单独判断并交回 DefWindowProc，否则会覆盖 '
            'Flutter 自己设的光标（I 型/手型）',
      );
      expect(
        seg.contains('break'),
        isTrue,
        reason: '★ HTCLIENT 命中后必须 break（交回 DefWindowProc）—— '
            '只判断不交回等于没判断',
      );
    });

    test('★ 缩放热区（WM_NCHITTEST）仍返回 HT*（别回归）', () {
      for (final ht in <String>[
        'HTLEFT',
        'HTRIGHT',
        'HTTOP',
        'HTBOTTOM',
        'HTTOPLEFT',
        'HTTOPRIGHT',
        'HTBOTTOMLEFT',
        'HTBOTTOMRIGHT',
      ]) {
        expect(code.contains(ht), isTrue, reason: '缩放热区缺少 $ht');
      }
    });
  });
}
