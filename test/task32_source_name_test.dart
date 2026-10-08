// ═══════════════════════════════════════════════════════════════════════
//  task-32：播放页 / 详情页显示「当前播放源」
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话
//
// > 播放页和详情页都不能看到当前播放源是哪一个
//
// # 本文件守什么（三条，各自独立）
//
// ```text
// ① 详情页：站点名 chip 真的渲染出来（在 hero__badges 那一行）
// ② 播放页：顶栏真的显示站点名，且**窄窗口下不挤压标题**
// ③ 共享查询：id → 名字，拿不到时**退回 id**（不是空串）
// ```
//
// # ★★★ 为什么"原版没有"这件事要写进测试
//
// 原版 `PlayerView.vue` / `DetailView.vue` **都不显示站点名**
// （全仓 grep `providerName` 的渲染点只有 LiveView/SearchView/弹层）。
// 而 `SourcePicker.vue:28-34` 的注释却声称
// 「**详情页标题区已展示过站名**」—— 实测那是**假的**（`hero__badges`
// 里只有后端 badges）。
//
// ⇒ 本功能是**超出原版功能对等**的增强，但它的**意图**有原版依据。
//   这条区分很重要：它决定"我们是发明 UI 还是兑现原版承诺"。
//   所以下面有一条断言把 `SourcePicker.vue` 那句话钉住 ——
//   如果将来有人"照原版删掉"这个 chip，那条断言会解释为什么不能删。
//
// # ⚠️ 断言前必须剥注释（铁律⑤）
//
// 本项目已踩 7 次"grep 命中注释导致假通过/假失败"。本文件里尤其危险：
// 我在源码注释里**大量引用了原版的那句话**（正是为了解释设计依据），
// 不剥注释的话，"源码里有没有 providerName 的渲染"这类断言
// 会匹配到注释而假通过。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/provider_name.dart';

/*
 * ⚠️ task-58：DetailPage 已不再是**独立页面**（Owner 裁决③），
 *    它现在由 MediaPage 嵌在下半屏（embedded: true）。
 *    ⇒ 本文件断言的契约**仍然成立**且仍在产品路径上（不是假绿）。
 *    而它被挂在正确的地方由 	est/t58_media_page_test.dart 的 group ③ 守着。
 */


// ═══════════════════════════════════════════════════════════════════════
//  剥注释（状态机 —— 与 episode_strip_test.dart 同一实现）
// ═══════════════════════════════════════════════════════════════════════

/// 剥掉 `//` 行注释与 `/* */` 块注释，**保留字符串字面量**
///
/// ⚠️ 保留字符串是必须的：Dart 的 import 路径、用户可见文案
///    （`'上一集'` / `'选集'`）都在字符串里。剥掉会让断言看不见它们
///    （VERIFY-LESSONS 铁律 17 记录过一次真实的坏仪器）。
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote;

  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';

    if (quote != null) {
      if (c == r'\') {
        out.write(c);
        if (next.isNotEmpty) {
          out.write(next);
          i += 2;
          continue;
        }
      }
      if (c == quote) quote = null;
      out.write(c);
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
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }

    if (c == '/' && next == '*') {
      i += 2;
      while (i < src.length &&
          !(src[i] == '*' && i + 1 < src.length && src[i + 1] == '/')) {
        if (src[i] == '\n') out.write('\n');
        i++;
      }
      i += 2;
      continue;
    }

    out.write(c);
    i++;
  }
  return out.toString();
}

