// ═══════════════════════════════════════════════════════════════════════ //  详情页（Detail   追更页（Follow）—— 功能对等回归测试
// ═══════════════════════════════════════════════════════════════════════ //
// # 这个文件守什么 //
// 对齐原版 `src/views/DetailView.vue`  80 行）一 // `src/views/FollowView.vue`  80 行）时发现的**真实差异**  // 以及三个"读的键后端不发送 的静默缺口：
// ```text
// ① PlaySource.title / count / nested   → 线路名空、集数角标 0、嵌套层不可见 // ① UpdateInfo.added / latest_title     → 　 N 集」显示总集数、最新一集名不显示 // ① MediaDetail.badges / meta           → 详情页头部角标整排消失 // ```
// 三者都**不报错 *：编译过、analyze 0 error、能跑起来，
// 唯一症状是 少显示点东西"—— 用户不会为一个没出现的角标报 bug　 //
// # ★★★ 静态断言**必须先剥掉注释 *
//
// 项目里踩过 3 次「断言匹配到注释文本 → 假通过」。本文件里尤其危险：
// 我在源码注释里 *大量引用了原版代码 *（比如把
// `favApi.toggle(...)` 这种"不该出现"的写法写进注释来解释为什么不能用）　 // 不剥注释的话  // ```text
// 断言「不能出现 toggleFavorite」→ 匹配到我自己解释这个坑的注释 → **假失败 *
// 断言「必须有 added　           → 匹配到注释里的字段说是     → **假通过**
// ```
// 两个方向都会错。所以 *所有 *静态断言统一以 [stripComments]　 //
// ⚠️ 纯静态断言（读源码文本  *不能替代**行为验证 —— //    它只能钉住 某个写法在 不在"。真正的行为验证在下面的 widget 测试
//    与真机实测里　 
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/widgets/detail_raw_meta.dart';
import 'package:sourin_spike/ui/widgets/follow_update_notice.dart';
import 'package:sourin_spike/ui/app_theme.dart';

