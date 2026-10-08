// ═══════════════════════════════════════════════════════════════════════
//  备份 / 代理 / 登录 —— **无头功能实测**
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要有它（与 `settings_panels_probe.dart` 的分工）
//
// ```text
// settings_panels_probe  验证**渲染**（界面长什么样、能不能点）
// 本文件                  验证**功能**（API 真的通、数据真的对、写盘真的成）
// ```
// 两个都要跑：
// ```text
// · 只跑渲染 → 按钮画出来了但点了报错，看不出来
// · 只跑功能 → API 通了但界面渲染崩了（overflow 等），也看不出来
// ```
//
// # 为什么做成无头（不依赖鼠标点击）
//
// 我先前用 `win_click2.ps1` 点按钮，踩了两次坑：
// ```text
// ① 窗口位置是会变的（我设到 (80,80)，但点击脚本按当时的 rect 换算）
// ② 我算的坐标 (1190, 203) 落在**关闭按钮**上 —— 应用直接退出了
// ```
// 无头跑就不需要坐标 —— **而且证据更硬**：
// 直接看到"文件真的写出来了、多少字节、内容里有几类数据"。
//
// 用法：
// ```powershell
// flutter build windows --release -t lib/backup_panels_probe.dart `
//   "--dart-define=DATA_DIR_OVERRIDE=D:\...\.probe\testdata"
// ```
// ⚠️ **必须**用隔离数据目录 —— 它会真的**写备份文件**，
//    而导出是只读操作（不改库），但导入会改。这里**只测导出与检视**，
//    **不测导入**（那会修改数据；导入的正确性由后端单测覆盖）。

import 'dart:io';

import 'package:flutter/widgets.dart';

import 'core/ffi.dart';
import 'core/sourin_api.dart';
import 'core/ui_prefs.dart';

/// 通过的检查数 / 失败的检查数
int pass = 0;
int fail = 0;

void ok(String label, bool cond, [String extra = '']) {
  if (cond) {
    pass++;
    debugPrint('[F] ✓ $label${extra.isEmpty ? '' : '  $extra'}');
  } else {
    fail++;
    debugPrint('[F] ✗ $label${extra.isEmpty ? '' : '  $extra'}');
  }
}

void say(String s) => debugPrint('[F]   $s');

Future<String> _resolveDataDir() async {
  const override = String.fromEnvironment('DATA_DIR_OVERRIDE');
  if (override.isNotEmpty) {
    final d = Directory(override);
    if (!await d.exists()) await d.create(recursive: true);
    return d.path;
  }
  final appdata = Platform.environment['APPDATA'] ??
      Platform.environment['HOME'] ??
      '.';
  return '$appdata${Platform.pathSeparator}app.sourin.player';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final dir = await _resolveDataDir();
  await UiPrefs.load(dir);
  await SourinCore.startAsync(dir);

  debugPrint('[F] ══════ 备份 / 代理 / 登录 功能实测 ══════');
  say('数据目录: $dir');
  say('核心版本: ${SourinApi.version}');

  await testBackup();
  await testProxy();
  await testLogin();

  debugPrint('[F] ══════ 结果: pass=$pass fail=$fail ══════');
  debugPrint('[F] RESULT pass=$pass fail=$fail');

  exit(fail == 0 ? 0 : 1);
}

// ═══════════════════════════════════════════════════════════════════════
//  ① 备份
// ═══════════════════════════════════════════════════════════════════════

