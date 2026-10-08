
// ═══════════════════════════════════════════════════════════════════════
//  UI 契约（task-12）—— 静态断言
// ═══════════════════════════════════════════════════════════════════════
//
// 这个文件锁住的是**源码里的分支条件**，不是渲染结果：
//
// ```text
// ① ★★ 没有订阅链接 → 「检测更新」入口点不动
//      —— 与 settings_page.dart 的 `onPluginUpdate == null` 同一条
// ② 三种结局都不许静默：没链接 / 失败 / 有结果 各有各的文案
// ③ 「已是最新」只可能出现在**真的查成功且无变化**那一支
// ④ 一键更新**绝不自动删**（deleteMissing 默认 false，要用户显式勾）
// ```
//
// ⚠️ 为什么是静态断言而不是 widget 测试：
//    `TvboxUpdateDialog` 里的按钮回调会直接走 `SourinApi`（真核心 / FFI），
//    widget 测试里点一下就抛 `MissingPluginException`；
//    而本功能最关键的契约（没有链接就不给入口）本来就是
//    **源码里的条件分支**，读源码断言比 pump 一个假弹窗更直接。
//    真正的端到端（含真 HTTP）在 Rust 侧 `mod task12_subscription` 里跑。
//
// ⚠️ 断言前必须**剥注释**：本文件写了大量注释解释为什么不画按钮、
//    为什么默认不删，里面全都提到了这些标识符 ——
//    不剥注释的话，把功能删掉测试照样绿（假绿）。这个坑本项目踩过 7 次。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/ui/widgets/tvbox_source_panel.dart';

