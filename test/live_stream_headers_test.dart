// ═══════════════════════════════════════════════════════════════════════
//  任务⑰⑧：直播黑屏 —— 播放器必须收到 `headers`（Referer）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话
//
// > 直播为什么不能看?我做的是插件,为什么不能播放我的源?
// > （澄清后）cctv看得到但是点开黑屏
//
// # 根因（实测，不是推断）
//
// 点播和直播**不一样**：
// ```text
// 点播 resolve_stream(154,...)
//   url = http://127.0.0.1:56008/s/...      ← 本地代理，防盗链已在代理里处理
//   → 不传 headers 也能播
//
// 直播 get_live_stream(cctv, cctv1)
//   url = https://ldncctv...myqcloud.com/... ← ★ 原始地址，**没有代理**
//   headers = [["Referer","https://tv.cctv.com/"]]
//   → ★ 必须有 Referer，否则 403
// ```
// curl 同一条 m3u8 实测：
// ```text
// 不带 Referer  → HTTP 403 已禁止
// 带 Referer    → HTTP 200 + 合法 m3u8
// ```
// 而播放器原先写的是 `Media(st.url)` —— **headers 全丢** → 403 → 黑屏。
//
// # 本测试守住什么
//
// ```text
// ① StreamCandidate.httpHeaders 把 [[k,v],...] 正确转成 Map（含顺序/去重）
// ② 空 headers → 空 Map（不能变成 null 或抛异常）
// ③ 端到端：Media 真的带上了 httpHeaders（而不是"改了一行但没接上"）
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/models.dart';

