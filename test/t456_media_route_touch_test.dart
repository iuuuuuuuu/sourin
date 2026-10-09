// t456 守卫：全仓所有 `MediaPage(...)` 构造点都必须显式传 `isTouchOnly`。
//
// 缺陷背景（真机证实，2026-10-04）：
//   lib/shell.dart 的 `_mediaRoute()` 构造 MediaPage 时漏传 `isTouchOnly`，
//   MediaPage 用默认值 false 兜底 ⇒ PlayerPage._isPcKeyboardTarget 恒为 true，
//   于是手机上经首页卡片进入的播放器整条走 PC 键盘/鼠标分支：
//     · 双击不快进快退，而是切换全屏（logcat: [PLAYER-KEY] 双击 ⇒ 切换全屏）
//     · 长按右半屏读 pcButtons.forwardRate，左半屏读 pcButtons.rewindStep
//     · 设置页「长按左右两侧」开关关掉也不生效（_longPressEnabledForThisDevice 恒 true）
//   这类缺陷不会编译报错、不会抛异常，只会「悄悄走错分支」——
//   所以用源码契约测试把它钉死：只要有人再加一个漏传的 MediaPage 构造点，本测试就红。
//
// 这不是行为测试（行为测试需要起真播放器，成本过高），
// 但它守的是一个**可静态判定**的契约，且真的会红（见文件末尾的自检用例）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '_support/strip_comments.dart';

/// 需要扫描的源码根目录（相对包根）。
const List<String> kScanRoots = <String>['lib'];

/// 递归收集 .dart 文件。
List<File> dartFilesUnder(Directory dir) {
  final out = <File>[];
  if (!dir.existsSync()) return out;
  for (final e in dir.listSync(recursive: true, followLinks: false)) {
    if (e is File && e.path.endsWith('.dart')) out.add(e);
  }
  out.sort((a, b) => a.path.compareTo(b.path));
  return out;
}

/// ★★★ 2026-10-09 修复：扫描前**必须先剥注释**（本文件曾被自己的注释绊倒）
///
/// # 实测踩到的假红（三处，全是文档注释里写了 `MediaPage(...)` 这几个字）
/// ```text
/// lib/shell.dart:4724      /// lead 裁决（原文）：**不要改 `shell.dart` 里 `MediaPage(...)` 那个构造点
/// lib/shell.dart:4835      * 本处是全仓**唯一**漏传这个参数的 `MediaPage(` 构造点（其余
/// lib/ui/cache_page.dart:323  /// lead 裁决：**不要改 shell.dart 里 MediaPage(...) 那个构造点的参数表**
/// ```
/// ⇒ 三处都被数成了真的构造调用 ⇒ offenders 非空 ⇒ 测试红。
/// ★ 而本文件头部 :10-11 早就写过「这类缺陷不会编译报错……所以用源码契约测试把它钉死」——
///   同一个道理：静态文本匹配**注释也会被匹配到**，而注释里提到 API 名是**正常且必要**的
///   （解释设计决策时不可能不写类型名）。
///
/// # 为什么在**这里**剥、而不是让作者去改注释
/// ```text
/// ① 改注释是「为了迁就工具而让文档变差」—— 那三处注释正是解释 task-12 那个
///    「不许改 MediaPage 参数表」裁决的唯一记录，写 `MediaPage(` 是有意让人搜得到的。
/// ② 本仓**铁律 170**：同一纪律只能有一个实现 ⇒ 用 `_support/strip_comments.dart`
///    的**状态机**版（不是正则 —— 正则会误删字符串里的 `/* */`、且漏删行尾注释）。
/// ③ 剥注释**保留换行**（见那个 helper 的 :98/:109），所以剥后偏移与原文**逐行对齐**，
///    `substring(0, at).split('\n').length` 算出的行号仍然准确。
/// ```
List<({int at, String text})> mediaPageCallSites(String src) {
  // ★ 唯一的改动：入口处剥一次注释，其余逻辑**逐字不动**。
  return _scanCallSites(stripComments(src));
}

