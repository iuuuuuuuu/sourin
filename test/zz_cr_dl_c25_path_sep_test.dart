// ═══════════════════════════════════════════════════════════════════════
//  ★★★ CR-25 回归探针：探针源码不许硬编码反斜杠路径分隔符
// ═══════════════════════════════════════════════════════════════════════
//
// # 这条修的是 macOS CI 9 条红的**根因**
// ```text
// CI 在 macOS 上跑的是**裸** flutter test（.github/workflows/build.yml:372）。
// 在 POSIX 路径里反斜杠只是一个普通字符、不是分隔符 —— 于是探针造出来的
//   「root + 反斜杠 + 我的剧 + 反斜杠 + 第01集 开局.mp4」
// 在 macOS 上是**一个文件名里带反斜杠的单个文件**，落在 <root>/ 根下，
//   根本不成其为「剧目录」⇒ 扫盘断言 / .part 存在性断言 / 路径相等断言全红。
// ```
//
// # ★★ 为什么判据是**静态扫源码**，而不是「跑一遍用例看红不红」
// ```text
// 缺陷在 Windows 上**完全不可见**（那里反斜杠就是分隔符）
//   ⇒ 任何运行时用例在本机都测不出它，绿了也证明不了什么。
//   本仓铁律是「假门禁比红更糟」（CR-03 就是在骂仓库里已有的假测试）
//   ⇒ 这里必须换一个**能真正区分对错**的判据：直接扫源码字面量。
//   这正是 macOS CI 红的那一组文件 ⇒ 判据与缺陷一一对应，不是猜的。
// ```
//
// # ★★★ 第 2 版修的是**覆盖面洞**（原始缺陷可以原样再溜一次进 CI）
// ```text
// 第 1 版把 7 个文件名**写死**在 kProbeFiles 里。实测后果：
//   往 zz_cr_cache_owner1009_test.dart 注入 2 处硬编码反斜杠，
//   第 1 版门禁仍然打印「CR-25 扫了 7 个探针文件，违规 0 处」+ All tests passed。
//   zz_cr_cache_owner1009_test.dart / zz_cr_play_detail_cover_test.dart /
//   zz_cr_play_detail_origin_test.dart 这三个**提交后会进 CI** 的探针文件
//   不在名单里 ⇒ 门禁对它们完全瞎。
// 第 2 版 ⇒ 名单改成**动态发现**（Directory('test').listSync()），
//   另加一份**冻结的必须覆盖名单** kMustBeCovered 当金丝雀：
//   发现口径一旦退化，就带着文件名字红。
// ```
//
// # 探针文件的口径（为什么是这两个条件）
//   ① 文件名含 probe（不分大小写）—— 本仓 task 探针的通用命名；
//   ② 文件名以 zz_cr_ 开头 —— 本仓 CR-xx 回归门禁/探针的通用命名。
//   并集 = 66 个（test/ 下 90 个 zz_*.dart 中的 66 个），把第 1 版那 7 个
//   与要进 CI 的那 3 个全包进去，且**不再写死全集**。
//   刻意**不**收全部 90 个：口径必须可解释（都是「探针 / 回归门禁」），
//   普通的 zz_xxx_test.dart 用例不归本门禁管。
//   ★ 本文件**排除自己**：门禁正文/注释里必然有反斜杠样本，
//     不排除 ⇒ 一旦判据收紧就恒红。
//
// # 检测规则（第 2 版收紧了：只打「**拼出来的**路径」）
//   先剥掉注释（含跨行块注释、跨行三引号字符串），再逐个字符串字面量看：
//   ① 普通字面量（可插值）：body 里出现**两个连续反斜杠**、**且**含未被转义的
//      美元符 ⇒ 违规。这正是缺陷签名：把硬编码分隔符**拼进**运行时算出来的路径。
//   ② 加号拼接写法：root.path + 两个反斜杠 + name。字面量 body 里出现
//      **两个连续反斜杠**（或 raw 字面量 body **整个就是反斜杠**）、**且**该
//      字面量**紧挨着加号** ⇒ 违规。第 ① 条会漏掉这一形态（那种字面量里
//      没有美元符），实测本仓 0 处、而模拟的 4 种缺陷写法全部命中。
//   ③ raw 字面量不做插值 ⇒ 单靠 ① 永不违规。r + 单引号 + 一个反斜杠 + 单引号
//      这类「引用分隔符这个字符本身」的写法（replaceAll 那个字符, '/') 不算 ——
//      但它**紧挨加号**时就是 ② 的缺陷形态，必须抓。
//   ④ 纯字面量路径（盘符路径样本）= 喂给被测代码的**输入样本** /
//      固定位置 / 路径穿越**攻击向量**，语义由调用方决定 ⇒ 不在本门禁管辖内。
//      第 1 版把这些全判违规 ⇒ 一片假红，门禁会被当噪音废弃。
//   ⚠️ 刻意**不**匹配单个反斜杠接 n / t / 美元符 的正常转义：那是换行 /
//      制表符 / 转义美元符，与路径分隔符无关。
//
// # 豁免（**有名字 + 有理由**，绝不静默跳过）
//   见 kWaivers。豁免必须**真的挂着**：被豁免的文件里若已无此类字面量 ⇒ 红。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// 本门禁自己：注释里就有反斜杠样本 ⇒ 必须排除，否则判据一收紧就恒红
const String kSelfFileName = 'zz_cr_dl_c25_path_sep_test.dart';