void main() {
  late String src;

  setUpAll(() {
    src = File('lib/ui/widgets/tvbox_source_panel.dart').readAsStringSync();
  });

  /// 去掉注释后的源码（`//` 行、`///` 文档行、块注释起始行）
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

  /// 弹窗状态类体（切片终点用**代码**锚点，不能用注释文本）
  String dialogBody() {
    final code = codeOnly();
    final start = code.indexOf('class _TvboxUpdateDialogState');
    expect(start > 0, isTrue, reason: '应能找到 _TvboxUpdateDialogState');
    return code.substring(start);
  }

  group('① ★★ 没有订阅链接就没有可用的「检测更新」入口', () {
    test('★★★ 检测按钮的 enabled 条件含 _hasLink', () {
      /*
       * 这是整个功能最关键的一条。
       *
       * 用户直接贴 JSON 文本导入的源**没有来源链接**
       *（`tvbox-sources.json` 里那条 sourceUrl 是 null）→ 无从查新版。
       * 对这类源必须**点不动**入口 —— 能点却没反应等于假装有能力。
       */
      final body = dialogBody();
      expect(
        RegExp(r'onPressed:\s*\(busy\s*\|\|\s*!_hasLink\)\s*\?\s*null')
            .hasMatch(body),
        isTrue,
        reason: '★ 检测按钮必须在 !_hasLink 时禁用',
      );
      expect(body.contains("'检测更新'"), isTrue);
    });

    test('★★ 没有链接时如实说明，且不说已是最新', () {
      final body = dialogBody();
      expect(body.contains("'没有订阅链接，查不了更新'"), isTrue,
          reason: '★ 如实说查不了，而不是留白或假装查过了');
      expect(
        body.contains("'这个源是贴文本导入的，没有订阅链接 —— 查不了更新。填入当初的配置地址即可。'"),
        isTrue,
      );
    });

    test('★ 入口的开关是 _hasLink（= sourceUrl 非空），不是别的字段', () {
      final body = dialogBody();
      expect(
        body.contains("_hasLink = (widget.sourceUrl ?? '').trim().isNotEmpty"),
        isTrue,
        reason: '★ 判据必须是「后端真的存了链接」，不是 UI 里临时输入的内容',
      );
    });
  });

  group('② 三种结局都有文案，一个都不静默', () {
    test('★★★ !it.ok 必须走失败分支（不能落到已是最新）', () {
      /*
       * 本功能唯一不能犯的错：把「查失败」显示成「已是最新」。
       * 那样用户以为源没更新，实际上我们根本没查到 —— 比不显示更糟。
       */
      final body = dialogBody();
      expect(body.contains('if (!it.ok) {'), isTrue);
      expect(body.contains('return _failLine(colors, it.error);'), isTrue,
          reason: '★★ 失败分支必须**先于**成功分支返回');
      final iFail = body.indexOf('if (!it.ok) {');
      final iOk = body.indexOf('final text = it.hasChanges');
      expect(iFail > 0 && iOk > iFail, isTrue,
          reason: '★★ 失败判断必须在成功文案之前（顺序反了就会把失败说成最新）');
    });

    test('★★ 后端没给原因时也如实说没给原因，不编一个', () {
      final body = dialogBody();
      expect(body.contains("'检测失败（后端没有给出原因）'"), isTrue);
      expect(body.contains("'检测失败：\$why'"), isTrue);
    });

    test('★★ 已是最新只出现在查成功且无变化那一支', () {
      final body = dialogBody();
      final i = body.indexOf("'已是最新（远端 \${it.remoteConvertible} 个可转换站点）'");
      expect(i > 0, isTrue, reason: '应有已是最新文案');
      final seg = body.substring(i - 160 < 0 ? 0 : i - 160, i);
      expect(seg.contains('it.hasChanges'), isTrue,
          reason: '★★ 已是最新必须挂在 it.hasChanges 的 false 支上');
    });

    test('★ 还没检测过（_check == null）与检测失败是两种文案', () {
      final body = dialogBody();
      expect(body.contains("'还没检测过 —— 点「检测更新」才会联网'"), isTrue);
      expect(body.contains('if (it == null) {'), isTrue,
          reason: '★ null（还没查）不能与 !ok（查了失败）混成一个分支');
    });
  });

  group('③ 一键更新：默认不删、要用户显式勾', () {
    test('★★★ _deleteMissing 初值必须是 false', () {
      /*
       * 配置作者临时删掉一个站、过两天又加回来是常事。
       * 默认删 = 用户点一下「应用更新」就**不可逆地**丢本地数据
       *（含他手动改过的启用状态/排序）。
       */
      final body = dialogBody();
      expect(body.contains('bool _deleteMissing = false;'), isTrue,
          reason: '★★ 默认必须是只报告不删');
      expect(body.contains('bool _applyNew = true;'), isTrue,
          reason: '新增站点默认加入（用户点更新就是想拿到新站）');
    });

    test('★★ 两个开关的文案写明了后果，不是光秃秃一个勾', () {
      final body = dialogBody();
      expect(body.contains("label: '同时加入新增站点'"), isTrue);
      expect(body.contains("label: '同时删除远端已消失的站'"), isTrue);
      expect(body.contains("'默认不删 —— 配置作者临时删站又加回来是常事'"), isTrue,
          reason: '★ 为什么默认不删要写在界面上，不能只写在代码注释里');
    });

    test('★★ 更新按钮绝不自动触发 —— 只有点了 _applyUpdate 才动', () {
      final body = dialogBody();
      expect(body.contains('onPressed: _updating ? null : _applyUpdate,'), isTrue);
      final i0 = body.indexOf('void initState()');
      expect(i0 > 0, isTrue, reason: '应有 initState');
      final init = body.substring(i0, body.indexOf('void dispose()'));
      expect(init.contains('checkTvboxUpdates'), isFalse,
          reason: '★★ 打开弹窗不能自动联网（检测是用户点的）');
      expect(init.contains('updateTvboxSource'), isFalse,
          reason: '★★ 更不能自动应用更新');
    });
  });

  group('④ 结果如实报，不省字段', () {
    test('★ 更新结果里新增/变更/删除/失败/未应用都要出现', () {
      final body = dialogBody();
      for (final s in [
        "'新增 \${r.added.length} · 变更 \${r.changed.length} · 删除 \${r.deleted.length}'",
        "'有 \${r.failed.length} 个新站探测失败，没有注册'",
        "'按你的选择跳过了 \${r.notApplied.length} 个新增站'",
      ]) {
        expect(body.contains(s), isTrue, reason: '缺了这一条：\$s');
      }
    });

    test('★ 远端消失的站按删了/没删分别措辞', () {
      final body = dialogBody();
      expect(body.contains("'远端已消失 \${r.removed.length} 个站：只报告，没有删'"), isTrue);
      expect(body.contains("'远端已消失 \${r.removed.length} 个站，其中 \${r.deleted.length} 个已按你的选择删除'"), isTrue);
    });

    test('★★ 多仓时如实说不能直接更新，并给出子仓让用户挑', () {
      final body = dialogBody();
      expect(body.contains("'远端现在是一份「多仓」配置（只有 urls，没有 sites），不能直接更新。'"), isTrue,
          reason: '★ 多仓不能假装能一键更新');
      expect(body.contains('for (final repo in it.repos.take(20))'), isTrue);
    });
  });

  group('⑤ 项目铁律', () {
    test('★★★ 新文件禁止 import package:flutter/material.dart', () {
      expect(src.contains('package:flutter/material.dart'), isFalse,
          reason: '★ 会与 material_ui 串台（本项目实测对比度掉到 1.16:1）');
      expect(src.contains('package:material_ui/material_ui.dart'), isTrue);
    });

    test('★★ 面板只依赖 SourinApi，不反向依赖设置页', () {
      final code = codeOnly();
      expect(code.contains("import '../../core/sourin_api.dart';"), isTrue);
      expect(code.contains('settings_page'), isFalse,
          reason: '★ 自包含：设置页只负责打开它一行');
    });

    test('★ 面板不自己 showDialog（由静态 show 收口 + 统一入口 showAppDialog）', () {
      final code = codeOnly();
      /*
       * ★★★ task-104：全项目的对话框统一走 `showAppDialog`（唯一入口）
       *
       * 语义**没放松**，反而更严：
       * ```text
       * 改前：只禁「多一个 showDialog<」 ⇒ 有人写 showDialog( 不带泛型就绕过去了
       * 改后：showDialog 一次都不许出现（归零）
       *       且必须有 1 处 showAppDialog<bool>( —— 正是静态 show 那一处
       * ```
       * 为什么归零是对的：showAppDialog 就是 showDialog 的**唯一**封装，
       * 动效（animationStyle）在那一处统一接上（见 overlay_motion.dart）。
       */
      final raw = RegExp(r'\bshowDialog<').allMatches(code).length;
      expect(raw, 0, reason: '★ 面板里不许再直接调 showDialog —— 统一走 showAppDialog');
      final app = RegExp(r'\bshowAppDialog<').allMatches(code).length;
      expect(app, 1, reason: '★ 只有 TvboxUpdateDialog.show 一处（统一入口）');
    });
  });
}
