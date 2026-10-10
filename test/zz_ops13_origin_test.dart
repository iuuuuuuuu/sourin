// ///////////////////////////////////////////////////////////////////////////
//  OPS-13 反馈 C：续播进度「来源身份」—— 纯判据（不挂页面、不碰 FFI）
// ///////////////////////////////////////////////////////////////////////////
//
// # Owner 原话（逐字）
//
// > 续播进度,我希望的是我缓存这集了,但是如果我在线看,他还能记得我看过
// > 而不是 本地和线上的就彻底分开了,你懂不
//
// # 本文件钉住什么
//
// `lib/core/progress_origin.dart` 是「统一键」的**唯一下拉点**。它是纯函数，
// 所以这里全部是**行为断言**（不是「看源码里有没有那行字」）。
//
// # ★ 为什么单列一个文件（而不是塞进挂页面的那个）
//
// 挂 `MediaPage`/`PlayerPage` 的用例需要 media_kit / 真 dll 才能真跑；
// 而这一批判据**零依赖** —— 任何机器上都必须能跑、必须能红。
// 混在一起的话，环境一跳过就把纯判据一起跳掉了。
//
// # ★ 环境探针那条为什么在最后
//
// `flutter_tester` 能不能加载 `sourin_core.dll` 决定「端到端」那两条
// （`zz_ops13_mirror_write_test.dart` / `zz_ops13_resume_read_test.dart`）
// 是真跑还是如实跳过。这里先量出来并**如实打印**，
// 免得后面那两条悄悄变成假绿。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/progress_origin.dart';
import 'package:sourin_spike/ui/cache_page.dart' show kLocalProvider;

String _src(String rel) => File(rel).readAsStringSync();

