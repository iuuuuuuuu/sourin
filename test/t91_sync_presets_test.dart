// t91 —— WebDAV 服务预设（用户 m13471）+ 保留份数 / 自动备份设置的存在性
//
// ─────────────────────────────────────────────────────────────────────
// 这个文件守什么
// ─────────────────────────────────────────────────────────────────────
//
// 用户原话（m13471，附了一张 `配置云盘（WebDAV）` 对话框的截图）：
//   「配置云盘这里,搞几个预设,点击后自动填充域名和配置信息,比如坚果云,
//     选择后自动填充坚果云的网址 然后默认也是选择坚果云」
//
// 拆成三条**可判定**的要求：
//   ① 有几个预设（不止坚果云一个）
//   ② 点一下预设 ⇒ 地址被**自动填好**（不是留个 hint 让用户自己敲）
//   ③ 打开对话框时**默认就是坚果云**，且地址已经填好、不用动任何东西
//
// ③ 是最容易做假的一条：把 hintText 写成坚果云地址**看起来**像"默认填好了"，
//   实际上框里是空的。所以下面**不信 hint**，直接读 `TextEditingController.text`。
//
// ─────────────────────────────────────────────────────────────────────
// ★ 关键使能点：`SyncPanel` 在 `flutter test` 里**能真挂载**
// ─────────────────────────────────────────────────────────────────────
//
// 历史记录说 `SettingsPage` 在 `flutter test` 里被换成 `ErrorWidget`
// （`build()` 走到 `${SourinApi.version}` ⇒ `_ensureBound()` ⇒
//  `DynamicLibrary.open('sourin_core.dll')` 抛）。但 `SyncPanel` 不一样：
// 它的三支 `_reload()`（`syncStatus()` / `syncSettings()` / `syncBackupList()`）
// **全都包了 try/catch** ⇒ FFI 抛了只是打一行 debugPrint，面板照常渲染。
//
// 实测（本文件的 `⓪` 段就是这条的回归锁）：`ErrorWidget=0 / 云盘同步=1 /
// 配置云盘=1`。⇒ 于是这里能走**真树真点**的路线：
// 挂面板 → 点「配置云盘」→ 对话框真的弹出来 → 真的点预设胶囊 →
// 真的读回四个输入框的 controller。这比只扫源码强得多。
//
// ─────────────────────────────────────────────────────────────────────
// ★ 剥注释：必须用共享实现（铁律 170）
// ─────────────────────────────────────────────────────────────────────
//
// `test/_support/strip_comments.dart` 是全仓唯一的剥注释实现。
// `test/settings_panels_test.dart:24-119` 自己抄了一份，那是**反例**，不许学。
// 本文件 `import '_support/strip_comments.dart';`。
//
// ★ 而且这里**需要**剥注释才成立：`sync_panel.dart` 的注释里**故意**写了
//   「坚果云国际版 `nutstore.net` 没有独立 WebDAV 地址」这句提醒 ——
//   若拿原文去断言「不得出现 nutstore」，就会把自己写的注释当成编造地址。
//   ⇒ 判据落在剥完注释的代码上；同时用**阳性对照**证明"剥"没有把文件剥空。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/widgets/settings_kit.dart';
import 'package:sourin_spike/ui/widgets/sync_panel.dart';

import '_support/strip_comments.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

const _panel = 'lib/ui/widgets/sync_panel.dart';

String _rawOf(String path) => File(path).readAsStringSync();
String _codeOf(String path) => stripComments(_rawOf(path));