void main() {
  group('任务⑰⑧ 直播必须带上 Referer', () {
    test('httpHeaders 把核心层的有序列表转成 media_kit 要的 Map', () {
      const st = StreamCandidate(
        url: 'https://ldncctvwbndtxy.liveplay.myqcloud.com/x/index.m3u8',
        kind: 'hls',
        headers: [
          ('Referer', 'https://tv.cctv.com/'),
        ],
      );

      expect(st.httpHeaders, {'Referer': 'https://tv.cctv.com/'});
      // 这正是 media_kit `Media(httpHeaders:)` 收的类型
      expect(st.httpHeaders, isA<Map<String, String>>());
    });

    test('多个 header 全部保留', () {
      const st = StreamCandidate(
        url: 'https://example.com/a.m3u8',
        headers: [
          ('Referer', 'https://tv.cctv.com/'),
          ('User-Agent', 'Mozilla/5.0'),
        ],
      );
      expect(st.httpHeaders.length, 2);
      expect(st.httpHeaders['Referer'], 'https://tv.cctv.com/');
      expect(st.httpHeaders['User-Agent'], 'Mozilla/5.0');
    });

    test('没有 headers 时是空 Map（不是 null，也不抛）', () {
      const st = StreamCandidate(url: 'http://127.0.0.1:56008/s/abc/');
      expect(st.httpHeaders, isEmpty);
      // 空 Map 传给 media_kit 是安全的（它用 `?? cache[...]` 兜底）
      expect(() => Media(st.url, httpHeaders: st.httpHeaders), returnsNormally);
    });

    test('同名 header 只保留第一个（Map 无法表达重复键，如实约束）', () {
      const st = StreamCandidate(
        url: 'https://example.com/a.m3u8',
        headers: [
          ('Referer', 'https://first.example/'),
          ('Referer', 'https://second.example/'),
        ],
      );
      expect(st.httpHeaders.length, 1);
      expect(st.httpHeaders['Referer'], 'https://first.example/');
    });

    test('端到端：直播候选的 Referer 真的到了 Media 上', () {
      // 模拟 core 的 get_live_stream(cctv, cctv1) 真实返回
      final st = StreamCandidate.fromJson(<String, dynamic>{
        'url': 'https://ldncctvwbndtxy.liveplay.myqcloud.com/'
            'ldcctvwbnd/ldcctv1_2/index.m3u8',
        'kind': 'hls',
        'quality': '标清',
        'headers': [
          ['Referer', 'https://tv.cctv.com/'],
        ],
        'drm_protected': false,
      });

      expect(st.isPlayable, isTrue, reason: '标清线路不是 DRM，应当可播');

      // ★ 这就是播放器该做的那一步（player_page.dart 的 `_startPlayback`）
      final media = Media(st.url, httpHeaders: st.httpHeaders);

      expect(
        media.httpHeaders,
        isNotNull,
        reason: 'Media 必须带上 httpHeaders —— 丢了就是 403/黑屏',
      );
      expect(media.httpHeaders!['Referer'], 'https://tv.cctv.com/');
      expect(media.uri, st.url);
    });

    test('DRM 线路被 isPlayable 拦下（不会静默黑屏）', () {
      final st = StreamCandidate.fromJson(<String, dynamic>{
        'url': 'https://ldncctvcpudtxy.liveplay.myqcloud.com/x/index.m3u8',
        'kind': 'hls',
        'quality': '高清',
        'headers': [
          ['Referer', 'https://tv.cctv.com/'],
        ],
        'drm_protected': true,
      });
      expect(st.drmProtected, isTrue);
      expect(st.isPlayable, isFalse,
          reason: 'DRM 线路必须被拦下，让 UI 走"所有线路都不可播"的提示分支，'
              '而不是交给播放器去黑屏');
    });
  });

  group('任务⑰⑧ 源码契约：起播必须把 headers 传给播放器', () {
    /*
     * ⚠️ 这里做**源码级**断言，是因为 `_startPlayback` 是私有方法，
     *    无法从外部直接调用；而"headers 有没有接上"正是这次缺陷的本体。
     *    单测 `Media` 能否携带 headers 只证明了一半 ——
     *    如果调用点写回 `Media(st.url)`，功能照样是坏的。
     */
    late String playerSrc;

    /// 去掉注释后再断言 —— 否则失败原因里引用的 `Media(st.url)`
    /// 会把自己也判失败（修复说明里正当地提到了那个旧写法）。
    String stripComments(String s) {
      final noBlock = s.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
      return noBlock
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
    }

    setUpAll(() {
      playerSrc = stripComments(File('lib/ui/player_page.dart').readAsStringSync());
    });

    test('★ 直播起播处不得再出现裸的 Media(st.url)', () {
      expect(
        playerSrc.contains('Media(st.url)'),
        isFalse,
        reason: '`Media(st.url)` 会把 headers 全丢掉 —— 直播因此 403/黑屏。'
            '必须写成 `Media(st.url, httpHeaders: st.httpHeaders)`',
      );
    });

    test('★ 起播处确实传了 httpHeaders', () {
      expect(
        playerSrc.contains('Media(st.url, httpHeaders: st.httpHeaders)'),
        isTrue,
        reason: '起播必须带上核心层给的请求头（央视直播需要 Referer，'
            '实测不带 → 403，带 → 200）',
      );
    });

    test('★ models.dart 的误导性注释已修正（它会把下一个人带沟里）', () {
      final models = File('lib/core/models.dart').readAsStringSync();
      expect(
        models.contains('通常已是**本地代理地址**'),
        isFalse,
        reason: '原注释断言"通常已是本地代理地址 / 不需要再处理请求头"，'
            '**只对点播成立** —— 直播返回的是原始地址且必须有 Referer。'
            '这条错误前提正是本次黑屏的温床，必须删掉。',
      );
      expect(
        models.contains('**不一定是本地代理地址**'),
        isTrue,
        reason: '必须留下改正后的说明（点播走代理 / 直播是原始地址）',
      );
    });

    test('★★ mpv 必须允许跨源播放列表（黑屏的第 2 个原因）', () {
      /*
       * 修好 Referer 之后**仍然黑屏**，实测日志：
       * ```text
       * PLAYER-ERROR Refusing to load potentially unsafe URL from a playlist.
       * PLAYER-ERROR Use the --load-unsafe-playlists option to load it anyway.
       * ```
       * 央视的 .m3u8 主列表引用了**另一个主机**上的子列表，
       * mpv 默认拒绝加载 → 必须显式开 `load-unsafe-playlists`。
       *
       * 这里断言源码里有这一句 —— 因为它是在 `_setHwdec()` 里、
       * 无法从外部调用的私有路径；删掉它直播会静默回到黑屏。
       */
      expect(
        playerSrc.contains("setProperty('load-unsafe-playlists', 'yes')"),
        isTrue,
        reason: '必须给 mpv 开 load-unsafe-playlists，否则跨源 HLS 播放列表'
            '会被拒绝加载 → 直播黑屏（实测报 "Refusing to load potentially '
            'unsafe URL from a playlist"）',
      );
    });
  });
}