void main() {
  group('① 命名空间常量：只有一处定义这条铁律', () {
    test('★★★ kProgressLocalProvider 必须与 kLocalProvider 是同一个值', () {
      /*
       * # 为什么这条是硬判据
       *
       * `local` 这个字面量现在有两处：`lib/ui/cache_page.dart:787`（历史）
       * 与 `lib/core/progress_origin.dart`（本轮，因为 core 不许 import ui）。
       * 谁改了一处而没改另一处，本地进度的键就**静默**对不上了 ——
       * 不报错，只是永远查不到（Rust 侧注释原话：拼错不会报错，只会静默查不到）。
       */
      expect(
        kProgressLocalProvider,
        kLocalProvider,
        reason: '★★★ 两个常量必须同值 —— 否则本地进度键会静默错位',
      );
    });
  });

  group('② 键格式：与 Rust item_key 同构（两边一起钉）', () {
    test('★★★ 键 = "provider:mediaId"，与 Rust 的 format! 逐字同构', () {
      expect(canonicalProgressKey('bilibili', 'BV1xx411c7mD'),
          'bilibili:BV1xx411c7mD');
      expect(canonicalProgressKey('dandanplay', '36578'), 'dandanplay:36578');
      /*
       * ★ 本地键：绝对路径里既有 `:`（盘符）又有 `/`，**不做任何转义**。
       *   转义的话就与 Rust 那条键不一致了 —— 而 Rust 是唯一拼键的地方。
       */
      expect(canonicalProgressKey('local', 'D:/源影/第01集.mp4'),
          'local:D:/源影/第01集.mp4');
    });

    test('★★★ 两端格式契约（源码扫描）：Rust 与 Dart 的拼法必须一致', () {
      final rust = _src('rust/sourin_core/src/commands_write.rs');
      expect(rust.contains('format!("{provider}:{id}")'), isTrue,
          reason: '★ Rust 侧的 item_key 变了 —— Dart 侧必须同步（它是唯一拼键点）');
      final dart = _src('lib/core/progress_origin.dart');
      expect(dart.contains("'\$provider:\$mediaId'"), isTrue,
          reason: '★ Dart 侧的拼法必须是 provider + ":" + mediaId');
    });
  });

  group('③ ProgressOrigin.of：不猜', () {
    test('★★★ 任一侧缺失/全空白 => null（宁可没有来源，也不要错的来源）', () {
      expect(ProgressOrigin.of(provider: null, mediaId: '36578'), isNull);
      expect(ProgressOrigin.of(provider: 'dandanplay', mediaId: null), isNull);
      expect(ProgressOrigin.of(provider: '', mediaId: '36578'), isNull);
      expect(ProgressOrigin.of(provider: 'dandanplay', mediaId: ''), isNull);
      expect(ProgressOrigin.of(provider: '   ', mediaId: '36578'), isNull);
      expect(ProgressOrigin.of(provider: 'dandanplay', mediaId: '  '), isNull);
    });

    test('★ 两侧都在 => 原样（首尾空白裁掉）', () {
      final o = ProgressOrigin.of(provider: ' bilibili ', mediaId: ' BV1 ');
      expect(o, isNotNull);
      expect(o!.provider, 'bilibili');
      expect(o.mediaId, 'BV1');
      expect(o, ProgressOrigin.of(provider: 'bilibili', mediaId: 'BV1'),
          reason: '★ 值相等 => == 成立（否则 `if (origin == ...)` 之类的判断会静默失效）');
    });
  });

  group('④ localProgressOrigin：从 CachedPlayRequest 的两个字段得到来源', () {
    test('★★★ 旁文件没来源 => null', () {
      expect(localProgressOrigin(originProvider: null, originMediaId: null),
          isNull);
      expect(localProgressOrigin(originProvider: '', originMediaId: ''), isNull);
    });

    test('★★★ 来源本身就是 local => null（镜像到 local 键 = 原地重写）', () {
      expect(
        localProgressOrigin(originProvider: 'local', originMediaId: 'D:/a.mp4'),
        isNull,
        reason: '★ 旁文件写 local 时不能拿它当"原来源" —— 那会写一条重复的 local 键',
      );
    });

    test('★ 真来源 => 原样透出', () {
      final o = localProgressOrigin(
          originProvider: 'bilibili', originMediaId: 'BV1xx411c7mD');
      expect(o!.provider, 'bilibili');
      expect(o.mediaId, 'BV1xx411c7mD');
    });
  });

  group('⑤ mirrorOriginFor：三条拒绝 + 一条放行', () {
    const origin = ProgressOrigin(provider: 'bilibili', mediaId: 'BV1');

    test('★★★ 没有来源 => 不镜像', () {
      expect(mirrorOriginFor(null, sessionProvider: 'local'), isNull);
    });

    test('★★★ 来源是 local => 不镜像', () {
      expect(
        mirrorOriginFor(
            const ProgressOrigin(provider: 'local', mediaId: 'D:/a.mp4'),
            sessionProvider: 'bilibili'),
        isNull,
      );
    });

    test('★★★ 来源 provider == 会话 provider => 不镜像（会覆盖会话自己那条）', () {
      /*
       * 这一条是**硬约束**，不是洁癖：镜像那条按设计**不带 episode_id**
       * （见 PlayerPage._saveProgress），一旦真打到会话自己的键上，
       * 就会把正常那条的 episode_id 抹成 NULL
       * => 续播的「按集校验」（player_page.dart:3390）失效
       * => 上一集的进度串到这一集。
       */
      expect(mirrorOriginFor(origin, sessionProvider: 'bilibili'), isNull);
    });

    test('★ 来源是别的站点 => 放行（本地会话的常规情形）', () {
      expect(mirrorOriginFor(origin, sessionProvider: 'local'), origin);
      expect(mirrorOriginFor(origin, sessionProvider: 'dandanplay'), origin);
    });
  });

  group('⑥ mirrorProgressTitle：标题优先，退到文件名时要去后缀', () {
    test('★★★ 有集标题 => 用它（不看文件名）', () {
      expect(
        mirrorProgressTitle(episodeTitle: '第03集', episodeFileName: '第03集 x.mp4'),
        '第03集',
      );
    });

    test('★★★ 没有集标题 => 文件名去后缀（本地会话手上只有文件名）', () {
      /*
       * 本地会话的 `episodeId` 是文件名（shell.dart:4830 传 `req.episode.fileName`），
       * 而 `CachedEpisode` 根本没有 `episodeTitle` 字段（cache_page.dart:134-156）
       * => 不剥后缀的话，播放记录里会出现「第01集.mp4」这种条目。
       */
      expect(
        mirrorProgressTitle(episodeTitle: '', episodeFileName: '第01集 CR13.mp4'),
        '第01集 CR13',
      );
      expect(
        mirrorProgressTitle(episodeTitle: '  ', episodeFileName: '正片.mkv'),
        '正片',
      );
      // `.part`（下载中的半截文件）也要剥
      expect(
        mirrorProgressTitle(episodeTitle: '', episodeFileName: '第02集.mp4.part'),
        '第02集',
      );
      // 没有后缀 => 原样
      expect(
        mirrorProgressTitle(episodeTitle: '', episodeFileName: '无后缀'),
        '无后缀',
      );
    });

    test('★★★ 两边都空 => null（不写镜像）', () {
      /*
       * ★ 不能退化成空串：Rust 的 upsert_progress 对空标题是「保留旧值」
       *   （store.rs:932-947 的 CASE WHEN excluded.title <> ''），
       *   写一条空标题只会白刷 updated_at，把「取更新的那条」判据带偏。
       */
      expect(mirrorProgressTitle(episodeTitle: '', episodeFileName: ''), isNull);
      expect(mirrorProgressTitle(episodeTitle: ' ', episodeFileName: '  '), isNull);
      expect(mirrorProgressTitle(episodeTitle: '', episodeFileName: '.mp4'), isNull);
    });
  });

  group('⑦ progressBelongsToCurrentEpisode：与 player_page.dart:3390 逐字等价', () {
    test('★★★ 四种组合', () {
      // ① 进度那条没有集信息（老数据 / 镜像那条）=> 放行
      expect(
        progressBelongsToCurrentEpisode(
            progressEpisodeId: null, currentEpisodeId: '51463'),
        isTrue,
        reason: '★ 镜像那条故意不带 episode_id —— 就是靠这里放行，否则永远续不上',
      );
      expect(
        progressBelongsToCurrentEpisode(
            progressEpisodeId: '', currentEpisodeId: '51463'),
        isTrue,
      );
      // ② 当前会话不知道自己是哪一集 => 放行（= :3390 的 curEpId != null 不成立）
      expect(
        progressBelongsToCurrentEpisode(
            progressEpisodeId: '51463', currentEpisodeId: null),
        isTrue,
      );
      // ③ 同一集 => 放行
      expect(
        progressBelongsToCurrentEpisode(
            progressEpisodeId: '51463', currentEpisodeId: '51463'),
        isTrue,
      );
      // ④ 不同集 => 拒绝（上一集的进度不能串到这一集）
      expect(
        progressBelongsToCurrentEpisode(
            progressEpisodeId: '51463', currentEpisodeId: '51464'),
        isFalse,
        reason: '★★ 这条拒绝必须还在 —— 否则看完第 3 集点开第 4 集会被 seek 到结尾',
      );
      expect(
        progressBelongsToCurrentEpisode(
            progressEpisodeId: '51463', currentEpisodeId: '第01集.mp4'),
        isFalse,
        reason: '★ 本地会话的"集号"是文件名 —— 站点集 id 与它**必然不等**',
      );
    });
  });

  group('⑧ 环境探针：真核心能不能在本测试进程里加载', () {
    test('★ 探针（决定端到端两条是真跑还是如实跳过）', () async {
      final dir = Directory('${Directory.systemTemp.absolute.path}'
          '${Platform.pathSeparator}ops13_core');
      var ok = false;
      String why = '';
      try {
        if (!dir.existsSync()) dir.createSync(recursive: true);
        await SourinCore.startAsync(dir.path);
        ok = SourinCore.isStarted;
        why = ok ? '核心已启动' : 'startAsync 返回了但 isStarted=false';
      } catch (e) {
        why = e.toString();
      }
      // ignore: avoid_print
      print('[OPS13] 真核心探针: ok=$ok  why=$why');
      if (!ok) {
        return markTestSkipped(
            'flutter_tester 加载不了 sourin_core.dll（$why）—— '
            '端到端那两条会如实跳过并打印原因');
      }
      expect(SourinCore.isStarted, isTrue);
    });
  });
}
