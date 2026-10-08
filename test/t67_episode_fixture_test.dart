// task-67 阶段2 —— 集号解析的跨语言契约（Lead 裁决 ⑥ 的 Dart 侧）
//
// ─────────────────────────────────────────────────────────────────────────
// 这个文件存在的理由
// ─────────────────────────────────────────────────────────────────────────
//
// 换源合并需要判断「两行记录说的是不是同一集」。这个判断要**同时看两行**的
// episode_title，而两行都在 Rust 手里（Dart 只有 FROM 那一侧）⇒ 解析器落在
// Rust（store.rs 的 episode_number_from_title）。
//
// 但项目里**已经**有一份 Dart 实现 lib/core/models.dart:1577
// episodeNumberFromTitle（注释自称「全项目唯一实现」）。于是同一个概念有了
// 两份实现 —— 它们会漂移，而漂移的后果是**把进度搬到错误的集上**。
//
// 钉住办法：test/fixtures/episode_number_cases.json 是**静态**夹具，
//   · 本文件读它，逐行断言 Dart 实现的结果 == expected；
//   · rust/sourin_core/src/store.rs 的 mod tests 里
//     episode_number_fixture_matches_dart 读**同一份文件**，断言 Rust 结果相同。
// ⇒ 任一侧漂移都会变红。
//
// ★ 为什么夹具是静态的，而不是「Dart 测试把结果落盘成夹具」：
//   生成式夹具会**自愈**。Dart 解析器一旦漂移，测试就把漂移后的结果写进夹具，
//   于是 Dart 侧永远绿，只剩 Rust 侧变红，而夹具本身再也说不清「原本约定了
//   什么」。静态夹具让两份实现都被同一个第三方钉住。
//
// ★ 这个测试**不**碰 FFI（不 open sourin_core.dll）⇒ 在 `flutter test` 里能跑。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/models.dart';

/// 夹具路径：相对仓库根（`flutter test` 的 cwd 就是仓库根）。
const String _fixturePath = 'test/fixtures/episode_number_cases.json';

/// Rust 侧读夹具的路径（从 `rust/sourin_core` 出发）—— 两侧必须指向同一个文件。
/// 这里只用于断言失败时给出可操作的提示，不参与判定。
const String _rustFixturePath = '../test/fixtures/episode_number_cases.json';

