// ═══════════════════════════════════════════════════════════════════════
//  task-38 追加：提示的**触发点**（不是会话状态，而是"内容需要"）
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话（逐字）：
// > 像次元城支持自动登录的应该无感登录，哔哩哔哩如果遇到片源需要会员
// > 或者登录，这时候才提示出来（账号过期也是同理）
//
// # 这条改变了**触发点**
//
// ```text
// 【原设计】触发点 = 会话状态
//   provider_login_panel.dart 里登录态一失效就**自动展开**表单：
//     if (_state == SessionState.expired) _open = true;
//   ⇒ 用户一进设置页就看到"需要登录/可能需要验证码"
//   ⇒ 但那一刻他**什么都不用做**：
//      · canAutoLogin 的源 → 点播时自动重登（实测 0.46 秒）
//      · 其它源            → 他只是路过，不是遇上了播不了的片
//
// 【用户要的】触发点 = 内容需要
//   ⇒ 设置页**不主动展开**；真正的提示发生在**播放失败那一刻**
//     （player_page 的失败页给「登录」按钮 —— 那条路径本来就有）
// ```
//
// # ★ 为什么用"源码断言"而不是 pump 面板
//
// `_open` 是 `_ProviderLoginPanelState` 的**私有字段**，而它的取值
// 依赖两个 FFI 调用（`provider_session` / `provider_session_state`）的结果。
// 直接 pump 需要真核心 + 真会话，且只能间接验证"表单有没有展开"。
//
// ⚠️ 所以这里断言源码，但**必须剥注释** —— 本文件的注释里
//    恰恰写了 `if (_state == SessionState.expired) _open = true;` 这句原文
//    （就在上面解释里），不剥的话把真代码删掉测试照样绿。
//    这是本项目**实测复现过**的假绿洞（注释匹配）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String panel;

  setUpAll(() {
    panel = File('lib/ui/widgets/provider_login_panel.dart').readAsStringSync();
  });

  /// 剥掉 Dart 注释（行注释 + 块注释），保留其余内容
  ///
  /// ⚠️ 必须处理**块注释**（本项目注释以块注释为主），否则只剥 `//`
  ///    会把大段解释文字当成代码（那会让"断言某个标识符不存在"假红）。
  String codeOnly(String src) {
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

  group('① ★★★ 设置页不再"主动打扰"（删掉自动展开）', () {
    test('★★★ 登录态失效时**不得**自动展开表单', () {
      final code = codeOnly(panel);
      expect(
        code.contains('if (_state == SessionState.expired) _open = true;'),
        isFalse,
        reason: '★★★ 这行是"一进设置页就弹登录表单"的根因。'
            '用户要的是**遇到需要的内容时**才提示，不是在设置页主动打扰。'
            '（断言剥注释后的代码：注释里写一遍不算）',
      );
    });

    test('★★ 但**入口要保留** —— 用户想登录时点得到「登录」按钮', () {
      final code = codeOnly(panel);
      /*
       * 这是「提供入口」vs「主动打扰」的区分：
       * ```text
       * 删掉自动展开  → 用户自己点「登录」
       * 连入口都删掉  → 用户找不到地方登录（那才是 bug）
       * ```
       * 入口 = 状态行右侧那个 TextButton（`_open` 的切换开关）。
       */
      expect(
        code.contains('setState(() => _open = !_open)'),
        isTrue,
        reason: '★ 用户点击展开/收起的入口必须还在 —— '
            '否则用户永远没法登录了（修一个坏一个）',
      );
      // defaultOpen 也必须仍然生效（失败页弹窗靠它直接展开表单）
      expect(
        code.contains('_open = widget.defaultOpen'),
        isTrue,
        reason: '★ 失败页弹窗传 `defaultOpen: true`（"点进来就是要登录"）——'
            '那条路径**应该**自动展开，不能一起砍掉',
      );
    });

    test('★ 初始化时 `_open` 只由 `defaultOpen` 决定（不依赖会话状态）', () {
      final code = codeOnly(panel);
      // initState 里赋值那一处
      final i = code.indexOf('void initState()');
      expect(i > 0, isTrue, reason: '应能找到 initState');
      final body = code.substring(i, i + 400);
      expect(body.contains('_open = widget.defaultOpen'), isTrue);
      expect(
        body.contains('_state == SessionState.expired'),
        isFalse,
        reason: '★ initState 里不该按会话状态决定展开',
      );
    });
  });

  group('② ★★ 播放失败时的判据：结构化 kind 优先', () {
    late String player;

    setUpAll(() {
      player = File('lib/ui/player_page.dart').readAsStringSync();
    });

    test('★★★ `_isAuthError` 必须**优先**用结构化 kind', () {
      final code = codeOnly(player);
      final i = code.indexOf('bool get _isAuthError');
      expect(i > 0, isTrue, reason: '应能找到 _isAuthError');
      final body = code.substring(i, i + 900);

      expect(
        body.contains("_errorKind == 'unauthorized'"),
        isTrue,
        reason: '★★★ 必须优先用来自 FFI 的结构化 kind —— '
            '它**不受文案措辞影响**。只靠 `contains("unauthorized")` 时，'
            '插件换个说法就静默失效（不是报错，而是"登录按钮不出现"）',
      );
      // 结构化判据必须在字符串兜底**之前**（否则等于没用）
      final kindIdx = body.indexOf("_errorKind == 'unauthorized'");
      final strIdx = body.indexOf("lower.contains('unauthorized')");
      expect(strIdx > kindIdx, isTrue,
          reason: '★★ 结构化判据必须在字符串判据**之前** —— '
              '放后面等于没有（字符串那条会先短路）');
    });

    test('★★ 字符串兜底**必须保留**（没有 kind 的错误真实存在）', () {
      final code = codeOnly(player);
      final i = code.indexOf('bool get _isAuthError');
      final body = code.substring(i, i + 900);
      expect(
        body.contains("lower.contains('unauthorized')"),
        isTrue,
        reason: '★ 兜底要留：`media_kit` 的播放错误、本页自拼的中文串'
            '（如 `_error = \'该内容没有可播放的地址\'`）都**没有** kind',
      );
      expect(body.contains("e.contains('登录已失效')"), isTrue,
          reason: '★ `playback.rs:157` 的固定文案没有结构化 kind 可依');
    });

    test('★★ 4 处 `_error = e.toString()` 都要**同时记 kind**', () {
      final code = codeOnly(player);
      final nStr = RegExp(r'_error = e\.toString\(\);').allMatches(code).length;
      final nKind = RegExp(r'_errorKind = _kindOf\(e\);').allMatches(code).length;
      expect(nStr, greaterThan(0), reason: '应能找到 e.toString() 赋值点');
      expect(
        nKind,
        nStr,
        reason: '★★★ 每一处 `_error = e.toString()` 都必须配一行 '
            '`_errorKind = _kindOf(e)` —— 漏一处，那条路径就退化回字符串判据'
            '（实际 $nKind / $nStr）',
      );
    });

    test('★★ 清空 `_error` 时也要清 `_errorKind`（防陈旧 kind 误判）', () {
      final code = codeOnly(player);
      /*
       * 危险场景：上一次失败是 unauthorized（`_errorKind='unauthorized'`），
       * 然后换了源、清空了 `_error` 但**没清 kind**；
       * 下一次失败是"没有可播放地址"（kind=null）——
       * 于是 `_isAuthError` 拿**旧的** unauthorized 判 true →
       * 给一个跟登录无关的失败显示「登录」按钮（误判）。
       */
      final nClearErr = RegExp(r'_error = null;').allMatches(code).length;
      final nClearKind = RegExp(r'_errorKind = null;').allMatches(code).length;
      expect(nClearErr, greaterThan(0));
      expect(
        nClearKind,
        nClearErr,
        reason: '★★★ 每处 `_error = null` 都要配 `_errorKind = null` —— '
            '否则陈旧的 kind 会让下一次**无关**的失败也显示「登录」按钮'
            '（实际 $nClearKind / $nClearErr）',
      );
    });

    test('★★ 更正了那段**事实错误**的注释（"风险和收益不成比例"）', () {
      /*
       * 原注释说「为这一处判断去改动整条错误传递链的类型……风险和收益
       * 完全不成比例」。那句话**不成立** —— 链上早就有 kind 了
       * （`ffi.rs` 的 err_json → `SourinCoreException.kind`），
       * 是这一层自己 `toString()` 掉了。
       *
       * ⚠️ 断言"新说明存在"而不是"旧句子不存在"：
       *    旧句子会作为**历史记录**被引用（说明它错在哪），
       *    所以它可能仍然出现在注释里 —— 那是**对的**。
       */
      final raw = player;
      expect(
        raw.contains('这里原先的注释') || raw.contains('那个判断**不成立**'),
        isTrue,
        reason: '★★ 必须写明"原注释的事实判断不成立"—— '
            '否则后人会继续相信那段话，永远不去用现成的 kind',
      );
      expect(
        raw.contains('kind') && raw.contains('SourinCoreException'),
        isTrue,
        reason: '★ 要指出 kind 本来就在 `SourinCoreException` 上',
      );
    });
  });

  group('③ `_kindOf` 的取值契约', () {
    test('★ 拿不到 kind 时返回 null（不是空串、不是抛）', () {
      final code = codeOnly(File('lib/ui/player_page.dart').readAsStringSync());
      final i = code.indexOf('static String? _kindOf(Object? e)');
      expect(i > 0, isTrue, reason: '应能找到 _kindOf');
      final body = code.substring(i, i + 400);
      expect(
        body.contains('return null;'),
        isTrue,
        reason: '★ 不是 SourinCoreException 时必须返回 null —— '
            '调用方靠 null 判断"要回退到字符串判据"',
      );
      expect(
        body.contains('k.isEmpty ? null : k'),
        isTrue,
        reason: '★ 空串也要当成 null（否则 `_errorKind == ""` 会绕过兜底判断）',
      );
    });
  });
}
