// ═══════════════════════════════════════════════════════════════════════
//  二级页：Emby 内容源（task-35 ⑥）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个页面是干什么的
//
// Emby 的接入形态是**一个 JS 插件**（$rust/sourin_core/plugins/emby.js$），
// 不是一个内置 Provider。所以用户需要三件事：
// $text
//   ① 把插件装进去          → 本页「安装」区块
//   ② 填服务器地址 / 账号 / 密码 → 本页「服务器配置」区块
//   ③ 知道到底通没通         → 本页「连接自检」区块
// $
//
// # ★★★ 为什么这个页面要自带「连接自检」（这是本页存在的核心理由）
//
// 本页写于 2026-10-05（task-35），当时的实测结论是：宿主有 **三个 bug**
// 让「在设置页填 Emby 配置」这条路**当前走不通**（证据 $.probe/emby/TASK35-REPORT.md$）：
// $text
//   ① $lib/core/models.dart:354$ 读 $j['type']$，而 Rust 出口字段名是
//      $kind$（$rust/sourin_core/src/model.rs:690-713$）⇒ 所有控件
//      退化成普通文本框（密码明文可见、开关变文本框）。
//   ② $show_if$ 的嵌套键被 $js_value_to_rust$ 递归 snake_case
//      （$rust/sourin_core/src/plugins/mod.rs:167/:172$）。
//   ③ ★ 最要命的：$plugin_config_set/get$ 写读 $<dataDir>/<id>.json$，
//      而插件 $host.config$ 读 $<dataDir>/plugins/.data/<id>.json$
//      （$rust/sourin_core/src/commands_remote.rs:813/:844$ vs
//       $rust/sourin_core/src/plugins/mod.rs:2355-2368$）
//      ⇒ **用户在设置页填的 serverUrl/username/password 插件永远读不到**。
// $
//
// ★ 2026-10-06 改判（task-33 在**正式包 F91EA3BA** 上做的真机复核 + 源码复核）：
// $text
//   ① 已修 —— $lib/core/models.dart:376$ 新增 $static String normalizeKind()$，
//      $:399$ 改成 $normalizeKind((j['kind'] ?? j['type']) as String?)$，
//      $type$ 兜底、未知 kind 降级 text ⇒ 控件不再全部退化成文本框。
//   ③ 已修 —— $rust/sourin_core/src/commands_remote.rs:62$
//      $fn plugin_data_dir() = plugins_dir(data_dir).join(".data")$，
//      $:838$ 写、$:870$ 读都走它；插件侧 $load_plugins_hydrated$ 读的
//      $rust/sourin_core/src/plugins/mod.rs:2362$ $dir.join(".data")$ 是同一处。
//   ② 与本页无关 —— Dart 侧**从来没有**实现 $show_if$（全项目 0 处实现，
//      只有 2 处注释）；$js_value_to_rust$ 只对**对象键名**做 snake_case、
//      不动字符串值，而配置项的 $key$ 本身就是字符串值 ⇒ 不挡 Emby 配置读写。
// $
//
// ★ 真机端到端证据（正式包 F91EA3BA / emulator-5554 / 411.43 dp）：
// 设置页填地址+账号+密码 → 保存 → 插件读到 $cfg:serverUrl / cfg:username /
// cfg:password / cfg:transcode$ 四项 → 插件**自己**登录成功并把
// $token / userId / serverId / views$ 写回
// $/data/data/app.sourin.sourin_spike/files/plugins/.data/emby.json$
// → 首页 Emby 卡片点进去拿到 3 张真卡片（TestMovie / TestShow.S01E01 / S01E02）。
//
// ⚠️ 所以「连接自检」现在的作用变了 —— 它**不经过插件**，用 $dart:io$ 的
//    $HttpClient$ 直接打 Emby REST API，回答的是另一个问题：
// $text
//   自检通过 = 「你填的地址 / 账号 / 密码」本身是对的（独立证实）
//   自检通过 ≠ 播放一定成功（播放层是 libmpv 的事，见下）
// $
//
// ⚠️ 播放层的诚实边界（2026-10-06 真机实测，16 次点播 10 次播到结尾、6 次失败）：
// 失败**全部**落在同一份「moov 在尾部」的片源上（TestMovie：8 次 2 成）；把 moov 挪到
// 头部（FastStart：8 次 8 成）后零失败。交错 A/B 顺序 tail/fs/tail/fs/tail/fs 已排除
// 「时间顺序」这个混淆变量。失败时 mpv 报 $Failed to recognize file format.$（该文案在
// 整包里**只**存在于 $libmpv.so$，不是我们的 Dart 代码写的）；服务端每次都是 206 + 完整
// 97522 B。详见 $.probe/android_fix/M18-OWNER-REPORT.md$ 的 ⑮-补 6。
//
// # 为什么不自带「一键安装 emby.js」
//
// $emby.js$ 在仓库里，但**没有打进 Flutter asset**（$pubspec.yaml$ 无
// assets 段），Flutter 侧运行时读不到它；内置插件的 seed 清单是 Rust 里的
// const（$rust/sourin_core/src/state.rs:714/:802/:1137$，只有 demo / iptv /
// tvbox-live）⇒ emby **不会被自动 seed**。
// 所以本页只能提供「从网址安装」与「粘贴源码安装」两条**用户自己带料**的路。
// 要真正一键装，需要 Lead 把 emby.js 加进 pubspec asset 或加进 seed 清单。
//
// ═══════════════════════════════════════════════════════════════════════
//  ★ 2026-10-07 多源（Owner：「emby 设定也是可以添加多个源」）
// ═══════════════════════════════════════════════════════════════════════
//
// # 选的是哪条路：多个 provider 实例，不是「一个插件多份配置」
//
// 宿主是**零内置 Provider**（$rust/sourin_core/src/state.rs:37-41$），
// 而 Emby 的全部状态都挂在插件 id 上：
// $text
//   配置   <dataDir>/plugins/.data/<id>.json     （plugins/mod.rs:1545 store_path）
//   凭据   token / userId / views 由插件自己 host.store 写进**同一个**文件
//   源码   <dataDir>/plugins/<id>.js             （plugins/mod.rs:2884 save_plugin）
//   清单   ProviderManifest { id, name: @name }  （plugins/mod.rs:295）
// $
//  ⇒ 「换一个 @id」= 换一整套配置 + 凭据 + 一个独立的内容源。
//    反过来，「一个插件多份配置」必须改 emby.js 源码（加 profile 概念），
//    那是**改插件**，而插件是用户自己装进去的 —— 本页管不到已装的旧版。
//
// 所以多源 = 同一份源码派生多个实例：$emby$ / $emby-2$ / $emby-3$ …，
// 派生规则见 [EmbySettingsPage.rewriteInstance]（6 个锚点，缺一不可）。
// 这与本仓既有的多实例约定一致（%APPDATA% 实测：api/api-2、cj/cj-3、
// jszyapi/jszyapi-2、suoniapi/suoniapi-2 全是「同一份源码换 @id」）。
//
// # 「当前源」不需要本页发明
//
// 首页顶部源栏的选中项是**全局单选** $UiPrefs.homeSource$（键
// $dsh.homeSource$，home_page.dart:274/:438/:657$）。新实例一旦装上就
// 自动进源栏（capabilities.vod=true ⇒ 过 homeSourceList 那道过滤），
// 用户点一下即切换 ⇒ 本页只负责**增删改实例**，不碰「当前源」。
// ⚠️ 首页是保活的（shell.dart 用 Stack+Offstage 保活，切页不重建），
//    所以新装/新删的实例要**回首页下拉刷新**才会出现在源栏里 ——
//    本页的文案必须把这一步说清楚，否则用户会以为没生效。
//
// # 本页的「当前实例」是**本页的编辑焦点**，不是首页的当前源
//
// 页内选中哪个实例，只决定下面「服务器配置 / 登录 / 连接自检」作用在谁身上。
// 列表行会标注哪个实例正被**首页**用着（只读），但不提供「设为首页源」
// 按钮 —— 那个按钮会骗人：$UiPrefs.homeSource$ 只在 HomePageState 的
// 字段初始化时读一次（$home_page.dart:274$），本页改盘不会让保活着的
// 首页跟着换源（真要换，得改 home_page.dart，那是父 agent 负责的文件）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../core/sourin_api.dart';
import '../../core/ui_prefs.dart';
import '../tokens.dart';
import '../widgets/overlay_motion.dart';
import '../widgets/settings_kit.dart';
import '../widgets/settings_sub_page.dart';

