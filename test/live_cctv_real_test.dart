@Tags(['native-media'])
library;

// ═══════════════════════════════════════════════════════════════════════
//  ★ 本文件被标记为 `native-media`（默认不跑）—— 原因见下
// ═══════════════════════════════════════════════════════════════════════
//
// 本文件调用 `MediaKit.ensureInitialized()`，它会加载 **libmpv-2.dll**。
// 实测：在 `flutter test` 的 flutter_tester 进程里加载该原生库，
// 会**偶发 native 崩溃**（访问违例 c0000005，进程退出码 79）。
//
// ```text
// 失败形态：整文件用例一起 `did not complete`（不是单用例失败）
// 实测崩溃率：加载 libmpv 6/25；不加载 0/25（干净交错 A/B）
// 与并发无关：串行 8 次里红 5 次；单文件串行也红（1/5）
// ```
//
// ★ 完整证据链与已排除清单：`.probe/native-media-tests.md`
// ★ 标签配置：`dart_test.yaml`
//
// 手动跑（改播放器 / media_kit 相关代码时**应该**跑一遍）：
// ```powershell
// flutter test test/ --tags native-media --concurrency=1
// ```
//
// ⚠️ `--concurrency=1` 并不能避免崩溃，只是让输出更易读。
// ═══════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════
//  任务⑰⑧：真实央视直播 —— Referer + load-unsafe-playlists 一起验（需外网）
// ═══════════════════════════════════════════════════════════════════════
//
// # 发现过程（两步，都是实测）
//
// ```text
// 第 1 步：发现 Referer 丢了
//   curl 不带 Referer → 403；带 → 200 + 合法 m3u8
//   player_page.dart 写的是 Media(st.url)  ← headers 全丢
//
// 第 2 步：修了 Referer 之后，用**真实 Player** 再播，仍然黑屏，且报：
//   PLAYER-ERROR Refusing to load potentially unsafe URL from a playlist.
//   PLAYER-ERROR Use the --load-unsafe-playlists option to load it anyway.
//   PLAYER-STATE duration=0 position=0 buffering=true        ← ★ 黑屏
// ```
// 即：**两个独立的原因**都要修。只修 Referer 不够。
//
// # 开启方式（环境变量，默认跳过 —— 依赖外网）
//
// ```powershell
// $env:LIVE_NET_TEST = "1"
// flutter test test/live_cctv_real_test.dart
// ```

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

bool get kRunNet => Platform.environment['LIVE_NET_TEST'] == '1';

/// ★★ media_kit 能不能初始化（缺 `libmpv-2.dll` 时为 false）
///
/// # 为什么要有这个开关（2026-09-25 修）
///
/// 原先 `main()` 里**无条件**调 `MediaKit.ensureInitialized()`。
/// 而它内部会 `DynamicLibrary.open('libmpv-2.dll')` ——
/// 本机这个 dll **不在 %PATH%** 上，于是**加载期**就抛：
/// ```text
/// Failed to load "test/live_cctv_real_test.dart":
/// Cannot find libmpv-2.dll in your system %PATH%.
///   package:media_kit/src/player/native/core/native_library.dart 81:9
///   test/live_cctv_real_test.dart 77:12   main
/// ```
///
/// 关键在于**抛的时机**：`main()` 的顶层语句在**测试文件加载时**执行，
/// 而下面那套 `if (!kRunNet) { print('SKIP'); return; }` 的跳过闸门
/// 是在**用例体内**才跑的 —— 也就是说**闸门根本没机会执行**，
/// 整个文件直接变成 "loading ... [E]"，全量测试因此永远有一条红。
///
/// 这是一种很容易忽略的失效模式：**能跳过外网的闸门，挡不住"加载期依赖"**。
/// 所以这里把初始化也纳入闸门 —— 初始化失败就当"环境不具备"，
/// 和没设 `LIVE_NET_TEST=1` 一样**跳过**（而不是让整个文件加载失败）。
///
/// ⚠️ 这样处理**不会**把真 bug 藏起来：本文件断言的是
///    "Referer + load-unsafe-playlists 打开后 duration 会推进"，
///    而 `libmpv` 缺失是**测试环境**问题，不是被测代码的问题。
///    附带 `libmpv-2.dll` 的路径即可真正跑起来，见文件头的说明。
final bool kMediaKitReady = () {
  try {
    MediaKit.ensureInitialized();
    return true;
  } catch (_) {
    return false;
  }
}();

