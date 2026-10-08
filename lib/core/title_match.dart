// ═══════════════════════════════════════════════════════════════════════
//  标题匹配度 —— **判据的唯一下拉点**
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么这个文件存在（task-73 的架构判断）
//
// ```text
// 第一版 `titleSimilarity` 写在 `lib/ui/widgets/source_switch_dialog.dart:60`
// —— 那是个 **重 UI 弹层文件**（610 行、依赖 ffi / sourin_api / tokens）。
//
// 搜索页（`search_page.dart`）也要按匹配度排序时，发现它需要同一个函数。
// ⇒ 那一刻就是「该抽出来了」的信号（本仓 `json_utils.dart` 顶部引用的
//    `.trellis/spec/guides/code-reuse-thinking-guide.md` **Pattern 4**）：
//
//   > **Bad**：多个消费者各自把同一份逻辑取出来 —— 这是**重复的契约逻辑**。
//   >          每个消费者都拥有一份私有判据，下一次规则变更会改到一处、
//   >          漏掉另一处。
//   > **Good**：抽成共享工具，各处 import。
// ```
//
// ★ **绝不允许**为了"少改一个 import"就复制第二份 —— 两份判据必然漂移，
//   到时候「搜索页排出来的顺序」和「换源弹层排出来的顺序」会不一致，
//   而用户看到的是**同一个词**的两个排序结果。
//
// # 向后兼容
//
// `source_switch_dialog.dart` 原地 `export` 了本文件 ⇒ 原先
// `import 'widgets/source_switch_dialog.dart';` 的两个调用点
//（`detail_page.dart:51` / `player_page.dart:111`）**一行都不用改**。
// 同 task-58 把 `PlayRequestData` 搬到 `media_session.dart` 后原地 export 的做法。

import 'models.dart';

/// 标题相似度（0~1）
///
/// # 算法：**字符 bigram 的 Jaccard 相似度**
///
/// ```text
/// "无职转生 第三季 ～到了异世界就拿出真本事～"
/// "无职转生 第三季"
/// → 提取 2 字组 {无职,职转,转生,生 , 第,三季,…}
/// → 交集/并集 = 0.4 左右（B 是 A 的子串，所以不会太高）
/// ```
///
/// ⚠️ 不用「包含即 1.0」—— 那会让《西游记》和《西游记后传》都得满分。
///    bigram 能让「后传」这种差异体现出来。
///
/// 归一化：去掉空格/标点/全角符号，只留汉字字母数字。
double titleSimilarity(String a, String b) {
  // ⚠️ 写成**函数声明**而不是 `final norm = (String s) => ...`
  //    —— 后者会触发 `prefer_function_declarations_over_variables`
  //    （它原来是那样写的，搬过来时顺手按 lint 改了；
  //      **语义逐字相同**，只是绑定形式不同）。
  String norm(String s) =>
      s.replaceAll(RegExp(r'[\s\p{P}\p{S}]+', unicode: true), '').toLowerCase();
  final aa = norm(a);
  final bb = norm(b);
  if (aa.isEmpty || bb.isEmpty) return 0;
  if (aa == bb) return 1;

  Set<String> grams(String s) {
    final out = <String>{};
    // 单字串没有 bigram —— 直接用它自己，否则永远算 0
    if (s.length == 1) out.add(s);
    for (var i = 0; i + 1 < s.length; i++) {
      out.add(s.substring(i, i + 2));
    }
    return out;
  }

  final ga = grams(aa);
  final gb = grams(bb);
  var inter = 0;
  for (final g in ga) {
    if (gb.contains(g)) inter++;
  }
  final union = ga.length + gb.length - inter;
  return union == 0 ? 0 : inter / union;
}

/// 一组结果里**最像**的那条的相似度 —— 用整组的代表分
///
/// # 为什么用 max 而不是平均
///
/// ```text
/// 一个源返回 30 条时，通常只有 1~2 条是用户要的那部，
/// 其余是该站的无关内容。取**平均**会让"准确命中了 1 条、
/// 另外 29 条是噪声"的源排到很后面 —— 但那个源其实**是最准的**。
/// ```
///
/// ★ 判据与换源弹层（`source_switch_dialog.dart:236`，task-73 之前就在这里）
///   **逐字一致** —— 现在两处调用的是**同一个函数**，不靠"记得改两遍"。
///
/// ⚠️ 空列表必须给 0，不能让它走到 `reduce` 抛
///    （`Bad state: No element`）—— 空组理论上不会出现，
///    但搜索链路的边界（源返回 0 条却有 hit 事件）不能靠"应该不会"。
double bestTitleScore(String keyword, List<MediaItem> items) {
  if (items.isEmpty) return 0;
  var best = 0.0;
  for (final it in items) {
    final s = titleSimilarity(keyword, it.title);
    if (s > best) best = s;
  }
  return best;
}

/// 一组**条目**按与关键词的相似度降序排（稳定）
///
/// ★ 搜索页（`search_page.dart` 的 `_addHit`）与换源弹层
///   （`source_switch_dialog.dart` 的 `hit` 分支）用的是**同一个函数**
///   —— 两处都要「组内最像的排前面」，判据不许各写一遍。
///
/// ⚠️ 换源弹层只显示前 8 条（`candidate.items.take(8)`）⇒
///    排序必须发生在 `take` **之前**，否则最像的那条可能根本不在前 8 条里。
///    （调用点是在 `_candidates.add(...)` 里排完再存 ⇒ 天然满足。）
List<MediaItem> rankItemsByTitleDesc(String keyword, List<MediaItem> items) =>
    stableRankDesc(items, (it) => titleSimilarity(keyword, it.title));

/// 按分数**降序**排列，**同分保持原顺序**（稳定排序）
///
/// # ★★ 为什么必须自己写，不能用 `List.sort`
///
/// ```text
/// Dart 的 `List.sort` **不是稳定排序**（introsort / dual-pivot quicksort）
/// ⇒ 同分的元素相对顺序**不确定**
/// ⇒ 后果：搜索结果会在每次重排时"乱跳"（用户看到列表自己抖动），
///   而且**不可复现** —— 同一关键词搜两次可能得到不同顺序。
/// ```
///
/// # 稳定性怎么保证的
///
/// ```text
/// 不依赖排序算法本身，而是把「原索引」显式做成**次关键字**：
///     先比分数（降序），分数相同则比 `order` 里的原始下标（升序）
/// ⇒ 同分元素的下标是升序的 ⇒ 输出里它们的相对顺序 == 输入顺序。
/// ```
///
/// # 为什么"每次回填后重排"仍然保持到达顺序
///
/// ```text
/// 本函数在**每次**新结果到达后都会被调用一次。归纳：
///   ① 新元素总是 `add` 到末尾 ⇒ 它的下标**最大**
///      ⇒ 在它所属的同分组里排在**最后**（与"后到者靠后"一致）
///   ② 既有同分元素的相对下标顺序不变 ⇒ 上一次的先后被保留
/// ⇒ 到达顺序在同分组内被**逐次保持**，不需要额外记序号。
/// ```
List<T> stableRankDesc<T>(List<T> src, double Function(T) scoreOf) {
  if (src.length < 2) return List<T>.of(src);
  // 分数只算一次（比较函数会被调用 O(n log n) 次）
  final keys = <double>[for (final v in src) scoreOf(v)];
  final order = List<int>.generate(src.length, (i) => i);
  order.sort((a, b) {
    final c = keys[b].compareTo(keys[a]); // 降序
    return c != 0 ? c : a.compareTo(b); // ★ 同分 → 原顺序（稳定）
  });
  return <T>[for (final i in order) src[i]];
}