/// Emby 内容源设置页（独立路由，见文件头「未接线」说明）
class EmbySettingsPage extends StatefulWidget {
  const EmbySettingsPage({super.key, this.host});

  /// 宿主能力注入点（$null$ = 走真实 FFI）
  ///
  /// ⚠️ 生产路径既不设置它也不依赖它 —— $settings_page.dart:1980$ 传的是
  ///    $const EmbySettingsPage()$。它存在只为让 widget 测试能真跑：
  ///    $SourinCore$ 一被触碰就要 $DynamicLibrary.open('sourin_core.dll')$
  ///    （$lib/core/ffi.dart:165$），在 $flutter test$ 里必然找不到。
  ///    范式同 $lib/ui/browse_page.dart:363$ 的 $_pageLoaderOverride$。
  final EmbyBackend? host;

  @override
  State<EmbySettingsPage> createState() => _EmbySettingsPageState();
}

/// 给测试用的一行入口（$null$ 的 host = 真 FFI）
///
/// ⚠️ 它只是把私有 State 里的判定函数转出来 —— 生产路径不用它，
///    存在的原因是 widget 测试**必须**能验「多源 id 的识别与排序」，
///    而那两条规则在 $private$ State 上，测试直接够不着。
@visibleForTesting
bool debugIsEmbyInstanceId(String id) =>
    _EmbySettingsPageState.isEmbyInstanceId(id);

/// 见 [debugIsEmbyInstanceId]
@visibleForTesting
int debugInstanceOrdinal(String id) =>
    _EmbySettingsPageState.instanceOrdinal(id);

/// 见 [debugIsEmbyInstanceId]
@visibleForTesting
String debugDisplayName(String baseName, String id) =>
    _EmbySettingsPageState.displayName(baseName, id);

/// 见 [debugIsEmbyInstanceId]
@visibleForTesting
int debugNextOrdinal(Iterable<String> taken) =>
    _EmbySettingsPageState.nextOrdinal(taken);

/// 见 [debugIsEmbyInstanceId]
@visibleForTesting
String? debugRewriteInstance(String source, String newId, String newName) =>
    _EmbySettingsPageState.rewriteInstance(source, newId, newName);

class _EmbySettingsPageState extends State<EmbySettingsPage> {
  /// 第一个实例的插件 id —— 与 $emby.js$ 头部 $@id emby$ 一致
  ///
  /// 多源下它只是**第一个**实例（也是派生新实例时的模板锚点），
  /// 不再是「唯一的那个」。见 [isEmbyInstanceId] / [instanceOrdinal]。
  static const String kPluginId = 'emby';

  final _serverUrl = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _installUrl = TextEditingController();
  final _installSrc = TextEditingController();
  final _newName = TextEditingController();

  bool _transcode = false;
  bool _busy = false;

  /// 一次性操作的结果文案（安装 / 保存 / 登录）
  String _status = '';
  String? _error;

  /// 全部 Emby 实例（$emby$ / $emby-2$ / …），按序号排好
  List<_EmbyInstance> _instances = const [];

  /// 本页当前编辑的实例 id（$null$ = 一个都没装）
  String? _selectedId;

  PluginEntry? _plugin;
  PluginConfig? _config;
  String? _sessionState;

  /// 宿主能力（生产 = 真 FFI）
  EmbyBackend get _host => widget.host ?? const _FfiEmbyBackend();

  /// 是不是 Emby 的某个实例 id（$emby$ / $emby-2$ / …）
  ///
  /// ⚠️ 前缀判定要带 $-$：宿主允许的 id 字符是字母/数字/$-$/$_$
  ///    （$plugins/mod.rs:2893$），只判 $startsWith('emby')$ 会把
  ///    将来某个叫 $embyfoo$ 的插件误收进来。
  static bool isEmbyInstanceId(String id) =>
      id == kPluginId || id.startsWith('$kPluginId-');

  /// 实例的排序序号（$emby$ → 1，$emby-2$ → 2；认不出的排最后）
  static int instanceOrdinal(String id) {
    if (id == kPluginId) return 1;
    if (!id.startsWith('$kPluginId-')) return 1 << 20;
    return int.tryParse(id.substring(kPluginId.length + 1)) ?? (1 << 20);
  }

