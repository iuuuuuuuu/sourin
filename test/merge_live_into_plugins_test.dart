// ═══════════════════════════════════════════════════════════════════════
//  直播源配置并入「JS 插件」列表 —— 回归守卫
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（两句，第二句推翻了第一句的形态）
// ```text
// ① 直播源的配置也放到二级去
// ② 直播源还是跟js源合并吧,毕竟也是插件提供的,开关也方便
// ```
// ⇒ 最终形态 = **不要独立区块**，并进 JS 插件那份源列表。
//
// # 为什么"合并"在数据上天然成立（不是勉强拼）
// ```text
// · 直播源 = `capabilities.live` 为真的内容源 —— 本机 26 个源**全是 JS 插件**
// · 启停 = `setProviderEnabled(id, enabled)` → `disabled-providers.json`
//   ★ 与 JS 插件列表**本来就是同一个命令**
// ⇒ 原先两个区块的两个开关，其实是**同一个开关的两处入口** ——
//   合并是消重，不是移植。
// ```
//
// # ★★★ 这个文件守什么（合并最容易丢的东西）
//
// ```text
// ① 独立区块**真的没了**（否则用户看到两处开关，正是他要去掉的重复）
// ② 但能力**一条都没少** —— 这是合并与"删掉"的分界线：
//      开关    → 卡片上的「启用 / 停用」（onToggle）
//      认直播  → 卡片上的「直播」能力 chip（_capLabels）
//      看总数  → 块头的 `直播 N/M` chip（本次新增）
//    ★ ② 若丢了，用户就再也关不掉某个直播源了 —— 那是功能倒退，
//      比"两个开关重复"严重得多。
// ③ ★ 直播页的提示**必须指向新位置** —— 否则用户照着
//    「在 设置 → 直播源 里配置」找过去会**扑空**（提示比没有更糟）。
// ```
//
// # ★★ 为什么用静态契约（而不是 widget 测试）
// `SettingsPage` 在 `flutter test` 里**挂不上**：
// `build()` 里的 `${SourinApi.version}` → `_ensureBound()` →
// `DynamicLibrary.open('sourin_core.dll')` ⇒ 测试环境没有那个 DLL
// ⇒ build() 抛异常 ⇒ 子树被换成 ErrorWidget。
// （这是 `task43_plugins_subpage_test.dart` 里记录的、由独立验证者
//   实测确认的结构墙，不是本文件的推测。）
//
// ⚠️ 因此本文件**只断言接线契约**，不断言像素/布局。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 去注释（行注释 + 块注释，**带状态机**）
///
/// # 为什么必须剥注释（本仓踩过至少 7 次）
/// 本次改动**故意**在注释里留了历史提及
/// （`/// ★ 2026-09-28：原 `_liveSourcesBlock` 区块已按 Owner 要求并入…`）。
/// 若不剥注释，`'_liveSourcesBlock' not in code` 这条断言会**假红**；
/// 而反过来，若要断言"某能力还在"，注释里的字面量又会让它**假绿**。
/// ⇒ 两个方向都错，所以必须剥注释后再断言。
///
/// ★ 与 `task43_plugins_subpage_test.dart` 的实现**逐字相同** ——
///   这是本仓既有的工具函数，不另发明一套（各写一份必然漂）。
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  var inLine = false;
  var inBlock = false;
  String? quote;

  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';

    if (inBlock) {
      if (c == '*' && next == '/') {
        inBlock = false;
        i += 2;
        continue;
      }
      if (c == '\n') out.write(c);
      i++;
      continue;
    }

    if (inLine) {
      if (c == '\n') {
        inLine = false;
        out.write(c);
      }
      i++;
      continue;
    }

    if (quote != null) {
      out.write(c);
      if (c == r'\' && next.isNotEmpty) {
        out.write(next);
        i += 2;
        continue;
      }
      if (c == quote) quote = null;
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
      inLine = true;
      i += 2;
      continue;
    }
    if (c == '/' && next == '*') {
      inBlock = true;
      i += 2;
      continue;
    }

    out.write(c);
    i++;
  }
  return out.toString();
}

