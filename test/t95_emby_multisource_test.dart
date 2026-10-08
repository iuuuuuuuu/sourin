// ═══════════════════════════════════════════════════════════════════════
//  t95：Emby **多源**（Owner：「emby 设定也是可以添加多个源」）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这条测试守的是什么
//
// 本仓的 Emby 源是**插件式 provider**：一台服务器 = 一个插件实例
// (emby / emby-2 / emby-3 …)，配置与凭据按 **插件 id** 分文件落盘
// (plugins/.data/<id>.json，rust/sourin_core/src/plugins/mod.rs:1545)。
// 所以「加一个源」= 把同一份 emby.js **换掉 @id 再装一遍**。
//
// 这一步改字符串的地方**特别容易静默出错**：
//   只改 @id、忘了改 @name    → 首页源栏两行同名，用户分不清哪个是哪个
//   只改 @id、忘了改 plugin.id → 宿主将来若读它就会串
//   忘了改三个内容条目 id     → emby-setup / emby-empty / emby-lib-* 撞车
//   一个锚点都没替换到        → 装出来的还是 @id emby ⇒ **覆盖掉用户第一个源**
// 最后一条最狠：界面显示「新增成功」，实际把用户已有的源重写了。
// 所以 debugRewriteInstance 对 6 个锚点**逐个校验**，任缺一个返回 null。
//
// # 为什么用 MaterialApp 而不是 FScaffold（与 material_ancestor_test 相反）
//
// SettingsSubPage / SettingsBlock 只用 material_ui + tokens
// (settings_kit.dart:30 只 import material_ui)，页面自己画返回按钮。
// 本文件要测的是**页面逻辑**（列表 / 切换 / 新增 / 删除），
// 用最薄的外壳即可；Material 祖先问题由 material_ancestor_test.dart 守。
//
// # 为什么必须注入假宿主
//
// SourinApi 全是 static 直连 FFI，一碰就要
// DynamicLibrary.open('sourin_core.dll')（lib/core/ffi.dart:165）——
// flutter test 里没有那个 DLL。所以 EmbySettingsPage(host: …)
// 是本页唯一的可测入口（生产传 null ⇒ 真 FFI，见 emby_page.dart:133）。

// ⚠️ 必须是 material_ui，不是 flutter/material：本页（和 settings_kit /
//    settings_sub_page）用的都是 package:material_ui —— flutter/material 的
//    MaterialApp 不会给 material_ui 的 TextField 提供 MaterialLocalizations，
//    一挂页就报「No MaterialLocalizations found.」（仓库 143 个 test 都这么写）。
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/settings/emby_page.dart';

/// 纯内存的假宿主 —— 实现的是 emby_page.dart 里那份 EmbyBackend 契约
class FakeHost implements EmbyBackend {
  FakeHost({this.seed = const []});

  /// id / name / file 三元组（可变的，安装与删除都改它）
  final List<({String id, String name, String file})> seed;

  final Map<String, Map<String, dynamic>> configs = {};
  final List<String> calls = [];
  final List<String> removed = [];
  final List<String> installedSources = [];
  String? lastConfigSetId;

  @override
  Future<PluginListResult> listPlugins() async {
    calls.add('list');
    return PluginListResult(
      plugins: [
        for (final s in seed)
          PluginEntry(
            file: s.file,
            id: s.id,
            name: s.name,
            version: '1.0.0',
            loaded: true,
          ),
      ],
    );
  }

  @override
  Future<PluginConfig> pluginConfigGet(String id) async {
    calls.add('cfgGet:$id');
    return PluginConfig(values: configs[id] ?? const {});
  }

  @override
  Future<int> pluginConfigSet(String id, Map<String, dynamic> values) async {
    calls.add('cfgSet:$id');
    lastConfigSetId = id;
    configs[id] = Map<String, dynamic>.from(values);
    return values.length;
  }

  @override
  Future<String?> providerSessionStateWire(String provider) async => 'active';

  @override
  Future<Map<String, dynamic>> providerLogin(
      String provider, String username, String password) async {
    calls.add('login:$provider:$username');
    return {'displayName': username};
  }