  /// 自检结果（null = 还没测过）
  String? _selfCheck;
  bool _selfCheckOk = false;
  List<String> _libs = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _serverUrl.dispose();
    _username.dispose();
    _password.dispose();
    _installUrl.dispose();
    _installSrc.dispose();
    _newName.dispose();
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════════════
  //  读
  // ═══════════════════════════════════════════════════════════════════

  /// 拉**全部** Emby 实例 + 当前编辑实例的配置项 + 登录态
  ///
  /// ⚠️ 每一步各自 try/catch —— 照 $about_page.dart:62-68$ 的做法。
  ///    插件没装时 $plugin_config_get$ 会报错（正常状态，不是故障），
  ///    若共用一个 try，用户连「插件未安装」这句提示都看不到。
  ///
  /// # 多源（2026-10-07）之后这里多做了两件事
  ///
  /// $text
  ///   ① listPlugins() 不再只挑 id=='emby'，而是收全部 isEmbyInstanceId
  ///      ⇒ 「服务器列表」区块列出的是**所有**实例，不是只有第一个。
  ///   ② 选中项要**跨 $load$ 存活**：安装 / 保存 / 登录之后都会调本方法，
  ///      若每次都把选中项重置成第一个，用户刚配好的第二个实例会被
  ///      「偷偷切回第一个」，下一个操作就作用在错的源上。
  ///      所以只在前一次选中项**不存在了**（被删/首次加载）时才回退。
  /// $
  Future<void> _load() async {
    PluginEntry? entry;
    PluginConfig? cfg;
    String? state;

    final found = <_EmbyInstance>[];
    try {
      final list = await _host.listPlugins();
      for (final p in list.plugins) {
        if (!isEmbyInstanceId(p.id)) continue;
        found.add(_EmbyInstance(id: p.id, name: p.name, file: p.file));
      }
    } catch (e) {
      debugPrint('[EMBY] 插件列表读取失败: $e');
    }
    found.sort((a, b) {
      final d = instanceOrdinal(a.id).compareTo(instanceOrdinal(b.id));
      return d != 0 ? d : a.id.compareTo(b.id);
    });

    // 选中项：保持 → 否则第一个 → 否则 null
    final prev = _selectedId;
    String? sel;
    if (prev != null && found.any((i) => i.id == prev)) {
      sel = prev;
    } else if (found.isNotEmpty) {
      sel = found.first.id;
    }
    _selectedId = sel;

    if (sel != null) {
      try {
        entry = (await _host.listPlugins()).plugins.firstWhere(
          (p) => p.id == sel,
        );
      } catch (_) {
        // 上面已经拿到 id/name/file 了，entry 只用来显示版本号，取不到就算了
      }
      try {
        state = await _host.providerSessionStateWire(sel);
      } catch (e) {
        debugPrint('[EMBY] 会话状态读取失败（未登录时属正常）: $e');
      }
    }

    // 每个实例都取一份配置，只为在列表里显示它的地址
    //
    // # 为什么值得多花 N 次本地读
    //
    // 源栏和列表里显示的是 @name（$Emby$ / $Emby 2$ / …），用户自己起的名字
    // 未必记得住；**地址才是他区分「这是家里那台还是公司那台」的唯一线索**。
    // plugin_config_get 是读本地 JSON（$plugins/.data/<id>.json$），不是网络请求。
    //
    // ⚠️ 逐个 try/catch：某个实例的配置读不出来（文件损坏 / 从没配过）
    //    不该让整页变成错误态，只让那一行少显示一点。
    for (var i = 0; i < found.length; i++) {
      try {
        final c = await _host.pluginConfigGet(found[i].id);
        final u = c.values['serverUrl'];
        found[i] = found[i].copyWith(serverUrl: u is String ? u : null);
        if (found[i].id == sel) cfg = c;
      } catch (e) {
        debugPrint('[EMBY] ${found[i].id} 的配置读取失败（未配置时属正常）: $e');
      }
    }

    if (!mounted) return;
    setState(() {
      _instances = found;
      _plugin = entry;
      _config = cfg;
      _sessionState = state;
      _seedControllers(cfg);
    });
  }

  /// 当前编辑实例的显示名（拿不到就退回 id）
  String get _selectedLabel {
    final id = _selectedId;
    if (id == null) return '(没有实例)';
    for (final i in _instances) {
      if (i.id == id) return i.name;
    }
    return id;
  }

  /// 切到另一个实例：清空输入框再重新拉它的配置
  ///
  /// ⚠️ **必须清空** $serverUrl/username/password$ ——
  ///    $_seedControllers$ 只在输入框空着时才填（那是为了不冲掉用户
  ///    正在打的字）。切实例时若不清空，用户会看到**上一个源**的地址
  ///    留在框里，一点「保存配置」就把新源的配置覆盖成旧源的地址。
  ///    密码框尤其危险：它显示的是圆点，用户看不出里面是谁的密码。
  Future<void> _selectInstance(String id) async {
    if (id == _selectedId) return;
    setState(() {
      _selectedId = id;
      _serverUrl.clear();
      _username.clear();
      _password.clear();
      _selfCheck = null;
      _selfCheckOk = false;
      _libs = const [];
      _status = '';
      _error = null;
    });
    await _load();
  }

  // ═══════════════════════════════════════════════════════════════════
  //  多源：实例 id / 源码派生
  // ═══════════════════════════════════════════════════════════════════

  /// 下一个可用的实例序号（已装 1、3 → 返回 2）
  ///
  /// ⚠️ 用「已装集合里的最小空缺」而不是「最大 +1」：删掉 $emby-2$ 再新增
  ///    应当补回 2，否则用户会看到 $emby$ / $emby-3$ 这种带窟窿的列表，
  ///    而且每次删+增都让 id 一直往后涨（同名实例越攒越多）。
  static int nextOrdinal(Iterable<String> taken) {
    final used = taken.map(instanceOrdinal).toSet();
    var n = 1;
    while (used.contains(n)) {
      n++;
    }
    return n;
  }

  /// 把一个实例 id 变成可读名字：$emby$ → 原名，$emby-2$ → $原名 2$
  static String displayName(String baseName, String id) {
    final n = instanceOrdinal(id);
    return n <= 1 ? baseName : '$baseName $n';
  }

