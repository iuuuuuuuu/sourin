// ═══════════════════════════════════════════════════════════════════════
//  task-38：登录失效文案按能力位特例化（UI 契约）
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话：
// > 次元城登录失效 明明不需要验证码就可以自动登录，还提示 验证码
//
// # ★★★ 为什么用「运行时断言」而不是「源码文本断言」
//
// 本项目刚踩过两个**假绿洞**（另一个任务抓到的，已记成铁律），
// 一般形式是：**断言要盯住"值从哪来"，不能只盯"调用点长什么样"**。
// ```text
// 洞 A：`src.contains('followRemainingByKey')` 不带括号
//       ⇒ 删掉调用点后，顶部的 import 行还匹配 ⇒ 照样绿
// 洞 B：断言字面量 `unread: f.unreadCount`
//       ⇒ 把取值包一层 helper ⇒ 一个字面量都不出现 ⇒ 照样绿
// ```
// 所以这里**不**断言 `panel.contains('_caps.canAutoLogin')` 之类 ——
// 那种断言：
// ```text
// · 注释里写一遍也算（本项目已在注释里写了大量解释！）
// · 把判据包进 helper 就绕过
// · 函数改名/内联也骗不过（但文本断言会被骗）
// ```
// 改成：把判据抽成**顶层纯函数** [`expiredHintFor`]，
// 测试直接**给参数、断言返回值** —— 参数变 → 返回值必须跟着变，
// 这是"值从哪来"层面的判据。
//
// ⚠️ 端到端（真凭据 → 自动重登成功）在
//    `rust/sourin_core/tests/zz_t38_*.rs` 里跑（那才是机制本身的证明）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/widgets/provider_login_panel.dart';

