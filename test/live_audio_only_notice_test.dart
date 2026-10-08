// ═══════════════════════════════════════════════════════════════════════
//  任务⑰⑧：直播"只有音频能播"时必须给出**非阻断提示**
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话
//
// > cctv看得到但是点开黑屏
//
// # 根因（独立实测，两条互补的证据链）
//
// ```text
// ① 核心层 get_live_stream(cctv, cctv1) 的真实返回（已核对原始 JSON）：
//      高清    drm_protected: true
//      标清    drm_protected: true
//      仅音频  drm_protected: 缺失      ← 只有它通过 isPlayable
//
// ② ffmpeg（与 mpv 完全不同的解码器）实测：
//      音频线  Stream #0:0: Audio: aac …   ← ★ 没有 video 流 ⇒ 必然全黑
//      高清线  250 帧 / 386 条解码错误：
//              [h264] error while decoding MB 9 0, bytestream 42177
//              [dec] corrupt decoded frame
//              [h264] Cannot use next picture in error concealment
//      本地对照 450 帧 / 0 错误              ← 证明判据本身有效
// ```
// ⇒ 视频轨确实被加密，音频是唯一能播的。**这不是我们的 bug**，
//   但"静默播成黑屏"是。原版会明确告知（`PlayerView.vue:4281-4299`）。
//
// # 本测试锁住什么
//
// 判据是**纯 Dart 逻辑**（不看源码字符串），所以直接跑真值表：
// ```text
// 有 DRM 视频线 + 只剩音频可播  → 提示「已切换到音频收听」
// 有可播的视频线               → 不提示（正常能看，别打扰）
// 全部线路都不可播             → 走 _error 分支（"所有线路都不可播"）
// 点播（非直播）               → 不提示（这条通道只对直播有意义）
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/models.dart';

/// 复刻 `_PlayerPageState._load()` 里的判定（保持与生产代码同构）
///
/// ⚠️ 这是一份**逻辑镜像**。之所以不直接调私有方法：`_load()` 依赖
///    FFI 核心 + 真实播放器。镜像的风险是"两边漂移" ——
///    所以同时用源码契约测试锁住生产代码里有这段判定（见下）。
String? decideNotice({
  required bool isLive,
  required List<StreamCandidate> list,
}) {
  final playableLines = list.where((s) => s.isPlayable).toList();
  if (playableLines.isEmpty) return null; // 走 _error 分支，不是这条
  final first = playableLines.first;
  final hasDrmVideo = list.any(
    (s) => s.drmProtected && (s.quality == '高清' || s.quality == '标清'),
  );
  final onlyAudioPlayable = !playableLines
      .any((s) => s.quality == '高清' || s.quality == '标清');
  if (!isLive || !hasDrmVideo || !onlyAudioPlayable) return null;
  return first.displayName;
}

StreamCandidate cand({
  required String url,
  required String quality,
  bool drm = false,
}) =>
    StreamCandidate.fromJson(<String, dynamic>{
      'url': url,
      'kind': 'hls',
      'quality': quality,
      'label': '$quality线路',
      'headers': [
        ['Referer', 'https://tv.cctv.com/'],
      ],
      'drm_protected': drm,
    });

