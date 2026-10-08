// ═══════════════════════════════════════════════════════════════════════
//  编排者独立验证：模型契约的两个「未验证缺口」
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么单独做这个
//
// 代理 Z 的 `model_roundtrip_probe.dart` 跑出 `pass=7 fail=2`，其中两条是：
// ```text
// ✗ ★ 找到有 nested 的真实样本   所有插件的前 6 个条目都没有嵌套源
// ✗ ★ 找到有 badges 的真实样本   所有插件的前 6 个条目都没有 badges
// ```
// 也就是说：**nested 与 badges 的解析从来没被真实数据验证过**。
//
// 真实数据里找不到样本 ≠ 解析是错的，但也 ≠ 解析是对的。
// 本文件用**从 Rust 源码抄下来的真实 JSON 形状**直接驱动 `fromJson`，
// 断言字段**真的有值** —— 这是「用真实形状做往返」，比"没抛异常"强得多。
//
// ⚠️ JSON 形状的**唯一权威**是 `rust/sourin_core/src/model.rs`，不是我的记忆。
//    本文件里的 JSON 逐字段对照过 model.rs 的 serde 属性。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/models.dart';

void main() {
  group('模型契约 —— nested / badges 往返（真实 JSON 形状）', () {
    test('★ PlaySource.nested 递归解析（model.rs:186）', () {
      // 形状取自 model.rs：
      //   pub struct PlaySource {
      //       pub code: String,
      //       pub title: String,
      //       #[serde(default)] pub count: u32,
      //       #[serde(default, skip_serializing_if = "Vec::is_empty")]
      //       pub nested: Vec<PlaySource>,
      //   }
      const raw = '''
      {
        "code": "line1",
        "title": "线路一",
        "count": 24,
        "nested": [
          {"code": "line1-hd", "title": "高清", "count": 12},
          {"code": "line1-sd", "title": "标清", "count": 12,
           "nested": [{"code": "line1-sd-a", "title": "备用", "count": 6}]}
        ]
      }
      ''';

      final src = PlaySource.fromJson(jsonDecode(raw) as Map<String, dynamic>);

      // ★ 强判据：字段真的有值（不是"没抛异常"）
      expect(src.code, 'line1');
      expect(src.title, '线路一', reason: 'title 读错键名就会是空串');
      expect(src.count, 24, reason: 'count 读错键名就会是 0');
      expect(src.nested.length, 2, reason: 'nested 没解析就是空列表');

      // 第一层子线路
      expect(src.nested[0].title, '高清');
      expect(src.nested[0].count, 12);

      // ★ 递归：第二层子线路（原版 SourcePicker.vue:74-80 就是递归渲染）
      expect(src.nested[1].nested.length, 1, reason: '嵌套必须递归解析');
      expect(src.nested[1].nested[0].title, '备用');
      expect(src.nested[1].nested[0].count, 6);
    });

    test('★ PlaySource 缺 nested 键时是空列表而不是崩（serde default）', () {
      const raw = '{"code": "c", "title": "t", "count": 5}';
      final src = PlaySource.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      expect(src.nested, isEmpty);
      expect(src.title, 't');
    });

    test('★ MediaDetail.badges / meta 解析（model.rs:212,217）', () {
      // 形状取自 model.rs：
      //   #[serde(default, skip_serializing_if = "Vec::is_empty")]
      //   pub badges: Vec<String>,
      //   #[serde(default, skip_serializing_if = "serde_json::Map::is_empty")]
      //   pub meta: serde_json::Map<String, serde_json::Value>,
      const raw = '''
      {
        "provider": "cctv",
        "id": "cctv:123",
        "title": "新闻联播",
        "badges": ["连载中", "更新至 12 集", "9.2 分"],
        "meta": {"year": "2026", "area": "内地", "score": 9.2},
        "kind": "series"
      }
      ''';

      final d = MediaDetail.fromJson(jsonDecode(raw) as Map<String, dynamic>);

      // ★ 强判据
      expect(d.title, '新闻联播');
      expect(d.badges.length, 3, reason: 'badges 没解析就是空列表（修复前整个字段都不存在）');
      expect(d.badges, contains('连载中'));
      expect(d.badges, contains('9.2 分'));
      expect(d.meta['year'], '2026');
      expect(d.meta['score'], 9.2);
    });

    test('★ badges/meta 缺失时是空而不是崩', () {
      const raw = '{"provider": "p", "id": "i", "title": "t"}';
      final d = MediaDetail.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      expect(d.badges, isEmpty);
      expect(d.meta, isEmpty);
    });

    test('★ UpdateInfo.added ≠ newCount（store.rs:383 的语义差）', () {
      // 形状取自 store.rs：
      //   pub old_count: u32, pub new_count: u32, pub added: u32,
      //   pub latest_title: Option<String>,
      const raw = '''
      {
        "key": "cctv:123",
        "title": "无职转生",
        "provider": "cctv",
        "old_count": 2,
        "new_count": 13,
        "added": 11,
        "latest_title": "第13集"
      }
      ''';

      final u = UpdateInfo.fromJson(jsonDecode(raw) as Map<String, dynamic>);

      // ★ 这三条一起才能证明语义没混
      expect(u.oldCount, 2);
      expect(u.newCount, 13, reason: 'newCount 是总数');
      expect(u.added, 11, reason: 'added 是【新增数】—— 读成 newCount 就会显示「+13 集」');
      expect(u.added, isNot(u.newCount), reason: '两者语义不同，不能互相顶替');
      expect(u.latestTitle, '第13集', reason: '读错键名（new_episode_title）就永远是 null');
    });
  });
}