/// 探针文件的发现口径（理由见文件头「探针文件的口径」）
bool isProbeFileName(String name) {
  final lower = name.toLowerCase();
  return lower.contains('probe') || name.startsWith('zz_cr_');
}

/// ★ 冻结的**必须覆盖**名单（金丝雀）。
///
/// 7 个 = CR-25 正文点名 + 同批被点名的探针文件（第 1 版写死的那 7 个）；
/// 3 个 = 提交后会进 CI、第 1 版**漏掉**的那三个（覆盖洞本体）。
///
/// 这 10 个必须**全部**出现在动态发现集里 ⇒ 发现口径一旦退化就带名字红。
const List<String> kMustBeCovered = <String>[
  // —— 第 1 版的 7 个（一个都不许删）——
  'zz_t3_19_cache_page_probe_test.dart',
  'zz_t11_panel_probe_test.dart',
  'zz_t12_defect_a_probe_test.dart',
  'zz_t12_seam_probe_test.dart',
  'zz_t3_20_concurrency_probe_test.dart',
  'zz_t11_block_probe_test.dart',
  'zz_t11_panel_render_probe_test.dart',
  // —— ★ 第 1 版漏掉的三个（覆盖洞本体）——
  'zz_cr_cache_owner1009_test.dart',
  'zz_cr_play_detail_cover_test.dart',
  'zz_cr_play_detail_origin_test.dart',
];

/// 显式豁免：**有名字 + 有理由**。豁免必须真的挂着（见主用例第 ⑤ 步）。
class Waiver {
  const Waiver(this.file, this.reason);
  final String file;
  final String reason;
}

const List<Waiver> kWaivers = <Waiver>[
  Waiver(
    'zz_t12_cache_page_probe_test.dart',
    '只有一处，是 Windows 长路径前缀（四个反斜杠 + 问号 + 反斜杠）的构造，'
        '且被同一个 test 里 if (Platform.isWindows) 整段包住 ⇒ macOS 上根本不执行。'
        '改成 Platform.pathSeparator 反而会破坏「长路径前缀」这个被测语义。',
  ),
];

// ───────────────────────── 源码扫描器 ─────────────────────────

/// 一个字符串字面量
class _Lit {
  const _Lit(
      this.start, this.end, this.isRaw, this.body, this.closer, this.closed);
  final int start; // 字面量在行内的起始下标（引号本身）
  final int end; // 字面量在行内的结束下标
  final bool isRaw; // 带 r 前缀（不做插值、无反斜杠转义）
  final String body; // 引号之间的**源码原文**
  final String closer; // 闭合引号（三引号时是三个字符）
  final bool closed; // 本行内是否闭合成
}

/// 这个字符能出现在标识符里吗（用来判定 r 前缀是不是独立的 raw 标记）
bool _isIdentChar(String c) {
  final u = c.codeUnitAt(0);
  return (u >= 0x30 && u <= 0x39) ||
      (u >= 0x41 && u <= 0x5A) ||
      (u >= 0x61 && u <= 0x7A) ||
      c == '_' ||
      c == r'$';
}

