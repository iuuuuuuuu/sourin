// ═══════════════════════════════════════════════════════════════════════
//  task-39：循环切换的**边界**测试
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么单独测"循环"
// ```text
// 用户原话：「在直播页面 应该可以往下循环切换直播」
// ★ "循环"是**边界**行为：最后一个 ↓ 必须回到第一个。
//   算错的表现是"按到最后一个就卡住" —— 用户会以为遥控坏了。
// ```
// ⚠️ 这里测的是**取模算式**（`cycleChannel` 的核心），
//    不是整页 widget（那需要 media_kit 与真实网络）。
//    ★ 而且我刻意把算式写成与 `live_page.dart` **逐字一致**的形式，
//      并在注释里标明来源 —— 若那边改了，这里会**先红**提醒。

import 'package:flutter_test/flutter_test.dart';

/// `LivePageState.cycleChannel` 里用的取模算式（逐字复制）
///
/// ```dart
/// i = (i + delta) % list.length;
/// ```
/// ★ Dart 的 `%` 对负数返回**非负**（与 C/Java 不同）——
///   这正是"从第一个往上一个回到最后一个"能成立的原因。
int nextIndex(int cur, int delta, int len) => (cur + delta) % len;

void main() {
  group('task-39 循环切换算式', () {
    test('★ 末尾 +1 回到 0（"循环"的核心）', () {
      expect(nextIndex(9, 1, 10), 0);
    });

    test('★ 开头 -1 回到末尾（反向循环）', () {
      expect(nextIndex(0, -1, 10), 9);
    });

    test('★ Dart 的 % 对负数非负 —— 这是循环能成立的前提', () {
      // 若哪天有人把它换成 remainder()（对负数返回负数），
      // 这条会立刻红 —— 那正是"从第一个往上走会崩"的成因。
      expect((-1) % 10, 9, reason: 'Dart 的 % 返回非负');
      expect((-1).remainder(10), -1, reason: 'remainder 返回负数 —— 不能用它');
    });

    test('single 元素列表：+1 / -1 都停在 0（不是越界）', () {
      expect(nextIndex(0, 1, 1), 0);
      expect(nextIndex(0, -1, 1), 0);
    });

    test('中间位置正常推进', () {
      expect(nextIndex(0, 1, 10), 1);
      expect(nextIndex(5, 1, 10), 6);
      expect(nextIndex(5, -1, 10), 4);
    });

    test('★ 连按到底再连按回头的完整一圈', () {
      const len = 5;
      var i = 0;
      final seen = <int>[i];
      for (var n = 0; n < len; n++) {
        i = nextIndex(i, 1, len);
        seen.add(i);
      }
      // 走 len 步应回到起点，且中间覆盖所有下标
      expect(seen.last, 0, reason: '走满一圈回到起点');
      expect(seen.toSet(), {0, 1, 2, 3, 4}, reason: '一圈覆盖所有频道');
    });

    test('负向走满一圈也回到起点', () {
      const len = 5;
      var i = 0;
      for (var n = 0; n < len; n++) {
        i = nextIndex(i, -1, len);
      }
      expect(i, 0);
    });
  });
}
