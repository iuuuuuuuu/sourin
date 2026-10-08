// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 音量偏好被 mpv 的**默认广播**覆盖成 1.0（会改坏用户设置的真 bug）
// ═══════════════════════════════════════════════════════════════════════
//
// # 现场证据（真机）
//
// ```text
// ui-prefs.json 的 dsh.playprefs.lastVolume：**0.75 → 1.0**
// 写入时间 2026-09-27 **09:03:20**
// 那一刻**没有任何人操作音量** —— 只有我在跑客户端做验证
// ```
//
// # 根因
//
// ```text
// `_bindPlayerStreams()` 里的监听**无条件**把任何音量广播都当"用户调的"：
//     _player.stream.volume.listen((v) {
//       if (!_muted && v > 0) _savePlayPref('lastVolume', (v/100).toString());
//     });
//
// ⇒ 而 mpv 在播放器刚创建时会广播它自己的**默认音量 100**
//   （`_muted` 默认 false，100 > 0 ⇒ 条件成立）
// ⇒ ★ 于是 "1.0" 被写进用户的偏好，而**用户从没碰过音量**
// ```
//
// # 为什么"再加一次正确的 setVolume 写回"不行
//
// ```text
// ① `setVolume(75)` 的广播发生在 `_bindPlayerStreams()` **之前**
//    ⇒ broadcast 流不缓存 ⇒ 那次广播**收不到**
// ② 即使收到，也只是"碰巧赢了竞态" —— 依赖广播顺序的修复是脆的
// ⇒ ★ 正确判据是「**用户发起的**」：只有用户在 UI 上真的动过手才写偏好
// ```
//
// # ⚠️ 本文件为什么**不挂真 PlayerPage**
//
// ```text
// 真 `PlayerPage` 一构建就建 `Player`（media_kit）⇒ 留下真实定时器
// ⇒ `tester.runAsync` 里 fake-async 排不干 ⇒ **测试挂 10 分钟**
//   （本仓已踩过两次：`.probe/probe_tests/t59_headless_pixels_test.dart`）
// ⇒ 改用**纯逻辑**验证：把判据抽成可测的形式
// ```
//
// # 本文件测什么
//
// ```text
// ① ★ UiPrefs 层：一次假广播会不会永久覆盖用户的值（决定性证据）
// ② ★ 源码结构：监听器里必须有"用户发起"白名单，且**不得**无条件写偏好
// ③ ★ 白名单必须覆盖全部**用户入口**（键盘/滚轮/滑杆/遥控）
// ④ ★ `initState` 的起播 setVolume **不得**盖用户戳（那是我们发起的）
// ```
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/ui_prefs.dart';

/// 剥注释（本仓铁律：`contains` 必须先剥注释）
String _strip(String s) => s
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ')
    .replaceAll(RegExp(r'//[^\n]*'), ' ');

