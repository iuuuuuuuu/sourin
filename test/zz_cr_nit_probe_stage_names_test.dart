// ========================================================================
// ** CR-26 / CR-27 反向验证：探针的段名与描述必须与它真正跑的那棵树一致（2026-10-10）
// ========================================================================
//
//  CR-27（lib/t423_arm64_probe.dart）
//
//    builder 已经改成 AppThemeHost→WindowFrame→ColoredBox，
//    但 _holdStage(3, …) 的描述串还写着 FTheme→FToaster→WindowFrame→ColoredBox。
//    t421_report.txt 会把这句话原样记进去 ⇒ 报告里那一层**根本不存在**，
//    读报告的人以为黑屏是 FToaster 干的。
//
//  CR-26（lib/t424_arm64_probe.dart）
//
//    C2 的 builder 与 C1 **逐字相同**（都是 AppThemeHost(data:materialTheme,…)），
//    段名却叫 C2_plus_FToaster、描述写着「内部 Overlay.wrap ⇒ Clip.hardEdge」，
//    而真正的 Overlay.wrap 在 **C2n**（段 5）里、且用的是 Clip.none。
//    于是「4 段名义上带 Clip.hardEdge / 5 段不带」根本不是最小对：
//    4 里压根没有 Overlay。把「4 黑 5 彩」读成「Clip 无罪」是错的。
//
//  本文件断言什么
//
//    · CR-27：t423 里提到 FTheme / FToaster 的行必须全部消失 ——
//      那两个 widget 在这个探针里根本不存在。
//    · CR-26：C2 段（4）必须**真的**含 Overlay.wrap + Clip.hardEdge，
//      否则它的段名是骗人的；且 4 与 5 必须是**只差 clipBehavior** 的最小对。
//    · 一致性：_holdStage(n, …) 描述串里出现的 widget 链，
//      必须能在该段真正的 builder 文本里找到。
//
//  这些都是**文本层**断言：探针要上真机才跑得起来，
//  而「段名与代码对不对得上」这件事在 CI 的 Windows 机器上就该拦住。

import "dart:io";

import "package:flutter_test/flutter_test.dart";

const String kT423 = "lib/t423_arm64_probe.dart";
const String kT424 = "lib/t424_arm64_probe.dart";

// _holdStage 描述串的收尾：Dart 单引号串 + 右括号 + 分号。
const String closer = "');";

/// 只留代码行（去掉整行注释与空行）。
List<String> codeLines(String src) => src
    .split("\n")
    .where((String l) {
      final String t = l.trimLeft();
      return !(t.startsWith("//") || t.startsWith("*") || t.isEmpty);
    })
    .toList();

/// 取出某一段 runApp(...) 的源码：从上一个 runApp( 之后到 _holdStage(n 之前。
String stageBody(String src, int stage) {
  final int end = src.indexOf("_holdStage($stage,");
  if (end < 0) throw StateError("t: 找不到 _holdStage($stage, …)");
  final int from = src.lastIndexOf("runApp(", end);
  if (from < 0) throw StateError("t: _holdStage($stage) 之前没有 runApp(");
  return src.substring(from, end);
}

/// 只要 `builder:` 到 `home:` 之间那段 —— 也就是 builder 闭包本体。
/// 最小对只能比这一段：`home:` 里的段名标签本来就该各段不同，
/// 把它算进去会把「只差 clipBehavior」永远判成不成立。
String builderCore(String src, int stage) {
  final String body = stageBody(src, stage);
  final int b = body.indexOf("builder:");
  final int h = body.indexOf("home:");
  if (b < 0 || h < 0 || h <= b) {
    throw StateError("t: 段 $stage 的 stageBody 里找不到 builder:/home: 边界");
  }
  return body.substring(b, h);
}