/// 取源码里某个**类/方法体**的正文（按大括号配对）
String bodyOf(String code, String signature) {
  final start = code.indexOf(signature);
  expect(start >= 0, isTrue,
      reason: '★ 前置断言：必须能找到 `$signature`（找不到≠合规，见铁律 78）');
  var depth = 0;
  var started = false;
  for (var i = start; i < code.length; i++) {
    final ch = code[i];
    if (ch == '{') {
      depth++;
      started = true;
    } else if (ch == '}' && started) {
      depth--;
      if (depth == 0) return code.substring(start, i + 1);
    }
  }
  fail('★ `$signature` 的大括号不配对');
}

void main() {
  late String settingsCode;
  late String liveCode;

  /// **未剥注释**的原文（少数断言必须看注释，见 ③ 那条）
  late String settingsRaw;
  late String liveRaw;

  setUpAll(() {
    /*
     * ★★★ 路径支持**环境变量覆盖**（红度证明用）
     *
     * 本文件有 10 条断言，要证明它们**不是空的**，唯一办法是
     * 故意破坏实现看是否变红。而 `lib/ui/settings_page.dart` 是
     * **大文件 + 有并发写入者**，直接改它做变异测试风险高。
     *
     * ⇒ 红度脚本把源码**复制**到 `.probe/`，在**副本**上注入变异，
     *   用 `MERGE_LIVE_SRC=<副本>` 跑本文件。生产文件零改动。
     *
     * ★ 默认（无环境变量）仍读**真实文件** —— 常规
     *   `flutter test test/` 跑的就是生产代码，不会因为有了开关
     *   就"测副本不测真的"。
     */
    String pick(String envKey, String fallback) {
      final v = Platform.environment[envKey];
      return (v != null && v.isNotEmpty) ? v : fallback;
    }

    /*
     * ★★ 两个版本都要留着（这是被测试自己抓出来的需求）
     *
     * ```text
     * 大多数断言要看**代码**（注释里的字面量会造成假绿/假红）
     *   ⇒ 用 stripComments 之后的 settingsCode / liveCode
     *
     * 但「注释有没有同步更新」这类断言**必须**看注释
     *   ⇒ 用原文 settingsRaw / liveRaw
     * ```
     * 我第一版只留了剥注释版，结果 ③ 的"两处都同步"断言
     * 实测只数到 **1** 处 —— 而原文里确实是 **2** 处
     *（1 tooltip + 1 注释）。那条断言的本意就是"注释也要改"，
     *  用剥注释版去数它，等于**把要测的东西先删掉再测**。
     */
    settingsRaw =
        File(pick('MERGE_LIVE_SRC', 'lib/ui/settings_page.dart'))
            .readAsStringSync();
    liveRaw =
        File(pick('MERGE_LIVE_LIVE', 'lib/ui/live_page.dart')).readAsStringSync();
    settingsCode = stripComments(settingsRaw);
    liveCode = stripComments(liveRaw);
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ① 独立区块真的没了
  // ═══════════════════════════════════════════════════════════════════
  group('① 独立「直播源」区块已删除', () {
    test('★★★ 代码里不再有 `_liveSourcesBlock`（调用点与方法都没了）', () {
      expect(
        settingsCode.contains('_liveSourcesBlock'),
        isFalse,
        reason: '★★ 独立区块必须**彻底**消失 —— 留着它用户就看到'
            '两处开关（JS 插件卡片一处、独立区块一处），'
            '而 Owner 原话正是「合并吧,开关也方便」。'
            '⚠️ 本断言跑在 `stripComments` 之后：注释里的历史提及不算数',
      );
    });

    test('★ 不再有 `title: 直播源` 这样的独立区块标题', () {
      expect(
        settingsCode.contains("title: '直播源'"),
        isFalse,
        reason: '★ 独立区块的标题必须消失（否则是一块空壳）',
      );
    });

    test('★ 原直播源开关的**形态**不该再出现', () {
      /*
       * ⚠️ 不能断言"全文件没有 SwitchListTile" —— 那是**假判据**。
       *
       * 我第一版就是这么写的，结果**假红**。实测该文件里确实还有 2 处：
       * ```text
       * L1724  遥控「开机自动开启」的开关
       * L5035  插件配置里 `type == 'bool'` 的字段渲染
       * ```
       * 两处都与直播源**毫无关系** —— 是正当用法。
       * ⇒ 判据必须**精确到直播源那个形状**：
       *   `value: p.enabled` + `onChanged: (_) => _toggleProvider(p)`
       *   （原 `_liveSourcesBlock` 的写法）
       * ★ 教训：「某组件不存在」是**过宽**的判据 —— 同一组件在别处
       *   有正当用法时，它只会误报。要断言的是**那个具体用法**。
       */
      final liveSwitch = settingsCode.contains('value: p.enabled') &&
          settingsCode.contains('onChanged: (_) => _toggleProvider(p)');
      expect(
        liveSwitch,
        isFalse,
        reason: '★ 原独立区块的开关（`value: p.enabled` + '
            '`onChanged: (_) => _toggleProvider(p)`）若还在，'
            '说明那块没删干净。'
            '⚠️ 本仓其它 SwitchListTile（遥控自启 / 插件 bool 字段）是正当用法，不算',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 能力一条都没少（合并 ≠ 删掉）
  // ═══════════════════════════════════════════════════════════════════
  group('② 能力未丢（合并与"删掉"的分界线）', () {
    test('★★★ 有 `_liveSources` getter，判据是 `capabilities.live`', () {
      final has = settingsCode.contains('get _liveSources =>');
      expect(has, isTrue,
          reason: '★★ 「哪些源能直播」这个判据**必须**保留 —— '
              '它是 `直播 N/M` 汇总 chip 的数据源');
      expect(
        settingsCode.contains('p.capabilities.live'),
        isTrue,
        reason: '★★ 判据必须是**声明的能力位**（不是探测结果）：'
            '配置页不该依赖运行期状态（进设置页时可能还没探过）',
      );
    });

    test('★★★ 卡片仍能启停源（`onToggle` → `_toggleProvider`）', () {
      /*
       * ★ 这是"合并"与"删掉"的**分界线**：
       *   开关若丢了，用户再也关不掉某个直播源 —— 功能倒退，
       *   比"两个开关重复"严重得多。
       */
      expect(
        settingsCode.contains('onToggle: () => _toggleProvider('),
        isTrue,
        reason: '★★★ 卡片必须仍把 `onToggle` 接到 `_toggleProvider` —— '
            '那是启停直播源的**唯一**入口了（独立区块已删）',
      );
      expect(
        settingsCode.contains('Future<void> _toggleProvider(ProviderManifest p)'),
        isTrue,
        reason: '★ `_toggleProvider` 本身必须还在（它含"写→读回真相→按真相报"三步）',
      );
    });

    test('★★ 卡片上仍显示「直播」能力 chip', () {
      expect(
        settingsCode.contains("if (c.live) '直播',"),
        isTrue,
        reason: '★★ `_capLabels` 里的「直播」必须还在 —— '
            '独立区块删掉后，用户靠这枚 chip 逐张辨认哪些源能直播',
      );
    });

    test('★★★ 块头有 `直播 N/M` 汇总 chip', () {
      expect(
        settingsCode.contains("text: '直播 '"),
        isTrue,
        reason: '★★★ 合并后必须有汇总 chip —— '
            '否则用户要滚动 26 张卡才能数出有几个直播源',
      );
      /*
       * ★ 断言它**真的在算启用数**（而不是写死一个数字）。
       *   写死的话会显示过期数据 —— 比不显示更糟。
       *
       * ⚠️ 必须用 **raw string**（`r'...'`）：普通字符串里的 `${...}`
       *    会被 Dart **插值**（编译不过：`Undefined name '_liveSources'`），
       *    而这里要匹配的是**源码字面量**，必须原样。
       *    ★ 这个坑 `task43_plugins_subpage_test.dart:569` 已经记录过一次 ——
       *      我第一版还是踩了（同一个文件里就有现成的写法可抄）。
       */
      expect(
        settingsCode.contains(
            r"'${_liveSources.where((p) => p.enabled).length}'"),
        isTrue,
        reason: '★★ chip 的分子必须是**实时算**的启用数，不能写死',
      );
      expect(
        settingsCode.contains(r"'/${_liveSources.length}'"),
        isTrue,
        reason: '★ chip 的分母是直播源总数',
      );
    });

    test('★ 没有直播源时不画那枚 chip（不产生「直播 0/0」噪声）', () {
      expect(
        settingsCode.contains('if (_liveSources.isNotEmpty) ...['),
        isTrue,
        reason: '★ 空时画「直播 0/0」是噪声 —— '
            '与本块既有的 `_enabledCount != _providers.length` 同一原则',
      );
    });

    test('★★ 持久化仍走 `setProviderEnabled`（不新增存储）', () {
      final toggle = bodyOf(
          settingsCode, 'Future<void> _toggleProvider(ProviderManifest p)');
      expect(
        toggle.contains('setProviderEnabled'),
        isTrue,
        reason: '★★ 启停必须仍写 `disabled-providers.json`（与 JS 插件同一个命令）'
            '—— 新增一套存储会让两处不一致',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 直播页的提示指向新位置（否则用户扑空）
  // ═══════════════════════════════════════════════════════════════════
  group('③ 直播页提示已同步（用户不会扑空）', () {
    test('★★★ 不再提示「设置 → 直播源」（那个入口已不存在）', () {
      expect(
        liveCode.contains('设置 → 直播源'),
        isFalse,
        reason: '★★★ 独立区块删了，旧提示就是**死链** —— '
            '用户照着找过去什么都没有。提示比没有更糟，必须同步',
      );
    });

    test('★★ 提示改指「设置 → JS 插件」', () {
      expect(
        liveCode.contains('设置 → JS 插件'),
        isTrue,
        reason: '★★ 提示必须指向**新位置**（JS 插件二级页的源卡片）',
      );
    });

    test('★ tooltip 与注释两处都同步了（不是只改一处）', () {
      /*
       * ★ 为什么要数个数：
       *   本仓有过"两处同构必须一起改"的教训 ——
       *   只改 tooltip 不改注释，下一个人读注释会以为入口还在旧位置。
       *
       * ⚠️⚠️ 这条**必须**用 `liveRaw`（未剥注释），**不能**用 `liveCode`。
       *
       * 我第一版用了 `liveCode`，实测只数到 **1** 处而失败 ——
       * 而原文里确实是 **2** 处（1 tooltip + 1 注释）。
       * 原因：这条断言的**本意就是"注释也要改"**，而 `stripComments`
       * 把注释删掉了 ⇒ 等于**先把要测的东西删掉再测它**。
       * ★ 一般化：判据选错了"看哪一份"，断言就会自我否定。
       */
      final n = '设置 → JS 插件'.allMatches(liveRaw).length;
      expect(n, 2,
          reason: '★ 应恰好 2 处（1 个用户可见的 tooltip + 1 处注释说明），'
              '实际 $n 处 —— 少一处说明有地方没同步',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 工具自检（证明上面那些断言不是恒真的）
  // ═══════════════════════════════════════════════════════════════════
  group('④ 仪器自检', () {
    test('★ `stripComments` 真的剥掉了注释（否则 ① 会假红）', () {
      const sample = '''
        // _liveSourcesBlock 在行注释里
        /* _liveSourcesBlock 在块注释里 */
        final x = 1;
      ''';
      final out = stripComments(sample);
      expect(out.contains('_liveSourcesBlock'), isFalse,
          reason: '★ 剥注释失效 ⇒ ① 那组会**假红**（我故意留的历史提及）');
      expect(out.contains('final x = 1;'), isTrue,
          reason: '★ 剥注释不能把代码也剥掉');
    });

    test('★ `bodyOf` 能取到真实方法体（否则 ② 的断言是空的）', () {
      final body = bodyOf(
          settingsCode, 'Future<void> _toggleProvider(ProviderManifest p)');
      expect(body.length, greaterThan(200),
          reason: '★ 取到的正文太短 ⇒ 说明括号配对找错了位置，断言不可信');
      expect(body.trimRight().endsWith('}'), isTrue);
    });

    test('★★ 阴性对照：源码**真的读到了**（否则整套断言是假绿）', () {
      /*
       * 若文件读成空串（路径写错 / 文件被搬走 / 被重命名），
       * 那么所有 `contains(...) isFalse` 都会**通过** ——
       * 一整套假绿。⇒ 这条是"文件真的读到了"的守门人。
       *
       * ⚠️ 阈值必须与**所量的那一份**匹配 —— 我第一版拿
       *   `settingsCode.length`（**剥注释后** = 86215）去比 100000，
       *   直接失败。而那个文件的**原文**是 158417 字符。
       *   注释占了将近一半 ⇒ 两个数根本不是一个量纲。
       *
       * ★ 一般化：写阈值断言时，先问"我量的是哪一份、它的合理量级是多少"。
       *   拿剥过的内容去套原文的阈值，是个**假判据** —— 它永远红，
       *   然后人会去调低阈值（把判据调废），而不是发现量错了对象。
       */
      expect(settingsRaw.length, greaterThan(100000),
          reason: '★ settings_page.dart 原文只有 ${settingsRaw.length} 字符 —— '
              '多半读错了文件，上面所有断言都不可信');
      expect(liveRaw.length, greaterThan(50000),
          reason: '★ live_page.dart 原文只有 ${liveRaw.length} 字符 —— 同上');

      /*
       * ★ 再加一条：剥注释**不能把内容也剥光**。
       *   若 `stripComments` 有 bug（比如把字符串也吃掉），
       *   下面那些 `contains` 断言会集体失真。
       *
       * ⚠️⚠️ 这里用**比例**而不是绝对阈值 —— 我第一版写的是
       *   `liveCode.length > 40000`，实测 **39919**，差 81 字符就红。
       *   而那个 40000 是我**猜**的（"原文 86206，砍一半差不多"），
       *   不是量出来的。猜出来的阈值有两个毛病：
       * ```text
       * ① 差一点点就红 —— 而红的原因与"文件读错了"毫无关系，
       *    纯粹是我猜的数偏了 ⇒ 假红
       * ② 它会诱使人**把阈值调低**（把判据调废）而不是去查真问题
       * ```
       * ⇒ 真正要守的是**关系**："剥完还剩一个合理的比例"。
       *   两个文件实测都是 ~46%，取 30% 做下界，留足余量。
       */
      double kept(int stripped, int raw) => stripped / raw;

      expect(kept(settingsCode.length, settingsRaw.length), greaterThan(0.30),
          reason: '★ settings_page.dart 剥注释后只剩 '
              '${settingsCode.length}/${settingsRaw.length} —— '
              '剥得太狠，说明剥注释器把代码也吃掉了');
      expect(kept(liveCode.length, liveRaw.length), greaterThan(0.30),
          reason: '★ live_page.dart 剥注释后只剩 '
              '${liveCode.length}/${liveRaw.length} —— 同上');
      expect(settingsCode.length, lessThan(settingsRaw.length),
          reason: '★ 剥注释后**必须变短**（该文件注释很多）—— '
              '没变短说明剥注释根本没生效，那 ① 那组会假红');
      expect(liveCode.length, lessThan(liveRaw.length),
          reason: '★ 同上（live_page 的注释也很多）');
    });
  });
}