/// 从 raw[start]（引号本身）开始读一个字面量
_Lit _readLiteral(String raw, int start) {
  final q = raw[start];
  final p = start - 1;
  final isRaw = p >= 0 &&
      (raw[p] == 'r' || raw[p] == 'R') &&
      (p == 0 || !_isIdentChar(raw[p - 1]));
  final triple =
      start + 2 < raw.length && raw[start + 1] == q && raw[start + 2] == q;
  final closer = triple ? q + q + q : q;
  var j = start + 1;
  while (j < raw.length) {
    if (!isRaw && raw[j] == r'\') {
      j += 2; // 转义：跳过下一个字符（\ 与 \" 都算）
      continue;
    }
    if (raw.startsWith(closer, j)) {
      return _Lit(start, j + closer.length, isRaw, raw.substring(start + 1, j),
          closer, true);
    }
    j++;
  }
  return _Lit(start, raw.length, isRaw, raw.substring(start + 1), closer, false);
}

/// 跨行状态：块注释 / 未闭合的多行字面量
class _ScanState {
  bool inBlock = false;
  String? triple;
}

/// 剥掉注释后，收集这一行里的字符串字面量
List<_Lit> _literalsOnLine(String raw, _ScanState st) {
  final out = <_Lit>[];
  var i = 0;
  while (i < raw.length) {
    if (st.inBlock) {
      final e = raw.indexOf('*/', i);
      if (e < 0) return out; // 整行还在块注释里
      st.inBlock = false;
      i = e + 2;
      continue;
    }
    final t = st.triple;
    if (t != null) {
      final e = raw.indexOf(t, i);
      if (e < 0) return out; // 整行还在多行字符串里
      st.triple = null;
      i = e + t.length;
      continue;
    }
    final c = raw[i];
    if (c == '/' && i + 1 < raw.length && raw[i + 1] == '/') {
      return out; // 行注释：本行到此为止
    }
    if (c == '/' && i + 1 < raw.length && raw[i + 1] == '*') {
      st.inBlock = true;
      i += 2;
      continue;
    }
    if (c == "'" || c == '"') {
      final lit = _readLiteral(raw, i);
      if (!lit.closed) {
        st.triple = lit.closer; // 未闭合 ⇒ 后面几行都算这个字符串
        return out;
      }
      out.add(lit);
      i = lit.end;
      continue;
    }
    i++;
  }
  return out;
}

/// 这个字面量 body 里有没有**未被转义的**美元符（= 真的会插值）
bool _hasInterpolation(String body) {
  for (var i = 0; i < body.length; i++) {
    if (body[i] != r'$') continue;
    var back = 0;
    var k = i - 1;
    while (k >= 0 && body[k] == r'\') {
      back++;
      k--;
    }
    if (back % 2 == 0) return true;
  }
  return false;
}

bool _isSpace(String c) => c == ' ' || c == '\t';

/// 这个字面量**紧挨着加号**吗（root.path + 反斜杠 + name 这种拼法）
bool _adjacentToPlus(String raw, _Lit lit) {
  var a = lit.start - 1;
  while (a >= 0 && _isSpace(raw[a])) {
    a--;
  }
  if (a >= 0 && raw[a] == '+') return true;
  var b = lit.end;
  while (b < raw.length && _isSpace(raw[b])) {
    b++;
  }
  if (b < raw.length && raw[b] == '+') return true;
  return false;
}

