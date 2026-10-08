// ═══════════════════════════════════════════════════════════════════════
//  Provider 导入 / 编辑入口 + 插件区块缺失的 3 个按钮（任务 R）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守什么
//
// 审计（635 行报告）认定两处**真缺口**：
// ```text
// 缺口组① Provider 导入 / 编辑 —— 4 个命令无 UI 入口
//   import_declarative_provider  原版 SettingsView.vue:1458
//   install_http_provider        原版 SettingsView.vue:1474
//   get_provider_config          原版 SettingsView.vue:1384
//   get_provider_order           原版 SettingsView.vue:1586
//
// 缺口组② JS 插件区块缺 3 个按钮（原版共 5 个）
//   健康检测 health_sweep     —— 包装一直存在，设置页调用数 = 0
//   导入源   openAdd          —— 声明式 JSON / HTTP 的唯一界面入口
//   重新加载 reload_plugins   —— 包装一直存在，设置页调用数 = 0
// ```
//
// # 为什么要断言「真的调了 API」而不只是「按钮存在」
//
// 项目里踩过这个坑（见 `settings_panels_test.dart` 的开头）：
// **"代码写完了"和"功能可用了"之间差一次接线**。
// `healthSweep()` 的包装在 `sourin_api.dart:145` 躺了很久，
// 但设置页里调用数为 0 —— 光断言"有这个按钮"是抓不到的。
//
// # ⚠️ 断言前必须先剥注释（本项目踩过至少四次）
//
// 这些新增代码的注释里**大量提到** `SourinApi.healthSweep()` /
// `reloadPlugins` 这些标识符（因为要把"为什么"写清楚）。
// 纯文本匹配会把注释当成真实调用 → **假通过**。
// 所以下面所有源码断言都走 [_code]（先剥注释）。
//
// # 分层
//
// ```text
// 静态接线断言  → 本文件（不需要真核心）
// 纯函数行为断言 → 本文件（prettyJson / parseHeaders / fromJson / toast）
// 真实观感与网络 → 真机截图 + 真实健康检测（单测做不到，需要 FFI）
// ```

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/widgets/provider_import_dialog.dart';
import 'package:sourin_spike/core/sourin_api.dart';