Map<String, dynamic> _loadFixture() {
  final f = File(_fixturePath);
  if (!f.existsSync()) {
    fail('夹具不存在：$_fixturePath（cwd=${Directory.current.path}）');
  }
  return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  group('t67 ⑥ 集号解析跨语言契约夹具', () {
    test('夹具文件存在且形状正确（仪器自检）', () {
      final root = _loadFixture();
      final cases = root['cases'];
      expect(
        cases,
        isA<List<dynamic>>(),
        reason: '夹具必须有 cases 数组；实际顶层键=${root.keys.toList()}',
      );
      final list = cases as List<dynamic>;
      expect(
        list.length,
        greaterThanOrEqualTo(20),
        reason: '夹具至少 20 条（含契约/边界用例）',
      );
      for (final raw in list) {
        final m = raw as Map<String, dynamic>;
        expect(
          m.containsKey('input'),
          isTrue,
          reason: '每条必须有 input（允许为 null）：$m',
        );
        expect(
          m.containsKey('expected'),
          isTrue,
          reason: '每条必须有 expected（整数或 null）：$m',
        );
        final e = m['expected'];
        expect(
          e == null || e is int,
          isTrue,
          reason: 'expected 只能是 int 或 null，实际 ${e.runtimeType}：$m',
        );
      }
    });

    test('★ Dart episodeNumberFromTitle 逐行匹配夹具', () {
      final list = (_loadFixture()['cases'] as List<dynamic>)
          .cast<Map<String, dynamic>>();

      final mismatches = <String>[];
      for (final m in list) {
        final input = m['input'] as String?;
        final expected = m['expected'] as int?;
        final actual = episodeNumberFromTitle(input);
        if (actual != expected) {
          mismatches.add(
            '  input=${jsonEncode(input)}  expected=$expected  actual=$actual'
            '${m['note'] == null ? '' : '   // ${m['note']}'}',
          );
        }
      }

      expect(
        mismatches,
        isEmpty,
        reason:
            'Dart 解析器与夹具不一致（${mismatches.length}/${list.length} 条）：\n'
            '${mismatches.join('\n')}\n'
            '★ 若你**有意**改了集号语义，必须同时更新 $_fixturePath\n'
            '  并重跑 Rust 侧 ${_rustFixturePath.replaceAll('../', 'rust/sourin_core/')} 的\n'
            '  episode_number_fixture_matches_dart —— 否则两份实现开始漂移。',
      );
    });

    test('★ 夹具必须覆盖关键边界（防止有人删条目让契约变松）', () {
      final list = (_loadFixture()['cases'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final inputs = list.map((m) => m['input']).toList();

      // 这几条是契约本身，不是功能：删掉它们，跨语言钉住就出现空洞。
      const mustHave = <Object?>[
        '第01集', // 生产数据（无职转生 FROM 侧）
        '第1集', // 生产数据（无职转生 TO 侧）—— 两者必须同为 1
        '第01話',
        '第１集', // 全角
        '第1话',
        null, // NULL 输入
        '第1集 遗忘的过去',
        '第1回', // 与 player_page.dart:3420 _epOrder 的分歧点
        '第0集', // n <= 0 守卫
        '第4294967296集', // 2^32 位宽
        '第12345678901234567890集', // 超出 i64
        '第一集', // 中文数字：不支持
        '正片', // 无集号
      ];
      for (final v in mustHave) {
        expect(
          inputs.contains(v),
          isTrue,
          reason: '夹具缺少契约用例 ${jsonEncode(v)} —— 不要删，请恢复',
        );
      }
    });

    test('★ 无职转生那组：两个源的集号必须判为同一集', () {
      // 生产数据（.probe/dbcopy-t67c）：
      //   cycani:3862      pos=91  ep='第01集'
      //   hongniuzy2:150722 pos=766 ep='第1集'
      // 裁决 ⑦ 的第二条（集号不同 ⇒ 不携带）只有在集号**相同**时才不触发。
      // 这一条断言把「第01集 与 第1集 同集」钉成契约，而不是某个人的判断。
      expect(episodeNumberFromTitle('第01集'), 1);
      expect(episodeNumberFromTitle('第1集'), 1);
      expect(
        episodeNumberFromTitle('第01集'),
        episodeNumberFromTitle('第1集'),
        reason: '★ 这两个串在**字符串**上不等，但在**集号**上必须相等；'
            '若改成按字符串比，无职转生那组会走「不携带」分支 ⇒ 766s 的进度被丢掉',
      );
    });

    test('★ 时光代理人那组：集号不同 ⇒ 应当不携带', () {
      // 生产数据：caiji-2:83810 pos=622 ep='第08集' vs cj:99018 pos=2 ep='第01集'
      expect(episodeNumberFromTitle('第08集'), 8);
      expect(episodeNumberFromTitle('第01集'), 1);
      expect(
        episodeNumberFromTitle('第08集'),
        isNot(episodeNumberFromTitle('第01集')),
        reason: '这一组是裁决 ⑦ 第二条（集号不同 ⇒ TO 行完全不动、FROM 行删掉）的样本',
      );
    });

    test('★ 无职转生那组的进度是 91 vs 766 —— 合并规则的唯一可区分锚点', () {
      // 这不是解析器的测试，而是把「为什么必须取 max」记在测试里：
      // 其余几组重复行两侧 position 同值，取 FROM 与取 max 结果相同 ⇒ 测不出规则。
      // 只有这一组（91 vs 766）能区分。改合并规则时必须让这一组仍然可区分。
      const fromPos = 91; // cycani:3862
      const toPos = 766; // hongniuzy2:150722
      expect(
        fromPos,
        isNot(toPos),
        reason: '★ 若这两个数变成相等，合并规则的红度证明就失去唯一锚点',
      );
      expect(
        toPos > fromPos,
        isTrue,
        reason: 'TO 侧更大 ⇒ max 与 FROM 可区分',
      );
    });
  });
}
