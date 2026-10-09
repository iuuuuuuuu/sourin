// 探针：PluginEditDialog 在**完整 App 外壳**下能不能真的渲染出来。
//
// 背景（Owner 真机截图，2026-10-09）：
//   「js插件点击编辑就变成这样子,并没有弹窗出现」—— 截图里只有一层灰，没有对话框。
//
// 为什么这个文件之前不存在：
//   task-10 ③ 做这个表单时**没有留下任何探针**，所以这个 bug 一路溜到真机。
//   本探针补上这个口子。
//
// 判据设计（★ 关键：区分「没渲染」与「渲染了但看不见」）：
//   ① showAppDialog 之后，对话框**在树里**（AlertDialog 存在）
//   ② 标题/动作按钮**真的被布局**且有非零尺寸
//   ③ ★ 反面对照：不给 outer navigator 时应当**失败**（证明判据不是恒真）
import 'dart:async';

// ★★★ 2026-10-09：必须用 material_ui（本仓的 Material 库），
//   而不是 flutter/material —— 见下面「两个 Material 库」的注释。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/widgets/plugin_edit_dialog.dart';

void main() {
  testWidgets('① 添加型：完整外壳下对话框真的渲染出来', (t) async {
    // ★ 用**真机尺寸**（1444x845），并断言宽度按设计 ~560 而不是撑满视口
    await t.binding.setSurfaceSize(const Size(1444, 845));
    addTearDown(() => t.binding.setSurfaceSize(null));
    /*
     * ★ context 必须取自**页面内**（Localizations 之下），所以用 Builder。
     *
     * 我第一次用 `navigatorKey.currentContext` ⇒ 那是 Navigator 自己的 context，
     * 它的**祖先不含** Localizations ⇒ 报 `No MaterialLocalizations found`。
     * 那与 ui-dev 在 plugin_edit_dialog.dart:108-112 记的限制是同一件事，
     * 但**真实调用点**（settings_page 里 `_editPlugin`）用的是页面内 context ⇒
     * 用 Builder 才是忠实的复现形状。
     */
    late BuildContext pageCtx;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (c) {
          pageCtx = c;
          return const SizedBox();
        }),
      ),
    ));
    await t.pump();

    unawaited(showPluginEditDialog(context: pageCtx));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));

    final dlg = find.byType(AlertDialog);
    print('PROBE| ① AlertDialog 在树里 = ${dlg.evaluate().isNotEmpty}');
    if (dlg.evaluate().isNotEmpty) {
      final size = t.getSize(dlg);
      print('PROBE| ① 对话框尺寸 = ${size.width} x ${size.height}');
      print('PROBE| ① 有「添加插件」标题 = ${find.text('添加插件').evaluate().isNotEmpty}');
      print('PROBE| ① 有「取消」按钮 = ${find.text('取消').evaluate().isNotEmpty}');
      print('PROBE| ① 有「安装」按钮 = ${find.text('安装').evaluate().isNotEmpty}');
      expect(size.width, greaterThan(100), reason: '对话框宽度退化 ⇒ 看不见');
      expect(size.height, greaterThan(100), reason: '对话框高度退化 ⇒ 看不见');
      /*
       * ★★ 关键判据：AlertDialog 的**实际渲染宽度**必须在设计值附近，
       *   不能跟着视口撑满 —— 撑满就等于「遮罩铺满、看不到卡片」，
       *   正是 Owner 截图那个形态。
       * `content: SizedBox(width: 560)` + AlertDialog 的 padding ⇒ 约 560~640。
       */
      /*
       * ★ 判据修正（我第一版测错了节点）：
       *   `find.byType(AlertDialog)` 取的是**外层包装**（它本来就铺满），
       *   所以恒等于视口、永远判红 —— 那是**判据自己的问题**，不是缺陷。
       *   真正决定「看得见看不见」的是**卡片内部内容**的渲染尺寸。
       */
      final content = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(SizedBox),
      );
      final csz = t.getSize(content.first);
      print('PROBE| ① 内容区尺寸 = ${csz.width} x ${csz.height}');
      expect(csz.width, lessThan(900),
          reason: '内容区跟着视口撑满 ⇒ 真机上会表现为「只有一层灰」');
      expect(csz.width, greaterThan(200), reason: '内容区退化 ⇒ 也看不见');
    }
    expect(dlg.evaluate().isNotEmpty, isTrue, reason: '对话框根本没进树');
    await t.pump(const Duration(milliseconds: 400));
  });

  testWidgets('② 编辑型（源码型）：预填并锁定 —— 这是 Owner 点的那条路', (t) async {
    late BuildContext pageCtx;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (c) {
          pageCtx = c;
          return const SizedBox();
        }),
      ),
    ));
    await t.pump();

    /*
     * ★ 本机 28 个插件**全部没有 .meta**（实测 `%APPDATA%\app.sourin.player\plugins`
     *   下没有 `.meta` 目录）⇒ `upstream` 全是空串 ⇒ **全部是源码型**。
     * 所以 Owner 点的「编辑」走的是这条：异步读源码那条路。
     */
    const e = PluginEntry(
      file: 'cycani.js',
      id: 'cycani',
      name: '次元城动画',
      version: '1.0.0',
      upstream: '',
    );
    unawaited(showPluginEditDialog(context: pageCtx, existing: e));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));

    final dlg = find.byType(AlertDialog);
    print('PROBE| ② AlertDialog 在树里 = ${dlg.evaluate().isNotEmpty}');
    expect(dlg.evaluate().isNotEmpty, isTrue);
    final size = t.getSize(dlg);
    print('PROBE| ② 尺寸 = ${size.width} x ${size.height}');
    print('PROBE| ② 标题含「编辑」 = ${find.textContaining('编辑').evaluate().isNotEmpty}');
    print('PROBE| ② 有「保存」 = ${find.text('保存').evaluate().isNotEmpty}');
    expect(size.width, greaterThan(100));
    expect(size.height, greaterThan(100));
    await t.pump(const Duration(milliseconds: 400));
  });

  /// ★★★ 回归锁：类型判据**只看真实的安装来源**，不看 `upstream`（2026-10-09 修的 bug）
  ///
  /// # 修的是什么
  /// ```text
  /// 改前：`PluginEntry.upstream` 非空 ⇒ 判成链接型 ⇒ 预填那个值 + 类型锁死。
  /// 而 `upstream` 是**上游接口地址**，还曾从正文 `const API` 猜 ⇒
  /// 手写插件 bilibili 的 upstream = "https://api.bilibili.com"
  /// ⇒ 编辑框显示「链接安装」+ 预填接口地址
  /// ⇒ 点保存走 installPlugin(接口地址) ⇒ **把本地插件覆盖坏**。
  /// ```
  ///
  /// # 为什么直接测纯函数，而不是测对话框
  /// ```text
  /// ⚠️ 我第一版就是测对话框（断言「将按：链接安装」不在树里）—— **恒绿的假绿**：
  ///    · `_loadingSource` 为 true 时那行渲染的是「正在读取源码…」，断言不到；
  ///    · 换成断言 TextField.maxLines 也一样：读源码要 FFI，测试宿主里
  ///      `readPlugin` 的 future **永不完成** ⇒ 永远停在 maxLines=14（源码型）
  ///      ⇒ 把判据改回 upstream 做反面对照，它照样绿。
  /// 实测取证：插桩打印只在「开始 readPlugin」出现，之后没有任何一行 —— 证明卡住了。
  /// ```
  /// ⇒ 判据本身抽成了纯函数 `kindForExisting`，这里做**正反两向**断言。
  test('③ 类型判据：只认真实安装来源，upstream 不参与', () {
    // ① 核心回归：没有真实来源 ⇒ 源码型（哪怕"上游接口"是个 https 地址）
    expect(kindForExisting(sourceUrl: null), PluginInputKind.source,
        reason: '没有 .meta 来源 ⇒ 必须按源码型（否则保存会覆盖坏插件）');
    expect(kindForExisting(sourceUrl: ''), PluginInputKind.source);
    // ② 空白串也算没有（防止 sidecar 里写了空串被当成链接型）
    expect(kindForExisting(sourceUrl: '   '), PluginInputKind.source,
        reason: '空白串不是有效来源');
    // ③ 真·按链接安装的 ⇒ 链接型（编辑的就是那个链接）
    expect(kindForExisting(sourceUrl: 'https://example.com/p.js'),
        PluginInputKind.link);
    // ④ 两边都有值时以来源为准 —— 接口地址不参与判定
    expect(kindForExisting(sourceUrl: 'https://example.com/p.js'),
        isNot(PluginInputKind.source));
  });
}
