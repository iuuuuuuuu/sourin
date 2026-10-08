// ═══════════════════════════════════════════════════════════════════════
//  task-62：右侧面板 B + C —— 选集**固定高度** + **自动滚动到当前集**
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
//
// > 下面剧集高度固定一下，加一个剧集自动滚动到当前观看剧集位置的功能，
// > 当然进入到这个页面 上一集 下一集，也都要自动联动滚动到当前剧集到可视区域
//
// # 本文件测什么
//
// ```text
// B  选集固定高度：kEpsViewportH 这个常量真的被用上，且高度真的是它
// C  自动滚动：三条触发路径 + ★ **只滚选集、不滚外层 ListView**
// ```
//
// ══════════════════════════════════════════════════════════════════════
// ★★★ 本文件最重要的一条：**外层 ListView 的 offset 不变**
// ══════════════════════════════════════════════════════════════════════
//
// `Scrollable.ensureVisible(ctx)` 会**向上遍历所有 `Scrollable`** ——
// 而详情页外层就是一个 `ListView` ⇒ 用它会把**整页**滚走。
// 本仓有同族真实事故：task-3「设置页往下滑会被自动拉回」
// （`spatial_nav.dart` 的 `_scrollIntoView` 用了同一个 API）。
//
// ⇒ ★ 所以本文件的核心断言是：
//    **滚完选集之后，外层 ListView 的 offset 必须还是 0**。
//
// ⚠️ 这条断言**必须能变红**（红度证明见文件末尾的说明）——
//    若把实现换成 `Scrollable.ensureVisible`，它就会红。
//
// 跑法：
//   powershell -File .probe\flutter_test_lock.ps1 `
//     -Paths 'test/t61_panel_scroll_test.dart' -Agent panel2

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/ui/detail_page.dart';