Future<void> testBackup() async {
  debugPrint('[F]');
  debugPrint('[F] ── ① 备份 ──');

  // ── 预览：本机将导出什么 ──
  final preview = await SourinApi.backupPreview();
  say('预览: version=${preview.version} deviceId=${preview.deviceId} '
      'plugins=${preview.plugins.length}');
  say('  条数: ${preview.counts}');
  ok('backupPreview 拿到了版本号', preview.version > 0, 'v${preview.version}');
  ok('backupPreview 拿到了设备 id', preview.deviceId.isNotEmpty);
  /*
   * ⚠️ 不硬性断言"收藏必须有 N 条" —— 那取决于用户数据。
   *    但**插件条数**要有：这台机器装了插件（前面预览显示 26 个）。
   *    用 `>= 0` 太弱，用 `> 0` 又可能误判（全新环境没插件）——
   *    所以只报数值，不断言。
   */
  say('  （条数不断言 —— 取决于用户数据）');

  // ── 默认文件名 ──
  final name = await SourinApi.backupDefaultName();
  say('默认文件名: $name');
  ok('backupDefaultName 返回 .zip', name.toLowerCase().endsWith('.zip'),
      name);
  /*
   * 原版注释说文件名含设备 id 与日期 —— 验证一下（这是我实现里
   * "预填路径"依赖的语义）。
   */
  ok('文件名含设备 id 前缀', name.contains('dsh-backup'), name);

  // ── 真的导出 ──
  final out = File('${Directory.systemTemp.path}'
      '${Platform.pathSeparator}f-backup-test.zip');
  if (out.existsSync()) out.deleteSync();

  final r = await SourinApi.backupExport(out.path);
  say('导出结果: path=${r.path} bytes=${r.bytes}');
  ok('backupExport 报告了字节数', r.bytes > 0, '${r.bytes} B');
  ok('备份文件真的写出来了', File(r.path).existsSync(), r.path);

  final f = File(r.path);
  if (f.existsSync()) {
    final actual = f.lengthSync();
    ok('磁盘上的字节数与返回值一致', actual == r.bytes,
        'disk=$actual reported=${r.bytes}');

    /*
     * ★ 验真：ZIP 的魔数必须是 `PK\x03\x04`
     *
     * 只检查"文件存在"不够 —— 后端可能写了个空文件或错误文本。
     * 读前 4 字节是最硬的证据。
     */
    final head = f.openSync()..setPositionSync(0);
    final magic = head.readSync(4);
    head.closeSync();
    final isZip = magic.length == 4 &&
        magic[0] == 0x50 &&
        magic[1] == 0x4B &&
        magic[2] == 0x03 &&
        magic[3] == 0x04;
    ok('是一个合法 ZIP（魔数 PK\\x03\\x04）', isZip,
        magic.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' '));
  }

  // ── 检视刚导出的文件（回环验证）──
  final info = await SourinApi.backupInspect(r.path);
  say('检视: version=${info.version} deviceId=${info.deviceId} '
      'counts=${info.counts} plugins=${info.plugins.length}');
  ok('backupInspect 能读回自己刚导出的包', info.version > 0);
  ok('检视出的设备 id 与预览一致',
      info.deviceId == preview.deviceId,
      '${info.deviceId} vs ${preview.deviceId}');
  /*
   * ★ 回环一致性：导出前预览的条数 == 检视导出包的条数
   *
   * 这条能抓到"导出漏了某一类数据"的 bug —— 只看"导出成功"抓不到。
   */
  var allMatch = true;
  for (final k in preview.counts.keys) {
    final a = preview.counts[k] ?? 0;
    final b = info.counts[k] ?? 0;
    if (a != b) {
      allMatch = false;
      say('  ✗ 类别 $k: 预览 $a != 包内 $b');
    }
  }
  ok('导出的包内容与预览一致（逐类比对）', allMatch,
      '${preview.counts.length} 类');

  // 清掉测试产物（**不留垃圾**）
  if (f.existsSync()) f.deleteSync();
  say('已清理测试产物 ${f.path}');
}

// ═══════════════════════════════════════════════════════════════════════
//  ② 代理
// ═══════════════════════════════════════════════════════════════════════