/// 「只差 clipBehavior」的正规化：把**两侧**所有 clip 取值都抹成同一个占位符。
/// 只在某一侧做替换是错的：C2n 里 `Clip.none` 出现两次（外层 Overlay.wrap +
/// 内层 Stack），单边替换会顺带改掉两段本来就该共有的那一行。
String normalizeClip(String s) => s
    .replaceAll("Clip.hardEdge", "CLIP")
    .replaceAll("Clip.none", "CLIP");

/// 从 _holdStage(n, "…") 里把描述串抠出来。
String holdStageWhat(String src, int stage) {
  final int at = src.indexOf("_holdStage($stage,");
  if (at < 0) throw StateError("t: 找不到 _holdStage($stage, …)");
  // 先定位**开引号**，再从它后面找收尾 `');`。
  // （反过来先找收尾是错的：那样切出来的 raw 不含闭引号，
  //   q2 会等于 q1，每一段都误判成「没有单引号描述串」——
  //   这个坑是本文件 ③ 组的负对照替我抓到的。）
  final int q1 = src.indexOf(closer.substring(0, 1), at);
  if (q1 < 0) throw StateError("t: _holdStage($stage) 没有单引号描述串");
  final int eol = src.indexOf(closer, q1);
  if (eol < 0) throw StateError("t: _holdStage($stage) 描述串没闭合");
  return src.substring(q1 + 1, eol);
}

/// 从描述串里抽出它声称的 widget 链（按 → / + / ⇒ 切）。
List<String> claimedWidgets(String what) {
  String flat = what.replaceAll("→", " => ");
  flat = flat.replaceAll(" ⇒ ", " => ");
  flat = flat.replaceAll(" + ", " => ");
  final List<String> out0 = <String>[];
  for (final String piece in flat.split(" => ")) {
    final String w = piece.trim();
    if (w.isEmpty) continue;
    if (RegExp("^[A-Z]").hasMatch(w)) out0.add(w);
  }
  return out0;
}

/// 抠出 kStageNames 里的段名（下标即段号）。
List<String> stageNames(String src) {
  final int start = src.indexOf("kStageNames");
  if (start < 0) throw StateError("t: 找不到 kStageNames");
  final int end = src.indexOf("];", start);
  if (end < 0) throw StateError("t: kStageNames 没有闭合");
  return RegExp("'([^']*)'")
      .allMatches(src.substring(start, end))
      .map((Match m) => m.group(1)!)
      .toList();
}

/// 抠出 kStageColors 里的颜色（0x…），下标即段号。
List<String> stageColors(String src) {
  final int start = src.indexOf("kStageColors");
  if (start < 0) throw StateError("t: 找不到 kStageColors");
  final int end = src.indexOf("];", start);
  if (end < 0) throw StateError("t: kStageColors 没有闭合");
  return RegExp("0x[0-9A-Fa-f]{8}")
      .allMatches(src.substring(start, end))
      .map((Match m) => m.group(0)!)
      .toList();
}
/// 探针里真正存在的 widget 名白名单。
///
/// 描述串里出现了谁，就必须在该段的 builder 文本里找得到谁 —— 
/// 否则段名在骗人（这正是 CR-26 / CR-27 的共同病根）。
const List<String> kKnownWidgets = <String>[
  "AppThemeHost",
  "WindowFrame",
  "ColoredBox",
  "ShellPage",
  "SourinApp",
  "FToaster",
  "FTheme",
  "Overlay.wrap",
  "Clip.hardEdge",
  "Clip.none",
];

/// 一致性检查的核心：段 n 的描述串声称用了哪些 widget，
/// 而它真正 runApp 的那段文本里有没有。
///
/// 返回不一致清单（空 = 一致）。测试体只断言它为空，
/// 负对照那几条断言它**不为空** —— 双向都能证明这不是假门禁。
List<String> stageInconsistencies(String src, int stage, {required bool strict}) {
  final List<String> bad = <String>[];
  final String what;
  final String body;
  try {
    what = holdStageWhat(src, stage);
    body = stageBody(src, stage);
  } on StateError {
    if (strict) rethrow;
    return <String>["段 $stage 结构变了（找不到 runApp/_holdStage）"];
  }
  for (final String w in kKnownWidgets) {
    if (what.contains(w) && !body.contains(w)) {
      bad.add("段 $stage 描述串声称有 $w，但它的 builder 里没有");
    }
  }
  return bad;
}

