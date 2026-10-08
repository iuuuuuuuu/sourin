// ═══════════════════════════════════════════════════════════════════════
//  方向键归属 —— 谁有权消费它（双门控回归）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守的是什么（2026-09-23 实测抓到的真回归）
//
// 我为了让 TV 遥控器能用空间导航，在 shell 里**无条件**注册了
// `HardwareKeyboard.instance.addHandler(_onGlobalKey)`，对方向键一律
// `return true`（消费掉）。
//
// 但 `HardwareKeyboard` 的 handler 跑在**焦点树派发之前** ——
// 一旦 return true，焦点树永远收不到。于是播放器里
// ```text
// ←/→ 快退快进、↑/↓ 音量（player_page.dart 的 _onKey，原版 ArtPlayer 键位）
// ```
// **全部失效**。真机实测（Android TV，`adb shell input keyevent DPAD_RIGHT`）：
// ```text
// logcat 一行输出都没有 → 播放器完全没收到
// ```
// 而且**没有任何报错** —— 只有真的按键看反馈才发现。
//
// # 原版的规则（`spatialNav.ts` 注释）
//
// > 那些是给**桌面键盘**用的，TV 上方向键应该先被空间导航消费掉。
// > 用 capture + stopPropagation，保证 TV 上方向键不会触发播放器快捷键。
// > **桌面不受影响 —— 因为桌面根本不装这个模块（见调用点）。**
//
// 关键词是**「见调用点」**：原版**有条件安装**，我漏了这层。
//
// # 修法：两层门控
//
// ```text
// ① 设备层 Device.needsFocusRing（= 是 TV）
// ② 页面层 _pageUsesArrowKeys()（= 在播放器）
// ```
// 两者都放行时，方向键才归空间导航。
//
// ⚠️ 光有设备层不够 —— **TV 上播放器也需要方向键**
//    （遥控器快进/音量），所以必须有页面层。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('方向键归属的决策逻辑', () {
    /*
     * 把门控逻辑抽成纯函数来测 —— 不去碰真实的 shell（那要整个 app），
     * 但**语义必须与 shell.dart 里的一致**。
     *
     * ⚠️ 这里刻意用 `expect` 断言**真值表**，而不是复述实现。
     *    真值表是从"谁该拿到方向键"这个需求推出来的，实现怎么变都要满足它。
     */
    bool spatialNavConsumes({
      required bool isTv,
      required bool playerOpen,
      required bool typingInTextField,
    }) {
      // 门控 ①：桌面不启用
      if (!isTv) return false;
      // 门控 ②：播放器自己要用
      if (playerOpen) return false;
      // 门控 ③：输入框里在打字
      if (typingInTextField) return false;
      return true;
    }

    test('桌面（非 TV）→ 空间导航**不**消费方向键（原版：桌面不装这个模块）', () {
      expect(
        spatialNavConsumes(
            isTv: false, playerOpen: false, typingInTextField: false),
        isFalse,
        reason: '桌面必须让方向键归播放器/列表 —— '
            'Windows 实测 `needsFocusRing=false`，'
            '若无条件消费就废掉了桌面键盘的快进/音量。',
      );
    });

    test('TV + 播放器打开 → 空间导航**不**消费（让给播放器快进/音量）', () {
      expect(
        spatialNavConsumes(
            isTv: true, playerOpen: true, typingInTextField: false),
        isFalse,
        reason: 'TV 上播放器也要方向键：←/→ 快退快进、↑/↓ 音量。'
            '若被 shell 消费，真机上按 → 毫无反应（实测过）。',
      );
    });

    test('TV + 不在播放器 → 空间导航消费（首页/详情页选片）', () {
      expect(
        spatialNavConsumes(
            isTv: true, playerOpen: false, typingInTextField: false),
        isTrue,
        reason: '这是空间导航的主战场：首页选片、详情页选剧集。',
      );
    });

    test('TV + 正在输入框打字 → 不消费（让用户移动光标）', () {
      expect(
        spatialNavConsumes(
            isTv: true, playerOpen: false, typingInTextField: true),
        isFalse,
        reason: '搜索框里按 ←/→ 必须是移动光标，不能变成移焦点。',
      );
    });
  });

  test('★ 桌面构建下 shell 的 handler 必须早退（不能只靠注释保证）', () {
    /*
     * 静态断言：`_onGlobalKey` 里必须有设备门控。
     *
     * 光有真值表不够 —— 那测的是"我抽出来的那个函数"，
     * 不能保证 `shell.dart` **真的**按它实现（我第一次修 Material
     * 那个 bug 时就栽在"测了函数本身、没测真实路径"上）。
     */
    final src = _readLib('shell.dart');

    expect(
      src.contains('if (!Device.needsFocusRing) return false;'),
      isTrue,
      reason: '_onGlobalKey 里必须有设备门控 —— '
          '否则桌面键盘的方向键会被空间导航吃掉（真回归，实测过）。',
    );
    expect(
      src.contains('if (_pageUsesArrowKeys()) return false;'),
      isTrue,
      reason: '_onGlobalKey 里必须有页面门控 —— '
          '否则 TV 播放器收不到方向键，快进/音量失效。',
    );
  });

  test('★ 播放器打开标志被正确置位/清除', () {
    final src = _readLib('shell.dart');

    final openCount = RegExp(r'_playerOpen = true;').allMatches(src).length;
    expect(
      openCount,
      greaterThanOrEqualTo(2),
      reason: '两个进播放器的入口（`_openPlayer` 和 `_openLiveChannel`）'
          '都必须置位 `_playerOpen`，否则从直播进播放器时方向键会被抢走。',
    );

    final clearCount = RegExp(r'_playerOpen = false;').allMatches(src).length;
    expect(
      clearCount,
      greaterThanOrEqualTo(2),
      reason: '每个置位都要有对应的清除（`whenComplete`），'
          '否则退出播放器后空间导航永久失效 —— '
          '用户会觉得"从播放器返回后遥控器就坏了"。',
    );
  });
}

String _readLib(String name) {
  // 用 dart:io 读源码做静态断言（与 theme_regression_test 同样的手法）
  return File('lib/$name').readAsStringSync();
}