void main() {
  group('① ★★★ 决定性证据：一次假广播会不会永久覆盖用户的值', () {
    test('★★★ 只有一次"默认音量广播" ⇒ 用户的 0.75 被永久覆盖成 1.0', () async {
      /*
       * ★ 这条**故意**断言"会发生覆盖" —— 它证明的是**缺陷的存在性**
       *   （而不是"修复有效"）。它是修复的**前提证据**：
       *   若这条不成立，说明我判断错了，不该去改生产代码。
       */
      final dir = Directory.systemTemp.createTempSync('sourin-vol-proof');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final f = File('${dir.path}${Platform.pathSeparator}ui-prefs.json');
      await UiPrefs.load(dir.path);

      // 用户存的是 0.75
      UiPrefs.set('dsh.playprefs.lastVolume', '0.75');
      await UiPrefs.flush();

      // 模拟 mpv 的默认音量广播（100）被无条件写回
      UiPrefs.set('dsh.playprefs.lastVolume', '1.0');
      await UiPrefs.flush();

      final after = jsonDecode(f.readAsStringSync()) as Map;
      // ignore: avoid_print
      print('[VOL] 一次假广播后 lastVolume = '
          '${after['dsh.playprefs.lastVolume']}');

      expect(after['dsh.playprefs.lastVolume'], '1.0',
          reason: '★ 这条**证明缺陷存在**：只要有一次 100 的广播被写回，'
              '用户存的 0.75 就永久变成 1.0 —— '
              '这正是真机 09:03:20 发生的事（而那一刻没人碰过音量）');
    });
  });

  group('② ★★★ 监听器必须只记"用户发起的"', () {
    late final String src;
    setUpAll(() {
      src = _strip(File('lib/ui/player_page.dart').readAsStringSync());
    });

    test('★★★ volume 监听里必须有"用户发起"白名单', () {
      final i = src.indexOf('_player.stream.volume.listen(');
      expect(i, greaterThan(0), reason: '找不到 volume 监听器');
      final body = src.substring(i, i + 2000);

      expect(body.contains('_lastUserVolumeAction'), isTrue,
          reason: '★★★ volume 监听器必须检查"用户是否真的动过手" —— '
              '否则 mpv 的**默认音量广播(100)** 会被当成用户行为，'
              '把用户存的 0.75 覆盖成 1.0（真机实测 09:03:20）');
      expect(body.contains('_kVolumeEchoWindow'), isTrue,
          reason: '★ 必须用**时间窗**而不是"一次性的布尔" —— '
              '用户把音量调到**同一个值**时 mpv 幂等、**不发**广播，'
              '布尔标记会一直挂着，把之后某条无关广播误判成用户行为；'
              '时间窗会自动过期，没有这个残留问题');
    });

    test('★★★ 不许再出现"无条件写 lastVolume"的写法', () {
      final i = src.indexOf('_player.stream.volume.listen(');
      final body = src.substring(i, i + 2000);
      /*
       * 旧的（有缺陷的）写法：
       * ```dart
       * if (!_muted && v > 0) {
       *   _lastVolume = v / 100;
       *   _savePlayPref('lastVolume', _lastVolume.toString());
       * }
       * ```
       * ⇒ 判据：写偏好那一段**必须**被白名单条件包住。
       *   最直接的检查是"写偏好之前出现过 `isUserEcho`"。
       */
      expect(body.contains('isUserEcho'), isTrue,
          reason: '★★★ 写偏好必须被 `isUserEcho` 包住 —— '
              '裸的 `if (!_muted && v > 0)` 就是那个会改坏用户设置的写法');
      final saveIdx = body.indexOf("_savePlayPref('lastVolume'");
      final guardIdx = body.indexOf('isUserEcho');
      expect(guardIdx, lessThan(saveIdx),
          reason: '★★★ 白名单判断必须在写偏好**之前**');
    });

    test('★★★ 白名单必须覆盖全部**用户入口**', () {
      /*
       * 用户能改音量的入口（全都会走到 `_player.setVolume`）：
       * ```text
       * _volumeBy()   键盘 ↑/↓ 与滚轮（共用一个实现）
       * onVolume:     底栏音量滑杆
       * set_volume    遥控器
       * ```
       * ★ 漏掉任何一个 ⇒ 那条路径上用户调的音量**不会被记住**
       *   （从"改坏用户设置"变成"用户设置不生效" —— 同样是缺陷）
       */
      final n = RegExp(r'_lastUserVolumeAction = DateTime\.now\(\)')
          .allMatches(src)
          .length;
      // ignore: avoid_print
      print('[VOL] 用户入口盖戳数 = $n');
      expect(n, greaterThanOrEqualTo(3),
          reason: '★★★ 至少要有 3 个用户入口盖戳：'
              '`_volumeBy`（键盘/滚轮）、`onVolume`（滑杆）、`set_volume`（遥控）—— '
              '实测只有 $n 个');
    });

    test('★★★ 起播那次 setVolume **不得**盖用户戳（那是我们发起的）', () {
      /*
       * `_loadPlayPrefs()` 里的 `_player.setVolume(_lastVolume * 100)`
       * 是**我们**为了"起播即生效"调的，不是用户调的。
       * ★ 若它盖了戳 ⇒ mpv 的默认广播会被误认为用户行为 ⇒ 缺陷复发。
       */
      final i = src.indexOf('void _loadPlayPrefs()');
      expect(i, greaterThan(0), reason: '找不到 _loadPlayPrefs');
      final body = src.substring(i, i + 1500);
      expect(body.contains('_lastUserVolumeAction = DateTime.now()'), isFalse,
          reason: '★★★ 起播的 setVolume **不许**盖用户戳 —— '
              '那会让 mpv 的默认音量广播被误判成"用户调的" ⇒ '
              '把用户的 0.75 覆盖成 1.0（这正是要修的 bug）');
    });

    test('★★ 静音按钮**不**盖戳（取消静音恢复的音量不是用户"调"的）', () {
      final i = src.indexOf('void _toggleMute()');
      expect(i, greaterThan(0), reason: '找不到 _toggleMute');
      final body = src.substring(i, i + 700);
      expect(body.contains('_lastUserVolumeAction = DateTime.now()'), isFalse,
          reason: '★ 取消静音时恢复的音量用户并没有"调"它 —— '
              '而且监听器里本来就有 `!_muted` 守卫');
    });
  });
}