  @override
  Future<void> providerLogout(String provider) async => calls.add('logout:$provider');

  @override
  Future<PluginInstallResult> installPlugin(String url) async =>
      installPluginSource('// from $url');

  @override
  Future<PluginInstallResult> installPluginSource(String source,
      {String? nameHint}) async {
    installedSources.add(source);
    // 从源码里抠出 @id / @name —— 与宿主 parse_meta 的做法一致（只看头部）
    final head = source.length > 2048 ? source.substring(0, 2048) : source;
    final id = _meta(head, '@id ') ?? '';
    final name = _meta(head, '@name ') ?? id;
    if (id.isNotEmpty && !seed.any((s) => s.id == id)) {
      seed.add((id: id, name: name, file: '$id.js'));
    }
    calls.add('install:$id');
    return PluginInstallResult(
      id: id,
      name: name,
      version: '1.0.0',
      file: '$id.js',
      bytes: source.length,
    );
  }

  static String? _meta(String head, String key) {
    final i = head.indexOf(key);
    if (i < 0) return null;
    final rest = head.substring(i + key.length);
    var end = rest.length;
    for (final c in ['@', '\n']) {
      final p = rest.indexOf(c);
      if (p >= 0 && p < end) end = p;
    }
    return rest.substring(0, end).trim();
  }

  @override
  Future<void> removePlugin(String file) async {
    calls.add('remove:$file');
    removed.add(file);
    seed.removeWhere((s) => s.file == file);
  }

  @override
  Future<int> reloadPlugins() async => seed.length;
}

/// 一份最小的「合法 emby.js」—— 6 个锚点一个不少
const String kEmbySrc = '''
// @id emby
// @name Emby
// @version 1.0.0
globalThis.plugin = {
  id: 'emby',
  home: function () {
    return { sections: [{ id: 'emby-setup' }, { id: 'emby-empty' }] };
  },
  lib: function (x) { return { id: 'emby-lib-' + x }; },
};
''';

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

/// 挂上整页并等它稳下来
///
/// ⚠️ 必须把测试窗口**调高**（默认 800×600）：本页有 5 个区块，
///    默认尺寸下「保存配置 / 登录 / 删除」这些按钮都在屏幕外，
///    $tester.tap$ 会因为命中不到而失败 —— 那是**测试脚手架的问题**，
///    不是页面的问题，但红起来一样难查。
Future<void> pumpPage(WidgetTester t, EmbyBackend host) async {
  t.view.physicalSize = const Size(1400, 4200);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(wrap(EmbySettingsPage(host: host)));
  await t.pumpAndSettle();
}

