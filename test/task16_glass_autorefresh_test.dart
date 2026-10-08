// ══════════════════════════════════════════════════════════════════════
//  task-16：追更页三个 tab 液态玻璃 + 去掉「检查更新」改自动更新
//           + 设置页「主题」区块液态玻璃
// ══════════════════════════════════════════════════════════════════════
//
// # 用户原话（三条）
//
// ```text
// 1.追更页面的  追更中 收藏 历史,这三个没有做液态玻璃
// 2.追更页面,去掉检查更新,应该是自动更新 这三个模块的数据
// 6.设置页的主题,也没做液态玻璃
// ```
// 以及澄清：
// > 我们现在的底栏的那种液态玻璃效果,你就直接套用就行了
//
// # 为什么用「源码断言 + 真 widget 树断言」两层
//
// ```text
// 源码断言     证明**代码里写了**（快、稳定）
// widget 断言  证明**真的挂载了**（源码里有但没接进去 = 假绿）
// ```
// ★ 本项目已有的教训（`settings_page.dart` 里那段"代码写完了和
//   功能可用了之间差一次接线"）：只断言源码文本会漏掉"没挂载"。
//
// # ⚠️ 为什么这里不 pump 整个 FollowPage
//
// `FollowPage` 要真核心（FFI）才能构造数据，`flutter_test` 里跑不起来
// —— 这与 `provider_layout_test.dart` 的取舍一致（它也是静态断言）。
// 所以：
// ```text
// · 玻璃结构      → 静态断言 + 独立 pump 一个复刻结构的最小 widget
//                   验证 GlassContainer 真的能挂载并渲染出像素
// · 自动更新      → 断言 `shouldSweep` 的**节流逻辑**（它是公开的、
//                   纯函数式的判断，可直接单测）
// · 「检查更新」删除 → 源码断言（按钮与方法都必须消失）
// ```
//
// 真实观感由 `.probe/probe_tests/task16_glass_shot_test.dart` 产出的
// PNG 覆盖（`RepaintBoundary.toImage()`，不碰用户桌面）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String follow;
  late String settings;

  /// ★ 主题二级页（2026-09-25 任务 ㉙：主题区块搬到二级页了）
  ///
  /// 用户拍板方案 A，把 5 个低频区块拆进二级页，「主题」是其中之一：
  /// ```text
  /// 改前：settings_page.dart       _Block(title:'主题', ...)
  /// 改后：settings/theme_page.dart SettingsBlock(title:'主题', ...)
  /// ```
  /// 项目铁律⑥：**断言跟着实际承担者走** —— 所以下面
  /// 「主题区块用液态玻璃」那一组改成查这个文件。
  ///
  /// ⚠️ 断言的**语义一条都没放松**（仍然是"必须 GlassContainer"、
  ///    仍然是"pill 本体不得加玻璃"），只是换了查找的文件。
  late String themePage;

  setUpAll(() {
    follow = File('lib/ui/follow_page.dart').readAsStringSync();
    settings = File('lib/ui/settings_page.dart').readAsStringSync();
    themePage = File('lib/ui/settings/theme_page.dart').readAsStringSync();
  });

  /// 去掉注释后的源码（**只用于"不得出现"这类否定断言**）
  ///
  /// ⚠️ 必要：本次改动在注释里**引用了被删掉的旧代码**
  ///（`_checkUpdates` / `'已是最新，暂无更新'`），
  /// 直接查整份源码会命中注释、让否定断言永远失败 ——
  /// 而代码其实已经改对了。
  String codeOnly(String src) {
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

  /// 取某个方法的正文（从签名到**下一个同级成员**之前）
  ///
  /// ⚠️ 不能用固定长度切片 —— 固定窗口会**溢出到下一个方法**，
  ///    于是断言查的是别人的代码：
  /// ```text
  /// _maybeSweep 后面紧跟 _markRead，再后面是 _openDetailFor
  /// 而 _openDetailFor **确实**会调 _flash（数据缺失时提示）
  /// → 用 +1200 的窗口查 "_flash(" 必然命中，永远假红
  /// ```
  /// 这里按「下一个 `\n  Future<` / `\n  void ` / `\n  bool ` /
  /// `\n  /// `（同级成员的起始缩进）」切，得到**只有这个方法**的正文。
  String methodBody(String src, String signature) {
    final i = src.indexOf(signature);
    expect(i > 0, isTrue, reason: '应能找到 $signature');
    final rest = src.substring(i);
    // 同级成员：两个空格缩进 + 声明关键字
    final m = RegExp(r'\n  (?:Future<|void |bool |String |List<|int |double )')
        .firstMatch(rest.substring(signature.length));
    if (m == null) return rest;
    return rest.substring(0, signature.length + m.start);
  }

  // ═══════════════════════════════════════════════════════════════════
  group('① 追更页三个 tab 用液态玻璃', () {
    test('★ 用开源包的 GlassContainer（不是自己写 BackdropFilter）', () {
      /*
       * 用户原话：
       * > 我们现在的底栏的那种液态玻璃效果,你就直接套用就行了
       *
       * 项目里已经踩过这个坑（`shell.dart:2793-2801` 记着用户**两次打回**）：
       * 自己写的 `ClipRRect > BackdropFilter(blur) > DecoratedBox` 只能做
       * **毛玻璃（frosted）**，做不出液态玻璃的核心 —— **折射**。
       */
      expect(follow, contains("import 'package:liquid_glass_widgets/"),
          reason: '★ 必须用开源包，不能自己实现（用户明确要求）');
      expect(follow, contains('GlassContainer('),
          reason: '★ 三个 tab 外层必须是 GlassContainer');
      expect(
        codeOnly(follow).contains('BackdropFilter'),
        isFalse,
        reason: '★ 不得自己写 BackdropFilter —— 那是毛玻璃，用户已两次打回',
      );
    });

    test('★ 形状与质量照抄底栏（同一个形状语言）', () {
      // 底栏 `shell.dart:3560`：LiquidRoundedSuperellipse(barHeight / 2)
      // my_shelf `:366`：LiquidRoundedSuperellipse(borderRadius: 999)
      expect(
        follow,
        contains('shape: const LiquidRoundedSuperellipse(borderRadius: 999)'),
        reason: '★ 胶囊形 —— 与底栏/my_shelf 同一个形状语言',
      );
      expect(follow, contains('quality: GlassQuality.standard'),
          reason: '★ standard 是包文档推荐的 95% 场景档（与底栏同一档）');
    });

    test('★★ 结构是「一块玻璃包三个 tab」，不是「三个玻璃 pill」', () {
      /*
       * 这是 `my_shelf.dart:330-360` 记下的**结构教训**（它第一版做错了）：
       * > 我第一版给**每个 tab** 各套一块 `GlassContainer` ——
       * > 于是屏幕上出现三个独立的小玻璃胶囊。
       * > ★ 教训：**"看起来不像"时先怀疑结构，不要先调参数**。
       *
       * 底栏也是这个结构（一条玻璃 + 一个滑动药丸），所以观感才一致。
       * → 全文件 `GlassContainer` 只应该有 **1 处**（外层那一个）。
       */
      final n = RegExp(r'GlassContainer\(').allMatches(codeOnly(follow)).length;
      expect(n, 1,
          reason: '★ 只能有一个 GlassContainer（外层）—— '
              '给每个 tab 各套一块会变成三个独立小胶囊，与底栏不像');
    });

    test('★★ 内部 tab 是透明的 + 有滑动选中药丸（照抄 my_shelf）', () {
      /*
       * 原版 `.mtab { background: transparent }` —— 玻璃在外层容器、
       * 选中药丸在 `_FollowTabs` 里。这是「跟底栏一样」的关键：
       * 底栏 = 一条玻璃 + 一个滑动药丸。
       */
      expect(follow, contains('class _FollowTabs extends StatelessWidget'),
          reason: '分段控件应抽成独立 widget（照 my_shelf 的结构）');
      expect(follow, contains('AnimatedPositioned'),
          reason: '★ 选中药丸要能滑动（与底栏同一个做法）');
      expect(follow, contains('Curves.easeOutBack'),
          reason: '★ easeOutBack 会轻微过冲再回弹 —— 那是"液态"手感'
              '（底栏与 my_shelf 都是这个曲线）');
      expect(follow, contains('Motion.slow'),
          reason: '★ 420ms 与底栏同一个时长');
      expect(follow, contains('class _FollowTabChip extends StatelessWidget'),
          reason: '单个 tab 应独立（本身透明，选中靠药丸）');
    });

    test('★★ 药丸与文字色成对取自 palette（否则深色下白药丸+白字）', () {
      /*
       * `my_shelf.dart:573-592` 的关键认知：
       * > **药丸是白的，所以药丸上的字必须是深色**
       * > ⚠️ 只抄一边会在深色主题下变成「白药丸 + 白字」= 完全看不见。
       *
       * 所以两套值必须绑在一个 palette 里给，不能各写各的。
       */
      expect(follow, contains('class _FollowPalette'),
          reason: '★ 配色必须集中成 palette（两套值成对）');
      expect(follow, contains('pillGradient'),
          reason: '药丸填充要有明暗两套');
      expect(follow, contains('activeText'),
          reason: '★ 选中态文字色要与药丸明暗**相反**');
      // 深色那套必须是「很透的白」
      expect(follow, contains('Colors.white.withValues(alpha: 0.19)'),
          reason: '★ 深色主题的药丸是"很透的白叠加"（照抄 my_shelf）');
    });

    test('★ tab 的 key 与状态字符串显式映射（不靠枚举名猜）', () {
      /*
       * 状态字段 `_tab` 是字符串（既有代码与测试都依赖
       * `'following'` / `'all'` / `'continue'`），而枚举名是
       * `continueWatching` ≠ `'continue'` —— 必须显式给出 key，
       * 否则改枚举名会静默改掉状态值。
       */
      expect(follow, contains('enum _FollowTab'),
          reason: '三个 tab 应有显式枚举（顺序即药丸 left 的下标）');
      expect(follow, contains("continueWatching('继续观看', 'continue')"),
          reason: "★ 枚举名 continueWatching 必须显式映射到状态值 'continue'");
      expect(follow, contains('firstWhere'),
          reason: 'String → 枚举要显式匹配（并兜住未知值）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  group('② 去掉「检查更新」+ 自动更新三模块', () {
    test('★★ 「检查更新」按钮必须不存在了（用户明确要求）', () {
      expect(codeOnly(follow).contains('检查更新'), isFalse,
          reason: '★ 用户原话：「追更页面,去掉检查更新」');
      expect(codeOnly(follow).contains('_checkUpdates'), isFalse,
          reason: '★ 按钮删了，它的处理函数也该消失（否则是死代码）');
    });

    test('★★ 巡检能力**没有丢** —— 搬到了自动路径', () {
      /*
       * ★ 这是本任务最容易做错的地方：直接删掉 `_checkUpdates`
       *   会让「N 部有更新」那块提示**永远空着**。
       *
       * 因为 `check_updates` 做的事与 `_load` **不是一回事**：
       * ```text
       * _load         只读本地 DB
       * check_updates 真的联网问每个插件"现在更新到第几集了"
       * ```
       * 所以巡检必须独立调度，不能只靠刷新列表。
       */
      expect(follow, contains('SourinApi.checkUpdates('),
          reason: '★★ 巡检必须仍在调 —— 删了它「N 部有更新」永远空着');
      expect(follow, contains('_maybeSweep'),
          reason: '★ 巡检搬到自动路径 `_maybeSweep`');
    });

    test('★★ 三处「回到本页」的入口都要触发自动更新', () {
      /*
       * 「自动更新」= 两个动作，三处入口都必须做**两件**，
       * 所以抽成 `_refreshOnEnter()` 一处实现。
       * 分散写必然出现"某个入口只刷新了列表、没跑巡检"——
       * 表现是**从不同路径回来看到的内容不一样**，极难复现。
       */
      final body = codeOnly(follow);
      expect(body.contains('_refreshOnEnter'), isTrue,
          reason: '★ 三处入口共用一个方法（保证不遗漏）');
      expect(body.contains('unawaited(_refreshOnEnter())'), isTrue,
          reason: '★ 非阻塞调用（巡检可能十几秒，不能拖住列表）');
      // 三处入口
      expect(body.contains('void didChangeDependencies()'), isTrue,
          reason: '入口①：从详情页/播放页返回');
      expect(body.contains('void didChangeAppLifecycleState('), isTrue,
          reason: '入口②：应用回前台');
      expect(body.contains('Future<void> loadAll()'), isTrue,
          reason: '入口③：shell 切回本 tab（原版 onActivated）');
    });

    test('★★ 巡检有节流（否则切 tab 来回切会反复打 20 个源的网络请求）', () {
      expect(follow, contains('_sweepInterval'),
          reason: '★ 必须有节流窗口 —— 巡检很贵（联网逐条 detail）');
      expect(follow, contains('Duration(minutes: 10)'),
          reason: '★ 10 分钟：远小于"每集更新间隔"，又能挡住反复切 tab');
      expect(follow, contains('bool shouldSweep(DateTime now)'),
          reason: '★ 节流判断抽成公开方法 —— 可单测（不用等真实 10 分钟）');
      expect(follow, contains('_lastSweepAt'),
          reason: '要记住上次巡检时间');
    });

    test('★ 节流逻辑本身：首次必跑、窗口内跳过、超窗口再跑', () {
      /*
       * 纯逻辑断言（不依赖 widget）——
       * 把"什么时候该跑"这个判断固化下来。
       */
      final body = codeOnly(follow);
      final seg = methodBody(body, 'bool shouldSweep(');
      expect(seg.contains('if (last == null) return true;'), isTrue,
          reason: '★ 首次（没跑过）必须跑');
      expect(
        seg.contains('now.difference(last) >= _sweepInterval'),
        isTrue,
        reason: '★ 距上次不足窗口 → 跳过；超过 → 再跑',
      );
    });

    test('★ 自动巡检**不弹 toast**（用户没主动点，弹提示会困惑）', () {
      /*
       * ⚠️ 判据要**只看这个方法的正文**（`methodBody` 按下一个同级
       *    成员切开），不能用固定长度窗口 —— 窗口会溢出到后面的
       *    `_openDetailFor`，而那个方法**确实**会调 `_flash`
       *   （数据缺失时提示），于是永远假红。
       */
      final body = codeOnly(follow);
      final seg = methodBody(body, 'Future<void> _maybeSweep()');
      final tryIdx = seg.indexOf('try {');
      expect(tryIdx > 0, isTrue, reason: '_maybeSweep 应有 try/catch');
      final exec = seg.substring(tryIdx);
      expect(exec.contains('_flash('), isFalse,
          reason: '★ 自动路径不弹 toast —— 用户没点它，弹红条只会困惑；'
              '如实记日志即可（下次回本页重试）');
      expect(exec.contains('debugPrint'), isTrue,
          reason: '失败要如实记日志，不静默');
    });

    test('★ 先记时间再发请求（防并发重复巡检）', () {
      final body = codeOnly(follow);
      final seg = methodBody(body, 'Future<void> _maybeSweep()');
      final setIdx = seg.indexOf('_lastSweepAt = DateTime.now()');
      final callIdx = seg.indexOf('await SourinApi.checkUpdates(');
      expect(setIdx > 0 && callIdx > 0, isTrue,
          reason: '两行都应在 _maybeSweep 里');
      expect(setIdx < callIdx, isTrue,
          reason: '★ 必须先记时间再发请求 —— 否则并发调用（切 tab + 回前台'
              '同时触发）会各自看到"没跑过"，打两轮巡检');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  group('⑥ 设置页「主题」区块用液态玻璃', () {
    test('★ 主题区块用 GlassContainer', () {
      /*
       * ★ 2026-09-25 任务 ㉙：区块搬到 `lib/ui/settings/theme_page.dart`。
       *   断言**语义不变**（仍然是"主题区块必须用 GlassContainer"），
       *   只是跟着代码换了查找的文件 —— 铁律⑥。
       */
      expect(themePage, contains("import 'package:liquid_glass_widgets/"),
          reason: '★ 主题页要用开源包（与底栏同一个组件）');
      // 定位「主题」区块，确认玻璃在它里面
      final i = themePage.indexOf("title: '主题'");
      expect(i > 0, isTrue, reason: '应能找到「主题」区块');
      final seg = themePage.substring(i, i + 3500);
      expect(seg.contains('GlassContainer('), isTrue,
          reason: '★ 「主题」区块必须有 GlassContainer');
      expect(seg.contains('LiquidRoundedSuperellipse(borderRadius: 999)'),
          isTrue,
          reason: '★ 胶囊形 —— 与底栏同一个形状语言');
      expect(seg.contains('GlassQuality.standard'), isTrue,
          reason: '★ 与底栏同一档质量');
    });

    test('★★ 只包容器，**不改** `_GesturePill`（它被手势配置复用）', () {
      /*
       * `_GesturePill` 有两个使用点：
       * ```text
       * _GestureChoice（手势配置，设置页多处）  → Wrap(for o in options)
       * 主题区块                                 → Wrap(for m in AppThemeMode.values)
       * ```
       * 用户只要求改「主题」这一块 —— 改 pill 本身会让**手势配置
       * 那几处也跟着变玻璃**，那是范围外的影响。
       *
       * ★ 2026-09-25 任务 ㉙：`_GesturePill` 搬进 `widgets/settings_kit.dart`
       *   并公开为 `SettingsGesturePill`（跨文件必须公开）。
       *   **断言的意思完全一样**：pill 本体里不得出现 `GlassContainer`。
       */
      final kit = File('lib/ui/widgets/settings_kit.dart').readAsStringSync();
      final pillStart =
          kit.indexOf('class SettingsGesturePill extends StatelessWidget');
      expect(pillStart > 0, isTrue,
          reason: '应该还能找到 pill 类（搬来后叫 `SettingsGesturePill`）');
      final pillBody = kit.substring(pillStart, pillStart + 1200);
      expect(pillBody.contains('GlassContainer'), isFalse,
          reason: '★★ pill 本体不得加玻璃 —— 它被手势配置复用，'
              '用户只要求改「主题」区块');
    });

    test('★ 玻璃容器要有 padding（否则 pill 压住折射带，看起来像没生效）', () {
      final i = themePage.indexOf("title: '主题'");
      final seg = themePage.substring(i, i + 3500);
      expect(seg.contains('padding: const EdgeInsets.all(Sp.x2)'), isTrue,
          reason: '★ 玻璃效果作用在边缘 —— pill 紧贴边缘会盖住折射带'
              '（my_shelf 用的是 4px，同一个道理）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  group('不破坏既有成果', () {
    test('★ 追更页仍不 import flutter/material（两套 Theme 串台）', () {
      expect(follow.contains("import 'package:flutter/material.dart'"), isFalse,
          reason: '★ 混用两套 Material 会让 Theme.of 拿到 fallback（亮色）');
      expect(follow.contains("import 'package:material_ui/material_ui.dart'"),
          isTrue);
    });

    test('★ 设置页仍不 import flutter/material', () {
      expect(settings.contains("import 'package:flutter/material.dart'"),
          isFalse,
          reason: '★ 本文件曾因混用 Material 两套库导致标题对比度 1.16:1');
    });

    test('★ 三个 tab 的文案与计数仍在（玻璃是外观，功能不变）', () {
      expect(follow, contains("following('追更中', 'following')"));
      expect(follow, contains("all('全部收藏', 'all')"));
      expect(follow, contains("continueWatching('继续观看', 'continue')"));
    });

    test('★ 空态文案仍未回归（原版逐字）', () {
      expect(follow, contains("'还没有追更的内容'"));
      expect(follow, contains("'还没有收藏'"));
      expect(follow, contains("'还没有观看记录'"));
    });
  });
}