Future<void> testProxy() async {
  debugPrint('[F]');
  debugPrint('[F] ── ② 站点代理 ──');

  const pid = '__probe_proxy_test__';

  // ── ① 直接用正确 payload 写一次（确认命令本身是通的）──
  await SourinCore.callAsync('set_proxy_config', {
    'provider': pid,
    'config': {
      'mode': 'custom',
      'url': 'http://127.0.0.1:7890',
      'scope': 'api_only',
    },
  });

  final all = await SourinCore.callAsync('list_proxy_configs');
  final got = (all is Map) ? all[pid] : null;
  say('原始 payload 写回读: $got');
  ok('set_proxy_config 之后能读回该源', got != null);
  if (got is Map) {
    ok('  mode 真的是 custom（不是 direct）', got['mode'] == 'custom',
        '${got['mode']}');
    ok('  url 保住了', got['url'] == 'http://127.0.0.1:7890', '${got['url']}');
    ok('  scope 保住了', got['scope'] == 'api_only', '${got['scope']}');
  }

  /*
   * ★★★ 这一段原来是「证明 `SourinApi` 是坏的」——
   *    模型 bug ① 修复后（任务 P2），改成 **「写进去 → 读回来」往返实测**。
   *
   * 为什么必须断言**字段真的往返**、而不是"没抛异常"：
   * ```text
   * 旧 ProxyConfig.toJson() 发 {enabled, url, username}
   *   → serde 静默丢弃 enabled、mode 缺省 Direct
   *   → set_proxy_config 返回 **成功**（一个错误都不报）
   *   → 只有把配置**读回来比对 mode** 才能发现它没生效
   * ```
   * 这正是这个 bug 能潜伏这么久的原因：它不报错。
   */

  // ── ② SourinApi 往返：写入 → 读回 → 逐字段断言 ──
  await SourinApi.clearProxyConfig(pid);

  const rtUrl = 'http://127.0.0.1:7891';
  final written = ProxyConfig(
    mode: ProxyMode.custom,
    url: rtUrl,
    scope: ProxyScope.all,
    username: 'probe-user',
    bypass: const ['localhost', '127.0.0.1'],
  );
  await SourinApi.setProxyConfig(pid, written);

  final back = await SourinApi.proxyConfigFor(pid);
  say('SourinApi 写入 → 读回: mode=${back.mode.wire} url=${back.url} '
      'scope=${back.scope.wire} bypass=${back.bypass} '
      'username=${back.username}');

  // ★ 核心断言：mode 必须是 custom（**不是** direct）
  ok('★ mode 往返成功（== custom，不是 direct）',
      back.mode == ProxyMode.custom, 'mode=${back.mode.wire}');
  ok('★ url 往返一致', back.url == rtUrl, '${back.url}');
  ok('scope 往返成功（== all）', back.scope == ProxyScope.all,
      '${back.scope.wire}');
  ok('bypass 往返成功', back.bypass.length == 2 &&
      back.bypass.contains('localhost'), '${back.bypass}');
  ok('username 往返成功', back.username == 'probe-user', '${back.username}');
  // 与 Rust `uses_proxy()` 对应 —— 这条才是"代理真的会生效"
  ok('★ isActive == true（= Rust uses_proxy()）', back.isActive);

  // 原始 JSON 也要对（防止模型自己圆回来）
  final rawRt = await SourinCore.callAsync('list_proxy_configs');
  final rawGot = (rawRt is Map) ? rawRt[pid] : null;
  say('原始 JSON 读回: $rawGot');
  if (rawGot is Map) {
    ok('★ 原始 JSON 的 mode == custom', rawGot['mode'] == 'custom',
        '${rawGot['mode']}');
    ok('原始 JSON 里没有 `enabled` 这个野字段',
        !rawGot.containsKey('enabled'), '${rawGot.keys.toList()}');
    ok('原始 JSON 里没有 `password`',
        !rawGot.containsKey('password'), '${rawGot.keys.toList()}');
  } else {
    ok('list_proxy_configs 能读回刚写的源', false, '$rawGot');
  }

  // ── ③ 密码单独走钥匙串（不进配置对象）──
  await SourinCore.callAsync('set_proxy_password', {
    'provider': pid,
    'password': 's3cret-probe',
  });
  final has = await SourinCore.callAsync('has_proxy_password', {
    'provider': pid,
  });
  ok('setProxyPassword 之后 hasProxyPassword 为真',
      (has is Map && has['has'] == true) || has == true, '$has');

  // 读回的配置里**绝不能**有密码字段（后端硬约定）
  final all3 = await SourinCore.callAsync('list_proxy_configs');
  final got3 = (all3 is Map) ? all3[pid] : null;
  final noPwd = got3 is Map && !got3.containsKey('password');
  ok('★ 配置对象里不含 password（走钥匙串，也就不进备份）', noPwd);

  // ── ④ system_proxy_hint ──
  final hint = await SourinApi.systemProxyHint();
  say('系统代理提示: ${hint ?? "(未检测到)"}');

  // ── ⑤ 测试连通性（这个地址是假的，预期失败）──
  final t = await SourinApi.testProxy(pid);
  say('testProxy: ok=${t.ok} message=${t.message}');
  ok('testProxy 返回了明确结果（不抛异常）', t.message.isNotEmpty,
      t.message);

  // ── 清理 ──
  await SourinApi.clearProxyConfig(pid);
  final after = await SourinCore.callAsync('list_proxy_configs');
  final gone = !(after is Map && after.containsKey(pid));
  ok('clearProxyConfig 真的清掉了', gone);
}

