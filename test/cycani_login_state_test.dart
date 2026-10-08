// ═══════════════════════════════════════════════════════════════════════════
//  cycani 登录状态 —— 「显示已登录但实际不能播」的回归锁（2026-09-24）
// ═══════════════════════════════════════════════════════════════════════════
//
// # 用户报的 bug（原话）
//
// > 次元城明明已登录了,也提示未登录,然后我要求在这个页面也要显示出来
// > 登录 按钮,点击可以进行直接登录,但是首先要修复这个显示已登录,
// > 但实际不能播放的问题
//
// # 实测出来的根因（**不是**字段名不匹配）
//
// 编排者最初判断是「camelCase vs snake_case 字段名不匹配」。
// 实测证伪了：`plugins/mod.rs:1090` 的 `call_js` 出口**已经统一做过**
// camelCase → snake_case 递归转换（`js_value_to_rust`），
// 所以 `expiresAt` 到 Rust 时已经是 `expires_at`，解析正常。
//
// 真链路（隔离目录 + 用户真实数据只读副本，跑通全链路实测）：
// ```text
// token 真的过期（JWT exp 比现在早 11 小时）
//   → session_needs_refresh() = true   ← 它把「已过期」和「即将过期」都算 true
//   → session_state = Expiring         ← 无法区分二者
//   → UI 把 Expiring 渲染成「已登录 · 无需操作」   ← ★ 用户看到的现象
//   → 点播时 token 已死 → unauthorized
// ```
//
// # 这个文件锁什么
//
// ```text
// ① Rust 侧：真过期必须报 expired（不是 expiring）
// ② Rust 侧：解不出 exp 的 token（opaque / 无 exp / 畸形）**绝不能**报过期
// ③ Dart 侧：expiring 的文案不能说「无需操作」
// ④ Dart 侧：失败页的「登录」按钮**只对登录类错误**显示
// ⑤ Dart 侧：登录成功后要能自动重试播放
// ```
//
// ⚠️ 静态文本断言**必须先剥注释** —— 本项目在这个坑上踩过至少四次
//    （见 `settings_panels_test.dart` 的 `_code()` 说明）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 去掉注释行 —— 做文本匹配前**必须**先剥，否则注释里提到的标识符会被当成真实调用
String _code(String src) => src
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
    })
    .join('\n');

