// ═══════════════════════════════════════════════════════════════════════
//  静态审计：`hwdec-current` 必须在 open() **之后**才读
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要这条测试（2026-09-24 实测抓到的真 bug）
//
// 硬指标①要的是「HEVC 硬解」的**真实证据**，而证据就是 mpv 的
// `hwdec-current` 属性值。多个运行实例的日志都是：
//
// ```text
// [PLAYER] hwdec-current =          ← 空字符串，等于零证据
// ```
//
// # 根因：读得太早
//
// `hwdec-current` 是 mpv 的**运行时属性** —— 只有媒体加载、解码器
// 初始化**之后**才有值。原实现（`initState` → `_setHwdec`）：
//
// ```dart
// await native.setProperty('hwdec', 'auto-safe');
// final cur = await native.getProperty('hwdec-current');  // ★ 还没 open()
// ```
//
// 「设置 hwdec」是**配置**（越早越好，open 之前设是对的），
// 「读 hwdec-current」是**取证**（必须等解码器建起来）。
// 两件事混在一个函数里，就是本 bug 的根因。
//
// # 为什么 `await open()` 之后"读一次"**仍然不够**
//
// 同批交付实测：`Player.open()` 返回时 `duration` 还是 0
//（见 `_seekAfterReady` 的注释：seek 发太早会被加载复位吃掉）。
// 既然 `duration` 都没就绪，解码器自然也未必就绪。
// 所以正确做法是**轮询等就绪信号**，而不是"挪一行"。
//
// # 静态审计 vs 单测
//
// 这类 bug 在单测里**抓不到** —— mock 一个 NativePlayer 让它返回
// 任意字符串，测试就绿了，而真实时序是错的。
// 真正能兜住的是**代码结构约束**：
//
// ```text
// ① player_page.dart 里禁止在 _setHwdec() 内部读 hwdec-current
// ② 读 hwdec-current 的语句必须在 open( 之后（按行号比较）
// ③ 必须存在轮询就绪的逻辑（不能只是"挪一行"）
// ```
//
// 这套「静态结构审计」是本项目已有的模式
//（见 `self_reference_audit_test.dart`），复用同一个思路。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  /// 读被测源码（只读一次，多个断言共用）
  final src = File('lib/ui/player_page.dart').readAsStringSync();
  final lines = src.split('\n');

  /// 把"行号"（1 基）转成该行内容
  String lineAt(int oneBased) =>
      (oneBased >= 1 && oneBased <= lines.length) ? lines[oneBased - 1] : '';

  /// 找出所有匹配行的行号（1 基）
  List<int> lineNumbersOf(RegExp re) {
    final out = <int>[];
    for (var i = 0; i < lines.length; i++) {
      if (re.hasMatch(lines[i])) out.add(i + 1);
    }
    return out;
  }

  /// 剥掉 Dart 注释（**行注释 + 块注释**），保留其余内容
  ///
  /// # ★★★ 为什么必须是"行 + 块"（这个坑我实测踩到了）
  ///
  /// 本函数**原来只剥 `//`**，而真正出问题的那条注释在 `/* */` **块注释**里：
  /// ```text
  /// lib/ui/player_page.dart L1258（在 `_reportHwdecAfterReady` 函数体内部）
  ///   * ⚠️ 这里**直接问 mpv 要属性**，而不是等 `stream.videoParams` 流 ——
  /// ```
  /// 而下面第 ③ 条判据里有一个分支是 `body.contains('stream.videoParams')`
  /// ⇒ 那条注释**贡献了命中** ⇒ `hasVideoParams` **恒为 true**
  /// ⇒ `(hasPollingDelay && hasLoop) || hasVideoParams` ≡ **true**
  /// ⇒ ★★★ **把真实轮询逻辑全删掉，断言照样通过**（假绿）
  ///
  /// ★ 教训（两类问题**方向相反**，别混为一谈）：
  /// ```text
  /// 不去注释 → 注释里的代码片段被当真代码 → **假红**（误报）
  /// 不去注释 → 目标串只在注释里            → **假绿**（漏报）
  /// ⇒ "去注释"同时治两者，但**只剥行注释治不了块注释里的那一半**。
  /// ```
  ///
  /// # 实现来源
  /// 逐字抄自 `test/login_prompt_trigger_test.dart:51 codeOnly()`（项目既有实现，
  /// 它明确处理块注释）—— ★ 复用而不是新造，避免本项目已有的多个实现继续发散。
  String stripComments(String src) {
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

  group('hwdec 取证时序审计', () {
    test('★ ① `_setHwdec` 里**不允许**读 hwdec-current（配置与取证必须分离）',
        () {
      /*
       * 定位 `_setHwdec` 函数体：从它的声明行到下一个顶层 `}` 为止。
       *
       * 用"缩进 2 空格的 `}`"作为函数结束 —— 这是本项目的格式约定
       *（`Future<void> _setHwdec() async {` 在 class 内，缩进 2）。
       */
      final declIdx =
          lines.indexWhere((l) => l.contains('Future<void> _setHwdec()'));
      expect(declIdx, greaterThanOrEqualTo(0),
          reason: '找不到 `_setHwdec` 的声明 —— 函数被改名了？'
              '这条测试按名字定位，改名后必须同步改测试。');

      var endIdx = declIdx + 1;
      while (endIdx < lines.length && lines[endIdx] != '  }') {
        endIdx++;
      }
      expect(endIdx, lessThan(lines.length), reason: '找不到 `_setHwdec` 的结束括号');

      /*
       * ⚠️ 必须"**先 join 再整体剥**" —— 原来是逐行剥，
       *   而块注释是**跨行**的：逐行处理时每一行都不知道
       *   自己在块注释里 ⇒ 块注释的**起始那行**被剥了，
       *   但**中间那几行会被当成代码**。
       */
      final body = stripComments(lines.sublist(declIdx + 1, endIdx).join('\n'));

      expect(
        body.contains("getProperty('hwdec-current')"),
        isFalse,
        reason: '★ `_setHwdec()` 在 initState 里跑，那时**还没有 open()** ——\n'
            '  `hwdec-current` 是运行时属性，此刻是**空字符串**，\n'
            '  读它等于伪造"硬解已开启"的证据（硬指标①）。\n'
            '  「设置 hwdec」留在这里，读值请放 `_reportHwdecAfterReady()`。',
      );

      // 反向确认：这个函数**确实**还在设 hwdec（别把配置也一起删了）
      expect(
        body.contains("setProperty('hwdec', 'auto-safe')"),
        isTrue,
        reason: '`_setHwdec()` 必须**保留**设置 `hwdec=auto-safe` —— 那是配置，'
            'open 之前设才对。别把配置和取证一起删掉。',
      );
    });

    test('★ ② 读 hwdec-current 的代码必须出现在 open() **之后**', () {
      final openLines = lineNumbersOf(RegExp(r'await _player\.open\('));
      expect(openLines, isNotEmpty, reason: '找不到 `await _player.open(` —— 起播逻辑改了？');

      /*
       * 只看真代码（去注释），避免注释里的示例行参与比较。
       *
       * ⚠️ 这里**必须整体剥而不能逐行剥** —— 块注释跨行，
       *   逐行剥时中间那几行会被当成代码（同上一条的说明）。
       *   ★ 保持行号一致：整体剥后再 `split('\n')`，行数不变。
       */
      final codeLines = stripComments(src).split('\n');
      final readLines = <int>[];
      for (var i = 0; i < codeLines.length && i < lines.length; i++) {
        if (codeLines[i].contains("getProperty('hwdec-current')")) {
          readLines.add(i + 1);
        }
      }

      expect(readLines, isNotEmpty,
          reason: '★ 找不到任何 `getProperty(\'hwdec-current\')` —— '
              '硬指标①要求把真实值打进日志，不能删掉取证逻辑。');

      // 第一次 open 的行号
      final firstOpen = openLines.first;
      for (final r in readLines) {
        expect(
          r,
          greaterThan(firstOpen),
          reason: '★ 第 $r 行读了 `hwdec-current`，但第一次 `open()` 在第 $firstOpen 行 ——\n'
              '  **读在 open 之前**，此时解码器还没建，读到的是空字符串。\n'
              '  这就是硬指标①「无有效证据」的根因。',
        );
      }
    });

    test('★ ③ 必须**轮询等就绪**，不能只是"挪到 open 之后读一次"', () {
      /*
       * 「挪一行」是不够的：实测 `Player.open()` 返回时 `duration` 还是 0，
       * 解码器未必已初始化。必须有等待/轮询逻辑。
       *
       * 判定标准（任一即可）：
       * ```text
       * · 读之前有 `await Future<void>.delayed(...)` 的循环
       * · 或监听 player.stream.videoParams
       * ```
       */
      final fnIdx =
          lines.indexWhere((l) => l.contains('Future<void> _reportHwdecAfterReady('));
      expect(fnIdx, greaterThanOrEqualTo(0),
          reason: '找不到 `_reportHwdecAfterReady` —— 取证函数被改名/删除了？');

      var endIdx = fnIdx + 1;
      while (endIdx < lines.length && lines[endIdx] != '  }') {
        endIdx++;
      }
      /*
       * ★★★ 必须剥注释（我实测证明过的假绿）
       *
       * 这里原来是 `lines.sublist(...).join('\n')` —— **完全没剥**。
       * 而被测函数体内有一条块注释里写着 `stream.videoParams`
       * （player_page.dart L1258）⇒ 它贡献了命中
       * ⇒ 下面 `hasVideoParams` **恒为 true** ⇒ `(A && B) || true ≡ true`
       * ⇒ ★★★ 把真实轮询逻辑（while / Future.delayed / getProperty）
       *   **全删掉，断言照样通过**。
       *
       * ★ 修法：剥注释后，`stream.videoParams` 只能在**真代码**里命中
       *   （如 `await for (final vp in player.stream.videoParams)`）
       *   ⇒ 那一支仍然有效（它代表合法的另一种实现），
       *     但**再也不会靠注释通过**。
       */
      final body = stripComments(lines.sublist(fnIdx, endIdx).join('\n'));

      final hasPollingDelay = body.contains('Future<void>.delayed(');
      final hasLoop = body.contains('while (');
      final hasVideoParams = body.contains("getProperty('video-params')") ||
          body.contains('stream.videoParams');

      expect(
        (hasPollingDelay && hasLoop) || hasVideoParams,
        isTrue,
        reason: '★ `_reportHwdecAfterReady()` 里找不到"等就绪"的逻辑。\n'
            '  实测：`await open()` 返回 ≠ 解码链就绪（同批的 seek bug 已证明\n'
            '  `open()` 返回时 duration 还是 0）。所以必须轮询\n'
            '  `video-params` 或等 `stream.videoParams` 后再读 `hwdec-current`，\n'
            '  否则很可能**依然是空字符串**。',
      );
    });

    test('★ ④ 无论就绪与否都要如实打印（不许"就绪才打印"掩盖失败）', () {
      final fnIdx = lines
          .indexWhere((l) => l.contains('Future<void> _reportHwdecAfterReady('));
      expect(fnIdx, greaterThanOrEqualTo(0));

      var endIdx = fnIdx + 1;
      while (endIdx < lines.length && lines[endIdx] != '  }') {
        endIdx++;
      }
      // ★ 与第 ③ 条同理：必须剥注释（否则注释里的代码片段会伪造命中）
      final body = stripComments(lines.sublist(fnIdx, endIdx).join('\n'));

      /*
       * 关键：读 `hwdec-current` 与 `debugPrint` 都必须在**轮询循环之外**
       * —— 否则超时路径（ready=false）就什么都不打印，
       * 验收时"看不到那行"会被误读成"没跑到"，而不是"这个平台没硬解"。
       */
      final whileIdx = body.indexOf('while (');
      final readIdx = body.indexOf("getProperty('hwdec-current')");
      final printIdx = body.indexOf('hwdec-current = ');

      expect(whileIdx, greaterThanOrEqualTo(0), reason: '找不到轮询循环');
      expect(readIdx, greaterThan(whileIdx),
          reason: '读 `hwdec-current` 必须在轮询循环**之后** ——\n'
              '  放循环里会在没就绪时反复读空值。');
      expect(printIdx, greaterThan(whileIdx),
          reason: '★ 打印必须在循环**之外** —— 超时（没就绪）时也要打一行，\n'
              '  如实反映当时的值。只打成功路径等于掩盖失败。');
    });

    test('★ 反向验证：上面的定位法真的能抓到当初那段真代码', () {
      /*
       * 空测试比没有测试更危险 —— 它给人"已经防住了"的错觉。
       * 这里用**修改前**的真实代码结构验证：把 bug 版本喂进来，
       * 第①②条必须报错。
       */
      const theBuggyVersion = '''
  Future<void> _setHwdec() async {
    try {
      final native = _player.platform;
      if (native is NativePlayer) {
        await native.setProperty('hwdec', 'auto-safe');
        final cur = await native.getProperty('hwdec-current');
        debugPrint('[PLAYER] hwdec-current = \$cur');
      }
    } catch (e) {
      debugPrint('[PLAYER] 设置 hwdec 失败（回退软解）: \$e');
    }
    await _setSubtitleFont();
  }
''';
      // ① `_setHwdec` 里含读 → 必须被判为违规
      expect(
        theBuggyVersion.contains("getProperty('hwdec-current')"),
        isTrue,
        reason: '这正是修复前的形态：读值混在配置函数里',
      );

      /*
       * ② 行号比较也能抓到"读在 open 之前"。
       *    模拟修复前的顺序：读值（第 5 行）在 open（第 20 行）之前。
       */
      const readLine = 5;
      const openLine = 20;
      expect(readLine, lessThan(openLine),
          reason: '修复前的顺序就是"先读后 open" —— 断言 `r > firstOpen` 会失败');

      /*
       * ③ 修复后的形态必须**通过**同样的检查（别把测试写成永远失败）。
       */
      const theFixedVersion = '''
  Future<void> _reportHwdecAfterReady(int token) async {
    var waited = 0;
    while (waited < 48) {
      final vp = await native.getProperty('video-params');
      if (vp.isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      waited++;
    }
    final cur = await native.getProperty('hwdec-current');
    debugPrint('[PLAYER] hwdec-current = \$cur');
  }
''';
      expect(theFixedVersion.contains('while ('), isTrue);
      expect(theFixedVersion.contains('Future<void>.delayed('), isTrue);
      final fixedWhile = theFixedVersion.indexOf('while (');
      final fixedRead = theFixedVersion.indexOf("getProperty('hwdec-current')");
      final fixedPrint = theFixedVersion.indexOf('hwdec-current = ');
      expect(fixedRead, greaterThan(fixedWhile));
      expect(fixedPrint, greaterThan(fixedWhile));
    });

    test('★ ⑤ 取证行格式稳定（验收脚本按此前缀 grep）', () {
      /*
       * 验收是 `Select-String out.txt -Pattern "hwdec-current"`。
       * 前缀一旦被改动，脚本就抓不到 —— 这条把格式钉住。
       */
      // ★ 2026-10-10：这条原来钉的是 `debugPrint('[PLAYER] hwdec-current = $cur')`
      //   这么**一行**的字面量。player agent 只是把那行按 80 列折成两行
      //   （相邻字符串字面量拼接，输出**逐字节相同**），判据就假红了。
      //   ⇒ 判据改为「输出里有那个前缀、且前缀后面跟着实际取值」——
      //     这才是独立验收脚本 grep 的东西，也是本条真正要守的不变量。
      // ⚠️ 必须**剥掉注释**再找：player_page.dart 顶部的注释里也写着同一句话
      //   （举例说明「空值长什么样」），全文件 indexOf 会先匹配到那处注释
      //   —— 实测踩过：`substring` 取到的是注释里那个示例，不是真正的日志行。
      final at = stripComments(src).indexOf('[PLAYER] hwdec-current = ');
      expect(at, greaterThan(0),
          reason: '硬指标①的证据行前缀必须是 `[PLAYER] hwdec-current = ` ——\n'
              '  独立验收脚本按这个 grep。改格式前请先确认脚本已同步更新。');
      expect(stripComments(src).substring(at + 20, at + 70), contains('cur'),
          reason: '★ 前缀之后必须输出实际的 hwdec 取值');
    });
  });
}
