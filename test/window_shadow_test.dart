// ═══════════════════════════════════════════════════════════════════════════
// 窗口投影（「像 QQ 那种边缘模糊阴影」）的防回退测试
// ═══════════════════════════════════════════════════════════════════════════
//
// # 为什么用"读源码 + 断言结构"而不是 widget 测试
//
// ```text
// 阴影是【Win32 层】的事（独立 WS_EX_LAYERED 窗口 + UpdateLayeredWindow），
// 完全不经过 Flutter 的 widget 树 ⇒ widget 测试看不到它。
// ⇒ 唯一能在 CI 里守住的判据是：**源码里必须存在这几处关键调用**。
// ```
//
// # 用户原话
//
// > 那为什么 qq 就能实现，你不行？你死磕这个问题给解决了
// > 站在窗口有阴影了
//
// # 走过的三条死路（测试里也锁住，防止后人重走）
//
// ```text
// ① 让 DWM 画阴影 —— 本机拿不到（系统级 VisualFXSetting=2）
//    实测：新建全新 WS_OVERLAPPEDWINDOW 窗口，外扩 = (0,0,0,0)
// ② 在窗口【内侧】画投影 —— 结构上不可能对
//    实测：变成"一圈比内容暗 19 级的实色带"，用户明确否掉
// ③ SetWindowRgn 二值裁剪 —— 做不出渐变
// ⇒ ④ 独立 WS_EX_LAYERED 窗口 + UpdateLayeredWindow（本方案）
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 读一个文件并剥掉注释（★ 铁律⑤：grep 必须先剥注释，否则会命中注释里的字面量）
String _codeOf(String path) {
  final raw = File(path).readAsStringSync();
  // 块注释
  var s = raw.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  // 行注释
  s = s.replaceAll(RegExp(r'//[^\n]*'), '');
  return s;
}