/// 真正干活的扫描器 —— **只接受已剥注释的源码**。
///
/// ⚠️ 不要直接用这个函数（会被注释骗）；一律走上面那个 [mediaPageCallSites]。
///
/// 找出 [src] 里所有 `MediaPage(` 的**构造调用**，返回 (起始下标, 完整实参文本)。
///
/// 排除类定义里的 `const MediaPage({...})`：调用不会以 `{` 开头（命名参数调用
/// 的第一个非空白字符是标识符，不是 `{`）。
List<({int at, String text})> _scanCallSites(String src) {
  const needle = 'MediaPage(';
  final out = <({int at, String text})>[];
  var from = 0;
  while (true) {
    final idx = src.indexOf(needle, from);
    if (idx < 0) break;
    from = idx + 1;
    // 前一个字符不能是标识符字符（排除 `MyMediaPage(` 这类）。
    if (idx > 0) {
      final prev = src.codeUnitAt(idx - 1);
      final isIdent = (prev >= 0x30 && prev <= 0x39) ||
          (prev >= 0x41 && prev <= 0x5A) ||
          (prev >= 0x61 && prev <= 0x7A) ||
          prev == 0x5F;
      if (isIdent) continue;
    }
    // 括号配对，取完整实参文本。
    var j = idx + needle.length;
    var depth = 1;
    while (j < src.length && depth > 0) {
      final c = src.codeUnitAt(j);
      if (c == 0x28) {
        depth++;
      } else if (c == 0x29) {
        depth--;
      }
      j++;
    }
    final text = src.substring(idx, j);
    // 跳过类定义 / 构造声明（实参以 `{` 开头）。
    var k = idx + needle.length;
    while (k < src.length && (src.codeUnitAt(k) == 0x20 || src.codeUnitAt(k) == 0x0A || src.codeUnitAt(k) == 0x0D || src.codeUnitAt(k) == 0x09)) {
      k++;
    }
    if (k < src.length && src.codeUnitAt(k) == 0x7B) continue;
    out.add((at: idx, text: text));
  }
  return out;
}