/// 剥掉注释 —— 静态断言里做文本匹配**必须先剥**
///
/// 比 `settings_panels_test.dart` 的 `_code` 更彻底：那个只过滤
/// **整行**以 `//` / `*` / `/*` 开头的行，抓不到
/// ```dart
/// final x = 1; // 这里提到 SourinApi.healthSweep()
/// ```
/// 这种**行尾注释**。本文件用正则把块注释与行注释都去掉。
///
/// ⚠️ 代价：字符串字面量里的 `//`（如 `'http://...'`）也会被截断。
///    所以本文件**不对含 `//` 的字符串做断言** —— 这是有意的取舍，
///    宁可少断言两条，也不要一条假通过的。
String _code(String src) => src
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  缺口组②：插件区块的 3 个按钮 + 接线
  // ═══════════════════════════════════════════════════════════════════
  group('插件区块缺的 3 个按钮', () {
    late String src;
    late String code;

    setUpAll(() {
      src = File('lib/ui/settings_page.dart').readAsStringSync();
      code = _code(src);
    });

    test('★★ 健康检测：按钮存在 + 真的调了 healthSweep()', () {
      /*
       * 原版 `SettingsView.vue:1716`：
       * ```html
       * <button class="btn btn--ghost" :disabled="sweepping" @click="sweep">
       *   {{ sweepping ? "检测中…" : "健康检测" }}
       * </button>
       * ```
       *
       * ⚠️ 关键是**第二半** —— `healthSweep()` 的包装在
       *    `sourin_api.dart:145` 一直存在，缺的是调用点。
       *    只断言按钮文案会**假通过**（注释里就写着这四个字）。
       */
      expect(code.contains('健康检测'), isTrue, reason: '按钮文案必须是「健康检测」');
      expect(
        code.contains('SourinApi.healthSweep()'),
        isTrue,
        reason: '★ 必须真调 healthSweep() —— 光有按钮是假接线',
      );
      // 探测期间禁用 + 文案变「检测中…」（原版 `:disabled="sweepping"`）
      expect(code.contains('检测中…'), isTrue, reason: '探测中要有「检测中…」文案');
      expect(code.contains('_sweeping'), isTrue, reason: '必须有 _sweeping 状态位');
    });

    test('★★★ 健康检测的反馈必须报出「几个源不可用」或「全部正常」', () {
      /*
       * 原版 `SettingsView.vue:1490`（这是这个功能的**全部价值**）：
       * ```ts
       * const r = await provApi.healthSweep();
       * const bad = Object.entries(r).filter(([, ok]) => !ok);
       * flash(bad.length ? `${bad.length} 个源不可用` : "全部正常");
       * ```
       *
       * ⚠️ 只显示"检测完成"等于没做 —— 用户点这个按钮就是想知道
       *    **哪些源挂了**。本机 26 个源，没法逐个点进去试。
       */
      expect(
        code.contains('全部正常'),
        isTrue,
        reason: '★ 全好时必须说「全部正常」',
      );
      expect(
        code.contains('个源不可用'),
        isTrue,
        reason: '★ 有坏的必须报出数量（原版文案是 bad.length 个源不可用）',
      );
      // 判据是 `!e.value`（后端返回 `id → 是否可用`）
      expect(
        code.contains('where((e) => !e.value)'),
        isTrue,
        reason: '★ 必须把 false 的挑出来 —— 判据写反的话"全好"和"全坏"会颠倒',
      );
    });

    test('★★ 导入源：按钮存在 + 打开导入弹窗', () {
      /*
       * 原版 `SettingsView.vue:1719`：`<button ... @click="openAdd">导入源</button>`
       *
       * ⚠️ 原版注释特意强调过这是**唯一界面入口**：
       * > 「导入源」是声明式 JSON / HTTP 接入的唯一界面入口，
       * > 删掉就再也加不了（后端能力还在，但用户点不到）。
       */
      expect(code.contains('导入源'), isTrue, reason: '按钮文案必须是「导入源」');
      expect(
        code.contains('ProviderImportDialog.showAdd('),
        isTrue,
        reason: '★ 必须真的打开弹窗（`showAdd` = 原版 openAdd）',
      );
    });

    test('★★ 重新加载：按钮存在 + 真的调了 reloadPlugins()', () {
      /*
       * 原版 `SettingsView.vue:1725`：
       * ```html
       * <button class="btn btn--ghost" :disabled="pluginBusy" @click="reloadPlugins">
       *   {{ pluginBusy ? "处理中…" : "重新加载" }}
       * </button>
       * ```
       *
       * 这个按钮的价值：用户手工把 `.js` 放进 `plugins/` 目录后，
       * 界面不会自己发现 —— 没有它就只能重启程序。
       */
      expect(code.contains('重新加载'), isTrue, reason: '按钮文案必须是「重新加载」');
      expect(
        code.contains('SourinApi.reloadPlugins()'),
        isTrue,
        reason: '★ 必须真调 reloadPlugins() —— 包装在 :780 一直存在但零调用',
      );
      expect(code.contains('_pluginBusy'), isTrue, reason: '必须有 _pluginBusy 状态位');
      expect(code.contains('处理中…'), isTrue, reason: '忙碌时文案变「处理中…」');
    });

    test('★★ 5 个按钮必须用 Wrap（原版明确要求的折行语义）', () {
      /*
       * 原版 `SettingsView.vue:1708` 的注释（照抄）：
       * > ⚠️ 用 `flex-wrap: wrap` + `gap` 而不是写死宽度 ——
       * >    手机上五个按钮一行放不下，要能自然折行。
       *
       * Flutter 的 `Wrap` 就是这个语义。写成 `Row` 会在窄屏
       * 直接**溢出报错**（黄黑条纹），不是折行。
       */
      /*
       * ⚠️ 锚点用 `检测中…` 而不是 `健康检测` —— `健康检测` 四个字
       *    在 `_healthSweep()` 的报错文案里也出现过
       *    （`_flash('健康检测失败：$e')`），而那个方法定义在
       *    `build()` **之前**，拿它当锚点会定位到错误的位置。
       */
      final anchor = code.indexOf('检测中…');
      expect(anchor, greaterThanOrEqualTo(0), reason: '缺「检测中…」文案');

      final start = code.lastIndexOf('Wrap(', anchor);
      expect(start, greaterThanOrEqualTo(0), reason: '「健康检测」前面必须有 Wrap(');

      /*
       * ⚠️⚠️ 这里踩过一个 **off-by-one**，记下来（本项目第三次
       *      "断言在错误的文本范围上跑"）。
       *
       * `substring(start, end)` 取的是**半开区间** `[start, end)` ——
       * `end` 处的文本**不在**结果里。而 `end` 正是
       * `'粘贴源码安装'` 的起始位置，于是最后那个标签被切掉了：
       * ```text
       * group.contains('健康检测')     → true  ✓
       * group.contains('导入源')       → true  ✓
       * group.contains('重新加载')     → true  ✓
       * group.contains('从网址安装')   → true  ✓
       * group.contains('粘贴源码安装') → false ✗ ← 假红
       * ```
       * 报错信息是"插件区块缺按钮「粘贴源码安装」"—— **误导**：
       * 按钮明明在，是切片边界把它排除了。
       *
       * 修法：把 end 推到标签**之后**（`+ endLabel.length`）。
       */
      const endLabel = '粘贴源码安装';
      final end = code.indexOf(endLabel, anchor);
      expect(end, greaterThan(start), reason: '两个安装按钮必须跟在健康检测之后');

      // ★ 先证明**切片本身**是对的，再看里面的按钮
      //
      // 为什么要这两条：如果哪天切片范围又算错，报的会是
      // "切片错了"而不是"按钮缺了" —— 定位快得多。
      // （教训来自本轮 P3 发现的「假红/恒真断言」三例：
      //   共同点都是断言跑在错误的文本范围上。）
      final group = code.substring(start, end + endLabel.length);
      expect(group.contains('Wrap('), isTrue,
          reason: '切片必须包含 Wrap 开头（切片范围算错了）');
      expect(group.contains(endLabel), isTrue,
          reason: '切片必须包含最后一个按钮（切片范围算错了）');

      // 五个按钮必须在**同一个** Wrap 里（不是分散成好几个 Row）
      for (final label in [
        '健康检测',
        '导入源',
        '重新加载',
        '从网址安装',
        '粘贴源码安装',
      ]) {
        expect(group.contains(label), isTrue,
            reason: '插件区块缺按钮「$label」');
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  缺口组①：Provider 导入 / 编辑入口
  // ═══════════════════════════════════════════════════════════════════
  group('Provider 导入 / 编辑入口', () {
    late String code;

    setUpAll(() {
      code = _code(File('lib/ui/settings_page.dart').readAsStringSync());
    });

    test('★★ 编辑入口：调 get_provider_config 回填', () {
      /*
       * 原版 `SettingsView.vue:1384`：
       * ```ts
       * const cfg = await provApi.config(p.id);      // get_provider_config
       * if (!cfg) { flash("该源没有可编辑的配置"); return; }
       * ```
       *
       * ⚠️ 原版注释解释了为什么必须回填**原始配置**：
       * > manifest 只是解析后的结果（名称、能力位等），
       * > 用户真正要改的是**请求地址、JSONPath 映射、自定义头**这些，
       * > 它们只存在原始配置里。不回填的话用户只能删了重建 ——
       * > 打错一个字就得全部重来（这正是加这个功能的起因）。
       */
      expect(
        code.contains('SourinApi.getProviderImportSeed('),
        isTrue,
        reason: '★ 必须调 get_provider_config（包装名为 getProviderImportSeed）',
      );
      expect(
        code.contains('该源没有可编辑的配置'),
        isTrue,
        reason: '★ 原版兜底文案，逐字对齐',
      );
      expect(
        code.contains('ProviderImportDialog.showEdit('),
        isTrue,
        reason: '★ 必须用编辑态打开弹窗（预填），不是 showAdd',
      );
    });

    test('★★★ JS 插件走源码编辑器（原版 edit() 的第一条分支）', () {
      /*
       * 原版 `SettingsView.vue:1365`：
       * ```ts
       * if (p.kind === "js") {
       *   const info = pluginList.value.find((x) => x.id === p.id);
       *   if (!info) {
       *     flash("找不到该插件的文件（可能刚被删除，试试「重新加载」）");
       *     return;
       *   }
       *   await editPlugin(info);   // ← 源码编辑器
       *   return;
       * }
       * ```
       *
       * ⚠️ 这条分支是原版**修过的真 bug**：原先编辑按钮的条件是
       *    `kind === 'http' || kind === 'declarative'`，而 JS 插件的
       *    kind 是 `"js"` → 编辑按钮**不显示**。JS 插件当然该能编辑 ——
       *    它就是磁盘上的一个 .js 文件。
       */
      expect(
        code.contains("p.kind == 'js'"),
        isTrue,
        reason: '★ 必须有 JS 插件的分派分支',
      );
      expect(
        code.contains('_editPlugin(info)'),
        isTrue,
        reason: '★ JS 插件必须转给源码编辑器，不是配置弹窗',
      );
      expect(
        code.contains('找不到该插件的文件'),
        isTrue,
        reason: '★ 原版兜底文案（还提示了「重新加载」）',
      );
    });

    test('★★ 「编辑」按钮的判据必须**正向列举**可编辑的', () {
      /*
       * 原版 `canEdit`（`SettingsView.vue:1354`）注释（照抄）：
       * > ⚠️ 判据要**正向列举可编辑的**，而不是「不等于 builtin」——
       * >    后者在将来新增源类型时会误放行（点了报错比不放更糟）。
       *
       * 后端的 `kind` 是 String 不是 enum，将来加新形态时
       * `!= 'builtin'` 会立刻放行，用户点进去才发现没配置可改。
       */
      expect(code.contains('bool get _canEdit'), isTrue, reason: '缺 _canEdit 判据');
      // 三种形态都要放行
      for (final k in ["'declarative'", "'http'", "'js'"]) {
        expect(code.contains(k), isTrue, reason: '_canEdit 必须放行 kind == $k');
      }
      // ⚠️ 不能写成「不等于 builtin」
      expect(
        code.contains("provider.kind != 'builtin'"),
        isFalse,
        reason: '★ 禁止用 `!= builtin` 当判据（原版注释明确否定了这种写法）',
      );
    });

    test('★ 卡片真的把 onEdit 接出去了', () {
      /*
       * ⚠️ 这条断言原先锁死字面量 `onEdit: () => _editProvider(p)`。
       *
       * 2026-09-25 拖动排序落地后，卡片改成按下标取（`_providers[i]`）——
       * 因为 `ReorderableListView` 的拖拽需要下标。
       * 于是这条断言**假红**了：功能完好，只是变量名从 `p` 变成了
       * `_providers[i]`。
       *
       * 教训：断言锁死**变量名**会把重构误报成回归。
       * 这里改成锁**结构**（用正则允许任意实参），
       * 既保住"必须接上 onEdit"这个真契约，又不会因为改名而假红。
       */
      expect(
        RegExp(r'onEdit:\s*\(\)\s*=>\s*_editProvider\(').hasMatch(code),
        isTrue,
        reason: '★ 卡片必须接上 onEdit，否则按钮点了没反应',
      );
      expect(
        code.contains('required this.onEdit'),
        isTrue,
        reason: '_ProviderCard 必须声明 onEdit 参数',
      );
      // 声明了还必须**用**上，否则按钮是死的
      expect(
        code.contains('onPressed: onEdit'),
        isTrue,
        reason: '★ 光声明不够 —— 编辑按钮必须真的调用 onEdit',
      );
    });

    test('★★★ toast 必须让开**悬浮底栏**的高度（否则反馈全看不见）', () {
      /*
       * # 这是我在验证任务 R 时实测发现的真缺陷（2026-09-24）
       *
       * 底栏是**悬浮**的（`shell.dart` 用 Stack，不占布局空间）。
       * toast 原先只让了 `Sp.x10` = **40px**，而底栏占 58 + 间隙 12 = 70px
       * → toast 正好落在玻璃底下，被模糊层糊住。
       *
       * 截图证据：底部只看得见一团黑色圆角矩形，文字**完全不可辨认**
       *（`.probe/rK-sweep.png` 与放大图 `.probe/rN-toast.png`）。
       *
       * 后果不只是我的任务 —— **所有 `_flash()` 都失效**：
       * ```text
       * 我这轮加的   「N 个源不可用」「全部正常」「已重新加载 N 个插件」
       * 原有的       「已停用」「顺序已保存」「已移除」
       * ```
       * 提示发出来了、用户看不见 = 等于没发。
       *
       * 修法用 `Sp.bottomBarInset` 而不是把数字调大：那个 token 的注释
       * 写着它的存在理由**就是这件事**（「给悬浮底栏让位」），
       * 且它已被 ListView 的 padding 用 —— 同一个值两边一致，
       * 而且 TV 自动取 110（写死 90 在 TV 上仍会被盖）。
       */
      expect(
        code.contains('bottom: Sp.bottomBarInset'),
        isTrue,
        reason: '★ toast 的 bottom 必须用 Sp.bottomBarInset 让开悬浮底栏',
      );
      expect(
        code.contains('bottom: Sp.x10'),
        isFalse,
        reason: '★ 不许退回写死的 40px —— 那会被底栏盖住（实测过）',
      );
    });

    test('★★ 导入成功后必须重新拉列表（同 id 覆盖语义）', () {
      /*
       * 后端 `import_declarative_provider` 是**同 id 覆盖**：
       * ```rust
       * list.retain(|x| x.id() != manifest.id);   // 先删旧的
       * list.push(PersistedProvider::Declarative { ... });
       * ```
       * 所以本地插入一条会**留下两条同名源**。必须重新拉。
       */
      expect(
        code.contains('await loadAll()'),
        isTrue,
        reason: '★ 导入/编辑后必须 loadAll()，不能本地插入',
      );
      expect(
        code.contains('widget.onProvidersChanged?.call()'),
        isTrue,
        reason: '★ 要通知首页刷新（源变了，首页分区要重拉）',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  项目铁律
  // ═══════════════════════════════════════════════════════════════════
  group('项目铁律', () {
    test('★★★ 新文件禁止 import package:flutter/material.dart', () {
      /*
       * Flutter 3.47 把 Material 从 SDK 里**拆成独立包** `material_ui`。
       * `package:flutter/material.dart` 仍然存在（同一 SDK 里两份源码），
       * 于是同一个 app 里可以**同时存在两套 Material** ——
       * 两套 `Theme` 串台，症状是颜色/对比度莫名其妙不对。
       *
       * 本项目实测踩过：设置页标题对比度只剩 **1.16:1**（不可读）。
       * 详见 `pubspec.yaml` 里 `material_ui` 那段注释 +
       * `test/material_split_test.dart`。
       */
      for (final f in [
        'lib/ui/widgets/provider_import_dialog.dart',
        'lib/ui/settings_page.dart',
        'lib/core/sourin_api.dart',
      ]) {
        final s = File(f).readAsStringSync();
        expect(
          s.contains("package:flutter/material.dart"),
          isFalse,
          reason: '★ $f 混用了两套 Material —— 必须统一 material_ui',
        );
      }
    });

    test('★ 新文件必须 import material_ui（不是别的 Material 来源）', () {
      final s = File('lib/ui/widgets/provider_import_dialog.dart').readAsStringSync();
      expect(
        s.contains("package:material_ui/material_ui.dart"),
        isTrue,
        reason: '★ 必须走 material_ui（与其余 35 个 UI 文件一致）',
      );
    });

    test('★★ 没有新增依赖（file_selector 已够用）', () {
      /*
       * 任务约束：禁止加新依赖。
       * 这个断言防的是"顺手引一个包"—— 本项目体积预算紧张
       *（release 7z 目标 50 MB，见 pubspec 注释）。
       */
      final pubspec = File('pubspec.yaml').readAsStringSync();
      for (final forbidden in ['file_picker', 'flutter_highlight', 'code_text_field']) {
        expect(
          pubspec.contains(forbidden),
          isFalse,
          reason: '★ 不应该引入 $forbidden',
        );
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  纯函数行为（不碰 FFI，可真跑）
  // ═══════════════════════════════════════════════════════════════════
  group('prettyJson（原版 :1431）', () {
    test('★ 合法 JSON 会被格式化（缩进 2 空格）', () {
      /*
       * 原版：
       * ```ts
       * try { return JSON.stringify(JSON.parse(raw), null, 2); }
       * catch { return raw; }
       * ```
       * 原版注释：`// 格式化后再填：用户改起来比压缩成一行的 JSON 容易得多`
       */
      expect(
        prettyJson('{"a":1}'),
        '{\n  "a": 1\n}',
      );
    });

    test('★★★ 解析失败必须**原样返回**，不能抛异常', () {
      /*
       * 原版注释（照抄）：
       * > 尽量美化 JSON；解析失败就原样返回（用户手改坏了也能看到原文）
       *
       * ⚠️ 这条很关键：如果抛异常，用户**打开编辑弹窗的瞬间**就报错，
       *    他连自己错在哪都看不到（而错的那份 JSON 就在他面前）。
       *    这是"编辑功能比重新导入更好用"的核心 —— 半坏的配置能救。
       */
      const broken = '{"a": 1,,}';
      expect(
        () => prettyJson(broken),
        returnsNormally,
        reason: '★ 坏 JSON 不能抛异常（弹窗会打不开）',
      );
      expect(prettyJson(broken), broken, reason: '★ 必须原样返回，用户才能看到错在哪');
    });

    test('空串/空白原样返回（不是崩溃）', () {
      expect(prettyJson(''), '');
      expect(prettyJson('   '), '   ');
    });

    test('已经是格式化的 JSON 保持语义不变', () {
      const src = '{\n  "a": 1\n}';
      expect(jsonDecode(prettyJson(src)), jsonDecode(src));
    });
  });

  group('parseHeaders（原版 :1440）', () {
    test('空 / 纯空白 → null（= 无自定义头）', () {
      /*
       * 原版：`const t = text.trim(); if (!t) return undefined;`
       *
       * 返回 null 而不是空 Map：Rust 侧是
       * `headers: Option<HashMap<String,String>>` —— 传缺省
       * 与传空对象语义不同（前者走"没头"，后者会覆盖成空）。
       */
      expect(parseHeaders(''), isNull);
      expect(parseHeaders('   \n  '), isNull);
    });

    test('★ 合法对象 → Map<String,String>', () {
      final h = parseHeaders('{"Authorization": "Bearer xxx", "X-A": 1}');
      expect(h, isNotNull);
      expect(h!['Authorization'], 'Bearer xxx');
      // 非字符串值会被 stringify（后端要 HashMap<String,String>）
      expect(h['X-A'], '1');
    });

    test('★★ 非法 JSON → 报错，且文案与原版逐字一致', () {
      /*
       * 原版：
       * ```ts
       * try { v = JSON.parse(t); }
       * catch { throw new Error("自定义头不是合法 JSON"); }
       * if (!v || typeof v !== "object" || Array.isArray(v))
       *   throw new Error('自定义头必须是 JSON 对象，如 {"Authorization":"Bearer xxx"}');
       * ```
       */
      expect(
        () => parseHeaders('{not json'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            '自定义头不是合法 JSON',
          ),
        ),
      );
    });

    test('★★ 是数组/标量 → 报错（必须是对象）', () {
      // `Array.isArray(v)` 那条守卫
      expect(
        () => parseHeaders('[1,2]'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('必须是 JSON 对象'),
          ),
        ),
      );
      expect(() => parseHeaders('123'), throwsA(isA<FormatException>()));
      expect(() => parseHeaders('"str"'), throwsA(isA<FormatException>()));
    });
  });

  group('导入模板（原版 :837 TEMPLATE）', () {
    test('★★★ 模板必须是**合法 JSON**（用户点「填入模板」后要能导入）', () {
      /*
       * 这是模板唯一的硬要求 —— 它在原版是个 JS 模板字符串，
       * 搬到 Dart 要转义 `$`（Dart 的字符串插值符），
       * 转义漏一个就变成非法 JSON，而**用户点一下才发现**。
       */
      expect(
        () => jsonDecode(kDeclarativeTemplate),
        returnsNormally,
        reason: '★ 模板必须是合法 JSON —— 否则「填入模板」直接导入失败',
      );
    });

    test('★★ 模板的 JSONPath 必须是字面 `\$.xxx`（\$ 没被 Dart 吃掉）', () {
      /*
       * ⚠️ 踩坑记录：Dart 单引号字符串里 `$` 是插值符。
       * 写 `"items": "$.class"` 会被当成插值 → 编译错误或变量未定义。
       * 必须写 `"\$.class"`。
       *
       * 而**如果**有人为了省事写成 `\${...}` 或漏了转义，
       * 解析出来就不是 `$.class` —— 用户照抄的源会解析失败。
       */
      final m = jsonDecode(kDeclarativeTemplate) as Map<String, dynamic>;
      final endpoints = m['endpoints'] as Map<String, dynamic>;
      final list = endpoints['list'] as Map<String, dynamic>;
      final map = list['map'] as Map<String, dynamic>;

      expect(map['items'], '\$.list', reason: '★ JSONPath 的 \$ 必须保留字面量');
      expect(map['id'], '\$.vod_id');
    });

    test('模板的占位符写法与原版一致（{category}/{page}/{id}/{keyword}）', () {
      /*
       * 这些占位符就是声明式源的**参数契约** —— 用户照着改。
       * 改错一个词，用户填的源会静默解析失败。
       */
      for (final ph in ['{category}', '{page}', '{id}', '{keyword}']) {
        expect(
          kDeclarativeTemplate.contains(ph),
          isTrue,
          reason: '模板缺占位符 $ph（原版如此）',
        );
      }
    });

    test('模板含原版的四个端点（categories/list/detail/search）', () {
      final m = jsonDecode(kDeclarativeTemplate) as Map<String, dynamic>;
      final endpoints = (m['endpoints'] as Map).keys.toSet();
      expect(endpoints, containsAll(['categories', 'list', 'detail', 'search']));
    });
  });

  group('ProviderImportSeed.fromJson（Rust PersistedProvider 契约）', () {
    test('★ declarative 形态', () {
      /*
       * Rust（`model.rs:1040`）：
       * ```rust
       * #[serde(tag = "kind", rename_all = "snake_case")]
       * pub enum PersistedProvider {
       *     Declarative { id: String, json: String },
       *     Http { id, base_url, #[serde(default)] headers },
       * }
       * ```
       */
      final s = ProviderImportSeed.fromJson({
        'kind': 'declarative',
        'id': 'demo',
        'json': '{"id":"demo"}',
      });
      expect(s, isNotNull);
      expect(s!.isDeclarative, isTrue);
      expect(s.isHttp, isFalse);
      expect(s.id, 'demo');
      expect(s.json, '{"id":"demo"}');
    });

    test('★ http 形态（含 headers）', () {
      final s = ProviderImportSeed.fromJson({
        'kind': 'http',
        'id': 'x',
        'base_url': 'http://127.0.0.1:8787',
        'headers': {'Authorization': 'Bearer t'},
      });
      expect(s, isNotNull);
      expect(s!.isHttp, isTrue);
      expect(s.baseUrl, 'http://127.0.0.1:8787');
      expect(s.headers['Authorization'], 'Bearer t');
    });

    test('★★ http 形态缺 headers → 空 Map（后端 `#[serde(default)]`）', () {
      /*
       * Rust 侧 headers 有 `#[serde(default)]` —— 所以**真的会缺**。
       * 不兜底会 NPE，而症状是"打开编辑弹窗就崩"。
       */
      final s = ProviderImportSeed.fromJson({
        'kind': 'http',
        'id': 'x',
        'base_url': 'http://a',
      });
      expect(s, isNotNull);
      expect(s!.headers, isEmpty);
    });

    test('★★★ kind 不认识 → null（不许默认当成声明式）', () {
      /*
       * 为什么要**正向列举** kind 而不是"默认当声明式"：
       * 后端将来加第三种形态时，误当成声明式会让用户看到一个
       * **空白的 JSON 编辑框**，点保存就把原源覆盖成一个坏配置。
       *
       * 返回 null → UI 不给「编辑」按钮 —— 这是**安全的失败方式**
       *（原版 `canEdit` 的注释也是这个思路：点了报错比不放更糟）。
       */
      expect(
        ProviderImportSeed.fromJson({'kind': 'wasm', 'id': 'x', 'json': '{}'}),
        isNull,
      );
      expect(
        ProviderImportSeed.fromJson({'kind': 'declarative', 'id': 'x'}),
        isNull,
        reason: 'declarative 缺 json → null（不是空串）',
      );
      expect(
        ProviderImportSeed.fromJson({'kind': 'http', 'id': 'x'}),
        isNull,
        reason: 'http 缺 base_url → null',
      );
      expect(ProviderImportSeed.fromJson({'id': 'x'}), isNull, reason: '缺 kind');
      expect(ProviderImportSeed.fromJson({'kind': 'declarative'}), isNull,
          reason: '缺 id');
    });
  });

  group('ProviderImportDone.toast（原版 flash 文案）', () {
    test('★ 声明式：导入 / 保存 —— **不**带契约版本', () {
      /*
       * 原版 `doImport`：
       * ```ts
       * flash(wasEditing ? `已保存「${m.name}」` : `已导入「${m.name}」`);
       * ```
       *
       * ⚠️ 声明式源**没有契约版本**这个概念（契约是 HTTP 源的）。
       *    它 manifest 里的 `version` 是用户在 JSON 里自己写的，
       *    拼上去会显示成"契约 v1.0" —— 那是误导。
       */
      const a = ProviderImportDone(
        name: '示例站',
        wasEditing: false,
        version: '1.0',
      );
      expect(a.toast, '已导入「示例站」');

      const b = ProviderImportDone(
        name: '示例站',
        wasEditing: true,
        version: '1.0',
      );
      expect(b.toast, '已保存「示例站」');
    });

    test('★ HTTP：安装 / 保存 —— 带「（契约 v…）」', () {
      /*
       * 原版 `doInstallHttp`：
       * ```ts
       * flash(wasEditing
       *   ? `已保存「${m.name}」（契约 v${m.api_version}）`
       *   : `已安装「${m.name}」（契约 v${m.api_version}）`);
       * ```
       */
      const a = ProviderImportDone(
        name: '我的服务',
        wasEditing: false,
        version: '1',
        isHttp: true,
      );
      expect(a.toast, '已安装「我的服务」（契约 v1）');

      const b = ProviderImportDone(
        name: '我的服务',
        wasEditing: true,
        version: '1',
        isHttp: true,
      );
      expect(b.toast, '已保存「我的服务」（契约 v1）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ★★ 真渲染测试：编辑回填（不碰 FFI，却能证明"看到的就是原配置"）
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 为什么这一段必须用**真 widget 渲染**而不是静态断言
  //
  // 「编辑」的全部价值就是**回填**：用户能看到自己原来的 JSON / URL / 头。
  // 静态断言只能证明"代码里调了 prettyJson"，**证明不了它显示出来**。
  // 而回填的失败方式恰恰是静默的：
  // ```text
  // 忘了 prefill      → 弹窗是空的，用户以为配置丢了（其实后端有）
  // 忘了 prettyJson   → 一行压缩 JSON，用户没法改（这正是加编辑的起因）
  // 忘了格式化 headers → 用户看到 "{}" 以为"这里有配置"
  // ```
  // 这三种都不会报错，只能靠"渲染出来的文本对不对"来抓。
  //
  // ⚠️ 弹窗本身**不依赖 FFI** —— `initState` 只做纯文本预处理
  //    （`prettyJson` / `_formatHeaders`），API 调用只发生在点提交时。
  //    所以能安全地 `pumpWidget` 它（这一点值得记：把 I/O 挡在构造之外，
  //    测试才可能不依赖真核心）。
  group('编辑回填（真渲染）', () {
    /// 把弹窗挂起来（外面必须有 MaterialApp —— 否则 Theme/Navigator 都没有）
    Future<void> pumpDialog(
      WidgetTester tester, {
      ProviderImportSeed? seed,
      String? name,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProviderImportDialog(seed: seed, editingName: name),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('★★★ 编辑声明式源：标题/模式锁/回填的 JSON 都要对', (tester) async {
      /*
       * 原版 `edit()`（:1365）的声明式分支：
       * ```ts
       * editing.value = p;
       * importMode.value = "declarative";
       * importJson.value = prettyJson(cfg.json);   // ← 格式化后再填
       * showImport.value = true;
       * ```
       */
      const rawJson =
          '{"id":"demo","name":"示例站","base":"https://api.example.com"}';
      final seed = ProviderImportSeed.fromJson({
        'kind': 'declarative',
        'id': 'demo',
        'json': rawJson,
      })!;

      await pumpDialog(tester, seed: seed, name: '示例站');

      // ① 标题带源名（用户要知道在编辑哪个）
      expect(find.text('编辑「示例站」'), findsOneWidget);

      // ② 编辑态**锁住**接入方式切换 —— 原版 :2746 的注释：
      //    「源的类型是它的身份，改类型等于换一个源，不是「编辑」」
      expect(
        find.text('HTTP Provider'),
        findsNothing,
        reason: '★ 编辑态不能出现接入方式切换（原版明确锁住）',
      );
      expect(find.textContaining('正在编辑声明式源'), findsOneWidget);

      // ③ ★ 回填且**已格式化**（不是压缩成一行）
      final field = tester.widget<TextField>(find.byType(TextField));
      final shown = field.controller!.text;
      expect(shown, contains('"id": "demo"'), reason: '★ 回填的必须是原始 JSON');
      expect(shown, contains('\n'), reason: '★ 必须格式化过（压缩成一行没法改）');
      expect(
        jsonDecode(shown),
        jsonDecode(rawJson),
        reason: '★ 格式化不能改变语义',
      );

      // ④ 编辑态的按钮是「保存」，且**没有**「填入模板」
      //    （原版 :2788 `v-if="!isEditing"`）
      expect(find.text('保存'), findsOneWidget);
      expect(find.text('填入模板'), findsNothing);
      expect(find.text('导入'), findsNothing);
    });

    testWidgets('★★★ 编辑 HTTP 源：base_url + 格式化后的 headers 回填', (tester) async {
      /*
       * 原版 `edit()` 的 else 分支：
       * ```ts
       * importMode.value = "http";
       * httpBase.value = cfg.base_url;
       * httpHeadersJson.value = Object.keys(cfg.headers || {}).length
       *   ? JSON.stringify(cfg.headers, null, 2) : "";
       * ```
       * 原版注释说明**为什么自定义头必须可改**：
       * > 原实现只能装不能改，用户换了令牌就得删源重建 ——
       * > 而 base_url 与其它头会一起丢掉（这正是加编辑功能的起因之一）。
       */
      final seed = ProviderImportSeed.fromJson({
        'kind': 'http',
        'id': 'x',
        'base_url': 'http://127.0.0.1:8787',
        'headers': {'Authorization': 'Bearer TOKEN123'},
      })!;

      await pumpDialog(tester, seed: seed, name: '我的服务');

      expect(find.text('编辑「我的服务」'), findsOneWidget);
      expect(find.textContaining('正在编辑HTTP 插件'), findsOneWidget);

      // 两个输入框：base_url 在前、headers 在后
      final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
      expect(fields.length, 2, reason: 'HTTP 表单应有 URL + headers 两个输入框');
      expect(fields[0].controller!.text, 'http://127.0.0.1:8787');
      expect(
        fields[1].controller!.text,
        contains('Bearer TOKEN123'),
        reason: '★ 头必须回填 —— 否则用户改令牌还得重建源',
      );
      // 格式化过（不是挤成一行）
      expect(fields[1].controller!.text, contains('\n'));
    });

    testWidgets('★★★ HTTP 源 headers 为空 → 输入框留空（不是 "{}"）', (tester) async {
      /*
       * 原版：`Object.keys(cfg.headers || {}).length ? ... : ""`
       *
       * ⚠️ 给 `{}` 会让用户以为"这里有配置"，其实什么都没有；
       *    留空才符合"没填就是没有"的语义。
       */
      final seed = ProviderImportSeed.fromJson({
        'kind': 'http',
        'id': 'x',
        'base_url': 'http://a',
        'headers': <String, String>{},
      })!;

      await pumpDialog(tester, seed: seed, name: 'x');
      final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
      expect(fields[1].controller!.text, isEmpty,
          reason: '★ 空头要留空，不能显示成 "{}"');
    });

    testWidgets('★★ 新增态：接入方式可切 + 有「填入模板」+ 按钮是「导入」', (tester) async {
      /*
       * 原版 `openAdd()`（:1413）—— 与编辑态**恰好相反**：
       * ```text
       * 显示 tabs      （编辑态锁住）
       * 有「填入模板」  （编辑态没有）
       * 按钮「导入」    （编辑态是「保存」）
       * 输入框全空      （编辑态回填）
       * ```
       * 这条与上面两条**成对**：任何一条挂了都说明"编辑/新增"被搞混了。
       */
      await pumpDialog(tester);

      expect(find.text('导入声明式源'), findsOneWidget);
      // 两种接入方式都在
      expect(find.text('声明式 JSON'), findsOneWidget);
      expect(find.text('HTTP Provider'), findsOneWidget);
      // 新增态专属
      expect(find.text('填入模板'), findsOneWidget);
      expect(find.text('导入'), findsOneWidget);
      expect(find.textContaining('正在编辑'), findsNothing);

      // ★ 输入框必须是**空的**（原版 `openAdd` 的显式清空）
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, isEmpty,
          reason: '★ 新增态不能带上一次编辑的内容（否则会覆盖掉同 id 的源）');
    });

    testWidgets('★★★ 「编辑 A → 关闭 → 点新增」不能把 A 的配置带进来', (tester) async {
      /*
       * 原版 `openAdd()` 的注释（照抄）：
       * > ⚠️ 必须显式清空：否则「编辑 A → 关闭 → 点添加」会把 A 的配置
       * >    带进来，用户以为在新建，实际会覆盖掉 A（同 id 覆盖语义）。
       *
       * 这条是**真 bug 的回归测试** —— 它会静默覆盖用户已有的源。
       *
       * # ⚠️ 必须走**真实的 showDialog 路径**（我第一版写错了，记下来）
       *
       * 我第一版用两次 `pumpWidget(ProviderImportDialog(seed: ...))` 模拟
       * "先编辑再新增"，结果**假失败**：
       * ```text
       * 第二次 pumpWidget 传的是同一个 widget 类型且没换 key
       * → Flutter **复用同一个 Element/State**
       * → initState 不会重跑 → controller 还是 A 的内容
       * ```
       * 但生产路径上每次 `showDialog` 都 **push 一个新路由**，
       * Element 是全新的，`initState` 必然执行。
       *
       * 所以这个测试用了 `showAdd` / `showEdit`（真路由），
       * 而不是自己拼 widget —— 测的是**用户实际走的那条路**。
       */
      final seed = ProviderImportSeed.fromJson({
        'kind': 'declarative',
        'id': 'A',
        'json': '{"id":"A","name":"源A"}',
      })!;

      // 宿主：两个按钮，分别触发真实的 showEdit / showAdd（与设置页一致）
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Column(
                children: [
                  ElevatedButton(
                    onPressed: () => ProviderImportDialog.showEdit(
                      ctx,
                      seed: seed,
                      name: '源A',
                    ),
                    child: const Text('EDIT_A'),
                  ),
                  ElevatedButton(
                    onPressed: () => ProviderImportDialog.showAdd(ctx),
                    child: const Text('ADD'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // ── ① 先「编辑 A」→ 应回填 ──
      await tester.tap(find.text('EDIT_A'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        contains('源A'),
        reason: '编辑态必须回填 A 的配置',
      );

      // ── ② 关闭弹窗（点「取消」—— 原版 closeImport）──
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(ProviderImportDialog), findsNothing,
          reason: '取消后弹窗应关闭');

      // ── ③ 再点「新增」→ ★ 必须是空的 ──
      await tester.tap(find.text('ADD'));
      await tester.pumpAndSettle();

      expect(find.byType(ProviderImportDialog), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
        reason: '★★★ A 的配置不能被带进新增流程（会静默覆盖 A）',
      );
      expect(find.text('源A'), findsNothing,
          reason: '★★★ 新增态的标题里不该出现 A 的名字');
      expect(find.text('导入声明式源'), findsOneWidget);
    });

    testWidgets('★★ 导入按钮的可用性跟随输入（空 → 禁用）', (tester) async {
      /*
       * 原版：`:disabled="!importJson.trim()"` / `":disabled="!httpBase.trim()"`
       *
       * 空输入时按钮必须**禁用**（不是"点了报错"）——
       * 让用户一眼看出"还差点东西"。
       */
      await pumpDialog(tester);

      FilledButton submitBtn() => tester.widget<FilledButton>(
            find.widgetWithText(FilledButton, '导入'),
          );
      expect(submitBtn().onPressed, isNull, reason: '★ 空输入时「导入」必须禁用');

      // 填入模板后应该可点
      await tester.tap(find.text('填入模板'));
      await tester.pumpAndSettle();
      expect(submitBtn().onPressed, isNotNull,
          reason: '★ 填入模板后「导入」应可用（模板本身是合法 JSON）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  API 层：包装的参数名必须与 Rust 契约一致
  // ═══════════════════════════════════════════════════════════════════
  group('sourin_api.dart 的命令与参数名', () {
    late String code;

    setUpAll(() {
      code = _code(File('lib/core/sourin_api.dart').readAsStringSync());
    });

    test('★★ getProviderImportSeed 用 get_provider_config + 参数 id', () {
      /*
       * Rust/FFI（`ffi.rs:1248`）：
       * ```rust
       * "get_provider_config" => { let id = a.str("id")?; ... }
       * ```
       * 参数名写错 → `a.str("id")` 报错，或（更糟）静默拿到默认值。
       */
      expect(code.contains("'get_provider_config'"), isTrue);
      expect(code.contains("{'id': id}"), isTrue);
    });

    test('★★★ 必须用 jmapOrNull 而不是 jmap（后端返回 Option）', () {
      /*
       * 后端签名是 `Result<Option<PersistedProvider>, String>` ——
       * **内置源返回 JSON null**，那是正常情况不是错误。
       *
       * `jmap` 对 null 会抛「期望对象，实际收到 Null」，
       * 症状是"点内置源的编辑就报错"。
       *
       * ⚠️ 这个坑在本文件里已经踩过**三次**
       *（getProgress / getSkipMarker / providerSession）——
       *    所以这里专门钉一条断言。
       */
      final fn = code.substring(
        code.indexOf('getProviderImportSeed'),
        code.indexOf('getProviderImportSeed') + 400,
      );
      expect(
        fn.contains('jmapOrNull(r)'),
        isTrue,
        reason: '★ Option 返回必须用 jmapOrNull，用 jmap 会在 null 时抛异常',
      );
      expect(
        fn.contains('jmap(r)'),
        isFalse,
        reason: '★ 不能退回 jmap',
      );
    });

    test('★ 四个命令包装都存在（原版 index.ts 的对照）', () {
      /*
       * ⚠️ 更正一条审计措辞：这 4 个命令的**包装一直都有**，
       *    缺的是 UI 入口。这里断言包装在，是为了防止
       *    "补 UI 时误删/改名"。
       * ```text
       * 原版 src/api/index.ts:99   order()             → get_provider_order
       * 原版 src/api/index.ts:102  importDeclarative() → import_declarative_provider
       * 原版 src/api/index.ts:111  installHttp()       → install_http_provider
       * 原版 src/api/index.ts:125  config()            → get_provider_config
       * ```
       */
      for (final cmd in [
        "'get_provider_order'",
        "'import_declarative_provider'",
        "'install_http_provider'",
        "'get_provider_config'",
        "'health_sweep'",
        "'reload_plugins'",
      ]) {
        expect(code.contains(cmd), isTrue, reason: '缺命令包装 $cmd');
      }
    });
  });
}