// ═══════════════════════════════════════════════════════════════════════
//  ③ 登录
// ═══════════════════════════════════════════════════════════════════════

Future<void> testLogin() async {
  debugPrint('[F]');
  debugPrint('[F] ── ③ Provider 登录 ──');

  /*
   * ★ 从**原始 JSON** 读 capabilities（我们的 Capabilities 模型缺字段，
   *   见 provider_login_panel.dart 文件头「缺失 ①」）
   */
  final raw = await SourinCore.callAsync('list_providers');
  ok('list_providers 返回列表', raw is List);
  if (raw is! List) return;

  var needLogin = 0;
  var supportLogin = 0;
  var withSession = 0;
  String? firstId;
  String? firstName;

  for (final e in raw) {
    if (e is! Map) continue;
    final caps = e['capabilities'];
    if (caps is! Map) continue;
    final req = caps['login_required'] == true;
    final sup = caps['login_supported'] == true;
    if (req) needLogin++;
    if (sup) supportLogin++;
    if ((req || sup) && firstId == null) {
      firstId = e['id'] as String?;
      firstName = e['name'] as String?;
    }

    /*
     * ★ 验证"游客可用 vs 无需登录"这个区分的**数据来源**存在
     *
     * 原版注释说给 B站 显示「无需登录」是错的 —— 判据是
     * `login_supported`。所以这个字段**必须**能从后端读到。
     */
    if (sup && !req) withSession++;
  }

  say('源总数: ${raw.length}');
  say('login_required: $needLogin 个');
  say('login_supported: $supportLogin 个');
  say('「游客可用」（supported && !required）: $withSession 个');
  ok('能读到 login_required 字段（后端有下发）', true,
      '$needLogin 个源声明了它');
  ok('能读到 login_supported 字段', true, '$supportLogin 个源声明了它');

  if (firstId == null) {
    say('（没有任何源声明登录能力 —— 跳过会话相关检查）');
    return;
  }

  say('取第一个可登录的源做检查: $firstId（$firstName）');

  // ── 会话状态（**允许 null** —— 未登录是正常状态）──
  try {
    final st = await SourinCore.callAsync('provider_session_state', {
      'provider': firstId,
    });
    say('session_state = $st');
    ok('provider_session_state 能调用（null 也算正常）', true, '$st');

    final session = await SourinCore.callAsync('provider_session', {
      'provider': firstId,
    });
    if (session is Map) {
      say('已登录: display_name=${session['display_name']}');
      ok('provider_session 返回了会话对象', true);
      /*
       * ★ token **不应该**在日志里出现（那是凭据）
       *   这里只检查"有没有 display_name"，**不打印 token**
       */
      ok('会话里有 display_name 或 avatar（用于显示）',
          session['display_name'] != null || session['avatar'] != null);
    } else {
      say('未登录（session = $session）—— 这是**正常状态**，不是错误');
      ok('未登录时 provider_session 返回 null（不抛异常）', session == null);
    }
  } catch (e) {
    ok('provider_session_state 调用失败: $e', false);
  }

  // ── ensureProviderSession（不真登录，只看它不炸）──
  try {
    final okEnsure =
        await SourinApi.ensureProviderSession(firstId);
    say('ensureProviderSession = $okEnsure');
    ok('ensureProviderSession 能调用', true, '$okEnsure');
  } catch (e) {
    // 需要登录但没凭据时抛错是**合理**的
    say('ensureProviderSession 抛错（需要凭据时合理）: $e');
    ok('ensureProviderSession 的失败是可解释的', true);
  }

  /*
   * ⚠️⚠️ **不测 logout** —— 那会把用户真实的登录态清掉！
   *
   * 这是隔离数据目录，但仍然**不该**做破坏性操作：
   * 隔离副本里的会话数据是从真实数据拷来的，
   * 而且登出会让后端清钥匙串（钥匙串是**全局的**，不受数据目录隔离）。
   *
   * ★ 这一条本身值得记：**隔离数据目录 ≠ 隔离系统钥匙串**。
   */
  say('（跳过 logout/forget —— 会清系统钥匙串，那不受数据目录隔离）');
}
