// ═══════════════════════════════════════════════════════════════════════
//  task-69：搜索/换源结果必须带上「来源有多少集」
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
// ```text
// 2.切换源和搜索页,结果都应该展示出来来源有多少集,这样子可以很方便的
//   知道那个源最好最快,还有支持画质(如果包含这个信息的话)
// ```
//
// # ★★★ 这个文件守的是什么（一个静默了很多轮的真 bug）
//
// ```text
// 后端发的是   {"subtitle": "全 27 集", "badges": ["全 1 集", "7.0 分"]}
// 前端原来读    j['note']        ← 键名不匹配 ⇒ note **恒为 null**
// ```
// ⇒ 6 处读 `.note` 的界面**全部**拿不到副标题：
// ```text
//   home_page.dart:995 ／ browse_page.dart:297 ／ search_page.dart:495
//   source_switch_dialog.dart:574 ／ remote_bridge.dart:1069,1182
// ```
//
// # ★ fixture 全部是**真实 FFI 返回的原文**
//
// 来源：`.probe/t69_ffi_episodes.txt` 与 `.probe/t69_field_split.txt`
// （真实 sourin_core.dll + 真实插件 cctv.js / cycani.js，
//   私有 dataDir，不碰用户数据）
//
// # 判据（每条都对应一个真实源的**真实**行为）
// ```text
// ① cctv 的 album 条目：subtitle="全 27 集" ⇒ note 必须 = "全 27 集"
// ② cycani 的条目：subtitle=null，badges=["全 1 集","7.0 分"]
//      ⇒ note 必须 = "全 1 集"（★ 从 badges 兜底，不能变成 null）
// ③ cctv 的单条视频：subtitle="4:37"（时长）⇒ note = "4:37"（照实显示）
// ④ badges 必须**原样**解析出来（Owner 要的"哪个源最好"也靠它）
// ⑤ 不含「集」的 badges（"7.0 分"）**不得**被当成副标题（那是噪音）
// ⑥ 没有集数信息时 note 为 null ⇒ UI **不画**占位（Owner：「如果包含的话」）
// ```

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/models.dart';

/// 真实 FFI 返回的条目（逐字抄自 `.probe/t69_ffi_episodes.txt`）
const _cctvAlbum = '''
{"id":"cctv:2c3bc187ad3544b8b8ec848a23a306c4",
 "title":"老舅",
 "cover":"https://p3.img.cctvpic.com/fmspic/2025/05/10/x-1.jpg",
 "subtitle":"全 27 集",
 "badges":["CCTV-8电视剧频道"],
 "kind":"series"}
''';

/// 真实 FFI 返回（逐字抄自 `.probe/t69_field_split.txt` 的 cycani 段）
///
/// ★ 关键：cycani 的 `subtitle` 是 **null**，集数**只在 badges** 里。
const _cycaniBadgeOnly = '''
{"id":"cycani:3862",
 "title":"斗罗大陆",
 "cover":"https://img.example/x.jpg",
 "subtitle":null,
 "badges":["全 1 集","7.0 分"],
 "kind":"series"}
''';

/// 真实 FFI 返回（cctv 的单条视频，subtitle 是**时长**不是集数）
const _cctvSingle = '''
{"id":"cctv:795e327d7be64af38ac7ea62cd3ea991",
 "title":"[影视留声机]电视剧《庆余年》配乐《竹林追杀》",
 "cover":"https://p3.img.cctvpic.com/fmspic/2025/05/10/y-1.jpg",
 "subtitle":"1:30",
 "badges":["CCTV-15音乐频道"],
 "kind":"movie"}
''';

/// 真实 FFI 返回（西游记，带集数区间的写法）
const _cctvRange = '''
{"id":"cctv:abc123",
 "title":"西游记",
 "cover":null,
 "subtitle":"全 4 集（第2–23集）",
 "badges":[],
 "kind":"series"}
''';

MediaItem _p(String raw) =>
    MediaItem.fromJson(jsonDecode(raw) as Map<String, dynamic>);