// ═══════════════════════════════════════════════════════════════════════ //  剥注释（状态机，见文件头说明为什么不能用正则  // ═══════════════════════════════════════════════════════════════════════ 
/// 剥掉 `//` 行注释与 `/* */` 块注释，**保留字符串字面量**
///
/// 必须区分三种情况（正则做不到，需要记忆状态）  /// ```text
/// 'http://x'      字符串里的 `//` 不是注释
/// "a /* b"        字符串里的 `/*` 不是注释
/// /*  //  */      块注释里的 `//` 不是行注释 /// ```
/// 块注释里的换行=*保留**，这样报错时的行号还能对上源码
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote; // 在字符串里时记录引号字符

  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';

    // ── 在字符串里：原样保留，只找结束引号 ──
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

    // ── 不在字符串里 ──
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && next == '/') {
      // 行注释：跳到行尾（保留换行，行号不变
       while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && next == '*') {
      // 块注释：跳到 */
      i += 2;
      while (i < src.length &&
          !(src[i] == '*' && i + 1 < src.length && src[i + 1] == '/')) {
        // 保留换行，行号才对得上
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

/// 读源码并剥注释
String code(String path) {
  final f = File(path);
  if (!f.existsSync()) {
    fail('源码文件不存在  $path（工作目录  ${Directory.current.path}）' );
  }
  return stripComments(f.readAsStringSync());
}

// ═══════════════════════════════════════════════════════════════════════ //  ① 剥注释本身要正确（否则下面所有断言都不可信  // ═══════════════════════════════════════════════════════════════════════ 
void main() {
  group('stripComments（所有静态断言的前置）', () {
    test('行注释被剥掉', () {
      expect(stripComments('a; // toggleFavorite\nb;'), contains('a;'));
      expect(stripComments('a; // toggleFavorite\nb;'), isNot(contains('toggleFavorite')));
    });

    test('块注释被剥掉（含 `*` 开头的续行）' , () {
      const src = '/*\n * toggleFavorite 说明\n */\nreal();';
      final out = stripComments(src);
      expect(out, isNot(contains('toggleFavorite')));
      expect(out, contains('real();'));
    });

    test('★ 字符串里的 `//` 与 `/*` 必须保留', () {
      // 这两条是"用正则就错 的证据
expect(stripComments("final u = 'http://x';"), contains('http://x'));
      expect(stripComments('final s = "a /* b";'), contains('a /* b'));
    });

    test('★ 块注释里的 `//` 不是行注释（不能把后面的代码吃掉）' , () {
      const src = '/* // */\nreal();';
      expect(stripComments(src), contains('real();'));
    });

    test('块注释保留换行 —— 行号仍能对上源码', () {
      /*
       * 输入 6 行：`a;` / 块注释起始 / (空  / (空  / 块注释结束 / `b;`
       * 剥掉块注释后仍是 6 行（起止两行各留一个空行）—
* 这样报错时行号指的仍是 *源码**那行　        *
       * ⚠️ 这里**故意不写块注释的字面起止符号**         *    Dart 的块注释是 *可嵌套 *的，在注释里写出起始符号会让
       *    整个注释在错误的位置闭合（我第一版就这么写的
*    报错指向 300 行开外）。要写就写进字符串字面量里 —
*    见上面那几条 `stripComments('...')` 的用例　        */
      const src = 'a;\n/*\n\n\n*/\nb;';
      final lines = stripComments(src).split('\n');
      expect(lines.length, 6, reason: '行数必须与源码一致，否则报错行号会漂移' );
      expect(lines.first.trim(), 'a;');
      expect(lines.last.trim(), 'b;', reason: '`b;` 必须仍在最后一行' );
    });
  });

  // ═════════════════════════════════════════════════════════════════════   //  ① 详情页静态对等（DetailView.vue    // ═════════════════════════════════════════════════════════════════════ 
  /*
   * ══════════════════════════════════════════════════════════════════════
   * ★★★ task-58 说明：`DetailPage` 已**不再是独立页面**，但**本组测试仍然有效**
   * ══════════════════════════════════════════════════════════════════════
   *
   * # 为什么不是"假绿"（我核对了）
   *
   * Owner 裁决③「旧详情页完全去掉」之后，`DetailPage` 被
   * `MediaPage` **嵌在下半屏**（`embedded: true`）—— 它**仍在产品路径上**，
   * 只是不再独占一个路由。⇒ 这里断言的契约（收藏/追更独立、
   * 线路名读 title、`setFavorite(on:)` 而不是 toggle…）**全部仍然成立**，
   * 而且**仍然会被用户触发**。
   *
   * # 什么才是"假绿"（判据）
   *
   * ```text
   * 假绿 = 断言的对象**已不在产品路径上**（死代码 / 退役文件）
   *        ⇒ 测试绿，但用户永远碰不到那段代码
   * 本组 = 断言的对象**仍在路径上**（MediaPage 的详情区）
   *        ⇒ 绿 = 真的在保护用户可见的行为 ✓
   * ```
   * ★ 唯一的差别是"宿主页面"变了（独立路由 → 合并页的下半屏）。
   *
   * # 所以这里**不需要**改断言，只需要这条标注
   *
   * 而"新路径真的接上了"由 `t58_media_page_test.dart` 的 group ③ 守着：
   * ```text
   * · 非直播入口必须是 MediaPage（不是 PlayerPage）
   * · 直播入口必须仍是 PlayerPage（风险④）
   * · lib/ 里不得再有地方 push 独立 DetailPage
   * · MediaPage 必须传 embedded: true
   * ```
   * ⇒ ★★ 两者**合起来**才完整：本文件守"详情区的行为契约"，
   *    `t58_media_page_test` 守"它被挂在正确的地方"。
   */
  group('详情页 · 收藏 / 追更（DetailView.vue:285-488）' , () {
    late String src;

    setUpAll(() => src = code('lib/ui/detail_page.dart'));

    test('★★★ 收藏必须用显开 setFavorite(on:) *不能**用 toggleFavorite', () {
      /*
       * 原版 `DetailView.vue:268` 的注释（真 bug 的修复）
* > 用 `favApi.toggle()` 来「取消收藏」，但后端 `toggle_favorite`
       * > **没有删除分支** —— 它只有 新建"一 复活"
* > 所以 取消"反而把实 *复活**了　        *
       * 所以判据是两条**同时**成立
*   ① 出现 `setFavorite(` 且带 `on:`
       *   ① **不出现
* `toggleFavorite(`
       * 第二条正是 注释里写了这个词就会假失败 的典型 —— 靠 stripComments 挡住　        */
      expect(
        src,
        contains('SourinApi.setFavorite('),
        reason: '收藏必须用显式的 setFavorite（原版 DetailView.vue:328）' ,
      );
      expect(
        src,
        contains('on: want'),
        reason: '必须显式传目标状态 on:（原版 DetailView.vue:331）' ,
      );
      expect(
        src,
        isNot(contains('toggleFavorite(')),
        reason: '★ 绝不能用 toggleFavorite —— 后端没有删除分支' 
            '「取消收藏」会变成「复活」（原版 DetailView.vue:268）' ,
      );
    });

    test('★★★ 追更必须用 setFollowing *不能**用 setFavorite(on: true)', () {
      /*
       * 原版 `DetailView.vue:431-457`：`set(on: true)` 最 *复活语义**
       * （后端 `if fav.deleted { fav.deleted = false }`），
       * 于是追更按钮变成了 取消收藏的后悔药"
       * `setFollowing` 只改 following，绝不碰 deleted
       *
       * ⚠️ 2026-09-25 断言位置更正：原来断言的是 `follow_page.dart`（src）。
       *    用户要求「追更这里下面的两个操作按钮很丑,直接删了吧」之后，
       *    追更页不再有切换入口 —— **但契约本身仍然成立**，
       *    现在由 `detail_page.dart` 承担（详情页的「追更」按钮）。
       *
       * ★ 这条断言**不能删**：它防的是"用 setFavorite(on:true) 冒充追更"
       *   （那会让「取消收藏」变成「复活」）。断言必须跟着**实际承担者**走，
       *   而不是跟着某个文件走。
       */
      final detail = code('lib/ui/detail_page.dart');
      expect(
        detail,
        contains('SourinApi.setFollowing('),
        reason: '追更必须走 setFollowing（原版 DetailView.vue:458）'
            '—— 追更入口现在在详情页',
      );
      // 追更页若仍有切换入口，也必须走 setFollowing（现在没有了，故只查详情页）
      if (src.contains('setFollowing') || src.contains('following:')) {
        expect(src, isNot(contains('toggleFavorite(')),
            reason: '追更页若仍能切追更，同样不得用 toggleFavorite');
      }
    });

    test('★ 收藏状态判据必须是 favorited，不能是 deleted', () {
      /*
       * 原版 `DetailView.vue:395`         * > 判据必须是 `favorited`  *不能是 `deleted`**
       * 因为解耦后 `deleted=1 ⇒ !favorited && !following` —
* 追更还开着时 deleted 仍是 0，用它会算出"取消不掉"　        */
      expect(src, contains('_isFav = r.favorited'));
      expect(
        src,
        isNot(contains('_isFav = !r.deleted')),
        reason: 'deleted 的语义是"两个状态都没了"，不能当收藏判据',
      );
    });

    test('★ 取消收藏时不能顺手关掉追更（不做联动）' , () {
      /*
       * Owner 原话（原版 DetailView.vue:296-326）：
       * > 在追更和收藏都打开的情况下，无法取消收藏
* > 必须要取消追更，才能取消收藏  *这两个是不需要联动的**
       *
       * 判据：`_toggleFav` **方法体内**不能出现 `_following = false`　        *
       * ⚠️ 必须限定在方法体里，不能全局 `contains` —
*    字段声明 `bool _following = false;` 也含这个子串
*    全局断言会 *假失败 *（这正是"静态断言范围要精确 的一个实例）　        */
      final body = _methodBodyOf(src, 'Future<void> _toggleFav(');
      expect(
        body,
        isNot(contains('_following = false')),
        reason: '★ 取消收藏不得联动关闭追更（Owner 明确要求）' ,
      );
      expect(body, contains('_following = prevFollowing'), reason: '失败要回滚' );
    });

    test('★ 点收藏时不能传 following（收藏不隐含追更）' , () {
      /*
       * Owner         * > 我发现我现在点击收藏就会触发追更，这是两个完全不同的功能啊
* 原版 `DetailView.vue:352` 传的是 `following: undefined`
* 我们会 null 表示"不改追更状态  —— 所以 setFavorite 调用里
* **不能**出现 `following:` 实参　        */
      final call = _callSiteOf(src, 'SourinApi.setFavorite(');
      expect(
        call,
        isNot(contains('following:')),
        reason: '收藏不得传 following —— 那会把追更一起打开（原版 DetailView.vue:352）' ,
      );
    });
  });

  group('详情页 · 播放源 / 线路（DetailView.vue:206-254, 666-673）' , () {
    late String src;

    setUpAll(() => src = code('lib/ui/detail_page.dart'));

    test('★★★ 线路名必须读 title（后端真名），不能只读 name', () {
      /*
       * 权威定义 `rust/sourin_core/src/model.rs:177-187`         * ```rust
       * pub struct PlaySource { pub code: String, pub title: String, ... }
       * ```
       * 而 `models.dart` 的 `PlaySource` 原来读的是 `name` —
* 后端**从不下发**那个键 → 线路名永远是空 → UI 只能显示 code　        *
       * ★ 判据位置随根因修复 *迁移**了：
       * ```text
       * 修复前：解析逻辑在 widgets/detail_raw_meta.dart（绕行层
* 修复后：解析逻辑回到 core/models.dart（唯一契约来源
* ```
       * 所以这里断言 `models.dart` 的 `PlaySource.fromJson` 读真名 —
* 那才是 以后 Rust 改字段名时 *唯一**要改的地方 　        */
      final models = code('lib/core/models.dart');
      final playSource = _classBodyOf(models, 'class PlaySource {');
      expect(
        playSource,
        contains("j['title']"),
        reason: "★ 必须读 title（Rust 真名），不是 name（model.rs:180）" ,
      );
      expect(
        playSource,
        contains("j['count']"),
        reason: "★ 必须读 count（Rust 真名），不是 episode_count（model.rs:183）" ,
      );
      expect(
        playSource,
        contains("j['nested']"),
        reason: '★ nested 是原版递归渲染的核心（SourcePicker.vue:74-80）' ,
      );

      /*
       * ★ 反向断言：绕行层**不能**再有第二份解析　        *
       * 留着就是"第二份契约 —— 以后 Rust 改字段名，两处都要改"        * 漏掉哪一处都不报错（正是这三个缺口本身的形态）　        */
      final picker = code('lib/ui/widgets/detail_raw_meta.dart');
      expect(
        picker,
        isNot(contains("j['title']")),
        reason: '★ 绕行已撤：解析只能在 models.dart 一处，'
            '否则就是第二份契约（前两找 ProxyCfg/_call 也是这么撤的）' ,
      );
      expect(
        picker,
        isNot(contains('DetailSourceNode')),
        reason: '★ 平行类型必须删掉 —— 数据只有一条来源：PlaySource',
      );
    });

    test('★ 线路区必须支持嵌套（原版 SourcePicker.vue 是递归组件）' , () {
      /*
       * 原版 `SourcePicker.vue:74-80` 自己渲染自己
* ```vue
       * <SourcePicker v-if="hasChildren" :sources="childSources" ... />
       * ```
       * 我们原先是一层横含 ListView，嵌套线路 *永远看不到
*　        */
      expect(
        src,
        contains('DetailSourcePicker('),
        reason: '必须用支持嵌套的选择器（原版 SourcePicker.vue）' ,
      );
      final picker = code('lib/ui/widgets/detail_raw_meta.dart');
      expect(
        picker,
        contains('_Level('),
        reason: '必须有递归局 —— 原版靠组件自引用实现（SourcePicker.vue:74）' ,
      );
    });

    test('★ 单选项的层要隐藏（原版 SourcePicker.vue:35）' , () {
      final picker = code('lib/ui/widgets/detail_raw_meta.dart');
      expect(
        picker,
        contains('sources.length > 1'),
        reason: '原版 `visible = sources.length > 1` —— 一个选项没有"选择"的意义' ,
      );
    });

    test('★ 集数角标 0 时不显示（原版 `v-if="s.count"`）' , () {
      final picker = code('lib/ui/widgets/detail_raw_meta.dart');
      expect(
        picker,
        contains('count > 0'),
        reason: 'count=0 的语义是"该源没报集数"，不是 最 0 集 ',
      );
    });

    test('★ 有源就要拉剧集 —— 不能用 sources.length > 1 当条件' , () {
      /*
       * 原版 `DetailView.vue:200-204` 的实测记录：
       * > cycani 的《指名！》只有一个源（cychub），但下面挂着 24 集
* > 只在多源时才拉，会导致单源多集的内容**一集都看不到
*　        */
      expect(
        src,
        isNot(contains('if (_hasMultiSource) {\n        await _loadEpisodes')),
        reason: '是否拉剧集要看 有没有源"，不是 源多不多"',
      );
      // 正向上：`preferred != null` 就要拉
expect(
        src,
        contains('await _loadEpisodes(preferredCode)'),
        reason: '有首选源就按它拉一次权威剧集列表' ,
      );
    });

    test('★ 按源拉剧集必须走 getEpisodes(sourceCode)', () {
      /*
       * 原版 `DetailView.vue:234-245` 的 `loadEpisodes` 里重新调了一次
* `content.detail()` —— 那是**取不到指定源的剧集 *的
* （detail 返回默认源的剧集）
* 我们这边用正确的 `get_episodes`，这条守住别退化回去　        */
      expect(src, contains('SourinApi.getEpisodes('));
      expect(src, contains('code,'), reason: '必须把 sourceCode 传给 get_episodes');
    });

    test('★ 源偏好要能命中嵌套层的 code', () {
      /*
       * 用户上次可能选的是第二层的线路。若只在顶层找，
       * 记住的偏好会**静默失效**、跳回第一个源
* 原版 `SourcePicker.vue:49-52` 的 containsActive 正是一
* "选中项可能在子树里 写的　        */
      expect(
        src,
        contains('flattened'),
        reason: '偏好查找必须覆盖嵌套层（原版 containsActive）' ,
      );
    });
  });

  group('详情页 · 元信息 / 徽章（DetailView.vue:587-593）' , () {
    late String src;

    setUpAll(() => src = code('lib/ui/detail_page.dart'));

    test('★★★ 必须渲染后端 badges（原版直接 v-for，不重拼）' , () {
      /*
       * 原版 `DetailView.vue:588`         * ```vue
       * <span v-for="b in detail.badges" class="chip chip--brand">{{ b }}</span>
       * ```
       * `badges` 是 *后端拼好的 *（cycani 插件拼「连载中 / 更新至 12 集 / 9.2 分」，
       * 见 `plugins/cycani.js:499-518`），顺序与措辞都是产品决定　        *
       * 而 `models.dart` 的 `MediaDetail` **没有 badges 字段** →
* 我们这边那排角标**一个都没显示过**　        */
      expect(
        src,
        contains('detail.badges'),
        reason: '★ 必须渲染后端的 badges（model.rs:212，原版 DetailView.vue:588）' ,
      );
    });

    test('★ 不能再用自己拼的「年份 地区/类型」当主徽章' , () {
      /*
       * `MediaDetail.year` / `.area` 在 Rust 的 `MediaDetail`
       * （`model.rs:204-224`）里**根本不存在
* —
* 那些信息在后端的 `meta` 里。自己拼等于发明一套与原版不同的文案，
       * 而且永远是空的（字段读不到 → 不渲染）　        */
      expect(
        src,
        isNot(contains('detail.year')),
        reason: 'detail.year 后端不下发（真位置是 meta），别拿它拼徽章',
      );
      expect(src, isNot(contains('detail.area')));
    });

    test('★ meta 兜底只在 badges 为空时生效（不能覆盖后端文案）' , () {
      expect(
        src,
        contains('detail.badges.isEmpty'),
        reason: '有后端 badges 时一个字都不该加 —— 保证与原版一致' ,
      );
    });

    test('★ 「N 个播放源」角标与线路区用**同一一 *数量', () {
      /*
       * 否则会出现 角标读 2 个源，但下面没有线路区 的自相矛盾　        */
      expect(src, contains('sourceCount > 1'));
      expect(src, contains('_sourceNodes.length > 1'));
    });
  });

  group('详情页 · 播放 / 选集 / 进度（DetailView.vue:129-178, 502-546）' , () {
    late String src;

    setUpAll(() => src = code('lib/ui/detail_page.dart'));

    test('★★★「继续观看/播放」按钮已删（Owner 要求）—— 但**续播提示**仍在', () {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 2026-09-27：Owner 要求删掉那个按钮
       * ══════════════════════════════════════════════════════════════
       *
       * Owner 原话（逐字）：
       * > 我觉得 继续观看按钮可以删除了，因为已经正在播放了
       *
       * # 它为什么确实是多余的（不是"少个入口而已"）
       * ```text
       * 合并页里播放器**进来就自动起播**（真机日志逐字）：
       *   [PLAYER] ★ 检测到上次进度 77s，将续播
       *
       * 而那个按钮走 `_resumePlay()` ⇒ `_play(ep)` ⇒
       * `onPlay(PlayRequestData(...))` ⇒ `MediaPage._onDetailPlay`
       * ⇒ `session.applySession(req)`
       * ⇒ ★ `isSameSessionAs` 四元组**完全相同** ⇒ 走"同一会话"分支
       * ⇒ **只更新标题，不重启流** ⇒ 点它**什么都不会发生**
       *
       * ⚠️ 更糟的是无剧集分支那个「播放」按钮：
       *    `_play()` 不带 ep ⇒ `req.episodeId = null`
       *    而剧集 + 有续播时 `cur.episodeId = '51463'`
       *    ⇒ **判为"换会话"** ⇒ 重新解析流 ⇒ 黑屏 + 从头开始（丢进度）
       * ```
       * ⇒ 两个按钮**都**删了（`_Info` 的操作行 + 无剧集分支）。
       *
       * # 为什么"续播提示"要**留着**（这条断言守的就是它）
       * ```text
       * 「上次看到 第11集 · 剩 3 分钟」是一颗**信息** chip，不是动作 ——
       * Owner 说的是"按钮可以删除"，而这条信息本身对用户有用
       *（他就想知道自己看到哪了）。
       * ⇒ 删的是**动作**，不是**信息**。
       * ```
       */
      // ① 按钮必须真的没了（含两个分支）
      expect(src, isNot(contains("'继续观看'")),
          reason: '★★★「继续观看」按钮必须删掉（Owner 明确要求）—— '
              '它在合并页里是**空操作**（同一会话早退）');
      expect(src, isNot(contains('onPressed: onPlay')),
          reason: '★★★ `_Info` 里那个播放按钮必须删掉');
      expect(src, isNot(contains('onPressed: () => _play()')),
          reason: '★★★ 无剧集分支那个「播放」按钮也必须删掉 —— '
              '它比空操作更糟：剧集+有续播时会被判成"换会话"⇒ 黑屏 + 丢进度');
      expect(src, isNot(contains('void _resumePlay()')),
          reason: '★ `_resumePlay` 已无调用者 ⇒ 必须一起删（否则是死代码）');

      // ② ★ 续播**提示**（信息，不是动作）必须仍在
      expect(src, contains('resume!.position > 5'),
          reason: '★★ 「上次看到 …」提示的判据必须保留 —— '
              'Owner 删的是**按钮**，不是这条信息');
      expect(src, contains("'上次看到 '"),
          reason: '★★★ 续播提示 chip 必须还在 —— 用户要能看到自己看到哪了。'
              '★ 若这条失败，说明有人把"删按钮"做成了"删整块信息"');
    });

    test('★★★ 两个选集状态都要有：active（选中）  played（看过）', () {
      /*
       * Owner 要求（原版 DetailView.vue:684-691）：
       * > 这个页面如果有观看记录，下面的应该默认选中上次观看的集数
* > 然后如果是只有一个，默认也应该选择第一个，
       * > 不应该显示没选中的效果        *
       * ```text
       * active  当前**选中**（默认上次观看的，否则第一集）
       * played  曾经**看过**（区到 看过但没选中""        * ```
       * ⚠️ 不能只留 active：用户想看到"哪几集看过
*    也不能只留 played：没观看记录时整片灰着，像没选中　        */
      expect(src, contains('active: _activeEpisodeId == ep.id'));
      expect(src, contains('played: _resume?.episodeId == ep.id'));
    });

    test('★ 选中优先级：上次观看 > 第一集 > null', () {
      expect(src, contains('_episodes.first.id'), reason: '① 兜底第一集' );
      expect(src, contains('return null'), reason: '① 没有剧集时不渲染选集区' );
    });

    test('★ 手动点过的选集优先于自动推导' , () {
      // 场景：点开第 5 集但还没产生进度 → 高亮不该跳回第一集
expect(src, contains('_pickedEpisodeId ?? _selectedEpisodeId'));
      expect(src, contains('_pickedEpisodeId = ep.id'));
    });

    test('★★★ 换源弹层的 episodeIndex 必须只看进度，没进度会 0', () {
      /*
       * 原版 `DetailView.vue:129-134`         * ```js
       * const currentEpisodeIndex = computed(() => {
       *   if (!resume.value) return 0;      // → 没进度就是 0
       *   const i = episodes.value.findIndex(e => e.id === resume.value.episode_id);
       *   return i >= 0 ? i + 1 : 0;
       * });
       * ```
       * 而我们原先用 `_activeEpisodeId` 反推 —— 它没有进度时会
* **兜底成第一集 *，于是全新作品会传 `episodeIndex: 1`         * 被当成 看到第 1 集 　        *
       * `0` 是哨兵值（原版 SourceSwitchDialog.vue:50「没有剧集概念时会 0」）　        */
      expect(
        src,
        contains('final epIdx = _currentEpisodeIndex;'),
        reason: '★ 必须用只看进度的 _currentEpisodeIndex（原版 DetailView.vue:129）' ,
      );
      expect(
        src,
        isNot(contains('_episodes.indexWhere((e) => e.id == _activeEpisodeId)')),
        reason: '★ 不能用 当前高亮集 反推 —— 没进度时会兜底成第一集' ,
      );
    });

    test('★ 播放要把「源 + 剧集列表 + 下标」一起交给播放器', () {
      /*
       * 原版 `DetailView.vue:495-501`         * > 若只传单集 id，播放器就无法知道下一集是谁，自动连播无从实现　        */
      expect(src, contains('episodes: _episodes'));
      expect(src, contains('episodeIndex: idx >= 0 ? idx : null'));
      expect(src, contains('sourceCode:'));
    });

    test('★ 换源要用 pushReplacement（不是 push）' , () {
      /*
       * 原版 `DetailView.vue:107-113`         * > 用 `router.push` 而不是原地换 provider —
* > 因为新源的 id、剧集、线路全都不一样，整页重新加载最干净　        *
       * 我们这边 `onOpenDetail` 用 shell 用 `pushReplacement` 实现
       * （`shell.dart:2047`）—— 详情页只负责回调，不自己 push　        */
      expect(
        src,
        contains('widget.onOpenDetail?.call(pick.provider, pick.id)'),
        reason: '换源后跳到新源的详情页（整页重载）' ,
      );
    });
  });

  // ═════════════════════════════════════════════════════════════════════   //  ① 追更页静态对等（FollowView.vue    // ═════════════════════════════════════════════════════════════════════ 
  group('追更页 · 三个 tab（FollowView.vue:24, 198-202, 216-231）' , () {
    late String src;

    setUpAll(() => src = code('lib/ui/follow_page.dart'));

    test('★ 默认 tab 是「追更中」，不是「全部收藏」', () {
      expect(src, contains("String _tab = 'following'"));
    });

    test('★ 三个 tab 的标签与计数与原版一致' , () {
      expect(src, contains("'追更中'"));
      expect(src, contains("'全部收藏'"));
      expect(src, contains("'继续观看'"));
    });

    test('★ 两个列表必须**分别**查（followingOnly true/false）' , () {
      /*
       * 原版 `FollowView.vue:36-40` 并发拉三份：
       * ```js
       * favApi.list(true)    // 追更列表（list_following_for_ui         * favApi.list(false)   // 收藏列表（只后
favorited=1         * progApi.continueWatching(20)
       * ```
       * ⚠️ 不能只拉一次再 filter —— `list(false)` 的 SQL 是 `WHERE favorited=1`         *    拿不到「只追更不收藏」的条目　        */
      expect(src, contains('SourinApi.listFavorites(followingOnly: true)'));
      expect(src, contains('SourinApi.listFavorites(followingOnly: false)'));
      expect(src, contains('SourinApi.continueWatching(limit: 20)'));
    });

    test('★ 三个请求要并发（原版 Promise.all）' , () {
      expect(
        src,
        contains('Future.wait'),
        reason: '原版用 Promise.all 并发 —— 串行会让首屏多等两个 RTT',
      );
    });
  });

  group('追更页 · 更新标记（FollowView.vue:71-93, 245-262）' , () {
    late String src;

    setUpAll(() => src = code('lib/ui/follow_page.dart'));

    test('★★ 未读数走「还剩几集没看」算法（**有意偏离原版**，用户要求）', () {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 这条断言**翻转过来了**（task-40，2026-09-25）
       * ══════════════════════════════════════════════════════════════
       *
       * 原来断言的是：
       * ```dart
       * expect(src, contains('SourinApi.totalUnread()'));
       * ```
       * 那对应**旧语义**：`SUM(unread_count)` = "自上次巡检后新增了几集"。
       *
       * # 用户明确要求换语义（原话逐字）
       *
       * > 底部的菜单栏，追更默认就显示  3  徽标，这是错误的
       * > 首页的追更  底部的追更 追更页面的追更   这几个都应该按照
       * > 这个追更这个剧还有多少集没看来显示这个徽标，比如 12集，
       * > 只看了一集 就显示11，以此类推，当往后看到12集则计数器为0
       *
       * ⇒ 新语义 = **总集数 − 已看集数**，与"巡检累加"**不是一回事**。
       * ⇒ 所以这条路刻意不再用 `totalUnread()`，改用共享算法
       *   `followRemainingByKey`（三处界面共用，见 `models.dart`）。
       *
       * ⚠️ 这是**有意偏离原版**的一处（用户拍板），
       *    与上面那条「追更中角标」是同类情况 ——
       *    断言必须跟着**用户要求**走，不能钉死在原版行为上。
       */
      expect(src, contains('followRemainingByKey('),
          reason: '★ 必须用共享算法（不是自己写一套）—— '
              '三处写三遍必然漂');
      expect(src, contains('widget.onUnreadChanged?.call('),
          reason: '★ 算出来要**推给底栏**（否则底部徽标不动）');
      /*
       * ★ 反向断言：旧路径**不许**回来。
       *   留着它会造成"两套语义并存"，比完全不用更糟 ——
       *   谁也说不清徽标显示的是哪个数。
       */
      expect(src, isNot(contains('SourinApi.totalUnread()')),
          reason: '★ 旧语义（SUM(unread_count)）已被用户否掉，'
              '不许并存 —— 两套语义并存会让徽标含义不可解释');
    });

    test('★ 标记已读走 mark_favorite_read', () {
      expect(src, contains('SourinApi.markFavoriteRead(f.key)'));
    });

    test('★ 标记已读后要刷新列表与未读数', () {
      final body = _methodBodyOf(src, 'Future<void> _markRead(');
      expect(body, contains('_load()'));
      expect(body, contains('_refreshUnread()'));
    });

    test('★★★ 更新条目必须显示 added（新增集数），不是 new_count（总数）' , () {
      /*
       * 原版 `FollowView.vue:257`         * ```vue
       * <span class="chip chip--brand">+{{ u.added }} 集 /span>
       * ```
       * 权威定义 `rust/sourin_core/src/store.rs:383`：`pub added: u32`（新增集数）　        *
       * 而 `models.dart` 的 `UpdateInfo` 读的是 `new_count`
       *    `store.rs:381` 的 *现在检测到的集数 *）
* 实测差异：从 10 集更到 13 集 →
* ```text
       * 原版  　 3 集　   （added         * 我们  　 13 集　  ★ 数值错了（那是总数
* ```
       */
      final notice = code('lib/ui/widgets/follow_update_notice.dart');
      final models = code('lib/core/models.dart');
      final updateInfo = _classBodyOf(models, 'class UpdateInfo {');

      // 解析侧：真名必须读对（唯一定义处 = models.dart
       expect(
        updateInfo,
        contains("j['added']"),
        reason: '★ 必须读 added（store.rs:383），不是 new_count',
      );
      expect(
        updateInfo,
        contains("j['latest_title']"),
        reason: '★ 必须读 latest_title（store.rs:386）' ,
      );

      // 渲染侧：组件必须用 added 那个字段
      expect(
        notice,
        contains('item.added'),
        reason: '★ 渲染的必须是 added（新增集数）',
      );
      expect(
        src,
        contains('UpdateInfo'),
        reason: '★ 追更页要用类型化的 UpdateInfo（走 SourinApi.checkUpdates）' ,
      );
      expect(
        src,
        isNot(contains('checkUpdatesRaw')),
        reason: '★ 绕行已撤：不能再自己调核心层解原始 JSON（第二份契约）' ,
      );
      expect(
        src,
        isNot(contains('u.newCount')),
        reason: '★ newCount 是 现在共几集 ，显示成"+N 集 数值是错的',
      );
    });

    test('★★★ 更新条目必须显示 latest_title（最新一集标题）', () {
      /*
       * 原版 `FollowView.vue:258`：`{{ u.latest_title }}`
       * 权威定义 `store.rs:386`：`pub latest_title: Option<String>`
       *
       * `models.dart` 读的是 `new_episode_title` —— 后端**从不下发** →
* 那一段「第13集」的次级文字永远不显示　        */
      final notice = code('lib/ui/widgets/follow_update_notice.dart');
      final models = code('lib/core/models.dart');
      final updateInfo = _classBodyOf(models, 'class UpdateInfo {');
      expect(
        updateInfo,
        contains("j['latest_title']"),
        reason: '★ 必须读 latest_title（store.rs:386）' ,
      );
      expect(notice, contains('item.latestTitle'), reason: '必须渲染出来');
    });

    test('★ 「N 部有更新」文案与原版一致（手动 toast 已随按钮删除）', () {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★★ 2026-09-25 变更：断言**改指到仍然承担它的地方**
       * ══════════════════════════════════════════════════════════════
       *
       * 用户原话：
       * > 追更页面,去掉检查更新,应该是自动更新 这三个模块的数据
       *
       * 原先这条断言查的是 `follow_page.dart` 里 `_checkUpdates()` 的
       * **成功 toast**（原版 `FollowView.vue:78-80`）：
       * ```dart
       * _flash(updates.isNotEmpty ? '发现 ${updates.length} 部有更新' : '已是最新，暂无更新');
       * ```
       * 而「检查更新」按钮被用户要求删掉后，`_checkUpdates` 也随之删除
       *（它的职责搬到了自动路径 `_maybeSweep`）——
       * 于是这两条 toast 字符串**在追更页不存在了**。
       *
       * # ★ 为什么不直接把这条测试删掉（那不是"放宽断言"吗）
       *
       * 原版的**用户可见文案**其实有两处，只有一处消失：
       * ```text
       * ① 「N 部有更新」区块      → ★ 仍然存在
       *    follow_update_notice.dart 的 FollowUpdateNotice
       *    （自动巡检拿到结果后，把那块提示渲染出来）
       * ② 手动点按钮后的 toast    → 删除（按钮没了，没有动作可回执）
       * ```
       * 所以这条断言**迁移到 ①**（它才是文案的真正承担者），
       * 而不是删掉 —— 删掉就等于「N 部有更新」这个文案失去守卫。
       *
       * ⚠️ 「已是最新，暂无更新」**确实无处可去了**：
       *    它是"用户点了按钮、结果没更新"的回执。自动路径**刻意不弹
       *    toast**（见 `_maybeSweep` 的说明：用户没主动点，
       *    弹一个红条/提示只会造成"我没点它啊？"的困惑）。
       *    所以这条字符串随按钮一起消失是**设计意图**，不是遗漏 ——
       *    下面用一条**反向断言**把它锁住，防止有人"补回来"。
       */
      final notice = code('lib/ui/widgets/follow_update_notice.dart');

      // ① 文案仍然存在（换了个地方承担）
      expect(
        notice,
        contains("' 部有更新'"),
        reason: '★「N 部有更新」是原版文案（FollowView.vue:252），'
            '自动巡检后由 FollowUpdateNotice 渲染',
      );

      // ② 手动 toast 已删除 —— 且**不该被补回来**
      expect(
        src,
        isNot(contains('已是最新，暂无更新')),
        reason: '★ 手动「检查更新」按钮已按用户要求删除 → '
            '它的回执 toast 也该消失（自动路径刻意不弹 toast）',
      );
      expect(
        src,
        isNot(contains('_checkUpdates')),
        reason: '★ 手动巡检方法应已删除（职责搬到自动路径 _maybeSweep）',
      );
    });
  });

  /*
   * ══════════════════════════════════════════════════════════════════════
   * ★★★ 本 group 已迁移到**详情页**（2026-09-25）
   * ══════════════════════════════════════════════════════════════════════
   *
   * # 为什么迁移（不是删测试）
   *
   * 用户原话：
   * > 追更这里 下面的 这两个操作按钮很丑,直接删了吧
   *
   * 追更页卡片下那两个按钮（追更铃铛 / 标记已读）被删掉之后，
   * `_toggleFollow` / `_unfavorite` 在追更页**没有调用点了** ——
   * 代理把它们一并删除（删得对：留着就是死代码）。
   *
   * ★ 但**契约本身一条都不能少**：
   * ```text
   * ① 切追更必须走 setFollowing，不能用 toggleFavorite
   *    （toggle_favorite 没有删除分支 → 「取消收藏」会变成「复活」）
   * ② 传 provider/nativeId + 元信息（不是 key）
   * ③ 失败也要刷新（否则界面停在旧状态，用户以为点成功了）
   * ④ 返回 null 时要刷新，不能假装成功
   * ```
   * 这些契约现在由 `lib/ui/detail_page.dart` 的 `_toggleFollow` 承担 ——
   * 追更页留的注释也明确指向它：
   * > 追更 / 取消追更现在在**详情页**（`lib/ui/detail_page.dart` 的
   * > `_toggleFollow`，同样走 `setFollowing`）。用户点卡片 → 进详情页
   * > → 在那里追更/收藏，路径是通的。
   *
   * ⚠️ **所以断言必须跟着"实际承担者"走，而不是跟着某个文件走**。
   *    把测试删掉 = 契约失去守卫；把断言留在追更页 = 假红。
   */
  group('详情页 · 追更开关（契约从追更页迁移过来，FollowView.vue:128-170）', () {
    late String src;

    setUpAll(() => src = code('lib/ui/detail_page.dart'));

    test('★★★ 切追更必须用 setFollowing *不能**用 toggleFavorite', () {
      /*
       * 原版 `FollowView.vue:98-127`（真 bug，实测复现）
       * > 这里原先调 `favApi.toggle(...)`，而 `toggle_favorite` 是
       * > **"不存在就新建、已删除就复活"** 的语义 —— 它**没有删除分支**。
       * > 于是「点铃铛关掉追更」会**让已取消的收藏复活**。
       */
      expect(src, contains('SourinApi.setFollowing('));
      expect(
        src,
        isNot(contains('toggleFavorite(')),
        reason: '★ 关追更会让已取消的收藏复活（原版 FollowView.vue:103）',
      );
    });

    test('★ 切追更传 provider/nativeId + 元信息（不是 key）', () {
      /*
       * 原版 `FollowView.vue:130-137`：传 provider/id 与元信息
       * 万一某行不存在，命令会新建一行（favorited: false）——
       * 也就是"只追更不收藏"。
       */
      final body = _methodBodyOf(src, 'Future<void> _toggleFollow(');
      expect(body, contains('widget.provider'));
      expect(body, contains('widget.id'));
      expect(body, contains('title:'));
      expect(body, contains('cover:'));
      expect(body, contains('kind:'));
    });

    test('★★★ 失败也要刷新（原版 FollowView.vue:147-155）', () {
      /*
       * 原版注释：
       * > 之前这里没有 try/catch，失败会冒泡上去导致后面的 `load()` 不执行
       * > —— 界面停在旧状态，用户以为点成功了。现在无论成败都刷新。
       */
      final body = _methodBodyOf(src, 'Future<void> _toggleFollow(');
      expect(body, contains('catch'), reason: '必须有 try/catch');
    });

    test('★ setFollowing 返回 null 时要回滚而不是假装成功', () {
      final body = _methodBodyOf(src, 'Future<void> _toggleFollow(');
      expect(body, contains('r != null'),
          reason: '★ 必须判返回值 —— null 表示后端没认，不能假装成功');
    });
  });

  group('追更页 · 已删除的切换入口（用户要求）', () {
    late String src;

    setUpAll(() => src = code('lib/ui/follow_page.dart'));

    test('★ 追更页卡片下不再有切换按钮（用户要求删掉）', () {
      /*
       * 用户原话：「追更这里 下面的 这两个操作按钮很丑,直接删了吧」
       * → `_MiniButton` 与 `_toggleFollow`/`_unfavorite` 都应消失。
       */
      expect(src, isNot(contains('_MiniButton')),
          reason: '★ 那两个操作按钮必须删掉（用户明确要求）');
      expect(src, isNot(contains('SourinApi.removeFavorite(')),
          reason: '取消收藏的入口也随按钮一起删了');
    });

    test('★ 但追更页必须留注释指向详情页（否则下一个人找不到入口）', () {
      /*
       * ⚠️ 这里查的是**原始源码**（不是 `code()` 剥注释后的）——
       *    因为要断言的**就是注释本身**：追更页要写明
       *    「追更/取消追更已迁到详情页」，否则维护者会以为功能丢了。
       *    用 `code()` 会把这个断言变成永远失败的假红。
       */
      final raw = File('lib/ui/follow_page.dart').readAsStringSync();
      expect(raw, contains('detail_page.dart'),
          reason: '★ 追更入口已迁到详情页 —— 追更页要说明去哪找，'
              '否则用户/维护者会以为功能丢了');
      expect(raw, contains('setFollowing'),
          reason: '注释里要点明详情页走的仍是 setFollowing（契约没变）');
    });
  });

  group('追更页 · 排序 / 分组 / 空态（FollowView.vue:198-202, 312-317）' , () {
    late String src;

    setUpAll(() => src = code('lib/ui/follow_page.dart'));

    test('★ 排序由后端负责，前端**不得**再排（否则会打乱"最近更新优先 ）' , () {
      /*
       * 原版 `FollowView.vue:198-202` 的 `currentList` 是 *纯选择**         * ```js
       * const currentList = computed(() => {
       *   if (tab.value === "continue") return continueList.value;
       *   if (tab.value === "all") return allFavs.value;
       *   return following.value;      // → 直接用后端顺序，不 sort
       * });
       * ```
       * 后端 `list_following_for_ui` 按 `last_update_at` 排（"最近有更新的排前面"         * 见 `rust/sourin_core/src/follow.rs:114-123` 一
* `commands.rs:287-293` 的说明：**不能**用巡检队列的顺序）　        *
       * ⚠️ 前端若自己 sort（比如按标题/按 unread），用户看到的顺序就与原版不同，
       *    而且"刚看到的更新下次刷新换位"这个 bug 会回来　        */
      final getter = _methodBodyOf(src, 'List<Favorite> get _currentList');
      expect(
        getter,
        isNot(contains('.sort(')),
        reason: '★ 排序是后端的职责（list_following_for_ui）—— 前端再排会打乱它',
      );
      expect(
        src,
        isNot(contains('.sort((a, b) =>')),
        reason: '追更列表不得在 UI 层排序' ,
      );
    });

    test('★ 原版没有分组 —— 不得自己发明（用户硬性要求）', () {
      /*
       * 原版 `FollowView.vue:318-360` 是一一 *平铺**的 `.fav-grid`         * 没有任何
group / section 概念　        * 用户要求「操作逻辑必须与原版一致」，所以不能加分组　        */
      expect(
        src,
        isNot(contains('groupBy')),
        reason: '原版无分组 —— 不得发明',
      );
      expect(
        src,
        isNot(contains('SliverStickyHeader')),
        reason: '原版无分组标题 —— 不得发明',
      );
    });

    test('★ 空态文案逐字对齐原版', () {
      // 原版 FollowView.vue:315-316（追更 收藏）与 :282-283（继续观看）
      expect(src, contains("'还没有追更的内容'"));
      expect(src, contains("'还没有收藏'"));
      expect(src, contains("'在详情页点击收藏，即可在这里追踪更新'"));
      expect(src, contains("'还没有观看记录'"));
      expect(src, contains("'开始播放后，这里会出现可以继续观看的内容'"));
    });

    test('★ 追更中的卡片**不再**打「追更中」角标（用户要求去掉）', () {
      /*
       * 原版 `FollowView.vue:329` 是 `:badge="f.following ? '追更中' : undefined"`。
       *
       * ★ 2026-09-25 用户要求去掉：
       * > 最近追更这里 下面不用显示 追更中 这三个字
       *
       * 理由（我在 follow_page.dart 里也写了）：这个列表本身就是
       * 「最近追更」，**每一项都是追更中的** —— 给每项打同一个标签
       * 没有任何区分度，纯占视觉空间。
       *
       * ⚠️ 这是**有意偏离原版**的一处（用户明确要求），
       *    所以断言也翻转过来了：必须**没有** badge。
       *    `PosterCard.badge` 参数本身保留（别处可能用）。
       */
      expect(src, isNot(contains("'追更中' : null")),
          reason: '★ 用户要求去掉「追更中」角标（有意偏离原版 FollowView.vue:329）');
      expect(src, isNot(contains('badge:')),
          reason: '追更页不再传 badge');
    });

    test('★★ 未读数角标改为「还剩几集没看」（**有意偏离原版**，用户要求）', () {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 这条断言**翻转过来了**（task-40，2026-09-25）
       * ══════════════════════════════════════════════════════════════
       *
       * 原来断言：`expect(src, contains('unread: f.unreadCount'));`
       * ```text
       * 依据：原版 FollowView.vue:328  :unread="f.unread_count"
       * 含义：unread_count = 巡检发现新集时**累加**（follow.rs:112）
       * ```
       *
       * 用户原话（逐字）把语义改成了「这条剧还剩多少集没看」：
       * > 这几个都应该按照这个追更这个剧还有多少集没看来显示这个徽标，
       * > 比如 12集，只看了一集 就显示11，
       * > 以此类推，当往后看到12集则计数器为0，纠正一下这里的逻辑
       *
       * ⇒ 新实现从 `remaining` map 取值（由共享算法算好传进来）。
       *   `_FavGrid` 是**独立** StatelessWidget，拿不到 FollowPageState
       *   的字段，所以通过构造参数 `remaining` 传入。
       *
       * ⚠️ 同样是**有意偏离原版**（用户拍板），断言跟着用户要求走。
       */
      expect(src, contains('unread: remaining['),
          reason: '★ 徽标值必须来自共享算法算出的 remaining map');
      expect(src, isNot(contains('unread: f.unreadCount')),
          reason: '★ 旧语义（巡检累加）已被用户否掉，不许并存');
      /*
       * ★ 0 的处理：`?? 0` —— PosterCard 内部是 `unread > 0` 才画
       *   ⇒ 看完最后一集 ⇒ 0 ⇒ **徽标消失**（用户明确要求的效果）
       */
      expect(src, contains('remaining[f.key] ?? 0'),
          reason: '★ 拿不到就该是 0（不显示），而不是 null/崩溃');
    });

    test('★ 继续观看的剩余时间文案（原版 FollowView.vue:191-196）' , () {
      expect(src, contains("'剩 \${m ~/ 60} 小时 \${m % 60} 分'"));
      expect(src, contains("'剩 \$m 分钟'"));
    });

    test('★ 继续观看显示「集数 · 剩余时间」', () {
      /*
       * 原版 FollowView.vue:301 —— 形态是「第N集 · 剩 X 分钟」。
       *
       * ══════════════════════════════════════════════════════════════
       * ⚠️ 本条**原来断言字面量** `p.episodeTitle ?? "单集"`
       * ══════════════════════════════════════════════════════════════
       *
       * task-63 之后那个内联写法被**有意**替换成 `progressDisplayEpisode(p)`
       * （`follow_page.dart:1335`），理由（源码注释逐字）：
       * ```text
       * `progressDisplayTitle` 现在也会拿 `episodeTitle` 兜底 ⇒
       * 若这一行仍写 `p.episodeTitle ?? "单集"`，
       * 标题与副标题会**显示同一个集名**（"第01集 · 第01集"）
       * ⇒ 所以抽成配对函数，用**同一个判据**判断"标题用掉了什么"。
       * ```
       * ⇒ ★ 断言字面量 = 断言**实现细节**，重构一次就假红
       *   （本仓铁律⑲：断言**结构/契约**，不要断言符号存在）。
       *
       * # 改成断言真正的契约
       * ```text
       * ① 文案里必须有「集数」那一段（由 progressDisplayEpisode 提供）
       * ② 必须有「 · 」分隔 + 剩余时间
       * ③ 旧的内联写法**不许**再出现（否则就是"两套判据并存"）
       * ```
       */
      expect(src, contains('progressDisplayEpisode(p)'),
          reason: '★★★ 「集数」文案必须走 `progressDisplayEpisode` —— '
              '它与 `progressDisplayTitle` 是**配对**的（防标题/副标题重复）');
      expect(src, contains(r"'${progressDisplayEpisode(p)} · $remaining'"),
          reason: '★ 形态必须是「<集数> · <剩余时间>」（原版 FollowView.vue:301）');
      expect(src, isNot(contains('p.episodeTitle ?? "单集"')),
          reason: '★★ 旧的内联写法不许再出现 —— 否则"标题用掉了 episodeTitle"'
              '这个判据就有两份，迟早漂移（那正是 task-63 修掉的缺陷）');
    });
  });

  group('追更页 · 每次返回都刷新（FollowView.vue:59-69）' , () {
    test('★ loadAll 是 public（shell 切回本 tab 时要能调）' , () {
      /*
       * 原版 `FollowView.vue:69`：`onActivated(loadAll)`
       * > 本页在 keepAlivePages 里，onMounted 只跑一次
* > 不刷新就会出现「明明刚追更，回来却看不到」　        *
       * Flutter 侧由 `shell.dart:1545` 通过 GlobalKey 调
* `_followKey.currentState?.loadAll()` —— 所以方法必须 *公开**
       * （`FollowPageState.loadAll`，不能写成 `_loadAll`）　        */
      final src = code('lib/ui/follow_page.dart');
      expect(
        src,
        contains('Future<void> loadAll()'),
        reason: '★ shell 要用 GlobalKey 调它（shell.dart:1545），必须是公开方法',
      );
      expect(src, contains('class FollowPageState extends State<FollowPage>'));
    });
  });

  // ═════════════════════════════════════════════════════════════════════   //  ① 铁律：不认
  // ═════════════════════════════════════════════════════════════════════   //  ① 铁律：不许 import flutter/material（两套 Theme 串台）
  // ═════════════════════════════════════════════════════════════════════ 
  group('行为 · 用真实 Provider 的 JSON 形状验证（端到端契约）' , () {
    /*
     * ⚠️ 这里的 JSON **逐字段抄自 Rust 源码**，不是我自己编的       *
     * ```rust
     * // rust/sourin_core/src/providers/cctv.rs:947-962 —— 央视最 2 个源
     * sources.push(PlaySource { code: "official".into(),
     *                           title: "官方 HLS".into(), count: 1, nested: vec![] });
     * sources.push(PlaySource { code: "cdn".into(),
     *                           title: "CDN 直连".into(), count: 4, nested: vec![] });
     *
     * // rust/sourin_core/src/providers/cycani.rs:906-924 —— 后端拼好的 badges
     * badges.push(format!("共 {n} 集
));
     * badges.push(if completed { "已完组 .into() } else { "连载中 .into() });
     * ```
     *
     * # 为什么必须用真实形状测（而不是我编一个好看的 JSON       *
     * 缺口①的**全部特征**就是"键名对不上 "      * ```text
     * 用 Rust 真名（title/count/nested）→ 修好后必须能解析出来
     * 用旧 Dart 名（name/episode_count）→ 修好前也"能解析 （读不到而已）"      * ```
     * 如果我编的测试 JSON 里同时写了两种键，那测试**永远通过**       * 无论代码读哪个 —— 等于没测。所以必须用**只有真名**的形状　      */

    /// `cctv.rs:947-962` 的真实输出（**只有** Rust 真名，没有 name/episode_count
     const cctvDetailJson = {
      'id': 'cctv:c899032a-0000-0000-0000-000000000000',
      'title': 'CCTV-1 综合',
      'cover': 'https://example.invalid/logo.png',
      'badges': <String>[],
      'meta': <String, dynamic>{},
      'sources': [
        {'code': 'official', 'title': '官方 HLS', 'count': 1},
        {'code': 'cdn', 'title': 'CDN 直连', 'count': 4},
      ],
      'episodes': <dynamic>[],
    };

    test('★★★ 央视真实 2 源能被解析出标题与集数（修好前全是空/0）' , () {
      /*
       * ★ 解析入口随根因修复迁移：
       * ```text
       * 修复剧
parseDetailSources(rawJson)  → 绕行层的平行类型
       * 修复后
MediaDetail.fromJson(rawJson) → 唯一的类型化契约
       * ```
       * 断言的是**同一份真实 JSON 形状**，只是走正规入口　        */
      final detail = MediaDetail.fromJson(cctvDetailJson);
      final nodes = detail.sources;

      expect(nodes.length, 2);
      expect(
        nodes[0].title,
        '官方 HLS',
        reason: '★ 读 title 才有值；读 name 会得到空值' ,
      );
      expect(
        nodes[0].count,
        1,
        reason: '★ 读 count 才有值；读 episode_count 会得到 0',
      );
      expect(nodes[1].title, 'CDN 直连');
      expect(nodes[1].count, 4);
      expect(nodes[0].label, '官方 HLS', reason: 'label = title || code');
    });

    test('★★★ 元信息：真实 badges 形状能解析出来' , () {
      /*
       * cycani.rs:906-924 的真实输出　        *
       * ★ 解析入口随根因修复迁移到 `MediaDetail.fromJson`
       *   （`MediaDetail.badges` / `.meta` 已按 model.rs:212,217 补上），
       *   不再需要绕行层的 `DetailRawMeta`　        */
      final d = MediaDetail.fromJson({
        'id': 'cycani:3862',
        'title': '无职转生 第三季' ,
        'badges': ['更新至 12 集', '连载中'],
        'meta': {'year': '2024', 'area': '日本', 'score': 9.2},
      });
      expect(d.badges, ['更新至 12 集', '连载中'],
          reason: '★ 后端拼好的文案与顺序必须原样透传');
      expect(d.meta['score'], 9.2);
    });

    test('★ 缺口①的反向证据：旧键名形状确实读不到（说明这个测试有效）' , () {
      /*
       * 这条是 *给上一条做对照**的：证明"读 name/episode_count 会失败
* 如果两条都过，说明测试真的在区分两种键名 —— 而不是恒真　        *
       * ⚠️ 注意 `PlaySource.fromJson` 为了过渡期兼容 *也认**旧键名
*    （插件与 Rust 谁先改都不坏）。所以反向证据不能靠"旧键名读不到"         *    而要断言**真名优先且真名缺失时回退为空**——见下面两段　        */
      final real = MediaDetail.fromJson({
        'sources': [
          {'code': 'x', 'title': '真名标题', 'count': 7},
        ],
      });
      expect(real.sources[0].title, '真名标题');
      expect(real.sources[0].count, 7);

      // 真名缺失 → 标题空、集数 0（这正是修好前的症状
       final missing = MediaDetail.fromJson({
        'sources': [
          {'code': 'x'},
        ],
      });
      expect(missing.sources[0].title, isEmpty,
          reason: '真名缺失 → 标题空（修好前的症状）' );
      expect(missing.sources[0].count, 0, reason: '真名缺失 → 集数 0（修好前的症状）');
      expect(missing.sources[0].label, 'x', reason: '此时只能退回显示 code');
    });

    test('★★★ 追更更新：真实 UpdateInfo 形状（store.rs:370-387）' , () {
      /*
       * 全部字段名抄自 `rust/sourin_core/src/store.rs:370-387`         * ```rust
       * pub key, title, cover, provider,
       * pub old_count, pub new_count, pub added, pub latest_title
       * ```
       * 场景：追更的剧从 2 集更到 13 集　        *
       * ★ 解析入口随根因修复迁移：绕行层删掉后直接用 `UpdateInfo.fromJson`　        */
      final item = UpdateInfo.fromJson({
        'key': 'cycani:3862',
        'title': '无职转生 第三季' ,
        'cover': null,
        'provider': 'cycani',
        'old_count': 2,
        'new_count': 13,
        'added': 11,
        'latest_title': '第13集',
      });

      expect(item.added, 11,
          reason: '★ 11 = 13-2（新增）；若读 new_count 会显示成 "+13 集 （错）' );
      expect(item.latestTitle, '第13集');
      expect(item.title, '无职转生 第三季' );
      expect(item.oldCount, 2);
      expect(item.newCount, 13);
      expect(item.provider, 'cycani');
    });
  });

  group('铁律 · 统一 material_ui（禁止 flutter/material）' , () {
    const mine = [
      'lib/ui/detail_page.dart',
      'lib/ui/follow_page.dart',
      'lib/ui/widgets/detail_raw_meta.dart',
      'lib/ui/widgets/follow_update_notice.dart',
    ];

    for (final path in mine) {
      test('$path 用 material_ui 而不是 flutter/material', () {
        /*
         * Flutter 3.47 把 material 拆成了独立的 `material_ui` 包
* 仓库里同时存在两套 Material → 两个**不同的
* `Theme`
         * InheritedWidget 类型，互相看不见
* ```text
         * shell.dart      → material_ui 的 MaterialApp / Theme
         * lib/ui 下的页面 → flutter/material 的 Theme.of
         *   → 找不到祖先 → 走兜底
ThemeData.fallback() → **亮色**
         * ```
         * 表现是「主题明明设了深色，文字却是深色」（对比度 1.16:1，几乎看不见）
* 所以这里必须逐字断言
import 行　          */
        final src = code(path);
        expect(
          src,
          contains("import 'package:material_ui/material_ui.dart';"),
          reason: '$path 必须 import material_ui',
        );
        expect(
          src,
          isNot(contains("package:flutter/material.dart")),
          reason: '★ 禁止 import flutter/material —— 会造成两套 Theme 串台',
        );
      });
    }

    test('★ 颜色角色名不能混用（Material vs forui 是两套命名）', () {
      /*
       * ```text
       * Theme.of(context).colorScheme  → onSurface / onSurfaceVariant / outlineVariant
       * AppPalette.of(context)      → foreground / mutedForeground / border
       * ```
       * 把 forui 的名字用在 Material 的 colorScheme 一 *编译不过**         * 所以这条其实是组 复制粘贴"兜底的静态检查　        */
      for (final path in mine) {
        final src = code(path);
        if (src.contains('Theme.of(context).colorScheme')) {
          expect(
            src,
            isNot(contains('colors.mutedForeground')),
            reason: '$path 用了 Material 的 colorScheme，就不能写 forui 的角色名',
          );
          expect(src, isNot(contains('colors.foreground')));
          expect(src, isNot(contains('colors.border')));
        }
      }
    });
  });

  // ═════════════════════════════════════════════════════════════════════   //  ① 行为测试：线路树解析（这是真逻辑，不是文本匹配）
  // ═════════════════════════════════════════════════════════════════════ 
  group('行为 · PlaySource 解析（真实键名）', () {
    /// 走 *唯一**的解析入口 `MediaDetail.fromJson`（与详情页真实链路一致）
    List<PlaySource> sourcesOf(Map<String, dynamic> j) =>
        MediaDetail.fromJson(j).sources;

    test('★ 按 Rust 真名 title/count/nested 解析', () {
      /*
       * 这就是 `rust/sourin_core/src/model.rs:177-187` 的实际形状
* 用真名解析成功 = 缺口①修好了　        */
      final nodes = sourcesOf({
        'sources': [
          {'code': 'cychub', 'title': 'CYCHUB 线路', 'count': 24},
          {
            'code': 'cdn',
            'title': 'CDN 直连',
            'count': 4,
            'nested': [
              {'code': 'cdn-hd', 'title': '高清', 'count': 2},
            ],
          },
        ],
      });

      expect(nodes.length, 2);
      expect(nodes[0].code, 'cychub');
      expect(nodes[0].title, 'CYCHUB 线路', reason: '★ 真名是 title，不是 name');
      expect(nodes[0].count, 24, reason: '★ 真名是 count，不是 episode_count');
      expect(nodes[0].nested, isEmpty);

      expect(nodes[1].nested.length, 1, reason: '★ nested 必须被解析出来' );
      expect(nodes[1].nested[0].code, 'cdn-hd');
      expect(nodes[1].nested[0].title, '高清');
      expect(nodes[1].nested[0].count, 2);
    });

    test('★ 嵌套可以任意深度（原版递归渲染的前提）', () {
      final nodes = sourcesOf({
        'sources': [
          {
            'code': 'l1',
            'title': 'L1',
            'nested': [
              {
                'code': 'l2',
                'title': 'L2',
                'nested': [
                  {'code': 'l3', 'title': 'L3'},
                ],
              },
            ],
          },
        ],
      });
      expect(nodes[0].nested[0].nested[0].code, 'l3');
    });

    test('★ 旧键名（name/episode_count）仍然兼容 —— 插件一 Rust 谁先改都不坏', () {
      final nodes = sourcesOf({
        'sources': [
          {'code': 'x', 'name': '旧名', 'episode_count': 7},
        ],
      });
      expect(nodes[0].title, '旧名');
      expect(nodes[0].count, 7);
    });

    test('★ 真名优先于旧名（两种键同时出现时不能读错）' , () {
      /*
       * ⚠️ 这条是 *给上一条兜底 *的：如果 `fromJson` 里写成
*    `j['name'] ?? j['title']`，上面那条仍然会绿（因为只有旧名），
       *    但真名会被旧名盖掉。所以必须有一个 两种都有"的输入来钉住优先级　        */
      final nodes = sourcesOf({
        'sources': [
          {'code': 'x', 'title': '真名', 'name': '旧名', 'count': 9, 'episode_count': 3},
        ],
      });
      expect(nodes[0].title, '真名', reason: '★ 真名必须优先');
      expect(nodes[0].count, 9, reason: '★ 真名必须优先');
    });

    test('★ label 回退到 code（原版 `s.title || s.code`）' , () {
      final nodes = sourcesOf({
        'sources': [
          {'code': 'cdn', 'title': ''},
        ],
      });
      expect(nodes[0].label, 'cdn', reason: '标题为空时必须显示 code，不能是空壳');
    });

    test('★ 缺 count → 0（不显示角标），缺 nested → 空' , () {
      final nodes = sourcesOf({
        'sources': [
          {'code': 'a', 'title': 'A'},
        ],
      });
      expect(nodes[0].count, 0);
      expect(nodes[0].nested, isEmpty);
    });

    test('★ flattened 覆盖所有层级（偏好查找要用它）', () {
      final nodes = sourcesOf({
        'sources': [
          {
            'code': 'l1',
            'title': 'L1',
            'nested': [
              {
                'code': 'l2',
                'title': 'L2',
                'nested': [
                  {'code': 'l3', 'title': 'L3'},
                ],
              },
            ],
          },
        ],
      });
      final flat = nodes[0].flattened.map((e) => e.code).toList();
      expect(flat, ['l1', 'l2', 'l3'], reason: '任意深度都要能命中' );
    });

    test('★ sources 缺失 / 不是数组时不崩（退化成空）', () {
      expect(MediaDetail.fromJson(const {}).sources, isEmpty);
      expect(MediaDetail.fromJson(const {'sources': null}).sources, isEmpty);
    });

    test('★ sources 里混了非对象元素时跳过，不整体失败' , () {
      final nodes = sourcesOf({
        'sources': [
          'garbage',
          {'code': 'ok', 'title': '好'},
          null,
        ],
      });
      expect(nodes.length, 1);
      expect(nodes.single.code, 'ok');
    });
  });

  group('行为 · MediaDetail.badges / meta（model.rs:212,217）' , () {
    test('★ 读 badges（model.rs:212）' , () {
      final m = MediaDetail.fromJson({
        'badges': ['连载中', '更新至 12 集', '9.2 分'],
      });
      expect(m.badges, ['连载中', '更新至 12 集', '9.2 分']);
    });

    test('★ 读 meta（model.rs:217）' , () {
      final m = MediaDetail.fromJson({
        'meta': {'year': '2026', 'area': '日本'},
      });
      expect(m.meta['year'], '2026');
      expect(m.meta['area'], '日本');
    });

    test('★ badges 缺失 / 类型错 → 空列表（不是抛异常）', () {
      expect(MediaDetail.fromJson(const {}).badges, isEmpty);
      expect(MediaDetail.fromJson(const {'badges': null}).badges, isEmpty);
      expect(MediaDetail.fromJson(const {'badges': 'garbage'}).badges, isEmpty);
      expect(MediaDetail.fromJson(const {}).meta, isEmpty);
      expect(MediaDetail.fromJson(const {'meta': 'garbage'}).meta, isEmpty);
    });

    test('★ badges 里混了非字符串 → 转成字符串而不是丢整条', () {
      final m = MediaDetail.fromJson({
        'badges': ['a', 1, true],
      });
      expect(m.badges, ['a', '1', 'true']);
    });
  });

  group('行为 · UpdateInfo（added / latest_title）' , () {
    test('★★★ 读 added（store.rs:383），不是 new_count', () {
      /*
       * 这是那个"数值错了 的真 bug 的直接回归：
       * ```text
       * 什 10 集更到 13 集
*   added = 3      → 原版显示的
*   new_count = 13 → 我们以前显示的（错的
* ```
       *
       * ★ 绕行层（FollowUpdateItem）已撤除 —— 现在 `UpdateInfo` 自己
       *   就带 `added` / `latestTitle`，所以断言直接打在模型上　        */
      final item = UpdateInfo.fromJson({
        'key': 'cycani:1',
        'title': '某番',
        'old_count': 10,
        'new_count': 13,
        'added': 3,
        'latest_title': '第13集',
      });
      expect(item.added, 3, reason: '★ 必须是 added=3，不是 new_count=13');
      expect(item.latestTitle, '第13集');
    });

    test('★ latest_title 缺失 → null（不渲染那一段）', () {
      final item = UpdateInfo.fromJson({
        'key': 'k',
        'title': 't',
        'added': 1,
      });
      expect(item.latestTitle, isNull);
    });

    test('★ added 缺失 → 0（不是崩）' , () {
      final item = UpdateInfo.fromJson({'key': 'k', 'title': 't'});
      expect(item.added, 0);
    });

    test('★★★ 已废弃的旧键名不再被读（防止"第二份契约 复活）' , () {
      /*
       * 旧模型读的是 `new_episode_title` —— 后端**从不下发**那个键
* 撤绕行时保留了 `newEpisodeTitle` 这个 `@Deprecated` 转发 getter
       * 给尚未迁移的调用点（无独立存储，不可能漂移）　        *
       * 这条断言钉住  *真名 `latest_title` 才是唯一数据来源** —
* 只给旧键名时拿不到值（这正是修好前的症状）　        */
      final legacy = UpdateInfo.fromJson({
        'key': 'k',
        'title': 't',
        'added': 1,
        'new_episode_title': '第 集' ,
      });
      expect(
        legacy.latestTitle,
        isNull,
        reason: '★ 旧键名后端从不下发 —— 读它永远是 null（这就是那个静默 bug）' ,
      );

      // 真名才有值
final real = UpdateInfo.fromJson({
        'key': 'k',
        'title': 't',
        'added': 1,
        'latest_title': '第1集',
      });
      expect(real.latestTitle, '第1集');
    });
  });

  // ═════════════════════════════════════════════════════════════════════   //  ① 行为测试：组件真的能渲染（widget 测试    // ═════════════════════════════════════════════════════════════════════ 
  group('行为 · 组件渲染', () {
    /// 用 *唯一**的解析入口造线路树（与详情页真实链路一致）
    List<PlaySource> sourcesOf(Map<String, dynamic> j) =>
        MediaDetail.fromJson(j).sources;

    testWidgets('DetailSourcePicker 渲染多层线路 + 集数角标', (tester) async {
      final nodes = sourcesOf({
        'sources': [
          {'code': 'cychub', 'title': 'CYCHUB 线路', 'count': 24},
          {
            'code': 'cdn',
            'title': 'CDN 直连',
            'count': 4,
            'nested': [
              {'code': 'cdn-hd', 'title': '高清线路', 'count': 2},
              {'code': 'cdn-sd', 'title': '标清线路', 'count': 2},
            ],
          },
        ],
      });

      await tester.pumpWidget(
        _shell(
          DetailSourcePicker(
            sources: nodes,
            active: 'cdn-hd',
            onPick: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 顶层两项
      expect(find.text('CYCHUB 线路'), findsOneWidget);
      expect(find.text('CDN 直连'), findsOneWidget);
      // ★ 嵌套层也要渲染出来（原版 SourcePicker.vue:74-80 的递归
       expect(
        find.text('高清线路'),
        findsOneWidget,
        reason: '★ 嵌套线路必须可见 —— 这是原来完全缺失的能力' ,
      );
      expect(find.text('标清线路'), findsOneWidget);
      // 集数角标
      expect(find.text('24'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
      expect(find.text('2'), findsNWidgets(2));
    });

    testWidgets('DetailSourcePicker 子层只有一项时整层隐藏（原版 visible 判据）' , (tester) async {
      /*
       * 原版 `SourcePicker.vue:35`：`visible = sources.length > 1`         * 而同组件 `:74-80` 的递归调用**没有**给它豁免 —— 子层同样受这条约束　        *
       * `SourcePicker.vue:28-34` 的注释解释了为什么连"唯一可见的层级 也不留：
       * > depth 0 且只有一个源时也隐藏，因为单独一个源没有「选择」的意义
* > 详情页标题区已展示过站名　        *
       * ⚠️ 这条是 *刻意的 *，不是我们的缺失 —— 别为了 让嵌套看得见"
       *    去把它改成 子层永远显示"，那会与原版不一致　        */
      final nodes = sourcesOf({
        'sources': [
          {'code': 'a', 'title': 'A', 'count': 1},
          {
            'code': 'b',
            'title': 'B',
            'count': 1,
            'nested': [
              {'code': 'b-1', 'title': '唯一的子线路', 'count': 1},
            ],
          },
        ],
      });

      await tester.pumpWidget(
        _shell(DetailSourcePicker(sources: nodes, active: 'a', onPick: (_) {})),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('唯一的子线路'),
        findsNothing,
        reason: '子层只有一页 → 整层隐藏（原版 SourcePicker.vue:35 无豁免）',
      );
    });

    testWidgets('DetailSourcePicker 单选项的层不渲染（原版 visible 判据）' , (tester) async {
      final nodes = sourcesOf({
        'sources': [
          {'code': 'only', 'title': '唯一线路', 'count': 1},
        ],
      });

      await tester.pumpWidget(
        _shell(
          DetailSourcePicker(sources: nodes, active: 'only', onPick: (_) {}),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('唯一线路'),
        findsNothing,
        reason: '原版 `visible = sources.length > 1` —— 一个选项没有选择的意义' ,
      );
    });

    testWidgets('DetailSourcePicker 点嵌套项时回调拿到正确 code', (tester) async {
      PlaySource? picked;
      final nodes = sourcesOf({
        'sources': [
          {'code': 'a', 'title': 'A', 'count': 1},
          {
            'code': 'b',
            'title': 'B',
            'count': 1,
            'nested': [
              {'code': 'b-2', 'title': 'B2', 'count': 1},
              {'code': 'b-3', 'title': 'B3', 'count': 1},
            ],
          },
        ],
      });

      await tester.pumpWidget(
        _shell(
          DetailSourcePicker(
            sources: nodes,
            active: 'a',
            onPick: (s) => picked = s,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('B2'));
      await tester.pumpAndSettle();

      expect(picked, isNotNull);
      expect(picked!.code, 'b-2', reason: '嵌套项的 code 要原样传给 get_episodes');
    });

    testWidgets('DetailSourcePicker 标题空时显示 code（不留空壳）', (tester) async {
      final nodes = sourcesOf({
        'sources': [
          {'code': 'cdn', 'title': ''},
          {'code': 'other', 'title': '其它'},
        ],
      });

      await tester.pumpWidget(
        _shell(DetailSourcePicker(sources: nodes, active: '', onPick: (_) {})),
      );
      await tester.pumpAndSettle();

      expect(find.text('cdn'), findsOneWidget, reason: '原版 `s.title || s.code`');
    });

    testWidgets('FollowUpdateNotice 显示 added — latest_title', (tester) async {
      // ⚠️ 重建说明：`buildUpdateItems` 已随绕行层撤除
      //    （见 `follow_update_notice.dart` 文件头）。这里改走
      //    `UpdateInfo.fromJson` —— 与下面注释里那份 Rust 真名 JSON 同形。
      final items = [
        UpdateInfo.fromJson(const {
          'key': 'a',
          'title': '某番',
          'old_count': 10,
          'new_count': 13,
          'added': 3,
          'latest_title': '第13集',
        }),
      ];

      await tester.pumpWidget(_shell(FollowUpdateNotice(items: items)));
      await tester.pumpAndSettle();

      expect(find.text('某番'), findsOneWidget);
      expect(
        find.text('+3 集'),
        findsOneWidget,
        reason: '★ 必须是新增 3 集，不是总数 13 集',
      );
      expect(
        find.text('第13集'),
        findsOneWidget,
        reason: '★ latest_title 以前永远不显示（读错键名）' ,
      );
      /*
       * 「N 部有更新」的计数是 `Text.rich`（`TextSpan` 拼的），
       * 所以 `find.text('1')` 匹配不到 —— 它比对的是整段纯文本
* 用 `find.textContaining` 匹配拼好后的整句　        */
      expect(
        find.textContaining('部有更新'),
        findsOneWidget,
        reason: '　  部有更新」的头部计数',
      );
      expect(
        find.textContaining('1 部有更新'),
        findsOneWidget,
        reason: '★ 计数必须是 items.length=1，不是 added 或别的数',
      );
    });

    testWidgets('FollowUpdateNotice 无 latest_title 时不渲染那一段', (tester) async {
      // ⚠️ 同上：`buildUpdateItems` 已撤除，改走
      //    `UpdateInfo.fromJson`（无 latest_title 键）。
      final items = [
        UpdateInfo.fromJson(const {'key': 'a', 'title': '某番', 'added': 1}),
      ];

      await tester.pumpWidget(_shell(FollowUpdateNotice(items: items)));
      await tester.pumpAndSettle();

      expect(find.text('某番'), findsOneWidget);
      expect(find.text('+1 集'), findsOneWidget);
    });
  });
}

// ═══════════════════════════════════════════════════════════════════════ //  辅助
// ═══════════════════════════════════════════════════════════════════════ 
/// 取某个调用点的实参文本（到配对的右括号为止）
///
/// 用于"这个方法里必须 / 不能出现某写法"这类断言
String _callSiteOf(String src, String marker) {
  final start = src.indexOf(marker);
  if (start < 0) fail('源码里找不到调用点：$marker');
  var depth = 0;
  var i = start + marker.length - 1; // 从 marker 的 `(` 开始
  final buf = StringBuffer();
  for (; i < src.length; i++) {
    final c = src[i];
    buf.write(c);
    if (c == '(') depth++;
    if (c == ')') {
      depth--;
      if (depth == 0) break;
    }
  }
  return buf.toString();
}

/// 取一个类的**类体**文本（到配对的大括号为止）
///
/// ⚠️ 重建说明：原文件在损坏中丢了这个函数的定义
///    （全文只有 3 处调用、没有定义）。语义与 [_methodBodyOf] 完全一致，
///    所以直接委派。
String _classBodyOf(String src, String marker) => _methodBodyOf(src, marker);

String _methodBodyOf(String src, String marker) {
  final start = src.indexOf(marker);
  if (start < 0) fail('源码里找不到方法: $marker');
  final open = src.indexOf('{', start);
  if (open < 0) fail('方法没有方法体  $marker');
  var depth = 0;
  final buf = StringBuffer();
  for (var i = open; i < src.length; i++) {
    final c = src[i];
    buf.write(c);
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) break;
    }
  }
  return buf.toString();
}

/// 把控件套进真实的壳（material_ui 的 MaterialApp + forui 主题  ///
/// ⚠️ 必须用 **material_ui** 的 MaterialApp
///
/// 用 `flutter/material` 的会让 `Theme.of` 找不到祖先、走兜底亮色 —— /// 那正是项目踩过的"两套 Theme 串台"bug。测试里同样要一致
Widget _shell(Widget child) {
  return MaterialApp(
    theme: AppTheme.themeFor(Brightness.light),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}