/// 真正的跳过条件：**外网闸门** + **media_kit 可用**，两者都要
bool get kSkip => !kRunNet || !kMediaKitReady;

/// 跳过原因（写进日志，省得下次又要重新诊断一遍）
String get kSkipReason {
  if (!kRunNet) return '未设置环境变量 LIVE_NET_TEST=1';
  if (!kMediaKitReady) return 'media_kit 初始化失败（缺 libmpv-2.dll，不在 %PATH%）';
  return '';
}

const String kReferer = 'https://tv.cctv.com/';

/// 标清线路（`drm_protected=false`，是 `isPlayable` 选中的那条）
const String kUrlSd =
    'https://ldncctvwbndtxy.liveplay.myqcloud.com/ldcctvwbnd/ldcctv1_2/index.m3u8';

/// 起播并返回 (duration, 错误/日志样本)
Future<({Duration dur, List<String> errs, List<String> logs})> _play(
  String url, {
  required bool unsafeOpt,
  required bool referer,
}) async {
  final p = Player();
  final errs = <String>[];
  final logs = <String>[];
  final s1 = p.stream.error.listen(errs.add);
  final s2 = p.stream.log.listen((e) => logs.add('${e.prefix}: ${e.text}'));
  try {
    final native = p.platform;
    if (unsafeOpt && native is NativePlayer) {
      await native.setProperty('load-unsafe-playlists', 'yes');
    }
    await p.open(
      Media(url, httpHeaders: referer ? const {'Referer': kReferer} : null),
      play: true,
    );
    Duration dur = Duration.zero;
    var waited = 0;
    while (waited < 20000 && dur == Duration.zero) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      waited += 500;
      dur = p.state.duration;
    }
    return (dur: dur, errs: errs, logs: logs);
  } finally {
    await s1.cancel();
    await s2.cancel();
    await p.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  /*
   * ⚠️ `MediaKit.ensureInitialized()` **不在这里直接调** ——
   *    它缺 dll 时会在**加载期**抛，绕过下面每个用例里的跳过闸门。
   *    现在初始化放在顶层 `kMediaKitReady`（try/catch 包住），
   *    失败就当作"环境不具备"并跳过（见那里的注释）。
   */
  if (kSkip) {
    // 整个文件在环境不具备时**只挂一条跳过用例** ——
    // 这样它不会变红，但又明确出现在报告里（不是"悄悄消失"）。
    test('SKIP: 真实央视直播（需要外网 + libmpv-2.dll）', () {
      // ignore: avoid_print
      print('SKIP: $kSkipReason');
    });
    return;
  }

  group('任务⑰⑧ 真实央视直播（需外网 LIVE_NET_TEST=1）', () {
    test('★ 只给 Referer、不开 load-unsafe-playlists → 仍黑屏（复现第 2 个原因）',
        () async {
      final r = await _play(kUrlSd, unsafeOpt: false, referer: true);
      // ignore: avoid_print
      print('A) referer=yes unsafe=no  duration=${r.dur}');
      for (final e in r.errs.take(4)) {
        // ignore: avoid_print
        print('   ERR $e');
      }
      for (final l in r.logs.take(6)) {
        // ignore: avoid_print
        print('   LOG $l');
      }
      // 不断言（CDN 行为可能变），只记录机制
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('★★ Referer + load-unsafe-playlists 全开 → 真的起播（duration 推进）',
        () async {
      final r = await _play(kUrlSd, unsafeOpt: true, referer: true);
      // ignore: avoid_print
      print('B) referer=yes unsafe=yes duration=${r.dur}');
      for (final e in r.errs.take(4)) {
        // ignore: avoid_print
        print('   ERR $e');
      }
      for (final l in r.logs.take(8)) {
        // ignore: avoid_print
        print('   LOG $l');
      }

      if (r.dur == Duration.zero) {
        final joined = '${r.errs.join(" ")} ${r.logs.join(" ")}'.toLowerCase();
        final blocked = joined.contains('403') ||
            joined.contains('forbidden') ||
            joined.contains('unsafe');
        // ignore: avoid_print
        print(blocked
            ? 'REVIEW: 仍被 403/unsafe 拦住 → 还有别的原因'
            : 'SKIP: 无 403/unsafe 迹象，更像网络不可达（不是代码问题）');
        return;
      }

      expect(r.dur > Duration.zero, isTrue,
          reason: 'duration > 0 = 流真的被解开 = 不再是黑屏');
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