/// 宿主模板（照本仓惯例 `test/t38_login_autosopen_test.dart:48-58`）
Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    builder: (context, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

/// 对话框里的第 `i` 个 `TextField` 的**实际内容**
///
/// ★ 直接读 controller —— 不信 `hintText`。
///   hint 是"框空着时显示的灰字"，恰恰是"其实没填"最容易伪装成的样子。
String _fieldText(WidgetTester t, int i) {
  final fields = t.widgetList<TextField>(find.byType(TextField)).toList();
  return fields[i].controller?.text ?? '';
}

TextField _field(WidgetTester t, int i) =>
    t.widgetList<TextField>(find.byType(TextField)).elementAt(i);

/// 打开对话框并等它落定（不用 `pumpAndSettle`：它超时会抛，且对无限动画会挂）
Future<void> _openDialog(WidgetTester t) async {
  await t.tap(find.text('配置云盘'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 500));
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ⓪ 仪器自检：面板真的挂上了（否则后面所有 tap 都会以"找不到 XX"失败）
  // ═══════════════════════════════════════════════════════════════════
  group('⓪ 仪器自检', () {
    testWidgets('★★ SyncPanel 能真挂载（不是 ErrorWidget）', (t) async {
      t.view.physicalSize = const Size(1280, 1600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      await t.pumpWidget(_host(const SyncPanel()));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));

      /*
       * ★ 这条**不是**洁癖：`SyncPanel.initState` 会
       *   `addPostFrameCallback((_) => _reload())` ⇒ 三个 FFI 调用必然失败
       *   （测试进程里没有 `sourin_core.dll`）。若有人把某支 try/catch 拆掉，
       *   整棵树会被换成 `ErrorWidget`，而**下面的每条断言都会以
       *   "找不到 XX" 失败** —— 报错信息完全不指向真因。
       *   ⇒ 这里先把它钉死。
       */
      expect(
        find.byType(ErrorWidget).evaluate(),
        isEmpty,
        reason: '★ SyncPanel 被换成了 ErrorWidget ⇒ 某一支 `_reload()` '
            '的 try/catch 没了（FFI 在测试进程里必然失败）。\n'
            '⚠️ 真因只在 stderr 的 debugPrint 里，别只看这里。',
      );
      expect(find.text('云盘同步'), findsOneWidget);
      expect(find.text('配置云盘'), findsOneWidget);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ① 预设表：只收官方可查证的地址，绝不编
  // ═══════════════════════════════════════════════════════════════════
  group('① 预设表（源码级）', () {
    late String raw;
    late String code;
    late List<String> urls;

    setUpAll(() {
      raw = _rawOf(_panel);
      code = _codeOf(_panel);
      final at = code.indexOf('_kWebdavPresets');
      expect(
        at > 0,
        isTrue,
        reason: '★ 前置：剥完注释后找不到 `_kWebdavPresets` '
            '（要么预设表被删了，要么剥注释把它剥掉了）',
      );
      final block = code.substring(at);
      urls = RegExp(r"url: '([^']*)'")
          .allMatches(block)
          .map((m) => m.group(1)!)
          .toList();
    });

    test('★ 阳性对照：剥注释没有把文件剥空，预设表也读到了', () {
      /*
       * ★ 没有这条，下面「不许出现 X」的阴性断言全是假的 ——
       *   万一 `stripComments` 把整个文件剥成空串，
       *   `urls` 就是 `[]`，每一条 `contains` 都"通过"。
       *   （铁律：阴性断言必须配阳性对照。）
       */
      expect(raw.length, greaterThan(20000), reason: '★ 源文件太小，不像 sync_panel.dart');
      expect(code.length, greaterThan(10000), reason: '★ 剥注释后太短 ⇒ 怀疑剥过头');
      expect(code.length, lessThan(raw.length), reason: '★ 剥完必须更短（确实剥了）');
      expect(urls.length, greaterThanOrEqualTo(8), reason: '★ 至少 8 个预设');
      expect(urls.first, 'https://dav.jianguoyun.com/dav/');
    });

    test('★★★ 第一个预设 = 坚果云（用户要求"默认也是选择坚果云"）', () {
      /*
       * 顺序本身就是判据：`initState` 里 `_preset = _kWebdavPresets.first`。
       * 若有人把别的服务插到前面，默认项就**静默**变了 —— 而用户的原话是
       * 「默认也是选择坚果云」。
       */
      final block = code.substring(code.indexOf('_kWebdavPresets'));
      final firstName = RegExp(r"name: '([^']*)'").firstMatch(block)?.group(1);
      expect(
        firstName,
        '坚果云',
        reason: '★★★ 预设表第一项必须是坚果云 —— 它是默认选中项，'
            '顺序变了默认就变了（用户 m13471：「默认也是选择坚果云」）',
      );
      expect(urls.first, 'https://dav.jianguoyun.com/dav/');
    });

    test('★★★ 地址白名单：每个 url 都是官方可查证的，编不出来', () {
      /*
       * ★ 这条是**防"好心编地址"**。WebDAV 预设最容易出的错不是写错字，
       *   而是"我记得百度网盘好像支持" —— 然后填一个不存在的地址，
       *   用户配半天连不上，只会以为自己密码错。
       *
       * 新增服务必须**同时**改这里 ⇒ 强制后来者先去找官方文档。
       * （文件头 `sync_panel.dart:940-949` 写了收录标准与不收录名单。）
       */
      const allowed = <String>{
        // 4 个可直接用的
        'https://dav.jianguoyun.com/dav/',
        'https://webdav.pcloud.com',
        'https://app.koofr.net/dav/Koofr',
        'https://webdav.yandex.ru',
        // 4 个需要替换 <…> 的模板
        'https://<主机>/remote.php/dav/files/<用户名>/',
        'https://<主机>:5006/',
        'https://<UserID>.infini-cloud.net/dav/',
      };
      for (final u in urls) {
        expect(
          allowed,
          contains(u),
          reason: '★★★ 预设里出现了白名单外的地址：`$u`。\n'
              '· 若这是新服务的**官方** WebDAV 地址 ⇒ 去找官方文档，'
              '然后把地址加进本测试的 `allowed`（这一步是故意的关卡）\n'
              '· 若是"猜的 / 记得好像有" ⇒ 删掉它。文件头写明：'
              '功能存在但地址只有第三方文档的一律不收，'
              '明确没有原生 WebDAV 的绝不编地址',
        );
      }
      for (final u in urls) {
        expect(u.startsWith('https://'), isTrue, reason: '★ 必须 https：$u');
      }
    });

    test('★★ 不得出现编造的坚果云国际版地址（阴性 + 阳性对照）', () {
      /*
       * ★ 坚果云国际版（Nutstore）**没有**独立的 WebDAV 域名。
       *   `dav.nutstore.net` 是"看起来很合理"的编造。
       *
       * ★ 双侧检查（铁律：阴性断言必须配阳性对照）：
       *   ① 剥完注释的代码里**不得**出现 `nutstore`（判据）
       *   ② 原文里**必须**出现 `nutstore`（证明这个词确实在文件里，
       *      只不过是在注释里提醒后人 —— 若 ② 挂了，说明提醒被删了）
       */
      expect(
        code.contains('nutstore'),
        isFalse,
        reason: '★★ 编造的坚果云国际版地址泄漏进了**代码**（不是注释）。'
            '坚果云只有 dav.jianguoyun.com 这一个 WebDAV 域名',
      );
      expect(
        raw.contains('nutstore'),
        isTrue,
        reason: '★ 阳性对照失败：连注释里那句「坚果云国际版没有独立 WebDAV '
            '地址」的提醒都没了 —— 后人会再踩一次这个坑',
      );
    });

    test('★ 4 个模板地址必须含 `<…>`，且保存时会被拦下来', () {
      /*
       * 模板（`https://<主机>/…`）直接保存必然连接失败，
       * 后端只会报「无法连接（检查地址与网络）」⇒ 用户以为密码错。
       * ⇒ 生产代码里必须有占位符拦截。
       */
      final templates = urls.where((u) => u.contains('<')).toList();
      expect(
        templates.length,
        greaterThanOrEqualTo(1),
        reason: '★ 至少要有一个模板地址（Nextcloud / 群晖 / InfiniCLOUD 这些'
            '必须先替换主机名），否则"拦占位符"这段代码永远走不到',
      );
      expect(
        code.contains("url.contains('<')"),
        isTrue,
        reason: '★★ 占位符拦截没了 —— 模板地址会被当真实地址提交，'
            '用户看到的是「无法连接」而不是「请先替换 <主机>」',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 真树真点：打开对话框 ⇒ 默认坚果云 ⇒ 点预设自动填充
  // ═══════════════════════════════════════════════════════════════════
  group('② 真树真点（挂 SyncPanel 并真的操作对话框）', () {
    /// 每个用例都从头挂一次，保证互不污染
    Future<void> boot(WidgetTester t) async {
      t.view.physicalSize = const Size(1280, 1600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(_host(const SyncPanel()));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
    }

    testWidgets('★★★ 打开即"默认坚果云"：地址和远程目录**已经填好**', (t) async {
      await boot(t);
      await _openDialog(t);

      expect(find.text('配置云盘（WebDAV）'), findsOneWidget, reason: '对话框没弹出来');
      expect(
        find.byType(TextField).evaluate().length,
        4,
        reason: '★ 对话框应有 4 个输入框（地址/用户名/密码/远程目录）',
      );

      /*
       * ★★ 判据核心：不信 hint，直接读 controller。
       *    「默认也是选择坚果云」= 打开就能直接填用户名点保存，
       *    **不需要**先点一下坚果云。
       */
      expect(
        _fieldText(t, 0),
        'https://dav.jianguoyun.com/dav/',
        reason: '★★★ 打开对话框时地址框**必须已经填好坚果云地址**。\n'
            '· 空着 ⇒ 只把地址写进了 `hintText`，看着像填好了其实没填 '
            '（用户要求的是"自动填充域名和配置信息"）\n'
            '· 是别的地址 ⇒ 默认项不是坚果云',
      );
      expect(
        _fieldText(t, 3),
        'sourin',
        reason: '★ 远程目录也要顺手填好（用户说的"自动填充配置信息"）',
      );

      // 表单结构顺手锁一下（顺序错了 tab 序就乱了）
      expect(_fieldText(t, 1), '', reason: '用户名必须留空给用户填');
      expect(_fieldText(t, 2), '', reason: '密码必须留空');
      expect(
        _field(t, 2).obscureText,
        isTrue,
        reason: '★ 密码框必须 obscureText（明文显示 WebDAV 密码是缺陷）',
      );
      expect(
        _field(t, 1).decoration?.hintText,
        '坚果云账号邮箱（完整邮箱）',
        reason: '★ 用户名的提示要跟着预设走（坚果云要完整邮箱）',
      );
      expect(
        _field(t, 2).decoration?.hintText,
        '第三方应用密码（不是登录密码）',
        reason: '★★ 坚果云**必须**用第三方应用密码 —— '
            '这条提示是用户能不能配通的关键（用登录密码连不上）',
      );
    });

    testWidgets('★★★ 默认选中态在坚果云身上（其余都不选中）', (t) async {
      await boot(t);
      await _openDialog(t);

      /*
       * ★ "默认也是选择坚果云"有两个层面：
       *   ① 地址填好（上一条已锁）
       *   ② 胶囊**高亮**在坚果云上 —— 否则用户看到 8 个灰胶囊，
       *      会以为自己还要选一个，而地址框里已经有内容，更迷惑。
       */
      SettingsGesturePill pill(String name) =>
          t.widget<SettingsGesturePill>(
            find.widgetWithText(SettingsGesturePill, name),
          );

      expect(pill('坚果云').selected, isTrue, reason: '★★★ 坚果云胶囊必须默认高亮');
      for (final other in const [
        'Nextcloud',
        'ownCloud',
        '群晖 NAS',
        'pCloud',
        'Koofr',
        'Yandex Disk',
        'InfiniCLOUD',
      ]) {
        expect(
          find.widgetWithText(SettingsGesturePill, other),
          findsOneWidget,
          reason: '★ 预设胶囊 `$other` 没渲染出来',
        );
        expect(pill(other).selected, isFalse, reason: '★ `$other` 不该默认选中');
      }
    });

    testWidgets('★★★ 点预设 ⇒ 地址被真的填进去（群晖为例）', (t) async {
      await boot(t);
      await _openDialog(t);

      await t.tap(find.widgetWithText(SettingsGesturePill, '群晖 NAS'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));

      expect(
        _fieldText(t, 0),
        'https://<主机>:5006/',
        reason: '★★★ 点预设后地址框必须变成该服务的地址（用户要求'
            '「点击后自动填充域名和配置信息」）',
      );
      expect(
        t
            .widget<SettingsGesturePill>(
              find.widgetWithText(SettingsGesturePill, '群晖 NAS'),
            )
            .selected,
        isTrue,
        reason: '★ 点过之后选中态要跟着搬家',
      );
      expect(
        t
            .widget<SettingsGesturePill>(
              find.widgetWithText(SettingsGesturePill, '坚果云'),
            )
            .selected,
        isFalse,
        reason: '★ 坚果云要取消选中（同一时刻只能有一个选中）',
      );
      expect(
        _field(t, 1).decoration?.hintText,
        'DSM 用户名',
        reason: '★ 用户名提示也要跟着预设变',
      );

      // 再点回坚果云：能来回切，不是单向
      await t.tap(find.widgetWithText(SettingsGesturePill, '坚果云'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(
        _fieldText(t, 0),
        'https://dav.jianguoyun.com/dav/',
        reason: '★ 切回坚果云要能切回去',
      );
    });

    testWidgets('★★ 手改地址 ⇒ 预设自动"取消选中"', (t) async {
      await boot(t);
      await _openDialog(t);

      /*
       * 用户手改了地址就不再等于任何预设 ⇒ 8 个胶囊全不高亮是**对的**
       * （选中态是按当前地址算出来的，不是"上次点了谁"）。
       * ★ 这条同时验证 `onChanged` 里那个 `setState` 没被删掉 ——
       *   删了的话点完预设再手改，坚果云会**一直**亮着。
       */
      await t.enterText(find.byType(TextField).first, 'https://dav.example.com/dav/');
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));

      expect(_fieldText(t, 0), 'https://dav.example.com/dav/');
      expect(
        t
            .widget<SettingsGesturePill>(
              find.widgetWithText(SettingsGesturePill, '坚果云'),
            )
            .selected,
        isFalse,
        reason: '★★ 地址已不是坚果云，胶囊却还亮着 ⇒ `onChanged` 里的 '
            'setState 被删了（`_urlMatchesPreset` 不会重算）',
      );
    });

    testWidgets('★★★ 模板地址没替换 ⇒ 拦下来并出红字（对话框不关）', (t) async {
      await boot(t);
      await _openDialog(t);

      final fields = find.byType(TextField);
      await t.tap(find.widgetWithText(SettingsGesturePill, 'Nextcloud'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(_fieldText(t, 0), 'https://<主机>/remote.php/dav/files/<用户名>/');

      // 用户名填上（否则先撞"用户名为空直接 return"，走不到占位符判据）
      await t.enterText(fields.at(1), 'me@example.com');
      await t.pump();

      await t.tap(find.text('保存并测试'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));

      expect(
        find.textContaining('占位符'),
        findsOneWidget,
        reason: '★★★ 地址里还有 <主机> 却没提示 ⇒ 直接提交后后端只会报'
            '「无法连接（检查地址与网络）」，用户会去反复改密码',
      );
      expect(
        find.byType(AlertDialog),
        findsOneWidget,
        reason: '★★ 有占位符时对话框**不能关** —— 关了用户就看不到那句提示了',
      );
      expect(find.text('配置云盘（WebDAV）'), findsOneWidget);
    });

    testWidgets('★★★ 地址合法 ⇒ 对话框关掉并把值交出去（走到 API 调用）', (t) async {
      await boot(t);
      await _openDialog(t);

      final fields = find.byType(TextField);
      await t.enterText(fields.at(0), 'https://dav.example.com/dav/');
      await t.enterText(fields.at(1), 'me@example.com');
      await t.enterText(fields.at(2), 'app-pass');
      await t.pump();

      await t.tap(find.text('保存并测试'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));

      // ★ 用 `findsNothing` 而不是 `isEmpty`：`Finder` 不是 `Iterable`，
      //   matcher 的 `isEmpty` 对它会**无条件返回 false** ——
      //   实测它一边打印「Found 0 widgets」一边判 FAIL，是个假红。
      //   （要 `isEmpty` 得先 `.evaluate()`，见上面 ⓪ 组。）
      expect(
        find.byType(AlertDialog),
        findsNothing,
        reason: '★ 地址合法就该 pop 出结果（`Navigator.pop(context, (url:…))`）',
      );
      /*
       * ★ pop 之后 `_configureWebdav` 会调 `SourinApi.configureWebdav(...)`。
       *   测试进程里没有 `sourin_core.dll` ⇒ 必然抛 ⇒ 面板显示「配置失败：…」。
       *   **这条断言恰恰证明"值真的交出去了"**：若 pop 出去的是 null
       *   （或 record 没走到），`_configureWebdav` 会 `if (r == null) return;`
       *   直接返回 ⇒ 面板上不会出现任何消息。
       */
      expect(
        find.textContaining('配置失败'),
        findsOneWidget,
        reason: '★★ pop 出来的值没有被交给 API —— '
            '面板上没有「配置失败」说明 `_configureWebdav` 提前 return 了'
            '（pop 的是 null，或 record 字段没接上）',
      );
    });

    testWidgets('★ 取消 ⇒ 什么都不发生（面板上没有消息）', (t) async {
      await boot(t);
      await _openDialog(t);

      await t.tap(find.text('取消'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));

      expect(find.byType(AlertDialog), findsNothing, reason: '★ 取消应关掉对话框');
      expect(
        find.textContaining('配置失败'),
        findsNothing,
        reason: '★ 点了取消却去调了 API（`if (r == null) return;` 被删了）',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 保留份数 / 自动备份设置（用户 m13472）—— 源码级
  // ═══════════════════════════════════════════════════════════════════
  group('③ 保留份数与自动备份（源码级）', () {
    late String code;

    setUpAll(() {
      code = _codeOf(_panel);
    });

    test('★ 阳性对照：五个新 API 都接上了', () {
      for (final call in const [
        'SourinApi.syncSettings()',
        'SourinApi.setSyncSettings(',
        'SourinApi.syncBackupNow()',
        'SourinApi.syncBackupList()',
        'SourinApi.syncBackupDelete(',
      ]) {
        expect(
          code.contains(call),
          isTrue,
          reason: '★ 阳性对照失败：`sync_panel.dart` 里找不到 `$call` ⇒ '
              '后端做了但界面没接上，用户看不到',
        );
      }
    });

    test('★★★ 两个间隔是分开的（别合并成一个）', () {
      /*
       * ★ 这是**设计缺陷**的回归锁（契约修订 #6）。
       *   只有一个间隔时，打开"自动同步"= 每 30 分钟上传一个整包 zip，
       *   而用户的原话是「他那个就耗很低的流量」。
       *   阅读 App 就是这么拆的：进度 debounce 5 分钟、整包备份 24 小时。
       */
      expect(
        code.contains('autoIntervalMinutes'),
        isTrue,
        reason: '★★ 少了「多久看一眼云端」的间隔',
      );
      expect(
        code.contains('autoBackupIntervalMinutes'),
        isTrue,
        reason: '★★★ 少了「整体备份间隔」—— 只剩一个间隔的话，'
            '自动同步会把整包 zip 当心跳传，正是用户说的"耗流量"',
      );
      expect(
        code.contains('retainCount'),
        isTrue,
        reason: '★★ 少了保留份数设置（用户："可以配置最多保存数量"）',
      );
    });

    test('★ 立即备份 / 删除备份两个手动入口都在', () {
      expect(code.contains('立即备份'), isTrue, reason: '★ 少了手动备份按钮');
      expect(code.contains('删除云端备份'), isTrue, reason: '★ 少了删备份的确认框');
      expect(
        code.contains('不进回收站'),
        isTrue,
        reason: '★ 删云端备份前必须提示"不进回收站"（WebDAV 删除多半是永久的）',
      );
    });

    test('★★ 保留份数**可选值**里含 10（用户说"默认10个"）', () {
      expect(
        code.contains('const [3, 5, 10, 20, 50]'),
        isTrue,
        reason: '★ 保留份数选项里必须有 10 —— 用户原话「默认10个」',
      );
      // ★ 默认值在**模型**里（`SyncSettings.retainCount`），不在面板里 ——
      //   第一版把判据写在面板上，`sync_panel.dart` 里当然找不到 ⇒ 假红。
      final model = _codeOf('lib/core/models.dart');
      expect(
        model.contains('this.retainCount = 10'),
        isTrue,
        reason: '★★ `SyncSettings.retainCount` 的默认值必须是 10 '
            '（用户原话「默认10个」）—— 后端契约 §2 同此值',
      );
      expect(
        model.contains("(j['retainCount'] as num?)?.toInt() ?? 10"),
        isTrue,
        reason: '★★ 从后端 JSON 解析时的兜底也必须是 10 —— '
            '少了这个 `?? 10`，设置文件缺字段时面板会读到 0',
      );
    });

    test('★ 备份按「日期时间」命名，面板负责把文件名还原成人话', () {
      /*
       * 用户：「按照日期时间保存」。后端出 `dsh-backup-<设备>-yyyyMMdd-HHmmss.zip`
       * （字典序 = 时间序），面板把它拆成 `yyyy-MM-dd HH:mm:ss` + 设备名。
       */
      expect(
        code.contains('dsh-backup-'),
        isTrue,
        reason: '★ 少了备份文件名前缀 —— 清理与显示都靠它',
      );
      expect(
        code.contains(r'^(.*)-(\d{8})-(\d{6})$'),
        isTrue,
        reason: '★★ 少了文件名解析正则。★ 前一段必须是**贪婪**的 `(.*)`：'
            '设备名里允许含 `-`（后端会净化但不是删掉），'
            '用 `([^-]*)` 会把 `my-phone` 拆成 `my` + 一个解析失败的名字',
      );
    });

    test('★ 面板不许 import flutter/material.dart（生产代码纪律）', () {
      final raw = _rawOf(_panel);
      expect(
        RegExp(r"import\s+'package:flutter/material\.dart'").hasMatch(raw),
        isFalse,
        reason: '★ 生产代码只能用 `package:material_ui/material_ui.dart`（本仓铁律）',
      );
      expect(
        raw.contains("import 'package:material_ui/material_ui.dart'"),
        isTrue,
        reason: '★ 阳性对照：它确实是用 material_ui 写的',
      );
    });
  });
}