void main() {
  setUp(() {
    // UiPrefs 的 _data 是 static，会跨测试文件互相污染（ui_prefs.dart:29）
    UiPrefs.debugResetForTest(<String, String>{});
  });

  group('实例 id 的识别与排序（纯函数）', () {
    test('只认 emby / emby-N，不误收 embyfoo', () {
      expect(debugIsEmbyInstanceId('emby'), isTrue);
      expect(debugIsEmbyInstanceId('emby-2'), isTrue);
      expect(debugIsEmbyInstanceId('emby-13'), isTrue);
      expect(debugIsEmbyInstanceId('embyfoo'), isFalse);
      expect(debugIsEmbyInstanceId('emby2'), isFalse);
      expect(debugIsEmbyInstanceId('api-2'), isFalse);
      expect(debugIsEmbyInstanceId(''), isFalse);
    });

    test('序号：emby=1，emby-N=N，认不出的排最后', () {
      expect(debugInstanceOrdinal('emby'), 1);
      expect(debugInstanceOrdinal('emby-2'), 2);
      expect(debugInstanceOrdinal('emby-13'), 13);
      expect(debugInstanceOrdinal('emby-x'), greaterThan(1000));
      expect(debugInstanceOrdinal('emby-'), greaterThan(1000));
    });

    test('新增取**最小空缺**，不是最大+1', () {
      // 已装 1 和 3 → 下一个是 2（否则删了再加会留下 emby-3 这种窟窿）
      expect(debugNextOrdinal(['emby', 'emby-3']), 2);
      expect(debugNextOrdinal(['emby']), 2);
      expect(debugNextOrdinal(['emby', 'emby-2', 'emby-3']), 4);
      expect(debugNextOrdinal(<String>[]), 1);
    });

    test('显示名：第一个用原名，后面的加序号', () {
      expect(debugDisplayName('Emby', 'emby'), 'Emby');
      expect(debugDisplayName('Emby', 'emby-2'), 'Emby 2');
      expect(debugDisplayName('公司那台', 'emby-3'), '公司那台 3');
    });
  });

  group('源码派生（6 个锚点）', () {
    test('六个锚点全部替换掉', () {
      final out = debugRewriteInstance(kEmbySrc, 'emby-2', 'Emby 2');
      expect(out, isNotNull);
      expect(out, contains('@id emby-2'));
      expect(out, contains('@name Emby 2'));
      expect(out, contains("id: 'emby-2',"));
      expect(out, contains("id: 'emby-2-setup'"));
      expect(out, contains("id: 'emby-2-empty'"));
      expect(out, contains("id: 'emby-2-lib-'"));
      // 旧的 @id 必须**不再**出现在头部（否则 parse_meta 认出的还是 emby）
      //
      // ⚠️ 不能直接断言 head 里没有 '@id emby'：'@id emby-2' 就以它开头，
      //    contains 恒真 —— 这是个假绿断言，守不住任何东西。
      //    parse_meta 取的值是**到行尾**为止（plugins/mod.rs:74-104），
      //    所以要断的是「@id emby 后面紧跟换行」这个完整行形态。
      final head = out!.substring(0, out.length > 2048 ? 2048 : out.length);
      expect(head.contains('@id emby-2'), isTrue);
      expect(head.contains('@id emby\n'), isFalse);
      expect(head.contains('@name Emby 2\n'), isTrue);
    });

    test('缺任一锚点 → 返回 null（宁可失败也不覆盖第一个源）', () {
      for (final drop in [
        '// @id emby',
        '// @name Emby',
        "  id: 'emby',",
        "{ id: 'emby-setup' }",
        "{ id: 'emby-empty' }",
        "{ id: 'emby-lib-' + x }",
      ]) {
        final broken = kEmbySrc.replaceFirst(drop, '');
        expect(broken, isNot(kEmbySrc), reason: '锚点 "$drop" 没被剥掉，用例本身失效');
        expect(debugRewriteInstance(broken, 'emby-2', 'Emby 2'), isNull,
            reason: '少了 "$drop" 还能派生，就会静默装出一个 @id 仍是 emby 的实例');
      }
    });

    test('目标 id 就是 emby 时拒绝（会覆盖第一个源）', () {
      expect(debugRewriteInstance(kEmbySrc, 'emby', 'Emby'), isNull);
    });

    // ★ 上面几个用例走的是 kEmbySrc —— 我手写的**最小**源码。
    //   最小源码能过，不等于**真的** emby.js 能过：真实文件 586 行，
    //   @name 后面跟的是 ' * @version 1.0.0' 这种同一注释块里的下一行，
    //   取值边界（\n / */ / @）稍有差池就会把版本号一起吃进去。
    //   所以这里直接读仓库里那份真源码再派生一次 —— 这是本文件里
    //   唯一「拿真实产物当输入」的用例。
    test('真实 emby.js（586 行）也能派生，且不啃掉 @version', () {
      final real = File('rust/sourin_core/plugins/emby.js').readAsStringSync();
      // 22784 **字节** / 19635 **字符**（中文一个字 3 字节）——
      // 断的是字符数，别照着文件大小写 20000 那种想当然的数。
      expect(real.length, greaterThan(19000), reason: '读到的不是真源码？');
      expect(real, contains('@id emby'));

      final out = debugRewriteInstance(real, 'emby-2', '公司那台');
      expect(out, isNotNull, reason: '真源码派生失败 —— 用户贴真 emby.js 会装不上');

      // parse_meta 只看开头 2048 字符（plugins/mod.rs:74-104），
      // 在这里断头部就够，而且正是宿主实际读的那一段。
      final head = out!.substring(0, 2048);
      expect(head, contains('@id emby-2'));
      expect(head, contains('@name 公司那台'));
      // ★ 关键：旧名字「Emby」必须被**整个吃掉**。
      //   写成 replaceFirst('@name ', '@name 公司那台 ') 会得到
      //   '@name 公司那台 Emby'，源栏里就是这种半截名字。
      expect(head.contains('@name 公司那台 Emby'), isFalse);
      // 相邻的元数据行不能被啃掉
      expect(head, contains('@version 1.0.0'));
      expect(head, contains('@author sourin'));
      // 其余五个锚点
      expect(out, contains("id: 'emby-2',"));
      expect(out, contains("id: 'emby-2-setup'"));
      expect(out, contains("id: 'emby-2-empty'"));
      expect(out, contains("id: 'emby-2-lib-'"));
      // 反向：不能再有任何 @id emby 的**行形态**
      expect(head.contains('@id emby\n'), isFalse);
    });
  });

  group('页面：一个源都没有', () {
    testWidgets('空态给出「还没有任何 Emby 源」，且不假装有配置', (t) async {
      final host = FakeHost();
      await pumpPage(t, host);

      expect(find.text('服务器列表'), findsOneWidget);
      expect(find.textContaining('还没有任何 Emby 源'), findsOneWidget);
      // 没有源时不能有「保存配置」这条路可走（会被静默写到别的源上）
      await t.tap(find.text('保存配置'));
      await t.pumpAndSettle();
      expect(find.textContaining('还没有任何 Emby 源'), findsWidgets);
    });
  });

  group('页面：多个源', () {
    FakeHost twoHost() => FakeHost(seed: [
          (id: 'emby', name: 'Emby', file: 'emby.js'),
          (id: 'emby-2', name: 'Emby 2', file: 'emby-2.js'),
        ]);

    testWidgets('两个源都列出来，默认选第一个', (t) async {
      final host = twoHost()
        ..configs['emby'] = {'serverUrl': 'http://192.168.1.10:8096'}
        ..configs['emby-2'] = {'serverUrl': 'http://10.0.2.2:8096'};

      await pumpPage(t, host);

      expect(find.text('Emby'), findsWidgets);
      expect(find.text('Emby 2'), findsWidgets);
      // 列表行显示各自地址 —— 这是用户区分两台服务器的唯一线索
      expect(find.textContaining('http://192.168.1.10:8096'), findsWidgets);
      expect(find.textContaining('http://10.0.2.2:8096'), findsWidgets);
      // 默认编辑第一个
      expect(find.textContaining('会写进「Emby」（emby）'), findsOneWidget);
    });

    testWidgets('切换实例：输入框换成那一台的地址，不串', (t) async {
      final host = twoHost()
        ..configs['emby'] = {'serverUrl': 'http://192.168.1.10:8096'}
        ..configs['emby-2'] = {'serverUrl': 'http://10.0.2.2:8096'};

      await pumpPage(t, host);

      await t.tap(find.text('Emby 2'));
      await t.pumpAndSettle();

      expect(find.textContaining('会写进「Emby 2」（emby-2）'), findsOneWidget);
      // 输入框里的地址必须是**第二台**的
      final urlField = t.widget<TextField>(find.widgetWithText(TextField, '服务器地址'));
      expect(urlField.controller!.text, 'http://10.0.2.2:8096');
    });

    testWidgets('保存配置写到**当前编辑的**源，不是第一个', (t) async {
      final host = twoHost();
      await pumpPage(t, host);

      await t.tap(find.text('Emby 2'));
      await t.pumpAndSettle();
      await t.enterText(find.widgetWithText(TextField, '服务器地址'), 'http://10.0.0.9:8096');
      await t.tap(find.text('保存配置'));
      await t.pumpAndSettle();

      expect(host.lastConfigSetId, 'emby-2');
      expect(host.configs['emby-2']?['serverUrl'], 'http://10.0.0.9:8096');
      expect(host.configs.containsKey('emby'), isFalse);
    });

    testWidgets('登录打到当前编辑的源', (t) async {
      final host = twoHost();
      await pumpPage(t, host);

      await t.tap(find.text('Emby 2'));
      await t.pumpAndSettle();
      await t.enterText(find.widgetWithText(TextField, '用户名'), 'bob');
      await t.tap(find.text('登录'));
      await t.pumpAndSettle();

      expect(host.calls, contains('login:emby-2:bob'));
    });

    testWidgets('删除要二次确认，确认后删的是那一行的文件', (t) async {
      final host = twoHost();
      await pumpPage(t, host);

      final deleteIcons = find.byIcon(Icons.delete_outline);
      expect(deleteIcons, findsNWidgets(2));
      await t.tap(deleteIcons.at(1));
      await t.pumpAndSettle();

      expect(find.text('删除源「Emby 2」？'), findsOneWidget);
      // 先取消 —— 不能什么都不问就删
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(host.removed, isEmpty);

      await t.tap(find.byIcon(Icons.delete_outline).at(1));
      await t.pumpAndSettle();
      await t.tap(find.text('删除'));
      await t.pumpAndSettle();

      expect(host.removed, ['emby-2.js']);
      // 删完只剩一个源
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    });

    testWidgets('粘贴源码新增 → 自动派生成 emby-3 并选中它', (t) async {
      final host = twoHost();
      await pumpPage(t, host);

      await t.enterText(find.widgetWithText(TextField, '或粘贴插件源码'), kEmbySrc);
      await t.enterText(
          find.widgetWithText(TextField, '新源的名字（留空 = 自动叫 Emby N）'), '公司那台');
      await t.tap(find.text('粘贴源码安装'));
      await t.pumpAndSettle();

      // 派生出来的 id 是**最小空缺**（已有 1、2 → 3），不是把第一个源重写一遍
      expect(host.installedSources.single, contains('@id emby-3'));
      expect(host.installedSources.single, contains('@name 公司那台'));
      expect(host.seed.map((s) => s.id), containsAll(['emby', 'emby-2', 'emby-3']));
      // 装完切到新源，用户可以接着填地址
      expect(find.textContaining('会写进「公司那台」（emby-3）'), findsOneWidget);
    });

    testWidgets('新源名字留空 → 自动叫 Emby N', (t) async {
      final host = twoHost();
      await pumpPage(t, host);

      await t.enterText(find.widgetWithText(TextField, '或粘贴插件源码'), kEmbySrc);
      await t.tap(find.text('粘贴源码安装'));
      await t.pumpAndSettle();

      expect(host.installedSources.single, contains('@name Emby 3'));
    });

    testWidgets('锚点不全的源码 → 报错且**一个字节都没装**', (t) async {
      final host = twoHost();
      await pumpPage(t, host);

      final broken = kEmbySrc.replaceFirst("id: 'emby-empty'", '');
      await t.enterText(find.widgetWithText(TextField, '或粘贴插件源码'), broken);
      await t.tap(find.text('粘贴源码安装'));
      await t.pumpAndSettle();

      expect(host.installedSources, isEmpty);
      expect(find.textContaining('不能安全地派生成新源'), findsOneWidget);
    });
  });

  group('页面：首页正在用哪个源（只读标注）', () {
    testWidgets('UiPrefs.homeSource 指向的实例标出「首页正在用」', (t) async {
      UiPrefs.debugResetForTest(<String, String>{'dsh.homeSource': 'emby-2'});
      final host = FakeHost(seed: [
        (id: 'emby', name: 'Emby', file: 'emby.js'),
        (id: 'emby-2', name: 'Emby 2', file: 'emby-2.js'),
      ]);

      await pumpPage(t, host);

      // 只标注，不提供「设为首页源」按钮（那会骗人：首页是保活的，
      // 本页写盘不会让它换源，见 emby_page.dart 文件头的多源说明）
      expect(find.textContaining('首页正在用'), findsOneWidget);
      expect(find.text('设为首页源'), findsNothing);
    });
  });
}