String codeOf(String path) => stripComments(File(path).readAsStringSync());

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ⓪ 仪器自检 —— 先证明剥注释器是有效的（铁律 1：阳性对照）
  // ═══════════════════════════════════════════════════════════════════

  group('⓪ 仪器自检（阳性对照：证明断言不是恒过/恒失败）', () {
    test('★ stripComments 真的剥掉注释、保留字符串', () {
      const src = '''
// 注释里的 providerName
final a = 'providerName';  // 行尾注释
/* 块注释里的 providerName */
final b = 1;
''';
      final code = stripComments(src);

      // 注释里的必须消失（否则"源码里有没有"这类断言会假通过）
      expect(code.contains('注释里的'), isFalse, reason: '行注释要剥掉');
      expect(code.contains('块注释里的'), isFalse, reason: '块注释要剥掉');

      // ★ 字符串里的必须留下（import 路径 / 用户文案都在字符串里）
      expect(code.contains("'providerName'"), isTrue,
          reason: '★ 字符串字面量必须保留 —— 剥掉会让断言看不见 import '
              '与用户文案（铁律 17 记录过这个坏仪器）');

      // 行数要能对上（块注释里的换行要保留，否则报错行号错位）
      expect(code.split('\n').length, src.split('\n').length,
          reason: '块注释里的换行必须保留，否则报错行号会漂');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ① 共享查询：id → 名字
  // ═══════════════════════════════════════════════════════════════════

  group('① providerDisplayName（共享查询）', () {
    setUp(resetProviderNameCache);
    tearDown(resetProviderNameCache);

    test('★ 空 id 直接返回空（不炸、不去查）', () async {
      expect(await providerDisplayName(''), '');
    });

    test('★★ 查不到时必须**退回 id**，不能返回空串', () async {
      /*
       * 这是本组最重要的一条。
       *
       * flutter test 里没有原生库 → `SourinApi.listProviders()` 必然失败
       * → `_ensure()` 返回 null → 函数必须**退回 id**。
       *
       * 为什么"退回 id"是对的（不是偷懒）：
       * ```text
       * 显示 `cycani` 仍然回答了"我在哪个源"；
       * 显示空字符串则什么都没回答 —— 那正是用户抱怨的"看不到"。
       * ```
       * 与 `player_page.dart::_loginAndRetry` 同一条原则
       * （「查不到就退回 id，不能因为拿不到漂亮名字就不弹窗」）。
       */
      final got = await providerDisplayName('cycani');
      expect(got, 'cycani',
          reason: '★★ 取不到显示名时必须退回 **id** —— '
              '返回空串等于"什么都没显示"，正是用户报的缺陷');
    });

    test('★ 失败**不写缓存**（否则一次瞬时失败会永久生效）', () async {
      /*
       * 判据：连续两次调用都要走到"尝试加载"那条路。
       *
       * 怎么观测？—— 这个环境里加载**永远失败**，
       * 所以如果失败被缓存了，第二次调用会立刻返回（不打印日志）。
       * 我用一个可观测的副作用：调两次，两次都必须返回 id
       * （若失败被缓存成空表，第二次会走到 `m[id]` 为 null 的分支 ——
       *  仍然返回 id，所以这条**观测不出来**）。
       *
       * ⇒ 所以这条改成**静态**断言：源码里 catch 分支**不能**有
       *   `_cache = `。这是这条契约唯一的可判据形式。
       */
      final code = codeOf('lib/ui/widgets/provider_name.dart');
      final catchIdx = code.indexOf('catch (e)');
      expect(catchIdx, greaterThan(-1), reason: '必须有 catch 分支');

      // catch 块到下一个方法定义之间
      final after = code.substring(catchIdx);
      final end = after.indexOf('Future<String> providerDisplayName');
      final catchBody = end > 0 ? after.substring(0, end) : after;

      expect(catchBody.contains('_cache ='),
          isFalse,
          reason: '★ 失败分支里**不能**写 `_cache =` —— '
              '否则一次瞬时失败会让整个进程再也拿不到源名');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 详情页：站点名 chip
  // ═══════════════════════════════════════════════════════════════════

  group('② 详情页显示当前站点', () {
    final code = codeOf('lib/ui/detail_page.dart');

    test('★★ 详情页必须渲染 providerName 的 chip', () {
      expect(code.contains('providerName'), isTrue,
          reason: '★ 详情页要显示当前站点名（用户要求）');

      /*
       * ⚠️ 只断言"出现过 providerName"是不够的 ——
       *    它可能只出现在字段声明里，而**没被渲染**。
       *    所以断言那条**渲染语句**本身。
       */
      expect(code.contains('_Chip(text: providerName!, brand: true)'), isTrue,
          reason: '★★ 必须是**真的渲染**（`_Chip(text: providerName!)`），'
              '不是只声明一个字段 —— 声明而不渲染正是原版'
              '`current-provider-name` 那个死代码的形态');
    });

    test('★ chip 放在徽章行（原版注释所指的位置）', () {
      /*
       * 位置有依据：`SourcePicker.vue:28-34` 说
       * 「详情页**标题区**已展示过站名」—— 而 `hero__badges`
       * 就是标题区那排徽章。所以 chip 必须与后端 badges 同一行。
       */
      final badgesIdx = code.indexOf('for (final b in badges)');
      final nameIdx = code.indexOf('_Chip(text: providerName!');
      expect(badgesIdx, greaterThan(-1));
      expect(nameIdx, greaterThan(badgesIdx),
          reason: '★ 站点 chip 必须与后端 badges **同一个 Wrap** —— '
              '那正是原版注释说的"标题区"');
    });

    test('★ 未取到名字时**不渲染**（不占位、不显示空 chip）', () {
      expect(code.contains('if (providerName != null) _Chip'),
          isTrue,
          reason: '★ null 时整条不渲染 —— 显示一个空 chip 比不显示更怪');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 播放页：顶栏站点名 + 窄窗口不挤压
  // ═══════════════════════════════════════════════════════════════════

  group('③ 播放页顶栏显示当前站点', () {
    final code = codeOf('lib/ui/player_page.dart');

    test('★★ _TopBar 有 providerName 参数并真的渲染', () {
      expect(code.contains('this.providerName'), isTrue,
          reason: '★ `_TopBar` 要能收到站名');
      expect(code.contains('providerName: _providerName'), isTrue,
          reason: '★ 调用点必须把 state 传进去 —— '
              '只加参数不传 = 永远不显示（原版死代码的形态）');
      expect(code.contains('providerName!,'), isTrue,
          reason: '★ 必须真的把名字画出来');
    });

    test('★★★ 站名必须限宽 —— 窄窗口下不许挤压标题', () {
      /*
       * 交付要求（Lead 明确提的）：
       * > 加源名后必须证明没挤压/换行/截断，特别是**窄窗口**下
       *
       * # 为什么"限宽"是这条的**唯一**正确实现
       *
       * 顶栏是 `Row`：
       * ```text
       * 返回键 | Expanded(标题/集名) | [站名 pill] | 直播 | 提示键
       * ```
       * `Expanded` 会**先让位**给固定宽度的兄弟 —— 站名 pill 不限宽时，
       * 长站名会把标题压成 "…"。限宽后站名**自己**省略号，标题保住。
       */
      expect(code.contains('_kNameMaxW'), isTrue,
          reason: '★★★ 站名必须有最大宽度常量');
      expect(code.contains('maxWidth: _kNameMaxW'), isTrue,
          reason: '★★★ 必须真的用上那个约束');

      // 值要合理：太大会挤标题，太小会显示不全
      final m = RegExp(r'_kNameMaxW\s*=\s*([\d.]+)').firstMatch(code);
      expect(m, isNotNull, reason: '要能解析出常量值');
      final v = double.parse(m!.group(1)!);
      expect(v, greaterThanOrEqualTo(80),
          reason: '太小会让「哔哩哔哩」都显示不全（当前 $v）');
      expect(v, lessThanOrEqualTo(260),
          reason: '太大在窄窗口下会挤标题（当前 $v）');
    });

    test('★★ 站名必须能省略号（maxLines:1 + ellipsis）', () {
      /*
       * 限宽只是"不让它挤别人"；省略号是"它自己被截断时体面"。
       * 两者缺一：只有限宽而无 ellipsis → 文字溢出画黄黑条。
       */
      final idx = code.indexOf('providerName!,');
      expect(idx, greaterThan(-1));
      final around = code.substring(idx, (idx + 420).clamp(0, code.length));
      expect(around.contains('maxLines: 1'), isTrue,
          reason: '★ 站名要单行');
      expect(around.contains('TextOverflow.ellipsis'), isTrue,
          reason: '★ 截断时要省略号，不是溢出');
    });

    test('★ 换源后必须**重新取**站名（否则一直显示旧站名）', () {
      /*
       * `_provider` 在 `_resolveAndPlay` 里被替换。不重取的话
       * 顶栏会停在旧站名 —— 比不显示更糟（用户以为换源没生效）。
       */
      final resolveIdx = code.indexOf('_provider = provider;');
      expect(resolveIdx, greaterThan(-1), reason: '换源点必须在');

      final after = code.substring(resolveIdx, (resolveIdx + 900).clamp(0, code.length));
      expect(after.contains('_loadProviderName()'), isTrue,
          reason: '★★ 换源后必须重新取站名 —— '
              '否则顶栏停在旧源（用户会以为换源失败）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 为什么不能"照原版删掉"（设计依据的可执行记录）
  // ═══════════════════════════════════════════════════════════════════

  group('④ 原版依据（防止后人"照原版"删掉它）', () {
    test('★★ 原版 SourcePicker 的注释声称"详情页标题区已展示过站名"', () {
      /*
       * ★★★ 这是本功能**不是"发明 UI"** 的唯一依据，必须可执行地钉住。
       *
       * 如果将来有人：
       * ```text
       * ① 发现"原版没有站名" ⇒ 认为这是多余的增强 ⇒ 删掉
       * ```
       * 这条测试会告诉他：原版**自己**的注释说详情页标题区**应该**有站名
       * —— 只是它没做到。删掉等于把原版未兑现的意图也删了。
       *
       * ⚠️ 原版路径在**另一个仓库**（`cctv_to_client`）。它不存在时
       *    这条测试**跳过而不是失败** —— 否则在只有 Flutter 侧的
       *    环境里会变成假失败（铁律 12：先怀疑验证工具）。
       */
      final p = File(r'D:\WishProject\cctv_to_client\src\components\SourcePicker.vue');
      if (!p.existsSync()) {
        // ignore: avoid_print
        print('⚠️ 跳过：原版仓库不在本机（$p）—— '
            '这是环境缺失，不是实现回归');
        return;
      }

      final src = p.readAsStringSync();
      expect(src.contains('详情页标题区已展示过站名'), isTrue,
          reason: '★★ 原版注释里那句"详情页标题区已展示过站名"'
              '是本功能的依据。它消失了说明原版改了 —— '
              '那要重新核对，而不是照旧删我们的 chip');
    });

    test('★★ 原版那两个 computed 是死代码（我们不要复制这个形态）', () {
      /*
       * `current-provider-name` / `currentProviderName` 在原版里
       * **只声明不渲染**（SourceSwitchDialog.vue:49 声明；
       * 标记"当前"用的是 `props.currentProvider` 这个 id）。
       *
       * 这条钉住"原版确实没渲染"这个事实 —— 它同时解释了
       * 为什么我们的实现必须**真的渲染**（上一条断言守着）。
       */
      final p = File(
          r'D:\WishProject\cctv_to_client\src\components\SourceSwitchDialog.vue');
      if (!p.existsSync()) {
        // ignore: avoid_print
        print('⚠️ 跳过：原版仓库不在本机（$p）');
        return;
      }

      final src = p.readAsStringSync();
      final tplIdx = src.indexOf('<template>');
      expect(tplIdx, greaterThan(-1));

      // 模板里（真正渲染的那部分）**不能**出现 currentProviderName
      final tpl = src.substring(tplIdx);
      expect(tpl.contains('currentProviderName'), isFalse,
          reason: '★ 原版模板里确实没用它（死代码）—— '
              '这正是"声明而不渲染"的形态，我们必须避免');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑤ ★★★ 窄窗口不挤压 —— **行为**验证（不是静态断言）
  // ═══════════════════════════════════════════════════════════════════

  group('⑤ 窄窗口下顶栏不挤压（挂真实 _TopBar 量像素）', () {
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 为什么这一组必须存在（一条真实的"假通过"记录）
     * ══════════════════════════════════════════════════════════════════
     *
     * 上面 ③ 那组是**静态**断言（源码里有没有 `maxWidth: _kNameMaxW`）。
     * 它证明"约束写在代码里了"，但**证明不了它真的起作用** ——
     * 比如：
     * ```text
     * 约束加在了错误的那一层（包住了 Row 而不是 pill）
     * 或者 pill 被 Flexible 包着 ⇒ 约束根本不参与布局
     * ```
     * 这两种情况下静态断言**全绿**，而用户看到的标题仍然被挤扁。
     *
     * # 更重要的：我先试的"运行期探针"给出了一个假通过
     *
     * 在 `lib/t32_probe.dart`（进程内 toImage 探针）里试过两种改宽度的办法：
     * ```text
     * ① windowManager.setSize(900, 600)
     *    → 窗口仍是 1280x720；标题宽度与宽窗口**逐字节相同**（349.0）
     * ② 运行期置标志 + 重新 runApp（SizedBox + MediaQuery 900x600）
     *    → 更糟：量出来还是 349.0 / left=1160.0（陈旧值），
     *      截图变成 19KB 空白，判据却打印 "OK（未被挤压）"
     * ```
     * ⇒ 那两次**都是假通过**：判据根本没变，结论却说没问题。
     *   若标题真被挤了，它们**也会**报 OK（铁律 40：没有反馈回路的
     *   假阴性最危险）。
     *
     * ⇒ 所以改用 widget 测试：`setSurfaceSize` 是**受控**的，
     *   布局真的按给定宽度跑，且**可复现**（不依赖窗口管理器、
     *   不依赖其他 agent 是否占用了共享 build 目录）。
     */
    const longTitle = 'task32 播放页取证 一个足够长的标题用来量挤压';

    /// 在给定宽度下挂一个 `_TopBar` 的等价物并返回测量结果
    ///
    /// ⚠️ `_TopBar` 是**私有类**，测试无法直接构造。
    ///    所以这里用一个**结构完全相同**的替身：同样的 `Row`、
    ///    同样的 `Expanded(标题)` + `ConstrainedBox(maxWidth)` 站名。
    ///
    ///    ⇒ 它测的是**布局契约**（"限宽后标题不被挤压"），
    ///      而不是"私有类能被构造"。
    ///      真正的端到端证据在 `.probe/t32-scene/t32-player.png`
    ///      （真实 PlayerPage 的进程内像素，站名 pill 在 (1160,22)）。
    Widget topBarLike({
      required String title,
      required String? providerName,
      double maxW = 180,
    }) {
      return MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Row(
            children: [
              const SizedBox(width: 48), // 返回键
              const SizedBox(width: Sp.x2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: FontSizes.base,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              if (providerName != null && providerName.isNotEmpty) ...[
                const SizedBox(width: Sp.x2),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxW),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Sp.x3,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: Radii.rFull,
                    ),
                    child: Text(
                      providerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: FontSizes.cap,
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 48), // 提示键
            ],
          ),
        ),
      );
    }

    testWidgets('★ 900px 窄窗口：标题仍在、站名仍在、两者不重叠', (t) async {
      await t.binding.setSurfaceSize(const Size(900, 600));
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(
        topBarLike(title: longTitle, providerName: '次元城动画'),
      );
      await t.pump();

      final titleRect = t.getRect(find.text(longTitle));
      final nameRect = t.getRect(find.text('次元城动画'));

      // ① 标题**没有被压成 0 宽**（"看不见了"是最坏的结果）
      expect(titleRect.width, greaterThan(0),
          reason: '★ 标题必须仍然可见（宽度 > 0）');

      // ② 标题与站名**不重叠**（重叠 = 画在一起，用户读不了）
      expect(titleRect.right, lessThanOrEqualTo(nameRect.left + 0.01),
          reason: '★★ 标题右边界必须在站名左边界**之前** —— '
              '重叠就意味着两段文字画在一起');

      // ③ 站名自己有正宽度（没被压没）
      expect(nameRect.width, greaterThan(0),
          reason: '站名也要可见');
    });

    testWidgets('★★ 412px 手机宽度 + **最长真实站名**也不挤压', (t) async {
      /*
       * ══════════════════════════════════════════════════════════════
       * 为什么单独有这一条（Lead 提的问题）
       * ══════════════════════════════════════════════════════════════
       *
       * > 你有 maxWidth:180 的限宽，但 412px 宽时 180 已经接近一半
       * > ⇒ 会不会挤压标题？
       *
       * ★ 答案的关键在于 `ConstrainedBox(maxWidth:)` 是**上限**，
       *   不是**预留** —— 短站名只占它自己的自然宽度。
       *   所以"412px 下没事"**必须用最长站名**再证一次，
       *   否则只是证明了"当前这个源恰好够短"。
       *
       * ★ 站名用的是**真实数据**里最长的那个：
       *   `.probe/user-view/plugins/` 下 27 个插件的 `@name` 里，
       *   最长是 `360` → `360资源-采集`（8 字）。
       *   （提取脚本：`.probe/t32_provider_names.py`）
       *
       * 进程内实测（`.probe/t32_probe.dart -Narrow -NarrowW 412 -Provider 360`）：
       * ```text
       * root 实际布局宽度 = 412.0px   <- 仪器自证
       * 标题 w=200.1  站名 w=75.9  间距=20.0px  不重叠
       * 站名 pill 外框 ~ 99.9px（文字 75.9 + padding 24）
       * ```
       * ⇒ 100px / 412px ≈ 24%，远未占满，标题仍有 200px。
       */
      const longestReal = '360资源-采集'; // 真实插件集里最长的 @name

      await t.binding.setSurfaceSize(const Size(412, 600));
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(
        topBarLike(title: longTitle, providerName: longestReal),
      );
      await t.pump();

      final titleRect = t.getRect(find.text(longTitle));
      final nameRect = t.getRect(find.text(longestReal));

      // 把数字打出来，供报告引用
      // ignore: avoid_print
      print('[T32-412] 412px 最长站名: 标题=${titleRect.width.toStringAsFixed(1)}px '
          '站名=${nameRect.width.toStringAsFixed(1)}px '
          '标题右=${titleRect.right.toStringAsFixed(1)} '
          '站名左=${nameRect.left.toStringAsFixed(1)}');

      expect(titleRect.width, greaterThan(0),
          reason: '★ 412px 下标题必须仍然可见');
      expect(nameRect.width, greaterThan(0),
          reason: '★ 412px 下站名必须仍然可见');
      expect(titleRect.right, lessThanOrEqualTo(nameRect.left + 0.01),
          reason: '★★ 412px 下标题与站名**不许重叠** —— '
              '手机是最窄的版式，这里重叠就等于用户读不了标题');

      /*
       * ★ 再钉一条：标题必须**保住一半以上**的可用宽度。
       *
       * "不重叠"是底线，但一个被压到 20px 的标题也不重叠 ——
       * 那对用户毫无价值。412px 里两侧固定件（返回键 48 + 提示键 48
       * + 两个 Sp.x2 间距 + pill 外框）约 200px，
       * 标题**应该**能拿到一半以上。
       */
      expect(titleRect.width, greaterThan(150),
          reason: '★★ 标题要保住有意义的宽度（实测 200.1px）—— '
              '只判"不重叠"会让"标题被压成一点点"也算通过');
    });

    testWidgets('★★★ 反面：**去掉限宽**后长站名真的会挤压标题', (t) async {
      /*
       * ★ 这是本组的**阳性对照**（铁律 1）。
       *
       * 没有它的话，上面那条"不重叠"可能只是"这个替身本来就宽"
       * —— 恒过的断言等于没断言。
       *
       * 做法：把 maxWidth 放到极大（模拟"忘了限宽"），
       * 用一个**超长**站名，看标题是否真的被压窄。
       */
      // 超长站名（60 字，远超限宽）—— 用字面量，不能 `* 12`（const 里不可用）
      const longName = '次元城动画次元城动画次元城动画次元城动画次元城动画次元城动画'
          '次元城动画次元城动画次元城动画次元城动画次元城动画次元城动画';

      await t.binding.setSurfaceSize(const Size(900, 600));
      addTearDown(() => t.binding.setSurfaceSize(null));

      // ── 限宽 180：标题保住 ──
      await t.pumpWidget(topBarLike(title: longTitle, providerName: longName));
      await t.pump();
      final narrowTitle = t.getRect(find.text(longTitle)).width;

      // ── 不限宽（maxWidth 放到 10000）：标题应被挤窄 ──
      await t.pumpWidget(
        topBarLike(title: longTitle, providerName: longName, maxW: 10000),
      );
      await t.pump();
      final wideTitle = t.getRect(find.text(longTitle)).width;

      expect(wideTitle, lessThan(narrowTitle),
          reason: '★★★ 阳性对照：**不限宽时长站名必须真的把标题挤窄** —— '
              '如果这两者一样，说明这条判据测不出挤压，'
              '那么"限宽有效"的结论就是空的。');

      // 把数字打出来，供报告引用（也便于人眼复核这条判据真的动了）
      // ignore: avoid_print
      print('[T32-SQ] 900px 限宽180 → 标题=${narrowTitle.toStringAsFixed(1)}px  '
          '不限宽 → 标题=${wideTitle.toStringAsFixed(1)}px  '
          '差=${(narrowTitle - wideTitle).toStringAsFixed(1)}px');
    });
  });
}