void main() {
  group('㊷ 窗口投影：像 QQ 那种边缘模糊阴影', () {
    const shadowCpp = 'windows/runner/window_shadow.cpp';
    const shadowH = 'windows/runner/window_shadow.h';
    const win32Cpp = 'windows/runner/win32_window.cpp';
    const runnerCmake = 'windows/runner/CMakeLists.txt';

    test('★ 阴影实现文件存在（window_shadow.cpp / .h）', () {
      expect(File(shadowCpp).existsSync(), isTrue,
          reason: '阴影实现文件必须存在');
      expect(File(shadowH).existsSync(), isTrue,
          reason: '阴影头文件必须存在');
    });

    test('★★★ CMakeLists 必须把 window_shadow.cpp 加进构建', () {
      final cmake = File(runnerCmake).readAsStringSync();
      expect(cmake.contains('window_shadow.cpp'), isTrue,
          reason: '★ 不加进 CMakeLists 的话，改了这个文件也不会被编译 —— '
              '那是"改了没生效"的经典陷阱');
    });

    test('★★★ 必须用 WS_EX_LAYERED + UpdateLayeredWindow（本方案的核心）', () {
      final code = _codeOf(shadowCpp);
      expect(code.contains('WS_EX_LAYERED'), isTrue,
          reason: '★ UpdateLayeredWindow 的前提');
      expect(code.contains('UpdateLayeredWindow'), isTrue,
          reason: '★ 逐像素 alpha 的唯一途径');
      expect(code.contains('AC_SRC_ALPHA'), isTrue,
          reason: '★ 没有它就没有 alpha 混合，阴影会变成实心黑块');
    });

    test('★★★ 四个扩展样式必须齐全（缺一个就有可感知的副作用）', () {
      final code = _codeOf(shadowCpp);
      // 逐个断言，并说明缺了会怎样
      expect(code.contains('WS_EX_TOOLWINDOW'), isTrue,
          reason: '缺 → 阴影窗口会出现在任务栏/Alt-Tab 里');
      expect(code.contains('WS_EX_NOACTIVATE'), isTrue,
          reason: '缺 → 点阴影会抢焦点，主窗口失焦');
      expect(code.contains('WS_EX_TRANSPARENT'), isTrue,
          reason: '★ 缺 → 鼠标点"窗口边缘外一点"会被阴影吃掉');
      expect(code.contains('WS_POPUP'), isTrue,
          reason: '缺 → 阴影窗口会有标题栏');
    });

    test('★★★ 阴影窗口必须挂到主窗口的【正下方】（Z 序）', () {
      final code = _codeOf(shadowCpp);
      // SetWindowPos 的第二个参数是 hWndInsertAfter —— 传主窗口即"插在它下面"
      final m = RegExp(r'SetWindowPos\s*\(\s*shadow_\s*,\s*main_').firstMatch(code);
      expect(m, isNotNull,
          reason: '★ SetWindowPos 的 hWndInsertAfter 必须传 main_ —— '
              '否则阴影会盖在窗口上面（那样就成了"一层灰纱"）');
    });

    test('★★★ 必须在 WM_WINDOWPOSCHANGED 里更新阴影（跟随移动/缩放）', () {
      final code = _codeOf(win32Cpp);
      expect(code.contains('WindowShadow'), isTrue,
          reason: 'win32_window.cpp 必须接线');
      // 找到 WM_WINDOWPOSCHANGED 那段，确认里面有 Update()
      final idx = code.indexOf('WM_WINDOWPOSCHANGED');
      expect(idx, greaterThan(0), reason: '必须有 WM_WINDOWPOSCHANGED 分支');
      final tail = code.substring(idx, (idx + 600).clamp(0, code.length));
      expect(tail.contains('Update()'), isTrue,
          reason: '★ WM_WINDOWPOSCHANGED 覆盖了拖动/缩放/最大化/贴靠 —— '
              '只在这里调一次 Update() 就能覆盖全部情况');
    });

    test('★★★ 主窗口销毁时必须 Detach（否则留孤儿阴影窗口）', () {
      final code = _codeOf(win32Cpp);
      final idx = code.indexOf('case WM_DESTROY');
      expect(idx, greaterThan(0), reason: '必须有 WM_DESTROY 分支');
      final tail = code.substring(idx, (idx + 500).clamp(0, code.length));
      expect(tail.contains('Detach()'), isTrue,
          reason: '★ 不 Detach 的话，主窗口关掉后屏幕上会留一块阴影');
    });

    test('★★★ 必须有 A/B 开关 SOURIN_WIN_SHADOW（便于对照实验）', () {
      final code = _codeOf(shadowCpp);
      expect(code.contains('SOURIN_WIN_SHADOW'), isTrue,
          reason: '★ 没有开关就无法做"有阴影 vs 无阴影"的对照实验');
      // ★ 必须与 SOURIN_WIN_NOSHADOW 区分开（那是"无边框化"的开关）
      expect(code.contains('SOURIN_WIN_NOSHADOW'), isFalse,
          reason: '★ 两个开关名字必须区分：'
              'SOURIN_WIN_NOSHADOW 是"无边框化"，SOURIN_WIN_SHADOW 是"投影"');
    });

    test('★★★ 位图只在尺寸变化时重建（性能关键）', () {
      final code = _codeOf(shadowCpp);
      // 必须有"尺寸没变就跳过重建"的短路
      final m = RegExp(r'if\s*\(\s*bw\s*!=\s*width_\s*\|\|\s*bh\s*!=\s*height_')
          .firstMatch(code);
      expect(m, isNotNull,
          reason: '★ 高斯模糊 800x600 约 6ms —— 拖动时每帧都跑会卡；'
              '必须有"尺寸没变就复用位图"的短路');
    });

    test('★★★ 不得回退到"窗口内侧画投影"（那条路已被用户否掉）', () {
      final frame = _codeOf('lib/ui/widgets/window_frame.dart');
      // 内侧投影的特征：Padding(EdgeInsets.all(kWindowShadowWidth)) + BoxShadow
      expect(frame.contains('BoxShadow'), isFalse,
          reason: '★ 窗口【内侧】画投影结构上不可能对：'
              '那一圈会被窗口边界硬切 ⇒ 变成"一圈实色边框"。'
              '用户原话：「现在就是一圈实色的边缘，根本就不是阴影」');
    });

    test('★ kWindowShadowWidth 必须为 0（内侧投影已撤销）', () {
      final frame = File('lib/ui/widgets/window_frame.dart').readAsStringSync();
      final m = RegExp(r'const double kWindowShadowWidth = ([\d.]+);')
          .firstMatch(frame);
      expect(m, isNotNull, reason: '常量必须存在（供后人查阅那段记录）');
      expect(m!.group(1), '0',
          reason: '★ 必须是 0 —— 内侧投影已撤销，改回非 0 会重新引入"实色边缘"');
    });
  });
}
