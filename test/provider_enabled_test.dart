// ═══════════════════════════════════════════════════════════════════════
//  源条过滤 + `get_provider_enabled` 语义 —— 任务 AE 的回归锁
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件锁的是什么（原版修过的**真 bug**）
//
// 原版 `src/stores/app.ts:259-283` 原文：
// > ## ⚠️ 这里曾是一个真 bug：用了 `working` 而不是 `enabled`
// >
// > | 字段 | 含义 | 谁能改 |
// > |---|---|---|
// > | `working` | **站点自身**是否可用（探测出来的）| 用户改不了 |
// > | `enabled` | **用户**是否要使用它（持久化的偏好）| 用户的选择 |
// >
// > 原实现用 `working` 过滤 —— 后果：**用户在设置里停用的源
// > 仍然出现在首页/搜索/直播里**（`enabled=false` 被完全忽略）。
// >
// > 实测证据：停用 cctv 后 `get_provider_enabled('cctv')` 返回 `false`，
// > 但首页的切换条里它还在，`list_providers` 也把它算作可用。
// >
// > 修法：`working` 与 `enabled` **都要**满足。
// > `enabled` 缺省（undefined）时按启用处理 —— 兼容老数据，
// > 且内置源若没写这个字段也不会被误判为停用。
//
// # ★ 为什么断言要分三层（本轮「断言在错误范围上跑」踩了 5 次）
//
// ```text
// ① 纯逻辑      sourceIsUsable / visibleSourceList 的真值表
//               → 直接断言布尔，判据明确
// ② 真实渲染    把源喂进真的 SourceBar，断言**药丸**在不在
//               → 这才是"停用后切换条里没有它"的落点
// ③ 接线        断言生产代码**真的走了**这条判据
//               → 防"逻辑写对了但没人调"（本项目出过 4 次）
// ```
// ⚠️ 只做 ① 会漏掉「判据写对了但 SourceBar 没用它」；
//    只做 ② 会漏掉「渲染对了但判据本身错」。
//
// ⚠️ 本文件**不碰 FFI**（`flutter test` 里没有 sourin_core.dll）——
//    真实的停用/启用往返由 `lib/ae_probe.dart` 在真机做（见那里的 RESULT 行）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/widgets/source_bar.dart';

/// 造一个源（只给影响判据的字段，其余用默认值）
ProviderManifest _p(
  String id, {
  bool working = true,
  bool enabled = true,
  String? name,
}) =>
    ProviderManifest(
      id: id,
      name: name ?? id,
      working: working,
      enabled: enabled,
    );

/// 宿主（照 `source_bar_test.dart` 的 harness —— 主题走 forui + material 双挂）
Widget _host(Widget child) {
  final data = FTheme.neutral.dark.desktop;
  return MaterialApp(
    theme: data.toApproximateMaterialTheme(),
    builder: (_, c) => FTheme(data: data, child: c ?? const SizedBox()),
    home: Scaffold(body: Center(child: child)),
  );
}

/// 收集树里**所有**可见文本（`Text` 与 `Text.rich` 都要）
///
/// ⚠️ 不能只用 `find.text('4')`：数量那个是 `Text.rich`，
///    `find.text` 默认不匹配它（`data` 为 null）——
///    那样断言会**恒假**，看起来像功能坏了，实际是取样方式错。
List<String> _allTexts(WidgetTester t) {
  final out = <String>[];
  for (final el in collectAllElementsFrom(
    t.binding.rootElement!,
    skipOffstage: false,
  )) {
    final w = el.widget;
    if (w is Text) {
      final d = w.data;
      if (d != null) {
        out.add(d);
      } else if (w.textSpan != null) {
        out.add(w.textSpan!.toPlainText());
      }
    }
  }
  return out;
}

