// ═══════════════════════════════════════════════════════════════════════
//  task-38：把「探测」的开销写进注释 + 断言它只在加载时做一次
// ═══════════════════════════════════════════════════════════════════════
//
// Lead 要求③：「量出中位数，并**写进注释**（后人看得到代价）」
//
// 实测（n=15，部署版真实插件，见 `rust/sourin_core/tests/zz_t38_perf.rs`）：
// ```text
// 基线（不触发探测）        中位数 = 1.461 ms
// 带探测（缺声明 → 走探测） 中位数 = 3.453 ms
// ★ 探测净开销              中位数 ≈ 2 ms / 插件
// ```
//
// # ★★ 这个文件里有两条"方向相反"的断言，别弄混
//
// ```text
// ① 「注释里写了开销」 → 必须用**原始源码**（不能剥注释）
//    ⚠️ 剥了就什么都没有了 —— 被测对象**就是注释**
//       （我第一版剥了注释来断言"注释里有数字"，必然红，是测试写错）
//
// ② 「探测调用只出现在哪几个函数」 → **必须剥注释**
//    ⚠️ 注释里也引用了那段 JS 表达式（解释"只允许出现在本函数里"）
//       ⇒ 不剥 ⇒ 计数多出来 ⇒ 假红
// ```
// ⇒ 教训：**"剥注释"本身也要看判据的对象是什么**。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥掉 Rust 注释（行注释 `//` + 块注释 `/* */`）
///
/// ⚠️ 用于"断言**代码**里有/没有 X"。断言"注释里有 X"时**绝不能**用它。
String stripRustComments(String src) {
  final out = StringBuffer();
  var inBlock = false;
  for (final line in src.split('\n')) {
    final buf = StringBuffer();
    var i = 0;
    while (i < line.length) {
      if (inBlock) {
        final end = line.indexOf('*/', i);
        if (end < 0) {
          i = line.length;
        } else {
          inBlock = false;
          i = end + 2;
        }
        continue;
      }
      if (line.startsWith('/*', i)) {
        inBlock = true;
        i += 2;
        continue;
      }
      if (line.startsWith('//', i)) break;
      buf.write(line[i]);
      i++;
    }
    out.writeln(buf.toString());
  }
  return out.toString();
}

void main() {
  test('★★ 注释必须写明探测开销的量化值（用原始源码）', () {
    // ★ 不剥注释 —— 被测对象就是注释
    final raw = File('rust/sourin_core/src/plugins/mod.rs').readAsStringSync();

    final i = raw.indexOf('实测开销');
    expect(i > 0, isTrue,
        reason: '★★ 应能找到"实测开销"那段注释 —— Lead 明确要求把量出的'
            '中位数写进注释（否则后人不知道代价，可能以为"读个文件而已"'
            '就把探测搬到高频路径上）');

    /*
     * 窗口取 2000 字符（实测那段注释约 1200 字符）。
     * ⚠️ 不要用 `indexOf('canAutoLogin')` 定位 —— 第一个匹配在 L516 的
     *    **另一段**注释里，离开销注释 6500+ 字符（我第一版这么写，漏了）。
     */
    final seg = raw.substring(i, (i + 2000).clamp(0, raw.length));

    expect(seg.contains('ms'), isTrue,
        reason: '★★ 必须给出**量化的**开销（含 ms）—— 空泛的"很快"没法用来判断'
            '能不能搬到别处');
    expect(seg.contains('加载'), isTrue,
        reason: '★ 必须说明它发生在**加载时** —— 那是"≈2ms 可以接受"的'
            '**唯一理由**；放到每次读会话状态上就不可接受');
    expect(seg.contains('有登录能力') || seg.contains('门控'), isTrue,
        reason: '★ 总代价要说准：**只有"有登录能力的插件"才走探测**'
            '（门控），不是 × 全部插件数。表述要与实现一致');
  });

  test('★★ 探测调用只出现在 2 个正当位置（用剥注释的源码）', () {
    // ★ 必须剥注释 —— 注释里也引用了那段 JS 表达式
    final src = stripRustComments(
        File('rust/sourin_core/src/plugins/mod.rs').readAsStringSync());

    const pat = r'plugin\.canAutoLogin \? plugin\.canAutoLogin\(\)';
    final occurrences = RegExp(pat).allMatches(src).length;

    /*
     * ★★ 期望是 **2 处**，而且两处**各有职责**（我第一版断言"只有 1 处"，
     *    红了 —— 那是**测试期望写错**，先确认了代码是对的）：
     * ```text
     * ① hydrate_capabilities  —— ★ B 方案新增的"加载时探测兜底"
     *                            没有它 ⇒ 部署版（无声明）识别不出来
     *                            ⇒ Owner 报的 bug 不变
     * ② can_auto_login()      —— trait 方法，早就存在
     *                            它是"运行时真相"的查询入口，被 ensure_session 调
     * ```
     */
    expect(occurrences, 2,
        reason: '★★ 应恰好 2 处：hydrate_capabilities（加载时探测）'
            '+ can_auto_login()（trait 查询）。'
            '多出来意味着某条高频路径上又抄了一份（2ms/次）；'
            '少了第一处意味着"修复到不了用户"（部署版无声明 ⇒ 识别不出）');

    // ── 第①处必须在 hydrate_capabilities 里 ──
    final h = src.indexOf('pub async fn hydrate_capabilities');
    expect(h > 0, isTrue, reason: '应能找到 hydrate_capabilities');
    final next = src.indexOf('\n    pub ', h + 10);
    final fnBody = src.substring(h, next > h ? next : h + 30000);
    expect(
      RegExp(pat).allMatches(fnBody).length,
      1,
      reason: '★★★ "加载时探测兜底"必须在 `hydrate_capabilities` 里 —— '
          '它是**注册前**跑一次的地方（每个插件一次）。'
          '若搬进 `can_auto_login()`，每读一次会话状态就白花 2ms',
    );

    // ── 第②处必须在 can_auto_login 里（trait 的本职）──
    final c = src.indexOf('async fn can_auto_login');
    expect(c > 0, isTrue, reason: '应能找到 can_auto_login（trait 方法）');
    final cEnd = src.indexOf('\n    async fn ', c + 10);
    final cBody = src.substring(c, cEnd > c ? cEnd : c + 800);
    expect(
      RegExp(pat).allMatches(cBody).length,
      1,
      reason: '★ trait 方法 `can_auto_login()` 里那处是它的本职'
          '（`ensure_session` 靠它判断能否自动重登）—— 不能没有',
    );
  });
}
