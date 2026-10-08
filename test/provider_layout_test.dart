// ═══════════════════════════════════════════════════════════════════════
//  设置页「内容源」卡片式布局
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户指出：「内容源布局太丑」
//
// 改之前是一行一个源，只有一个 `Switch` + 源名 + kind 文本：
// ```text
// [开关] 哔哩哔哩          js
// [开关] 360资源-采集      js
//   ... 25 行几乎一模一样
// ```
// 三个问题：信息密度低 / 没有层次 / 能力不可见。
//
// # 改成什么（照原版 `SettingsView.vue` 的 `.prov` 卡片）
//
// ```text
// ┌────────────────────────────────────────────────────────────┐
// │ [图标]  源名 [JS 插件] [v1.0.0] [已停用] [已失效]  [停用] [移除] │
// │         描述文字或 id                                       │
// │         [直播] [搜索] [需登录]                              │
// └────────────────────────────────────────────────────────────┘
// ```
//
// # 原版注释里最值得锁住的三条（都在下面有断言）
//
// ```text
// ① 名称行**禁止换行**
//    原版实测 28 张卡里 2 张折行 → 那两张高 30px，Owner 原话：
//    > 这个高度保持一下统一，这高度都不一样显示的太丑了
// ② 名称可收缩（Flexible），chip 不可压缩
// ③ 停用的卡片整卡降透明度（一眼看出"这张是关的"）
// ```
//
// ⚠️ 本文件是**静态断言真实路径** —— 设置页需要真核心（FFI）才能构造，
//    `flutter_test` 里跑不起来。真实观感由真机截图覆盖。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('内容源卡片布局', () {
    late String src;

    setUpAll(() {
      src = File('lib/ui/settings_page.dart').readAsStringSync();
    });

    test('★ 用卡片组件（不是一行一个 Switch）', () {
      expect(
        src.contains('class _ProviderCard extends StatelessWidget'),
        isTrue,
        reason: '★ 每源一张卡片 —— 用户指出「布局太丑」，'
            '根因就是"一行一个开关"没有层次',
      );
      expect(
        src.contains('_ProviderTile'),
        isFalse,
        reason: '旧的"一行一个"实现必须删干净（留死代码会误导后人）',
      );
    });

    test('★★ 名称行必须禁止换行（原版最强调的一条）', () {
      /*
       * 原版实测：28 张卡片里 2 张折行（名称行 25px → 57px），
       * 那两张就比别人高 30px。Owner 原话：
       * > 这个高度保持一下统一，这高度都不一样显示的太丑了
       *
       * Flutter 里对应 `maxLines: 1` + `TextOverflow.ellipsis`
       * + `Flexible`（可收缩）。
       */
      expect(
        src.contains('Widget _nameRow(ColorScheme colors)'),
        isTrue,
        reason: '名称行要独立成方法（便于保证"不换行"这条不被改坏）',
      );
      // 名称本体必须是 Flexible + ellipsis
      expect(
        RegExp(r'Flexible\(\s*\n\s*child: Text\(\s*\n\s*provider\.name')
            .hasMatch(src),
        isTrue,
        reason: '★ 名称必须包在 `Flexible` 里 —— 原版 `flex: 0 1 auto`，'
            '允许**收缩**而不是撑开。不收缩的话内容会溢出卡片盖住右侧按钮',
      );
      expect(
        src.contains('maxLines: 1,\n            overflow: TextOverflow.ellipsis,'),
        isTrue,
        reason: '★ 名称必须 `maxLines: 1` + ellipsis —— 这是"不换行"的实现',
      );
    });

    test('★★ chip 必须不可压缩（只做"名称可收缩"会被撑破）', () {
      /*
       * 原版 css：
       * ```css
       * .prov__name .chip { flex: none; white-space: nowrap; }
       * ```
       * 注释解释了为什么：
       * > `flex: none` 是关键 —— chip 默认 `flex: 0 1 auto` 会被压缩，
       * > 文字挤成两行（chip 内允许换行），高度照样参差。
       */
      expect(
        src.contains('softWrap: false'),
        isTrue,
        reason: '★ chip 必须禁止换行 —— 否则标签被压成两行，'
            '卡片高度照样参差（原版注释明确记录过）',
      );
      expect(
        src.contains('maxLines: 1,'),
        isTrue,
        reason: 'chip 也要限 1 行',
      );
    });

    test('★ 停用的卡片整卡降透明度', () {
      /*
       * 原版 `.prov.is-off { opacity: 0.55 }`。
       * 好处：一眼看出"这张是关的"，不用逐个读开关状态。
       */
      expect(
        src.contains('opacity: off ? 0.55 : 1.0'),
        isTrue,
        reason: '★ 照原版 `.prov.is-off { opacity: 0.55 }`',
      );
    });

    test('★ 两个状态标签是**两件事**，都要显示', () {
      /*
       * 原版注释：
       * > ★ 两个状态标签是**两件事**，都要显示：
       * >   · 已停用 —— 用户的选择（可改）
       * >   · 已失效 —— 站点自身不可用（探测得出，用户改不了）
       *
       * 只显示一个会让用户以为"我明明没停用它啊"。
       */
      expect(src.contains("_MiniChip(text: '已停用'"), isTrue,
          reason: '要显示「已停用」（用户的选择）');
      expect(src.contains("_MiniChip(text: '已失效'"), isTrue,
          reason: '要显示「已失效」（站点不可用）—— 与"已停用"是两件事');
    });

    test('★ chip 有四档色调（已停用/已失效必须不同色）', () {
      expect(
        src.contains('enum _ChipTone { plain, brand, off, danger }'),
        isTrue,
        reason: '★ 原版把「已停用」（灰）和「已失效」（红）做成不同颜色 —— '
            '同色的话用户分不清"是我不小心关了"还是"这源坏了"',
      );
      // ⚠️ 只能有一份定义（同名类型重复声明是编译错误）
      final count = RegExp(r'^enum _ChipTone', multiLine: true)
          .allMatches(src)
          .length;
      expect(
        count,
        1,
        reason: '★ `_ChipTone` 只能有**一份**定义 —— '
            '我插入新版本时忘了删旧的，编译报 "already defined"。'
            'Dart 同名类型不能重复声明（即使内容一样）。当前 $count 份。',
      );
    });

    test('★ 图标是 30px 方块（与右侧图标按钮等宽对齐）', () {
      /*
       * 原版 `.prov__icon { width: 30px; height: 30px }`，注释解释了
       * 为什么从 34 收到 30：
       * > 视觉上与右侧 30px 的图标按钮**等宽对齐**，一排看起来更整齐。
       */
      expect(src.contains('class _ProviderIcon extends StatelessWidget'), isTrue,
          reason: '图标独立成组件');
      expect(
        RegExp(r'width: 30,\s*\n\s*height: 30,').hasMatch(src),
        isTrue,
        reason: '★ 30x30 —— 照原版（不是随手写的 34/36）',
      );
    });

    test('★ kind 标签要反映**真实形态**（不能都说成"插件"）', () {
      /*
       * 原版注释特别强调：
       * > ★ 标签必须反映真实形态：HTTP Provider 跑在独立进程、
       * > 可用任意语言，与「声明式 JSON」是两回事，
       * > **标错会让用户误判能力与隔离性**
       */
      expect(src.contains("'js' => 'JS 插件'"), isTrue, reason: 'js → JS 插件');
      expect(src.contains("'declarative' => '声明式'"), isTrue,
          reason: 'declarative → 声明式');
      expect(src.contains("'http' => 'HTTP 插件'"), isTrue,
          reason: '★ http → HTTP 插件（它跑在独立进程，与声明式不是一回事）');
    });

    test('★ 内置源不给「移除」按钮（删了会复活）', () {
      /*
       * 原版用 kind 区分：`js`/`declarative`/`http` 是第三方的，其余内置。
       * 内置源编译在核心里，删了也会"复活" —— 给按钮是骗用户。
       */
      expect(
        src.contains("bool get _isThirdParty"),
        isTrue,
        reason: '要有"是否第三方"的判断',
      );
      expect(
        src.contains("if (_isThirdParty)\n          IconButton("),
        isTrue,
        reason: '★ 「移除」只在第三方源上显示',
      );
    });

    test('★ 能力标签必须来自**同一份**数据源（避免空行）', () {
      /*
       * `_hasAnyCap`（决定要不要渲染这一行）与 `_capsRow`（渲染什么）
       * 若各写一份判断，改一处忘另一处就会出现「判断说有、渲染时没有」
       * 的**空行**。
       */
      expect(
        src.contains('List<String> _capLabels(Capabilities c)'),
        isTrue,
        reason: '★ 能力标签要抽成单一来源的函数',
      );
      expect(
        src.contains('bool _hasAnyCap(Capabilities c) => _capLabels(c).isNotEmpty;'),
        isTrue,
        reason: '★ `_hasAnyCap` 必须复用 `_capLabels` —— '
            '两处各写一份"有哪些能力"会出现空行',
      );
    });

    test('★ 描述为空时退回显示 id（不留白）', () {
      // 原版 `{{ p.description || p.id }}`
      expect(
        src.contains('(d == null || d.isEmpty) ? provider.id : d'),
        isTrue,
        reason: '★ 原版 `p.description || p.id` —— 没描述就显示 id，'
            '总比一片空白强（用户至少能对上插件文件名）',
      );
    });

    test('★ 有"调整顺序"入口（原有功能不回归）', () {
      expect(src.contains("label: const Text('调整顺序')"), isTrue,
          reason: '排序面板入口必须保留');
      expect(src.contains('_openOrderDialog'), isTrue,
          reason: '_openOrderDialog 还在用');
    });

    test('★★ 禁止 import flutter/material.dart（两套 Theme 串台）', () {
      /*
       * Flutter 3.47 把 Material 拆成 `material_ui` 包。
       * `flutter/material.dart` 与 `material_ui.dart` 是**两个库**，
       * 各自的 `Theme` InheritedWidget 互相看不见 ——
       * 混用会让 `Theme.of` 拿到 fallback（M3 **亮色**）。
       *
       * ⚠️ 这个 bug 就发生在**本文件**：设置页标题对比度只有 1.16:1
       *    （几乎看不见）。见 `test/material_split_test.dart`。
       */
      expect(
        src.contains("import 'package:flutter/material.dart'"),
        isFalse,
        reason: '★ 本文件曾因混用 Material 两套库导致标题对比度 1.16:1',
      );
      expect(
        src.contains("import 'package:material_ui/material_ui.dart'"),
        isTrue,
        reason: '必须用 material_ui',
      );
    });

    test('★ forui 与 Material 的角色名不能混用', () {
      /*
       * `FTheme.of(context).colors`（forui）与
       * `Theme.of(context).colorScheme`（Material）的**角色名不同**：
       * ```text
       * forui:     foreground / mutedForeground / border
       * Material:  onSurface / onSurfaceVariant / outlineVariant
       * ```
       * 混用会编译失败（我踩过：`foreground` 在 ColorScheme 上不存在）。
       * 这里断言新加的卡片代码统一用 Material 的名称。
       */
      expect(
        src.contains('colors.onSurfaceVariant'),
        isTrue,
        reason: '卡片里应使用 Material 的角色名',
      );
      // 新卡片代码里不该出现 forui 的名字（老代码可能还在用，只查卡片段）
      final cardStart = src.indexOf('class _ProviderCard');
      final cardEnd = src.indexOf('class _ProviderIcon');
      expect(cardStart > 0 && cardEnd > cardStart, isTrue,
          reason: '应该能找到 _ProviderCard 段落');
      final cardBody = src.substring(cardStart, cardEnd);
      expect(
        cardBody.contains('colors.foreground') ||
            cardBody.contains('colors.mutedForeground') ||
            cardBody.contains('colors.border'),
        isFalse,
        reason: '★ `_ProviderCard` 里不得用 forui 的角色名 —— '
            '`ColorScheme` 上没有 `foreground`（编译报 undefined_getter）',
      );
    });
  });
}