/// 剥掉注释行 —— 静态断言里做文本匹配**必须先剥注释**
///
/// 这个坑本项目踩过至少四次：注释里提到某个标识符，
/// 纯文本匹配就把它当成真实调用，测试**假绿**。
String _code(String src) => src
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
    })
    .join('\n');

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 判据真值表（纯逻辑 —— 先把"判据本身是对的"证明掉）
  // ═══════════════════════════════════════════════════════════════════
  group('① 源可见性判据 sourceIsUsable（原版 working && enabled !== false）', () {
    test('★★ 核心 bug：enabled=false 的源**不可见**（哪怕 working=true）', () {
      /*
       * 这就是原版那个 bug 的正中央：
       * 旧实现只看 `working` → 这个源**会**出现在切换条里。
       */
      final off = _p('cctv', working: true, enabled: false);
      expect(
        sourceIsUsable(off),
        isFalse,
        reason: '★ 用户停用的源必须被过滤掉 —— 只看 working 就是原版那个 bug',
      );
    });

    test('★ enabled 缺省（true）时按**启用**处理', () {
      /*
       * 原版注释：「`enabled` 缺省（undefined）时按启用处理 ——
       * 兼容老数据，且内置源若没写这个字段也不会被误判为停用」。
       *
       * 我们的 `models.dart` 里 `enabled` 缺省值是 `true`
       * （`fromJson` 里 `j['enabled'] as bool? ?? true`），
       * 所以"没写这个字段"的源进来就是 true → 可见。
       */
      final def = _p('builtin', working: true);
      expect(
        sourceIsUsable(def),
        isTrue,
        reason: '★ 缺省必须算启用 —— 否则老数据/内置源会集体消失',
      );
      expect(
        ProviderManifest.fromJson({'id': 'x', 'name': 'X'}).enabled,
        isTrue,
        reason: '★ 后端没下发 enabled 键时，模型必须补 true（不是 false）',
      );
    });

    test('★ working=false 的源也不可见（两个条件都要满足）', () {
      expect(
        sourceIsUsable(_p('broken', working: false)),
        isFalse,
        reason: '站点自身探测失败 → 不该占切换条（点了没内容还不知道为什么）',
      );
      expect(
        sourceIsUsable(_p('broken-off', working: false, enabled: false)),
        isFalse,
        reason: '两个条件都不满足 → 当然不可见',
      );
    });

    test('★ 只有"两个都满足"才可见（完整真值表）', () {
      // 真值表：(working, enabled) → 可见
      const cases = <List<Object>, bool>{
        [true, true]: true, // ✓ 正常
        [true, false]: false, // ★ 原版那个 bug
        [false, true]: false, // 站点坏了
        [false, false]: false, // 又坏又停
      };
      cases.forEach((k, want) {
        final working = k[0] as bool;
        final enabled = k[1] as bool;
        expect(
          sourceIsUsable(_p('t', working: working, enabled: enabled)),
          want,
          reason: 'working=$working enabled=$enabled 应为 可见=$want',
        );
      });
    });

    test('★ 过滤**保持原顺序**（那是用户保存的排序，前端不得再 sort）', () {
      /*
       * 原版 `loadProviders` 注释：
       * > 前端绝对不要自己 sort —— 那会覆盖用户的排序。
       */
      final all = [
        _p('a'),
        _p('b', enabled: false),
        _p('c'),
        _p('d', working: false),
        _p('e'),
      ];
      final vis = visibleSourceList(all);
      expect(
        vis.map((p) => p.id).toList(),
        ['a', 'c', 'e'],
        reason: '★ 既要滤掉停用/失效的，又要保持 a<c<e 的原顺序',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 真实渲染（"停用后切换条里没有它"的落点）
  // ═══════════════════════════════════════════════════════════════════
  group('② SourceBar 渲染 —— 停用的源不能出现在药丸里', () {
    testWidgets('★★ 停用一个源 → 它的药丸**消失**，其余还在（数量真的变了）',
        (t) async {
      /*
       * ⚠️ 只断言"不抛异常"不算通过 —— 必须断言**列表内容真的变了**。
       *    所以这里两个方向都断：停用的那个 findsNothing，
       *    没停的那些 findsOneWidget。
       */
      final before = [
        _p('cctv', name: '央视'),
        _p('bilibili', name: '哔哩哔哩'),
        _p('cycani', name: '次元城'),
      ];

      // ── 停用前：三个都在 ──
      await t.pumpWidget(_host(SourceBar(
        sources: before,
        current: 'cctv',
        onSelect: (_) {},
      )));
      await t.pumpAndSettle();

      expect(find.text('央视'), findsOneWidget, reason: '停用前它应该在');
      expect(find.text('哔哩哔哩'), findsOneWidget);
      expect(find.text('次元城'), findsOneWidget);

      // ── 停用 cctv 后：它没了 ──
      final after = [
        _p('cctv', name: '央视', enabled: false), // ★ 用户停用了它
        _p('bilibili', name: '哔哩哔哩'),
        _p('cycani', name: '次元城'),
      ];
      await t.pumpWidget(_host(SourceBar(
        sources: after,
        current: 'bilibili', // 首页已优雅回退
        onSelect: (_) {},
      )));
      await t.pumpAndSettle();

      expect(
        find.text('央视'),
        findsNothing,
        reason: '★★ 这就是原版修的那个 bug —— 停用后它**不能**还在切换条里',
      );
      expect(find.text('哔哩哔哩'), findsOneWidget, reason: '其余源必须还在');
      expect(find.text('次元城'), findsOneWidget);
    });

    testWidgets('★ working=false 的源也不显示', (t) async {
      /*
       * ⚠️ 必须给**至少 3 个源、留下 ≥2 个可见** ——
       *    否则过滤后只剩 1 个，整条会自己隐藏（原版 `visible` 的逻辑），
       *    于是"可见的那个也不在"→ 断言看起来像功能坏了。
       *    （我第一版就是这样写错的：只给了 2 个源、滤掉 1 个 → 剩 1 个
       *     → 整条隐藏 → 误判成"正常的那个也没显示"。）
       */
      await t.pumpWidget(_host(SourceBar(
        sources: [
          _p('ok1', name: '正常的甲'),
          _p('bad', name: '坏掉的', working: false),
          _p('ok2', name: '正常的乙'),
        ],
        current: 'ok1',
        onSelect: (_) {},
      )));
      await t.pumpAndSettle();

      expect(find.text('正常的甲'), findsOneWidget);
      expect(find.text('正常的乙'), findsOneWidget);
      expect(
        find.text('坏掉的'),
        findsNothing,
        reason: '站点自身探测失败（working=false）→ 不该占切换条',
      );
    });

    testWidgets('★★ 只剩 1 个可见源时整条**自己隐藏**（不是显示 1 个药丸）',
        (t) async {
      /*
       * 原版 `visible = computed(() => props.sources.length > 1)`。
       *
       * ⚠️ 这条判据必须算在**过滤后**：3 个源里停用 2 个 → 实际只剩 1 个
       *    → 应该整条隐藏。用未过滤的长度会显示一条"只有一个药丸"的
       *    切换条（纯噪音，正是原版要避免的）。
       */
      await t.pumpWidget(_host(SourceBar(
        sources: [
          _p('a', name: '唯一'),
          _p('b', name: '停1', enabled: false),
          _p('c', name: '停2', enabled: false),
        ],
        current: 'a',
        onSelect: (_) {},
      )));
      await t.pumpAndSettle();

      expect(
        find.text('唯一'),
        findsNothing,
        reason: '★ 过滤后只剩 1 个源 → 整条隐藏（原版 visible 的逻辑）',
      );
    });

    testWidgets('★★ 数量显示用**过滤后**的数量（不能自相矛盾）', (t) async {
      /*
       * 6 个源、停用 2 个 → 可见 4 个 → 显示「4 个源」。
       * 显示 6 就是"条上只有 4 个药丸却写着 6 个源"的自相矛盾。
       *
       * ⚠️ `showCount` 的门槛是 `> 3`，所以 4 个正好会显示。
       */
      await t.pumpWidget(_host(SourceBar(
        sources: [
          _p('s1', name: 'A'),
          _p('s2', name: 'B'),
          _p('s3', name: 'C'),
          _p('s4', name: 'D'),
          _p('s5', name: '停E', enabled: false),
          _p('s6', name: '停F', enabled: false),
        ],
        current: 's1',
        onSelect: (_) {},
      )));
      await t.pumpAndSettle();

      final texts = _allTexts(t);
      expect(
        texts.any((s) => s.contains('4') && s.contains('个源')),
        isTrue,
        reason: '★ 必须显示"4 个源"（过滤后）。实际文本: $texts',
      );
      expect(
        texts.any((s) => s.contains('6') && s.contains('个源')),
        isFalse,
        reason: '★ 绝不能显示 6 —— 那是未过滤的数量，会与可见药丸数矛盾。'
            '实际文本: $texts',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 接线（判据写对了，但生产代码真的用它了吗）
  // ═══════════════════════════════════════════════════════════════════
  group('③ 接线断言 —— 生产代码真的走这条判据', () {
    late String barCode;

    setUpAll(() {
      barCode = _code(
        File('lib/ui/widgets/source_bar.dart').readAsStringSync(),
      );
    });

    test('★ 源条内部**自己**过滤（不是只指望调用方传干净的）', () {
      expect(
        barCode.contains('visibleSourceList(widget.sources)'),
        isTrue,
        reason: '★ 过滤必须在组件内部 —— 调用方有首页/直播/搜索多处，'
            '漏一处那个 bug 就回来（原版把它收进 store 计算属性就是这个理由）',
      );
    });

    test('★ 渲染循环用的是过滤后的列表，不是 widget.sources', () {
      /*
       * ⚠️ 这条是"逻辑写对了但没接上"的守门员：
       *    `_visible` 定义得再对，`itemBuilder` 里用 `widget.sources[i]`
       *    就还是会把停用的源画出来。
       */
      expect(
        barCode.contains('itemCount: sources.length'),
        isTrue,
        reason: '★ itemCount 必须用局部变量 sources（= 过滤后的）',
      );
      expect(
        barCode.contains('final s = sources[i];'),
        isTrue,
        reason: '★ itemBuilder 必须取过滤后列表的元素',
      );
      expect(
        barCode.contains('itemCount: widget.sources.length'),
        isFalse,
        reason: '★ 不得用未过滤的长度 —— 那会渲染出停用的源',
      );
      expect(
        barCode.contains('final s = widget.sources[i];'),
        isFalse,
        reason: '★ 不得用未过滤的列表取元素',
      );
    });

    test('★ 滚动定位的下标也按过滤后的列表算', () {
      /*
       * 用未过滤的列表数下标，只要前面有被停用的源，下标就会偏大 →
       * 选中项被滚过头。
       */
      expect(
        barCode.contains('_visible.indexWhere('),
        isTrue,
        reason: '★ `_scrollToCurrent` 的下标必须按可见列表算',
      );
      expect(
        barCode.contains('widget.sources.indexWhere('),
        isFalse,
        reason: '★ 不得按未过滤的列表算下标（会滚偏）',
      );
    });

    test('★ 判据是 working **与** enabled 的合取（不是只看一个）', () {
      final logic = _code(
        File('lib/ui/widgets/source_bar.dart').readAsStringSync(),
      );
      expect(
        logic.contains('p.working && p.enabled != false'),
        isTrue,
        reason: '★ 必须是合取，且 enabled 用 `!= false`（缺省 = 启用）',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ `get_provider_enabled` 的 UI 入口（缺口 ③）
  // ═══════════════════════════════════════════════════════════════════
  group('④ get_provider_enabled 有真实 UI 入口', () {
    late String setCode;

    setUpAll(() {
      setCode = _code(
        File('lib/ui/settings_page.dart').readAsStringSync(),
      );
    });

    test('★★ 设置页的「停用/启用」真的调了 getProviderEnabled', () {
      /*
       * 任务前：`SourinApi.getProviderEnabled` **零 UI 调用点**
       * （只有包装函数存在）。这条断言就是那个缺口的守门员。
       */
      expect(
        setCode.contains('SourinApi.getProviderEnabled('),
        isTrue,
        reason: '★★ `get_provider_enabled` 必须有真实 UI 入口 —— '
            '这是任务 AE 的缺口 ③',
      );
    });

    test('★ 写之后才读回（顺序不能反）', () {
      final iWrite = setCode.indexOf('SourinApi.setProviderEnabled(');
      final iRead = setCode.indexOf('SourinApi.getProviderEnabled(');
      expect(iWrite >= 0 && iRead >= 0 && iWrite < iRead, isTrue,
          reason: '★ 必须先写再读回 —— 反了就是读的旧状态，等于没验证');
    });

    test('★ 读失败不能把整个操作算失败（写已经成功了）', () {
      /*
       * `get_provider_enabled` 是**校验**用的，不是主操作。
       * 它抛异常时不该让用户看到"操作失败"（其实已经写成功了）。
       */
      expect(
        setCode.contains('get_provider_enabled 读回失败'),
        isTrue,
        reason: '★ 读回失败要单独兜住并只打日志，不能冒泡成"操作失败"',
      );
    });

    test('★ 提示文案按**读回的真相**，不是乐观取反', () {
      expect(
        setCode.contains('actual ? \'已启用'),
        isTrue,
        reason: '★ 文案必须用读回的 actual —— 用 `!p.enabled` 就是'
            '"点了停用但其实没停成"时给一条假成功提示',
      );
    });
  });
}