void main() {
  group("① CR-27：t423 的段名/描述必须与它真正跑的 builder 一致", () {
    final String src = File(kT423).readAsStringSync();

    test("★★ FTheme / FToaster 在 t423 里必须彻底消失（描述串会进报告）", () {
      final List<String> hits = <String>[];
      for (final String l in codeLines(src)) {
        if (l.contains("FTheme") || l.contains("FToaster")) hits.add(l.trim());
      }
      expect(hits, isEmpty,
          reason: "t423 的 builder 实际是 AppThemeHost→WindowFrame→ColoredBox，"
              "根本没有这两个 widget。可它们仍出现在下面这些**代码**行里 —— "
              "_holdStage 的描述串会被原样写进 t421_report.txt，"
              "读报告的人会以为黑屏是 FToaster 干的：\n"
              "读报告的人会以为黑屏是 FToaster 干的：\n${hits.join('\n')}");
    });

    test("★★ 段 3 的描述串必须与 builder 逐词对得上", () {
      expect(stageInconsistencies(src, 3, strict: true), isEmpty,
          reason: "段 3 是 t423 里唯一「builder 被改过、描述串没跟上」的那一段：\n"
              "  描述串：${holdStageWhat(src, 3)}\n"
              "  实际  ：${stageBody(src, 3)}");
    });

    test("★ 每一段的描述串都不能声称不存在的 widget", () {
      final List<String> all = <String>[];
      // 段 0（PREINIT）与段 6（F 回收）走的是 _canary()，不是 _holdStage()，
      // 所以只扫 1..5 这几段真正的 buildApp 段。
      for (int i = 1; i <= 5; i++) {
        all.addAll(stageInconsistencies(src, i, strict: false));
      }
      expect(all, isEmpty, reason: all.join("\n"));
    });
  });

  group("② CR-26：t424 的 C2 段必须真的是「带 Overlay.wrap 的那一段」", () {
    final String src = File(kT424).readAsStringSync();

    test("★★ 段 4（C2）的 builder 里必须真的有 Overlay.wrap", () {
      final String body = stageBody(src, 4);
      expect(body.contains("Overlay.wrap"), isTrue,
          reason: "C2 段名叫 C2_plus_FToaster、描述写着「内部 Overlay.wrap ⇒ "
              "Clip.hardEdge」，可它的 builder 与 C1 段**逐字相同**，"
              "里面一个 Overlay 都没有。\n"
              "这样 4 段与 5 段（C2n）就不是最小对 —— 5 段多了整整一层 Overlay，"
              "把「4 黑 5 彩」读成「Clip.hardEdge 无罪」是错的。\n"
              "实际段 4 文本：\n$body");
    });

    test("★★ 段 4（C2）的 builder 里必须明确写着 Clip.hardEdge", () {
      final String body = stageBody(src, 4);
      expect(body.contains("Clip.hardEdge"), isTrue,
          reason: "C2 的全部意义就是 Clip.hardEdge；它得由 C2 自己写出来，"
              "而不是靠 C2n 去反证。段 4 实际文本：\n$body");
    });

    test("★★ 段 4 与段 5 必须是只差 clipBehavior 的最小对", () {
      final String c2 = builderCore(src, 4);
      final String c2n = builderCore(src, 5);
      expect(c2.contains("Overlay.wrap"), isTrue);
      expect(c2n.contains("Overlay.wrap"), isTrue,
          reason: "C2n 是「C2 减掉 Clip」的那一段，C2 自己也得先有 Overlay");
      expect(c2.contains("Clip.hardEdge"), isTrue);
      expect(c2n.contains("Clip.none"), isTrue);
      // 把两侧的 clip 差异抹掉之后，两段必须逐字相同 ——
      // 这才是「最小对」的真正含义：自变量只有一个。
      final String a = normalizeClip(c2);
      final String b = normalizeClip(c2n);
      expect(a, b,
          reason: "两段除 clipBehavior 外还有别的差别 ⇒ 不是最小对，"
              "「4 vs 5 同态/异态」这个读数就失去了意义。\n"
              "--- C2 ---\n$c2\n--- C2n ---\n$c2n");
    });

    test("★ 每一段的描述串都不能声称不存在的 widget", () {
      final List<String> all = <String>[];
      for (int i = 1; i <= 9; i++) {
        all.addAll(stageInconsistencies(src, i, strict: false));
      }
      expect(all, isEmpty, reason: all.join("\n"));
    });

    test("★ 段名表与颜色表必须下标对齐（kStageNames[i] ↔ 段 i）", () {
      final List<String> names = stageNames(src);
      final List<String> colors = stageColors(src);
      expect(names.length, colors.length,
          reason: "kStageNames 有 ${names.length} 项，kStageColors 有 "
              "${colors.length} 项 —— 段号与下标对不上，报告会串段");
      expect(names.length, greaterThanOrEqualTo(11));
    });
  });

  group("③ 负对照：上面那条一致性检查**必须**能报错（否则就是假门禁）", () {
    // 样本 1：描述串声称 FToaster + Overlay.wrap，builder 里两样都没有。
    const String bad = """
Future<void> demo() async {
  runApp(MaterialApp(
    builder: (context, child) => AppThemeHost(
      data: materialTheme,
      child: child,
    ),
  ));
  await _holdStage(4, 'C2 = C1 + FToaster（内部 Overlay.wrap ⇒ Clip.hardEdge）');
}
""";
    test("★★ 描述串提到 FToaster、builder 里没有 ⇒ 必须报出来", () {
      final List<String> got = stageInconsistencies(bad, 4, strict: true);
      expect(got, isNotEmpty,
          reason: "样本里描述声称 FToaster 与 Overlay.wrap，"
              "builder 里都没有 —— 检查却一声不吭 ⇒ 这条检查是空转的假门禁");
      expect(got.join("\n"), contains("FToaster"));
      expect(got.join("\n"), contains("Overlay.wrap"));
      expect(got.join("\n"), contains("Clip.hardEdge"));
    });

    // 样本 2：描述串提到的 widget 在 builder 里都存在 ⇒ 必须一声不吭。
    const String good = """
Future<void> demo() async {
  runApp(MaterialApp(
    builder: (context, child) => AppThemeHost(
      data: materialTheme,
      child: Overlay.wrap(
        clipBehavior: Clip.hardEdge,
        child: child,
      ),
    ),
  ));
  await _holdStage(4, 'C2 = C1 + Overlay.wrap（clipBehavior: Clip.hardEdge）');
}
""";
    test("★★ 描述串与 builder 完全对得上 ⇒ 必须一声不吭", () {
      expect(stageInconsistencies(good, 4, strict: true), isEmpty,
          reason: "描述里提到的 AppThemeHost / Overlay.wrap / Clip.hardEdge "
              "在 builder 里都有 —— 不该报错。报错了说明白名单写歪了");
    });

    test("★ 最小对判定必须能区分「只差 clip」与「差了一整层」", () {
      const String c2 = "Overlay.wrap(\n  clipBehavior: Clip.hardEdge,\n  child: child,\n)";
      const String c2n = "Overlay.wrap(\n  clipBehavior: Clip.none,\n  child: child,\n)";
      final String a = normalizeClip(c2);
      final String b = normalizeClip(c2n);
      expect(a, b);   // 只差 clip ⇒ 最小对成立
      const String noOverlay = "AppThemeHost(\n  data: materialTheme,\n  child: child,\n)";
      expect(normalizeClip(noOverlay), isNot(b));
    });
  });
}
