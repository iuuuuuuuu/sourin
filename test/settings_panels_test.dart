// ═══════════════════════════════════════════════════════════════════════
//  设置面板（备份 / 代理 / 登录）—— 接线断言
// ═══════════════════════════════════════════════════════════════════════
//
// # 这些断言守什么
//
// 三个面板是**后端已有能力、我们没做界面**的补齐（26 个零调用 API 里的
// 一批）。所以断言的重点是「**接线正确**」：
// ```text
// ① 面板真的调了那些 API（不是画了个静态界面）
// ② 关键约束没被违反（密码不进配置对象 / 导入要两步确认 / 模型对齐后端）
// ③ 项目铁律（不 import flutter/material、不加依赖）
// ```
//
// ⚠️ 功能性验证（API 真的通、文件真的写出来）由
//    `lib/backup_panels_probe.dart` 做 —— 那是**真机实测**，
//    单测做不到（需要真 FFI + 真实数据目录）。
//    这个文件只做**静态接线断言**。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 去掉注释行 —— 静态断言里做文本匹配**必须先剥注释**
///
/// 这个坑在本项目里踩过**至少四次**：注释里提到某个标识符，
/// 纯文本匹配就把它当成真实调用，测试假失败。
String _code(String src) => src
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
    })
    .join('\n');