  /// 把一份 emby.js 源码改写成**另一个实例**（$emby$ → $emby-2$）
  ///
  /// # 为什么是「改字符串」而不是「让插件支持多配置」
  ///
  /// 见文件头的多源说明：宿主把配置、凭据、源码全按**插件 id** 分文件存，
  /// 所以换 id 就是换一整套状态 —— 零 Rust 改动、零内置 Provider。
  ///
  /// # 六个锚点，少一个都会出**静默**的错
  ///
  /// $text
  ///   ① @id            —— 宿主只认它（plugins/mod.rs:74 parse_meta），
  ///                       决定落盘文件名 <id>.js 与 <id>.json
  ///   ② @name          —— 首页源栏显示的就是它（mod.rs:295 manifest.name）
  ///                       两个实例同名 ⇒ 源栏上两行一模一样，用户分不清
  ///   ③ plugin.id      —— 装饰字段，但宿主将来若开始读它就会串
  ///   ④⑤⑥ 三个内容条目 id（emby-setup / emby-empty / emby-lib-）
  ///                       —— 它们会进首页分区与详情页的 key，
  ///                       两个实例共用 ⇒ key 撞车（详情页串源）
  /// $
  ///
  /// # 三个「替换 0 次」都要报错
  ///
  /// 锚点来自源码文本。用户贴进来的可能是**改过一版**的 emby.js
  /// （比如自己删了注释行），这时静默装下去会得到一个「@id 还是 emby」
  /// 的实例 —— 它会把用户已有的第一个源**覆盖掉**，而界面显示「新增成功」。
  /// 宁可失败也不覆盖（返回 null，由调用方报错）。
  static String? rewriteInstance(String source, String newId, String newName) {
    if (newId == kPluginId) return null;

    var out = source;
    // ① @id（parse_meta 只看开头 2048 字符，这个锚点必在文件头）
    const head = '@id $kPluginId';
    if (!out.contains(head)) return null;
    out = out.replaceFirst(head, '@id $newId');
    // ② @name —— 必须**连旧名字一起吃掉**，不能只替换 '@name ' 这个前缀
    //
    // ⚠️ 这里踩过一次：写成 out.replaceFirst('@name ', '@name $newName ')
    //    会把 '* @name Emby' 变成 '* @name 公司那台 Emby'（旧名还在），
    //    首页源栏就显示成「公司那台 Emby」这种半截名字。
    //    所以按宿主 parse_meta 的取值规则（值到最近的 @ / \n / "*/" 为止，
    //    plugins/mod.rs:74-104）把**整个值区间**换成新名字。
    const nameKey = '@name ';
    final nameAt = out.indexOf(nameKey);
    if (nameAt < 0) return null;
    final nameFrom = nameAt + nameKey.length;
    var nameTo = out.indexOf('\n', nameFrom);
    if (nameTo < 0) nameTo = out.length;
    final starAt = out.indexOf('*/', nameFrom);
    if (starAt >= 0 && starAt < nameTo) nameTo = starAt;
    final atAt = out.indexOf('@', nameFrom);
    if (atAt >= 0 && atAt < nameTo) nameTo = atAt;
    if (nameTo <= nameFrom) return null; // 空的 @name 也是坏源码
    out = out.replaceRange(nameFrom, nameTo, newName);
    // ③ globalThis.plugin 里的 id 字面量
    const literal = "id: '$kPluginId',";
    if (!out.contains(literal)) return null;
    out = out.replaceFirst(literal, "id: '$newId',");
    // ④⑤⑥ 内容条目 id
    final contentIds = <String>[
      "id: '$kPluginId-setup'",
      "id: '$kPluginId-empty'",
      "id: '$kPluginId-lib-'",
    ];
    for (final c in contentIds) {
      if (!out.contains(c)) return null;
      out = out.replaceFirst(c, c.replaceFirst("'$kPluginId-", "'$newId-"));
    }
    return out;
  }