void main() {

  test('全仓每个 MediaPage(...) 构造点都显式传了 isTouchOnly', () {
    final offenders = <String>[];
    var total = 0;
    for (final r in kScanRoots) {
      for (final f in dartFilesUnder(Directory(r))) {
        final src = f.readAsStringSync();
        if (!src.contains('MediaPage(')) continue;
        for (final s in mediaPageCallSites(src)) {
          total++;
          if (!s.text.contains('isTouchOnly:')) {
            final upto = src.substring(0, s.at);
            final line = upto.split('\n').length;
            offenders.add('${f.path.replaceAll('\\', '/')}:$line');
          }
        }
      }
    }
    expect(total, greaterThanOrEqualTo(3),
        reason: '扫描到的 MediaPage 构造点太少（实际 $total），扫描逻辑可能失效');
    expect(offenders, isEmpty,
        reason: '这些 MediaPage 构造点漏传 isTouchOnly（手机上会整条走 PC 分支）：\n  ${offenders.join('\n  ')}');
  });

  test('MediaPage 仍声明并透传 isTouchOnly（否则上面的契约是空的）', () {
    final f = File('lib/ui/media_page.dart');
    expect(f.existsSync(), isTrue, reason: 'lib/ui/media_page.dart 不见了');
    final src = f.readAsStringSync();
    expect(src.contains('final bool isTouchOnly;'), isTrue,
        reason: 'MediaPage.isTouchOnly 字段被删了 —— 守卫会变成空转');
    expect(src.contains('this.isTouchOnly = false'), isTrue,
        reason: 'MediaPage.isTouchOnly 的默认值兜底被改了，漏传的后果会变');
    expect(src.contains('isTouchOnly: widget.isTouchOnly'), isTrue,
        reason: 'MediaPage 没有把 isTouchOnly 透传给 PlayerPage');
  });

  test('shell.dart 的 _mediaRoute 是显式合规点（回归锚点）', () {
    /*
     * ★★★ 2026-10-09：这里**必须也剥注释**，否则偏移不可比。
     *
     * 实测踩到：`mediaPageCallSites` 返回的是**剥注释后**的下标，
     * 而本行原来在**原文**里找 `_mediaRoute` 的下标 —— 剥注释会让源码变短，
     * 于是 `s.at > i` 全部为 false ⇒ 报「_mediaRoute 之后没有任何 MediaPage 构造点」。
     * 那不是产品缺陷，是**两个坐标系混用**。
     *
     * 纪律：凡是拿 `mediaPageCallSites` 的下标与别处比较的地方，
     *       那个「别处」也必须是**同一份剥注释后的文本**。
     */
    final src = stripComments(File('lib/shell.dart').readAsStringSync());
    final i = src.indexOf('MaterialPageRoute<void> _mediaRoute(');
    expect(i, greaterThan(0), reason: 'lib/shell.dart 里找不到 _mediaRoute 了');
    final sites = mediaPageCallSites(src);
    final near = sites.where((s) => s.at > i).toList();
    expect(near, isNotEmpty, reason: '_mediaRoute 之后没有任何 MediaPage 构造点');
    expect(near.first.text.contains('isTouchOnly: Device.isTouchOnly'), isTrue,
        reason: '_mediaRoute 的第一个 MediaPage 构造点必须传 isTouchOnly: Device.isTouchOnly');
  });

  test('★ 自检：扫描器必须**剥注释**（注释里的 MediaPage( 不算构造点）', () {
    /*
     * ★ 这条是 2026-10-09 加的守卫 —— 没有它，「已剥注释」这个性质**无人看守**，
     *   将来有人把 mediaPageCallSites 改回直接扫原文，测试会**静默**退回假红。
     *
     * 三个样本都是真踩过的形态（见 mediaPageCallSites 的文档注释）。
     */
    String withCode(String comment) => [comment, 'Widget f() => 1;'].join('\n');
    final lineComment = withCode('/// 不要改 shell.dart 里 MediaPage(...) 那个构造点');
    final blockComment = withCode('/* 全仓唯一漏传的 MediaPage( 构造点（其余都传了） */');
    final urlInString = withCode('// 看 https://x/MediaPage( 这个地址');
    expect(mediaPageCallSites(lineComment), isEmpty,
        reason: '行注释里的 MediaPage( 被当成了构造点 ⇒ 会假红');
    expect(mediaPageCallSites(blockComment), isEmpty,
        reason: '块注释里的 MediaPage( 被当成了构造点 ⇒ 会假红');
    expect(mediaPageCallSites(urlInString), isEmpty,
        reason: '行注释（含 URL）里的 MediaPage( 被当成了构造点 ⇒ 会假红');

    // ★ 反面对照：真代码必须**仍然被抓到**（否则"剥注释"可能剥过头）
    const real = 'Widget f() => MediaPage(provider: p, id: i, isTv: Device.isTv);';
    expect(mediaPageCallSites(real).length, 1,
        reason: '真构造点被剥掉了 ⇒ 剥注释剥过头，门禁失去覆盖');
  });

  test('自检：扫描器能抓出故意漏传的样本', () {
    const bad = 'Widget f() => MediaPage(provider: p, id: i, isTv: Device.isTv);';
    const good =
        'Widget f() => MediaPage(provider: p, id: i, isTv: Device.isTv, isTouchOnly: Device.isTouchOnly);';
    const defn = 'class MediaPage extends StatefulWidget { const MediaPage({super.key}); }';
    final b = mediaPageCallSites(bad);
    final g = mediaPageCallSites(good);
    final d = mediaPageCallSites(defn);
    expect(b.length, 1);
    expect(b.first.text.contains('isTouchOnly:'), isFalse, reason: '漏传样本没被抓出来');
    expect(g.length, 1);
    expect(g.first.text.contains('isTouchOnly:'), isTrue);
    expect(d, isEmpty, reason: '类定义被误当成构造调用了');
  });
}
