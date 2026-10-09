// ═══════════════════════════════════════════════════════════════════════
//  播放器能力对等核查 —— 字幕 / 音轨 / 画中画 / 全屏 / 下一集 / 记忆位置
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件测什么
//
// 用户目标里逐条列的 12 项播放器能力。本文件**只覆盖本次补齐的**那几项
// （已验收的不重复测，见任务说明）：
// ```text
// ★ 记忆播放位置   进播放器时真的读回上次位置（本次最大的缺口）
// ★ 字幕           外挂文件 / 轨道切换 / ASS 样式
// ★ 音轨切换       aid + track-list
// ★ 下一集         可见按钮（原来只有 N 快捷键，鼠标用户发现不了）
// ★ 连播策略       endAction / 倒计时 / 自动跳过 真的接进播放逻辑
// ```
//
// # ⚠️ 断言前**必须剥掉注释行**
//
// 这是本项目反复踩的坑（至少 3 次，见 `fullscreen_titlebar_test.dart:109-116`
// 与 `skip_marker_test.dart:522-531` 的注释）：
// ```text
// 我在代码里写了大量中文注释解释"为什么"，
// 而注释里**会原样引用**被断言的代码片段（比如
//   // 原来错在：if (_sidChosen == null) { ... }
// ）→ 静态断言匹配到注释 → **假通过**
// ```
// 所以本文件所有文本断言都走 [code] / [codeOf]（先剥注释再匹配），
// 并且**反向验证**了剥离器真的有效（见最后一组）。
//
// # ⚠️ 为什么大量用静态断言而不是 widget 测试
//
// 这些能力最终都落到 `NativePlayer.setProperty` / `native.command` ——
// 那需要真的拉起 libmpv（`flutter test` 里没有原生库，会抛
// `UnsupportedError` 或直接崩）。所以：
// ```text
// ① 能不能落到 mpv  → 静态断言（属性名对不对、有没有转 NativePlayer）
// ② 面板本身能不能渲染 / 点击  → 真 widget 测试（纯 UI，不碰 mpv）
// ③ 真的能播        → 交付实测（lib/delivery_test.dart，需要真机）
// ```
// 三层缺一不可 —— 只做 ① 会"代码看起来对但一跑就崩"，
// 只做 ③ 会"能跑但不知道哪一步是对的"。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/widgets/player_settings_sheet.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

// ═══════════════════════════════════════════════════════════════════════
//  注释剥离器
// ═══════════════════════════════════════════════════════════════════════

/// 剥掉 `//` 行注释、`///` 文档注释、`/* */` 块注释
///
/// ⚠️ 只剥注释、**保留字符串字面量**里的内容 —— 因为有些断言就是要
///    匹配用户可见的文案（比如 `'关闭'` / `'上一集'`）。
///    完全照抄 `episode_strip_test.dart` 里那个已验证过的实现，
///    避免自己写一个没被验证过的版本。
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote; // 当前是否在字符串里（' 或 "）

  while (i < src.length) {
    final c = src[i];

    // ── 字符串字面量：整段照抄（但要处理转义）──
    if (quote != null) {
      out.write(c);
      if (c == r'\' && i + 1 < src.length) {
        out.write(src[i + 1]);
        i += 2;
        continue;
      }
      if (c == quote) quote = null;
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }

    // ── 行注释：吃到行尾 ──
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }

    // ── 块注释：吃到 `*/` ──
    if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        i++;
      }
      i += 2;
      continue;
    }

    out.write(c);
    i++;
  }
  return out.toString();
}

/// 读一个文件并剥掉注释
String codeOf(String path) => stripComments(File(path).readAsStringSync());

/// 把控件套进真实的壳（forui 主题 + material_ui 的 MaterialApp）
///
/// ⚠️ 必须用 **material_ui** 的 `MaterialApp` —— 用 `flutter/material`
///    会拿到 `ThemeData.fallback()`（亮色），与真机不一致
///    （见 `test/material_split_test.dart` 的决定性实验）。
Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: Stack(children: [child])),
  );
}

/// 构造一个面板（默认值集中在这里，各用例只改自己关心的那几个）
PlayerSettingsSheet _sheet({
  bool isLive = false,
  List<PlayerTrackOption> subtitleTracks = const [
    PlayerTrackOption(id: 'auto', label: '自动'),
    PlayerTrackOption(id: 'no', label: '关闭'),
    PlayerTrackOption(id: '1', label: '简体中文', hint: 'chi'),
  ],
  List<PlayerTrackOption> audioTracks = const [
    PlayerTrackOption(id: 'auto', label: '自动'),
    PlayerTrackOption(id: 'no', label: '关闭'),
    PlayerTrackOption(id: '1', label: '国语', hint: 'aac'),
  ],
  String currentSubtitleId = '1',
  String currentAudioId = '1',
  String? externalSubtitleName,
  Map<String, String> mpvStyle = const {
    'sub-ass-override': 'no',
    'sub-font': 'Microsoft YaHei',
    'sub-font-size': '55',
    'sub-color': '1.00/1.00/1.00',
    'sub-border-color': '0.00/0.00/0.00',
    'sub-border-size': '1.65',
    'sub-margin-y': '0',
  },
  PlayEndAction endAction = PlayEndAction.autoNext,
  bool countdownBeforeNext = true,
  bool keepSourceOnNext = true,
  bool autoSkip = true,
  // ── task-21 P1-8（面板倍速）──
  double rate = 1.0,
  // ── task-18 ③④⑤（片段下载 / 日志）──
  bool isPlaying = true,
  bool clipDownloading = false,
  bool clipDownloaded = false,
  String? clipDownloadError,
  ValueChanged<int>? onSetConcurrency,
  VoidCallback? onDownloadClip,
  VoidCallback? onOpenClipDir,
  ValueChanged<String>? onPickSubtitle,  ValueChanged<String>? onPickAudio,
  ValueChanged<String>? onLoadSubtitleFile,
  VoidCallback? onRemoveExternalSubtitle,
  void Function(String, String)? onSetMpvProperty,
  ValueChanged<PlayEndAction>? onSetEndAction,
  ValueChanged<bool>? onSetCountdown,
  ValueChanged<bool>? onSetKeepSource,
  ValueChanged<bool>? onSetAutoSkip,
  ValueChanged<double>? onSetRate,
  VoidCallback? onClose,
}) {
  return PlayerSettingsSheet(
    isLive: isLive,
    subtitleTracks: subtitleTracks,
    audioTracks: audioTracks,
    currentSubtitleId: currentSubtitleId,
    currentAudioId: currentAudioId,
    externalSubtitleName: externalSubtitleName,
    mpvStyle: mpvStyle,
    endAction: endAction,
    countdownBeforeNext: countdownBeforeNext,
    keepSourceOnNext: keepSourceOnNext,
    autoSkip: autoSkip,
    rate: rate,
    isPlaying: isPlaying,
    clipDownloading: clipDownloading,
    clipDownloaded: clipDownloaded,
    clipDownloadError: clipDownloadError,
    onSetConcurrency: onSetConcurrency ?? (_) {},
    onDownloadClip: onDownloadClip ?? () {},
    onOpenClipDir: onOpenClipDir ?? () {},
    onPickSubtitle: onPickSubtitle ?? (_) {},    onPickAudio: onPickAudio ?? (_) {},
    onLoadSubtitleFile: onLoadSubtitleFile ?? (_) {},
    onRemoveExternalSubtitle: onRemoveExternalSubtitle ?? () {},
    onSetMpvProperty: onSetMpvProperty ?? (_, __) {},
    onSetEndAction: onSetEndAction ?? (_) {},
    onSetCountdown: onSetCountdown ?? (_) {},
    onSetKeepSource: onSetKeepSource ?? (_) {},
    onSetAutoSkip: onSetAutoSkip ?? (_) {},
    onSetRate: onSetRate ?? (_) {},
    onClose: onClose ?? () {},
  );
}