void main() {
  group('任务⑰⑧ 直播只剩音频时必须提示（否则用户只看到黑屏）', () {
    test('★ 真实央视场景：视频线全 DRM + 音频可播 → 必须提示', () {
      // 这三条就是核心层对 cctv1 的真实返回
      final list = <StreamCandidate>[
        cand(url: 'https://x/udrmldcctv1_1/index.m3u8', quality: '高清', drm: true),
        cand(url: 'https://y/ldcctv1_2/index.m3u8', quality: '标清', drm: true),
        cand(url: 'https://z/audio/cctv1_2.m3u8', quality: '仅音频'),
      ];
      expect(list.where((s) => s.isPlayable).length, 1,
          reason: '只有「仅音频」应通过 isPlayable');
      final notice = decideNotice(isLive: true, list: list);
      expect(notice, isNotNull,
          reason: '★ 这就是"点开黑屏"的场景 —— 必须告诉用户为什么没有画面，'
              '而不是静默播一条纯音频流');
      expect(notice, contains('仅音频'));
    });

    test('有可播的视频线时**不**提示（正常能看，别打扰）', () {
      final list = <StreamCandidate>[
        cand(url: 'https://x/hd.m3u8', quality: '高清'), // 可播
        cand(url: 'https://y/sd.m3u8', quality: '标清', drm: true),
      ];
      expect(decideNotice(isLive: true, list: list), isNull,
          reason: '既然有能出画面的线路，就不该弹 DRM 提示');
    });

    test('点播（非直播）不提示 —— 这条通道只对直播有意义', () {
      final list = <StreamCandidate>[
        cand(url: 'https://x/udrm.m3u8', quality: '高清', drm: true),
        cand(url: 'https://z/audio.m3u8', quality: '仅音频'),
      ];
      expect(decideNotice(isLive: false, list: list), isNull,
          reason: '点播的 DRM 场景走"所有线路都不可播"那条分支，'
              '不该复用直播的音频提示');
    });

    test('有线可播但没有 DRM 视频线时不提示（普通直播源）', () {
      final list = <StreamCandidate>[
        cand(url: 'https://x/only.m3u8', quality: '仅音频'),
      ];
      expect(decideNotice(isLive: true, list: list), isNull,
          reason: '没有"被 DRM 挡掉的视频线"时，'
              '用户看到黑屏属于源本身的问题，不该甩锅给 DRM');
    });
  });

  group('任务⑰⑧ 源码契约：提示必须真的接进播放页', () {
    /*
     * 上面那组用**逻辑镜像**验证判据本身。镜像的风险是"两边漂移" ——
     * 生产代码删了这段判定，镜像测试照样绿。
     * 所以这里补一条源码断言，把两边钉在一起。
     */
    late String src;

    setUpAll(() {
      src = File('lib/ui/player_page.dart').readAsStringSync();
    });

    test('★ 播放页必须判定「只剩音频可播」并给出提示', () {
      expect(
        src.contains('_liveAudioOnlyNotice'),
        isTrue,
        reason: '必须有这个字段 —— 用户报的"点开黑屏"就是缺了这层告知',
      );
      expect(
        src.contains('hasDrmVideo') && src.contains('onlyAudioPlayable'),
        isTrue,
        reason: '判定的两个条件（有 DRM 视频线 / 只剩音频可播）都要在',
      );
    });

    test('★★ 提示**不能**写进 `_error`（它会被 _startPlayback 清掉）', () {
      /*
       * `_startPlayback()` 开头就 `_error = null`（语义是"起播失败"）。
       * 若把这条提示塞进 `_error`，它会在起播瞬间被清空 ——
       * 用户**依旧看到黑屏且没有任何解释**，等于没修。
       */
      final i = src.indexOf('_liveAudioOnlyNotice = audioOnlyNotice');
      expect(i, greaterThan(-1), reason: '找不到赋值点');
      // 附近的语句里不应出现 `_error =`
      final seg = src.substring(
        i > 400 ? i - 400 : 0,
        (i + 400) < src.length ? i + 400 : src.length,
      );
      expect(
        seg.contains('_error ='),
        isFalse,
        reason: '★ 提示字段附近不得给 `_error` 赋值 —— '
            '`_error` 在 `_startPlayback()` 里会被置空，提示会消失',
      );
    });

    test('★ 提示横幅必须被渲染（否则字段算了也没人看到）', () {
      expect(
        src.contains('_LiveAudioOnlyBanner'),
        isTrue,
        reason: '必须有对应的横幅 Widget 且在 build 里渲染',
      );
    });
  });
}
