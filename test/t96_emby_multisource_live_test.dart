// test/t96_emby_multisource_live_test.dart
//
// ★ 真宿主（真 sourin_core.dll）上的「Emby 多源」端到端守卫
//
// # 这个文件和 t95 的分工
//
//   t95_emby_multisource_test.dart —— 假宿主（FakeHost implements EmbyBackend），
//        验的是**页面逻辑**：id 识别 / 排序 / 派生 / 列表渲染 / 删除确认。
//        它一次都没碰真 Rust，所以「换 @id 真的会变成第二个源吗」它答不了。
//
//   本文件 —— 假宿主的反面：**全部走真 FFI**（真 DLL + 真插件目录 + 真配置落盘），
//        验的是「同一份 emby.js 派生出的 emby-2 在宿主里**真的是一个独立的源**」：
//          ① 装两份源码 → 磁盘上两个 .js，互不覆盖
//          ② 两份配置 → 磁盘上两个 .data/<id>.json，serverUrl / 账号互不串
//          ③ 删掉第二个 → 第一个还在，且第二个的配置**没被连带删掉**
//          ④ 真宿主上的页面 → 列表里两行，各自的地址来自各自那份 JSON
//
// # 为什么能这么写（脚手架来源）
//
//   范式抄自 test/zz_t53s_settings_live_toggle_test.dart（真宿主 widget 测试）与
//   test/task18_entry_test.dart（真宿主 + 隔离数据目录），三条铁律照搬：
//     · 环境前提不成立 ⇒ skip 而不是 fail（先构建 Windows 版再跑本守卫）
//     · 数据目录指到 .probe/ 下的隔离目录 ⇒ **绝不碰 Owner 的真实 profile**
//     · testWidgets 的测试体在 FakeAsync zone 里，FFI 回调靠
//       NativeCallable.listener 投递成 isolate 消息 ⇒ 裸 await 永不返回，
//       必须 tester.runAsync
//
// # 已知不覆盖的
//
//   providerLogin（emby.js 的 loginCmd 要真打 POST /Users/AuthenticateByName）
//   —— 本机没有可达的真 Emby 服务器，登录路径**不在本文件里验**。

import 'dart:convert';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/settings/emby_page.dart';

const String kTag = '[T96]';
void log(String s) => debugPrint('$kTag $s');

/// 一个能静默挂 10 分钟的测试比失败更贵
const Timeout kTimeout = Timeout(Duration(minutes: 5));

// ── 真宿主的前提 ──────────────────────────────────────────────────────
//
// ★ 为什么优先用 cargo 的产物而不是 bundle 里那份
//
//   2026-10-07 实测撞到：`build/windows/x64/runner/Release/sourin_core.dll`
//   （2026-10-04 18:03）**早于** `rust/sourin_core/src/commands_remote.rs`
//   （2026-10-06 01:20）—— 那个 .rs 里改的正是「plugin_config_set/get 把
//   plugins/.data 传成 data_dir」这个路径 bug（见该文件 :42-64 的注释）。
//   用旧 DLL 跑，写盘落在 `<dataDir>/emby.json`，而插件读的是
//   `<dataDir>/plugins/.data/emby.json` ⇒ 界面上读写自洽、插件永远读不到，
//   两边都不报错。这类"过期二进制"会让守卫**测的不是当前源码**。
//
//   `windows/CMakeLists.txt:123-134` 的约定是「先 cargo build --release，
//   再由 CMake 装进 bundle」，所以两者本就可能不一致 —— 这里直接盯
//   target/release 的产物（拿不到才退回 bundle 里那份），并打印时间戳，
//   让"守卫跑的到底是哪一版核心"在日志里可见。
const String _dllBuiltRel = r'rust\sourin_core\target\release\sourin_core.dll';
const String _dllBundleRel = r'build\windows\x64\runner\Release\sourin_core.dll';

