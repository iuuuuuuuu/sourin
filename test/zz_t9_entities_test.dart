// ═══════════════════════════════════════════════════════════════════════
//  task-9 ② 验收 —— 详情页简介的 HTML 实体兜底
//  （Owner：「右边介绍居然还有 &nbsp; 这种代码」）
// ═══════════════════════════════════════════════════════════════════════
//
// 这里测的是 lib/ui/detail_page.dart 里的 _decodeHtmlEntities ——
// 它是**兜底**：用户插件目录里已经转好的老 .js 文件不会自动重转，
// 那些源的简介仍然带 &nbsp;，所以显示前再解一次。
//
// ★ 判据与 Rust（tvbox::decode_entities）/ 转换器模板三处**必须一致**
//   （同一张实体表、同一个顺序）。最要紧的是顺序：&amp; 必须**最后**解。

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/detail_page.dart';

void main() {
  group('task-9 ② 简介实体兜底', () {
    test('命名实体', () {
      expect(decodeHtmlEntitiesForTest('a&nbsp;b'), 'a b');
      expect(decodeHtmlEntitiesForTest('&lt;p&gt;'), '<p>');
      expect(decodeHtmlEntitiesForTest('&quot;x&quot;'), '"x"');
      expect(decodeHtmlEntitiesForTest('&apos;y&apos;'), "'y'");
      expect(decodeHtmlEntitiesForTest('a&amp;b'), 'a&b');
    });

    test('数字实体（十进制 / 十六进制）', () {
      expect(decodeHtmlEntitiesForTest('&#39;'), "'");
      expect(decodeHtmlEntitiesForTest('&#x2913;'), '\u2913');
      expect(decodeHtmlEntitiesForTest('&#65;&#66;'), 'AB');
      expect(decodeHtmlEntitiesForTest('&#x41;'), 'A');
      // 解不出来的一律**原样保留**（不吞、不变空）
      expect(decodeHtmlEntitiesForTest('&#xZZ;'), '&#xZZ;');
      expect(decodeHtmlEntitiesForTest('&#;'), '&#;');
    });

    test('★★ &amp; 必须最后解（实测定的，不是推理定的）', () {
      // 若把 &amp; 放最前，这里会得到 ' '（错）
      expect(decodeHtmlEntitiesForTest('&amp;nbsp;'), '&nbsp;');
      expect(decodeHtmlEntitiesForTest('&amp;lt;'), '&lt;');
      expect(decodeHtmlEntitiesForTest('&amp;amp;'), '&amp;');
    });

    test('没有实体就原样返回', () {
      expect(decodeHtmlEntitiesForTest('纯文本'), '纯文本');
      expect(decodeHtmlEntitiesForTest('a & b'), 'a & b');
      expect(decodeHtmlEntitiesForTest(''), '');
    });

    test('★ 幂等 —— 解过一遍的文本再解不变（兜底必须幂等）', () {
      const once = '介绍 文本&更多';
      expect(decodeHtmlEntitiesForTest(once), once);
      // ★ 真实形态：真网络拿到的上游原文（360 源「雪王来了！」结尾就是 &nbsp;）
      const raw = '雪王来到陌生都市……但总有欢笑与温情相伴而来...&nbsp;';
      final fixed = decodeHtmlEntitiesForTest(raw);
      expect(fixed.contains('&nbsp;'), isFalse, reason: '结尾的 &nbsp; 必须被解掉');
      expect(decodeHtmlEntitiesForTest(fixed), fixed, reason: '再解一次必须不变');
    });

    test('Owner 报的真实形态：标签残留 + 实体混排', () {
      expect(
        decodeHtmlEntitiesForTest('第1集&nbsp;&nbsp;主演：A&amp;B'),
        '第1集  主演：A&B',
      );
    });
  });
}