/// 读仓库里的源文件
///
/// ⚠️ 测试的工作目录是**包根目录**（`flutter test` 的行为），
///    所以用相对路径即可，不要写绝对路径。
String _read(String rel) => File(rel).readAsStringSync();

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① Rust：真过期必须与「即将过期」区分开
  // ═══════════════════════════════════════════════════════════════════
  group('Rust 会话过期判据', () {
    late String provider;
    late String registry;

    setUpAll(() {
      provider = _code(_read('rust/sourin_core/src/provider.rs'));
      registry = _code(_read('rust/sourin_core/src/registry.rs'));
    });

    test('Session 提供「有效到期时间」，expires_at 缺失时走 JWT 兜底', () {
      expect(
        provider.contains('fn effective_expires_at'),
        isTrue,
        reason: '★ 必须有这个方法 —— expires_at 缺失时它负责从 JWT 的 exp 兜底。'
            '没有它，插件不返回 expiresAt 的会话就永远判不出过期',
      );
      expect(
        provider.contains('fn jwt_exp_secs'),
        isTrue,
        reason: 'JWT 解析入口（只读 exp，**刻意不校验签名**）',
      );
    });

    test('★ expires_at 缺失时**真的会**去看 JWT，而不是直接返回 None', () {
      // `self.expires_at.or_else(|| jwt_exp_secs(...))` 是这个修复的核心
      expect(
        RegExp(r'expires_at\s*\.or_else\(').hasMatch(provider) ||
            provider.contains('or_else(|| jwt_exp_secs'),
        isTrue,
        reason: '★ 必须是 `expires_at.or_else(jwt 兜底)` 的形态 —— '
            '如果写成 `expires_at` 直接用，本 bug 就回来了',
      );
    });

    test('★★ 解不出 exp 时**不能**判过期（否则误伤 opaque token 源）', () {
      // `matches!(..., Some(exp) if exp <= now)` —— 只有 Some 且已过才算过期
      expect(
        provider.contains('fn is_expired_at'),
        isTrue,
        reason: '过期判据必须收成一个方法，便于测试与复用',
      );
      expect(
        RegExp(r'matches!\s*\(\s*self\s*\.\s*effective_expires_at\s*\(\s*\)'
                r'\s*,\s*Some\s*\(\s*exp\s*\)\s*if\s+exp\s*<=\s*now\s*\)')
            .hasMatch(provider),
        isTrue,
        reason: '★ 判据必须是「解出了 exp **且** 已过」才为 true。'
            '写成 `unwrap_or(0) <= now` 之类的形态会把所有解不出的 token '
            '（opaque token / 无 exp / 畸形）全判成过期 —— '
            '那比原 bug 更糟：用户会去重新登录一个本来好用的源',
      );
    });

    test('session_needs_refresh 走 effective_expires_at（不再直读 expires_at）', () {
      // 取 session_needs_refresh 的函数体
      final i = provider.indexOf('async fn session_needs_refresh');
      expect(i, greaterThan(0), reason: '找不到 session_needs_refresh');
      final body = provider.substring(i, provider.indexOf('\n    }', i));
      expect(
        body.contains('effective_expires_at()'),
        isTrue,
        reason: '★ 必须用 effective_expires_at —— 原来直读 `s.expires_at`，'
            '插件不返回该字段时恒为 None → 恒 false → 已死的 token 被当成'
            '「无需续期」',
      );
      expect(
        body.contains('s.expires_at'),
        isFalse,
        reason: '★ 不能再用裸 `s.expires_at` 做判据',
      );
    });

    test('session_state 在「真过期」与「即将过期」之间分流', () {
      final i = registry.indexOf('pub async fn session_state');
      expect(i, greaterThan(0), reason: '找不到 session_state');
      final body = registry.substring(i, registry.indexOf('\n    }', i));
      expect(
        body.contains('session_expired()'),
        isTrue,
        reason: '★ session_state 必须先问「真的过期了吗」，'
            '否则已死的 token 会被报成 Expiring → UI 显示「已登录」',
      );
      expect(
        body.contains('SessionState::Expired'),
        isTrue,
        reason: '真过期且无法自动重登 → 必须报 Expired（UI 才会说「登录已失效」）',
      );
    });

    test('真过期但**有凭据**时仍报 Expiring（能自愈就不吓用户）', () {
      final i = registry.indexOf('pub async fn session_state');
      final body = registry.substring(i, registry.indexOf('\n    }', i));
      // 顺序：session_expired() → can_auto_login() → Expiring / Expired
      final iExpired = body.indexOf('session_expired()');
      final iAuto = body.indexOf('can_auto_login()');
      final iHard = body.indexOf('SessionState::Expired');
      expect(iExpired, greaterThanOrEqualTo(0));
      expect(iAuto, greaterThan(iExpired),
          reason: '★ 顺序必须是「先判过期，再问能不能自动重登」—— 反了就会'
              '把能自愈的源也报成失效，平白制造焦虑');
      expect(iHard, greaterThan(iAuto),
          reason: '★ `Expired` 只能在「不能自动重登」的分支里出现');
    });

    test('手写 base64url 解码仍在（不引入新依赖）', () {
      expect(
        provider.contains('fn base64url_decode'),
        isTrue,
        reason: 'JWT 解码入口',
      );
      // 兼容标准 base64 与 url-safe 两套字母表
      expect(provider.contains("b'-' | b'+'"), isTrue,
          reason: '★ 必须同时接受 url-safe `-` 与标准 `+` —— '
              '有些站点发的 token 并不严格是 url-safe');
      expect(provider.contains("b'_' | b'/'"), isTrue,
          reason: '同上，`_` 与 `/` 都要接受');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② Dart：登录面板的文案必须诚实
  // ═══════════════════════════════════════════════════════════════════
  group('登录面板文案', () {
    late String panel;

    setUpAll(() {
      panel = _code(_read('lib/ui/widgets/provider_login_panel.dart'));
    });

    test('★★ expiring 不能再宣称「无需操作」', () {
      expect(
        panel.contains('无需操作'),
        isFalse,
        reason: '★ 这是本 bug 的**用户可见面**：token 已经死了 11 小时，'
            '界面却说「令牌将在到期前自动续期，无需操作」。'
            'expiring 同时涵盖「即将过期」和「已过期但有凭据」两种情况，'
            '文案必须对两者都成立 —— 至少要让用户知道"可能需要重新登录"',
      );
    });

    test('expiring 仍保留 Tone.ok（确实不用用户动手）', () {
      final i = panel.indexOf('case SessionState.expiring');
      expect(i, greaterThan(0));
      final body = panel.substring(i, panel.indexOf('case SessionState', i + 10));
      expect(
        body.contains('Tone.ok'),
        isTrue,
        reason: '两种 expiring 的共同点是「不用你动手」，不该报红吓用户',
      );
      expect(
        body.contains('自动恢复') || body.contains('自动重试'),
        isTrue,
        reason: '要告诉用户"会自动恢复"，而不是含糊其辞',
      );
    });

    test('expired 的措辞要看「有没有会话」，不能只看 loginRequired', () {
      final i = panel.indexOf('case SessionState.expired');
      expect(i, greaterThan(0));
      final body = panel.substring(i, panel.indexOf('\n    }', i));
      expect(
        body.contains('_session == null'),
        isTrue,
        reason: '★ cycani 的 loginRequired 恒为 true，光看它会对着'
            '「刚登录过、刚失效」的用户说「该源需要登录后才能播放」—— '
            '那正是用户原话里那个「也提示未登录」。'
            '判据要补上「有没有会话」：有会话=登录过→「登录已失效」',
      );
      expect(
        body.contains('需要登录'),
        isTrue,
        reason: '从没有过会话 → 引导第一次登录（两种情况都要有）',
      );
      /*
       * ★★★ 2026-09-25（task-38）：`登录已失效` 这句**搬走了**
       *
       * 原先它在 `expired` 的 switch 分支里；task-38 把它抽成顶层纯函数
       * `expiredHintFor(caps)`（理由是：文案要按 `canAutoLogin` 能力位分两种，
       * 抽出来才能**运行时**断言返回值 —— 本项目刚抓到两个"文本断言假绿"的洞）。
       *
       * ⚠️ 所以这里**不能**删掉这条断言，要**跟着搬**到新位置 ——
       *    否则「有会话时要说『登录已失效』」这个**真实约束**就没人守了
       *    （那正是用户 2026-09-24 报过的「也提示未登录」）。
       *
       * ⚠️ 断言锚点是 `expiredHintFor(` **带左括号**（不是裸函数名）——
       *    裸名字会被 import 行 / 注释匹配（已实测复现过的假绿洞）。
       */
      expect(
        body.contains('expiredHintFor('),
        isTrue,
        reason: '★ expired 分支现在委托给 `expiredHintFor()` —— '
            '这句必须在这里（否则文案判据被搬走却没人调它）',
      );
      // 把文案判据搬到函数定义处继续守
      final fi = panel.indexOf('expiredHintFor(');
      expect(fi, greaterThan(0), reason: '应能找到 expiredHintFor 的定义');
      final fnBody = panel.substring(fi, panel.indexOf('\n}', fi));
      expect(
        fnBody.contains('登录已失效'),
        isTrue,
        reason: '★★ 有会话但已失效 → 必须明确说「登录已失效」'
            '（用户原话「也提示未登录」就是这条没做到）',
      );
    });

    test('★ 登录成功要有回调（失败页据此自动重试）', () {
      expect(
        panel.contains('onLoggedIn'),
        isTrue,
        reason: '★ 用户要求「登录成功后能重试播放」。'
            '面板自己不知道调用方是弹窗还是内嵌卡片，所以只发信号',
      );
      // 回调必须在**登录成功之后**触发，不能在 catch 里
      final iLogin = panel.indexOf('Future<void> _login()');
      final body = panel.substring(iLogin, panel.indexOf('\n  }', iLogin));
      final iSetOk = body.indexOf("_ok = '登录成功'");
      final iCallback = body.indexOf('widget.onLoggedIn?.call()');
      expect(iSetOk, greaterThanOrEqualTo(0), reason: '找不到登录成功分支');
      expect(iCallback, greaterThan(iSetOk),
          reason: '★ 回调必须在 setState 里标记成功**之后**，'
              '否则登录失败也会触发重试（白打一次请求）');
    });

    test('提供就地登录弹窗（用户要求「点击可以进行直接登录」）', () {
      expect(
        panel.contains('Future<bool> showProviderLoginDialog('),
        isTrue,
        reason: '★ 用户原话：「点击可以进行直接登录」。'
            '失败页拿得到 providerId，没有理由让用户自己回设置页找',
      );
      expect(
        panel.contains('defaultOpen: true'),
        isTrue,
        reason: '失败页点进来就是要登录，直接展开表单，省掉一次点击',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ Dart：播放失败页的「登录」按钮
  // ═══════════════════════════════════════════════════════════════════
  group('播放失败页登录按钮', () {
    late String player;

    setUpAll(() {
      player = _code(_read('lib/ui/player_page.dart'));
    });

    test('★ 只在**确实是登录问题**时才显示登录按钮', () {
      expect(
        player.contains('bool get _isAuthError'),
        isTrue,
        reason: '必须有判据 —— 无条件显示会让「该内容没有可播放的地址」'
            '这类用户也看到登录按钮，误导他去重登一个本来好用的账号',
      );
      // 两个信号都要认：插件抛的 unauthorized + 宿主补的「登录已失效」
      final i = player.indexOf('bool get _isAuthError');
      final body = player.substring(i, player.indexOf('\n  }', i));
      expect(
        body.contains('unauthorized'),
        isTrue,
        reason: '★ 插件抛的（cycani.js: "unauthorized: 登录已失效…"）',
      );
      expect(
        body.contains('登录已失效'),
        isTrue,
        reason: '★ 宿主补的（playback.rs:157 的固定文案）—— '
            '两个信号来自不同层，缺一就会漏判',
      );
    });

    test('★ 判据不做宽泛匹配（「登录」二字不算）', () {
      final i = player.indexOf('bool get _isAuthError');
      final body = player.substring(i, player.indexOf('\n  }', i));
      // 允许 `e.contains('登录已失效')`，但不允许裸的 `contains('登录')`
      expect(
        RegExp(r"contains\(\s*'登录'\s*\)").hasMatch(body),
        isFalse,
        reason: '★ 「该源需要登录后才能播放」也含「登录」二字，'
            '但它不是失效 —— 宽泛匹配会误判',
      );
    });

    test('失败页把 onLogin 传给 _ErrorOverlay，且非登录错误时为 null', () {
      expect(
        player.contains('onLogin: _isAuthError'),
        isTrue,
        reason: '★ 必须用条件表达式传 —— 写成 `onLogin: () => ...` 就是无条件显示',
      );
    });

    test('_ErrorOverlay 的 onLogin 是可空（null = 不渲染按钮）', () {
      final i = player.indexOf('class _ErrorOverlay');
      expect(i, greaterThan(0));
      final body = player.substring(i, player.indexOf('\n}', i));
      expect(
        body.contains('final VoidCallback? onLogin'),
        isTrue,
        reason: '必须是可空 —— 这是「只对登录问题显示」的类型级保证',
      );
      expect(
        body.contains('if (onLogin != null)'),
        isTrue,
        reason: '★ 按钮要包在非空判断里，否则无条件渲染',
      );
      expect(
        body.contains("Text('登录')"),
        isTrue,
        reason: '按钮文案必须是「登录」（用户原话就是这么要求的）',
      );
    });

    test('★ 登录成功后自动重试播放', () {
      expect(
        player.contains('Future<void> _loginAndRetry()'),
        isTrue,
        reason: '用户要求「登录成功后能重试播放」',
      );
      final i = player.indexOf('Future<void> _loginAndRetry()');
      final body = player.substring(i, player.indexOf('\n  }', i));
      expect(
        body.contains('showProviderLoginDialog('),
        isTrue,
        reason: '★ 必须走就地弹窗（直接登录），不是跳设置页',
      );
      expect(
        body.contains('await _load()'),
        isTrue,
        reason: '★ 登录成功后要真的重试，不能只是关掉弹窗',
      );
      // 只在成功时重试
      expect(
        body.contains('!ok') || body.contains('if (!ok'),
        isTrue,
        reason: '★ 登录失败不能重试 —— 白打一次请求，还会把错误提示冲掉，'
            '用户会以为"点了没反应"',
      );
    });

    test('登录弹窗要显示源的中文名（拿不到就退回 id）', () {
      final i = player.indexOf('Future<void> _loginAndRetry()');
      final body = player.substring(i, player.indexOf('\n  }', i));
      expect(
        body.contains('listProviders()'),
        isTrue,
        reason: '弹窗标题该是「登录 次元城」而不是「登录 cycani」',
      );
      expect(
        body.contains('name = _provider'),
        isTrue,
        reason: '★ 查不到名字要**退回 id**，不能因此不弹窗 —— '
            '用户此刻要的是登录，不是标题好看',
      );
    });

    test('没有引入 flutter/material（项目铁律）', () {
      final raw = _read('lib/ui/player_page.dart');
      expect(
        raw.contains("import 'package:flutter/material.dart'"),
        isFalse,
        reason: '统一用 package:material_ui/material_ui.dart',
      );
      final rawPanel = _read('lib/ui/widgets/provider_login_panel.dart');
      expect(
        rawPanel.contains("import 'package:flutter/material.dart'"),
        isFalse,
        reason: '统一用 package:material_ui/material_ui.dart',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 交叉检查：Rust 的错误文案与 Dart 的判据必须对得上
  // ═══════════════════════════════════════════════════════════════════
  group('跨层文案契约', () {
    test('★ playback.rs 的固定文案必须被 Dart 判据认到', () {
      final playback = _code(_read('rust/sourin_core/src/playback.rs'));
      expect(
        playback.contains('登录已失效'),
        isTrue,
        reason: '宿主在 ensure_session 失败时补的文案就在这',
      );
      // Dart 侧判据必须包含同一个串
      final player = _code(_read('lib/ui/player_page.dart'));
      final i = player.indexOf('bool get _isAuthError');
      final body = player.substring(i, player.indexOf('\n  }', i));
      expect(
        body.contains('登录已失效'),
        isTrue,
        reason: '★★ 这是**跨层契约**：Rust 改了这句文案，Dart 的登录按钮'
            '就会静默消失（判据匹配不上）→ 用户又回到"点了没反应"。'
            '两边必须同步',
      );
    });
  });
}
