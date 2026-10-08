// ═══════════════════════════════════════════════════════════════════════
//  task-39 单元测试：可用性判定 + 循环切换
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么这两块必须单测（都是"坏了很安静"的逻辑）
// ```text
// ① 可用性判定：判错的后果是"能播的台被藏起来"（用户以为源坏了）
//    或"不能播的台还显示"（用户点进去黑屏 —— 正是他报的问题）
// ② 循环切换：末位 +1 要回到 0。算错的表现是"按到最后一个就卡住"
//    ★ 这类**边界**逻辑最适合单测（跑得快、不用起 UI）
// ```

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/live_availability.dart';

StreamCandidate _cand({
  String url = 'http://x/y.m3u8',
  String? quality,
  String? label,
  bool drm = false,
}) =>
    StreamCandidate(
      url: url,
      kind: 'hls',
      quality: quality,
      label: label,
      drmProtected: drm,
    );

void main() {
  group('task-39 直播可用性判定', () {
    test('★ cctv 的真实形态：视频线全 DRM + 一条音频 ⇒ audioOnly', () {
      /*
       * 实测来源（.probe/t39_decode_v2.py，真解码）：
       * ```text
       * 高清  drm=true   197 帧 / 223 个解码错误  ⇒ 不可播
       * 标清  drm=true   连不上
       * 仅音频 drm 缺失  ★ 可播
       * ```
       * ⇒ 这正是用户说"不可用"的那些台。
       */
      final list = [
        _cand(quality: '高清', drm: true),
        _cand(quality: '标清', drm: true),
        _cand(quality: '仅音频', label: '广播'),
      ];
      expect(classifyStreams(list), LiveAvailability.audioOnly);
    });

    test('全 DRM（连音频都没有）⇒ unavailable', () {
      final list = [
        _cand(quality: '高清', drm: true),
        _cand(quality: '标清', drm: true),
      ];
      expect(classifyStreams(list), LiveAvailability.unavailable);
    });

    test('★ iptv 的形态（有可播视频线）⇒ playable', () {
      final list = [_cand(quality: '高清')];
      expect(classifyStreams(list), LiveAvailability.playable);
    });

    test('多线路里只要有一条带视频的可播 ⇒ playable（不是 audioOnly）', () {
      final list = [
        _cand(quality: '高清', drm: true),
        _cand(quality: '标清'), // 可播且有视频
        _cand(quality: '仅音频', label: '广播'),
      ];
      expect(classifyStreams(list), LiveAvailability.playable);
    });

    test('空列表 ⇒ unavailable（不是 unknown）', () {
      // ★ 区别很重要：空 = 源明确说没有线路；失败才是 unknown
      expect(classifyStreams(const []), LiveAvailability.unavailable);
    });

    test('url 为空的线路不算可播', () {
      final list = [_cand(url: '', quality: '高清')];
      expect(classifyStreams(list), LiveAvailability.unavailable);
    });

    group('isAudioOnlyLine（音频线识别）', () {
      test('cctv 的 "仅音频"/"广播" 都命中', () {
        expect(isAudioOnlyLine(_cand(quality: '仅音频')), isTrue);
        expect(isAudioOnlyLine(_cand(label: '广播')), isTrue);
        expect(isAudioOnlyLine(_cand(label: 'Audio')), isTrue);
      });

      test('★ 认不出时**保守当成视频线**（倾向显示，不误藏）', () {
        // 判据说的是"包含关键字" ⇒ 未知线路返回 false ⇒ 当成视频
        expect(isAudioOnlyLine(_cand(quality: '高清')), isFalse);
        expect(isAudioOnlyLine(_cand()), isFalse);
      });
    });

    group('★ shouldShowByDefault（默认显示策略）', () {
      test('playable / unknown ⇒ 显示', () {
        expect(shouldShowByDefault(LiveAvailability.playable), isTrue);
        // ★ unknown 必须显示 —— 否则"探不到"被当成"不可用"
        //   ⇒ 用户列表随网络状况随机变少（比不隐藏更糟）
        expect(shouldShowByDefault(LiveAvailability.unknown), isTrue);
      });

      test('audioOnly / unavailable ⇒ 默认隐藏（用户要求"不显示"）', () {
        expect(shouldShowByDefault(LiveAvailability.audioOnly), isFalse);
        expect(shouldShowByDefault(LiveAvailability.unavailable), isFalse);
      });
    });

    group('LiveAvailabilityProbe 缓存与失败处理', () {
      test('★★ 探测**失败**必须记 unknown（不是 unavailable）', () async {
        /*
         * # 这是本模块最重要的一条
         * ```text
         * 网络抖动 ⇒ fetch 抛异常
         * 若记成 unavailable ⇒ 那些台**被隐藏**
         *   ⇒ 用户的频道列表会随网络状况随机变少
         * ★ 正确：记 unknown ⇒ 照常显示（宁可多显示，不可误藏）
         * ```
         */
        final probe = LiveAvailabilityProbe(
          fetch: (p, id) async => throw Exception('网络炸了'),
        );
        await probe.probe([
          const LiveGroup(
            provider: 'cctv',
            providerName: '央视',
            channels: [LiveChannel(id: 'cctv1', name: 'CCTV-1')],
          ),
        ]);
        expect(probe.cached('cctv', 'cctv1'), LiveAvailability.unknown);
      });

      test('探测成功 ⇒ 结果进缓存，第二次 probe 不重复请求', () async {
        var calls = 0;
        final probe = LiveAvailabilityProbe(
          fetch: (p, id) async {
            calls++;
            return [_cand(quality: '高清')];
          },
        );
        final groups = [
          const LiveGroup(
            provider: 'iptv',
            providerName: 'IPTV',
            channels: [LiveChannel(id: 'CCTV1.cn@SD', name: 'CCTV-1')],
          ),
        ];
        await probe.probe(groups);
        expect(calls, 1);
        expect(probe.cached('iptv', 'CCTV1.cn@SD'), LiveAvailability.playable);

        // 第二次：命中缓存 ⇒ 不再请求
        final n = await probe.probe(groups);
        expect(n, 0, reason: '有有效缓存时不该重复探测');
        expect(calls, 1);
      });

      test('force=true 时忽略缓存重新探测', () async {
        var calls = 0;
        final probe = LiveAvailabilityProbe(
          fetch: (p, id) async {
            calls++;
            return [_cand(quality: '高清')];
          },
        );
        final groups = [
          const LiveGroup(
            provider: 'iptv',
            providerName: 'IPTV',
            channels: [LiveChannel(id: 'a', name: 'A')],
          ),
        ];
        await probe.probe(groups);
        await probe.probe(groups, force: true);
        expect(calls, 2);
      });

      test('并发池：多个频道都探到（不因并发漏掉）', () async {
        final probe = LiveAvailabilityProbe(
          concurrency: 4,
          fetch: (p, id) async => [_cand(quality: '高清')],
        );
        final groups = [
          LiveGroup(
            provider: 'iptv',
            providerName: 'IPTV',
            channels: [
              for (var i = 0; i < 20; i++)
                LiveChannel(id: 'ch$i', name: '频道 $i'),
            ],
          ),
        ];
        final n = await probe.probe(groups);
        expect(n, 20);
        for (var i = 0; i < 20; i++) {
          expect(probe.cached('iptv', 'ch$i'), LiveAvailability.playable,
              reason: '并发探测漏了 ch$i');
        }
      });

      test('TTL 过期后重新探测', () async {
        var calls = 0;
        final probe = LiveAvailabilityProbe(
          ttl: const Duration(milliseconds: 30),
          fetch: (p, id) async {
            calls++;
            return [_cand(quality: '高清')];
          },
        );
        final groups = [
          const LiveGroup(
            provider: 'iptv',
            providerName: 'IPTV',
            channels: [LiveChannel(id: 'a', name: 'A')],
          ),
        ];
        await probe.probe(groups);
        expect(calls, 1);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await probe.probe(groups);
        expect(calls, 2, reason: 'TTL 过期后应重新探测');
      });
    });
  });
}