/// 剥掉注释（行注释 + 块注释）—— **带状态机**，不是逐行判断
///
/// # 为什么不能只用 [_code]（逐行判断）
///
/// `_code` 按"行首是不是 `//` / `*` / `/*`"过滤，处理不了：
/// ```text
/// ① 行尾注释   `final x = 1; // 提到 getSaveLocation`  ← 行首不是注释
/// ② 单行块注释 `/* getSaveLocation */ final y = 2;`     ← 同上
/// ```
/// 这两种都会让**注释里的词**被当成真实代码 → 断言假绿。
///
/// 所以要真的走一遍字符（与 `test/episode_strip_test.dart:82`
/// 的 `stripComments` 同一个 oracle）：
/// ```text
/// 'http://x'      字符串里的 `//` **不是**注释
/// "a /* b"        字符串里的 `/*` 不是注释
/// /*  //  */      块注释里的 `//` 不是行注释
/// ```
String _stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  var inLine = false;
  var inBlock = false;
  String? quote;

  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';

    // 块注释：只找结束的 `*/`
    if (inBlock) {
      if (c == '*' && next == '/') {
        inBlock = false;
        i += 2;
        continue;
      }
      if (c == '\n') out.write(c);
      i++;
      continue;
    }

    // 行注释：到行尾为止
    if (inLine) {
      if (c == '\n') {
        inLine = false;
        out.write(c);
      }
      i++;
      continue;
    }

    // 字符串里：原样保留（转义要连下一个字符一起跳过）
    if (quote != null) {
      out.write(c);
      if (c == r'\' && next.isNotEmpty) {
        out.write(next);
        i += 2;
        continue;
      }
      if (c == quote) quote = null;
      i++;
      continue;
    }

    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && next == '/') {
      inLine = true;
      i += 2;
      continue;
    }
    if (c == '/' && next == '*') {
      inBlock = true;
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 断言 [a] 在 [b] 之前出现（**顺序契约**）
///
/// # 为什么需要它（P3/P2 复查发现的"锁死实现"问题）
///
/// 这个文件里有一批断言长这样：
/// ```dart
/// expect(code.contains('await _save(notify: false);'), isTrue)
/// ```
/// 它断言的是**某一行源码的逐字文本** —— 也就是**实现**，不是契约。
/// 后果：
/// ```text
/// ① 有人把 `_save(notify: false)` 重命名成 `_persist()` → 测试红，
///    但功能完全没变（**假红**）
/// ② 有人把 `_save` 移到 `testProxy` **之后** → 文本还在，
///    断言照样绿 —— 而"测试的是旧配置"这个 bug 真的回来了（**假绿**）
/// ```
/// ②才是危险的：它看起来在守契约，实际守的是"这串字符还在不在"。
///
/// 顺序类契约（"先保存再测试"）必须断言**位置关系**，不是存在性。
bool _before(String src, String a, String b) {
  final ia = src.indexOf(a);
  final ib = src.indexOf(b);
  return ia >= 0 && ib >= 0 && ia < ib;
}

void main() {
  group('备份面板', () {
    late String src;
    late String code;

    setUpAll(() {
      src = File('lib/ui/widgets/backup_panel.dart').readAsStringSync();
      code = _code(src);
    });

    test('★ 真的调了那 4 个备份 API（不是静态界面）', () {
      for (final m in [
        'SourinApi.backupPreview()',
        'SourinApi.backupDefaultName()',
        'SourinApi.backupExport(',
        'SourinApi.backupInspect(',
        'SourinApi.backupImport(',
      ]) {
        expect(code.contains(m), isTrue, reason: '必须调用 `$m`');
      }
    });

    test('★★ 导入必须**两步确认**（原版硬要求）', () {
      /*
       * 原版草稿原话：
       * > 导入的本质是"用文件覆盖本机数据"。不能默默覆盖 ——
       * > 用户可能只是想把另一台机器的收藏合过来，结果本机进度全没了。
       *
       * 所以：先 inspect（`_doPick`）→ 用户看到内容 → 再 import（`_doImport`）。
       * **不能**有一个"点了直接导入"的路径。
       *
       * # ⚠️ 复查：这条原来锁的是**实现细节**（P2/P3 修正）
       *
       * 原断言逐字匹配私有方法名与一行赋值：
       * ```dart
       * code.contains('Future<void> _doPick()')
       * code.contains("_picked = (path: path, info: info)")
       * ```
       * 前者把**方法改名**变成测试失败（假红）；
       * 后者把"用什么语法存"当成契约（换个写法就红，但行为没变）。
       *
       * 现在按**行为契约**断言（而且更严）：
       * ```text
       * ① 存在"读内容"与"确认导入"**两个**独立入口
       * ② 两者都真的调了对应的 API（inspect / import）
       * ③ **顺序**：inspect 出现在 import 之前
       * ④ 确认区真的**渲染**（不是只把数据存起来）——
       *    用 _before 断言"存 → 渲染"这条路真的通了
       * ```
       */
      expect(code.contains('SourinApi.backupInspect('), isTrue,
          reason: '必须有"读取内容"这一步（只 inspect，不导入）');
      expect(code.contains('SourinApi.backupImport('), isTrue,
          reason: '必须有单独的"确认导入"');

      // ★ 顺序契约：先把内容读出来（inspect），才谈得上确认导入
      expect(
        _before(code, 'SourinApi.backupInspect(', 'SourinApi.backupImport('),
        isTrue,
        reason: '★ inspect 必须在 import **之前** —— 顺序反了就等于'
            '"没看内容就导入"，那正是原版明令禁止的',
      );

      /*
       * 确认区必须真的渲染出来 —— 只存不显示等于没有确认步骤。
       * 断言"渲染调用发生在赋值之后"（而不是逐字匹配那一行赋值语法）。
       */
      expect(
        code.contains('_confirmBox('),
        isTrue,
        reason: '★ 必须有确认区渲染调用 —— 只存不显示等于没有确认步骤',
      );
      expect(
        _before(code, '_picked = ', '_confirmBox(_picked'),
        isTrue,
        reason: '★ 先存进 `_picked`，再把它渲染出来 —— 顺序错了确认区就是空的',
      );
    });

    test('★ 导入结果要显示"被跳过"的条目', () {
      /*
       * 原版语义：`skipped` 有内容就说明**部分数据没导入**。
       * UI 应该把它显示给用户，而不是只报"导入成功"。
       */
      expect(code.contains('s.skipped'), isTrue,
          reason: '★ 必须展示 skipped —— 不显示的化用户以为"都导入了"');
    });

    test('★ 说明文案要讲清"合并不覆盖"', () {
      expect(
        src.contains('不会删除本机任何数据'),
        isTrue,
        reason: '用户看到"导入"会本能担心覆盖，必须说清楚',
      );
    });

    test('★ 自包含（不依赖宿主 State）', () {
      /*
       * 任务要求：宿主只要 `_Block(title:'备份', children:[BackupPanel()])`
       * 就能用 —— 所以构造必须是 `const BackupPanel({super.key})`。
       */
      expect(
        RegExp(r'const BackupPanel\(\{super\.key\}\)').hasMatch(src),
        isTrue,
        reason: '必须是无参自包含 widget',
      );
    });
  });

  group('代理面板', () {
    late String src;
    late String code;

    setUpAll(() {
      src = File('lib/ui/widgets/proxy_panel.dart').readAsStringSync();
      code = _code(src);
    });

    test('★★★ 必须走 SourinApi 的 ProxyConfig（模型已与 Rust 对齐）', () {
      /*
       * # 这条断言原本是**反的**，任务 P2 修复后翻正
       *
       * 当初审计发现的是一个**真 bug**：
       * ```text
       * models.dart  ProxyConfig{enabled, url, username}   ← 错
       * Rust         ProxyConfig{mode, url, bypass, scope, username}
       *              （每个字段 #[serde(default)]，无 deny_unknown_fields）
       * ```
       * → `enabled` 被静默忽略 → `mode` 取默认 `Direct`
       * → `uses_proxy()` 返回 false → **代理永远不生效，且不报错**
       *
       * 实测证据（`lib/backup_panels_probe.dart` 当时跑出来的）：
       * ```text
       * 绕行方案:  {mode: custom, url: http://127.0.0.1:7890, scope: api_only}  ✓
       * SourinApi: {mode: direct, url: http://127.0.0.1:7891}  ← mode 没落
       * ```
       *
       * 当时的权宜之计是**在 `proxy_panel.dart` 里定义局部模型 `ProxyCfg`
       * 并直接调 FFI 绕开**，于是这条断言被写成了"**必须绕开**"。
       *
       * # 为什么那是个坏断言（值得记）
       *
       * ```text
       * 坏断言：必须绕开 SourinApi 的 ProxyConfig   ← 锁死了**实现手段**
       * 好断言：ProxyConfig 的字段必须与 Rust 一致  ← 锁死了**契约**
       * ```
       * 前者把"绕行"这个临时手段变成了**必须长期存在**的要求 ——
       * 于是根本修复（改 `models.dart`）一落地，测试反而全红。
       * **测试要断言正确的契约，不是某个特定实现。**
       *
       * # 现在（P2 修复后）
       *
       * `models.dart` 的 `ProxyConfig` 已按 `proxy.rs:90-107` 修好，
       * 所以面板**回到正常路径**：全部走 `SourinApi`。
       * 契约本身（字段集 / wire 值）由 `test/models_contract_test.dart`
       * 逐字段锁死 —— 那里才是这类断言该待的地方。
       */
      expect(code.contains('SourinApi.setProxyConfig'), isTrue,
          reason: '★ 必须走 SourinApi.setProxyConfig（模型已与 Rust 对齐）');
      expect(code.contains('SourinApi.clearProxyConfig'), isTrue,
          reason: '清除代理也走 SourinApi');
      expect(code.contains('SourinApi.testProxy'), isTrue,
          reason: '测试连通性走 SourinApi.testProxy');
      // 绕行方案必须**彻底消失**（留一半就是"两份契约"）
      expect(code.contains('ProxyCfg'), isFalse,
          reason: '★ 局部模型 `ProxyCfg` 必须删干净 —— '
              '留着一个"正确但与 models.dart 并行的"模型，'
              '下次字段变更就会改一处漏一处（**这正是当初那个 bug 的形态**）');
      expect(code.contains('static Future<dynamic> _call'),
          isFalse,
          reason: '★ 裸 FFI 包装 `_call` 也要删 —— 它当初存在的唯一理由是绕开'
              '字段错位的模型；现在它只会让命令名/参数名分散在两处');
      expect(code.contains('SourinCore.callAsync'), isFalse,
          reason: '★ 面板层不该再直接碰 FFI —— 统一走 SourinApi');
    });

    test('★★ wire 值必须与 Rust 严格一致（在模型层断言，不在面板层）', () {
      /*
       * 旧版这条断言是"面板文件里必须出现 `'direct'` 这些字面量" ——
       * 那是在**错误的层**断言契约：
       * ```text
       * 面板层  只负责"用哪个模式"，不该知道 wire 值长什么样
       * 模型层  才是 wire 值的唯一来源
       * ```
       * 面板层断言字面量，等于要求 wire 值**不能收敛到模型里** ——
       * 又是一个"锁死实现"的坏断言。
       *
       * 现在改成断言**接线正确** + 指向模型层测试。
       * wire 值的逐条断言在 `test/models_contract_test.dart`：
       * ```text
       * ProxyMode  → 'direct' | 'system' | 'custom'
       * ProxyScope → 'api_only' | 'all'
       * ```
       */
      // 面板必须真的把三种模式都用上（不是画了三个 pill 但只认一个）
      for (final m in ['ProxyMode.values', 'ProxyMode.custom',
        'ProxyMode.system', 'ProxyMode.direct']) {
        expect(code.contains(m), isTrue, reason: '面板必须处理 `$m`');
      }
      expect(code.contains('ProxyScope.values'), isTrue,
          reason: '作用范围的两个选项都要渲染');
      // 面板**不该**自己写 wire 值（那是模型的职责）
      expect(code.contains("'api_only'"), isFalse,
          reason: '★ 面板层不该出现 wire 字面量 —— 它应当用 `ProxyScope.all` / '
              '`ProxyScope.apiOnly`，把 wire 值的唯一来源留在 models.dart');
    });

    test('★★ 密码必须**单独走钥匙串**，不进配置对象', () {
      /*
       * Rust 硬约定（`proxy.rs:106`）：
       * > ⚠️ 密码绝不在此结构里 —— 只存钥匙串，见 set_password / take_password
       *
       * 原版也照这个做：「密码单独走钥匙串，不进配置对象，**也就不进备份**」。
       *
       * ⚠️ 这条断言原来查的是**面板文件里**的字面量 `'set_proxy_password'`
       *    —— 那是绕行时代的写法。现在面板走 `SourinApi`，所以断言改成：
       * ```text
       * ① 面板调的是 SourinApi.setProxyPassword（独立通道 → 系统钥匙串）
       * ② "是否已设密码"经 SourinApi 的代理读取路径拿到（不是从配置对象里读）
       * ③ 面板层不自己拼含 password 的 payload
       * ```
       * 第 ② 条为什么不是直接断言 `SourinApi.hasProxyPassword`：
       * ```text
       * 面板需要"配置 + 是否已设密码"两样东西 ——
       * 分两次调 = 两次 FFI 往返（面板每次展开都要跑）
       * SourinApi.proxyConfigWithPassword 内部并行拿两样，一次返回
       * ```
       * 所以断言的是**这个聚合入口**。它内部确实调 `hasProxyPassword`，
       * 那条接线在 `sourin_api.dart` 里（本次不改那个文件的中段）。
       */
      expect(code.contains('SourinApi.setProxyPassword'), isTrue,
          reason: '密码要走单独的 setProxyPassword（→ 系统钥匙串）');
      expect(code.contains('SourinApi.proxyConfigWithPassword'), isTrue,
          reason: '★ "是否已设密码"必须经 SourinApi 的代理读取路径拿到'
              '（内部走 hasProxyPassword —— 密码本身返回不了）');
      /*
       * 面板的 payload 里**绝不能**有 password ——
       * 面板自己不构造 payload 了，但它**持有**密码输入框，
       * 所以这里查的是"密码只被交给 setProxyPassword"。
       */
      expect(
        RegExp(r"'password'\s*:").hasMatch(code),
        isFalse,
        reason: '★ 面板层不得自己拼含 password 的 payload —— '
            '密码只能经 SourinApi.setProxyPassword 进钥匙串',
      );
      // 模型层的那一半契约（toJson 不含 password）见 models_contract_test.dart
    });

    test('★ 密码不回显（留空 = 不修改）', () {
      expect(
        src.contains('已保存（留空不修改）'),
        isTrue,
        reason: '原版硬约定：只显示"已保存密码"，留空表示不修改',
      );
    });

    test('★★ 测试连接前要先保存（否则测的是旧配置）', () {
      /*
       * 用户刚填完地址就点"测试连接" —— 不先保存的话测的是旧配置，
       * 结果毫无意义（而且会让人以为"我填的地址不通"）。
       *
       * # ⚠️ 复查：原断言是**假绿风险**（P2/P3 修正）
       *
       * 原文：
       * ```dart
       * expect(code.contains('await _save(notify: false);'), isTrue)
       * ```
       * 它只断言"这串字符还在文件里"。而 `_save(notify: false)` 在
       * **别处**也可能出现 —— 更糟的是：
       * ```text
       * 有人把 `_save(...)` 移到 `SourinApi.testProxy(...)` **之后**
       *   → 文本还在 → 断言**照样绿**
       *   → 而"测的是旧配置"这个 bug 真的回来了
       * ```
       * 这正是"看起来在守契约、实际只守了字符串存在性"。
       *
       * 现在断言**顺序**：保存必须发生在测试**之前**。
       */
      expect(
        _before(code, 'await _save(', 'SourinApi.testProxy('),
        isTrue,
        reason: '★ `_save` 必须出现在 `testProxy` **之前** —— '
            '只断言"那行代码存在"抓不到顺序被调换（用户刚填的地址没保存就测）',
      );
      // 而且 `_test` 内部确实两条都在（不是分散在两个方法里凑出来的顺序）
      final testBody = code.substring(
        code.indexOf('Future<void> _test()'),
        code.indexOf('Future<void> _test()') + 700,
      );
      expect(testBody.contains('_save('), isTrue,
          reason: '★ `_test` 内部必须先保存');
      expect(testBody.contains('SourinApi.testProxy('), isTrue,
          reason: '★ `_test` 内部再测连通性');
    });

    test('★ 折叠态只显示摘要、展开态显示"代理"标签', () {
      /*
       * 原版注释（`ProviderProxy.vue`）：
       * > 折叠态**只显示摘要**（"直连" / "系统代理" / "自定义"），
       * > 不显示「代理」二字与箭头 —— 它们与标题同一行，多两个字就把标题挤窄了
       * > ⚠️ 展开态**必须**把「代理」标签显示回来
       *
       * # ⚠️ 复查：原断言锁的是**三元表达式的写法**（P2/P3 修正）
       *
       * 原文逐字匹配 `_open ? '代理' : cfg.summary` ——
       * 有人把它重构成
       * ```dart
       * Text(_open ? '代理' : cfg.summary)     // 一样
       * final label = _open ? '代理' : cfg.summary;  Text(label)   // 也红
       * ```
       * 第二种行为完全相同却会失败。契约是**"展开显示'代理'、折叠显示摘要"**，
       * 不是"必须写成一行三元"。
       */
      expect(code.contains("'代理'"), isTrue,
          reason: '★ 展开态必须显示「代理」标签');
      expect(code.contains('cfg.summary'), isTrue,
          reason: '★ 折叠态必须显示摘要（cfg.summary）');
      // 两者必须在**同一个文案位置**做互斥选择 —— 即存在 _open 参与的切换
      expect(
        RegExp(r'_open\s*\?').hasMatch(code),
        isTrue,
        reason: '★ 摘要与「代理」必须是**互斥**的两态（有 `_open ?` 切换），'
            '不能两个都显示',
      );
    });

    test('★ 已配置的源自动展开 + defaultOpen（两件事取或）', () {
      /*
       * ⚠️ 复查（P2/P3）：原来的两条断言锁的是**逐字写法**
       * ```dart
       * code.contains('if (cfg.isConfigured) _open = true;')
       * src.contains('this.defaultOpen = false')
       * ```
       * 前者加个大括号 `if (cfg.isConfigured) { _open = true; }` 就红；
       * 后者把参数默认值换个次序也红 —— 都跟行为无关。
       *
       * 契约是"**已配置的源自动展开**"与"**有 defaultOpen 这个入口**"，
       * 所以改成断言这两件行为 + 入口存在。
       */
      expect(
        RegExp(r'if\s*\(\s*cfg\.isConfigured\s*\)').hasMatch(code),
        isTrue,
        reason: '★ 用户配过的说明他在意，不该每次都要再点一次（自动展开）',
      );
      expect(
        _before(code, 'if (cfg.isConfigured)', '_loading = false'),
        isTrue,
        reason: '★ 自动展开必须在 `_load` 拿到配置**之后** —— '
            '在拉到数据前判断 `isConfigured` 永远是 false（_cfg 还是 null）',
      );
      expect(
        RegExp(r'this\.defaultOpen\s*=\s*false').hasMatch(src),
        isTrue,
        reason: '★ `defaultOpen` 要有（且默认 false）—— 原版注释说这个 prop'
            '"在注释里被提到过但一直没实现"',
      );
    });

    test('★ 自包含', () {
      expect(
        RegExp(r'const ProxyPanel\(\{').hasMatch(src),
        isTrue,
        reason: '宿主只需传 providerId/providerName 就能用',
      );
    });
  });

  group('登录面板', () {
    late String src;
    late String code;

    setUpAll(() {
      src = File('lib/ui/widgets/provider_login_panel.dart').readAsStringSync();
      code = _code(src);
    });

    test('★ 真的调了登录相关 API（走 SourinApi，不再裸调 FFI）', () {
      /*
       * ⚠️ 这条原来断言的是**命令名字符串**（`'provider_login'` 等）——
       *    那是面板直接调 FFI 时代的写法。
       *    现在面板走 `SourinApi`（命令名收敛到 `sourin_api.dart`），
       *    所以断言改成**方法名** —— 断言真实的调用形态，不迁就旧写法。
       */
      for (final m in [
        'SourinApi.listProviders()',
        'SourinApi.providerSession(',
        'SourinApi.providerSessionStateWire(',
        'SourinApi.providerLogin(',
        'SourinApi.providerLogout(',
        'SourinApi.forgetProviderCredentials(',
      ]) {
        expect(code.contains(m), isTrue, reason: '必须调用 `$m`');
      }
      // 面板层不该再直接碰 FFI
      expect(code.contains('SourinCore.callAsync'), isFalse,
          reason: '★ 统一走 SourinApi —— 命令名/参数名不该分散在 UI 层');
    });

    test('★★★ 必须区分「游客可用」与「无需登录」（原版修过的真 bug）', () {
      /*
       * 原版注释：
       * > ★ 区分「压根不需要登录」与「游客可用、但登录是可选增强」
       * > 两者在后端都是 `not_required`，但界面上该说的话完全不同：
       * > · 央视 → 「无需登录」（确实没有登录这回事）
       * > · B站  → 「游客可用」（能登录，只是不登也能用）
       * > ⚠️ 给 B站 显示「无需登录」是**错的** —— 它旁边就有个「登录」按钮，
       * >    用户会以为是 bug。
       */
      expect(src.contains('游客可用'), isTrue, reason: '缺「游客可用」文案');
      expect(src.contains('无需登录'), isTrue, reason: '缺「无需登录」文案');
      /*
       * ★ 判据必须是**类型化字段** `loginSupported`（= `login_supported`）。
       *
       * ⚠️ 旧写法是 `_caps.supported` —— 那来自本文件里一个**局部模型**
       *    `LoginCaps.fromRaw()`（因为当时 `models.dart` 的 `Capabilities`
       *    少了这些字段）。任务 P2 把 `Capabilities` 补齐后，
       *    局部模型已删除，判据换成模型字段。
       *    「一份契约只在一个地方」—— 这正是当初那个 bug 的教训。
       */
      expect(code.contains('_caps.loginSupported'), isTrue,
          reason: '★ 判据必须是 `loginSupported`（= Rust `login_supported`）');
      // 局部模型必须删干净
      expect(code.contains('LoginCaps'), isFalse,
          reason: '★ `LoginCaps.fromRaw` 必须删 —— 留着就是"第二份契约"，'
              '默认值（尤其 loginNeedsUsername）写错一处两处就不一致');
      expect(RegExp(r"caps\['").hasMatch(code), isFalse,
          reason: '★ 不得再从原始 JSON 里手抠 capabilities 字段 —— '
              '`Capabilities.fromJson` 才是唯一来源');
    });

    test('★★ 登录入口的过滤条件是 `loginRequired || loginSupported`', () {
      /*
       * 后端注释：
       * > 设置页的登录入口过滤条件是 `login_required || login_supported`，
       * > 而会话校验只看 `login_required`。
       *
       * ⚠️ 用错会让 B站 这种"游客可用"的源**没有登录入口**。
       *
       * ⚠️ 旧断言查的是本文件里的 `required || supported` 字面量 ——
       *    那是局部模型时代的写法。现在这个判据收进了模型：
       *    `Capabilities.showLoginEntry`（**唯一来源**）。
       *    真值表穷举在 `test/models_contract_test.dart`。
       */
      expect(code.contains('_caps.showLoginEntry'), isTrue,
          reason: '★ 必须用模型上的 `showLoginEntry`（= required || supported）');
      // 不需要登录的源不渲染（不是显示一个用不了的按钮）
      expect(code.contains('if (!_loading && !_caps.showLoginEntry)'), isTrue,
          reason: '不需要登录的源应 `SizedBox.shrink()`');
    });

    test('★★ capabilities 必须用**类型化字段**读（模型已补齐 14 个字段）', () {
      /*
       * 这条原来是"必须从原始 JSON 读 capabilities" ——
       * 理由是当时 `Capabilities` 只有一个 `login` 布尔，
       * 缺 `login_required` / `login_supported` / `login_needs_username`
       * / `login_hint` / `login_qr_supported`。
       *
       * 任务 P2 把 `Capabilities` 按 `model.rs:560-625` 补齐成 14 个字段，
       * 所以"从原始 JSON 手抠"这个缓解措施**必须撤除**：
       * ```text
       * fromRaw  = 第二份契约（字段名 + 默认值各写一遍）
       * 类型化   = 唯一来源（默认值只在 Capabilities.fromJson 里写一次）
       * ```
       * 断言改成：面板用的是模型的类型化字段。
       */
      expect(code.contains('_caps.loginRequired'), isTrue,
          reason: '★ 必须用类型化字段 `loginRequired`');
      expect(code.contains('_caps.loginSupported'), isTrue,
          reason: '★ 必须用类型化字段 `loginSupported`');
      expect(code.contains('_caps.loginHint'), isTrue,
          reason: '★ 必须用类型化字段 `loginHint`');
      expect(code.contains('p.capabilities'), isTrue,
          reason: '★ 从 `SourinApi.listProviders()` 的 `ProviderManifest.capabilities` 取');
    });

    test('★★ `loginNeedsUsername` 默认必须是 **true**', () {
      /*
       * 后端：`#[serde(default = "default_true")]`
       * 注释：
       * > 设 false 时前端隐藏账号框，也**不再要求它非空**
       * > （否则登录按钮永远是禁用状态）。
       *
       * ⚠️ 默认写成 false 会让所有老插件**都不显示账号框** —— 登录直接坏掉。
       *
       * ⚠️ 默认值现在**只在 `Capabilities.fromJson` 里写一次**
       *    （断言在 `test/models_contract_test.dart`）。
       *    这里断言的是**消费侧**：面板用类型化字段，且不拦着不让登录。
       */
      expect(
        code.contains('if (_caps.loginNeedsUsername && _userCtrl.text.trim().isEmpty)'),
        isTrue,
        reason: '★ 账号非空校验必须带 `_caps.loginNeedsUsername` 前置条件 —— '
            'B站的 Cookie 导入不需要账号，硬要求非空会让登录按钮永远禁用',
      );
      // 账号框按它显示
      expect(code.contains('if (_caps.loginNeedsUsername)'), isTrue,
          reason: '★ 账号框要按 loginNeedsUsername 显示/隐藏');
    });

    test('★★ 会话状态必须按**字符串**读（后端返回的是枚举字符串，不是对象）', () {
      /*
       * ★ 这是 P2 顺手发现的**第 4 个静默 bug**。
       *
       * 后端 `provider_session_state` 的真实签名是：
       * ```rust
       * Result<Option<SessionState>, String>          // commands_backup.rs:81-86
       * #[serde(rename_all = "snake_case")]
       * pub enum SessionState { NotRequired, Active, Expiring, Expired }
       * ```
       * 也就是**一个字符串**（`"active"` / `"not_required"` / …）或 null，
       * **不是对象**。
       *
       * 而 `SourinApi.providerSessionState` 的签名写成了
       * `Future<Map<String, dynamic>?>` → `jmapOrNull("active")` 抛
       * 「期望对象，实际收到 String」→ 被 `catchError` 吞掉 → 拿到 null
       * → `_state` 永远 null → **UI 永远显示"无需登录"**，
       * 连 `expired`（登录已失效）都不提示。
       * 而"清除本机凭据"按钮**只在 `expired` 时显示**，所以它也是死的。
       *
       * → 面板必须用 `providerSessionStateWire`（返回 `String?`）。
       */
      expect(code.contains('SourinApi.providerSessionStateWire('), isTrue,
          reason: '★ 必须用返回 `String?` 的 `providerSessionStateWire` —— '
              '后端返回的是枚举字符串，不是对象');
      expect(code.contains('SourinApi.providerSessionState('), isFalse,
          reason: '★ 不得用签名写错的那个（`Map?`）—— 它会静默抛异常被吞掉，'
              '导致会话状态永远是 null');
      expect(code.contains('st is String'), isTrue,
          reason: '★ 必须按字符串判定（`is String`），不能按 `is Map`');
    });


    test('★★ scan/QR 登录：**已补齐**（命令层 + Dart 层 + UI 页签）', () {
      /*
       * 本文件早期版本这条断言的是「**不做**扫码页签」，依据是当时 spike 的
       * Rust 侧没有 provider_qr_login_start / provider_qr_login_poll。
       *
       * ⚠️ 那个审计结论**有一半是错的**：原版 src-tauri/src/lib.rs:4647-4648
       *    **注册了**这两个命令，原版设置页的扫码页签一直能用。
       *    （当时只 grep 了 spike 自己的 generate_handler!，没查原版。）
       *
       * 2026-10-05 补齐后，断言反过来守「这个能力真的接线了」：
       * Rust 命令层  commands_backup.rs:154/:176 + ffi.rs:1498/:1507
       * Dart 包装层  sourin_api.dart providerQrLoginStart / providerQrLoginPoll
       * UI 页签      provider_login_panel.dart（只在 loginQrSupported 时渲染）
       * 端到端真请求证据：rust/sourin_core/tests/t525_qr_login.rs（4 passed，
       * start 真的拿到 key + 145 字符 url + 22972 字符 svg，poll 立即 pending）。
       */
      for (final m in [
        'SourinApi.providerQrLoginStart(',
        'SourinApi.providerQrLoginPoll(',
      ]) {
        expect(code.contains(m), isTrue, reason: '必须调用 `$m`');
      }
      // 页签行只在插件声明支持扫码时渲染 —— 不支持时多一个页签纯属噪音
      expect(code.contains('_caps.loginQrSupported'), isTrue,
          reason: '★ 页签行必须 gate 在 `loginQrSupported` 上');
      // 文案必须与原版一致
      expect(code.contains('扫码登录'), isTrue, reason: '缺「扫码登录」页签文案');
      expect(code.contains('其它方式'), isTrue, reason: '缺「其它方式」页签文案');
      // ★ 轮询定时器必须持有句柄并被 cancel
      //   （原版注释：不定时清掉的话，弹窗关了还在打 B站 接口 = 风控风险）
      expect(code.contains('_qrTimer?.cancel()'), isTrue,
          reason: '★ Timer 必须持有句柄并 cancel');
      expect(code.contains('Timer.periodic(const Duration(seconds: 2)'), isTrue,
          reason: '★ 轮询 2 秒一次（原版注释：B站 poll 返回 ttl=1，'
              '二维码约 180 秒有效；1 秒太密有风控风险）');
      // ★★★ 原版 Owner 实测报的真 bug：「我刚扫了 然后就提示网络异常」
      //   ⇒ 单次网络失败只能改文案，**不能停轮询**
      expect(code.contains('网络异常，重试中…'), isTrue,
          reason: '★ 单次网络失败必须只改文案、继续轮询');
      // 旧结论必须删干净（注释里也不能留「完全不可用」的假结论）
      expect(src.contains('扫码登录完全不可用'), isFalse,
          reason: '★ 那个结论是错的 —— 原版 lib.rs:4647-4648 就注册了这两个命令');
    });

    test('★ 不测 logout 是**有意的**（钥匙串不受数据目录隔离）', () {
      /*
       * 探针里跳过了 logout/forget —— 那会清**系统钥匙串**，
       * 而钥匙串是全局的，不受 `DATA_DIR_OVERRIDE` 隔离。
       */
      final probe = File('lib/backup_panels_probe.dart').readAsStringSync();
      expect(
        probe.contains('跳过 logout'),
        isTrue,
        reason: '★ 必须写明为什么跳过 —— 否则后人会以为漏测了',
      );
    });

    test('★ 自包含', () {
      expect(
        RegExp(r'const ProviderLoginPanel\(\{').hasMatch(src),
        isTrue,
      );
    });
  });

  group('项目铁律', () {
    test('★★ 三个面板都不得 import flutter/material.dart', () {
      /*
       * Flutter 3.47 把 Material 拆成 `material_ui` 包。
       * 混用会造成"两套 Theme 串台" —— 本项目曾因此让设置页标题
       * 对比度只剩 **1.16:1**（几乎看不见）。
       */
      for (final f in [
        'lib/ui/widgets/backup_panel.dart',
        'lib/ui/widgets/proxy_panel.dart',
        'lib/ui/widgets/provider_login_panel.dart',
      ]) {
        final s = File(f).readAsStringSync();
        expect(
          s.contains("import 'package:flutter/material.dart'"),
          isFalse,
          reason: '★ `$f` 不得 import flutter/material（用 material_ui）',
        );
      }
    });

    test('★★ backup_panel 必须用 file_selector 弹**系统对话框**（不得回退到手填路径）', () {
      /*
       * # 这条断言原来守的是**反的**（已翻转）
       *
       * 原断言：「三个面板都**不得** import file_selector」，
       * 理由写的是「任务明确要求禁止加新依赖」。
       *
       * ★ 那条规则**已被 Owner 明确撤销**：
       * > 项目允许加新依赖,但是必须有用
       * 而且 `file_selector` 本来就**已在** `pubspec.yaml:166`
       * （`file_selector: ^1.0.3`）—— 根本不算"新"依赖。
       * 同一个仓库的 `lib/ui/widgets/player_settings_sheet.dart:63`
       * 早就在用它了 → 所谓"禁止"从来只在写这条断言的 3 个文件里成立。
       *
       * # 现在守的是**正向契约**
       *
       * Owner 原话：
       * > 导出导入,都通过文件选择器导出 导入,
       * > 而不是默认规定好目录导出
       *
       * 即：备份面板**必须**弹系统文件对话框，
       * 与原版 `src/components/BackupPanel.vue` 一致：
       * ```ts
       * const { save } = await import("@tauri-apps/plugin-dialog");  // 导出
       * const { open } = await import("@tauri-apps/plugin-dialog");  // 导入
       * ```
       *
       * ★ 防的回归：将来有人图省事改回「让用户自己填/粘贴路径」——
       *   那是被 Owner 明确否掉的交互（用户要会复制路径才能用）。
       *
       * ⚠️ `proxy_panel.dart` / `provider_login_panel.dart`
       *    **已从断言里去掉** —— 它们与文件对话框无关，
       *    原来被列进来只是原作者"约束自己"的副作用。
       */
      final raw = File('lib/ui/widgets/backup_panel.dart').readAsStringSync();
      final s = _stripComments(raw);

      expect(
        s.contains("import 'package:file_selector"),
        isTrue,
        reason: '★ 必须 import file_selector —— 否则弹不出系统对话框',
      );
      expect(
        s.contains('getSaveLocation'),
        isTrue,
        reason: '★ 导出必须弹**系统保存**对话框（原版 save()）',
      );
      expect(
        s.contains('openFile'),
        isTrue,
        reason: '★ 导入必须弹**系统打开**对话框（原版 open()）',
      );

      /*
       * ★ 反向断言：**不得**再有「让用户手填路径」的输入框。
       *
       * 用剥注释后的代码匹配 —— 注释里出现 `TextField` 不算数
       *（本项目踩过"注释让测试假绿/假红"至少四次，见文件头 `_code`）。
       */
      expect(
        s.contains('TextEditingController'),
        isFalse,
        reason: '★ 不该再有手填路径的输入框 —— '
            'Owner 明确否掉了「自己规定好目录 / 手填路径」',
      );
    });

    test('★ 用户真实数据目录绝不出现在测试/探针代码里', () {
      /*
       * 项目铁律：探针**必须**用 `DATA_DIR_OVERRIDE` 指向隔离目录，
       * 绝不能碰用户真实的 `%APPDATA%\app.sourin.player`。
       */
      final probe = File('lib/backup_panels_probe.dart').readAsStringSync();
      expect(
        probe.contains('DATA_DIR_OVERRIDE'),
        isTrue,
        reason: '★ 探针必须支持隔离数据目录',
      );
    });
  });
}