void main() {
  late String page;

  setUpAll(() {
    page = codeOf('lib/ui/player_page.dart');
  });

  // ═══════════════════════════════════════════════════════════════════
  //  0. 剥离器本身必须有效（否则下面全是假绿）
  // ═══════════════════════════════════════════════════════════════════

  group('0. 注释剥离器（防假通过）', () {
    test('★ 行注释 / 文档注释 / 块注释都被剥掉', () {
      const src = '''
// 这是行注释，里面有 Navigator.of(context).maybePop()
/// 这是文档注释，里面有 _applySubtitleTrack
/* 这是块注释
   里面也有 native.setProperty('sid', 'no') */
void real() {}
''';
      final out = stripComments(src);
      expect(out.contains('maybePop'), isFalse);
      expect(out.contains('_applySubtitleTrack'), isFalse);
      expect(out.contains("setProperty"), isFalse);
      expect(out.contains('void real() {}'), isTrue);
    });

    test('★★ 字符串字面量**不能**被误剥（否则文案断言会假红）', () {
      /*
       * 这条是本文件最值钱的一条反向验证。
       *
       * 剥注释的朴素实现（"见到 `//` 就吃到行尾"）会把
       * `'https://x'` 里的 `//` 当成注释开头 → 把整行后半段切掉。
       * 那种剥离器会让**所有含 URL 的断言假红**，
       * 而假红会让人去改本来正确的代码。
       */
      const src = "const u = 'https://a/b'; final s = '上一集';";
      final out = stripComments(src);
      expect(out.contains('https://a/b'), isTrue,
          reason: '★ 字符串里的 `//` 不是注释 —— 误剥会让 URL 断言假红');
      expect(out.contains('上一集'), isTrue, reason: '★ 用户可见文案必须保留');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  1. ★★★ 记忆播放位置（本次最大的缺口）
  // ═══════════════════════════════════════════════════════════════════

  group('1. 记忆播放位置 —— 进播放器要读回上次位置', () {
    test('★★★ 起播前必须调 getProgress（否则永远从 0 开始）', () {
      /*
       * # 这条是本轮最核心的断言
       *
       * 修之前的状态（我实际 grep 到的）：
       * ```text
       * lib/ui/detail_page.dart:221   ← 详情页读进度（显示"看到 12:34"）
       * lib/ui/player_page.dart       ← ✗ 一次都没有
       * ```
       * 也就是说 `_saveProgress` 一直在写，但**没有任何地方读回来** ——
       * 用户"看 20 分钟 → 退出 → 再进来"**永远从第 0 秒开始**。
       *
       * 这是用户能直接感知的功能（目标里明确列了"记忆播放位置"）。
       */
      expect(
        page.contains('SourinApi.getProgress(_provider, _contentId)'),
        isTrue,
        reason: '★★★ 播放页必须调 `getProgress` 读回上次位置 —— '
            '只写不读等于没有"记忆播放位置"',
      );
    });

    test('★★★ getProgress 必须在 _startPlayback **之前** 调用', () {
      /*
       * # 为什么顺序是硬约束
       *
       * `_startPlayback` 会**消费** `_pendingSeek`（读出来 → seek → 置 null）。
       * 如果 `_prepareResume` 在它之后跑：
       * ```text
       * ① 先从头起播（画面已经在第 0 秒）
       * ② 再读到上次位置、seek 过去
       * → 用户看到画面**闪回去又跳过来**
       * ```
       * 原版的顺序是 `await prepareResume();` → `await startPlayback(...)`
       * （`PlayerView.vue:1918` / `:1930`），这里必须一致。
       */
      final iResume = page.indexOf('await _prepareResume();');
      final iStart = page.indexOf('await _startPlayback(first);');
      expect(iResume, greaterThan(0), reason: '必须真的 await 了 _prepareResume');
      expect(iStart, greaterThan(0), reason: '必须真的 await 了 _startPlayback');
      expect(
        iResume,
        lessThan(iStart),
        reason: '★★★ 顺序错了：_prepareResume 必须在 _startPlayback 之前 —— '
            '反过来的话 _pendingSeek 已经被消费掉了，续播静默失效，'
            '用户看到"从头播再跳一下"',
      );
    });

    test('★★ 直播不续播（原版 prepareResume 第一行就 return）', () {
      final i = page.indexOf('Future<void> _prepareResume() async {');
      expect(i, greaterThan(0), reason: '必须有 _prepareResume');
      final body = page.substring(i, i + 400);
      expect(body.contains('if (_isLive) return;'), isTrue,
          reason: '直播是线性的，没有"上次看到哪儿"这回事');
    });

    test('★★ 按集号校验 —— 上一集的进度不能串到这一集', () {
      /*
       * 原版：`if (p.episode_id && s.episodeId && p.episode_id !== s.episodeId) return;`
       *
       * 不校验的后果：用户看完第 3 集（进度 2400s），
       * 点开第 4 集（总长 2400s）→ 直接被 seek 到结尾 → 立刻触发"已播放完毕"。
       */
      expect(
        page.contains('p.episodeId != curEpId'),
        isTrue,
        reason: '★★ 必须按 episode_id 校验 —— 否则上一集的进度会串到这一集',
      );
    });

    test('★★ 快看完了不续播（原版 `pos < duration - 10`）', () {
      expect(
        page.contains('pos >= p.duration - 10'),
        isTrue,
        reason: '剩不到 10 秒还跳过去的话，用户一进来就"播完了"',
      );
    });

    test('★ 读进度失败不能影响播放（原版 catch 里什么都不做）', () {
      final i = page.indexOf('Future<void> _prepareResume() async {');
      final body = page.substring(i, i + 2600);
      expect(body.contains('catch (e)'), isTrue,
          reason: '★ getProgress 会抛（后端/网络问题）—— 不 catch 的话'
              '播放页会直接进错误态，用户连视频都看不了',
      );
    });

    test('★ 进度落盘的三条路径都还在（写侧没被破坏）', () {
      // ① 定时落盘（原版：30 秒；我们 5 秒 —— 已验收，不动）
      expect(page.contains('_startProgressSaver()'), isTrue);
      // ② 退出时立刻落盘（dispose 里，不能 await 所以 fire-and-forget）
      expect(page.contains('_saveProgress(immediate: true);'), isTrue,
          reason: '退出/切集/换源前必须立刻落一次，否则最后几秒丢');
      // ③ 切集前落盘
      expect(page.contains('await _saveProgress(immediate: true);'), isTrue);
    });

    // ─────────────────────────────────────────────────────────────
    //  ★★★ 下面这两条是**交付实测抓到的真 bug** 的回归保护
    // ─────────────────────────────────────────────────────────────

    test('★★★ 续播 seek 必须**等 duration 出来**再做', () {
      /*
       * # 实测证据（2026-09-24 交付实测）
       *
       * 原来的写法是 `open()` 之后**立刻** `await _player.seek(target)`：
       * ```text
       * 日志：  [PLAYER] 已续播到 276s        ← "成功"
       * 画面：  00:29                        ← 实际还在开头
       * ```
       * 也就是说 **seek 被静默丢弃了，而日志永远说成功**。
       *
       * # 根因
       *
       * `Player.open()` 返回时 `duration` 还是 0（还没 demux 完）。
       * 紧接着代码会 `setProperty('audio-file', ...)` 挂外挂音轨
       * （B 站 DASH 音视频分离必然走这条）—— mpv 重建音频链时
       * **播放位置被复位到 0**，把刚排队的 seek 吃掉了。
       *
       * # 为什么这条断言必须存在
       *
       * 这是**唯一一类"日志全绿但用户看得见"的 bug**：
       * ```text
       * analyze  0 error     ✗ 抓不到
       * 单测     全绿        ✗ 抓不到（不碰真播放器）
       * 日志     "已续播到"   ✗ 反而误导
       * ```
       * 只有"截图看进度条"或者"断言等时长这个形态"能抓到。
       */
      expect(
        page.contains('Future<void> _seekAfterReady('),
        isTrue,
        reason: '★★★ 续播必须走 `_seekAfterReady`（等时长再 seek）—— '
            '直接 `await _player.seek(...)` 会被加载复位吃掉',
      );

      // 轮询等 duration：这是"等就绪"的判据
      final i = page.indexOf('Future<void> _seekAfterReady(');
      final body = page.substring(i, i + 1800);
      expect(
        body.contains('_duration <= Duration.zero'),
        isTrue,
        reason: '★ 必须等 `_duration` 变成正数再 seek（duration=0 时 seek 无效）',
      );
      expect(
        body.contains('await Future<void>.delayed('),
        isTrue,
        reason: '★ 必须是轮询等待，不能是固定 sleep 一次',
      );
      // 必须有上限，否则源拿不到时长时会永远挂着
      expect(
        body.contains('waited < 48'),
        isTrue,
        reason: '★ 轮询必须有上限（48×250ms=12s）—— 否则拿不到时长的源会永远等',
      );
    });

    test('★★★ 起播路径里不得再出现"open 之后立刻 seek"', () {
      /*
       * 反向断言：直接 `await _player.seek(` 这种形态在
       * `_startPlayback` 里**不能**出现 —— 它就是这个 bug 的写法。
       *
       * ⚠️ 允许的地方：`_seekAfterReady` 内部（那是修好之后的形态）。
       */
      final i = page.indexOf('Future<void> _startPlayback(StreamCandidate st) async {');
      expect(i, greaterThan(0));
      // 取到下一个方法定义为止（`_seekAfterReady` 在它后面）
      final j = page.indexOf('Future<void> _seekAfterReady(', i);
      expect(j, greaterThan(i), reason: '_seekAfterReady 必须定义在 _startPlayback 之后');
      final body = page.substring(i, j);

      expect(
        body.contains('await _player.seek('),
        isFalse,
        reason: '★★★ `_startPlayback` 里不得直接 await seek —— '
            '那时 duration 还是 0，seek 会被随后的音频链重建吃掉，'
            '而且日志会骗你说成功',
      );
      expect(
        body.contains('_seekAfterReady('),
        isTrue,
        reason: '★ 必须改走 _seekAfterReady',
      );
    });

    test('★★ 换流时要作废过期的续播 seek（否则串集）', () {
      /*
       * `_seekAfterReady` 是异步等时长的。用户在这段等待里换了线路，
       * 就会有两个在跑，旧的那个会把**上一集的秒数** seek 到新流上。
       */
      expect(page.contains('_seekToken'), isTrue,
          reason: '★★ 必须有代次号 —— 否则等时长期间换流会 seek 到错的秒数');
      final i = page.indexOf('Future<void> _seekAfterReady(');
      final body = page.substring(i, i + 1800);
      expect(body.contains('if (token != _seekToken)'), isTrue,
          reason: '★ 代次号不匹配时必须放弃这次 seek');
      expect(page.contains('_resumeSeekDone = false;'), isTrue,
          reason: '★ 每次起播要复位"已 seek"标志 —— '
              '否则换集后**不会**续播新集的进度',
      );
    });

    test('★ 续播目标超过时长时要夹取（否则一进来就"播放结束"）', () {
      final i = page.indexOf('Future<void> _seekAfterReady(');
      final body = page.substring(i, i + 1800);
      expect(body.contains('t > dur'), isTrue,
          reason: '★ 目标比新源总时长还长时要夹到时长内 —— '
              '否则会 seek 到结尾、立刻触发 completed + 连播倒计时',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  2. ★ 字幕（内嵌轨 / 外挂文件 / ASS 样式）
  // ═══════════════════════════════════════════════════════════════════

  group('2. 字幕', () {
    test('★★ 内嵌字幕轨切换走 mpv 的 sid（且必须转 NativePlayer）', () {
      /*
       * ⚠️ `Player` 本身**没有** setProperty —— 必须 `player.platform as NativePlayer`。
       *    项目记忆里专门记过这条（`PlayerConfiguration` 没有 hwdec 字段，
       *    只能 setProperty）。写错的报错是
       *    `The method 'setProperty' isn't defined for Player`。
       */
      expect(
        page.contains("await native.setProperty('sid', id)"),
        isTrue,
        reason: '字幕轨切换必须落到 mpv 的 `sid` 属性',
      );
      expect(
        page.contains('if (native is! NativePlayer) return;'),
        isTrue,
        reason: '★ setProperty 在 Player 上不存在，必须转 NativePlayer',
      );
    });

    test('★★ 选非 no 的轨时必须打开 sub-visibility', () {
      /*
       * mpv 手册：`--sid=no` disables subtitle decoding；
       * 而 `sub-visibility=no` 时**即使 sid 指向有效轨也不显示**。
       *
       * 用户的操作路径："关闭字幕" → 又选回某条轨。
       * 不重开可见性的话，sid 对了但屏幕上还是没字 ——
       * 表现为"选回来了却还是没字幕"，极难排查。
       */
      expect(
        page.contains("await native.setProperty('sub-visibility', 'yes')"),
        isTrue,
        reason: '★ 切回某条轨时必须打开 sub-visibility，否则还是看不到字',
      );
    });

    test('★★★ 外挂字幕必须用 sub-add，**不能**用 sub-file', () {
      /*
       * # 这条断言防的是一个"看起来更简单但会累积"的写法
       *
       * mpv 手册原文：
       * > ``--sub-file`` is a CLI/config file only alias for ``--sub-files-append``.
       *
       * 也就是说 `setProperty('sub-file', path)` 是 **append（追加）** 语义：
       * ```text
       * 用户加载 A.ass  → sub-files = [A.ass]
       * 用户换 B.ass    → sub-files = [A.ass, B.ass]   ← 累积！
       * 再换 C.ass      → sub-files = [A.ass, B.ass, C.ass]
       * ```
       * 表现是字幕面板里堆出一串外挂轨，而且**旧的那条还可能在显示**。
       *
       * 正确做法是 `sub-add <file> select` —— `select` 表示"加进来并立刻选中"。
       */
      expect(
        page.contains("native.command(['sub-add', path, 'select'"),
        isTrue,
        reason: '★★★ 外挂字幕必须走 `sub-add ... select` 命令',
      );
      expect(
        page.contains("setProperty('sub-file'"),
        isFalse,
        reason: '★★★ 不得用 sub-file —— mpv 手册明确它是 '
            '`sub-files-append` 的别名，重复设置会**累积**出多条外挂轨',
      );
    });

    test('★★ 换外挂字幕前要删掉旧的（否则还是累积）', () {
      expect(
        page.contains("native.command(['sub-remove'])"),
        isTrue,
        reason: '★ 换一条外挂字幕前必须 sub-remove，否则堆叠',
      );
    });

    test('★★ 换集后要重新挂外挂字幕（file-local 选项会被复位）', () {
      /*
       * mpv 手册「Per-File Options」：
       * > any file-local option changed at runtime is reset when the current
       * > file stops playing.
       *
       * `sub-add` 加进来的外挂轨是 **file-local** 的 —— 换集后
       * 不重新 add 的话，第二集就没字幕了（而用户会以为"字幕坏了"）。
       */
      final i = page.indexOf('Future<void> _applySubtitleStyle() async {');
      expect(i, greaterThan(0), reason: '必须有 _applySubtitleStyle');
      final body = page.substring(i, i + 900);
      expect(body.contains("native.command(['sub-add', ext.id, 'select'"),
          isTrue,
          reason: '★ 换集后必须重新挂载外挂字幕（file-local 会被 mpv 复位）');
    });

    test('★★ ASS 样式：sub-ass-override 必须可配（否则调了没反应）', () {
      /*
       * mpv 手册（`--sub-font` 那条）：
       * > The ``--sub-font`` option (and many other style related ``--sub-``
       * > options) are ignored when ASS-subtitles are rendered, unless
       * > ``--sub-ass=no`` is specified.
       *
       * 也就是 **ASS 字幕默认不吃字号/字体/颜色** —— 用户拖了滑块
       * 画面没变，只会以为功能坏了。所以 `sub-ass-override` 必须是
       * 一个**显式选项**，且界面上要写清楚后果。
       */
      final sheet = codeOf('lib/ui/widgets/player_settings_sheet.dart');
      expect(sheet.contains("'sub-ass-override'"), isTrue,
          reason: '★★ 必须有 sub-ass-override —— 没有它，'
              '字号/字体/颜色对 ASS 全部无效（mpv 既定行为）');
      // 三个档位的 wire 值必须与 mpv 手册一致
      for (final w in const ['no', 'yes', 'force']) {
        expect(sheet.contains("('$w',"), isTrue,
            reason: '★ sub-ass-override 的档位 `$w` 必须存在（mpv 手册的取值）');
      }
    });

    test('★★ 样式项的名字必须是 mpv 手册里的真名', () {
      final sheet = codeOf('lib/ui/widgets/player_settings_sheet.dart');
      /*
       * 全部来自 mpv `DOCS/man/options.rst`，不是猜的：
       * ```text
       * sub-font-size      unit is the size in scaled pixels at a window height of 720
       * sub-color          r/g/b，each component in the range 0.0 to 1.0
       * sub-border-color   alias for sub-outline-color
       * sub-border-size    alias for sub-outline-size
       * sub-margin-y       distance from the bottom
       * ```
       */
      for (final k in const [
        "'sub-font'",
        "'sub-font-size'",
        "'sub-color'",
        "'sub-border-color'",
        "'sub-border-size'",
        "'sub-margin-y'",
      ]) {
        expect(sheet.contains(k), isTrue,
            reason: '★ 样式项 `$k` 必须存在（名字来自 mpv 手册）');
      }
    });

    test('★★ 颜色必须是 mpv 要的 `r/g/b` 形式（不是 #RRGGBB）', () {
      /*
       * mpv 手册 `--sub-color`：
       * > The color is specified in the form ``r/g/b``, where each color
       * > component is specified as number in the range 0.0 to 1.0.
       *
       * 写成 `#FFFFFF` 的话 mpv 会**静默忽略**（属性设置失败但不抛错），
       * 表现为"点了颜色没反应"。
       */
      expect(
        SubtitleColorPreset('测试', 1, 1, 1).wire,
        '1.00/1.00/1.00',
        reason: '★ 必须是 r/g/b 形式 —— 十六进制会被 mpv 静默忽略',
      );
      expect(
        SubtitleColorPreset('测试', 0, 0.5, 1).wire,
        '0.00/0.50/1.00',
      );
    });

    test('★ 颜色比对要有容差（浮点字符串比对会假红）', () {
      // mpv 可能回 `1/1/1` 或 `1.0/1.0/1.0` —— 字符串严格比对会失配，
      // 表现是"已经选中的颜色没高亮"
      const white = SubtitleColorPreset('白', 1, 1, 1);
      expect(white.matches('1/1/1'), isTrue);
      expect(white.matches('1.0/1.0/1.0'), isTrue);
      expect(white.matches('1.00/1.00/1.00'), isTrue);
      expect(white.matches('0/0/0'), isFalse);
      expect(white.matches(null), isFalse);
    });

    test('★★ 默认值必须从 mpv **读回来**，不能写死', () {
      /*
       * mpv 的 `sub-font-size` 默认值在版本间变过（老版本 55、新版本 38）。
       * 面板写死一个数的话，用户**一打开面板**就看到"字号被改了" ——
       * 而他什么都没做。
       */
      expect(
        page.contains('Future<void> _readMpvStyle() async {'),
        isTrue,
        reason: '★★ 必须有 _readMpvStyle —— 打开面板前先从 mpv 读当前值',
      );
      /*
       * ★★★ 2026-10-07 改（桌面端第 3 条）：
       *
       * 这里原来断言的是 `body.contains('await _readMpvStyle();')` ——
       * 也就是「打开面板**之前**必须先 await 读样式」。**那条断言守的正是
       * 缺陷本身**：`native.getProperty` 走 FFI，mpv 侧只要不回应
       * （卡住 / 已崩 / 还没就绪）await 就永不返回 ⇒ `_settingsOpen` 恒为
       * false，而底栏的 3 秒自动隐藏计时器照常把底栏收掉 ⇒ 屏幕上就是
       * Owner 报的「点了齿轮无反应，下面一栏没了，上面还显示」。
       *
       * 现在改成守**真正该守的顺序**：打开面板的纯 UI 动作必须排在 mpv
       * 回读之前（回读降级为 unawaited 的后台刷新，读到了自己 setState）。
       */
      final i = page.indexOf('Future<void> _openSettings() async {');
      expect(i, greaterThan(-1), reason: '★ 找不到 _openSettings');
      final body = page.substring(i, i + 700);
      final openAt = body.indexOf('_settingsOpen = true');
      final readAt = body.indexOf('_readMpvStyle()');
      expect(openAt, greaterThan(-1), reason: '★ 打开面板要置 _settingsOpen');
      expect(readAt, greaterThan(-1), reason: '★ 打开面板要回读样式');
      expect(openAt, lessThan(readAt),
          reason: '★★★ 打开面板必须排在 mpv 回读**之前** —— '
              '反过来的话 mpv 不回应时面板永不出现（桌面端第 3 条缺陷）');
      expect(body.contains('unawaited(_readMpvStyle());'), isTrue,
          reason: '★ 回读必须是后台刷新（unawaited），不能 await —— '
              'await 会把面板钉在 mpv 往返之后');
    });

    test('★ 面板对"读不到"的项要禁用，不能假装有默认值', () {
      final sheet = codeOf('lib/ui/widgets/player_settings_sheet.dart');
      // 读不到时 onChanged 传 null（Slider/Dropdown 会禁用）
      expect(
        sheet.contains('onChanged: fontSize == null'),
        isTrue,
        reason: '★ 读不到字号时必须禁用滑块 —— 假装有个默认值等于骗用户',
      );
      expect(sheet.contains("hint: current == null ? '读不到' : null"), isTrue,
          reason: '★ 颜色读不到时要明说');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  3. ★ 音轨切换
  // ═══════════════════════════════════════════════════════════════════

  group('3. 音轨切换', () {
    test('★★ 音轨切换走 mpv 的 aid', () {
      expect(
        page.contains("await native.setProperty('aid', id)"),
        isTrue,
        reason: '音轨切换必须落到 mpv 的 `aid` 属性'
            '（手册：auto selects the default, no disables audio）',
      );
    });

    test('★★ 必须监听 stream.tracks（轨列表是**起播后**才有的）', () {
      /*
       * `Player.open()` 返回时轨列表往往还是空的 —— 要等解复用完成。
       * 只读一次的话面板永远是空的（"这条流没有字幕轨"），
       * 而实际上有轨。`delivery_test.dart` 实测过要等 1–2 秒。
       */
      expect(
        page.contains('_player.stream.tracks.listen('),
        isTrue,
        reason: '★★ 必须**监听**轨列表 —— open() 返回时还是空的',
      );
    });

    test('★★ 必须过滤 mpv 的伪轨道 auto/no', () {
      /*
       * media_kit 的 `Tracks` 默认值里就含这两条**控制项**：
       * ```dart
       * Tracks(subtitle: [SubtitleTrack('auto',...), SubtitleTrack('no',...)])
       * ```
       * `delivery_test.dart:786-807` 记过这个坑：把 `tracks.subtitle.first`
       * 当成"第一条字幕"会选中 `auto`；若真实轨不在第一位就会选到 `no`
       * （关闭字幕）→ 表现为"字幕怎么都不出来"。
       */
      expect(
        page.contains("if (s.id == 'auto' || s.id == 'no') continue;"),
        isTrue,
        reason: '★★ 必须跳过伪轨道 auto/no，否则"第一条字幕"可能是"关闭"',
      );
      expect(
        page.contains("if (a.id == 'auto' || a.id == 'no') continue;"),
        isTrue,
      );
    });

    test('★★ 自动选轨只能做一次（否则"关闭字幕"会被改回来）', () {
      /*
       * 用户手动选「关闭」后，如果每次轨列表刷新都自动选回第一条真实轨，
       * 「关闭字幕」就是一个**无效操作** —— 用户关了它自己又开。
       */
      expect(
        page.contains('_pickSubtitleMadeByUser'),
        isTrue,
        reason: '★★ 必须有"用户手动选过"的标志 —— '
            '否则关掉字幕会被自动选轨改回来',
      );
      final i = page.indexOf("if (_sidChosen == 'auto' && !_pickSubtitleMadeByUser)");
      expect(i, greaterThan(0),
          reason: '★ 自动选轨的条件必须同时要求"还没选过"与"用户没手动选过"');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  4. ★ 下一集（可见按钮）
  // ═══════════════════════════════════════════════════════════════════

  group('4. 下一集', () {
    test('★★ 必须有**可见的**上一集/下一集按钮', () {
      /*
       * 修之前：只有 `N` 快捷键 + 片尾倒计时。
       * 鼠标用户**根本发现不了**这个能力（快捷键提示浮层默认不显示）。
       * 证据：`_prevEpisode` 早就写好了却从没被引用过（analyze 报 unused）。
       *
       * 原版 `PlayerView.vue:4367-4392` 是有这两个按钮的。
       */
      expect(page.contains("label: const Text('上一集')"), isTrue,
          reason: '★ 上一集按钮必须存在（原版有）');
      expect(page.contains("label: const Text('下一集')"), isTrue,
          reason: '★ 下一集按钮必须存在（原版有）');
    });

    test('★★ 直播不显示这两个按钮（原版注释专门记录过）', () {
      /*
       * 原版注释：
       * > ⚠️ 直播没有「上一集/下一集」概念。
       * > 原来无脑渲染这两个按钮，直播时会显示成**两个灰掉的死按钮**
       * > （实测截图里直播页出现「上一集 ⋯ 下一集」，很怪）。
       */
      expect(
        page.contains('showEpisodeNav: !_isLive && _episodes.isNotEmpty'),
        isTrue,
        reason: '★★ 直播时整块不渲染 —— 原版实测过"两个灰死按钮"很怪',
      );
      expect(page.contains('if (showEpisodeNav) ...['), isTrue,
          reason: '★ 按钮必须真的被 showEpisodeNav 门控');
    });

    test('★ 到第一集/最后一集时按钮**禁用**而不是隐藏', () {
      // 原版是 `:disabled="!prevEpisode"` —— 禁用能让用户明白"这是第一集"，
      // 隐藏则让人以为按钮时有时无
      expect(page.contains('onPressed: hasPrev ? onPrev : null'), isTrue,
          reason: '★ 用 `onPressed: null` 禁用（而不是不渲染）');
      expect(page.contains('onPressed: hasNext ? onNext : null'), isTrue);
    });

    test('★ N 快捷键仍然指向同一套下一集逻辑（已验收，不能改坏）', () {
      final i = page.indexOf('if (k == LogicalKeyboardKey.keyN) {');
      expect(i, greaterThan(0));
      expect(page.substring(i, i + 90).contains('_gotoNextEpisode()'), isTrue,
          reason: '★ N 键必须还是走 _gotoNextEpisode（已验收的快捷键）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  5. ★ 连播策略（原版 ArtPlayer settings 的四项）
  // ═══════════════════════════════════════════════════════════════════

  group('5. 连播策略 —— 照抄原版 stores/player.ts', () {
    test('★★★ endAction 的三个分支必须真的落地', () {
      /*
       * 修之前：`_onEnded` 只有一句
       * ```dart
       * if (_nextEpisode != null) _startNextCountdown();
       * ```
       * 也就是说**不管用户选什么，行为都是自动连播** ——
       * 「单集循环」「播完停止」两个选项形同虚设。
       *
       * 原版 `PlayerView.vue:2763-2784` 是 switch 三路。
       */
      final i = page.indexOf('void _onEnded() {');
      expect(i, greaterThan(0));
      final body = page.substring(i, i + 2200);
      expect(body.contains('PlayEndAction.singleLoop'), isTrue,
          reason: '★★ 单集循环分支必须存在');
      expect(body.contains('PlayEndAction.autoNext'), isTrue,
          reason: '★★ 自动连播分支必须存在');
      expect(body.contains('PlayEndAction.stop'), isTrue,
          reason: '★★ 播完停止分支必须存在');
      // 单集循环要真的回到 0 并继续播（对应原版 v.currentTime=0; v.play()）
      expect(body.contains('_player.seek(Duration.zero)'), isTrue,
          reason: '★ 单集循环必须 seek 回 0');
      expect(body.contains('_player.play()'), isTrue,
          reason: '★ 单集循环必须继续播');
    });

    test('★★ 「连播前倒计时」开关必须真的被读', () {
      /*
       * 原版 `PlayerView.vue:2778`：
       * ```ts
       * if (prefs.countdownBeforeNext) startNextCountdown();
       * else gotoEpisode(nextEpisode.value);
       * ```
       */
      final i = page.indexOf('void _onEnded() {');
      final body = page.substring(i, i + 2200);
      expect(body.contains('if (_countdownBeforeNext)'), isTrue,
          reason: '★★ 关掉倒计时要**直接**下一集 —— 开关不接进逻辑就是死开关');
    });

    test('★★ 「自动跳过片头」开关必须真的被读', () {
      /*
       * 原版 `applySkipMarkers()` 第一行：
       * ```ts
       * if (!v || !s || isLive.value || !autoSkipOn.value) return;
       * ```
       * 不接的话面板里那个开关就是个死开关（能拨但什么都不影响）。
       */
      final i = page.indexOf('void _maybeSkip(Duration pos) {');
      expect(i, greaterThan(0));
      final body = page.substring(i, i + 900);
      expect(body.contains('if (!_autoSkip) return;'), isTrue,
          reason: '★★ _maybeSkip 必须读 _autoSkip —— 否则开关是死的');
    });

    test('★ 打开"自动跳过"时要重置"已跳过"标志', () {
      /*
       * 与「片头片尾」弹窗保存后的处理同理：用户刚打开开关，
       * 但 `_introSkipped` 可能在本会话早先已被置 true
       * （那时开关是关的、根本没跳）→ 不重置的话本集不会跳。
       */
      final i = page.indexOf('onSetAutoSkip: (v) {');
      expect(i, greaterThan(0));
      final body = page.substring(i, i + 500);
      expect(body.contains('_introSkipped = false;'), isTrue,
          reason: '★ 打开开关要重置 —— 否则本集不会跳，用户以为开关没用');
      expect(body.contains('_outroSkipped = false;'), isTrue);
    });

    test('★★ 默认值必须与原版一字不差', () {
      /*
       * 原版 `stores/player.ts:80-92`：
       * ```ts
       * endAction: "autoNext", keepSourceOnNext: true,
       * countdownBeforeNext: true, autoSkip: true,
       * lastSpeed: 1, lastVolume: 1,
       * ```
       */
      expect(page.contains('PlayEndAction _endAction = PlayEndAction.autoNext;'),
          isTrue, reason: '★ 默认「自动连播」（原版默认）');
      expect(page.contains('bool _countdownBeforeNext = true;'), isTrue);
      expect(page.contains('bool _keepSourceOnNext = true;'), isTrue);
      expect(page.contains('bool _autoSkip = true;'), isTrue);
    });

    test('★★ 偏好必须持久化（原版存 localStorage，我们存 UiPrefs）', () {
      expect(page.contains('_loadPlayPrefs()'), isTrue,
          reason: '★ 起播前要读回偏好 —— 否则每次进播放器都回到默认值');
      expect(page.contains("_savePlayPref('endAction'"), isTrue);
      expect(page.contains("_savePlayPref('countdownBeforeNext'"), isTrue);
      expect(page.contains("_savePlayPref('autoSkip'"), isTrue);
    });

    test('★ 非法偏好值要有白名单兜底（文件可能被写坏）', () {
      // 原版同样做了白名单校验（`stores/player.ts:98-112`）
      expect(
        page.contains('orElse: () => PlayEndAction.autoNext'),
        isTrue,
        reason: '★ endAction 非法时回退到默认 —— '
            '不兜底的话"播放完"什么都不做，用户以为播完了没反应',
      );
    });

    test('★ 音量/倍速要记住并在起播前套用（原版 lastVolume/lastSpeed）', () {
      expect(page.contains("_savePlayPref('lastVolume'"), isTrue,
          reason: '★ 记住音量（原版 PlayerView.vue:3983）');
      expect(page.contains("_savePlayPref('lastSpeed'"), isTrue,
          reason: '★ 记住倍速（原版 PlayerView.vue:3989）');
      // 必须在创建 Player 之后、起播之前设好，否则有"先满音量再变小"的突跳
      final i = page.indexOf('void _loadPlayPrefs() {');
      expect(i, greaterThan(0));
      final body = page.substring(i, i + 1600);
      /*
       * ★★ 2026-10-09 改口径（task-1 缺陷 1/11 的**必要**连带）
       *
       * # 为什么原来那句字面量没了
       * ```text
       * 改前：`_loadPlayPrefs()` 直接 `_player.setVolume(_lastVolume * 100)`。
       * 缺陷 1（静音后仍有声音）/ 11（静音按钮二次点击）的根因正是
       * 「音量下发散落在多处、没有统一出口」——修法是把下发收敛成
       * 唯一出口 `_sendVolume()`（player_page.dart:1542），它同时做探针打点
       * 与静音状态机。于是这里变成 `_sendVolume(_lastVolume * 100)`。
       * ⇒ 断言旧字面量会**假红**：`_sendVolume` 生产分支逐字等价于
       *    `_player.setVolume(v)`（见那里的 `_probeNoAudio` 注释，生产恒 false）。
       * ```
       *
       * ★ 判据的**实质没变**：起播前必须把音量套上去。而且这里**加严**了 ——
       *   不但要求 `_loadPlayPrefs` 走唯一出口，还要求那个出口在生产分支上
       *   确实是 `_player.setVolume` 的纯转发（否则「套用音量」是空转）。
       */
      expect(body.contains('_sendVolume(_lastVolume * 100)'), isTrue,
          reason: '★ 起播前就要套用音量（走唯一出口 `_sendVolume`）');
      final si = page.indexOf('void _sendVolume(double v) {');
      expect(si, greaterThan(0), reason: '★ 音量唯一出口 `_sendVolume` 不见了');
      final sendBody = page.substring(si, si + 400);
      expect(sendBody.contains('_player.setVolume(v)'), isTrue,
          reason: '★★ `_sendVolume` 必须在生产分支上真的下发到播放器 ——'
              '只打点不下发的话「起播前套用音量」就是空转');
    });

    test('★ 静音时**不**记音量（原版 `if (v && !v.muted)`）', () {
      /*
       * 记了静音的话，用户下次进来是静音的，
       * 而且他不知道自己什么时候"设过"静音 —— 很难联想到。
       */
      final i = page.indexOf('_player.stream.volume.listen(');
      expect(i, greaterThan(0));
      /*
       * ⚠️ 2026-09-27：条件从 `if (!_muted && v > 0)` 改成
       *    `if (isUserEcho && !_muted && v > 0)` ——
       *    前面多了「**用户真的动手调过**」这道白名单。
       *
       * # 为什么加白名单（**会改坏用户设置**的真 bug）
       * ```text
       * 真机实测：ui-prefs.json 的 dsh.playprefs.lastVolume
       *           **0.75 → 1.0**（写入 09:03:20）
       * 而那一刻**没有任何人操作音量**
       *
       * 根因：mpv 在播放器刚创建时会广播它自己的**默认音量 100**
       * ⇒ `!_muted && 100 > 0` 成立 ⇒ 把 "1.0" 写进用户偏好
       * ```
       * ⇒ ★ 所以这条断言**不能**再钉死那个字面量：它要守的是
       *    「静音不记」这个**语义**，而语义由 `!_muted` 承载；
       *    白名单是**附加**条件（由 `t61_volume_pref_test.dart` 专门守）。
       */
      final body = page.substring(i, i + 2500);
      expect(body.contains('!_muted && v > 0'), isTrue,
          reason: '★ 静音不记 —— 否则下次进来莫名其妙没声音');
      expect(body.contains('isUserEcho'), isTrue,
          reason: '★★★ 还必须有"用户发起的"白名单 —— 否则 mpv 的'
              '**默认音量广播(100)** 会把用户存的 0.75 覆盖成 1.0'
              '（真机实测 09:03:20，而那一刻没人碰过音量）。'
              '详见 `test/t61_volume_pref_test.dart`');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  6. 画中画 / 全屏 / 进度条 / 倍速 / 音量（已验收项的**回归**保护）
  // ═══════════════════════════════════════════════════════════════════

  group('6. 已验收能力的回归保护（不重复调查，只防改坏）', () {
    test('★ P 键画中画 + 不支持时不显示按钮', () {
      expect(page.contains('if (k == LogicalKeyboardKey.keyP)'), isTrue,
          reason: '★ P = 画中画（原版 `hk.add("KeyP", ...)`）');
      expect(page.contains('if (pipSupported)'), isTrue,
          reason: '★ 不支持的平台**不显示**按钮（灰按钮会让人以为坏了）');
    });

    test('★ F 键全屏 + 真的调 OS 全屏 + 退出走统一出口', () {
      expect(page.contains('if (k == LogicalKeyboardKey.keyF)'), isTrue);
      expect(page.contains('windowManager.setFullScreen('), isTrue,
          reason: '★ 只改标志位的话窗口纹丝不动（已验收，不能改坏）');
      expect(page.contains('titleBarVisible.value = !next;'), isTrue);
    });

    test('★ 直播禁用进度条', () {
      expect(page.contains('if (!isLive)'), isTrue,
          reason: '★ 直播不能快进/跳转 —— 进度条本身也是禁用的');
    });

    test('★ 倍速 / 音量快捷键还在', () {
      expect(page.contains('if (k == LogicalKeyboardKey.keyM)'), isTrue);
      expect(page.contains('if (k == LogicalKeyboardKey.comma)'), isTrue);
      expect(page.contains('if (k == LogicalKeyboardKey.period)'), isTrue);
    });

    test('★ Esc 关面板的顺序：设置面板必须在最前', () {
      /*
       * 设置面板是 `Positioned.fill` 的全屏 scrim，**最后打开的那一层**。
       * Esc 不先关它的话：用户看到面板还开着，窗口却退出了全屏/返回了上一页。
       */
      final i = page.indexOf('if (k == LogicalKeyboardKey.escape ||');
      expect(i, greaterThan(0));
      final body = page.substring(i, i + 700);
      final iSettings = body.indexOf('else if (_settingsOpen)');
      final iEpisode = body.indexOf('else if (_episodeSheetOpen)');
      expect(iSettings, greaterThan(0), reason: '★ Esc 必须能关设置面板');
      expect(iSettings, lessThan(iEpisode),
          reason: '★ 设置面板要排在选集之前（它是最后打开的那一层）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  7. 铁律
  // ═══════════════════════════════════════════════════════════════════

  group('7. 项目铁律', () {
    test('★★ 禁止 import flutter/material.dart（两套 Theme 串台）', () {
      for (final p in const [
        'lib/ui/player_page.dart',
        'lib/ui/widgets/player_settings_sheet.dart',
      ]) {
        expect(
          codeOf(p).contains("import 'package:flutter/material.dart'"),
          isFalse,
          reason: '★ `$p` 必须用 material_ui —— '
              'Flutter 3.47 拆包后混用会让 Theme.of 拿到亮色兜底（踩过）',
        );
      }
    });

    test('★★ 面板必须用 material_ui + forui', () {
      final sheet = codeOf('lib/ui/widgets/player_settings_sheet.dart');
      expect(sheet.contains("import 'package:material_ui/material_ui.dart'"),
          isTrue);
    });

    test('★ 面板不得新增依赖（只用 file_selector，它已在 pubspec 里）', () {
      /*
       * 任务明确要求"禁止加新依赖"。
       *
       * ⚠️ `file_selector` **不是本次加的** —— 它在 `pubspec.yaml` 的
       *    dependencies 里（`file_selector: ^1.0.3`），
       *    是另一个代理为文件对话框加的。
       *    这里断言"只用了它"，防止我在自己的文件里偷偷再引别的包。
       */
      final sheet = codeOf('lib/ui/widgets/player_settings_sheet.dart');
      final imports = RegExp(r"import 'package:([a-z_]+)/")
          .allMatches(sheet)
          .map((m) => m.group(1)!)
          .toSet();
      /*
       * ⚠️ `flutter` 是 **SDK 自带的库**（`package:flutter/services.dart`），
       *    不是 pub 依赖 —— 所以它必须被允许，否则「复制到剪贴板」
       *    （`Clipboard.setData`，task-18 ⑤）就没法写。
       *    本仓库先例：lib/ui/settings_page.dart 顶部同样 import 了
       *    `package:flutter/services.dart`。
       */
      expect(
        imports.difference({'file_selector', 'material_ui', 'flutter'}).isEmpty,
        isTrue,
        reason: '★ 面板只允许依赖 file_selector + material_ui（+ SDK 的 flutter），'
            '实际用了：$imports',
      );    });

    test('★ 面板不碰 mpv / 播放状态（纯 UI，可单测）', () {
      /*
       * 面板**不持有播放状态** —— 它只把宿主传进来的值画出来，
       * 用户改动时回调宿主。这样它才能脱离 libmpv 单测。
       */
      final sheet = codeOf('lib/ui/widgets/player_settings_sheet.dart');
      expect(sheet.contains('media_kit'), isFalse,
          reason: '★ 面板不得 import media_kit —— '
              '否则单测要拉起原生库才能构造');
      expect(sheet.contains('NativePlayer'), isFalse,
          reason: '★ 面板不得直接碰 NativePlayer');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  8. 面板的 widget 测试（真渲染 + 真点击）
  // ═══════════════════════════════════════════════════════════════════

  group('8. 设置面板 —— 真渲染与真点击', () {
    testWidgets('★ 三段都在（字幕 / 音轨 / 连播）', (t) async {
      await t.pumpWidget(_host(_sheet()));
      await t.pumpAndSettle();

      expect(find.text('播放设置'), findsOneWidget);
      expect(find.text('字幕'), findsOneWidget);
      /*
       * ⚠️ 「音轨」会出现**两次**：段落标题一次、行标签一次。
       *    这不是 bug（原版 ArtPlayer 面板同样有"标题 + 行标签"），
       *    所以这里断言 `findsWidgets`（至少一个）而不是 `findsOneWidget`。
       */
      expect(find.text('音轨'), findsWidgets);
      expect(find.text('连播'), findsOneWidget);
      // 外挂字幕入口
      expect(find.text('加载字幕文件…'), findsOneWidget);
    });

    testWidgets('★★ 点字幕轨会回调正确 id', (t) async {
      String? picked;
      await t.pumpWidget(_host(_sheet(
        onPickSubtitle: (id) => picked = id,
      )));
      await t.pumpAndSettle();

      // 「关闭」是伪轨道之一（id = 'no'）
      await t.tap(find.text('关闭').first);
      await t.pumpAndSettle();
      expect(picked, 'no',
          reason: '★ 点「关闭」必须回调 `no` —— '
              'mpv 手册：--sid=no disables subtitle decoding');
    });

    testWidgets('★★ 点音轨会回调正确 id', (t) async {
      String? picked;
      await t.pumpWidget(_host(_sheet(onPickAudio: (id) => picked = id)));
      await t.pumpAndSettle();

      /*
       * ⚠️ 面板内容比 600px 视口高，音轨那一段在**折叠线以下** ——
       *    直接 tap 会命中不了（或者点到别的控件上）。
       *    必须先滚进来，这也是"真渲染"测试该做的事
       *    （顺手验证了面板**确实可滚动** —— 不可滚动的话
       *      用户就够不到底部的连播设置了）。
       */
      final chip = find.text('国语 · aac');
      await t.scrollUntilVisible(chip, 120, scrollable: find.byType(Scrollable).first);
      await t.pumpAndSettle();
      await t.tap(chip);
      await t.pumpAndSettle();
      expect(picked, '1');
    });

    testWidgets('★★ 点「播放完」三项会回调正确的枚举', (t) async {
      PlayEndAction? got;
      await t.pumpWidget(_host(_sheet(onSetEndAction: (a) => got = a)));
      await t.pumpAndSettle();

      // 同上：连播段在最底部，要先滚进来
      final single = find.text('单集循环');
      await t.scrollUntilVisible(single, 120, scrollable: find.byType(Scrollable).first);
      await t.pumpAndSettle();
      await t.tap(single);
      await t.pumpAndSettle();
      expect(got, PlayEndAction.singleLoop,
          reason: '★ 「单集循环」必须回调 singleLoop');

      final stop = find.text('播完停止');
      await t.scrollUntilVisible(stop, 120, scrollable: find.byType(Scrollable).first);
      await t.pumpAndSettle();
      await t.tap(stop);
      await t.pumpAndSettle();
      expect(got, PlayEndAction.stop);
    });

    testWidgets('★★ 点 ASS 样式档位会带正确的 mpv wire 值', (t) async {
      String? prop;
      String? value;
      await t.pumpWidget(_host(_sheet(
        onSetMpvProperty: (k, v) {
          prop = k;
          value = v;
        },
      )));
      await t.pumpAndSettle();

      await t.tap(find.text('允许覆盖样式'));
      await t.pumpAndSettle();
      expect(prop, 'sub-ass-override');
      expect(value, 'yes',
          reason: '★ 必须写 mpv 手册的取值（no|yes|scale|force|strip）—— '
              '写中文标签进去 mpv 会静默忽略');
    });

    testWidgets('★★ 点颜色会带 `r/g/b` 形式的值', (t) async {
      String? prop;
      String? value;
      await t.pumpWidget(_host(_sheet(
        onSetMpvProperty: (k, v) {
          prop = k;
          value = v;
        },
      )));
      await t.pumpAndSettle();

      // 文字色那一排的「黄」（第 2 个）
      final swatches = find.byTooltip('1.00/1.00/0.00');
      expect(swatches, findsOneWidget, reason: '黄色预设必须存在');
      await t.tap(swatches);
      await t.pumpAndSettle();
      expect(prop, 'sub-color');
      expect(value, '1.00/1.00/0.00');
    });

    testWidgets('★★ 直播时**隐藏**连播整段（直播没有"播完"）', (t) async {
      await t.pumpWidget(_host(_sheet(isLive: true)));
      await t.pumpAndSettle();

      expect(find.text('连播'), findsNothing,
          reason: '★ 直播没有"播完"这回事 —— 显示这一段只会让人白试');
      // 但字幕/音轨仍然要有（直播流有字幕轨是常见的）
      expect(find.text('字幕'), findsOneWidget);
      // 「音轨」出现两次（段落标题 + 行标签），见上面那条的说明
      expect(find.text('音轨'), findsWidgets);
    });

    testWidgets('★ 没有字幕轨时给明确文案（不是空白）', (t) async {
      await t.pumpWidget(_host(_sheet(
        subtitleTracks: const [
          PlayerTrackOption(id: 'auto', label: '自动'),
          PlayerTrackOption(id: 'no', label: '关闭'),
        ],
      )));
      await t.pumpAndSettle();
      /*
       * 只剩伪轨 = 这条流没有真字幕轨，但"自动/关闭"仍可选。
       * ⚠️ 「自动」也会出现两次（字幕段一次、音轨段一次）——
       *    所以用 findsWidgets。
       */
      expect(find.text('自动'), findsWidgets);
      expect(find.text('关闭'), findsWidgets);
    });

    testWidgets('★ 已加载外挂字幕时显示文件名 + 移除按钮', (t) async {
      var removed = false;
      await t.pumpWidget(_host(_sheet(
        externalSubtitleName: '我的字幕.ass',
        onRemoveExternalSubtitle: () => removed = true,
      )));
      await t.pumpAndSettle();

      expect(find.text('我的字幕.ass'), findsOneWidget,
          reason: '★ 要显示加载的是哪个文件 —— 否则用户不知道挂上没');
      await t.tap(find.byTooltip('移除这条外挂字幕'));
      await t.pumpAndSettle();
      expect(removed, isTrue);
    });

    testWidgets('★ 点背景关闭面板', (t) async {
      var closed = false;
      await t.pumpWidget(_host(_sheet(onClose: () => closed = true)));
      await t.pumpAndSettle();

      // 点最外层 scrim（卡片之外的区域）
      await t.tapAt(const Offset(20, 20));
      await t.pumpAndSettle();
      expect(closed, isTrue, reason: '★ 点背景要能关（与播放页其它面板一致）');
    });

    testWidgets('★ 点卡片内部**不能**关掉面板（否则点滑块就关了）', (t) async {
      var closed = false;
      await t.pumpWidget(_host(_sheet(onClose: () => closed = true)));
      await t.pumpAndSettle();

      await t.tap(find.text('播放设置'));
      await t.pumpAndSettle();
      expect(closed, isFalse,
          reason: '★ 卡片内部要吃掉点击 —— 否则用户点一下标题面板就没了');
    });

    testWidgets('★ 字号滑块拖动会带数字字符串', (t) async {
      String? value;
      await t.pumpWidget(_host(_sheet(
        onSetMpvProperty: (k, v) {
          if (k == 'sub-font-size') value = v;
        },
      )));
      await t.pumpAndSettle();

      final slider = find.byType(Slider).first;
      await t.drag(slider, const Offset(40, 0));
      await t.pumpAndSettle();
      expect(value, isNotNull, reason: '★ 拖滑块要真的发出 sub-font-size');
      expect(int.tryParse(value!), isNotNull,
          reason: '★ mpv 的 sub-font-size 是整数像素 —— 不能传 "55.0"');
    });

    testWidgets('★★ 读不到样式值时滑块**禁用**（不能假装有默认值）', (t) async {
      await t.pumpWidget(_host(_sheet(mpvStyle: const {})));
      await t.pumpAndSettle();

      /*
       * ★ task-18 之后这条断言**收窄**了 —— 原来断言的是「面板里**所有**
       *   Slider 都必须禁用」，现在把「片段下载并发」那一根排除掉。
       *
       * 为什么排除它是对的、而不是放水：
       * ```text
       * 原断言的靶子是 **ASS 样式滑块** —— 它们的值**必须**从 mpv 读回来
       * （sub-font-size / sub-margin-y / sub-border-size），读不到就不能
       * 假装有个默认值，否则用户一打开面板就改了观感。
       *
       * 而 task-18 ③ 的并发滑杆值来源**根本不是 mpv**，是 UiPrefs 的
       * dsh.download.concurrency（ClipDownloader.concurrency，缺省 4）。
       * 那个 4 是**产品默认值**，不是「假装读到的 mpv 值」⇒ 它本来就该可用。
       * ```
       *
       * 排除判据取 (min == 0 && max == 8 && divisions == 8) —— 与
       * player_settings_sheet.dart 里那根滑杆的参数一一对应；并且断言
       * 这样的滑杆**有且只有一根**，防止将来有人把样式滑块也改成这个范围、
       * 从而把样式滑块偷渡出这条断言。
       */
      bool isConcurrencySlider(Slider s) =>
          s.min == 0 && s.max == 8 && s.divisions == 8;

      final sliders = t.widgetList<Slider>(find.byType(Slider)).toList();
      expect(sliders, isNotEmpty);

      final concurrencySliders = sliders.where(isConcurrencySlider).toList();
      expect(concurrencySliders.length, 1,
          reason: '★ 只允许「片段下载并发」这一根滑杆逃出下面的断言 —— '
              '多出来的说明有别的滑杆也用了 0-8 这个范围');
      expect(concurrencySliders.single.onChanged, isNotNull,
          reason: '★ 并发滑杆的值来自 UiPrefs（不是 mpv）⇒ 必须可用');

      final styleSliders = sliders.where((s) => !isConcurrencySlider(s));
      expect(styleSliders, isNotEmpty,
          reason: '★ 样式滑块还在（否则这条断言变成空转）');
      for (final s in styleSliders) {
        expect(s.onChanged, isNull,
            reason: '★ 读不到当前值时必须禁用 —— '
                '假装一个默认值等于"打开面板就改了用户观感"');
      }
      expect(find.text('读不到'), findsWidgets);
    });
  });
}