/// 诊断用开关：`$env:T96_DLL='<路径>'` 可以强制指定用哪一份核心
///
/// 存在的原因是一次**对照实验**：bundle 里那份 DLL（2026-10-04）早于
/// commands_remote.rs 的 plugins/.data 修复（2026-10-06），用它可以复现
/// 「设置页保存了、插件读不到」那个历史 bug —— 见本文件头部的说明。
final String _dllEnv = Platform.environment['T96_DLL'] ?? '';
final String _dllRel = _dllEnv.isNotEmpty
    ? _dllEnv
    : (File(_dllBuiltRel).existsSync() ? _dllBuiltRel : _dllBundleRel);
final bool _dllReady = File(_dllRel).existsSync();

/// 仓库里那份**未被改过**的 emby.js（派生新源的模板）
const String _srcRel = 'rust/sourin_core/plugins/emby.js';

/// 隔离数据目录 —— 与 t18e_data / t53s_data 同套路，跑完就删
final Directory _dataDir = Directory('.probe/t96e_data');

String _p(String rel) => '${_dataDir.path}/$rel';
File _f(String rel) => File(_p(rel));

/// 预载真 DLL
///
/// ★ 必须在 SourinApi.start() **之前**调用：lib/core/ffi.dart:169 用的是
///   **裸名** DynamicLibrary.open('sourin_core.dll')，按绝对路径先载进来，
///   裸名那一次就命中已经映射好的模块。
void _preloadCoreDll() {
  if (!_dllReady) return;
  final f = File(_dllRel);
  DynamicLibrary.open(f.absolute.path);
  log('DLL 预加载 = OK（${f.absolute.path}，${f.lengthSync()} 字节，'
      'mtime=${f.lastModifiedSync()}）');
  // ★ 守卫跑的是不是当前源码：拿 bundle 那份时给出过期警告
  if (_dllRel == _dllBundleRel) {
    final src = File('rust/sourin_core/src/commands_remote.rs');
    if (src.existsSync() && src.lastModifiedSync().isAfter(f.lastModifiedSync())) {
      log('★★ 警告：这份 bundle DLL 比 commands_remote.rs 旧 ⇒ '
          '先跑 cargo build --release --manifest-path rust/sourin_core/Cargo.toml');
    }
  }
}

// ── FakeAsync 逃生舱 ─────────────────────────────────────────────────
Future<T> _ffi<T>(WidgetTester tester, Future<T> Function() body) async {
  final r = await tester.runAsync(body);
  return r as T;
}

Future<void> _realWait(WidgetTester tester, int ms) async {
  await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
}

void _claim(WidgetTester tester, String where) {
  var n = 0;
  while (true) {
    final e = tester.takeException();
    if (e == null) break;
    n++;
    if (n <= 2) log('$where| ★ 收走异常: $e');
  }
  if (n > 2) log('$where| 共收走 $n 个异常');
}

/// 反复「真等待 + pump」直到条件成立（或轮数用尽）
Future<bool> _settleUntil(
  WidgetTester tester,
  bool Function() done, {
  int maxRounds = 24,
  int ms = 300,
}) async {
  for (var i = 0; i < maxRounds; i++) {
    await _realWait(tester, ms);
    await tester.pump();
    _claim(tester, 'until$i');
    if (done()) return true;
  }
  return false;
}

/// 页面宿主：与 t95 同一个形状（SettingsSubPage 里那些 TextField / ListTile
/// 需要 Material 祖先 + MaterialLocalizations，material_ui 的 MaterialApp 给）
Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

PluginEntry? _find(PluginListResult r, String id) {
  for (final p in r.plugins) {
    if (p.id == id) return p;
  }
  return null;
}

/// 真宿主后端：一行一个转手 SourinApi（页面**不**直接调 static，见
/// emby_page.dart:1179 的 EmbyBackend 说明），这里顺便数调用次数
class _RealHost implements EmbyBackend {
  int listCalls = 0;
  int configGets = 0;

  @override
  Future<PluginListResult> listPlugins() {
    listCalls++;
    return SourinApi.listPlugins();
  }

  @override
  Future<PluginConfig> pluginConfigGet(String id) {
    configGets++;
    return SourinApi.pluginConfigGet(id);
  }

