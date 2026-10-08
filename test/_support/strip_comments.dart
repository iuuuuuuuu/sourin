// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 共享 helper：剥注释（静态断言的**唯一**实现）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要有这个文件（2026-09-26 实测，铁律 170）
//
// ```text
// ★ 实测：全仓 `stripComments` 曾有 **10 个不同的实现**（19 个文件各写各的）。
// ★ 而其中 **naive 正则版**（被 6 个文件使用）**可证明更弱**：
//     ① 字符串里的 `/* */` 会被**误删** —— 把**代码**当注释删掉
//     ② 行尾 `// 注释` **不删** ⇒ `src.contains('注释里的词')` **仍然命中**
//        ⇒ ★ 断言"通过了"，但守的是**注释文本**，不是代码 ⇒ **假通过**
// ```
//
// # ★ 实证：本仓真发生过一次假通过
// ```text
// `test/search_all_test.dart` 断言
//     livePage.contains('_watchReplay') == true
// 而当时 `live_page.dart` 里 `_watchReplay` **只剩注释**（函数已删）
//   ⇒ ★ **代码里没有了，测试却是绿的** —— 因为它**不剥注释**
// ⇒ 同一个仓库、同一条纪律，出现了**两种行为**（分叉）。
// ```
//
// # 铁律 170
// ```text
// 「**同一纪律必须只有一个实现（一个 helper）**，否则它会分叉成两套行为」
// ★ 判据：写静态断言前，**先找仓里有没有既有的剥注释 helper**；
//   有就**必须用**（import 本文件），**不许**再抄一份。
// ```
//
// # 实现（状态机，不是正则）
// ```text
// 要区分三种情况 —— 正则做不到（需要记忆状态）：
//   'http://x'     字符串里的 `//` **不是**注释
//   "a /* b"       字符串里的 `/*` 不是注释
//   /*  //  */     块注释里的 `//` 不是行注释
// ```
//
// ⚠️ **本文件的实现是从 `test/live_page_test.dart` 逐字节抽取的**
//    （不是手抄 —— 手抄会引入转录漂移，铁律 158）。语义**零变化**。
//
// # 用法
// ```dart
// import '_support/strip_comments.dart';
//
// final code = stripComments(File('lib/ui/xxx.dart').readAsStringSync());
// // ★ 之后所有静态断言都断言 `code`，**不要**断言原始文本
// ```

/// 剥掉注释（`//` 行注释 **和** `/* */` 块注释）
///
/// ⚠️ 这是本文件所有静态断言的前提 —— 见文件头说明。
///
/// # 为什么用状态机而不是正则
///
/// 要区分三种情况：
/// ```text
/// 'http://x'     字符串里的 `//` **不是**注释
/// "a /* b"       字符串里的 `/*` 不是注释
/// /*  //  */     块注释里的 `//` 不是行注释
/// ```
/// 正则做不到（需要记忆状态）。所以走一遍字符。
/// （与 `test/episode_strip_test.dart` 的实现一致 —— 那边也是被同一个
///  假通过坑过之后写的。）
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote; // 当前是否在字符串里（记录引号字符）

  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';

    // ── 在字符串里：原样保留，只找结束引号 ──
    if (quote != null) {
      if (c == r'\') {
        out.write(c);
        if (next.isNotEmpty) {
          out.write(next);
          i += 2;
          continue;
        }
      }
      if (c == quote) quote = null;
      out.write(c);
      i++;
      continue;
    }

    // ── 不在字符串里 ──
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && next == '/') {
      // 行注释：跳到行尾（保留换行，行号不变）
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && next == '*') {
      // 块注释：跳到 */
      i += 2;
      while (i < src.length &&
          !(src[i] == '*' && i + 1 < src.length && src[i + 1] == '/')) {
        if (src[i] == '\n') out.write('\n'); // 保留换行，行号才对得上
        i++;
      }
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}