void main() {
  group('task-69 搜索/换源结果必须带「来源有多少集」', () {
    test('★★★ cctv album：subtitle「全 27 集」必须变成 note（原来恒为 null）', () {
      final it = _p(_cctvAlbum);
      // ignore: avoid_print
      print('T69|cctv album  note=${it.note}  badges=${it.badges}');

      expect(it.note, '全 27 集',
          reason: '★★★ 后端发的是 `subtitle`，而这里原来读 `j[\'note\']` '
              '⇒ note 恒为 null ⇒ 换源弹层/搜索页/首页/浏览页/遥控页 '
              '**6 处**全都显示不出「来源有多少集」。'
              '实测 note=${it.note}');
      expect(it.title, '老舅',
          reason: '★ 对照：标题必须照常解析（证明解析器确实跑了，'
              '不是整条 JSON 都没解析）');
    });

    test('★★★ cycani：subtitle 为 null 时，必须从 **badges** 兜底拿到「全 1 集」', () {
      /*
       * ★ 这条是本文件**最有价值**的一条。
       *
       * 实测（`.probe/t69_field_split.txt`）：
       * ```text
       * cctv   ：subtitle = "全 27 集"                     ← 集数在 subtitle
       * cycani ：subtitle = null
       *          badges   = ["全 1 集", "7.0 分"]           ← 集数**只**在 badges
       * ```
       * ⇒ 只接 `subtitle` 会**漏掉整个 cycani 源的集数**。
       */
      final it = _p(_cycaniBadgeOnly);
      // ignore: avoid_print
      print('T69|cycani badge-only  note=${it.note}  badges=${it.badges}');

      expect(it.note, '全 1 集',
          reason: '★★★ cycani 的集数**只**在 badges 里（subtitle=null）⇒ '
              '必须从 badges 兜底挑出含「集」的那条。'
              '若这里为 null ⇒ 换源时用户**看不到**次元城动画有多少集，'
              '而那正是 Owner 要的「知道哪个源最好最快」。实测 note=${it.note}');
      expect(it.badges, contains('全 1 集'),
          reason: '★ badges 必须原样解析（不能被丢掉）');
    });

    test('★★ cctv 单条视频：subtitle 是时长「1:30」⇒ 照实显示（不要吞掉）', () {
      final it = _p(_cctvSingle);
      // ignore: avoid_print
      print('T69|cctv single  note=${it.note}');

      expect(it.note, '1:30',
          reason: '★ 央视的单条视频 subtitle 是**时长**（实测 "1:30"/"4:37"）'
              '⇒ 照实显示即可。⚠️ 不要为了"只显示集数"把它过滤掉 —— '
              '那会让绝大多数央视条目失去副标题');
    });

    test('★★ 集数区间写法「全 4 集（第2–23集）」原样保留', () {
      final it = _p(_cctvRange);
      expect(it.note, '全 4 集（第2–23集）',
          reason: '★ 央视 album 有区间写法（实测），必须原样带出');
      // ignore: avoid_print
      print('T69|range  note=${it.note}');
    });

    test('★★★ badges 必须解析出来（Owner 的"哪个源最好"也靠它）', () {
      final it = _p(_cctvAlbum);
      expect(it.badges, isNotEmpty,
          reason: '★★ 后端一直在发 `badges`，而这里原来**根本没解析** '
              '（MediaItem 没有 badges 字段）⇒ 角标信息全丢。'
              '实测 badges=${it.badges}');
      expect(it.badges, contains('CCTV-8电视剧频道'));

      final c = _p(_cycaniBadgeOnly);
      expect(c.badges, ['全 1 集', '7.0 分'],
          reason: '★ 多条角标必须**全部**保留（顺序也照后端）');
    });

    test('★★ 不含「集」的 badges **不得**被当成副标题（防噪音）', () {
      /*
       * 兜底只认含「集」的那条。
       * ⇒ 若有人写成"取 badges.first"，这条会红：
       *    ["7.0 分"] 会被显示成副标题（用户看到"7.0 分"当集数，是噪音）。
       */
      const onlyScore = '''
{"id":"x:1","title":"某片","subtitle":null,"badges":["7.0 分"],"kind":"series"}
''';
      final it = _p(onlyScore);
      // ignore: avoid_print
      print('T69|score-only  note=${it.note}');

      expect(it.note, isNull,
          reason: '★★ badges 里没有含「集」的条目 ⇒ note 必须保持 null '
              '（**不要**把「7.0 分」当集数显示出来）。'
              '实测 note=${it.note}');
    });

    test('★★ 完全没有副标题信息 ⇒ note 为 null（UI 不画占位）', () {
      const bare = '{"id":"x:2","title":"某片","kind":"movie"}';
      final it = _p(bare);
      expect(it.note, isNull,
          reason: '★ Owner 原话「**如果包含这个信息的话**」⇒ '
              '不包含时必须是 null（让 UI 什么都不画），'
              '而不是空串或"—"占位');
      expect(it.badges, isEmpty);
    });

    test('★★ 兼容：万一某源真的发 `note`，仍然要认（`??` 兜底不能被删）', () {
      /*
       * ★ 这条对应 Lead 要求的红度证明第 2 条：
       *   「删掉 `?? j['note']` 兜底 ⇒ 若测试仍绿说明兜底没被测到」
       * ⇒ 本测试**就是**那条兜底的守卫。
       */
      const legacy = '''
{"id":"x:3","title":"旧格式条目","note":"更新至 13 集","kind":"series"}
''';
      final it = _p(legacy);
      // ignore: avoid_print
      print('T69|legacy note  note=${it.note}');

      expect(it.note, '更新至 13 集',
          reason: '★★ 若某条 JSON 直接带 `note`（旧格式/导入模板），'
              '必须仍然认它 ⇒ `?? j[\'note\']` 那段兜底**不能删**。'
              '实测 note=${it.note}');
    });

    test('★★ subtitle 优先于 note（同时存在时以 subtitle 为准）', () {
      const both = '''
{"id":"x:4","title":"两者都有","subtitle":"全 24 集","note":"旧备注","kind":"series"}
''';
      final it = _p(both);
      expect(it.note, '全 24 集',
          reason: '★ 后端字段（subtitle）优先 —— 它是权威来源');
      // ignore: avoid_print
      print('T69|both  note=${it.note}');
    });

    test('★★ 畸形输入不得抛异常（badges 不是数组 / 元素不是字符串）', () {
      const weird = '''
{"id":"x:5","title":"畸形","subtitle":null,"badges":"不是数组","kind":"movie"}
''';
      expect(() => _p(weird), returnsNormally,
          reason: '★ 后端理论上发 Vec<String>，但解析层不该因此崩 —— '
              '一个源的畸形数据不能让整个搜索页白屏');

      const weird2 = '''
{"id":"x:6","title":"畸形2","subtitle":null,"badges":[1,true,"全 3 集"],"kind":"movie"}
''';
      final it = _p(weird2);
      // ignore: avoid_print
      print('T69|weird2  note=${it.note}  badges=${it.badges}');

      expect(it.badges, ['1', 'true', '全 3 集'],
          reason: '★ 与 MediaDetail.badges 的既有做法一致（强转字符串，不丢条）');
      expect(it.note, '全 3 集',
          reason: '★ 强转后仍能认出含「集」的那条');
    });
  });
}