  /// 把宿主返回的配置值填进输入框（**只在输入框还空着时填**）
  ///
  /// ⚠️ 不能无条件覆盖：用户可能已经改了一半，一次 $_load()$ 就把
  ///    他打的字冲掉，是「页面把我的输入吃了」这类最难查的 bug。
  void _seedControllers(PluginConfig? cfg) {
    final v = cfg?.values;
    if (v == null) return;
    final url = v['serverUrl'];
    if (_serverUrl.text.isEmpty && url is String) _serverUrl.text = url;
    final u = v['username'];
    if (_username.text.isEmpty && u is String) _username.text = u;
    final p = v['password'];
    if (_password.text.isEmpty && p is String) _password.text = p;
    final t = v['transcode'];
    if (t is bool) _transcode = t;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  写
  // ═══════════════════════════════════════════════════════════════════

  Future<void> _run(Future<void> Function() body) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await body();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _installFromUrl() => _run(() async {
    final url = _installUrl.text.trim();
    if (url.isEmpty) throw '先填插件地址';
    final r = await _host.installPlugin(url);
    setState(
      () => _status =
          '已安装 ${r.name} v${r.version}（${r.file}，${r.bytes} 字节）· @id ${r.id}',
    );
    await _load();
  });

  /// 装源码 —— **没有任何实例时装第一个，已经有了就派生成新源**
  ///
  /// # 为什么要按「有没有实例」分叉
  ///
  /// $install_plugin_source$ 是**按 @id 覆盖写** ${id}.js$（$plugins/mod.rs:2884$
  /// $save_plugin$）。同一份 emby.js 再装一次，@id 还是 $emby$ ⇒ 只是把第一个
  /// 源的文件重写一遍，用户会以为「加了第二个源」，其实列表里还是只有一个。
  /// 所以有实例时必须**先派生 @id**（见 [rewriteInstance]），装成 $emby-2$。
  ///
  /// ⚠️ 派生的名字优先用用户填的「新源名字」，留空才自动叫「Emby N」——
  ///    首页源栏显示的就是 @name，两个源都叫 Emby 时用户分不清哪个是哪个。
  Future<void> _installFromSource() => _run(() async {
    final src = _installSrc.text;
    if (src.trim().isEmpty) throw '先把 emby.js 的内容贴进来';

    if (_instances.isEmpty) {
      final r = await _host.installPluginSource(src, nameHint: 'emby.js');
      setState(
        () => _status = '已安装 ${r.name} v${r.version}（${r.file}）· 这是第一个源',
      );
      _installSrc.clear();
      await _load();
      return;
    }

    final n = nextOrdinal(_instances.map((i) => i.id));
    final newId = '$kPluginId-$n';
    final typed = _newName.text.trim();
    final newName = typed.isEmpty ? displayName('Emby', newId) : typed;
    final derived = rewriteInstance(src, newId, newName);
    if (derived == null) {
      // 宁可失败也不静默装出一个 @id 仍是 emby 的实例（会覆盖第一个源）
      throw '这份源码里找不到 emby 的 6 个锚点（@id / @name / plugin.id / '
          '三个内容条目 id），不能安全地派生成新源。'
          '请贴未改过的 rust/sourin_core/plugins/emby.js。';
    }
    final r = await _host.installPluginSource(derived, nameHint: '$newId.js');
    setState(() => _status = '已新增源 ${r.name}（${r.file}）· 回首页下拉刷新，源栏里点一下切过去');
    _installSrc.clear();
    _newName.clear();
    await _load();
    // 切到刚装好的那个源，用户可以接着填地址
    await _selectInstance(r.id);
  });

  Future<void> _reload() => _run(() async {
    final n = await _host.reloadPlugins();
    setState(() => _status = '已重新加载，共 $n 个插件');
    await _load();
  });

  /// 当前编辑实例 id —— 没有实例时**抛**而不是静默用 $kPluginId$
  ///
  /// ⚠️ 静默回退成 $emby$ 会把配置写到**别的**源上：用户明明在给「Emby 2」
  ///    填地址，保存却落到第一个源，这是最难查的一类 bug（界面还显示成功）。
  String _requireSelected() {
    final id = _selectedId;
    if (id == null) {
      throw '还没有任何 Emby 源 —— 先在上面「安装」区块装一个';
    }
    return id;
  }

  /// 保存配置项
  ///
  /// ⚠️ $transcode$ **必须传 bool**（不是字符串）——
  ///    Rust $config_value_ok$（$plugins/mod.rs:1811$）对 $switch$ 只收
  ///    $is_boolean()$，传 $'true'$ 会整批保存失败并报
  ///    $配置项「优先转码」的值类型不对$（**0 项写入**）。
  ///    $settings_page.dart$ 的插件配置弹窗因为 bug ① 把 $switch$ 当成了
  ///    文本框，保存时就会踩这一条 —— 本页不踩。
  Future<void> _save() => _run(() async {
    final id = _requireSelected();
    final n = await _host.pluginConfigSet(id, <String, dynamic>{
      'serverUrl': _serverUrl.text.trim(),
      'username': _username.text.trim(),
      'password': _password.text,
      'transcode': _transcode,
    });
    setState(() => _status = '已保存 $n 项到「$_selectedLabel」（插件下次请求时就会读到）');
    await _load();
  });

  /// 登录**当前编辑的**实例
  ///
  /// ⚠️ 用户名/密码用的是**输入框里的**值，不是已保存的配置 ——
  ///    $provider_login$ 直接调插件的 login（$commands_backup.rs:37$），
  ///    不读插件 config。所以「先保存再登录」不是必须的，但也意味着
  ///    输入框空着时这里会拿着空账号去登录（会报插件的错，不会静默成功）。
  Future<void> _login() => _run(() async {
    final id = _requireSelected();
    final r = await _host.providerLogin(
      id,
      _username.text.trim(),
      _password.text,
    );
    setState(
      () => _status =
          '「$_selectedLabel」登录成功：${r['displayName'] ?? r['display_name'] ?? ''}',
    );
    await _load();
  });

  Future<void> _logout() => _run(() async {
    final id = _requireSelected();
    await _host.providerLogout(id);
    setState(() => _status = '「$_selectedLabel」已登出');
    await _load();
  });

  /// 删掉一个实例（连源码一起，但不碰它的配置/凭据文件）
  ///
  /// # 为什么要二次确认
  ///
  /// $remove_plugin$ 删的是 $<dataDir>/plugins/<id>.js$ —— **源码没了**，
  /// 想找回来得重新贴一遍 emby.js。而设置页的删除按钮就挨着「选中」，
  /// 误触一次代价不小。
  ///
  /// ⚠️ 它**不动** $plugins/.data/<id>.json$（$commands_provider.rs:179$ 只删 .js）
  ///    ⇒ 同一个 id 再装回来，地址/账号/凭据都还在。这点要在文案里说清，
  ///    否则用户以为「删了就干净了」，会把旧凭据留在盘上。
  Future<void> _deleteInstance(_EmbyInstance inst) async {
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除源「${inst.name}」？'),
        content: Text(
          '会删掉插件文件 ${inst.file}，这个源会从首页源栏消失。\n\n'
          '它的配置与登录凭据（plugins/.data/${inst.id}.json）不会被删 —— '
          '以后用同一个 id 再装回来，地址和账号还在。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await _run(() async {
      await _host.removePlugin(inst.file);
      if (_selectedId == inst.id) _selectedId = null;
      setState(() => _status = '已删除源「${inst.name}」· 回首页下拉刷新，源栏里就没了');
      await _load();
    });
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ★ 连接自检 —— 不经过插件，本页直接打 Emby REST API
  // ═══════════════════════════════════════════════════════════════════

  /// 打 $POST /Users/AuthenticateByName$，再拉一次媒体库列表
  ///
  /// # 为什么必须是「真请求」而不是「读配置看看填没填」
  ///
  /// 「填了」和「填对了」是两件事。这个按钮是用户唯一能自己确认
  /// 「我填的地址/账号密码是对的」的地方：它**不经过插件**，所以能
  /// 把「是配置错了」和「是插件/播放层错了」这两件事分开 —— 没有它，
  /// 用户会把插件侧的失败当成自己填错了，在错误的方向上反复试。
  ///
  /// ⚠️ 请求头必须带 `X-Emby-Authorization`（实测：不带就 401，
  ///    见 $.probe/emby/TASK35-REPORT.md$ 的交叉验证节）。
  Future<void> _runSelfCheck() => _run(() async {
    final base = _normalizeBase(_serverUrl.text);
    if (base == null) {
      setState(() {
        _selfCheckOk = false;
        _selfCheck = '服务器地址没填（示例：http://192.168.1.10:8096）';
        _libs = const [];
      });
      return;
    }

    setState(() {
      _selfCheck = '正在连接 $base …';
      _selfCheckOk = false;
      _libs = const [];
    });

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final body = jsonEncode(<String, String>{
        'Username': _username.text.trim(),
        'Pw': _password.text,
      });
      final req = await client
          .postUrl(Uri.parse('$base/Users/AuthenticateByName'))
          .timeout(const Duration(seconds: 10));
      req.headers.set('Content-Type', 'application/json');
      req.headers.set('Accept', 'application/json');
      req.headers.set(
        'X-Emby-Authorization',
        'MediaBrowser Client="sourin-spike", Device="sourin-app", '
            'DeviceId="sourin-emby-selfcheck", Version="0.1.0"',
      );
      // ★ 必须显式给 Content-Length 再 add(bytes)。
      //   只 req.write(body) 时 dart:io 走 **chunked** 传输，
      //   Emby（Kestrel）读不出 body ⇒ HTTP 400
      //   "Value cannot be null. (Parameter 'name')"。
      //   同 body 的 A1/A2/A3 对照见 $.probe/emby/selfcheck_probe2.dart$。
      final payload = utf8.encode(body);
      req.contentLength = payload.length;
      req.add(payload);
      final resp = await req.close().timeout(const Duration(seconds: 10));
      final text = await resp.transform(utf8.decoder).join();

      if (resp.statusCode != 200) {
        setState(() {
          _selfCheckOk = false;
          _selfCheck = 'HTTP ${resp.statusCode}：${_brief(text)}';
        });
        return;
      }

      final j = jsonDecode(text);
      final token = (j is Map ? j['AccessToken'] : null)?.toString() ?? '';
      final u = (j is Map && j['User'] is Map)
          ? (j['User'] as Map)
          : const <String, dynamic>{};
      final user = u['Name']?.toString() ?? '';
      final uid = u['Id']?.toString() ?? '';
      if (token.isEmpty) {
        setState(() {
          _selfCheckOk = false;
          _selfCheck = '登录成功但没返回 AccessToken（返回体：${_brief(text)}）';
        });
        return;
      }

      final libs = await _fetchViews(client, base, uid, token);
      setState(() {
        _selfCheckOk = true;
        _selfCheck =
            '连接正常 · 登录用户 ${user.isEmpty ? '(未命名)' : user} · '
            '媒体库 ${libs.length} 个';
        _libs = libs;
      });
    } on SocketException catch (e) {
      setState(() {
        _selfCheckOk = false;
        _selfCheck =
            '连不上 $base：${e.message}'
            '（安卓模拟器访问本机请用 10.0.2.2，不是 127.0.0.1）';
      });
    } on TimeoutException {
      setState(() {
        _selfCheckOk = false;
        _selfCheck = '连 $base 超时（10 秒）—— 地址不通或服务器没起来';
      });
    } finally {
      client.close(force: true);
    }
  });

