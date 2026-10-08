// ═══════════════════════════════════════════════════════════════════════
//  编排者验收：Android 三端形态判定的**规格真值表**
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要这个（硬指标② 的最后一块）
//
// 硬指标② 要求「一套 Dart 代码覆盖 Windows 桌面 / Android 手机 / Android TV」。
// 已用**真机**验证：Windows 桌面（交付实测 63 项）、Android TV（D-pad 逐页 +
// 冷启动 2170ms）。
//
// # ⚠️ 这个文件验证的是**规格**，不是执行
//
// `Device.detectViaPlatform()` 第一行是
// `if (!Platform.isAndroid) return DeviceKind.desktop;`
// —— 测试跑在 Windows 上，**永远走不到 Android 分支**，mock 平台通道也没用
// （我第一版就是这么写的，实测 4 条全红，返回 desktop）。
//
// 所以这里做的是**规格真值表**：把 `device.dart` 里那段判定的语义逐条复现
// 并断言，**同时断言源码本身仍是那个形状** —— 防止实现漂移而本文件继续绿。
//
// ★ 两种测试都要有，不能互相冒充：
//   · 行为测试（真机）：TV 分支已在 emulator-5554 上验证通过
//   · 规格测试（本文件）：四条分支语义 + 源码形状守卫

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 复现 `device.dart` 里 `detectViaPlatform()` 的判定语义
///
/// ⚠️ 这不是"另写一份实现"——它是**规格的声明**。下面的「源码形状守卫」
/// 会断言生产实现仍是同一形状，两者一起才有意义。
String kindFrom({required bool leanback, required bool touchscreen}) {
  if (leanback) return 'tv'; // ① leanback 是 TV 的定义
  if (!touchscreen) return 'tv'; // ② 没有触摸屏 → TV / 盒子
  return 'touchOnly'; // ③ 有触摸屏 → 手机 / 平板
}

void main() {
  group('★ 三端形态判定 —— 规格真值表（穷举四条分支）', () {
    test('Android TV：leanback=true → tv', () {
      expect(kindFrom(leanback: true, touchscreen: false), 'tv');
    });

    test('★ Android TV 盒子：不声明 leanback 但无触摸屏 → tv', () {
      expect(kindFrom(leanback: false, touchscreen: false), 'tv',
          reason: '没有触摸屏的 Android 就是 TV / 盒子');
    });

    test('★★ 带触摸屏的 TV 模拟器：leanback=true 仍判 tv', () {
      // 本机 emulator-5554 就是这一组合（AVD 同时声明 leanback 与
      // touchscreen，后者是 emulator 的产物）。leanback 优先 → 正确判 TV。
      expect(kindFrom(leanback: true, touchscreen: true), 'tv',
          reason: 'leanback 是 TV 的定义；模拟器的触摸屏不能让它翻盘');
    });

    test('★ Android 手机：有触摸屏、无 leanback → touchOnly', () {
      expect(kindFrom(leanback: false, touchscreen: true), 'touchOnly');
    });

    test('★ 四种组合的完整真值表（无遗漏）', () {
      final table = <String, String>{};
      for (final lb in [true, false]) {
        for (final ts in [true, false]) {
          table['lb=$lb,ts=$ts'] = kindFrom(leanback: lb, touchscreen: ts);
        }
      }
      expect(table, {
        'lb=true,ts=false': 'tv',
        'lb=true,ts=true': 'tv', // ★ 模拟器组合（本机就是它）
        'lb=false,ts=false': 'tv', // ★ 盒子组合
        'lb=false,ts=true': 'touchOnly', // ★ 手机组合
      });
    });

    test('★ 判定顺序不是无关紧要的（反例锁死顺序）', () {
      // 若写成「先判 touch 再判 leanback」，(true,true) 会返回 touchOnly。
      // 本机模拟器正是这个组合 → 顺序错了会把 TV 判成手机，表现为
      // 「焦点环不画 / 字号不放大 / TV 上看不到遥控器提示」。
      String wrongOrder({required bool leanback, required bool touchscreen}) {
        if (touchscreen) return 'touchOnly'; // ← 顺序反了
        return 'tv';
      }

      final correct = kindFrom(leanback: true, touchscreen: true);
      final wrong = wrongOrder(leanback: true, touchscreen: true);
      expect(correct, 'tv');
      expect(wrong, 'touchOnly');
      expect(correct, isNot(wrong),
          reason: '两种顺序结果不同 —— 证明顺序是规格的一部分');
    });
  });

  group('★★ 源码形状守卫（防止实现漂移而本文件继续绿）', () {
    late String src;

    setUpAll(() {
      src = File('lib/core/device.dart').readAsStringSync();
    });

    test('detectViaPlatform 仍存在且是 public static', () {
      expect(src, contains('static Future<DeviceKind?> detectViaPlatform()'));
    });

    test('★ 判定顺序仍是 leanback → touchscreen（不能反）', () {
      final lbIdx = src.indexOf('if (leanback) return DeviceKind.tv;');
      final tsIdx = src.indexOf('if (!touch) return DeviceKind.tv;');
      expect(lbIdx, greaterThan(0), reason: 'leanback 分支必须存在');
      expect(tsIdx, greaterThan(0), reason: 'touchscreen 分支必须存在');
      expect(lbIdx, lessThan(tsIdx),
          reason: '★ leanback 必须在 touchscreen 之前判 —— '
              '反了会把「带触摸屏的 TV」判成手机');
    });

    test('★ 最后一行仍是 touchOnly（手机分支）', () {
      expect(src, contains('return DeviceKind.touchOnly;'));
    });

    test('★ 平台守卫仍在（非 Android 直接 desktop）', () {
      expect(
          src, contains('if (!Platform.isAndroid) return DeviceKind.desktop;'));
    });

    test('★ 通道缺失时返回 null（交给兜底启发式）', () {
      expect(src, contains('return null;'),
          reason: '通道没注册时要让上层兜底，不能硬判');
    });

    test('读的是真实的 platform feature 名', () {
      expect(src, contains("'leanback'"));
      expect(src, contains("'touchscreen'"));
    });
  });

  group('★ DeviceKind 枚举完备性', () {
    test('恰好三端（desktop / touchOnly / tv）', () {
      final src = File('lib/core/device.dart').readAsStringSync();
      final m = RegExp(r'enum DeviceKind \{([\s\S]*?)\n\}').firstMatch(src);
      expect(m, isNotNull, reason: 'DeviceKind 枚举必须存在');
      final body = m!.group(1)!;
      for (final k in ['desktop', 'touchOnly', 'tv']) {
        expect(body, contains(k), reason: '缺少 $k');
      }
    });
  });
}
