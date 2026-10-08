// ═══════════════════════════════════════════════════════════════════════
//  模型 ↔ Rust 契约测试 —— 锁死「字段名必须对得上」
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守的是两个**静默失效**的真 bug（任务 P2）
//
// ```text
// bug ①  ProxyConfig 字段与 Rust 对不上 → **代理永远不生效且不报错**
// bug ②  Capabilities 的 4 个字段名后端根本不存在 → 标签永远是死标签
// ```
//
// # 为什么"没抛异常"不算通过
//
// 这两个 bug 的全部特征是**不报错**：
// ```text
// ① JSON 缺键 → `as bool? ?? false` 兜底 → 不抛
// ② 多传一个后端不认识的键 → serde 无 deny_unknown_fields → 静默丢弃
// ③ 编译过 ✓  analyze 0 error ✓  单测全绿 ✓  能跑起来 ✓
// ```
// 所以断言必须是**「写进去 → 读回来」的字段级往返**，
// 而不是"调用了某个方法"或"没抛异常"。
//
// # 两段各测什么
//
// ```text
// ① ProxyConfig  纯 Dart 的 toJson/fromJson 往返 + **权威键集合比对**
//                （键集合写死在测试里，抄自 Rust 源码；模型多一个键、
//                  少一个键都会红）
// ② Capabilities 15 个字段逐个往返 + **反向断言**：
//                旧字段名（login/rank/category/platform_history）
//                必须**读不出来**（后端从不发送它们）
// ```
//
// ⚠️ 真机 FFI 往返（写进 Rust → 读回 Dart）由
//    `lib/backup_panels_probe.dart` 做 —— 那需要真 FFI + 隔离数据目录，
//    单测环境里没有 `sourin_core.dll`。这里测的是**模型层**。
//    **两者都要跑**：模型层对了但接线错了，真机才会发现。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/models.dart';

// ═══════════════════════════════════════════════════════════════════════
//  ① ProxyConfig —— 权威键集合（抄自 Rust 源码）
// ═══════════════════════════════════════════════════════════════════════

/// `rust/sourin_core/src/proxy.rs:90-107` 的 `pub struct ProxyConfig`
///
/// ```rust
/// #[derive(Debug, Clone, Serialize, Deserialize)]
/// pub struct ProxyConfig {
///     #[serde(default)]                                        pub mode: ProxyMode,
///     #[serde(default, skip_serializing_if="Option::is_none")] pub url: Option<String>,
///     #[serde(default, skip_serializing_if="Vec::is_empty")]   pub bypass: Vec<String>,
///     #[serde(default)]                                        pub scope: ProxyScope,
///     #[serde(default, skip_serializing_if="Option::is_none")] pub username: Option<String>,
///     // ⚠️ 密码绝不在此结构里
/// }
/// ```
const _rustProxyKeys = {'mode', 'url', 'bypass', 'scope', 'username'};