  /// ⚠️ 路径必须是 `/Users/<userId>/Views`，**不能**用 `/Users/Me/Views`：
  ///    Emby 4.9.3.0 会把字面量 `Me` 当 Guid 解析，直接 HTTP 500
  ///    `Unrecognized Guid format.`（实测 A/B/F 三种鉴权形态全是 500，
  ///    只有 `/Users/<uid>/Views` 是 200，见 $.probe/emby/selfcheck_probe3.dart$）。
  Future<List<String>> _fetchViews(
    HttpClient client,
    String base,
    String uid,
    String token,
  ) async {
    if (uid.isEmpty) return const [];
    final req = await client
        .getUrl(Uri.parse('$base/Users/$uid/Views?api_key=$token'))
        .timeout(const Duration(seconds: 10));
    req.headers.set('Accept', 'application/json');
    final resp = await req.close().timeout(const Duration(seconds: 10));
    final text = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) return const [];
    final j = jsonDecode(text);
    final items = (j is Map ? j['Items'] : null);
    if (items is! List) return const [];
    final out = <String>[];
    for (final it in items) {
      if (it is Map) {
        final name = it['Name']?.toString() ?? '';
        final type = it['CollectionType']?.toString() ?? '';
        out.add(type.isEmpty ? name : '$name（$type）');
      }
    }
    return out;
  }

  /// $192.168.1.10:8096$ → $http://192.168.1.10:8096$（去尾斜杠）
  ///
  /// 与插件里 $baseUrl()$（$emby.js:97$）**同一套规则** ——
  /// 用户不会每次都写 scheme，两处行为不一致会让人以为是两个 bug。
  static String? _normalizeBase(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    if (!s.contains('://')) s = 'http://$s';
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s.isEmpty ? null : s;
  }

  static String _brief(String s) {
    final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= 160 ? one : '${one.substring(0, 160)}…';
  }

  // ═══════════════════════════════════════════════════════════════════
  //  渲染
  // ═══════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final installed = _plugin != null;

    return SettingsSubPage(
      title: 'Emby',
      subtitle: '可以接多台 Emby 服务器，一台一个源',
      children: [
        SettingsBlock(
          title: '服务器列表',
          children: [
            const _Hint(
              '每一台 Emby 服务器是一个独立的源，各自保存自己的地址、'
              '账号与登录状态。点一行即可切换到那台服务器的配置。',
            ),
            const _Hint(
              '装好之后回首页下拉刷新，新源会出现在首页顶部的源栏里，'
              '在那里点一下才是「切当前看的源」。',
            ),
            if (_instances.isEmpty)
              _note(colors, '还没有任何 Emby 源 —— 用下面「安装」区块装一个')
            else
              for (final inst in _instances)
                _InstanceTile(
                  instance: inst,
                  selected: inst.id == _selectedId,
                  isHomeSource: inst.id == UiPrefs.homeSource,
                  busy: _busy,
                  onSelect: () => _selectInstance(inst.id),
                  onDelete: () => _deleteInstance(inst),
                ),
            _actions([_btn('刷新列表', () => _run(_load))]),
          ],
        ),
        SettingsBlock(
          title: '插件状态',
          children: [
            SettingsInfoRow(
              label: '插件',
              value: installed
                  ? '${_plugin!.name} v${_plugin!.version}'
                  : '未安装',
            ),
            SettingsInfoRow(
              label: '文件',
              value: installed ? _plugin!.file : '(无)',
            ),
            SettingsInfoRow(
              label: '配置项',
              value: '${_config?.fields.length ?? 0} 项',
            ),
            SettingsInfoRow(label: '登录态', value: _sessionLabel()),
            if (_status.isNotEmpty) _note(colors, _status),
            if (_error != null) _note(colors, _error!, bad: true),
            _actions([_btn('重新加载', _reload)]),
          ],
        ),
        SettingsBlock(
          title: '安装',
          children: [
            const _Hint(
              'Emby 源需要先装上才能配置。填一个插件直链，或把插件源码'
              '直接粘贴到下面的输入框，两种方式都可以。',
            ),
            if (_instances.isEmpty)
              const _Hint('现在一个源都没有 —— 下面「粘贴源码安装」会装成第一个源。')
            else
              const _Hint(
                '已经装了源 —— 再粘一次同样的源码不会变成第二个源：'
                '本页会自动把它派生成第二个、第三个源，'
                '所以同一个插件贴几次就有几个源。',
              ),
            TextField(
              controller: _installUrl,
              decoration: const InputDecoration(
                labelText: '插件地址',
                hintText: 'https://example.com/emby.js',
                isDense: true,
              ),
            ),
            const SizedBox(height: Sp.x2),
            _actions([_btn('从网址安装', _installFromUrl)]),
            const SizedBox(height: Sp.x3),
            TextField(
              controller: _installSrc,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: '或粘贴插件源码',
                hintText: '// @id emby …',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: Sp.x2),
            if (_instances.isNotEmpty) ...[
              TextField(
                controller: _newName,
                decoration: const InputDecoration(
                  labelText: '新源的名字（留空 = 自动叫 Emby N）',
                  hintText: '公司那台',
                  helperText: '首页源栏里显示的就是这个名字，两台同名会分不清',
                  isDense: true,
                ),
              ),
              const SizedBox(height: Sp.x2),
            ],
            _actions([_btn('粘贴源码安装', _installFromSource)]),
          ],
        ),
        SettingsBlock(
          title: '服务器配置',
          children: [
            _note(
              colors,
              _selectedId == null
                  ? '下面这些还没归属：先在上面装一个源'
                  : '下面这些会写进「$_selectedLabel」（$_selectedId）',
            ),
            const _Hint(
              '保存后回到首页点 Emby 卡片验证：能列出影片就说明配置已生效。',
            ),
            const _Hint(
              '每台服务器一套地址 / 账号 / 密码 —— 换一台就点上面列表里那一行，'
              '本页会清空输入框重新填它自己的配置（不会串）。',
            ),
            TextField(
              controller: _serverUrl,
              decoration: const InputDecoration(
                labelText: '服务器地址',
                hintText: 'http://192.168.1.10:8096',
                helperText: '安卓模拟器里访问本机请填 http://10.0.2.2:8096',
                isDense: true,
              ),
            ),
            const SizedBox(height: Sp.x2),
            TextField(
              controller: _username,
              decoration: const InputDecoration(
                labelText: '用户名',
                isDense: true,
              ),
            ),
            const SizedBox(height: Sp.x2),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: '密码', isDense: true),
            ),
            const SizedBox(height: Sp.x1),
            // SettingsBlock 的卡片底色画在 DecoratedBox 上，而 ListTile 的背景/墨迹
            // 画在最近的 Material 祖先上 ⇒ 必须自己包一层透明 Material，
            // 否则 flutter 断言 'ListTile background color or ink splashes may be invisible.'。
            Material(
              type: MaterialType.transparency,
              child: SwitchListTile(
                value: _transcode,
                onChanged: (v) => setState(() => _transcode = v),
                title: const Text('优先转码'),
                subtitle: const Text('打开走服务器转码 HLS；关着走直连原画'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            _actions([
              _btn('保存配置', _save),
              _btn('登录', _login, primary: true),
              _btn('登出', _logout),
            ]),
          ],
        ),
        SettingsBlock(
          title: '连接自检',
          children: [
            const _Hint(
              '不经过插件，本页直接打 Emby 的 REST API。'
              '用来确认「地址 / 账号 / 密码」本身是对的。',
            ),
            _actions([_btn('测试连接', _runSelfCheck, primary: true)]),
            if (_selfCheck != null) ...[
              const SizedBox(height: Sp.x2),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _selfCheckOk
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    size: 18,
                    color: _selfCheckOk ? colors.primary : colors.error,
                  ),
                  const SizedBox(width: Sp.x2),
                  Expanded(
                    child: SelectableText(
                      _selfCheck!,
                      style: TextStyle(
                        fontSize: FontSizes.sm,
                        color: colors.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (_libs.isNotEmpty) ...[
              const SizedBox(height: Sp.x2),
              for (final lib in _libs)
                Padding(
                  padding: const EdgeInsets.only(bottom: Sp.x1),
                  child: Text(
                    '· $lib',
                    style: TextStyle(
                      fontSize: FontSizes.sm,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ],
        ),
        const SettingsBlock(
          title: '使用提示',
          children: [
            _Hint(
              '连接成功后，Emby 内容源会出现在首页与「发现」里，'
              '可直接点开浏览影片。',
            ),
            _Hint(
              '如果列表是空的，回到本页点「测试连接」检查地址、账号与密码，'
              '确认连接正常后再重新进入内容源。',
            ),
          ],
        ),
      ],
    );
  }

  String _sessionLabel() {
    switch (_sessionState) {
      case 'active':
        return '已登录';
      case 'expiring':
        return '已登录（即将过期）';
      case 'not_required':
        return '不需要登录';
      case 'expired':
        return '登录已失效';
      case null:
        return '未知（插件未装或未取到）';
      default:
        return _sessionState!;
    }
  }

  Widget _btn(
    String label,
    Future<void> Function() onTap, {
    bool primary = false,
  }) {
    final child = Text(label);
    final handler = _busy ? null : () => unawaited(onTap());
    if (primary) {
      return FilledButton(onPressed: handler, child: child);
    }
    return OutlinedButton(onPressed: handler, child: child);
  }

  Widget _actions(List<Widget> children) => Padding(
    padding: const EdgeInsets.only(top: Sp.x2),
    child: Wrap(
      spacing: Sp.x2,
      runSpacing: Sp.x2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final c in children) c,
        if (_busy)
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
      ],
    ),
  );

  Widget _note(ColorScheme colors, String text, {bool bad = false}) => Padding(
    padding: const EdgeInsets.only(top: Sp.x2),
    child: Text(
      text,
      style: TextStyle(
        fontSize: FontSizes.sm,
        color: bad ? colors.error : colors.primary,
      ),
    ),
  );
}

/// 一行小字说明（本页私有，不进 settings_kit）
/// 一个 Emby 实例在界面上需要的最小信息
///
/// $file$ 是宿主认的**文件名**（$emby-2.js$），删除 / 读取都靠它；
/// $id$ 是插件 @id（$emby-2$），配置 / 凭据 / 启用偏好靠它。
/// ⚠️ 两者在多源下**不能互相推导**：宿主允许 @id 与文件名不一致
///    （$commands_provider.rs:172$ 读的是 file），所以两个都存着。
class _EmbyInstance {
  const _EmbyInstance({
    required this.id,
    required this.name,
    required this.file,
    this.serverUrl,
  });

  final String id;
  final String name;
  final String file;

  /// 配置里的服务器地址（没配过 = null）
  final String? serverUrl;

  _EmbyInstance copyWith({String? serverUrl}) => _EmbyInstance(
    id: id,
    name: name,
    file: file,
    serverUrl: serverUrl ?? this.serverUrl,
  );
}

// ═══════════════════════════════════════════════════════════════════════
//  宿主能力注入点（生产 = 真 FFI；测试 = 假实现）
// ═══════════════════════════════════════════════════════════════════════

/// 本页要用的全部宿主能力
///
/// # 为什么要这层抽象
///
/// $SourinApi$ 的方法全是 static 且直连 FFI，一被调用就要
/// $DynamicLibrary.open('sourin_core.dll')$（$lib/core/ffi.dart:165$）——
/// 在 $flutter test$ 里那个 DLL 不存在，任何 widget 测试都会在第一次
/// 请求上炸掉。抽出这层之后测试可以塞一个纯内存的假宿主，
/// 把「多源列表 / 新增 / 切换 / 删除」这些**页面逻辑**真正跑起来。
///
/// ⚠️ 生产路径**从不**传它（$settings_page.dart:1980$ 是
///    $const EmbySettingsPage()$）⇒ 默认 $null$ ⇒ 走 [_FfiEmbyBackend]。
///    范式同 $lib/ui/browse_page.dart:363$ 的 $_pageLoaderOverride$。
abstract class EmbyBackend {
  Future<PluginListResult> listPlugins();
  Future<PluginConfig> pluginConfigGet(String id);
  Future<int> pluginConfigSet(String id, Map<String, dynamic> values);
  Future<String?> providerSessionStateWire(String provider);
  Future<Map<String, dynamic>> providerLogin(
    String provider,
    String username,
    String password,
  );
  Future<void> providerLogout(String provider);
  Future<PluginInstallResult> installPlugin(String url);
  Future<PluginInstallResult> installPluginSource(
    String source, {
    String? nameHint,
  });
  Future<void> removePlugin(String file);
  Future<int> reloadPlugins();
}

/// 真宿主：转手调 [SourinApi]（一行一个，没有逻辑）
class _FfiEmbyBackend implements EmbyBackend {
  const _FfiEmbyBackend();

  @override
  Future<PluginListResult> listPlugins() => SourinApi.listPlugins();

  @override
  Future<PluginConfig> pluginConfigGet(String id) =>
      SourinApi.pluginConfigGet(id);

  @override
  Future<int> pluginConfigSet(String id, Map<String, dynamic> values) =>
      SourinApi.pluginConfigSet(id, values);

  @override
  Future<String?> providerSessionStateWire(String provider) =>
      SourinApi.providerSessionStateWire(provider);

  @override
  Future<Map<String, dynamic>> providerLogin(
    String provider,
    String username,
    String password,
  ) => SourinApi.providerLogin(provider, username, password);

  @override
  Future<void> providerLogout(String provider) =>
      SourinApi.providerLogout(provider);

  @override
  Future<PluginInstallResult> installPlugin(String url) =>
      SourinApi.installPlugin(url);

  @override
  Future<PluginInstallResult> installPluginSource(
    String source, {
    String? nameHint,
  }) => SourinApi.installPluginSource(source, nameHint: nameHint);

  @override
  Future<void> removePlugin(String file) => SourinApi.removePlugin(file);

  @override
  Future<int> reloadPlugins() => SourinApi.reloadPlugins();
}

/// 服务器列表里的一行：点一下 = 把下面几个区块切到它
class _InstanceTile extends StatelessWidget {
  const _InstanceTile({
    required this.instance,
    required this.selected,
    required this.isHomeSource,
    required this.busy,
    required this.onSelect,
    required this.onDelete,
  });

  final _EmbyInstance instance;
  final bool selected;

  /// 首页源栏现在选中的是不是它（**只读标注**）
  final bool isHomeSource;
  final bool busy;
  final VoidCallback onSelect;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final url = instance.serverUrl;
    final sub = StringBuffer();
    if (url != null && url.isNotEmpty) {
      sub.write(url);
    } else {
      sub.write('还没填服务器地址');
    }
    if (selected) sub.write(' · 正在编辑');
    if (isHomeSource) sub.write(' · 首页正在用');

    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x2),
      // 同「服务器配置」区块的 SwitchListTile：卡片底色画在 DecoratedBox 上，
      // ListTile 的背景/墨迹画在最近的 Material 祖先上 ⇒ 不包会断言
      // 'ListTile background color or ink splashes may be invisible.'
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          selected: selected,
          leading: Icon(
            selected
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
            size: 20,
            color: selected ? colors.primary : colors.onSurfaceVariant,
          ),
          title: Text(
            instance.name,
            style: TextStyle(
              fontSize: FontSizes.sm,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: colors.onSurface,
            ),
          ),
          subtitle: Text(
            sub.toString(),
            style: TextStyle(
              fontSize: FontSizes.sm,
              color: colors.onSurfaceVariant,
            ),
          ),
          trailing: IconButton(
            tooltip: '删除这个源',
            icon: const Icon(Icons.delete_outline, size: 20),
            onPressed: busy ? null : onDelete,
          ),
          onTap: busy ? null : onSelect,
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: FontSizes.sm,
          color: colors.onSurfaceVariant,
          height: 1.5,
        ),
      ),
    );
  }
}

/// 一个圆点开头的条目
class _Bullet extends StatelessWidget {
  const _Bullet(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('· ', style: TextStyle(color: colors.onSurfaceVariant)),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: FontSizes.sm,
                color: colors.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