  @override
  Future<int> pluginConfigSet(String id, Map<String, dynamic> values) =>
      SourinApi.pluginConfigSet(id, values);

  @override
  Future<String?> providerSessionStateWire(String provider) =>
      SourinApi.providerSessionStateWire(provider);

  @override
  Future<Map<String, dynamic>> providerLogin(
          String provider, String username, String password) =>
      SourinApi.providerLogin(provider, username, password);

  @override
  Future<void> providerLogout(String provider) => SourinApi.providerLogout(provider);

  @override
  Future<PluginInstallResult> installPlugin(String url) => SourinApi.installPlugin(url);

  @override
  Future<PluginInstallResult> installPluginSource(String source,
          {String? nameHint}) =>
      SourinApi.installPluginSource(source, nameHint: nameHint);

  @override
  Future<void> removePlugin(String file) => SourinApi.removePlugin(file);

  @override
  Future<int> reloadPlugins() => SourinApi.reloadPlugins();
}

void main() {
  setUpAll(() async {
    if (!_dllReady) {
      log('★★ $_dllRel 不存在 ⇒ 跳过（先构建 Windows 版再跑本守卫）');
      return;
    }
    _preloadCoreDll();

    if (_dataDir.existsSync()) _dataDir.deleteSync(recursive: true);
    _dataDir.createSync(recursive: true);
    try {
      final started = await SourinApi.start(_dataDir.absolute.path);
      log('start() = $started');
    } catch (e) {
      log('★ SourinApi.start() 失败: $e');
    }
    UiPrefs.debugResetForTest(<String, String>{});
  });

  tearDownAll(() {
    if (_dataDir.existsSync()) {
      try {
        _dataDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  // ═══════════════════════════════════════════════════════════════════
  //  T96.0 前提自检（**不 skip** —— 没有 DLL 时它是本文件唯一的产出）
  // ═══════════════════════════════════════════════════════════════════
  testWidgets('T96.0 前提自检：真 emby.js 在仓库里，且能派生出 emby-2', (tester) async {
    log('dllReady = $_dllReady（$_dllRel）');
    final src = File(_srcRel);
    expect(src.existsSync(), isTrue, reason: '仓库里必须有未改过的 emby.js 当模板');
    final real = src.readAsStringSync();
    log('真源码 = ${utf8.encode(real).length} 字节 / ${real.length} 字符');
    expect(utf8.encode(real).length, greaterThan(20000));

    // 宿主 parse_meta 只看头部 2048 字符（plugins/mod.rs:74-104）
    expect(real.substring(0, 2048).contains('@id emby'), isTrue);
    expect(real.substring(0, 2048).contains('@id emby-2'), isFalse,
        reason: '模板本身不能已经是 emby-2，否则下面「派生」等于没派');

    final derived = debugRewriteInstance(real, 'emby-2', '公司那台');
    expect(derived, isNotNull, reason: '真源码必须命中 6 个锚点');
    final head = derived!.substring(0, 2048);
    expect(head.contains('@id emby-2'), isTrue);
    expect(head.contains('@name 公司那台'), isTrue);
    expect(head.contains('@id emby\n'), isFalse, reason: '第一份源的 @id 不能被留下');
    expect(derived.contains("id: 'emby-2',"), isTrue);
    expect(derived.contains("id: 'emby-2-setup'"), isTrue);
    expect(derived.contains("id: 'emby-2-empty'"), isTrue);
    expect(derived.contains("id: 'emby-2-lib-'"), isTrue);
  });

  // ═══════════════════════════════════════════════════════════════════
  //  T96.1 真宿主全流程：装两个源 → 两份配置 → 删第二个
  // ═══════════════════════════════════════════════════════════════════
  testWidgets('T96.1 真宿主：同一份 emby.js 派生出的第二个源是独立实例', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 4200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // ★ 每次跑前把 plugins/ 清空重装 —— 否则第二次跑会看到上一轮留下的
    //   .data/*.json（配置还在，断言「从零开始」就站不住）
    final pluginsDir = Directory(_p('plugins'));
    if (pluginsDir.existsSync()) pluginsDir.deleteSync(recursive: true);
    await _ffi(tester, SourinApi.reloadPlugins);

    final real = File(_srcRel).readAsStringSync();

    // ── ① 隔离目录里起步：一个 Emby 源都没有
    var list = await _ffi(tester, SourinApi.listPlugins);
    expect(list.plugins.where((p) => debugIsEmbyInstanceId(p.id)), isEmpty,
        reason: '隔离数据目录必须是干净的');

    // ── ② 装第一个源（真源码原样）
    final r1 = await _ffi(
        tester, () => SourinApi.installPluginSource(real, nameHint: 'emby.js'));
    log('装第一个源 → id=${r1.id} name=${r1.name} file=${r1.file} bytes=${r1.bytes}');
    expect(r1.id, 'emby');
    expect(r1.name, 'Emby');
    expect(r1.file, 'emby.js');
    expect(r1.bytes, utf8.encode(real).length,
        reason: 'bytes 是 UTF-8 字节数（plugins/mod.rs:2902 source.len()）');
    expect(_f('plugins/emby.js').existsSync(), isTrue);

    // ── ③ 派生并装第二个源
    final derived = debugRewriteInstance(real, 'emby-2', '公司那台')!;
    final r2 = await _ffi(tester,
        () => SourinApi.installPluginSource(derived, nameHint: 'emby-2.js'));
    log('装第二个源 → id=${r2.id} name=${r2.name} file=${r2.file} bytes=${r2.bytes}');
    expect(r2.id, 'emby-2');
    expect(r2.name, '公司那台');
    expect(r2.file, 'emby-2.js');

    // ★ 核心：第一个源**没被覆盖**（同 id 才会覆盖写，id 不同就是两个文件）
    expect(_f('plugins/emby.js').existsSync(), isTrue,
        reason: '装第二个源不能把第一个源的文件弄没');
    expect(_f('plugins/emby.js').readAsStringSync().contains('@id emby\n'), isTrue,
        reason: '第一个源的源码必须还是原样');
    expect(_f('plugins/emby-2.js').readAsStringSync().contains('@id emby-2'), isTrue);

    // ── ④ 宿主同时认得两个（loaded=true 且 config 非空 ⇒ hydrate 成功）
    list = await _ffi(tester, SourinApi.listPlugins);
    log('list_plugins → ${list.plugins.length} 个，failed=${list.failed}');
    final e1 = _find(list, 'emby');
    final e2 = _find(list, 'emby-2');
    expect(e1, isNotNull, reason: '真宿主里必须看得到第一个源');
    expect(e2, isNotNull, reason: '真宿主里必须看得到第二个源');
    expect(e1!.loaded, isTrue, reason: '加载失败原因: ${e1.error}');
    expect(e2!.loaded, isTrue, reason: '加载失败原因: ${e2.error}');
    expect(e1.file, 'emby.js');
    expect(e2.file, 'emby-2.js');
    expect(e1.config.length, 5, reason: 'emby.js 声明 5 项配置（serverUrl/username/password/transcode/note）');
    expect(e2.config.length, 5, reason: '派生源要拿到同一份 config 声明');

    // ── ⑤ 两份配置各自落盘（这是「多源」的实质：url / 账号 / token 互不串）
    final n1 = await _ffi(
        tester,
        () => SourinApi.pluginConfigSet('emby', {
              'serverUrl': 'http://192.168.1.10:8096',
              'username': 'jia',
              'password': 'p1',
              'transcode': true,
            }));
    final n2 = await _ffi(
        tester,
        () => SourinApi.pluginConfigSet('emby-2', {
              'serverUrl': 'http://10.0.0.5:8096',
              'username': 'gongsi',
              'password': 'p2',
            }));
    log('plugin_config_set → emby 写 $n1 项 / emby-2 写 $n2 项');
    expect(n1, 4);
    expect(n2, 3, reason: '没传 transcode ⇒ 只写 3 项（未声明的键才忽略，未传的键不写）');

    final c1 = await _ffi(tester, () => SourinApi.pluginConfigGet('emby'));
    final c2 = await _ffi(tester, () => SourinApi.pluginConfigGet('emby-2'));
    log('emby   serverUrl=${c1.values['serverUrl']} user=${c1.values['username']} transcode=${c1.values['transcode']}');
    log('emby-2 serverUrl=${c2.values['serverUrl']} user=${c2.values['username']} transcode=${c2.values['transcode']}');
    expect(c1.values['serverUrl'], 'http://192.168.1.10:8096');
    expect(c2.values['serverUrl'], 'http://10.0.0.5:8096');
    expect(c1.values['username'], isNot(c2.values['username']));
    expect(c1.values['transcode'], isTrue);
    expect(c2.values['transcode'], isFalse, reason: '没设过 ⇒ 取声明默认值 false');
    // resolved_config 保证返回全部声明键（plugins/mod.rs:1768-1779）
    expect(c1.values.length, greaterThanOrEqualTo(5));
    expect(c2.values.length, greaterThanOrEqualTo(5));

    // ── ⑥ 磁盘证据：一个源一个 JSON，内容不同
    //
    // ★ 路径依据（写侧与读侧必须是同一处，否则就是"设置页存了、插件读不到"
    //   那个经典 bug —— commands_remote.rs:47-58 的注释记的就是它）：
    //     · 插件读：plugins/mod.rs:2362  let data_dir = dir.join(".data")
    //     · 界面写：commands_remote.rs:62-64  plugin_data_dir = plugins_dir.join(".data")
    //     · 文件名：plugins/mod.rs:1545  store_path = dir.join("<id>.json")
    final f1 = _f('plugins/.data/emby.json');
    final f2 = _f('plugins/.data/emby-2.json');
    // 找不到时把 plugins/ 下**真实**有什么打出来 —— 不猜
    // 同时列数据目录**根部**：旧版核心会把配置写在 `<dataDir>/<id>.json`
    // （不是插件读的 plugins/.data/），这条日志就是用来抓它的
    log('dataDir 根部 = ${Directory(_dataDir.path).listSync().map((e) => e.path.replaceAll(_dataDir.path, '')).toList()}');
    log('plugins/ 下真实内容 = ${Directory(_p('plugins')).listSync(recursive: true).map((e) => e.path.replaceAll(_dataDir.path, '')).toList()}');
    log('emby.json   存在=${f1.existsSync()}');
    log('emby-2.json 存在=${f2.existsSync()}');
    expect(f1.existsSync(), isTrue, reason: '配置必须落在 plugins/.data/（插件也读这一处）');
    expect(f2.existsSync(), isTrue);
    final m1 = jsonDecode(f1.readAsStringSync()) as Map<String, dynamic>;
    final m2 = jsonDecode(f2.readAsStringSync()) as Map<String, dynamic>;
    expect(m1['cfg:serverUrl'], 'http://192.168.1.10:8096');
    expect(m2['cfg:serverUrl'], 'http://10.0.0.5:8096');
    expect(m1['cfg:username'], 'jia');
    expect(m2['cfg:username'], 'gongsi');
    expect(m2['cfg:transcode'], isNull, reason: '没写过的键不该凭空出现在第二个源的文件里');
    expect(m1.keys.join(','), isNot(m2.keys.join(',')));

    // ── ⑦ 删掉第二个源：第一个还在，第二个的配置**没被连带删掉**
    await _ffi(tester, () => SourinApi.removePlugin('emby-2.js'));
    expect(_f('plugins/emby-2.js').existsSync(), isFalse);
    expect(_f('plugins/emby.js').existsSync(), isTrue, reason: '删一个不能伤到另一个');
    expect(f2.existsSync(), isTrue,
        reason: 'remove_plugin 只删 .js（commands_provider.rs:179-197），配置留着');

    list = await _ffi(tester, SourinApi.listPlugins);
    expect(_find(list, 'emby-2'), isNull, reason: '删完必须从 registry 里摘掉');
    expect(_find(list, 'emby'), isNotNull);
    log('删除后剩余 Emby 实例 = '
        '${list.plugins.where((p) => debugIsEmbyInstanceId(p.id)).map((p) => p.id).toList()}');
  }, timeout: kTimeout, skip: !_dllReady);

  // ═══════════════════════════════════════════════════════════════════
  //  T96.2 真宿主上的**页面**：列表两行，地址各自来自各自那份 JSON
  // ═══════════════════════════════════════════════════════════════════
  testWidgets('T96.2 真宿主 + 真页面：两个源同时出现在列表里', (tester) async {
    tester.view.physicalSize = const Size(1400, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // T96.1 把 emby-2 删了 ⇒ 这里重新装回来（顺便验一次「同 id 覆盖写」）
    final real = File(_srcRel).readAsStringSync();
    final derived = debugRewriteInstance(real, 'emby-2', '公司那台')!;
    final again = await _ffi(tester,
        () => SourinApi.installPluginSource(derived, nameHint: 'emby-2.js'));
    expect(again.id, 'emby-2');
    expect(_f('plugins/emby-2.js').existsSync(), isTrue);

    // 首页源栏现在指着第二个源（UiPrefs.homeSource 是**全局单选**）
    UiPrefs.debugResetForTest(<String, String>{UiPrefs.homeSourceKey: 'emby-2'});

    final host = _RealHost();
    await tester.pumpWidget(_wrap(EmbySettingsPage(host: host)));
    _claim(tester, 'T96.2|pump');

    final ok = await _settleUntil(
      tester,
      () => find.textContaining('首页正在用').evaluate().isNotEmpty,
    );
    _claim(tester, 'T96.2|settle');
    expect(ok, isTrue, reason: '页面没在 24 轮内渲染出实例列表');
    expect(host.listCalls, greaterThan(0), reason: '页面必须真调了 listPlugins');

    // ★ 地址来自真宿主读回的 plugins/.data/<id>.json —— 两行各不相同
    // ★ 必须限定在 ListTile 里：同一个地址字符串在「服务器地址」输入框里也有
    //   一份（那是当前编辑实例的输入框），不限定就会数到 3 个。
    Finder inTile(String s) => find.descendant(
          of: find.byType(ListTile),
          matching: find.textContaining(s),
        );
    final t1 = inTile('192.168.1.10:8096');
    final t2 = inTile('10.0.0.5:8096');
    // ★ 标题同样限定在 ListTile 里：当前编辑实例的名字还会出现在
    //   「服务器配置」区块的归属提示（'下面这些会写进「公司那台」（emby-2）'）
    //   以及「连接自检」的按钮文案里 —— 那是**有意的**重复，不是 bug。
    final tName = inTile('公司那台');
    final tHome = find.textContaining('首页正在用');
    final tDel = find.byTooltip('删除这个源');
    log('页面读数 → 第一个源地址=${t1.evaluate().length}'
        ' 第二个源地址=${t2.evaluate().length}'
        ' 第二行标题=${tName.evaluate().length}'
        ' 首页正在用=${tHome.evaluate().length}'
        ' 删除按钮=${tDel.evaluate().length}');
    expect(t1.evaluate().length, 1);
    expect(t2.evaluate().length, 1);
    expect(tName.evaluate().length, 1,
        reason: '第二行的标题是派生时写进 @name 的名字');
    expect(tHome.evaluate().length, 1, reason: '只有被首页选中的那个源带这个标注');
    expect(tDel.evaluate().length, 2, reason: '两行各有一个删除按钮');

    // 收尾：先拆树，再推长时长排掉二级页 _flash 的 3 秒一次性 Timer
    await tester.pumpWidget(const SizedBox.shrink());
    _claim(tester, 'T96.2|teardown');
    await _realWait(tester, 100);
    await tester.pump(const Duration(seconds: 5));
    _claim(tester, 'T96.2|teardown2');
  }, timeout: kTimeout, skip: !_dllReady);
}
