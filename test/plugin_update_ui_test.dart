// ═══════════════════════════════════════════════════════════════════════
//  插件「检测更新 / 更新历史 / 回滚」的 UI 契约（task-23）
// ═══════════════════════════════════════════════════════════════════════
//
// 用户拍板：
// > 通过链接检测更新,可以进行回滚
// > 插件市场暂时不做  github raw 暂时不做
//
// # 这个文件锁住什么
//
// ```text
// ① ★★ 没有安装链接的插件**不显示**「插件更新」入口
//      —— 这是本功能最重要的产品原则：没有的能力不假装有
// ② 有链接的插件**显示**该入口
// ③ 入口的显示条件是「_pluginSources 里有这个 id」
// ④ 弹窗里三种检测结局都有对应文案（无更新 / 有更新 / 失败如实）
// ⑤ 检测是**用户点了才联网**（打开弹窗不自动检测）
// ⑥ 有新版时是「更新到 vX」按钮，**不自动覆盖**
// ```
//
// ⚠️ 为什么是**静态断言**（读源码）而不是 widget 测试：
//    `SettingsPage` 需要真核心（FFI）才能构造；而且这个功能的
//    关键契约（"不显示按钮"）是**源码里的条件分支**，
//    静态断言比 pump 一个假 SettingsPage 更直接、也更快。
//    真正的端到端（含网络）在 `rust/sourin_core/tests/batch23_plugin_update.rs`
//    里跑（本地 HTTP 服务 + 11 条断言）。
//
// ⚠️ 每条断言都做过**红度证明**（改坏实现 → 必需变红），见报告。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String src;

  setUpAll(() {
    src = File('lib/ui/settings_page.dart').readAsStringSync();
  });

  /// 去掉注释后的源码
  ///
  /// ⚠️ 本任务在代码里写了**大量**注释解释"为什么不显示按钮"、
  ///    "为什么不用批量检测判断" —— 里面全都提到了这些标识符。
  ///    不剥注释的话，把功能删掉测试照样绿（假绿）。
  ///    项目里这个坑已经踩过 7 次。
  String codeOnly() {
    final buf = StringBuffer();
    for (final line in src.split('\n')) {
      final t = line.trimLeft();
      if (t.startsWith('//') || t.startsWith('*') || t.startsWith('/*')) {
        continue;
      }
      buf.writeln(line);
    }
    return buf.toString();
  }

  /// 「插件更新」相关的那段（`_PluginUpdateDialog` 类体）
  String dialogBody() {
    final code = codeOnly();
    final start = code.indexOf('class _PluginUpdateDialog');
    expect(start > 0, isTrue, reason: '应能找到 _PluginUpdateDialog');
    /*
     * ⚠️ 终点锚点必须是**代码**，不能是注释文本 ——
     *    `codeOnly()` 已经把注释行剥掉了，用 `/// 插件配置对话框`
     *    永远找不到（初版就是这么写的，结果 end = -1 → 整组假红）。
     *    这是"断言锚点选错"的典型：锚点要选**被剥不掉**的东西。
     */
    final end = code.indexOf('class _PluginConfigDialog', start);
    expect(end > start, isTrue, reason: '应能找到下一个类的起点（切片终点）');
    return code.substring(start, end);
  }

  group('① ★★ 没有安装链接的插件不显示更新入口', () {
    test('★★★ 入口以 `_pluginSources.containsKey(id)` 为条件', () {
      /*
       * 这是整个功能最关键的一条。
       *
       * 用户手动丢进 `plugins/` 的 `.js` **没有来源链接**
       *（`plugins/.meta/<id>.json` 不存在）→ 无从查新版。
       * 对这类插件必须**不显示**入口 —— 显示一个点了没用的按钮
       * 等于假装有能力。
       *
       * 实现方式：`onPluginUpdate` 传 `null`，而 `_ProviderCard._actions`
       * 里是 `if (onPluginUpdate != null)` 才画按钮。
       */
      final code = codeOnly();
      expect(
        code.contains('_pluginSources.containsKey('),
        isTrue,
        reason: '★ 入口的条件必须是「有安装来源」',
      );
      // 三元的两端：有来源 → 回调；没有 → null
      expect(
        /*
         * ★★★ 2026-10-09 修正：变量从 `_providers[i]` 改成 `list[i]`
         *     （Owner 要求直播源与 JS 插件分开显示，本 tab 只画非直播源）。
         *     判据（**没有来源 ⇒ 传 null ⇒ 不画按钮**）一个字没变。
         */
        RegExp(r'\.containsKey\(\s*list\[i\]\.id\s*\)[\s\S]{0,600}?:\s*null,')
            .hasMatch(code),
        isTrue,
        reason: '★★ 没有来源时必须传 `null`（→ 卡片上不画按钮），'
            '不能传一个"点了提示无法检测"的回调',
      );
    });

    test('★★ 卡片里是 `if (onPluginUpdate != null)` 才画 —— null 就完全不出现', () {
      final card = codeOnly().substring(
        codeOnly().indexOf('class _ProviderCard'),
        codeOnly().indexOf('class _ProviderIcon'),
      );
      expect(
        card.contains('if (onPluginUpdate != null)'),
        isTrue,
        reason: '★★ `null` 时**不画**按钮（不是画一个 disabled 的）—— '
            'disabled 按钮仍然暗示"这个功能存在"，是误导',
      );
      // 按钮图标
      expect(card.contains('Icons.system_update_alt'), isTrue,
          reason: '更新入口用图标（卡片只有 299px，放不下文字按钮）');
      expect(card.contains("tooltip: '插件更新'"), isTrue);
    });

    test('★ 加载来源失败时保持空 map（保守方向：宁可少显示按钮）', () {
      /*
       * `list_plugin_sources` 失败 → `_pluginSources` 保持 `{}`
       * → 所有插件都当作"没有来源" → 不显示入口。
       *
       * ⚠️ 这个方向是**故意选的**：宁可少显示一个按钮，
       *    也**不能**在不知道来源的情况下显示「检测更新」骗用户。
       */
      final code = codeOnly();
      expect(code.contains('listPluginSources()'), isTrue,
          reason: '应调用 list_plugin_sources');
      expect(
        RegExp(r'var sources = <String, String>\{\};[\s\S]{0,400}?catch')
            .hasMatch(code),
        isTrue,
        reason: '★ 失败时保持空 map（保守）',
      );
    });
  });

  group('② 检测是"用户点了才联网"', () {
    test('★★ 打开弹窗**不**自动检测（只在 initState 读本地历史）', () {
      /*
       * 打开弹窗就自动检测 → 用户只想看一眼历史也会触发网络请求
       *（慢、可能失败、可能被 CDN 限流）。
       *
       * 所以 `initState` 只能调 `_loadVersions()`（纯本地读目录），
       * **不能**调 `_check()`。
       */
      final d = dialogBody();
      final initIdx = d.indexOf('void initState()');
      expect(initIdx >= 0, isTrue, reason: '应有 initState');
      final initBody = d.substring(initIdx, initIdx + 400);
      expect(
        initBody.contains('_loadVersions()'),
        isTrue,
        reason: 'initState 应读本地历史（毫秒级、零网络）',
      );
      expect(
        initBody.contains('_check()'),
        isFalse,
        reason: '★★ initState **不得**触发检测 —— 那会让"打开弹窗"变成网络请求',
      );
      // 检测只能由按钮触发
      expect(d.contains('onPressed: _busy ? null : _check'), isTrue,
          reason: '检测应由「检测更新」按钮触发');
    });

    test('★ 检测失败**如实显示原因**，不显示成"已是最新"', () {
      final d = dialogBody();
      /*
       * ⚠️ 只断言"源码里有 `检测失败：` 这个字符串"是**假绿**（实测踩到）：
       *    变异测试把失败分支改成 `return Text('已是最新…')`，
       *    只要**后面**还留着原来的 return 语句（死代码），
       *    那个字符串就仍在 → contains 断言照样绿。
       *
       * 所以必须断言**结构**：
       * ```text
       * ① 有 `if (c.error != null)` 分支
       * ② 该分支里出现的是「检测失败」而不是「已是最新」
       * ③ 「已是最新」只出现在**最后**那条（无更新）分支里
       * ```
       */
      final errIdx = d.indexOf('if (c.error != null)');
      expect(errIdx >= 0, isTrue,
          reason: '★★ 失败分支必须先于"无更新"分支判断');
      final hasUpdIdx = d.indexOf('if (c.hasUpdate)', errIdx);
      expect(hasUpdIdx > errIdx, isTrue, reason: '应能找到 hasUpdate 分支');
      final errBody = d.substring(errIdx, hasUpdIdx);

      // ② 失败分支里不能出现"已是最新"
      expect(
        errBody.contains('已是最新'),
        isFalse,
        reason: '★★★ 失败分支里**绝不能**出现"已是最新" —— '
            '那正是"假装成功"（变异测试证明：只查 contains 会假绿）',
      );
      // ② 失败分支要如实说"检测失败" + 带上原因
      expect(errBody.contains('检测失败'), isTrue,
          reason: '失败要显式说"检测失败"');
      expect(errBody.contains(r'${c.error}'), isTrue,
          reason: '★ 必须带上**具体原因**（网络错/链接失效/不是插件/无版本号），'
              '而不是一句笼统的"出错了"');

      // ③ "已是最新"只能出现在 hasUpdate 之后（无更新分支）
      final latestIdx = d.indexOf('已是最新', hasUpdIdx);
      expect(
        latestIdx > hasUpdIdx,
        isTrue,
        reason: '「已是最新」只能在**无更新**分支里（hasUpdate 判断之后）',
      );
      // 失败用错误色（视觉上区别于"已是最新"）
      expect(errBody.contains('colors.error'), isTrue,
          reason: '失败用错误色，让用户一眼看出不是"没问题"');
    });

    test('★ 远端内容变了但版本号没变 → 如实提示（不假装完全一致）', () {
      final d = dialogBody();
      expect(d.contains('sameContent'), isTrue,
          reason: '★ 要用 same_content 区分"真的一致"与"内容不同但版本号未变"');
      expect(
        d.contains('远端内容与本地不同但版本号未变'),
        isTrue,
        reason: '作者忘改版本号是真实情况，要如实说明（否则用户以为没变化）',
      );
    });
  });

  group('③ 不自动覆盖 + 回滚', () {
    test('★★ 有新版时是按钮，用户点了才更新', () {
      final d = dialogBody();
      expect(
        RegExp(r'if \(c != null && c\.hasUpdate\)').hasMatch(d),
        isTrue,
        reason: '★ 有新版才出现更新按钮',
      );
      expect(d.contains('更新到 v'), isTrue);
      expect(d.contains('updatePluginFromSource'), isTrue,
          reason: '★ 更新要调后端命令');
      // 绝不能"检测到就自动调更新"
      /*
       * ⚠️ 切片终点要用**下一个方法**，不能靠固定长度 ——
       *    `_check()` 本体只有 ~860 字符，我第一版取 1400 字符，
       *    结果窗口越界读到 `_update()` 里的 `updatePluginFromSource`，
       *    断言假红（**这是测试写错，不是产品 bug** —— 已实测确认
       *    `_check()` 体内没有那个调用）。
       */
      final checkIdx = d.indexOf('Future<void> _check()');
      expect(checkIdx >= 0, isTrue, reason: '应能找到 _check()');
      final checkEnd = d.indexOf('Future<void> _update()', checkIdx);
      expect(checkEnd > checkIdx, isTrue, reason: '应能找到 _update()（切片终点）');
      final checkBody = d.substring(checkIdx, checkEnd);
      expect(
        checkBody.contains('updatePluginFromSource'),
        isFalse,
        reason: '★★ `_check()` 里**绝不能**调更新 —— 检测归检测，覆盖要用户确认',
      );
    });

    test('★ 回滚按钮 + 调后端命令', () {
      final d = dialogBody();
      expect(d.contains('回滚到此版'), isTrue);
      expect(d.contains('rollbackPlugin'), isTrue);
      expect(d.contains('回滚中…'), isTrue, reason: '要有忙碌态（回滚要重载插件，有耗时）');
    });

    test('★ 历史档显示版本 + 时间（用户要能区分哪一档）', () {
      final d = dialogBody();
      expect(d.contains('PluginVersionEntry'), isTrue);
      expect(RegExp(r"_fmtTime\(v\.at\)").hasMatch(d), isTrue,
          reason: '★ 每档要显示时间（否则两档同名版本分不清）');
      expect(d.contains('_versions'), isTrue);
    });

    test('★ 更新/回滚后要刷新列表（版本号变了）', () {
      final code = codeOnly();
      expect(
        RegExp(r'_changed = true;').hasMatch(code),
        isTrue,
        reason: '做过更新/回滚要标记 changed',
      );
      expect(
        RegExp(r'if \(changed == true && mounted\)[\s\S]{0,200}?await loadAll\(\)')
            .hasMatch(code),
        isTrue,
        reason: '★ 关闭弹窗后要 `loadAll()` —— 否则卡片上还是旧版本号',
      );
    });
  });

  group('④ 卡片不被撑爆（4 列 299px）', () {
    test('★ 入口是**图标按钮**（不是文字按钮）', () {
      /*
       * 卡片单格 299px，5 个按钮已经占 264px（见 `_cardWideMinWidth` 的预算）。
       * 再加一个文字按钮（约 60px）必然溢出 → 必须是图标（约 40px），
       * 且窄版会跟着换行（`wide` 分支已处理）。
       */
      final card = codeOnly().substring(
        codeOnly().indexOf('class _ProviderCard'),
        codeOnly().indexOf('class _ProviderIcon'),
      );
      expect(
        RegExp(r'if \(onPluginUpdate != null\)\s*IconButton\(').hasMatch(card),
        isTrue,
        reason: '★ 必须是 IconButton（文字按钮会撑爆 299px 的卡片）',
      );
      expect(card.contains("visualDensity: VisualDensity.compact"), isTrue);
    });

    test('★ 弹窗宽度有界（照 _SkipHistoryDialog 的模式）', () {
      final d = dialogBody();
      expect(RegExp(r'width: 480').hasMatch(d), isTrue,
          reason: '弹窗要有固定宽度（内容自己撑会溢出）');
      expect(RegExp(r'height: 460').hasMatch(d), isTrue,
          reason: '★★ 高度必须**有界**（照 _SkipHistoryDialog）—— '
              '历史档再多也只占 460px，内部滚动');
    });

    test('★★★ 按钮行必须是 `Wrap`（`Row` 会溢出 31px）', () {
      /*
       * ══════════════════════════════════════════════════════════════════
       * 这是本次真踩到的回归，必须钉住
       * ══════════════════════════════════════════════════════════════════
       *
       * 加上「插件更新」图标后，窄版（4 列 / 单格 299px）的按钮行溢出：
       * ```text
       * 卡片内容宽 273px
       * 7 个按钮（↑ ↓ │ ⚙ 编辑 停用 🗑）   = 264  ✓
       * 8 个按钮（↑ ↓ │ ⟳ ⚙ 编辑 停用 🗑） = 304  ✗ 溢出 31px
       * 报错：A RenderFlex overflowed by 31 pixels on the right.
       * ```
       * 而且**没有一个按钮能砍**（遥控排序 / 更新入口 / 配置唯一入口 /
       * 编辑源码 / 常用开关 / 移除源）→ 只能让它们**折行**。
       *
       * `Wrap` 在放得下时与 `Row` 行为一致（单行不换），
       * 只在放不下时折到第二行 —— 宽版逐像素不变，窄版不再溢出。
       *
       * ⚠️ 这条断言的价值：`Row` → `Wrap` 是个**很容易被"顺手改回去"**
       *    的改动（看起来 `Row` 更直白），而改回去就会重新溢出。
       */
      final code = codeOnly();
      final i = code.indexOf('Widget _actions(ColorScheme colors)');
      expect(i > 0, isTrue, reason: '应能找到 _actions');
      /*
       * ⚠️ 切片终点要**就近**取：第一版用"下一个 `Widget _`"，
       *    结果下一个方法在 4 万字符之外（中间隔了 `_panels` /
       *    `_nameRow` / `_descLine` / `_capsRow` 一大堆注释与代码），
       *    切片里根本不含 `return Wrap(` → 假红。
       *    改成"取到 `_actions` 之后第一个 `\n  }` 为止"（方法体结尾）。
       */
      final end = code.indexOf('\n  }', i);
      expect(end > i, isTrue, reason: '应能找到 _actions 的方法体结尾');
      final body = code.substring(i, end);
      expect(body.contains('return Wrap('), isTrue,
          reason: '★★★ 按钮行必须是 `Wrap` —— `Row` 在窄版（299px）会溢出 31px。'
              '若改回 `Row`，请先确认 8 个按钮能塞进 273px（当前 304px，塞不下）');
      expect(body.contains('return Row('), isFalse,
          reason: '★ 不能是 `Row`（见上）');
      // 折行后第二行也要右对齐（否则"第一行靠右、第二行靠左"很难看）
      expect(body.contains('alignment: WrapAlignment.end'), isTrue,
          reason: '★ 窄版按钮行是右对齐的，折行后第二行也要右对齐');
    });
  });

  group('⑤ 版本比较契约（与 Rust 侧对齐）', () {
    test('★★ 界面不自己做版本比较（那是 Rust 的职责）', () {
      /*
       * `1.10.0 > 1.9.0` 这种比较**必须**在 Rust 里做（`version_is_newer`），
       * 界面只读 `has_update` 布尔值。
       *
       * ⚠️ 为什么不能在前端也写一份：两份实现必然漂移，
       *    表现就是"界面说有新版、更新完版本号没变"。
       */
      final code = codeOnly();
      expect(
        RegExp(r'hasUpdate').hasMatch(code),
        isTrue,
        reason: '★ 界面读 has_update 布尔值',
      );
      // 界面里不该出现自己解析版本号做比较的代码
      expect(
        RegExp(r'split\(.\.\)[\s\S]{0,80}?(compareTo|>|<)').hasMatch(code),
        isFalse,
        reason: '★★ 界面**不得**自己按 `.` 切段比版本 —— '
            '那是 Rust `version_is_newer` 的职责（两份实现会漂移）',
      );
    });

    test('★ 保留档数的文案数字与 Rust 侧一致', () {
      final code = codeOnly();
      expect(code.contains('kMaxPluginVersionsShown = 5'), isTrue,
          reason: '★ 与 Rust `MAX_PLUGIN_VERSIONS = 5` 必须一致'
              '（不一致会让界面说谎："说留 5 档、实际留 3 档"）');
      expect(code.contains(r'$kMaxPluginVersionsShown'), isTrue,
          reason: '文案要引用常量，不能写死数字');
    });
  });
}