/// body 整个就是反斜杠（raw 字面量的「引用分隔符这个字符本身」形态）
bool _allBackslashes(String body) {
  if (body.isEmpty) return false;
  for (var i = 0; i < body.length; i++) {
    if (body[i] != r'\') return false;
  }
  return true;
}

/// 这个字面量算不算「把硬编码反斜杠分隔符拼进路径」
bool _literalIsViolation(String raw, _Lit lit) {
  if (lit.isRaw) {
    // raw 不做插值 ⇒ 只有「紧挨加号」这一种拼路径形态（见文件头规则 ③）
    return _allBackslashes(lit.body) && _adjacentToPlus(raw, lit);
  }
  if (!lit.body.contains('\\\\')) return false; // 两个连续反斜杠
  // ① 插值写法 / ② 加号拼接写法
  return _hasInterpolation(lit.body) || _adjacentToPlus(raw, lit);
}

/// 扫一个文件，返回违规的「行号: 原文」
List<String> _scanFile(String path) {
  final out = <String>[];
  final st = _ScanState();
  final lines = File(path).readAsLinesSync();
  for (var i = 0; i < lines.length; i++) {
    for (final lit in _literalsOnLine(lines[i], st)) {
      if (_literalIsViolation(lines[i], lit)) {
        out.add((i + 1).toString() + ': ' + lines[i].trim());
      }
    }
  }
  return out;
}

void main() {
  test('CR-25：探针文件里 0 处硬编码反斜杠路径分隔符', () {
    // ── ① 动态发现：不写死名单 ───────────────────────────────────
    final dir = Directory('test');
    expect(dir.existsSync(), isTrue,
        reason: '★ 必须在仓库根跑（test/ 目录找不到）');
    final discovered = <String>[];
    for (final e in dir.listSync()) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      if (!name.startsWith('zz_') || !name.endsWith('.dart')) continue;
      if (name == kSelfFileName) continue; // 排除自己（见文件头）
      if (!isProbeFileName(name)) continue;
      discovered.add(name);
    }
    discovered.sort();
    debugPrint('CR-25 动态发现 ' + discovered.length.toString() + ' 个探针文件');

    // ── ② 发现口径退化 ⇒ 带文件名字红 ───────────────────────────
    final missing =
        kMustBeCovered.where((n) => !discovered.contains(n)).toList();
    debugPrint('CR-25 必须覆盖 ' +
        kMustBeCovered.length.toString() +
        ' 个（命中 ' +
        (kMustBeCovered.length - missing.length).toString() +
        ' 个）');
    expect(missing, isEmpty,
        reason: '★★★ 动态发现口径退化：这些**必须被覆盖**的探针文件没被发现 → ' +
            missing.join(', ') +
            '。别改小 kMustBeCovered —— 它是覆盖洞的金丝雀。');

    // ── ③ 自己必须不在扫描集里，否则判据一收紧就恒红 ─────────────
    expect(discovered.contains(kSelfFileName), isFalse,
        reason: '★ 本门禁自己必然含反斜杠样本 ⇒ 必须排除，否则恒红。');

    // ── ④ 覆盖洞本体：发现集不许退化成第 1 版那种写死的 7 个 ─────
    expect(discovered.length, greaterThan(7),
        reason: '★ 发现集只有 ' +
            discovered.length.toString() +
            ' 个 ⇒ 又退化成写死名单了（第 1 版就是 7 个）。');

    // ── ⑤ 豁免必须**真的挂着**（防止静默跳过）────────────────────
    final waivedNames = kWaivers.map((w) => w.file).toSet();
    final badWaiver = <String>[];
    for (final w in kWaivers) {
      if (!discovered.contains(w.file)) {
        badWaiver.add(w.file + '（不在发现集里）');
        continue;
      }
      if (!File('test/' + w.file).existsSync()) {
        badWaiver.add(w.file + '（文件不存在）');
        continue;
      }
      if (_scanFile('test/' + w.file).isEmpty) {
        badWaiver.add(w.file + '（已无此类字面量 ⇒ 豁免该删掉）');
      }
    }
    expect(badWaiver, isEmpty,
        reason: '★★ 豁免名单不实（会变成静默跳过）：' + badWaiver.join(' / '));

    // ── ⑥ 逐文件扫描 ────────────────────────────────────────────
    final bad = <String>[];
    var waivedHits = 0;
    for (final name in discovered) {
      final hits = _scanFile('test/' + name);
      if (hits.isEmpty) continue;
      if (waivedNames.contains(name)) {
        waivedHits += hits.length;
        for (final h in hits) {
          debugPrint('CR-25 豁免（理由见 kWaivers）→ ' + name + ' ' + h);
        }
        continue;
      }
      for (final h in hits) {
        bad.add(name + ' ' + h);
      }
    }
    for (final b in bad) {
      debugPrint('CR-25 违规 → ' + b);
    }
    final waivedFiles =
        kWaivers.where((w) => discovered.contains(w.file)).length;
    debugPrint('CR-25 扫了 ' +
        discovered.length.toString() +
        ' 个探针文件，违规 ' +
        bad.length.toString() +
        ' 处，豁免 ' +
        waivedHits.toString() +
        ' 处（豁免文件 ' +
        waivedFiles.toString() +
        ' 个）');
    expect(bad, isEmpty,
        reason: '★★★ 这些反斜杠在 POSIX 上是普通字符 ⇒ macOS CI 必红。'
            '请用 Platform.pathSeparator（或 p.join）拼路径。');
  });
}