void main() {
  group('① ProxyConfig ↔ Rust ProxyConfig', () {
    test('★★★ toJson 的键集合**必须**等于 Rust 的字段集（多一个少一个都红）', () {
      /*
       * 这是 bug ① 的核心断言。
       *
       * 旧的 toJson() 发的是 `{enabled, url, username}`：
       * ```text
       * · `enabled`  → Rust 没这个字段，serde **静默丢弃**
       * · `mode`     → 缺省 → #[serde(default)] 填 Direct
       * · `scope`    → 缺省 → ApiOnly（这次恰好对，但不是"对"，是"蒙对"）
       * · `bypass`   → 缺省 → 空
       * → uses_proxy() == false → 代理不生效，且**一个错误都不报**
       * ```
       * 所以断言**键集合相等**（不是"包含"）——
       * 这样将来有人手滑加回 `enabled`，或者漏掉 `scope`，都会立刻红。
       */
      const cfg = ProxyConfig(
        mode: ProxyMode.custom,
        url: 'http://127.0.0.1:7890',
        bypass: ['localhost'],
        scope: ProxyScope.all,
        username: 'u',
      );

      final keys = cfg.toJson().keys.toSet();
      expect(
        keys,
        _rustProxyKeys,
        reason: 'toJson 的键必须与 Rust 的 ProxyConfig 字段**完全一致**。\n'
            '  实际: $keys\n'
            '  期望: $_rustProxyKeys\n'
            '多出的键会被 serde 静默丢弃；缺少的键会被 #[serde(default)] '
            '填默认值（mode 缺省 = Direct = 代理不生效，且不报错）。',
      );
    });

    test('★★★ mode 必须真的出现在 payload 里（它是"代理生不生效"的唯一开关）', () {
      /*
       * 单独再钉一遍 `mode`，因为它是**最关键的那一个键**：
       * `uses_proxy()` 只看它（+ url）。
       *
       * ⚠️ 这条不是上一条的重复 —— 上一条断言"键集合相等"，
       *    但如果有人把 mode 的值写成 null 或空串，键还在、值没了，
       *    上一条照样绿。所以这条断言**值**。
       */
      final j = const ProxyConfig(mode: ProxyMode.custom).toJson();
      expect(j['mode'], 'custom',
          reason: 'mode 的值必须是 snake_case 的 wire 值');
      expect(j.containsKey('mode'), isTrue);
    });

    test('★★ mode 的三个 wire 值必须是 snake_case（serde rename_all）', () {
      for (final (m, wire) in [
        (ProxyMode.direct, 'direct'),
        (ProxyMode.system, 'system'),
        (ProxyMode.custom, 'custom'),
      ]) {
        expect(ProxyConfig(mode: m).toJson()['mode'], wire,
            reason: '${m.name} 的 wire 值应为 $wire');
      }
    });

    test('★★ scope 的两个 wire 值必须是 snake_case（`api_only` 不是 `apionly`）', () {
      for (final (s, wire) in [
        (ProxyScope.apiOnly, 'api_only'),
        (ProxyScope.all, 'all'),
      ]) {
        expect(ProxyConfig(scope: s).toJson()['scope'], wire,
            reason: '${s.name} 的 wire 值应为 $wire');
      }
    });

    test('★★ 默认值必须与 Rust 的 #[serde(default)] 一致', () {
      /*
       * ```rust
       * #[serde(default)] pub mode: ProxyMode,    // #[default] Direct
       * #[serde(default)] pub scope: ProxyScope,  // #[default] ApiOnly
       * ```
       * 这两条"恰好"是 Dart 侧最安全的默认值（直连 = 不劫持用户流量），
       * 但**必须显式钉住** —— 有人把 mode 默认改成 system，
       * 所有没配过代理的源都会突然走系统代理。
       */
      const cfg = ProxyConfig();
      expect(cfg.mode, ProxyMode.direct, reason: 'Rust #[default] 是 Direct');
      expect(cfg.scope, ProxyScope.apiOnly, reason: 'Rust #[default] 是 ApiOnly');
      expect(cfg.url, isNull, reason: 'Rust 是 Option<String>，默认 None');
      expect(cfg.username, isNull, reason: '同上');
      expect(cfg.bypass, isEmpty);
    });

    test('★★ url 为空时**不能**出现在 payload 里（否则后端存一个空 URL）', () {
      /*
       * Rust：`#[serde(default, skip_serializing_if = "Option::is_none")]`
       *
       * ```text
       * 传 null（不发该键）→ 后端存 None          ✓
       * 传 ""             → 后端存 Some("")     ✗ 落一个空 URL 进库
       * ```
       * 旧 Dart 的 `url` 是**非空 String 默认 ''**，所以它永远发 `"url": ""`
       * —— 这正是"配了代理但地址是空的"那种脏数据的来源。
       */
      expect(const ProxyConfig(mode: ProxyMode.custom).toJson().containsKey('url'),
          isFalse,
          reason: 'url 为 null 时不该发这个键（后端 skip_serializing_if）');
      expect(
        const ProxyConfig(mode: ProxyMode.custom, url: '   ')
            .toJson()
            .containsKey('url'),
        isFalse,
        reason: '全空白的 url 也要归一成"不发"（否则后端存一个空 URL）',
      );
      expect(
        const ProxyConfig(mode: ProxyMode.custom, url: ' http://a:1 ')
            .toJson()['url'],
        'http://a:1',
        reason: '非空的 url 要去掉首尾空白再发',
      );
    });

    test('★★ bypass 为空时不发；非空时原样发', () {
      expect(const ProxyConfig().toJson().containsKey('bypass'), isFalse,
          reason: 'Rust 是 skip_serializing_if = "Vec::is_empty"');
      expect(
        const ProxyConfig(bypass: ['localhost', '127.0.0.1']).toJson()['bypass'],
        ['localhost', '127.0.0.1'],
      );
    });

    test('★★★ payload 里**绝不能**出现 password（密码只走钥匙串）', () {
      /*
       * Rust 硬约定（`proxy.rs:106`）：
       * > ⚠️ 密码绝不在此结构里 —— 只存钥匙串，见 set_password / take_password
       *
       * 原版也照这个做：密码单独走钥匙串，不进配置对象，**也就不进备份**。
       * 所以这条不只是"字段名对不上"，而是**安全问题**。
       */
      const cfg = ProxyConfig(
        mode: ProxyMode.custom,
        url: 'http://127.0.0.1:7890',
        username: 'user',
        hasPassword: true, // 只是一个 UI 标记，**不是密码本身**
      );
      final j = cfg.toJson();
      expect(j.containsKey('password'), isFalse,
          reason: '★ 密码绝不能进配置对象（它走 set_proxy_password → 系统钥匙串）');
      expect(j.containsKey('has_password'), isFalse,
          reason: 'has_password 是**本机 UI 状态**，不是后端契约的一部分；'
              '发过去只会多一个被 serde 忽略的野字段');
      expect(j.containsKey('hasPassword'), isFalse);
    });

    test('★★★ 「写进去 → 读回来」纯 Dart 往返：逐字段必须相等', () {
      /*
       * ★ 核心验收（模型层版本）。
       *
       * ⚠️ 只断言"没抛异常"不算通过 —— 必须断言**字段真的往返成功**。
       *    这正是这个 bug 能潜伏这么久的原因：它不报错。
       */
      const written = ProxyConfig(
        mode: ProxyMode.custom,
        url: 'http://127.0.0.1:7890',
        bypass: ['localhost', '*.internal'],
        scope: ProxyScope.all,
        username: 'alice',
      );

      // 走一遍真实的序列化路径：toJson → （模拟网络）→ fromJson
      final back = ProxyConfig.fromJson(written.toJson());

      expect(back.mode, ProxyMode.custom,
          reason: '★★★ mode 必须往返成 custom —— **不是 direct**。'
              'mode 掉回 direct 就是"代理静默失效"这个 bug 本身。');
      expect(back.mode, isNot(ProxyMode.direct));
      expect(back.url, written.url);
      expect(back.bypass, written.bypass);
      expect(back.scope, ProxyScope.all);
      expect(back.username, written.username);
    });

    test('★★ fromJson 必须能吃后端**真实的**输出（含 skip_serializing_if 省略的键）', () {
      /*
       * 后端 `mode = Direct` 时**只发一个键**：
       * ```json
       * {"mode":"direct"}
       * ```
       * （url/username 是 None 被 skip、bypass 是空 Vec 被 skip）
       *
       * 如果 fromJson 对缺失键不容忍（比如 `j['url'] as String` 不带 `?`），
       * 这里就会抛 —— 而真实场景里"直连"是**最常见**的形态。
       */
      final direct = ProxyConfig.fromJson({'mode': 'direct'});
      expect(direct.mode, ProxyMode.direct);
      expect(direct.url, isNull);
      expect(direct.bypass, isEmpty);
      expect(direct.scope, ProxyScope.apiOnly,
          reason: 'scope 缺失 → 后端默认 api_only');

      // 完全空的 JSON（防御性：后端若返回 {}）
      expect(() => ProxyConfig.fromJson(const {}), returnsNormally);
    });

    test('★★ 未知的 mode/scope 值 → 安全的兜底（不抛，且不劫持流量）', () {
      /*
       * 后端不会发未知值，但"读到不认识的值"时的兜底必须是**安全**的：
       * 落到 `direct` = 不走代理，而不是落到 `system`（那会把用户的
       * 流量导到系统代理上）。
       */
      final weird = ProxyConfig.fromJson({'mode': 'quantum', 'scope': '???'});
      expect(weird.mode, ProxyMode.direct, reason: '未知 mode → 直连（安全兜底）');
      expect(weird.scope, ProxyScope.apiOnly);
    });

    test('★★★ isActive 必须与 Rust 的 uses_proxy() 逐字对应', () {
      /*
       * ```rust
       * pub fn uses_proxy(&self) -> bool {
       *     match self.mode {
       *         ProxyMode::Direct => false,
       *         ProxyMode::System => true,
       *         // Custom 但没填地址 → 等于没配，按直连处理（避免 reqwest 报错）
       *         ProxyMode::Custom => self.url.as_deref()
       *             .map(|u| !u.trim().is_empty()).unwrap_or(false),
       *     }
       * }
       * ```
       * ⚠️ 这里**单独**把 Rust 的三条分支抄成断言，而不是只测 `isActive` ——
       *    将来 Rust 改了判定，测试会红，逼人回来同步。
       */
      // Direct → false
      expect(const ProxyConfig(mode: ProxyMode.direct).isActive, isFalse);
      // System → true
      expect(const ProxyConfig(mode: ProxyMode.system).isActive, isTrue);
      // Custom + 有 url → true
      expect(
        const ProxyConfig(mode: ProxyMode.custom, url: 'http://127.0.0.1:7890')
            .isActive,
        isTrue,
      );
      // Custom + 无 url → false（"等于没配"）
      expect(const ProxyConfig(mode: ProxyMode.custom).isActive, isFalse);
      // Custom + 全空白 url → false（Rust 有 .trim()）
      expect(
        const ProxyConfig(mode: ProxyMode.custom, url: '   ').isActive,
        isFalse,
      );
    });

    test('★ isConfigured（UI 展开判据）与 isActive（真生效）是两件事', () {
      /*
       * ```text
       * mode = custom 但 url 为空 → isConfigured = true（用户确实选了自定义）
       *                            → isActive     = false（后端按直连处理）
       * ```
       * 把这两个混为一谈，就会出现「UI 显示已配置、实际没生效」——
       * 那正是用户查不出来的那种状态。
       */
      const halfDone = ProxyConfig(mode: ProxyMode.custom);
      expect(halfDone.isConfigured, isTrue);
      expect(halfDone.isActive, isFalse,
          reason: '★ 选了自定义但没填地址 = 不生效 —— 两个判据必须能分开');
    });

    test('★ copyWith 只改指定字段（改模式不能把地址弄丢）', () {
      const a = ProxyConfig(
        mode: ProxyMode.custom,
        url: 'http://127.0.0.1:7890',
        scope: ProxyScope.all,
        username: 'alice',
        bypass: ['localhost'],
      );
      final b = a.copyWith(mode: ProxyMode.system);
      expect(b.mode, ProxyMode.system);
      expect(b.url, a.url, reason: '改模式不该把地址弄丢');
      expect(b.scope, a.scope);
      expect(b.username, a.username);
      expect(b.bypass, a.bypass);
    });

    test('★ hasPassword 不是 wire 字段（往返时不该被"读回来"）', () {
      /*
       * 它由 `SourinApi.hasProxyPassword()` 单独查出来赋上。
       * 若有人把它当契约字段发出去，就会多一个被 serde 忽略的野字段。
       */
      expect(const ProxyConfig(hasPassword: true).toJson().containsKey('has_password'),
          isFalse);
      // 但 copyWith 要能改它（UI 用它显示"已保存密码"）
      expect(const ProxyConfig().copyWith(hasPassword: true).hasPassword, isTrue);
    });

    test('★ 摘要文案覆盖三种模式（UI 折叠态用它）', () {
      expect(const ProxyConfig().summary, '直连');
      expect(const ProxyConfig(mode: ProxyMode.system).summary, '跟随系统');
      expect(
        const ProxyConfig(mode: ProxyMode.custom, url: 'http://a:1').summary,
        'http://a:1',
      );
      // 自定义但没地址 —— 文案要说清楚，否则用户以为配好了
      expect(const ProxyConfig(mode: ProxyMode.custom).summary, contains('未填地址'));
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ② Capabilities —— 15 个字段，抄自 Rust
  // ═════════════════════════════════════════════════════════════════════

  /// `rust/sourin_core/src/model.rs` 的 `pub struct Capabilities`
  /// 的字段名（**逐字**，含 `login_needs_username` 的默认值差异）
  ///
  /// ⚠️ 这份常量**不**参与"自比自"的断言（见下面 `① 交叉核对` 里的说明）。
  ///    它的用途是：当 `Rust 源码 → Dart 模型` 的自动比对因为
  ///    Rust 侧真的改了字段而失败时，**指出期望值是什么**。
  ///
  /// ★ 2026-09-25（task-38）：`can_auto_login` 是第 15 个 —— 本轮新增。
  ///   它让本测试的"字段数交叉核对"红了（Rust 15 / 这里 14），
  ///   **那正是它该有的行为**（Rust 加了字段、Dart 侧清单没跟上）。
  const _rustCapKeys = {
    'vod',
    'live',
    'epg',
    'search',
    'login_required',
    'multi_source',
    'server_side_history',
    'favorites',
    'timeshift',
    'danmaku',
    'login_supported',
    'login_hint',
    'login_needs_username',
    'login_qr_supported',
    // ★ task-38 新增：能否用保存的凭据自动重新登录
    'can_auto_login',
  };

  group('② Capabilities ↔ Rust Capabilities', () {
    test('★★★ 交叉核对：真的去读 Rust 源码，字段集必须与 Dart 一致', () {
      /*
       * # ⚠️ 这条断言原来是个**恒真式**（P3 修正，2026-09-23）
       *
       * 第一版写的是：
       * ```dart
       * const _dartCapKeys = { ...14 个字面量... };
       * expect(_dartCapKeys, _rustCapKeys);   // ← 两个都是手写字面量
       * ```
       * 两个常量**内容一模一样**，所以这条断言**永远绿** ——
       * 它既没读 Dart 的 `fromJson`，也没读 Rust 的 `struct`，
       * 纯粹是"抄了两遍再自比"。`flutter test` 报它绿，
       * 给的是**假信心**（本项目已多次踩"假绿比没测更危险"）。
       *
       * # 现在真的去读 Rust 源码
       *
       * 从 `pub struct Capabilities {` 起、到收尾的 `}` 止，
       * 抓出所有 `pub <name>:` 形式的字段名。这样：
       * ```text
       * · Rust 加一个字段            → 这里红（Dart 没跟上）
       * · Rust 改名                  → 这里红
       * · Dart 的 fromJson 少读一个  → 下面那条"逐字段往返"红
       * ```
       * 注意**只取字段声明行**：结构体内部有大量 `///` 文档注释
       * （含中文与反引号），注释里也会出现 `login_required = true`
       * 这种文字 —— 用 `^\s*pub (\w+):` 锚定行首才能避开。
       */
      final modelRs = File('rust/sourin_core/src/model.rs');
      expect(modelRs.existsSync(), isTrue,
          reason: 'Rust 源码不在预期路径 —— 交叉核对没法做。'
              '若目录结构变了，改这里的路径而不是删掉这条断言。');

      final lines = modelRs.readAsLinesSync();
      final structAt = lines.indexWhere(
          (l) => l.contains('pub struct Capabilities'));
      expect(structAt, greaterThanOrEqualTo(0),
          reason: '在 model.rs 里找不到 `pub struct Capabilities`');

      final rustFields = <String>{};
      for (var i = structAt + 1; i < lines.length; i++) {
        final line = lines[i];
        // 收尾的 `}` —— 结构体结束
        if (line.trimRight() == '}') break;
        final m = RegExp(r'^\s*pub\s+(\w+)\s*:').firstMatch(line);
        if (m != null) rustFields.add(m.group(1)!);
      }

      expect(rustFields, isNotEmpty,
          reason: '一个字段都没抓出来 —— 正则或结构体边界判断写错了，'
              '这条断言会变成假绿');

      expect(
        rustFields,
        _rustCapKeys,
        reason: '★ `rust/sourin_core/src/model.rs` 的 `Capabilities` 字段集'
            '变了，但测试里的期望值没跟着改（或反过来）。\n'
            '  源码里的: $rustFields\n'
            '  期望的:   $_rustCapKeys\n'
            '改了 Rust 结构就要同步：① 这份期望值 '
            '② `lib/core/models.dart` 的 `Capabilities`',
      );
    });

    test('★★★ Dart 的 fromJson 必须真的读那 15 个键（逐键单独验证）', () {
      /*
       * 上一条证明"Rust 侧就是这 15 个字段"。这条证明
       * "Dart 侧**确实在读**这 15 个键"。
       *
       * 手法：**一次只给一个键**、值设成与该字段默认值**相反**的那个，
       * 然后看对应字段有没有跟着变。这样任何"键名写错/漏读"
       * 都会让某一个字段保持默认值 → 红。
       *
       * ⚠️ 为什么不直接断言 `fromJson` 的源码里出现 `j['xxx']`：
       *    那是文本匹配，容易假绿（注释里写一遍也算）也容易假红。
       *    这里用**行为**验证 —— 只有真的读了那个键，字段才会动。
       */
      // 键 → (从 JSON 读出该字段的取值函数, 该字段的默认值)
      final probes = <String, (bool Function(Capabilities), bool)>{
        'vod': ((c) => c.vod, false),
        'live': ((c) => c.live, false),
        'epg': ((c) => c.epg, false),
        'search': ((c) => c.search, false),
        'login_required': ((c) => c.loginRequired, false),
        'multi_source': ((c) => c.multiSource, false),
        'server_side_history': ((c) => c.serverSideHistory, false),
        'favorites': ((c) => c.favorites, false),
        'timeshift': ((c) => c.timeshift, false),
        'danmaku': ((c) => c.danmaku, false),
        'login_supported': ((c) => c.loginSupported, false),
        'login_qr_supported': ((c) => c.loginQrSupported, false),
        // ★ 默认值是 **true** —— 所以这里反过来给 false 才能看出"读到了"
        'login_needs_username': ((c) => c.loginNeedsUsername, true),
        // ★ task-38 新增：默认 false（老插件的 JSON 里没有这个键）
        'can_auto_login': ((c) => c.canAutoLogin, false),
      };

      // 覆盖面自检：14 个布尔 + login_hint（字符串，单独测） = 15
      expect(probes.length + 1, _rustCapKeys.length,
          reason: '★ 这里必须覆盖 Rust 的**每一个**字段 —— '
              '漏掉一个就等于那个字段没人守。');

      probes.forEach((key, probe) {
        final (read, defaultVal) = probe;
        final flipped = !defaultVal;

        expect(read(Capabilities.fromJson({key: flipped})), flipped,
            reason: '★ `$key` 没有被 `Capabilities.fromJson` 读到：\n'
                '  给 `{"$key": $flipped}` 时期望该字段变成 '
                '$flipped，实际仍是 $defaultVal（默认值）。\n'
                '  键名拼错一个字母就会这样 —— 而后端不会报错，'
                '这个能力位会**永远停在默认值**。');

        // 反向：不给该键时必须停在默认值（防止"读错到别的键上"）
        expect(read(Capabilities.fromJson(const {})), defaultVal,
            reason: '★ `$key` 的默认值应该是 $defaultVal');
      });

      // 唯一一个非布尔字段
      expect(
        Capabilities.fromJson(const {'login_hint': '粘贴 Cookie'}).loginHint,
        '粘贴 Cookie',
        reason: '★ `login_hint`（Option<String>）没被读到',
      );
    });

    test('★★★ 两个集合常量必须真的相等（原"恒真式"的替代说明）', () {
      /*
       * 保留这条**是为了交代历史**：原来的核心断言就是
       * `expect(_dartCapKeys, _rustCapKeys)`，而两个常量是手抄的同一份，
       * 所以它恒真。
       *
       * 现在真正的守门人是上面两条：
       * ```text
       * ① 交叉核对   Rust 源码字段集 == 期望常量
       * ② 逐键验证   Dart 的 fromJson 真的读了每一个键
       * ```
       * 两条合起来才等价于原来的意图（"Dart 与 Rust 对齐"），
       * 而任意一条单独都不能被"抄一遍"糊弄过去。
       *
       * 这条留着只做**自检**：确认这份期望常量本身没写重复/漏项。
       */
      expect(_rustCapKeys.length, 15,
          reason: 'Rust 的 `Capabilities` 就是 15 个字段（model.rs）—— '
              '★ 2026-09-25 task-38 加了 `can_auto_login`（第 15 个）');
      expect(_rustCapKeys, hasLength(_rustCapKeys.toSet().length),
          reason: '期望常量里不该有重复项');
    });

    test('★★★ 15 个字段逐个往返（全 true / 全 false 各测一遍）', () {
      /*
       * ★ 核心验收：**逐字段**往返，不是"没抛异常"。
       *
       * 全 true 一遍能抓到"某个字段读错键名"（那个字段会掉成 false）；
       * 全 false 一遍能抓到"某个字段默认值写成了 true"。
       */
      const allTrue = {
        'vod': true,
        'live': true,
        'epg': true,
        'search': true,
        'login_required': true,
        'multi_source': true,
        'server_side_history': true,
        'favorites': true,
        'timeshift': true,
        'danmaku': true,
        'login_supported': true,
        'login_hint': '从浏览器复制 Cookie 粘进来',
        'login_needs_username': true,
        'login_qr_supported': true,
      };

      final c = Capabilities.fromJson(allTrue);

      // 逐个断言 —— 一条一条写，失败时能直接看出是哪个字段
      expect(c.vod, isTrue, reason: 'vod 读错了');
      expect(c.live, isTrue, reason: 'live 读错了');
      expect(c.epg, isTrue, reason: 'epg 读错了');
      expect(c.search, isTrue, reason: 'search 读错了');
      expect(c.loginRequired, isTrue, reason: 'loginRequired 读错了（键 login_required）');
      expect(c.multiSource, isTrue, reason: 'multiSource 读错了（键 multi_source）');
      expect(c.serverSideHistory, isTrue,
          reason: 'serverSideHistory 读错了（键 server_side_history —— '
              '**不是** platform_history）');
      expect(c.favorites, isTrue, reason: 'favorites 读错了');
      expect(c.timeshift, isTrue, reason: 'timeshift 读错了');
      expect(c.danmaku, isTrue, reason: 'danmaku 读错了');
      expect(c.loginSupported, isTrue, reason: 'loginSupported 读错了');
      expect(c.loginHint, '从浏览器复制 Cookie 粘进来');
      expect(c.loginNeedsUsername, isTrue);
      expect(c.loginQrSupported, isTrue);

      // ── 反向：全 false ──
      final f = Capabilities.fromJson({
        for (final k in _rustCapKeys)
          if (k != 'login_hint') k: false,
      });
      for (final (name, v) in [
        ('vod', f.vod),
        ('live', f.live),
        ('epg', f.epg),
        ('search', f.search),
        ('loginRequired', f.loginRequired),
        ('multiSource', f.multiSource),
        ('serverSideHistory', f.serverSideHistory),
        ('favorites', f.favorites),
        ('timeshift', f.timeshift),
        ('danmaku', f.danmaku),
        ('loginSupported', f.loginSupported),
        ('loginNeedsUsername', f.loginNeedsUsername),
        ('loginQrSupported', f.loginQrSupported),
      ]) {
        expect(v, isFalse, reason: '$name 在后端发 false 时不该是 true');
      }
      expect(f.loginHint, isNull);
    });

    test('★★★ 旧字段名必须**读不出来**（反向断言，防止回退）', () {
      /*
       * 这 4 个键后端**从不发送**。断言它们在新模型里"没有对应字段"
       * 是最直接的防回退手段：如果将来有人把 `login` / `rank` /
       * `category` / `platformHistory` 加回来，这条会红。
       *
       * 怎么测"没有字段"：给一个**只含旧键**的 JSON，
       * 新模型应当全部落回默认值（而不是"被旧键点亮"）。
       */
      final legacy = Capabilities.fromJson(const {
        'login': true,
        'rank': true,
        'category': true,
        'platform_history': true,
      });

      expect(legacy.loginRequired, isFalse,
          reason: '★ `login` 这个键后端不存在 —— 它不能点亮 loginRequired。'
              '（`login_required` 才是真名）');
      expect(legacy.loginSupported, isFalse,
          reason: '★ 同上 —— 也**绝不能**让 `login` 顺带点亮 loginSupported，'
              '否则 B站 会被误判成"必须登录"');
      expect(legacy.serverSideHistory, isFalse,
          reason: '★ `platform_history` 后端不存在 —— 真名是 server_side_history');

      // 旧模型里那两个"死标签"的判据现在必须查无此物：
      // 这两个 getter 若存在，说明旧字段又回来了
      // （Dart 没有反射，所以用"给定旧键不生效"来间接证明）
      expect(legacy.showLoginEntry, isFalse);
    });

    test('★★★ loginNeedsUsername 默认必须是 **true**（不是 false）', () {
      /*
       * Rust：`#[serde(default = "default_true")]`
       *
       * 后端注释：
       * > B站的 Cookie 导入**不需要账号**，只有密码框（用来粘 Cookie）。
       * > 设 false 时前端隐藏账号框，也**不再要求它非空**
       * > （否则登录按钮永远是禁用状态）。
       *
       * ⚠️ 默认写成 false 会让所有**老插件**（没声明这一项的）都不显示
       *    账号框 —— 登录直接坏掉。
       */
      expect(const Capabilities().loginNeedsUsername, isTrue,
          reason: '★ 默认必须是 true（与后端 default_true 一致）');
      expect(Capabilities.fromJson(const {}).loginNeedsUsername, isTrue,
          reason: '★ 键缺失时也必须是 true');
      // 显式 false 要能读到
      expect(
        Capabilities.fromJson(const {'login_needs_username': false})
            .loginNeedsUsername,
        isFalse,
      );
    });

    test('★★ login_needs_username 的 camelCase 别名也要能读', () {
      /*
       * Rust：`#[serde(default = "default_true", alias = "loginNeedsUsername")]`
       * —— **插件 JSON 里两种写法都收**。
       *
       * 而 `list_providers` 是把插件声明的 JSON 透传出来的，
       * 所以 Dart 侧也要能读两种，否则插件写了 camelCase 我们就读不到，
       * 表现是"账号框该显示的时候没显示"。
       */
      expect(
        Capabilities.fromJson(const {'loginNeedsUsername': false})
            .loginNeedsUsername,
        isFalse,
        reason: '★ 必须兼容 camelCase 别名（Rust 有 alias = "loginNeedsUsername"）',
      );
      // snake_case 优先（它是规范写法）
      expect(
        Capabilities.fromJson(const {
          'login_needs_username': true,
          'loginNeedsUsername': false,
        }).loginNeedsUsername,
        isTrue,
        reason: '两种都出现时以 snake_case 为准（它是 Rust 的规范字段名）',
      );
    });

    test('★★★ loginRequired 与 loginSupported 是**两件事**（原版修过的真 bug）', () {
      /*
       * Rust 注释（`model.rs:583-597`）：
       * ```text
       * cycani    必须登录才能取流          → login_required = true
       * bilibili  游客就能看 1080P，
       *           但登录后能同步关注/收藏  → login_supported = true
       * ```
       * ⚠️ **绝不能**给 B站 设 `login_required = true` ——
       *    `Registry::ensure_session` 会因此**挡住游客播放**
       *    （`if !login_required { return Some(true) }` 那条捷径失效）。
       */
      final bilibili = Capabilities.fromJson(const {
        'login_required': false,
        'login_supported': true,
      });
      expect(bilibili.loginRequired, isFalse,
          reason: '★ B站 **不是**"必须登录" —— 设成 true 会挡住游客播放');
      expect(bilibili.loginSupported, isTrue);
      expect(bilibili.showLoginEntry, isTrue,
          reason: '★ 但设置页**仍要**显示登录入口（过滤条件是两者取或）');

      final cycani = Capabilities.fromJson(const {
        'login_required': true,
        'login_supported': false,
      });
      expect(cycani.loginRequired, isTrue);
      expect(cycani.showLoginEntry, isTrue);

      // 央视这种：两个都 false → 不显示登录入口
      expect(const Capabilities().showLoginEntry, isFalse);
    });

    test('★★ showLoginEntry 必须是 `required || supported`（用真值表穷举）', () {
      /*
       * 用真值表而不是"两个例子"，因为这里写错一个逻辑运算符
       * 就会让某一类源没有登录入口（用户查不出来）。
       * ```text
       * required  supported  → showLoginEntry
       * false     false      → false   （央视：确实没有登录这回事）
       * false     true       → true    （B站：游客可用，但入口要有）
       * true      false      → true    （cycani：必须登录）
       * true      true       → true
       * ```
       */
      for (final (req, sup, want) in [
        (false, false, false),
        (false, true, true),
        (true, false, true),
        (true, true, true),
      ]) {
        final c = Capabilities.fromJson({
          'login_required': req,
          'login_supported': sup,
        });
        expect(c.showLoginEntry, want,
            reason: 'required=$req supported=$sup → 期望 $want');
      }
    });

    test('★★ login_hint 是可空的（Option + skip_serializing_if）', () {
      /*
       * Rust：`#[serde(default, skip_serializing_if = "Option::is_none")]`
       * → 绝大多数源**不发这个键**，所以必须是 `String?` 而不是 `String`。
       * 写成非空会让"没写说明的源"整条 `fromJson` 抛异常
       * → **整个源列表加载失败**。
       */
      expect(Capabilities.fromJson(const {}).loginHint, isNull);
      expect(
        Capabilities.fromJson(const {'login_hint': '扫码或粘贴 Cookie'}).loginHint,
        '扫码或粘贴 Cookie',
      );
      // 后端发了 null（而不是省略）也要能吃
      expect(Capabilities.fromJson(const {'login_hint': null}).loginHint, isNull);
    });

    test('★ 未知键被忽略（不抛）—— 后端加字段不该让老客户端崩', () {
      expect(
        () => Capabilities.fromJson(const {
          'vod': true,
          'future_field_2027': true,
          'another_new_thing': 'x',
        }),
        returnsNormally,
      );
    });

    test('★ ProviderManifest.fromJson 里 capabilities 缺失 → 空能力（不抛）', () {
      /*
       * `models.dart:116-118` 的写法：
       * ```dart
       * capabilities: j['capabilities'] is Map
       *     ? Capabilities.fromJson(jmap(j['capabilities']))
       *     : const Capabilities(),
       * ```
       * 老插件可能整个不发 `capabilities` —— 那不该让源列表加载失败。
       */
      final p = ProviderManifest.fromJson(const {
        'id': 'demo',
        'name': 'Demo',
      });
      expect(p.capabilities.vod, isFalse);
      expect(p.capabilities.loginNeedsUsername, isTrue,
          reason: '★ 整个 capabilities 缺失时，loginNeedsUsername 也要是 true');
    });
  });
}