void main() {
/// 剥掉 JS 注释后的源码
///
/// # ★★★ 为什么必须剥（实测抓到的**假绿洞**）
///
/// 第一版断言是 `js.contains('canAutoLogin: true,')`。
/// 变异测试把那一行改成注释后：
/// ```js
/// // canAutoLogin: true,
/// ```
/// **断言照样绿** —— 因为 `'// canAutoLogin: true,'`
/// 里**包含**子串 `'canAutoLogin: true,'`。
///
/// ⇒ 这正是 Lead 提醒的那类洞（另一个任务抓到过两个）：
///   **"注释里写一遍也算"**。而本项目的注释里**恰恰**写了大量解释文字，
///   所以这个洞在这里**极易触发**，不是理论风险。
///
/// 修法：断言前先剥注释。剥的时候要**保留行号结构**（避免跨行错位），
/// 且要处理**块注释** `/* */`（本项目的注释风格就是块注释为主）。
String jsCodeOnly(String src) {
  final out = StringBuffer();
  var inBlock = false;
  for (final line in src.split('\n')) {
    final buf = StringBuffer();
    var i = 0;
    while (i < line.length) {
      if (inBlock) {
        final end = line.indexOf('*/', i);
        if (end < 0) {
          i = line.length; // 整行都在块注释里
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
      if (line.startsWith('//', i)) {
        break; // 行注释：本行剩余部分丢弃
      }
      buf.write(line[i]);
      i++;
    }
    out.writeln(buf.toString());
  }
  return out.toString();
}

  group('① 能力位：模型层（运行时）', () {
    test('★★ 默认 false —— 没声明的插件不能被承诺"正在自动重登"', () {
      /*
       * 默认 true 的后果：26 个老插件（没实现 autoLogin）也会显示
       * 「正在自动重新登录」→ 用户干等一个**永远不会发生**的重登
       * ⇒ 比原来那句通用文案**更糟**（从"误导"变成"撒谎"）。
       */
      const c = Capabilities();
      expect(c.canAutoLogin, isFalse,
          reason: '★ Capabilities() 的 canAutoLogin 必须默认 false');
    });

    test('★ fromJson 读 `can_auto_login`，缺字段兜底 false', () {
      expect(
        Capabilities.fromJson(const {'can_auto_login': true}).canAutoLogin,
        isTrue,
        reason: '★ 必须读 `can_auto_login`（snake_case，与 Rust 序列化一致）',
      );
      expect(
        Capabilities.fromJson(const {'can_auto_login': false}).canAutoLogin,
        isFalse,
      );
      // ★ 老插件的 JSON 里根本没有这个键
      expect(
        Capabilities.fromJson(const {}).canAutoLogin,
        isFalse,
        reason: '★ 缺字段时必须兜底 false —— 老插件不能被承诺自动重登',
      );
    });

    test('★ 驼峰键**不该**被读（防有人改错键名）', () {
      expect(
        Capabilities.fromJson(const {'canAutoLogin': true}).canAutoLogin,
        isFalse,
        reason: '★ 后端发的是 `can_auto_login`；若前端改读 camelCase，'
            '值会永远停在默认 false —— 表现是"能力位声明了但界面没反应"',
      );
    });
  });

  group('② 文案判据：直接断言**返回值**（不是源码文本）', () {
    test('★★★ canAutoLogin=true → 文案**不含「验证码」**且说不用动手', () {
      const caps = Capabilities(canAutoLogin: true);
      final d = expiredHintFor(caps);

      expect(
        d.hint.contains('验证码'),
        isFalse,
        reason: '★★★ 次元城没有验证码 —— 能自动重登时**绝不能**提"验证码"。'
            '实际文案：${d.hint}',
      );
      expect(d.hint.contains('正在自动重新登录'), isTrue,
          reason: '★ 应如实告诉用户正在自动重登');
      expect(d.hint.contains('直接播放即可恢复'), isTrue,
          reason: '★★ 必须告诉用户**不用动手** —— 用户的困惑正是'
              '"明明能自动登录，为什么叫我手动完成"');
      expect(d.tone, Tone.ok,
          reason: '★ 这是好消息（不用你动手）—— 用错误色会继续吓用户');
    });

    test('★★★ canAutoLogin=false → 保留原版通用文案（含验证码）', () {
      const caps = Capabilities(canAutoLogin: false);
      final d = expiredHintFor(caps);

      expect(
        d.hint.contains('验证码'),
        isTrue,
        reason: '★ 对真有验证码的源，原版那句（SettingsView.vue:175）是**对的** —— '
            '不能一刀切删掉',
      );
      expect(d.hint, '需重新登录（可能需要验证码，请手动完成）',
          reason: '★ 一字不改地保留原版文案');
      expect(d.tone, Tone.err);
    });

    test('★★ 两种能力的文案**必须不同**（否则等于没做特例化）', () {
      final on = expiredHintFor(const Capabilities(canAutoLogin: true));
      final off = expiredHintFor(const Capabilities(canAutoLogin: false));

      expect(
        on.hint == off.hint,
        isFalse,
        reason: '★★★ 两条文案必须不同 —— 相同就说明能力位没被用上'
            '（Owner 报的 bug 会原封不动回来）',
      );
      expect(on.tone == off.tone, isFalse,
          reason: '★ 色调也该不同（能自愈的不该是错误色）');
      // label 相同是**对的**（都是"登录已失效"，区别在 hint）
      expect(on.label, off.label,
          reason: '两种情况的标题都该是「登录已失效」（区别在提示语）');
    });

    test('★ 判据只认 `canAutoLogin` 这一个字段', () {
      /*
       * 反向断言：**只**翻 `canAutoLogin`，其它能力位不许影响这条文案。
       * 否则以后有人加个字段就把这条文案带偏了。
       */
      final base = expiredHintFor(const Capabilities(canAutoLogin: true));
      final noisy = expiredHintFor(const Capabilities(
        canAutoLogin: true,
        vod: true,
        live: true,
        search: true,
        loginRequired: true,
        loginSupported: true,
        loginNeedsUsername: false,
        loginQrSupported: true,
        multiSource: true,
      ));
      expect(noisy.hint, base.hint,
          reason: '★ 其它能力位不该影响这条文案（判据只认 canAutoLogin）');
    });
  });

  group('③ 插件侧：次元城必须声明并实现', () {

    test('★★★ cycani.js 声明 canAutoLogin: true 且真的实现了两个方法', () {
      final raw = File('rust/sourin_core/plugins/cycani.js').readAsStringSync();
      final js = jsCodeOnly(raw);

      /*
       * ⚠️ 断言**剥注释后**的源码 —— 见 `jsCodeOnly` 的说明。
       *    不剥的话，把声明注释掉测试照样绿（已实测复现）。
       */
      expect(
        js.contains('canAutoLogin: true,'),
        isTrue,
        reason: '★★★ 不声明能力位，UI 就继续显示「可能需要验证码」——'
            'Owner 报的 bug 原封不动回来。'
            '（断言剥注释后的代码：注释里写一遍**不算**）',
      );
      expect(js.contains('async canAutoLogin()'), isTrue,
          reason: '★ 声明必须与**真实实现**相符（不然是空头支票）');
      expect(js.contains('async autoLogin()'), isTrue,
          reason: '★ 同上');
      // ★ 实现体里必须真的重新登录（不是空壳）
      expect(
        RegExp(r'async autoLogin\(\)[\s\S]{0,300}?await login\(').hasMatch(js),
        isTrue,
        reason: '★ `autoLogin()` 必须真的调 `login()` —— '
            '空壳实现会让"正在自动重新登录"变成谎言',
      );
    });
  });

  group('④ 能力位必须真的接到界面上（防"声明了但没人用"）', () {
    test('★★ 面板的 expired 分支必须走 `expiredHintFor(_caps)`', () {
      /*
       * ⚠️ 这一条**是**源码断言，且我承认它的局限：
       *    它只能证明"接线还在"，不能证明"文案对"（文案由上面 ② 用
       *    运行时值证明）。两者互补：
       * ```text
       * ② 证明：判据函数对 → 但可能**没人调它**（函数空有）
       * ④ 证明：有人在调  → 但函数本身可能写错
       * ```
       * 缺任何一条都有洞，所以两条都要。
       *
       * ⚠️ 断言锚点选 `expiredHintFor(_caps)`（带参数调用），
       *    不是裸 `expiredHintFor` —— 否则 import 行/注释也能匹配（假绿洞 A）。
       *
       * ⚠️ 而且必须**剥注释**：本文件注释里就写了
       *    `return expiredHintFor(_caps);` 这句原文（就在上面那段解释里），
       *    不剥的话把真调用点删掉、只留注释，断言照样绿（已实测复现）。
       */
      final src = jsCodeOnly(
        File('lib/ui/widgets/provider_login_panel.dart').readAsStringSync(),
      );
      expect(
        src.contains('return expiredHintFor(_caps);'),
        isTrue,
        reason: '★★ 必须断言**带参数的调用**且**剥掉注释** —— '
            '裸函数名会被 import 行匹配、注释原文也会被匹配，'
            '两者都是被实测证明过的假绿洞',
      );
    });
  });
}