/// 剥掉 `//` 与 `/* */` 注释（**保留字符串字面量**）
///
/// ⚠️ 本仓铁律⑤：`grep`/`contains` 必须先剥注释 ——
///    我在源码注释里**刻意引用**了 `Scrollable.ensureVisible` 来解释
///    "为什么不能用它"；不剥的话那条"不许出现"的断言会被**注释**弄成假红。
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote;
  while (i < src.length) {
    final c = src[i];
    final n = i + 1 < src.length ? src[i + 1] : '';
    if (quote != null) {
      if (c == r'\') {
        out.write(c);
        if (n.isNotEmpty) {
          out.write(n);
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
    if (c == '/' && n == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && n == '*') {
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

void main() {
  late String raw;
  late String src;

  setUpAll(() {
    raw = File('lib/ui/detail_page.dart').readAsStringSync();
    src = stripComments(raw);
  });

  // ═══════════════════════════════════════════════════════════════════
  //  B —— 选集**固定高度**
  // ═══════════════════════════════════════════════════════════════════
  group('B 选集固定高度（Owner：「下面剧集高度固定一下」）', () {
    test('★★★ 选集区必须是**固定高度**的盒子里（不再是无限往下长的 Wrap）',
        () {
      /*
       * 改前：`Padding(child: Wrap(...))` —— Wrap 会**无限往下长**：
       * ```text
       * 24 集 = 8 行 ≈ 300px，27 集 ≈ 406px
       * ⇒ 下面的「播放源」等区块被一路推下去
       * ```
       * 改后：`SizedBox(height: epsH, child: Scrollbar(
       *          child: SingleChildScrollView(child: Wrap(...))))`
       *
       * ⚠️ 2026-09-27 第三轮：`height:` 的实参从**字面常量**改成**算出来的
       *    `epsH`**（Owner 第二次投诉「还是有留白」的根因就是定值 148
       *    在 800px 高的面板里留下 **181px 底部死区**）。
       * ```text
       * 契约没变：仍然是"固定高度 + 可滚"，
       *   只是那个高度 = max(kEpsViewportH, 可用高 − 选集之上实测高)
       *   ★ 它**仍然不随集数增长** —— Owner 那句"剧集高度固定一下"的本意
       *     就是别让 24 集撑成 8 行把页面顶下去。
       * ```
       */
      expect(src.contains('height: epsH'), isTrue,
          reason: '★★★ 选集必须装在**固定高度**的盒子里（现在是算出来的 `epsH`）'
              '—— 否则集数越多页面越长（Owner 报的正是这个）');
      expect(src.contains('kEpsViewportH'), isTrue,
          reason: '★ `kEpsViewportH` 必须仍是**下限** —— 极矮窗口下不能让'
              '选集缩成看不见');
      expect(src.contains('SingleChildScrollView'), isTrue,
          reason: '★★ 固定高度 + 可滚 —— 否则超出那部分就**看不见**了'
              '（比"页面变长"更糟：等于把后面的集藏起来）');
    });

    test('★★★ 选集高度必须**吃掉剩余空间**（消掉底部死区）', () {
      /*
       * ★ Owner 第二次投诉：「还是有留白，可以好好优化一下吗？看着不协调」
       *
       * 真机实测（pid 33212）：
       * ```text
       * 内容到 y=618 就结束了，面板高到 y=799
       * ⇒ ★ 底部死区 **181px**
       * ```
       * 根因：`kEpsViewportH = 148` 是**定值**，不随面板高度变化。
       *
       * ⇒ 修法：`epsH = max(kEpsViewportH, 可用高 − 选集之上实测高 − 尾距)`
       *   ★ 而"选集之上实测高"必须是**量**出来的（`_topKey` 的 RenderBox），
       *     不能估算 —— 估算会随主题/字号/有无续播条/有无播放源区漂移，
       *     而**漂移的判据 = 假的判据**。
       */
      expect(src.contains('final rest = availH - topH - Sp.x6 - Sp.x16;'),
          isTrue,
          reason: '★★★ 必须按"可用高 − 选集之上高 − 尾距"算剩余空间；'
              '★ 尾距不能漏（Sp.x6 是选集与下一区块的间距，'
              'Sp.x16 是 ListView 底部内边距）—— 漏了会多出一截可滚空白');
      expect(src.contains('return rest > kEpsViewportH ? rest : kEpsViewportH;'),
          isTrue,
          reason: '★★ 只在剩余空间**更大**时才撑开 ⇒ `kEpsViewportH` 仍是下限');
      expect(src.contains('final GlobalKey _topKey'), isTrue,
          reason: '★★★ "选集之上"的高度必须**实测**（RenderBox.size.height）—— '
              '估算会漂移');
      expect(src.contains('void _measureTop()'), isTrue,
          reason: '★ 测量函数必须存在');
      expect(src.contains('if (_topH != null && (h - _topH!).abs() < 0.5) return;'),
          isTrue,
          reason: '★★★ 必须**比较**后再 setState —— post-frame 里无条件 setState '
              '会排下一帧 ⇒ **无限重建循环**');
    });

    test('★★★ 高度常量必须是 148（3 行可见 + 第 4 行露一点）', () {
      /*
       * ★ 这条钉住**具体数值** —— 只测"用了常量"是不够的：
       *   若把 `kEpsViewportH` 改成 40（一行），测试照样绿，
       *   但用户只能看到一集 ⇒ 完全不可用。
       *
       * 148 的推导（见源码注释）：
       * ```text
       * 按钮 ≈ 38（文字 20 + padding 16 + 边框 2）
       * 一行 ≈ 46（38 + runSpacing 8）
       * 3 行 = 130；+18 让第 4 行露一点 ⇒ 用户看得出"还能滚"
       * ```
       */
      expect(src.contains('kEpsViewportH = 148'), isTrue,
          reason: '★★★ 高度必须是 148 —— '
              '130（3 行整）会让底部边界"太干净"，用户看不出还能滚；'
              '40 之类更小的值等于只显示一行，完全不可用');
    });

    test('★★★ 三个必需属性都还在：onTap / active / played', () {
      /*
       * ★ 重构最容易"顺手删掉"的就是这三个 —— 而它们是**用户可见的功能**：
       * ```text
       * onTap   ⇒ 点选集能播（删了就是"点了没反应"）
       * active  ⇒ 当前选中高亮（Owner 2026-09-21 明确要求过）
       * played  ⇒ 看过的高亮（区分"看过但没选中"）
       * ```
       */
      expect(src.contains('onTap: () => _play(ep)'), isTrue,
          reason: '★★★ `onTap` 必须还在 —— 否则点选集没反应');
      expect(src.contains('active: _activeEpisodeId == ep.id'), isTrue,
          reason: '★★★ `active` 必须还在 —— 当前集高亮（Owner 明确要求）');
      expect(src.contains('played: _resume?.episodeId == ep.id'), isTrue,
          reason: '★★★ `played` 必须还在 —— 看过的高亮');
    });

    test('★★★ 头部必须有**顶部间距**（Owner：「封面距离顶部应该有点间距」）',
        () {
      /*
       * ★ Owner 原话（附截图）：
       * > 封面距离顶部应该有点间距
       *
       * 逐像素实测（截图 1280×800）：
       * ```text
       * y=0..38    标题栏（黑）
       * y=39       过渡
       * y=40       ★ 封面/标题**从这里就开始** —— 与标题栏**零间距**
       * ```
       * 根因：头部那个 `Padding` 只给了 `horizontal`，**没有** top。
       *
       * ⚠️ 独立详情页（非 embedded）上面是「返回」按钮（自带 `Sp.x4`）
       *    ⇒ 那时本来就有间距 ⇒ 修复**只**影响 embedded（合并页）。
       *    用条件内边距 ⇒ 独立详情页的观感**不动**（冻结契约）。
       */
      expect(src.contains('widget.embedded ? Sp.x4 : 0'), isTrue,
          reason: '★★★ 合并页（embedded）里头部必须有顶部间距 —— '
              '否则封面紧贴标题栏（实测 y=40 就是内容，零间距）');
      expect(src.contains('EdgeInsets.fromLTRB('), isTrue,
          reason: '★ 必须用 fromLTRB 才能只给 embedded 加 top '
              '（`symmetric` 会同时改左右，且加不了"仅合并页"的条件）');
    });

    test('★ 阳性对照：容器真的换了类型（不是"只是加了常量"）', () {
      /*
       * ★ 若源码里 `SizedBox` 包着的是**旧**结构（没有 ScrollView），
       *   上面两条会同时通过而功能其实没做 —— 这条排除那种情况。
       *
       * ⚠️ 2026-09-27 第三轮：`height:` 的实参从 `kEpsViewportH` 变成 `epsH`
       *    ⇒ 这里的多行字面量匹配也要跟着改（否则它去守一个不存在的写法）。
       */
      expect(src.contains('key: _epsViewportKey,\n                  height: epsH,'),
          isTrue,
          reason: '★ 固定高度的盒子必须**同时**挂 `_epsViewportKey` —— '
              '那是自动滚动用来量视口尺寸的');
      expect(src.contains('controller: _epsCtrl'), isTrue,
          reason: '★ 必须挂上**自己的** ScrollController（不是外层的）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  C —— 自动滚动的**计算规则**（纯函数，边界全覆盖）
  // ═══════════════════════════════════════════════════════════════════
  group('C 自动滚动的计算规则（纯函数 episodeScrollTarget）', () {
    test('★★★ 已完整可见 ⇒ 返回 null（**不许**挪到中间）', () {
      /*
       * ⚠️ 这条是**用户体验**的关键：
       *    若"已可见也居中"，用户每点一次选集那一集都会被挪到视口正中间
       *    ⇒ 看起来像"页面乱跳 / 我点错了"。
       *
       * ══════════════════════════════════════════════════════════════
       * ★★★ 红度证明抓出来的**假通过**（本用例第一版是错的）
       * ══════════════════════════════════════════════════════════════
       *
       * 我第一版用 `itemDy=10, currentOffset=0` —— 它算出来 `want≈0`，
       * 于是被"差值 < 1 就不动"那条规则**兜住**了 ⇒
       * 我把 `if (itemDy >= 0 && ...) return null;` 改成 `if (false)` 时，
       * 这条断言**照样绿** ⇒ **它根本没在守"已可见就不动"**。
       *
       * ⇒ 必须换一个"已完整可见、但居中会明显移动"的用例：
       * ```text
       * viewH=148, itemH=38, itemDy=10（完整可见：10+38=48 <= 148）
       * 若走居中：want = cur + 10 − (148−38)/2 = cur + 10 − 55 = cur − 45
       * ⇒ 只要 cur ≥ 100，|want − cur| = 45 >> 1 ⇒ **不会被兜底规则吃掉**
       * ```
       * ★ 这个 `cur=200` 就是让两条规则**可区分**的关键。
       */
      final t = episodeScrollTarget(
        itemDy: 10, itemH: 38, viewH: 148,
        currentOffset: 200, maxExtent: 300,
      );

      /*
       * ★ 阳性对照（在同一用例里）：先证明"若走居中，它**会**移动 45px"
       *   —— 否则上面那条 `isNull` 可能又是因为"算了也不会动"而假通过。
       */
      final ifCentered =
          (200 + 10 - (148 - 38) / 2).clamp(0.0, 300.0);
      expect((ifCentered - 200).abs(), greaterThan(10.0),
          reason: '★ 仪器自检：这个用例下"居中"会移动 > 10px ⇒ '
              '所以 isNull 只能是"已可见就不动"规则给的（不是被兜底吃掉）');

      expect(t, isNull,
          reason: '★★★ 目标已完整可见（dy=10, 10+38=48 <= 148）⇒ 不许滚 —— '
              '否则用户每点一集它都被挪到视口中间，像"页面乱跳"');
    });

    test('★★★ 已可见但**靠下**（不完整可见）⇒ 仍然要滚', () {
      /*
       * ★ 边界：`itemDy + itemH > viewH` 时**必须滚**（只露出一半要居中）。
       *   这条与上面那条一起把"完整可见"的判据夹住。
       */
      final t = episodeScrollTarget(
        itemDy: 130, itemH: 38, viewH: 148, // 130+38=168 > 148 ⇒ 露不全
        currentOffset: 0, maxExtent: 300,
      );
      expect(t, isNotNull,
          reason: '★★ 只露一半 ⇒ 必须滚（判据是"**完整**可见"而不是"露了一点"）');
    });

    test('★★★ 在**上方**（被滚过头）⇒ 滚回去', () {
      final t = episodeScrollTarget(
        itemDy: -50, itemH: 38, viewH: 148,
        currentOffset: 100, maxExtent: 300,
      );
      expect(t, isNotNull, reason: '★ dy < 0 ⇒ 在视口上方 ⇒ 必须滚回去');
      expect(t, lessThan(100), reason: '★ 要往回滚（offset 变小）');
      expect(t, greaterThanOrEqualTo(0.0), reason: '★ 不许滚成负数');
    });

    test('★★★ 在**下方**（还没露出来）⇒ 滚下去', () {
      final t = episodeScrollTarget(
        itemDy: 200, itemH: 38, viewH: 148,
        currentOffset: 0, maxExtent: 300,
      );
      expect(t, isNotNull, reason: '★ dy=200 > 148 ⇒ 在视口下方 ⇒ 必须滚下去');
      expect(t, greaterThan(0), reason: '★ 要往下滚（offset 变大）');
      expect(t, lessThanOrEqualTo(300), reason: '★ 不许超过 maxExtent');
    });

    test('★★★ 结果**必须夹进** [0, maxExtent]（不许越界）', () {
      /*
       * 越界的 offset 会让 `animateTo` 抛异常或回弹 ——
       * 而"最后一集在很下面"正是最容易越界的场景。
       */
      final t = episodeScrollTarget(
        itemDy: 9999, itemH: 38, viewH: 148,
        currentOffset: 0, maxExtent: 300,
      );
      expect(t, 300.0, reason: '★★ 要夹到 maxExtent（不是 9999）');

      final t2 = episodeScrollTarget(
        itemDy: -9999, itemH: 38, viewH: 148,
        currentOffset: 100, maxExtent: 300,
      );
      expect(t2, 0.0, reason: '★★ 要夹到 0（不是负数）');
    });

    test('★★ 视口高为 0 ⇒ 返回 null（布局还没完成，别乱滚）', () {
      expect(
        episodeScrollTarget(
          itemDy: 10, itemH: 38, viewH: 0,
          currentOffset: 0, maxExtent: 300,
        ),
        isNull,
        reason: '★ viewH=0 说明还没布局完 ⇒ 滚了也没意义（且可能除零）',
      );
    });

    test('★★ 算出来跟当前位置一样 ⇒ 返回 null（不做无意义动画）', () {
      /*
       * 目标恰好在视口**正中间**且当前位置就是它 ⇒ 差值为 0 ⇒ 不动。
       */
      final t = episodeScrollTarget(
        itemDy: 0, itemH: 148, viewH: 148,
        currentOffset: 50, maxExtent: 300,
      );
      // itemH == viewH ⇒ 整行占满 ⇒ 已"完整可见"（0+148 <= 148）
      expect(t, isNull, reason: '★ 占满视口 ⇒ 已可见 ⇒ 不动');
    });

    test('★ 阳性对照：判据**真的会动**（不是恒返回 null）', () {
      /*
       * ★ 铁律①：若 `episodeScrollTarget` 恒返回 null，
       *   上面那些"返回 null"的断言会**全部假通过**。
       *   这条证明它在该动的时候**真的会给一个值**。
       */
      final t = episodeScrollTarget(
        itemDy: 500, itemH: 38, viewH: 148,
        currentOffset: 0, maxExtent: 1000,
      );
      expect(t, isNotNull,
          reason: '★ 目标远在下方 ⇒ 必须给出一个 offset（否则上面全假通过）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  C —— ★★★ 只滚选集，**不滚外层 ListView**（本仓真实事故的同族）
  // ═══════════════════════════════════════════════════════════════════
  group('C ★★★ 不许把整页滚走（本仓 task-3 同族事故）', () {
    test('★★★ 源码里**不许**出现 `Scrollable.ensureVisible`', () {
      /*
       * ⚠️ 必须用**剥过注释**的 `src`：
       *    我在 `_epsCtrl` / `_buildBody` 的注释里**刻意引用**了这个 API
       *    来解释"为什么不能用它" ⇒ 不剥注释这条会**假红**。
       *    （本仓铁律⑤，已踩过多次）
       */
      expect(src.contains('Scrollable.ensureVisible'), isFalse,
          reason: '★★★ 它会向上遍历**所有** Scrollable ⇒ '
              '把外层 ListView 一起滚走（task-3 同族事故）');
      expect(src.contains('ensureVisible'), isFalse,
          reason: '★★★ 任何形式的 ensureVisible 都不许用');
    });

    test('★ 仪器自检：stripComments 真的剥掉了注释里的引用', () {
      /*
       * ★ 与 t59 的同名自检同一个道理：
       *   若 `stripComments` 无效，上面那条"不许出现"就是**假通过**。
       */
      expect(raw.contains('Scrollable.ensureVisible'), isTrue,
          reason: '★ 文档注释里保留了它作为"为什么不用"的证据');
      expect(src.contains('Scrollable.ensureVisible'), isFalse,
          reason: '★★ 剥注释后不许有 —— 这条同时证明 stripComments 有效');
    });

    test('★★★ 滚动必须走**选集自己的**控制器', () {
      expect(src.contains('_epsCtrl.animateTo'), isTrue,
          reason: '★★★ 只对 `_epsCtrl` 做 animateTo ⇒ '
              '外层 ListView 的 offset **结构上不可能变**');
      expect(src.contains('final ScrollController _epsCtrl = ScrollController()'),
          isTrue,
          reason: '★★ 选集必须有自己的 ScrollController（不是借用外层的）');
    });

    test('★★★ 除 `_epsCtrl` 外**不许有**别的滚动手段（堵住"偷偷加一条"）', () {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★ 为什么加这条：上面那条只证明"**有** `_epsCtrl.animateTo`"
       * ══════════════════════════════════════════════════════════════
       *
       * 它挡不住这种改法：**保留** `_epsCtrl.animateTo`，同时在旁边
       * **再加**一条滚动外层的手段 ⇒ 上面那条照样绿，而整页还是被滚走了。
       *
       * ⇒ 这几条把"**任何**别的滚动手段"都禁掉：
       * ```text
       * Scrollable.of(...)        ← 会拿到**最近**的 Scrollable（可能是外层）
       * .position.jumpTo / animateTo  ← 绕过控制器直接操作
       * PrimaryScrollController  ← 同样可能指到外层
       * ```
       */
      expect(src.contains('Scrollable.of('), isFalse,
          reason: '★★★ 不许用 `Scrollable.of(` —— 它拿到的是**最近**的 '
              'Scrollable，在嵌套结构里可能指到外层 ListView');
      expect(src.contains('.position.jumpTo'), isFalse,
          reason: '★★ 不许绕过控制器直接 jumpTo');
      expect(src.contains('PrimaryScrollController'), isFalse,
          reason: '★★ 不许用 PrimaryScrollController（可能指到外层）');
    });

    test('★★★ `_scrollEpisodesIntoView` 里**只有** `_epsCtrl` 一个滚动目标', () {
      /*
       * ★ 把断言限定在**那个方法体内** —— 排除"文件别处合法地用了别的
       *   滚动 API"造成的假红（本仓铁律⑤的同族：先缩小范围再断言）。
       */
      final at = src.indexOf('void _scrollEpisodesIntoView() {');
      expect(at, greaterThan(0), reason: '★ 方法必须存在');
      var depth = 0;
      var end = at;
      for (var i = src.indexOf('{', at); i < src.length; i++) {
        if (src[i] == '{') depth++;
        if (src[i] == '}') {
          depth--;
          if (depth == 0) {
            end = i;
            break;
          }
        }
      }
      final body = src.substring(at, end);

      // 该方法体里出现的滚动调用
      final scrollTargets = RegExp(r'(_epsCtrl|Scrollable\.of\([^)]*\)|'
              r'PrimaryScrollController[^;]*)\s*\.\s*(animateTo|jumpTo)')
          .allMatches(body)
          .map((m) => m.group(1))
          .toSet();

      // ignore: avoid_print
      print('[T62] _scrollEpisodesIntoView 里的滚动目标 = $scrollTargets');

      expect(scrollTargets, isNotEmpty,
          reason: '★ 阳性对照：这里**必须**有滚动调用（否则这条是空断言）');
      expect(scrollTargets, {'_epsCtrl'},
          reason: '★★★ 这个方法的滚动目标**只能**是 `_epsCtrl` —— '
              '出现任何别的目标都可能把外层 ListView 滚走');
    });

    test('★★★ task-64：外层**根本不是可滚体**（比"仍是 ListView"更强）', () {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 这条断言在 task-64 被**反转**了 —— 理由必须留下
       * ══════════════════════════════════════════════════════════════
       *
       * # 改前（task-62）
       * ```dart
       * expect(src.contains('return ListView('), isTrue,
       *     reason: '★ 外层仍是 ListView —— 它不许被滚动逻辑影响');
       * ```
       * 当时的契约是「外层**是** ListView，但滚动逻辑**不许**碰它」——
       * 靠"只滚 `_epsCtrl`"这条纪律来保证。
       *
       * # 为什么现在必须反过来
       *
       * Owner 原话（逐字）：
       * ```text
       * > 右侧整体固定，不能上下滚动，只有选集部分内部可以滚动
       * ```
       * ⇒ 外层**不许再是可滚的**。而"不许可滚"比"可滚但别碰它"**更强**：
       * ```text
       * 旧契约：有 ListView，靠纪律不去滚它   ← 纪律可能被后人破坏
       * 新契约：压根没有 ListView            ← ★ 没有可滚的东西
       * ```
       * ★ 本仓铁律：**结构上不可能** > 靠断言禁止。
       *   所以这条不是"放宽"，是**收紧**。
       *
       * # ⚠️ 但**必须**同时确认两件事，否则就是"假绿"
       * ```text
       * ① 外层真的不是任何 Scrollable（不是换成 SingleChildScrollView 糊过去）
       * ② 选集**仍然**内部可滚（否则"只有选集可滚"变成"什么都不可滚"，
       *    24 集会被裁掉 —— 那是把 bug 换成另一个 bug）
       * ```
       * ⇒ 下面两条一起断言。
       */
      final i = src.indexOf('Widget _buildBody(BuildContext context, MediaDetail d) {');
      expect(i, greaterThan(0), reason: '★ `_buildBody` 必须存在');

      // 取到方法体（按大括号配平）
      var depth = 0;
      var end = i;
      for (var k = src.indexOf('{', i); k < src.length; k++) {
        if (src[k] == '{') depth++;
        if (src[k] == '}') {
          depth--;
          if (depth == 0) {
            end = k;
            break;
          }
        }
      }
      final body = src.substring(i, end);

      // ① 外层**不是**任何可滚体
      for (final forbidden in const [
        'ListView(',
        'SingleChildScrollView(',
        'CustomScrollView(',
        'GridView(',
        'PageView(',
      ]) {
        expect(body.contains(forbidden), isFalse,
            reason: '★★★ `_buildBody` 里不得出现 `$forbidden` —— '
                'Owner 要求「右侧整体固定，不能上下滚动」。'
                '★ 若换成 `SingleChildScrollView` 糊过去，'
                '那仍然是个可滚体，等于没改。');
      }
      expect(body.contains('return Column('), isTrue,
          reason: '★ 外层应是 `Column`（自然高度、不可滚）');

      // ② 选集**仍然**内部可滚（防"把 bug 换成另一个 bug"）
      final j = src.indexOf('List<Widget> _bodyEpisodes(double epsH) {');
      expect(j, greaterThan(0), reason: '★ `_bodyEpisodes` 必须存在');
      var d2 = 0;
      var e2 = j;
      for (var k = src.indexOf('{', j); k < src.length; k++) {
        if (src[k] == '{') d2++;
        if (src[k] == '}') {
          d2--;
          if (d2 == 0) {
            e2 = k;
            break;
          }
        }
      }
      final epsBody = src.substring(j, e2);
      expect(epsBody.contains('SingleChildScrollView('), isTrue,
          reason: '★★★ 选集**必须仍然内部可滚** —— 否则 24 集会直接被裁掉，'
              '那是把"整页能滚"换成"选集看不全"，同样是 bug');
      expect(epsBody.contains('height: epsH'), isTrue,
          reason: '★ 选集仍是**固定高度**的盒子（task-62 的契约不许丢）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  C —— 三条触发路径 + didUpdateWidget
  // ═══════════════════════════════════════════════════════════════════
  group('C 三条触发路径都要有（Owner 明确列举）', () {
    test('★★★ 路径③：必须实现 `didUpdateWidget`（播放器切集）', () {
      /*
       * Owner：「**上一集 下一集**，也都要自动联动滚动到当前剧集」
       *
       * 播放器切集 ⇒ 外层 `MediaSession.currentEpisodeId` 变 ⇒
       * 通过 `widget.currentEpisodeId` 传下来 ⇒ 必须在 `didUpdateWidget`
       * 里响应（**不能**在 build 里做 —— 那是每帧都跑的副作用）。
       */
      expect(src.contains('void didUpdateWidget(covariant DetailPage old)'),
          isTrue,
          reason: '★★★ 播放器切集要靠 `didUpdateWidget` 接住 —— '
              '在 build 里做会让用户手动滚动时被反复拽回去');
      expect(
        src.contains('if (old.currentEpisodeId == widget.currentEpisodeId) return;'),
        isTrue,
        reason: '★★ 必须先判"**真的变了**" —— '
            '父级每次 rebuild 都会调 didUpdateWidget，不判就会滚个不停',
      );
    });

    test('★★★ 路径①：剧集加载完要滚', () {
      expect(src.contains('_scheduleEpisodeScroll();'), isTrue,
          reason: '★ 触发路径存在');
      // 具体在 `_loadEpisodes` 的成功分支里
      final at = src.indexOf('Future<void> _loadEpisodes(');
      expect(at, greaterThan(0));
      final body = src.substring(at, at + 1200);
      expect(body.contains('_scheduleEpisodeScroll();'), isTrue,
          reason: '★★★ 路径①「进页（剧集加载完）」必须在 `_loadEpisodes` 里滚');
    });

    test('★★★ 路径②：用户点选集要滚', () {
      final at = src.indexOf('void _play([Episode? ep]) {');
      expect(at, greaterThan(0));
      final body = src.substring(at, at + 1200);
      expect(body.contains('_scheduleEpisodeScroll();'), isTrue,
          reason: '★★★ 路径②「用户点选集」必须在 `_play` 里滚');
    });

    test('★★★ 优先级：widget.currentEpisodeId **先于** _pickedEpisodeId', () {
      /*
       * ★ 顺序错了会"先滚回旧集再滚过去"（视觉上抖一下）。
       *   详见 `DetailPage.currentEpisodeId` 的文档。
       */
      final at = src.indexOf('String? get _activeEpisodeId {');
      expect(at, greaterThan(0), reason: '★ getter 必须存在');
      final body = src.substring(at, at + 700);

      final iPlayer = body.indexOf('widget.currentEpisodeId');
      final iPicked = body.indexOf('_pickedEpisodeId');
      final iSelected = body.indexOf('_selectedEpisodeId');

      expect(iPlayer, greaterThanOrEqualTo(0),
          reason: '★★★ 必须读 `widget.currentEpisodeId`（播放器的权威值）');
      expect(iPlayer, lessThan(iPicked),
          reason: '★★★ ① 必须在 ② 前面 —— 否则按「下一集」会先滚回旧集');
      expect(iPicked, lessThan(iSelected),
          reason: '★★ ② 必须在 ③ 前面（用户刚点的优先于历史记录）');
    });

    test('★★ 必须校验 id **真的在列表里**（换源后旧 id 会失效）', () {
      /*
       * ★ 换源/换线路后剧集列表会变，旧 id 可能已不存在 ⇒
       *   直接拿来高亮会"一集都不亮"。
       */
      final at = src.indexOf('String? get _activeEpisodeId {');
      final body = src.substring(at, at + 700);
      expect(body.contains('_episodes.any((e) => e.id == fromPlayer)'), isTrue,
          reason: '★★ 必须校验 id 在列表里 —— 否则换源后高亮全灭');
    });

    test('★★ 释放控制器（dispose）—— 否则反复进页会泄漏', () {
      expect(src.contains('_epsCtrl.dispose()'), isTrue,
          reason: '★ 自己创建的 ScrollController 要自己 dispose');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  回归：不许破坏既有行为
  // ═══════════════════════════════════════════════════════════════════
  group('回归：既有行为不许被破坏', () {
    test('★★★ 宽档（>=620）行为**一字未动**：封面 212 + 并排', () {
      /*
       * ⚠️ 2026-09-27 第三轮：断言从"单行三目"改成"宽档那一条 Row"。
       *
       * 旧写法（一条三目同时管三档）**已被拆掉** —— 因为 Owner 第二次投诉
       * 「还是有留白，看着不协调」，而根因正是"封面 + **全部**信息并排"
       * 这个结构（简介/按钮/续播被挤进封面右边那一列 ⇒ 左基准线与选集不一致）。
       *
       * ⇒ 现在：宽档是**单独一条** `Row([_Cover(212), Sp.x6, Expanded(info())])`，
       *   窄档/中档走「并排 head + 通栏 rest」。
       * ★ 契约本身**没变**：`>= 620` 仍是封面 212 + 并排 ⇒ 这条断言守的就是它。
       */
      expect(src.contains('_Cover(detail: d, width: 212.0)'), isTrue,
          reason: '★★★ 冻结契约：宽视口下封面必须仍是 212（改动前的值）');
      expect(src.contains('const SizedBox(width: Sp.x6)'), isTrue,
          reason: '★★ 宽档封面与信息之间的间距仍是 Sp.x6（改动前的值）');
    });

    test('★★★ 紧凑档仍在（极窄屏上下堆叠），封面 112', () {
      expect(src.contains('if (w < kHeaderCompactMax)'), isTrue,
          reason: '★★ 真手机竖屏（可用宽 < 300）仍走上下堆叠');
      expect(src.contains('_Cover(detail: d, width: 112)'), isTrue,
          reason: '★★ 紧凑档封面仍是 112');
    });

    test('★★ 不许用 flutter/material.dart（本仓硬约束）', () {
      expect(src.contains("import 'package:flutter/material.dart'"), isFalse,
          reason: '★★ 生产代码用 package:material_ui/material_ui.dart');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  B2 —— 选集视口高度 = max(下限, 剩余空间)  ← ★ 2026-09-27 第三轮
  // ═══════════════════════════════════════════════════════════════════
  group('B2 选集高度吃掉剩余空间（Owner 第二次投诉「还是有留白」）', () {
    test('★★★ 剩余空间更大时 ⇒ 撑到剩余空间（消掉底部死区）', () {
      /*
       * 真机实测（pid 33212）：
       * ```text
       * 内容到 y=618 就结束了，面板高到 y=799
       * ⇒ ★ 底部死区 **181px**
       * ```
       * 面板 800 − 之上 390 − 尾距（Sp.x6=24 + Sp.x16=64） = **322**
       */
      final h = episodeViewportHeight(topH: 390, availH: 800);
      // ignore: avoid_print
      print('[T62B2] 可用 800 / 之上 390 ⇒ 选集视口 ${h}px');
      expect(h, 800 - 390 - 24 - 64,
          reason: '★★★ 剩余空间（322）> 下限（148）⇒ 必须撑到剩余空间，'
              '否则底部留 181px 死区（Owner：「还是有留白」）');
      expect(h, greaterThan(kEpsViewportH),
          reason: '★ 阳性对照：这条用例必须真的**撑开**了 '
              '（若恒返回 148 则上面那条断言没有鉴别力）');
    });

    test('★★★ 剩余空间比下限还小 ⇒ 退回下限 148（不许缩成看不见）', () {
      // 极矮窗口：可用 300 − 之上 250 − 尾距 88 = **负数**
      final h = episodeViewportHeight(topH: 250, availH: 300);
      expect(h, kEpsViewportH,
          reason: '★★ 剩余空间为负时必须退回 `kEpsViewportH` —— '
              '否则选集高度 <= 0 ⇒ 用户**一集都看不到**');
    });

    test('★★★ 可用高为 null / 无限 ⇒ 退回下限（改动前的行为）', () {
      expect(episodeViewportHeight(topH: 390, availH: null), kEpsViewportH,
          reason: '★ 外层没给确定高度时（如放进可滚列表）"剩余空间"无意义 '
              '⇒ 退回改动前的行为');
      expect(
          episodeViewportHeight(topH: 390, availH: double.infinity),
          kEpsViewportH,
          reason: '★ `infinity` 同样无意义 —— 不挡住会让 `SizedBox` '
              '拿到无穷高 ⇒ 布局直接抛异常');
    });

    test('★★★ 边界：恰好等于下限 ⇒ 返回下限（不是 0）', () {
      // 可用 = 之上 + 尾距 + 148 ⇒ rest 恰好 = 148
      final h = episodeViewportHeight(topH: 400, availH: 400 + 24 + 64 + 148);
      // ignore: avoid_print
      print('[T62B2] 恰好等于下限 ⇒ $h');
      expect(h, kEpsViewportH,
          reason: '★ 边界值：`rest > kEpsViewportH` 用的是**严格大于** '
              '⇒ 相等时返回下限（两者数值相同，但要确认没有 off-by-one 变成 147）');
    });

    test('★★★ 高度**不随集数变化**（Owner 那句"剧集高度固定一下"）', () {
      /*
       * ★ Owner 的本意是"别让 24 集撑成 8 行把页面顶下去" ——
       *   而**不是**"固定成 148"。所以"吃掉剩余空间"与他的要求**不矛盾**。
       *   ⚠️ 但必须确认它真的**不读集数** —— 否则又变成"集数越多页面越长"。
       */
      final src2 = stripComments(
          File('lib/ui/detail_page.dart').readAsStringSync());
      final i = src2.indexOf('double episodeViewportHeight({');
      final end = src2.indexOf('double? episodeScrollTarget({');
      expect(i, greaterThan(0), reason: '找不到 episodeViewportHeight');
      expect(end, greaterThan(i), reason: '找不到下一个函数的边界');
      final body = src2.substring(i, end);
      for (final forbidden in ['_episodes', 'episodeCount', 'length']) {
        expect(body.contains(forbidden), isFalse,
            reason: '★★★ `episodeViewportHeight` 里不得读 `$forbidden` —— '
                '读了就变成"集数越多越高"（Owner 报的正是这个）');
      }
    });
  });
}
