// ═══════════════════════════════════════════════════════════════════════
//  模型汇总 —— 全部命令的返回类型（2026-09-22）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么把模型集中到一个文件
//
// 原本模型散在 `api.dart`（首页链路）和 `playback.dart`（播放链路）里。
// 补齐 91 个命令时发现：
// ```text
// · Favorite / Progress / HistoryEntry / SkipMarker 这些「用户数据」
//   两条链路都要用（首页显示"继续观看"，播放页要写进度）
// · 分散定义会导致**同一个概念两个类**，字段还容易漂移
// ```
// 按 code-reuse guide 的 Pattern 4（同一段逻辑出现两次就该抽出来），
// 统一到本文件。
//
// # 命名约定
//
// ```text
// Dart 字段名     camelCase   （Dart 惯例）
// JSON 字段名     snake_case  （Rust serde 默认）
// ```
// 转换在各自的 `fromJson` 里做 —— **只在这一层做**，
// UI 拿到的永远是 camelCase。
//
// # 容错策略
//
// ```text
// 必填字段缺失/类型错 → 抛 SourinCoreException（宁可炸，不要静默空）
// 可选字段缺失        → null / 空列表（正常情况）
// ```
// 为什么必填要炸：静默的空值会把「字段名拼错」变成**看不见的空界面**，
// 开发期毫无提示。抛出则问题在开发期就暴露，错误消息里还带实际收到的键名。

import 'json_utils.dart';

// ═══════════════════════════════════════════════════════════════════════
//  通用
// ═══════════════════════════════════════════════════════════════════════

/// 分页结果
///
/// # 为什么 pageCount / total 是可空的
///
/// **很多源不返回总数**（尤其第三方接口）。这时 UI 应该
/// **不显示**「共 N 条」而不是显示「共 0 条」。
class Page<T> {
  const Page({
    required this.items,
    this.page = 1,
    this.pageCount,
    this.total,
  });

  final List<T> items;
  final int page;
  final int? pageCount;
  final int? total;

  factory Page.fromJson(
    Map<String, dynamic> j,
    T Function(Map<String, dynamic>) fromItem,
  ) =>
      Page(
        items: jlist(j['items'], fromItem),
        page: (j['page'] as num?)?.toInt() ?? 1,
        pageCount: (j['page_count'] as num?)?.toInt(),
        total: (j['total'] as num?)?.toInt(),
      );
}

/// 一个内容源
class ProviderManifest {
  const ProviderManifest({
    required this.id,
    required this.name,
    this.version = '',
    this.kind = '',
    this.description,
    this.icon,
    this.themeColor,
    this.capabilities = const Capabilities(),
    this.config = const [],
    this.working = true,
    this.brokenReason,
    this.enabled = true,
  });

  final String id;
  final String name;
  final String version;
  final String kind;
  final String? description;
  final String? icon;
  final String? themeColor;
  final Capabilities capabilities;

  /// 插件声明的配置项（设置页据此渲染表单）
  ///
  /// ⚠️ 这个字段**只有从 registry 拿才有值** ——
  /// 静态解析（`load_plugins`）拿到的永远是空数组。
  final List<ConfigField> config;

  final bool working;
  final String? brokenReason;
  final bool enabled;

  factory ProviderManifest.fromJson(Map<String, dynamic> j) => ProviderManifest(
        id: jstr(j, 'id'),
        name: jstr(j, 'name'),
        version: j['version'] as String? ?? '',
        kind: j['kind'] as String? ?? '',
        description: j['description'] as String?,
        icon: j['icon'] as String?,
        themeColor: j['theme_color'] as String?,
        capabilities: j['capabilities'] is Map
            ? Capabilities.fromJson(jmap(j['capabilities']))
            : const Capabilities(),
        config: jlist<ConfigField>(j['config'], ConfigField.fromJson),
        working: j['working'] as bool? ?? true,
        brokenReason: j['broken_reason'] as String?,
        enabled: j['enabled'] as bool? ?? true,
      );
}

/// 源的能力位（哪些功能可用）
///
/// # ★★★ 字段名必须与 Rust `Capabilities` 逐字对齐（这是一个真 bug 的修复）
///
/// 权威定义：`rust/sourin_core/src/model.rs:560-625` 的
/// `pub struct Capabilities`（与 `src-tauri/src/model.rs` 完全一致，
/// TS `src/api/types.ts` 的 `interface Capabilities` 交叉验证过）。
///
/// ## 修之前是什么样（**静默失效**，用户根本查不出来）
///
/// ```text
/// Dart 旧字段   search / live / rank / category / login / epg /
///              timeshift / platform_history
/// Rust 真实字段 vod / live / epg / search / login_required / multi_source /
///              server_side_history / favorites / timeshift / danmaku /
///              login_supported / login_hint / login_needs_username /
///              login_qr_supported
/// ```
/// 也就是 Dart 读的 4 个键 **后端从来不发送**：
///
/// | Dart 旧字段 | 后端有这个键吗 | 后果 |
/// |---|---|---|
/// | `login` | ❌ 没有（真名 `login_required`） | 永远 false |
/// | `rank` | ❌ 没有 | 永远 false |
/// | `category` | ❌ 没有 | 永远 false |
/// | `platform_history` | ❌ 没有（真名 `server_side_history`） | 永远 false |
///
/// 而 Rust 真实字段里 Dart **一个都没读**的有 10 个：
/// `vod` / `login_required` / `multi_source` / `server_side_history` /
/// `favorites` / `danmaku` / `login_supported` / `login_hint` /
/// `login_needs_username` / `login_qr_supported`。
///
/// ## 为什么这类 bug 能潜伏这么久
///
/// ```text
/// ① JSON 缺键 → `as bool? ?? false` 兜底 → **不抛异常**
/// ② 编译过、analyze 0 error、单测全绿、能跑起来
/// ③ 唯一的症状是「某个标签永远不出现」——
///    用户不会为一个"没显示的标签"报 bug（他不知道本该有）
/// ```
/// 所以修复的同时加了 `test/models_contract_test.dart`，
/// 用**逐字段往返**把它钉死（只断言"没抛异常"是抓不到这类 bug 的）。
///
/// ## ⚠️ `loginRequired` 与 `loginSupported` **不是一回事**
///
/// Rust 注释（`model.rs:583-597`）写得非常明确：
/// ```text
/// cycani    必须登录才能取流          → login_required = true
/// bilibili  游客就能看 1080P，
///           但登录后能同步关注/收藏  → login_supported = true
/// ```
/// 而**绝不能**给 B站 设 `login_required = true` ——
/// `Registry::ensure_session` 会因此**挡住游客播放**
///（`if !login_required { return Some(true) }` 那条捷径失效）。
///
/// 所以两个消费点的判据是**分开的**：
/// ```text
/// 设置页显示登录入口   → loginRequired || loginSupported
/// 后端会话校验         → 只看 loginRequired
/// ```
class Capabilities {
  const Capabilities({
    this.vod = false,
    this.live = false,
    this.epg = false,
    this.search = false,
    this.loginRequired = false,
    this.multiSource = false,
    this.serverSideHistory = false,
    this.favorites = false,
    this.timeshift = false,
    this.danmaku = false,
    this.loginSupported = false,
    this.loginHint,
    this.loginNeedsUsername = true,
    this.loginQrSupported = false,
    this.canAutoLogin = false,
  });

  /// 支持点播（有详情页 + 剧集列表）
  final bool vod;

  /// 支持直播
  final bool live;

  /// 支持节目单（EPG）
  final bool epg;

  /// 支持搜索
  final bool search;

  /// **必须**登录才能取流（如 cycani）
  final bool loginRequired;

  /// 支持平台内多播放源（如 cycani 的 `play_from`）
  final bool multiSource;

  /// 平台自带服务端观看历史
  ///
  /// ⚠️ 旧 Dart 字段叫 `platformHistory` —— 那个键后端**从不下发**，
  ///    所以「平台历史」这个标签从来没显示过。
  final bool serverSideHistory;

  /// 支持收藏
  final bool favorites;

  /// 支持时移回看
  final bool timeshift;

  /// 支持弹幕
  final bool danmaku;

  /// **可以**登录，但不是必须 —— 游客态照样能用（如 B站）
  ///
  /// ⚠️ 与 [loginRequired] 是两件事，见类文档。
  final bool loginSupported;

  /// 登录弹窗里的一段说明（告诉用户该怎么操作）
  ///
  /// 例：B站要「从浏览器复制 Cookie 粘进来」，不写清楚用户不知道做什么。
  final String? loginHint;

  /// 登录是否需要「账号」字段
  ///
  /// ⚠️ **默认 true**（不是 false）—— Rust 是
  ///    `#[serde(default = "default_true")]`。
  ///    写成 false 会让所有老插件**都不显示账号框**，登录直接坏掉。
  ///
  /// B站的 Cookie 导入不需要账号，只有密码框（用来粘 Cookie）；
  /// 设 false 时前端隐藏账号框，也**不再要求它非空**
  /// （否则登录按钮永远是禁用状态）。
  final bool loginNeedsUsername;

  /// 是否支持**扫码登录**
  ///
  /// ⚠️ 与 [loginSupported] 的关系：扫码是**登录方式之一**，不是独立能力 ——
  ///    所以设了它也必须设 `loginSupported: true`，否则设置页的登录入口
  ///    根本不出现（那个过滤条件不看本字段）。
  ///
  /// ⚠️ 默认 false：老插件没声明这一项时保持原行为（只有账号/密码表单）。
  final bool loginQrSupported;

  /// ★★ 能否**用保存的凭据自动重新登录**（2026-09-25，task-38）
  ///
  /// # 为什么需要（Owner 报的真问题）
  ///
  /// > 次元城登录失效 明明不需要验证码就可以自动登录，还提示 验证码
  ///
  /// 登录态失效时设置页原本对**所有源**都写同一句原版通用文案
  /// （`SettingsView.vue:175`）：
  /// ```text
  /// 「需重新登录（可能需要验证码，请手动完成）」
  /// ```
  /// 但对实现了 `autoLogin()` 的插件（次元城：账号密码存在
  /// `plugins/.data/<id>.json`，token 一过期就能自己重登）这句是**误导**：
  /// 用户以为必须人工介入，实际他**只要点一下播放**就会自动恢复。
  ///
  /// 权威定义：`rust/sourin_core/src/model.rs` 的 `Capabilities::can_auto_login`。
  ///
  /// ⚠️ **默认必须是 `false`**：默认 true 会让没实现 `autoLogin()` 的老插件
  ///    也被承诺「正在自动重新登录」→ 用户干等一个**永远不会发生**的重登，
  ///    比原来那句通用文案**更糟**（从"误导"变成"撒谎"）。
  ///    所以 Rust 侧是 `#[serde(default)]`，这里也必须 `?? false`。
  final bool canAutoLogin;

  /// 设置页是否显示登录入口
  ///
  /// Rust 注释：过滤条件是 `login_required || login_supported`。
  /// 用错会让 B站 这种"游客可用"的源**没有登录入口**。
  bool get showLoginEntry => loginRequired || loginSupported;

  factory Capabilities.fromJson(Map<String, dynamic> j) => Capabilities(
        vod: j['vod'] as bool? ?? false,
        live: j['live'] as bool? ?? false,
        epg: j['epg'] as bool? ?? false,
        search: j['search'] as bool? ?? false,
        loginRequired: j['login_required'] as bool? ?? false,
        multiSource: j['multi_source'] as bool? ?? false,
        serverSideHistory: j['server_side_history'] as bool? ?? false,
        favorites: j['favorites'] as bool? ?? false,
        timeshift: j['timeshift'] as bool? ?? false,
        danmaku: j['danmaku'] as bool? ?? false,
        loginSupported: j['login_supported'] as bool? ?? false,
        loginHint: j['login_hint'] as String?,
        /*
         * ⚠️ 默认 **true**，与 Rust 的 `#[serde(default = "default_true")]` 一致。
         *
         * 这里还额外兼容 `loginNeedsUsername`（camelCase）—— 因为 Rust 侧
         * 有 `alias = "loginNeedsUsername"`：**插件 JSON 里两种写法都收**，
         * 而 `list_providers` 是直接把插件声明的 JSON 透传出来的，
         * 所以 Dart 侧也要能读两种，否则插件写了 camelCase 我们就读不到。
         */
        loginNeedsUsername:
            (j['login_needs_username'] ?? j['loginNeedsUsername']) as bool? ??
                true,
        loginQrSupported: j['login_qr_supported'] as bool? ?? false,
        canAutoLogin: j['can_auto_login'] as bool? ?? false,
      );
}

/// 插件声明的一个配置项（设置页据此渲染表单控件）
///
/// ══════════════════════════════════════════════════════════════════
/// ★★★ 字段名与「控件类型词表」都必须跟着**宿主出口**走
/// ══════════════════════════════════════════════════════════════════
///
/// 宿主（rust `model.rs:690 ConfigField`）序列化出去的键名是：
/// `key` / `label` / **`kind`** / `default` / `options` / **`hint`** /
/// `placeholder` / `show_if` / `min` / `max`。
///
/// 这里曾经读 `j['type']`（永远读不到 ⇒ 全部退化成默认值）与
/// `j['description']`（同样读不到 ⇒ 说明文字全丢）。**两处都不报错**，
/// 表现是「每个配置项都渲染成输入框、说明文字空白」——
/// 因为此前 26 个插件**一个都没声明过 config**，这条链路从没被真跑过。
///
/// 同时做**词表归一**：宿主只认
/// `switch | select | text | password | number | info`
/// （`model.rs:757 CONFIG_KINDS`），而插件作者习惯写 `bool` / `string`
/// （`type` 是 serde 的 alias，收进来时两种都收）。归一放在这里，
/// 界面只认一套词。
class ConfigField {
  const ConfigField({
    required this.key,
    required this.label,
    this.type = 'text',
    this.placeholder,
    this.description,
    this.defaultValue,
    this.options = const [],
  });

  final String key;
  final String label;

  /// 控件类型（**已归一**）：`switch` / `select` / `text` / `password` /
  /// `number` / `info`。
  ///
  /// ⚠️ `info` 是纯说明文字、**不接收值** —— 宿主 `config_value_ok`
  /// 对 info 恒为 false，若界面把它当普通输入框写回去，
  /// 整次保存会以「配置项「x」的值类型不对」失败。
  final String type;

  final String? placeholder;
  final String? description;
  final dynamic defaultValue;

  /// `select` 类型的候选值
  final List<ConfigOption> options;

  /// 把插件/宿主两种写法归一到宿主词表
  static String normalizeKind(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'switch':
      case 'bool':
        return 'switch';
      case 'select':
        return 'select';
      case 'password':
        return 'password';
      case 'number':
        return 'number';
      case 'info':
        return 'info';
      default:
        // text / string / 空 / 不认识 —— 宿主对不认识的一律降级 text
        return 'text';
    }
  }

  factory ConfigField.fromJson(Map<String, dynamic> j) => ConfigField(
        key: jstr(j, 'key'),
        label: j['label'] as String? ?? jstr(j, 'key'),
        // ★ 宿主出口是 kind；type 兜底（老声明式源/插件两种写法都收）
        type: normalizeKind((j['kind'] ?? j['type']) as String?),
        placeholder: j['placeholder'] as String?,
        // ★ 宿主出口是 hint；description 兜底
        description: (j['hint'] ?? j['description']) as String?,
        defaultValue: j['default'],
        options: jlist<ConfigOption>(j['options'], ConfigOption.fromJson),
      );
}

/// `select` 配置项的一个候选
class ConfigOption {
  const ConfigOption({required this.value, required this.label});

  final String value;
  final String label;

  factory ConfigOption.fromJson(Map<String, dynamic> j) => ConfigOption(
        value: j['value']?.toString() ?? '',
        label: j['label'] as String? ?? j['value']?.toString() ?? '',
      );
}

/// 插件的配置（声明 + 当前值）
class PluginConfig {
  const PluginConfig({this.fields = const [], this.values = const {}});

  /// 插件声明的配置项（渲染表单用）
  final List<ConfigField> fields;

  /// 每项的当前值（用户设过的，或声明里的默认值）
  final Map<String, dynamic> values;

  factory PluginConfig.fromJson(Map<String, dynamic> j) => PluginConfig(
        fields: jlist<ConfigField>(j['fields'], ConfigField.fromJson),
        values: jmap(j['values']),
      );
}

// ═══════════════════════════════════════════════════════════════════════
//  内容
// ═══════════════════════════════════════════════════════════════════════

/// 一个内容条目（卡片）
class MediaItem {
  const MediaItem({
    required this.id,
    required this.title,
    this.cover,
    this.note,
    this.year,
    this.category,
    this.provider,
    this.badges = const [],
  });

  /// 带源前缀的完整 id（如 `cycani:3862`）
  final String id;

  final String title;
  final String? cover;

  /// 副标题（如「更新至 12 集」/「全 27 集」）
  ///
  /// ⚠️ 它由 **`subtitle`** 填充（后端字段名），见 [MediaItem.fromJson]。
  final String? note;

  /// 角标（如「全 27 集」「7.0 分」「CCTV-8电视剧频道」）
  ///
  /// ★ 为什么必须解析它：**有的源把集数只放在这里**。
  ///   实测（task-69，`.probe/t69_field_split.txt`）：
  ///   ```text
  ///   cctv   ：subtitle = "全 27 集"                    ← 集数在 subtitle
  ///   cycani ：subtitle = null
  ///            badges   = ["全 1 集", "7.0 分"]          ← 集数**只**在 badges
  ///   ```
  ///   ⇒ 不接 badges 就会漏掉整个 cycani 的集数。
  final List<String> badges;

  final String? year;
  final String? category;
  final String? provider;

  factory MediaItem.fromJson(Map<String, dynamic> j) => MediaItem(
        id: j['id']?.toString() ?? '',
        title: j['title'] as String? ?? '',
        cover: j['cover'] as String?,
        /*
         * ══════════════════════════════════════════════════════════════
         * ★★★ task-69：`note` 的真实来源是后端的 **`subtitle`**
         * ══════════════════════════════════════════════════════════════
         *
         * # 修的是什么（一个静默了很多轮的真 bug）
         *
         * ```text
         * 后端发的是   {"subtitle": "全 27 集", "badges": [...]}
         * 这里原来读    j['note']          ← ★ 键名不匹配 ⇒ note **恒为 null**
         * ```
         * ⇒ 后果：**6 处**读 `.note` 的界面**全部**拿不到副标题：
         * ```text
         *   home_page.dart:995              首页卡片
         *   browse_page.dart:297            浏览页卡片
         *   search_page.dart:495            搜索页卡片
         *   source_switch_dialog.dart:574   换源弹层（逐条副标题）
         *   remote_bridge.dart:1069/1182    手机遥控页转发
         * ```
         * ★ 也就是说：**UI 早就写好了"显示副标题"，缺的只是这一行映射**。
         *   它不是"新加功能"，是"修一个既有 bug"。
         *
         * # 为什么三段兜底（`subtitle` → `note` → badges 里的「N 集」）
         *
         * ```text
         * ① `subtitle`  —— 后端的标准字段（cctv 的「全 27 集」走这里）
         * ② `note`      —— 保留：万一将来某个源/导入模板直接发 note
         * ③ badges 兜底 —— ★ cycani 把集数**只**放在 badges（"全 1 集"）
         *                  不兜底就会漏掉它整个源的集数
         * ```
         *
         * ⚠️ 兜底**只挑含「集」的那条**角标 —— 否则会把「7.0 分」或
         *    「CCTV-8电视剧频道」当成副标题显示出来（那是噪音）。
         *
         * # ★ 为什么改在这里而不是给调用点加 getter
         *
         * 6 个调用点里有 2 个（`home_page` / `browse_page`）**不在本任务
         * 写入范围内** ⇒ 改不了。只有"在解析层填好"才能让 6 处同时受益。
         * ⇒ 也正因如此，**不存在第二份判据**（不需要额外 helper）。
         */
        note: j['subtitle'] as String? ??
            j['note'] as String? ??
            _episodeBadge(j['badges']),
        badges: j['badges'] is List
            ? [for (final b in j['badges'] as List) b.toString()]
            : const [],
        year: j['year']?.toString(),
        category: j['category'] as String?,
        provider: j['provider'] as String?,
      );
}

/// 从 `badges` 里挑出**含「集」**的那一条（没有则 null）
///
/// # 为什么需要它（task-69 实测）
/// ```text
/// cctv   ：集数在 subtitle
/// cycani ：集数**只**在 badges —— 实测 ["全 1 集", "7.0 分"]
/// ```
/// ⇒ 这是「来源有多少集」这条需求的**必要兜底**（Owner 原话：
///   「结果都应该展示出来来源有多少集，这样子可以很方便的知道那个源最好最快」）。
///
/// ⚠️ 只认含「集」的 —— 否则会把「7.0 分」「CCTV-8电视剧频道」
///    这类角标误当副标题（那是噪音，不是用户要的集数）。
///
/// ★ 为什么用「集」而不是解析数字：各源文案不一（「全 27 集」
///   「更新至 13 集」「全 4 集（第2–23集）」）⇒ 解析数字既脆又没必要，
///   这里只要**选出那条**，展示交给 UI。
String? _episodeBadge(Object? rawBadges) {
  if (rawBadges is! List) return null;
  for (final b in rawBadges) {
    final s = b.toString();
    if (s.contains('集')) return s;
  }
  return null;
}

/// 一个分类
class Category {
  const Category({
    required this.id,
    required this.name,
    this.ext,
    this.filters = const [],
  });

  final String id;
  final String name;

  /// 源自定义的扩展字段（不同源不一样，原样透传）
  final Map<String, dynamic>? ext;

  /// 筛选条件（如「按年份」「按地区」）
  final List<Map<String, dynamic>> filters;

  factory Category.fromJson(Map<String, dynamic> j) => Category(
        id: j['id']?.toString() ?? '',
        name: j['name'] as String? ?? '',
        ext: j['ext'] is Map ? jmap(j['ext']) : null,
        filters: jlist(j['filters'], (m) => m),
      );
}

/// 首页的一个源分组
class ProviderGroup {
  const ProviderGroup({
    required this.provider,
    required this.providerName,
    this.sections = const [],
  });

  final String provider;
  final String providerName;
  final List<Section> sections;

  factory ProviderGroup.fromJson(Map<String, dynamic> j) => ProviderGroup(
        provider: jstr(j, 'provider'),
        // ⚠️ 字段名是 camelCase（providerName）—— 与原版前端一致
        providerName: j['providerName'] as String? ??
            j['provider_name'] as String? ??
            jstr(j, 'provider'),
        sections: jlist<Section>(j['sections'], Section.fromJson),
      );
}

/// 首页的一个区块（如「热门电影」「最近更新」）
///
/// # ⚠️ `items` 常常是空的 —— 这是**设计如此**
///
/// 原版 `HomeView.vue` L205 的注释：
/// > 其它源等用户切过去时再拉
///
/// 首页只列出「有哪些分类区块」，具体内容等用户切过去时再拉。
/// 所以 **UI 不要断言 items 非空** —— 那会误判成 bug。
class Section {
  const Section({
    required this.id,
    required this.title,
    required this.source,
    this.items = const [],
  });

  final String id;
  final String title;

  /// 该区块如何取数据（UI 据此懒加载）
  ///
  /// ⚠️ **非空** —— Rust 侧是 `pub source: SectionSource`（不是 Option）。
  ///    每个区块都有明确的取数方式（哪怕只是 `static`）。
  final SectionSource source;

  final List<MediaItem> items;

  factory Section.fromJson(Map<String, dynamic> j) => Section(
        id: j['id']?.toString() ?? '',
        title: j['title'] as String? ?? '',
        source: SectionSource.fromJson(
          j['source'] is Map ? jmap(j['source']) : const {},
        ),
        items: jlist<MediaItem>(j['items'], MediaItem.fromJson),
      );
}

/// 区块的数据来源
///
/// # ★★ 这是一个「内部标签枚举」，不是普通结构体
///
/// Rust 侧定义（`model.rs` L147）：
/// ```rust
/// #[serde(tag = "type", rename_all = "snake_case")]
/// pub enum SectionSource {
///     Category { category_id: String },
///     Rank { rank_id: String },
///     Recent,
///     Custom { key: String },
///     Static,
/// }
/// ```
/// 序列化成 JSON 是**扁平**的（`type` 是标签，其余字段平铺）：
/// ```jsonc
/// {"type": "category", "category_id": "1"}
/// {"type": "rank",     "rank_id": "hot"}
/// {"type": "recent"}
/// {"type": "custom",   "key": "xxx"}
/// {"type": "static"}
/// ```
///
/// # 我第一版写错了（2026-09-22）
///
/// 我按"普通结构体"猜的：`{ kind: String, id: String? }` ——
/// **字段名和形态都不对**。探针编译报
/// `The getter 'type' isn't defined for the type 'SectionSource'`，
/// 而且我还把 `Section.source` 声明成了可空（实际非空）。
///
/// 教训：**契约要看 Rust 的结构体定义，不能按名字猜**。
///
/// # 为什么不做成 sealed class 层次
///
/// Dart 侧用不上那层类型安全 —— 调用方就是
/// 「看 type 决定走哪个命令」，用 `switch` 更直接。
/// 做成层次反而要写一堆 pattern matching。
class SectionSource {
  const SectionSource({
    required this.type,
    this.categoryId,
    this.rankId,
    this.key,
  });

  /// `category` / `rank` / `recent` / `custom` / `static`
  final String type;

  /// `type == 'category'` 时有值
  final String? categoryId;

  /// `type == 'rank'` 时有值
  final String? rankId;

  /// `type == 'custom'` 时有值（Provider 自己解释）
  final String? key;

  bool get isCategory => type == 'category';
  bool get isRank => type == 'rank';

  factory SectionSource.fromJson(Map<String, dynamic> j) => SectionSource(
        type: j['type'] as String? ?? 'static',
        categoryId: j['category_id']?.toString(),
        rankId: j['rank_id']?.toString(),
        key: j['key']?.toString(),
      );
}

// ═══════════════════════════════════════════════════════════════════════
//  播放
// ═══════════════════════════════════════════════════════════════════════

/// 一个可播放的流
///
/// # 关于 `drmProtected`（原版注释里的实测背景）
///
/// 央视直播的视频轨被 `udrm` 加密 —— 容器与 NAL 头是明文
///（ffprobe 能看到 `h264` + `1024x576`），但**负载被加密**，
/// 解码时报 `top block unavailable for requested intra mode`。
///
/// 这类流的表现是**画面花屏/绿屏但时间在走** —— 用户完全不知道
/// 发生了什么。所以必须在模型里显式声明，UI 才能如实说
/// 「该源受 DRM 保护，暂不支持」，而不是让用户对着绿屏猜。
///
/// # 关于 `audioUrl`（DASH 音视频分离）
///
/// B 站 1080P 必须走 DASH，而 DASH **必然音视频分离**。
/// 音轨也要走同一个代理（同样的 headers），
/// 否则表现是「画面正常但完全没声音，且不报错」。
class StreamCandidate {
  const StreamCandidate({
    required this.url,
    this.kind = '',
    this.quality,
    this.label,
    this.headers = const [],
    this.notWebReady = false,
    this.drmProtected = false,
    this.audioUrl,
    this.format,
  });

  /// 播放地址。
  ///
  /// ⚠️ **不一定是本地代理地址** —— 这条注释原先写的是
  /// "通常已是本地代理地址，核心层处理了防盗链，不需要再处理请求头"，
  /// **那个前提只对点播成立**（2026-09-25 任务⑰⑧ 实测推翻）：
  /// ```text
  /// 点播 resolve_stream(154, 154:57300)
  ///   url = http://127.0.0.1:56008/s/18d83422f8a0934032177997e100/   ← ✅ 本地代理
  ///   → 核心层已处理防盗链，headers 传不传都行
  ///
  /// 直播 get_live_stream(cctv, cctv1)
  ///   url = https://ldncctvcpudtxy.liveplay.myqcloud.com/...          ← ❌ 原始地址
  ///   headers = [["Referer","https://tv.cctv.com/"]]                  ← ★ 必需
  ///   → ★ 核心层【没有】给直播做代理！headers 丢了就 403
  /// ```
  /// 所以**必须**把 [headers] 传给播放器（见 [httpHeaders]）。
  /// 漏传的后果就是用户报的「cctv 看得到但点开黑屏」。
  final String url;

  /// `"hls"` 或 `"mp4"`
  final String kind;

  final String? quality;
  final String? label;

  /// 需要附加的请求头（本地代理已处理，通常为空）
  final List<(String, String)> headers;

  /// 把 [headers] 转成 media_kit 的 `Media(httpHeaders:)` 需要的 Map
  ///
  /// # 为什么需要它（任务⑰⑧：直播黑屏的根因修复）
  ///
  /// media_kit 的 `Media` 收的是 `Map<String, String>? httpHeaders`
  ///（`media_kit-1.2.6/lib/src/models/media/media_native.dart:104-113`），
  /// 而核心层给的是 `[[k, v], ...]` 的**有序列表**
  ///（见 [fromJson]，与 Rust 的 `Vec<(String,String)>` 对齐 ——
  ///  用列表是为了保住顺序，同名头可能出现多次）。
  ///
  /// 之前全项目 4 处 `Media(url)` **都没传 headers**，其中
  /// `player_page.dart` 的直播起播那条就是「黑屏」的直接原因：
  /// ```text
  /// 不带 Referer → HTTP 403（实测）
  /// 带 Referer   → HTTP 200 + 合法 m3u8（实测）
  /// ```
  ///
  /// ⚠️ 同名头只保留**第一个**：`Map` 无法表达重复键。
  ///    实测央视的 `headers` 只有一个 Referer，其它源同理，
  ///    所以这个取舍在实践中无影响 —— 如实记录，避免误以为"全保住了"。
  Map<String, String> get httpHeaders {
    if (headers.isEmpty) return const <String, String>{};
    final m = <String, String>{};
    for (final (k, v) in headers) {
      m.putIfAbsent(k, () => v);
    }
    return m;
  }

  /// 是否不适合在 WebView 里播（Flutter 用 media_kit，不受此限）
  final bool notWebReady;

  /// 是否受 DRM 保护（受保护的不能播）
  final bool drmProtected;

  /// DASH 分离的音轨地址（音视频分离时必须一起给播放器）
  final String? audioUrl;

  final String? format;

  /// 是否可以直接交给播放器
  ///
  /// DRM 流不能播；其余都可以（代理已经在核心侧处理好了）。
  bool get isPlayable => !drmProtected && url.isNotEmpty;

  /// 显示的线路名（回退到清晰度，再回退到 kind）
  String get displayName =>
      label ?? quality ?? (kind.isEmpty ? '默认' : kind.toUpperCase());

  factory StreamCandidate.fromJson(Map<String, dynamic> j) => StreamCandidate(
        url: j['url'] as String? ?? '',
        kind: j['kind'] as String? ?? '',
        quality: j['quality'] as String?,
        label: j['label'] as String?,
        headers: (j['headers'] is List)
            ? (j['headers'] as List)
                .whereType<List>()
                .where((e) => e.length >= 2)
                .map((e) => (e[0].toString(), e[1].toString()))
                .toList()
            : const [],
        notWebReady: j['not_web_ready'] as bool? ?? false,
        drmProtected: j['drm_protected'] as bool? ?? false,
        audioUrl: j['audio_url'] as String?,
        format: j['format'] as String?,
      );
}

/// 作品详情
///
/// # ★ 与 Rust `MediaDetail` 逐字对齐（`model.rs:203-224`）
///
/// ```rust
/// pub struct MediaDetail {
///     pub id: MediaId,                  // ← 序列化成 "provider:native" 字符串
///     pub title: String,
///     #[serde(skip_serializing_if = "Option::is_none")] pub cover: Option<String>,
///     #[serde(skip_serializing_if = "Option::is_none")] pub description: Option<String>,
///     #[serde(default, skip_serializing_if = "Vec::is_empty")] pub badges: Vec<String>,
///     #[serde(default)] pub kind: MediaKind,
///     #[serde(default, skip_serializing_if = "serde_json::Map::is_empty")]
///     pub meta: serde_json::Map<String, serde_json::Value>,
///     #[serde(default, skip_serializing_if = "Vec::is_empty")] pub sources: Vec<PlaySource>,
///     #[serde(default, skip_serializing_if = "Vec::is_empty")] pub episodes: Vec<Episode>,
/// }
/// ```
///
/// ## ⚠️ `badges` / `meta` 是**补上来的**，它们曾经被整个丢掉
///
/// 修之前 Dart 侧根本没有这两个字段，后果：
/// ```text
/// badges → 原版 `DetailView.vue:588` 那排角标（「连载中」「更新至 12 集」「9.2 分」）
///          在详情页头部**一个都没显示过**
/// meta   → 原版也没渲染它，但它是 badges 为空的那些源的**唯一信息来源**
/// ```
///
/// ★ 为什么**必须**读后端拼好的 `badges` 而不是自己拼：
///   cycani 插件（`plugins/cycani.js:499-518`）已经把
///   「连载中 / 更新至 12 集 / 9.2 分」拼好了，**顺序和措辞都是产品决定**。
///   前端重拼一遍就会出现两套文案（且插件改了我们不会跟着改）。
///
/// ## ⚠️ `year` / `area` 不是 Rust 字段
///
/// 它们**不在**上面的结构体里 —— 那些信息在 `meta` 中由 Provider 自行填充。
/// 保留这两个 Dart 字段是因为仍有调用方在读（探针日志、兜底角标），
/// 但它们**永远从 JSON 的顶层读不到**，所以取值时要意识到这一点。
/// 正确的来源是 [meta]。
class MediaDetail {
  const MediaDetail({
    required this.id,
    required this.title,
    this.cover,
    this.description,
    this.year,
    this.area,
    this.kind,
    this.actors = const [],
    this.directors = const [],
    this.badges = const [],
    this.meta = const {},
    this.episodes = const [],
    this.sources = const [],
  });

  final String id;
  final String title;
  final String? cover;
  final String? description;

  /// ⚠️ 不在 Rust 结构里 —— 见类文档，真正的来源是 [meta]
  final String? year;

  /// ⚠️ 不在 Rust 结构里 —— 见类文档，真正的来源是 [meta]
  final String? area;

  final String? kind;

  /// ⚠️ 不在 Rust 结构里（Rust 把它放在 `meta` 里）
  final List<String> actors;

  /// ⚠️ 不在 Rust 结构里（Rust 把它放在 `meta` 里）
  final List<String> directors;

  /// ★ 后端**已经拼好**的角标（`model.rs:212`）
  ///
  /// 原版 `DetailView.vue:587-593` 直接 `v-for` 渲染它，**不在前端重拼**。
  final List<String> badges;

  /// 扩展元数据（年份/地区/评分/演员…，各源自己填，`model.rs:217`）
  final Map<String, dynamic> meta;

  final List<Episode> episodes;
  final List<PlaySource> sources;

  factory MediaDetail.fromJson(Map<String, dynamic> j) => MediaDetail(
        /*
         * ⚠️ `id` 在 Rust 里是 `MediaId`，**手写 serde 序列化成字符串**
         *    `"provider:native"`（`model.rs:26-30` 的 `impl Serialize`）。
         *    所以这里读到的就是那个串，不是对象。
         */
        id: j['id']?.toString() ?? '',
        title: j['title'] as String? ?? '',
        cover: j['cover'] as String?,
        description: j['description'] as String?,
        year: j['year']?.toString(),
        area: j['area'] as String?,
        kind: j['kind'] as String?,
        actors: jstrList(j['actors']),
        directors: jstrList(j['directors']),
        /*
         * ★ `badges` 用**强制转字符串**而不是 `jstrList` 的过滤。
         *
         * 这是为了与撤除前的行为**逐字一致**（绕行层当时写的是
         * `b.map((e) => e.toString())`）：
         * ```text
         * 过滤  ['a', 1, true] → ['a']              ← 丢了两条
         * 强转  ['a', 1, true] → ['a', '1', 'true'] ← 一条不丢
         * ```
         * Rust 侧是 `Vec<String>`，正常情况下两者等价；
         * 但"少显示一个角标"正是我们要修的那类静默症状，
         * 所以宁可强转也不要丢。
         */
        badges: j['badges'] is List
            ? [for (final b in j['badges'] as List) b.toString()]
            : const [],
        meta: j['meta'] is Map ? jmap(j['meta']) : const {},
        episodes: jlist<Episode>(j['episodes'], Episode.fromJson),
        sources: jlist<PlaySource>(j['sources'], PlaySource.fromJson),
      );
}

/// 一个播放源 / 线路（一个作品可能有多个，**且可以任意深度嵌套**）
///
/// # ★★★ 字段名必须与 Rust `PlaySource` 逐字对齐（这是三个真 bug 的修复）
///
/// 权威定义：`rust/sourin_core/src/model.rs:177-187`
/// （与 `src-tauri/src/model.rs` 一致；原版 TS `src/api/types.ts:76-81`
/// 的 `interface PlaySource` 交叉验证过）：
/// ```rust
/// pub struct PlaySource {
///     /// 该源的唯一编码，用于拉取剧集（如 cycani 的 `cychub`）
///     pub code: String,
///     pub title: String,
///     /// 该源下的剧集数量（0 表示未知）
///     #[serde(default)] pub count: u32,
///     /// ★ 嵌套：线路里还有线路
///     #[serde(default, skip_serializing_if = "Vec::is_empty")]
///     pub nested: Vec<PlaySource>,
/// }
/// ```
///
/// ## 修之前是什么样（**三个键名同时错，且全部静默**）
///
/// | Dart 旧字段 | 后端有这个键吗 | 后果 |
/// |---|---|---|
/// | `name` | ❌ 没有（真名 `title`） | 线路名**永远空** → UI 只能退化成显示 code（`cychub`） |
/// | `episodeCount` | ❌ 没有（真名 `count`） | 集数角标**永远 0** → 原版 `v-if="s.count"` 那一段从不出现 |
/// | `nested` | ❌ **字段根本不存在** | 嵌套线路**整层看不到** → 原版 `SourcePicker.vue:74-80` 的递归渲染完全失效 |
///
/// ## 为什么这类 bug 能潜伏（与 `Capabilities` 那个是同一族）
///
/// ```text
/// ① JSON 缺键 → `as String? ?? ''` / `as num? ?? 0` 兜底 → **不抛异常**
/// ② 编译过、analyze 0 error、单测全绿、能跑起来
/// ③ 唯一症状是「少显示点东西」——
///    用户不会为一个"没出现的角标"报 bug（他不知道本该有）
/// ```
/// 所以修复的同时用 `test/model_contract_gaps_test.dart` 逐字段往返钉死，
/// 并加了真机 FFI 往返探针（只断言"没抛异常"是抓不到这类 bug 的）。
///
/// ## 兼容读取（不是"第二份契约"）
///
/// `fromJson` 同时认旧名 `name` / `episode_count` / `id`：
/// ```text
/// 插件（JS）与 Rust provider 谁先改都不会坏 ——
/// 声明式 provider 的 JSON 由插件作者手写，历史上两种写法都出现过。
/// ```
/// ⚠️ 这是**读取侧的容错**，不是又定义一份契约：
///    写入侧（`toJson`）只发 Rust 真名，且这里只有一个 `fromJson`。
class PlaySource {
  const PlaySource({
    required this.code,
    required this.title,
    this.count = 0,
    this.nested = const [],
  });

  /// 拉剧集时传给 `get_episodes` 的 code
  final String code;

  /// 展示名 —— 原版 `s.title || s.code`（见 [label]）
  final String title;

  /// 该线路下的集数（0 = **未知**，不是"有 0 集"）
  ///
  /// ⚠️ 0 时 UI **不该显示角标** —— 原版是 `v-if="s.count"`，
  ///    0 与 undefined 在 Vue 里同样为假。
  final int count;

  /// ★ 嵌套子线路（原版 `SourcePicker.vue:74-80` 递归渲染的就是它）
  final List<PlaySource> nested;

  /// 有子线路
  bool get hasNested => nested.isNotEmpty;

  /// 展示名 —— **空则退回 code**（原版 `s.title || s.code`）
  ///
  /// 这里是**产品行为**，不是随便兜底：标题为空时显示空壳按钮，
  /// 用户会以为界面坏了。所以必须退回 code。
  String get label => title.isEmpty ? code : title;

  /// 本层 + 所有后代展平
  ///
  /// # 为什么需要（这不是原版的逻辑，是**我们的架构差异**）
  ///
  /// 原版点嵌套里的一项时，`pickSource(s)` 直接把 `s.code` 交给后端
  /// （原版 `DetailView.vue:247-254`），后端能按任意 code 找剧集。
  ///
  /// 而我们的 Rust 端**只有 `get_episodes(provider, id, source_code)` 一个入口**
  /// （`rust/sourin_core/src/playback.rs:89-103`），没有"按路径取剧集"的概念。
  /// 所以只能把用户点的那一项（无论在哪一层）当成一个平铺的 code 用。
  ///
  /// ⚠️ 展平只用于**校验"这个 code 是不是本作品声明的线路"**与
  ///    「记住的偏好能不能在子树里命中」，**不用于渲染** ——
  ///    渲染仍然分层（见 `DetailSourcePicker`）。
  List<PlaySource> get flattened => [
        this,
        for (final n in nested) ...n.flattened,
      ];

  factory PlaySource.fromJson(Map<String, dynamic> j) => PlaySource(
        code: (j['code'] ?? j['id'] ?? '').toString(),
        title: (j['title'] ?? j['name'] ?? '').toString(),
        count: ((j['count'] ?? j['episode_count']) as num?)?.toInt() ?? 0,
        /*
         * `nested` 缺失是**正常情况**（Rust 有 skip_serializing_if = is_empty）。
         * 非数组则当空 —— 详情页不该因为一个坏字段整页白屏。
         */
        nested: j['nested'] is List
            ? jlist<PlaySource>(j['nested'], PlaySource.fromJson)
            : const [],
      );

  // ── 旧字段名的只读转发（过渡期兼容，**不是第二份契约**）──
  //
  // 为什么还留着：调用点分布在多个代理负责的文件里，
  // 一次性全改会让共享编译单元长期处于红的状态。
  // 它们只是 getter 转发，**没有独立的存储**，所以不可能漂移。

  /// ⚠️ 已废弃 —— 真名是 [title]（后端从不下发 `name`）
  @Deprecated('后端真名是 title（model.rs:180），请用 title')
  String get name => title;

  /// ⚠️ 已废弃 —— 真名是 [count]（后端从不下发 `episode_count`）
  @Deprecated('后端真名是 count（model.rs:183），请用 count')
  int get episodeCount => count;
}

/// 一集
class Episode {
  const Episode({
    required this.id,
    required this.title,
    this.url,
    this.index = 0,
  });

  final String id;
  final String title;
  final String? url;
  final int index;

  factory Episode.fromJson(Map<String, dynamic> j) => Episode(
        id: j['id']?.toString() ?? '',
        title: j['title'] as String? ?? '',
        url: j['url'] as String?,
        index: (j['index'] as num?)?.toInt() ?? 0,
      );
}

/// 播放请求参数（`resolve_stream` 的可选入参）
class PlayRequest {
  const PlayRequest({
    this.sourceCode,
    this.episodeId,
    this.quality,
    this.extra,
  });

  final String? sourceCode;
  final String? episodeId;
  final String? quality;
  final Map<String, dynamic>? extra;

  Map<String, dynamic> toJson() => {
        if (sourceCode != null) 'source_code': sourceCode,
        if (episodeId != null) 'episode_id': episodeId,
        if (quality != null) 'quality': quality,
        if (extra != null) 'extra': extra,
      };
}

// ═══════════════════════════════════════════════════════════════════════
//  搜索
// ═══════════════════════════════════════════════════════════════════════

/// 跨源搜索结果
class SearchAllResult {
  const SearchAllResult({this.results = const [], this.skipped = const []});

  /// 命中的源：(provider_id, provider_name, 结果页)
  final List<(String, String, Page<MediaItem>)> results;

  /// ★ 被跳过的源及原因 —— UI 应**明确告知用户**，而非静默失败
  final List<(String, String)> skipped;

  factory SearchAllResult.fromJson(Map<String, dynamic> j) {
    final res = <(String, String, Page<MediaItem>)>[];
    for (final e in (j['results'] as List? ?? const [])) {
      if (e is List && e.length >= 3 && e[2] is Map) {
        res.add((
          e[0].toString(),
          e[1].toString(),
          Page.fromJson(jmap(e[2]), MediaItem.fromJson),
        ));
      }
    }
    final skip = <(String, String)>[];
    for (final e in (j['skipped'] as List? ?? const [])) {
      if (e is List && e.length >= 2) {
        skip.add((e[0].toString(), e[1].toString()));
      }
    }
    return SearchAllResult(results: res, skipped: skip);
  }
}

/// 流式搜索事件的类型
enum SearchEventKind {
  /// 某个源搜到了内容
  hit,

  /// 某个源失败 / 无结果 / 已失效
  miss,

  /// 全部完成（流结束信号）
  done,

  /// 出错（流结束信号）
  error,
}

/// 流式搜索的一个事件
class SearchStreamEvent {
  const SearchStreamEvent({
    required this.kind,
    this.provider = '',
    this.providerName = '',
    this.items = const [],
    this.page = 1,
    this.pageCount,
    this.total,
    this.reason,
    this.error,
  });

  final SearchEventKind kind;
  final String provider;
  final String providerName;
  final List<MediaItem> items;
  final int page;
  final int? pageCount;
  final int? total;

  /// `miss` 时的失败原因
  final String? reason;

  /// `error` 时的错误消息
  final String? error;

  factory SearchStreamEvent.fromJson(Map<String, dynamic> j) {
    final kindStr = j['kind'] as String? ?? '';
    final kind = switch (kindStr) {
      'hit' => SearchEventKind.hit,
      'miss' => SearchEventKind.miss,
      'done' => SearchEventKind.done,
      _ => SearchEventKind.error,
    };
    return SearchStreamEvent(
      kind: kind,
      provider: j['provider'] as String? ?? '',
      providerName: j['provider_name'] as String? ?? '',
      items: jlist<MediaItem>(j['items'], MediaItem.fromJson),
      page: (j['page'] as num?)?.toInt() ?? 1,
      pageCount: (j['page_count'] as num?)?.toInt(),
      total: (j['total'] as num?)?.toInt(),
      reason: j['reason'] as String?,
      error: j['error'] as String?,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  直播
// ═══════════════════════════════════════════════════════════════════════

/// 一个源的直播频道分组
class LiveGroup {
  const LiveGroup({
    required this.provider,
    required this.providerName,
    this.channels = const [],
  });

  final String provider;
  final String providerName;
  final List<LiveChannel> channels;

  factory LiveGroup.fromJson(Map<String, dynamic> j) => LiveGroup(
        provider: jstr(j, 'provider'),
        // ⚠️ camelCase（原版前端契约）
        providerName: j['providerName'] as String? ??
            j['provider_name'] as String? ??
            jstr(j, 'provider'),
        channels: jlist<LiveChannel>(j['channels'], LiveChannel.fromJson),
      );
}

/// 一个直播频道
class LiveChannel {
  const LiveChannel({
    required this.id,
    required this.name,
    this.logo,
    this.group,
    this.nowPlaying,
  });

  final String id;
  final String name;
  final String? logo;

  /// 频道分组（如「央视」「卫视」）—— 列表按它分栏
  final String? group;

  /// 当前节目名（若源已知）
  ///
  /// ⚠️ 这是**源自己报的**，不一定有；真正的节目单要调 `get_epg`。
  final String? nowPlaying;

  factory LiveChannel.fromJson(Map<String, dynamic> j) => LiveChannel(
        id: j['id']?.toString() ?? '',
        name: j['name'] as String? ?? '',
        logo: j['logo'] as String?,
        group: j['group'] as String?,
        nowPlaying: j['now_playing'] as String?,
      );
}

/// 一条节目单（EPG）
///
/// # ★ 时间字段是 **Unix 秒（整数）**，不是字符串
///
/// 我第一版把它们写成了 `String?` —— 那会让所有时间比较失效：
/// ```dart
/// now >= e.start        // 字符串比较，结果毫无意义
/// ```
/// 表现是「当前节目」高亮**永远不对**（要么全亮要么全不亮）。
/// 契约要看 Rust 结构体：`pub start: i64`。
class EpgEntry {
  const EpgEntry({
    required this.title,
    required this.start,
    required this.end,
    this.showTime,
    this.duration = 0,
    this.replayable = false,
  });

  final String title;

  /// 开始时间（Unix 秒）
  final int start;

  /// 结束时间（Unix 秒）
  final int end;

  /// 源自己给的显示时间串（如 "20:00"）—— 没有就自己格式化
  final String? showTime;

  /// 时长（秒）
  final int duration;

  /// 是否可回看
  ///
  /// ⚠️ 为 false 时**不能点**（除非是正在播的那条）——
  ///    原版注释说明了原因：源不提供回看流，点了只会报错。
  final bool replayable;

  /// 是否正在播出
  bool isNow(int nowSec) => nowSec >= start && nowSec < end;

  /// 播出进度（0~100，仅当正在播出时有意义）
  int progressAt(int nowSec) {
    if (!isNow(nowSec)) return 0;
    final total = end - start;
    if (total <= 0) return 0;
    final pct = ((nowSec - start) * 100) ~/ total;
    return pct > 100 ? 100 : pct;
  }

  factory EpgEntry.fromJson(Map<String, dynamic> j) => EpgEntry(
        title: j['title'] as String? ?? '',
        start: (j['start'] as num?)?.toInt() ?? 0,
        end: (j['end'] as num?)?.toInt() ?? 0,
        showTime: j['show_time'] as String?,
        duration: (j['duration'] as num?)?.toInt() ?? 0,
        replayable: j['replayable'] as bool? ?? false,
      );
}

// ═══════════════════════════════════════════════════════════════════════
//  用户数据：收藏 / 追更 / 进度 / 历史 / 跳过点
// ═══════════════════════════════════════════════════════════════════════

/// 收藏 / 追更记录
///
/// # ★★ `favorited` 与 `following` 是**独立**的两个状态
///
/// Owner 明确纠正过两次：
/// > 追更并不代表就要收藏，这是独立的状态
///
/// 所以四种组合都合法：
/// ```text
/// favorited=true  following=false   只收藏
/// favorited=false following=true    只追更   ← 修复前做不到
/// favorited=true  following=true    既收藏又追更
/// favorited=false following=false   deleted=true（墓碑）
/// ```
///
/// # 列表过滤用 `favorited` 而不是 `deleted`
///
/// ```text
/// deleted=0      "行还活着"（可能只是追更、没收藏）
/// favorited=1    ★ "在收藏列表里"
/// ```
/// 只追更不收藏的条目是 `deleted=0` 但 `favorited=0` ——
/// 用 `deleted=0` 过滤会把它**错误地显示在收藏列表里**。
class Favorite {
  const Favorite({
    required this.key,
    required this.provider,
    required this.nativeId,
    required this.title,
    this.cover,
    this.groupName,
    this.kind = 'series',
    this.favorited = false,
    this.following = false,
    this.lastEpisodeCount = 0,
    this.lastEpisodeTitle,
    this.unreadCount = 0,
    this.lastCheckedAt = 0,
    this.lastUpdateAt = 0,
    this.note,
    this.createdAt = 0,
    this.updatedAt = 0,
    this.deleted = false,
  });

  /// `{provider}:{native_id}` —— 全项目统一的主键格式
  final String key;

  final String provider;
  final String nativeId;
  final String title;
  final String? cover;
  final String? groupName;
  final String kind;

  /// 是否在收藏列表里
  final bool favorited;

  /// 是否在追更列表里
  final bool following;

  /// 开启追更时的**基准集数**（判「更新了」的依据）
  final int lastEpisodeCount;

  final String? lastEpisodeTitle;

  /// 未读更新数（底栏徽章）
  final int unreadCount;

  final int lastCheckedAt;
  final int lastUpdateAt;
  final String? note;
  final int createdAt;
  final int updatedAt;

  /// 墓碑标记（`remove_favorite` 写的是这个，不是真删）
  final bool deleted;

  factory Favorite.fromJson(Map<String, dynamic> j) => Favorite(
        key: jstr(j, 'key'),
        provider: j['provider'] as String? ?? '',
        nativeId: j['native_id'] as String? ?? '',
        title: j['title'] as String? ?? '',
        cover: j['cover'] as String?,
        groupName: j['group_name'] as String?,
        kind: j['kind'] as String? ?? 'series',
        favorited: j['favorited'] as bool? ?? false,
        following: j['following'] as bool? ?? false,
        lastEpisodeCount: (j['last_episode_count'] as num?)?.toInt() ?? 0,
        lastEpisodeTitle: j['last_episode_title'] as String?,
        unreadCount: (j['unread_count'] as num?)?.toInt() ?? 0,
        lastCheckedAt: (j['last_checked_at'] as num?)?.toInt() ?? 0,
        lastUpdateAt: (j['last_update_at'] as num?)?.toInt() ?? 0,
        note: j['note'] as String?,
        createdAt: (j['created_at'] as num?)?.toInt() ?? 0,
        updatedAt: (j['updated_at'] as num?)?.toInt() ?? 0,
        deleted: j['deleted'] as bool? ?? false,
      );
}

/// 播放进度
class Progress {
  const Progress({
    required this.key,
    required this.provider,
    required this.nativeId,
    required this.title,
    this.cover,
    this.episodeId,
    this.episodeTitle,
    this.position = 0,
    this.duration = 0,
    this.finished = false,
    this.updatedAt = 0,
  });

  final String key;
  final String provider;
  final String nativeId;
  final String title;
  final String? cover;
  final String? episodeId;
  final String? episodeTitle;

  /// 播放位置（秒）
  final int position;

  /// 总时长（秒）
  final int duration;

  /// 是否已看完（>95% 自动标记）
  final bool finished;

  final int updatedAt;

  /// 观看百分比（0~100）
  int get percent =>
      duration > 0 ? ((position * 100) ~/ duration).clamp(0, 100) : 0;

  factory Progress.fromJson(Map<String, dynamic> j) => Progress(
        key: jstr(j, 'key'),
        provider: j['provider'] as String? ?? '',
        nativeId: j['native_id'] as String? ?? '',
        title: j['title'] as String? ?? '',
        cover: j['cover'] as String?,
        episodeId: j['episode_id'] as String?,
        episodeTitle: j['episode_title'] as String?,
        position: (j['position'] as num?)?.toInt() ?? 0,
        duration: (j['duration'] as num?)?.toInt() ?? 0,
        finished: j['finished'] as bool? ?? false,
        updatedAt: (j['updated_at'] as num?)?.toInt() ?? 0,
      );
}

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 追更徽标算法（task-40）—— 全项目**唯一**实现
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（逐字）
//
// > 底部的菜单栏，追更默认就显示  3  徽标，这是错误的
// > 首页的追更  底部的追更 追更页面的追更   这几个都应该按照这个追更这个剧
// > 还有多少集没看来显示这个徽标，比如 12集，只看了一集 就显示11，
// > 以此类推，当往后看到12集则计数器为0，纠正一下这里的逻辑
//
// # 语义：**还需多少集没看 = 当前总集数 − 已看到第几集**
//
// ```text
// 全 12 集，看到第 1 集  ⇒ 11
// 全 12 集，看到第 12 集 ⇒ 0   ⇒ ★ 徽标**消失**（不是显示 "0"）
// ```
//
// ⚠️ 这与旧语义**完全不同**：
// ```text
// 旧：unread_count = 巡检发现新集时**累加**（follow.rs:112）
//     ⇒ 是"自上次检查后更新了几集"，而且只在**巡检**时变
//     ⇒ 与用户要的"还剩几集没看"不是一回事
// ```
//
// # ★ 为什么抽成一个函数（而不是三处各写一遍）
//
// 用户明确点了**三个**界面：
// ```text
// · 底部菜单栏徽标      shell.dart
// · 首页「我的」追更 tab  my_shelf.dart
// · 追更页              follow_page.dart
// ```
// 写三遍必然漂 —— 本项目已踩过"两处同构必须一起改"的坑
// （见 `test/shelf_card_opens_detail_test.dart` 文件头）。
//
// # ★★ 数据来源与**已知偏差**（实测得出，必须如实记录）
//
// 需要两个数，来源都查实了：
// ```text
// ① 总集数 = Favorite.lastEpisodeCount
//    · store.rs:869 schema `last_episode_count`
//    · follow.rs:109  每轮巡检**更新成 new_count** ⇒ 所以它是「当前」集数，
//      下季更新（12→13）会自动反映 ⇒ 满足"要用当前总集数"
//    · commands_write.rs:450 新开追更时也记基准
// ② 已看到第几集 = Progress.episodeId 在**详情页集列表**里的**下标**
//    · ⚠️ episodeId **不能**直接当序号用：实测用户真实数据里它是
//      '51699'（内部 id）、'BV1o2eM6kEDT|41961327629'（B 站复合）、
//      甚至一个完整 URL ⇒ 数字 id 与集号**毫无关系**
//    · 所以必须拿真正的集列表去查下标
// ```
//
// ## ⚠️ 已知偏差（**必须知道**，否则会误判）
//
// ```text
// 我们手上只有 `continueWatching`（store.rs:904）返回的列表，
// 它带业务过滤：`WHERE finished=0 AND position > 5`
// ⇒ 两种情况下这部剧**不在列表里**：
//    a. 已看完（finished=1）
//    b. 刚点开 5 秒内（position <= 5）
// ⇒ 此时 `watched` 传 null ⇒ 本函数返回 0 ⇒ **徽标不显示**。
//
// ★ 为什么这个偏差可以接受（而不是放着不管）：
//    · (a) 已看完 ⇒ 真实值**本来**就是 0 左右 ⇒ 结果正确
//    · (b) 刚点开 5 秒 ⇒ 用户刚开始看这一集 ⇒ 徽标应从"还剩 N"变
//      "还剩 N-1"，暂时显示 0 是**偏小**而非偏大 ⇒ 不会误导成
//      "还有一大堆没看" ⇒ 属于可接受
// ★ 若将来要精确：用 `SourinApi.listAllProgress()`（Rust 侧已有
//   `list_all_progress`，**无过滤**）取全量再按 key 查 —— 那是
//   "更准但更重"的取舍，需要时再换。
//
// # 边缘情况（逐条定义）
//
// ```text
// · total <= 0（源没有集数信息，如电影/B 站单视频）
//     ⇒ 返回 0（不显示徽标）—— 没有集数就谈不上"还剩几集"
// · watched == null（没看过，或上面那条偏差）
//     ⇒ 返回 0（不显示）—— 而不是返回 total
//     ★ 理由：用户刚追更一部 100 集的剧，立刻显示"100"是**噪音**，
//       而且原版对未看过的条目也不打未读角标。
//       用户说的"12集只看了一集就显示11"是**已经开看**的场景。
// · 全部看完（watched == total）⇒ 0 ⇒ 徽标消失 ✓（用户明确要求）
// · 下季更新（total 12→13, watched=12）⇒ 13-12 = 1 ✓（用当前集数）
// · watched > total（数据不一致/集列表变短）⇒ clamp 到 >= 0，不显示负数
// · 集列表里找不到该 episodeId（换了源/集被删）
//     ⇒ watched = 0 ⇒ 返回 0（不显示）—— 宁可少显示也不要显示错的
// ```
/// 从「第NN集」这类标题里解析集号（1-based）；解析不出返回 null
///
/// # 为什么需要这条兜底（实测得出）
///
/// `Progress.episodeId` **不是**集号 —— 用户真实数据里它是：
/// ```text
/// '51699'                       内部数字 id，与集号无关
/// 'BV1o2eM6kEDT|41961327629'    B 站复合 id
/// 'https://vod1.../index.m3u8'  一个完整 URL
/// ```
/// 而 `episodeTitle` 对中文源是**稳定**的（实测）：
/// ```text
/// '第01集'  '第27集'  '正片'  null
/// ```
/// ⇒ 所以「拿集列表查下标」优先，查不到再用标题解析兜底。
///
/// ⚠️ 只认 `第<N>集` / `第 <N> 集` 这种最常见形态，**不做**过度猜测：
///    猜错会把徽标显示成错的数字，比不显示更糟。
int? episodeNumberFromTitle(String? title) {
  if (title == null || title.isEmpty) return null;
  // 全角数字也认（'第０１集'）
  final normalized = title.replaceAllMapped(
    RegExp(r'[０-９]'),
    (m) => String.fromCharCode(m.group(0)!.codeUnitAt(0) - 0xFEE0),
  );
  final m = RegExp(r'第\s*(\d+)\s*[集话話]').firstMatch(normalized);
  if (m == null) return null;
  final n = int.tryParse(m.group(1)!);
  if (n == null || n <= 0) return null;
  return n;
}

/// ★★★ 追更徽标算法（task-40）—— 全项目**唯一**实现
///
/// 语义：**还需多少集没看 = 当前总集数 − 已看到第几集**
///
/// 详见文件里 `followRemaining` 上方那段总说明（数据来源 / 已知偏差 /
/// 边缘情况）。这里只列参数。
///
/// [totalEpisodes] 当前总集数（`Favorite.lastEpisodeCount`，巡检会更新）
/// [watchedEpisodeId] 已看到哪一集的内部 id（`Progress.episodeId`）
/// [watchedEpisodeTitle] 已看到哪一集的标题（解析「第NN集」用，兜底）
/// [episodeIds] 该作品的集列表 id（有就优先用它查下标；没有传 null）
int followRemaining({
  required int totalEpisodes,
  required String? watchedEpisodeId,
  String? watchedEpisodeTitle,
  List<String>? episodeIds,
}) {
  // ── ① 没有集数信息 ⇒ 谈不上"还剩几集" ──
  if (totalEpisodes <= 0) return 0;

  // ── ② 已看到第几集（1-based）；两条路都走不通 ⇒ 不显示 ──
  int? watched;
  if (episodeIds != null &&
      watchedEpisodeId != null &&
      watchedEpisodeId.isNotEmpty) {
    final i = episodeIds.indexOf(watchedEpisodeId);
    if (i >= 0) watched = i + 1; // 下标 0-based → 集号 1-based
  }
  watched ??= episodeNumberFromTitle(watchedEpisodeTitle);

  // 没看过 / 推不出集号 ⇒ 返回 0（不显示）
  //
  // ★ 为什么不返回 total：用户刚追更一部 100 集的剧立刻显示"100"
  //   是噪音；用户说的"12集只看了一集就显示11"是**已开看**的场景。
  if (watched == null) return 0;

  // ── ③ 还剩几集（clamp：数据不一致时不出负数）──
  final remaining = totalEpisodes - watched;
  return remaining < 0 ? 0 : remaining;
}

/// 批量算「每部追更作品还剩几集没看」—— 三个界面共用
///
/// # 为什么要有这个批量版
///
/// 三个界面（底部徽标 / 首页「我的」/ 追更页）都要**每部**算一次：
/// ```text
/// · 底部 = 所有追更的**总和**
/// · 首页「我的」= 每张卡片自己的数
/// · 追更页     = 每张卡片自己的数
/// ```
/// 所以给一个 map（key → 剩余集数），三处各取所需 ——
/// **避免**三处各自写一遍"遍历 + 查进度"的循环（写三遍必然漂）。
///
/// [allProgress] 必须传**全量**进度（`SourinApi.listAllProgress()`），
/// 不能用 `continueWatching()` —— 后者带业务过滤
/// （`WHERE finished=0 AND position > 5`，store.rs:909），
/// 会把"已看完"的行滤掉 ⇒ 刚看完的剧徽标不消失。
Map<String, int> followRemainingByKey({
  required List<Favorite> following,
  required List<Progress> allProgress,
}) {
  final byKey = <String, Progress>{};
  for (final p in allProgress) {
    byKey[p.key] = p;
  }
  final out = <String, int>{};
  for (final f in following) {
    final p = byKey[f.key];
    out[f.key] = followRemaining(
      totalEpisodes: f.lastEpisodeCount,
      watchedEpisodeId: p?.episodeId,
      watchedEpisodeTitle: p?.episodeTitle,
    );
  }
  return out;
}

/// 一条观看历史
class HistoryEntry {
  const HistoryEntry({
    required this.key,
    required this.provider,
    required this.nativeId,
    required this.title,
    this.cover,
    this.episodeTitle,
    this.position = 0,
    this.duration = 0,
    this.watchedAt = 0,
  });

  final String key;
  final String provider;
  final String nativeId;
  final String title;
  final String? cover;
  final String? episodeTitle;
  final int position;
  final int duration;
  final int watchedAt;

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
        key: jstr(j, 'key'),
        provider: j['provider'] as String? ?? '',
        nativeId: j['native_id'] as String? ?? '',
        title: j['title'] as String? ?? '',
        cover: j['cover'] as String?,
        episodeTitle: j['episode_title'] as String?,
        position: (j['position'] as num?)?.toInt() ?? 0,
        duration: (j['duration'] as num?)?.toInt() ?? 0,
        watchedAt: (j['watched_at'] as num?)?.toInt() ?? 0,
      );
}

/// 片头/片尾跳过点
///
/// # 区间校验（后端会挡，不只是前端）
///
/// ```text
/// ① 每个区间内部：start < end
/// ② 片头整体在片尾之前：introEnd <= outroStart
/// ```
/// 原版注释记录的真实事故：前端会挡，但**遥控端可能直接发命令**，
/// 结果把整个视频（1420 秒）设成了片头。
class SkipMarker {
  const SkipMarker({
    required this.key,
    required this.provider,
    required this.nativeId,
    this.title = '',
    this.introStart,
    this.introEnd,
    this.outroStart,
    this.outroEnd,
    this.autoSkip,
    this.updatedAt = 0,
  });

  final String key;
  final String provider;
  final String nativeId;
  final String title;
  final int? introStart;
  final int? introEnd;
  final int? outroStart;
  final int? outroEnd;

  /// 是否自动跳过（而不是只显示按钮）
  final bool? autoSkip;

  final int updatedAt;

  bool get hasIntro => introEnd != null;
  bool get hasOutro => outroStart != null;

  factory SkipMarker.fromJson(Map<String, dynamic> j) => SkipMarker(
        key: jstr(j, 'key'),
        provider: j['provider'] as String? ?? '',
        nativeId: j['native_id'] as String? ?? '',
        title: j['title'] as String? ?? '',
        introStart: (j['intro_start'] as num?)?.toInt(),
        introEnd: (j['intro_end'] as num?)?.toInt(),
        outroStart: (j['outro_start'] as num?)?.toInt(),
        outroEnd: (j['outro_end'] as num?)?.toInt(),
        autoSkip: j['auto_skip'] as bool?,
        updatedAt: (j['updated_at'] as num?)?.toInt() ?? 0,
      );
}

/// 追更检查发现的一条更新
///
/// # ★★★ 字段名必须与 Rust `UpdateInfo` 逐字对齐（这是"数值显示错"的真 bug）
///
/// 权威定义：`rust/sourin_core/src/store.rs:370-387`
/// （原版 TS `src/api/types.ts:747` 的 `interface UpdateInfo` 交叉验证过）：
/// ```rust
/// pub struct UpdateInfo {
///     pub key: String,
///     pub title: String,
///     #[serde(skip_serializing_if = "Option::is_none")] pub cover: Option<String>,
///     pub provider: String,
///     /// 之前记录的集数
///     pub old_count: u32,
///     /// 现在检测到的集数
///     pub new_count: u32,
///     /// ★ 新增集数
///     pub added: u32,
///     /// 最新一集标题
///     #[serde(skip_serializing_if = "Option::is_none")]
///     pub latest_title: Option<String>,
/// }
/// ```
///
/// ## 修之前是什么样（**两个字段名同时错，症状却像"数据不对"**）
///
/// | Dart 旧字段 | 后端有这个键吗 | 后果 |
/// |---|---|---|
/// | `newCount` ← `new_count` | ✅ 有，但**语义用错** | 显示的是「现在共几集」而不是「新增几集」 |
/// | `newEpisodeTitle` ← `new_episode_title` | ❌ 没有（真名 `latest_title`） | 那一段「第13集」**永远不显示** |
///
/// 实测差异（原版 `FollowView.vue:255-259` 渲染 `u.added`）：
/// ```text
/// 《某番》从 10 集更到 13 集
///   原版  「+3 集」     ← added
///   我们  「+13 集」    ★ 数值是错的（那是总数）
/// ```
/// ⚠️ 这个 bug 比"字段永远空"更隐蔽：**它显示了一个看起来合理的数字**，
///    所以没人会觉得是 bug —— 只会觉得"这剧更了 13 集"。
///
/// 所以新增 [added] / [latestTitle]，`oldCount` / `newCount` 也补上
/// （原版 UI 虽只用 `added`，但两个计数是同一份契约的一部分，
/// 缺了它们将来想做「10 → 13」这种展示时又要改一次模型）。
class UpdateInfo {
  const UpdateInfo({
    required this.key,
    required this.title,
    this.cover,
    this.provider = '',
    this.oldCount = 0,
    this.newCount = 0,
    this.added = 0,
    this.latestTitle,
  });

  /// `{provider}:{native_id}`
  final String key;

  final String title;
  final String? cover;
  final String provider;

  /// 之前记录的集数
  final int oldCount;

  /// 现在检测到的集数（**不是**新增数）
  final int newCount;

  /// ★ **新增**集数 —— 原版 `FollowView.vue:257` 的 `+{{ u.added }} 集`
  ///
  /// ⚠️ 不要用 [newCount] 顶替它，两者语义不同（增量 vs 总数）。
  final int added;

  /// 最新一集标题（原版 `FollowView.vue:258` 的 `{{ u.latest_title }}`）
  final String? latestTitle;

  factory UpdateInfo.fromJson(Map<String, dynamic> j) => UpdateInfo(
        key: j['key'] as String? ?? '',
        title: j['title'] as String? ?? '',
        cover: j['cover'] as String?,
        provider: j['provider'] as String? ?? '',
        oldCount: (j['old_count'] as num?)?.toInt() ?? 0,
        newCount: (j['new_count'] as num?)?.toInt() ?? 0,
        added: (j['added'] as num?)?.toInt() ?? 0,
        latestTitle: j['latest_title'] as String?,
      );

  // ── 旧字段名的只读转发（过渡期兼容，**不是第二份契约**）──
  //
  // ⚠️ 这两个 getter **语义是错的**（`newEpisodeTitle` 读的键后端从不下发），
  //    保留只是为了让尚未迁移的调用点继续编译。**新代码一律不要用**。

  /// ⚠️ 已废弃 —— 真名是 [latestTitle]（后端从不下发 `new_episode_title`）
  @Deprecated('后端真名是 latest_title（store.rs:386），请用 latestTitle')
  String? get newEpisodeTitle => latestTitle;
}

// ═══════════════════════════════════════════════════════════════════════
//  插件管理
// ═══════════════════════════════════════════════════════════════════════

/// 插件列表里的一项
class PluginEntry {
  const PluginEntry({
    required this.file,
    required this.id,
    required this.name,
    this.version = '',
    this.loaded = false,
    this.error,
    this.config = const [],
  });

  final String file;
  final String id;
  final String name;
  final String version;

  /// 是否成功加载（false 时 `error` 有原因）
  final bool loaded;

  final String? error;

  /// 插件声明的配置项
  final List<ConfigField> config;

  factory PluginEntry.fromJson(Map<String, dynamic> j) => PluginEntry(
        file: j['file'] as String? ?? '',
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        version: j['version'] as String? ?? '',
        loaded: j['loaded'] as bool? ?? false,
        error: j['error'] as String?,
        config: jlist<ConfigField>(j['config'], ConfigField.fromJson),
      );
}

/// 插件列表结果
class PluginListResult {
  const PluginListResult({this.plugins = const [], this.failed = const []});

  final List<PluginEntry> plugins;

  /// 加载失败的插件（文件名 + 原因）
  final List<(String, String)> failed;

  factory PluginListResult.fromJson(Map<String, dynamic> j) {
    final f = <(String, String)>[];
    for (final e in (j['failed'] as List? ?? const [])) {
      if (e is List && e.length >= 2) {
        f.add((e[0].toString(), e[1].toString()));
      }
    }
    return PluginListResult(
      plugins: jlist<PluginEntry>(j['plugins'], PluginEntry.fromJson),
      failed: f,
    );
  }
}

/// 插件安装结果
class PluginInstallResult {
  const PluginInstallResult({
    required this.id,
    required this.name,
    this.version = '',
    this.file = '',
    this.resolvedUrl,
    this.bytes = 0,
  });

  final String id;
  final String name;
  final String version;
  final String file;
  final String? resolvedUrl;
  final int bytes;

  factory PluginInstallResult.fromJson(Map<String, dynamic> j) =>
      PluginInstallResult(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        version: j['version'] as String? ?? '',
        file: j['file'] as String? ?? '',
        resolvedUrl: j['resolvedUrl'] as String?,
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
      );
}

// ═══════════════════════════════════════════════════════════════════════
//  代理
// ═══════════════════════════════════════════════════════════════════════

/// 代理模式（对应 Rust `ProxyMode`，`#[serde(rename_all = "snake_case")]`）
///
/// 权威定义：`rust/sourin_core/src/proxy.rs:66-88`。
/// ```rust
/// #[derive(..., Default)]
/// #[serde(rename_all = "snake_case")]
/// pub enum ProxyMode { #[default] Direct, System, Custom }
/// ```
/// 即 wire 值是 `"direct"` / `"system"` / `"custom"`，**默认 `Direct`**。
///
/// ⚠️ **默认值是 `Direct` 正是 bug ① 静默的原因** ——
///    旧的 `ProxyConfig.toJson()` 只发 `{enabled, url, username}`，
///    `mode` 缺省 → serde 填 `Direct` → `uses_proxy()` 返回 false
///    → 代理不生效，但**一个错误都不报**。
enum ProxyMode {
  /// 直连（未配置站点的默认值）
  direct('direct', '直连'),

  /// 跟随系统（读环境变量 `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY`）
  system('system', '跟随系统'),

  /// 自定义（该 Provider 专用）
  custom('custom', '自定义');

  const ProxyMode(this.wire, this.label);

  /// 传给后端的字符串（snake_case）
  final String wire;

  /// 界面文案
  final String label;

  /// 未知值 → `direct`
  ///
  /// ⚠️ 后端**不会**发未知值，但"读到不认识的值就当成直连"是安全的兜底：
  ///    直连 = 不走代理，不会把用户的流量偷偷导到别处。
  static ProxyMode parse(String? v) => switch (v) {
        'system' => ProxyMode.system,
        'custom' => ProxyMode.custom,
        _ => ProxyMode.direct,
      };
}

/// 代理作用范围（对应 Rust `ProxyScope`）
///
/// 权威定义：`rust/sourin_core/src/proxy.rs:79-88`，默认 `ApiOnly`。
enum ProxyScope {
  /// 仅 API 走代理（视频直连更流畅）—— **默认**
  apiOnly('api_only', '仅接口'),

  /// 全部流量走代理（含视频分片）
  all('all', '全部流量');

  const ProxyScope(this.wire, this.label);

  final String wire;
  final String label;

  static ProxyScope parse(String? v) =>
      v == 'all' ? ProxyScope.all : ProxyScope.apiOnly;
}

/// 某个源的代理配置
///
/// # ★★★ 字段集必须与 Rust `ProxyConfig` 逐字对齐（真 bug ① 的修复）
///
/// 权威定义：`rust/sourin_core/src/proxy.rs:90-107`
/// （与 `src-tauri/src/proxy.rs:92-107` 完全一致）：
/// ```rust
/// #[derive(Debug, Clone, Serialize, Deserialize)]
/// pub struct ProxyConfig {
///     #[serde(default)]                                    pub mode: ProxyMode,
///     #[serde(default, skip_serializing_if="Option::is_none")] pub url: Option<String>,
///     #[serde(default, skip_serializing_if="Vec::is_empty")]   pub bypass: Vec<String>,
///     #[serde(default)]                                    pub scope: ProxyScope,
///     #[serde(default, skip_serializing_if="Option::is_none")] pub username: Option<String>,
///     // ⚠️ 密码绝不在此结构里 —— 只存钥匙串，见 set_password / take_password
/// }
/// ```
///
/// ## 修之前是什么样（**代理永远不生效，且不报错**）
///
/// ```text
/// Dart 旧字段   {enabled: bool, url: String, username: String?, hasPassword: bool}
/// 旧 toJson()   {"enabled": true, "url": "...", "username": "..."}
///
/// Rust 结构     {mode, url, bypass, scope, username}
/// ```
/// 后果链条（每一环都**静默**）：
/// ```text
/// ① `enabled` 在 Rust 结构里**没有对应字段**，且结构上没有
///    `#[serde(deny_unknown_fields)]` → 被 serde **静默丢弃**
/// ② `mode` 缺失 → `#[serde(default)]` 填 `ProxyMode::Direct`
/// ③ `ProxyConfig::uses_proxy()`（proxy.rs:123-130）返回 false
/// ④ → **代理永远不生效** —— 用户以为配好了，实际还是直连
/// ```
/// 读取方向同样是坏的：旧 `fromJson` 读 `enabled`，
/// 而后端**从不下发这个字段** → 已配置的代理在 UI 上永远显示"未启用"。
///
/// ## ★ `uses_proxy()` 的判定（照抄，Dart 侧的 [isActive] 与它一致）
/// ```text
/// Direct → false
/// System → true
/// Custom → url 非空才 true（空则按直连，避免 reqwest 报错）
/// ```
class ProxyConfig {
  const ProxyConfig({
    this.mode = ProxyMode.direct,
    this.url,
    this.bypass = const [],
    this.scope = ProxyScope.apiOnly,
    this.username,
    this.hasPassword = false,
  });

  /// 代理模式 —— **默认直连**（与 Rust 的 `#[serde(default)]` 一致）
  final ProxyMode mode;

  /// 代理地址，如 `http://127.0.0.1:7890` / `socks5://127.0.0.1:1080`
  ///
  /// ⚠️ Rust 是 `Option<String>`（可空），不是非空 `String` ——
  ///    旧 Dart 写成非空 `String` 并默认 `''`，于是 `toJson()` 永远
  ///    发一个 `"url": ""`，后端会存下一个**空 URL**。
  final String? url;

  /// 不走代理的主机
  final List<String> bypass;

  final ProxyScope scope;

  /// 代理认证的用户名（密码**不在这里**）
  final String? username;

  /// 是否已存密码（**密码本身永远不会下发**）
  ///
  /// ⚠️ **不是**配置结构的一部分 —— 密码只存系统钥匙串
  ///    （`set_proxy_password` / `has_proxy_password`），
  ///    所以它由调用方从 `hasProxyPassword()` 单独查出来再赋上。
  final bool hasPassword;

  /// 折叠态那一行摘要（"直连" / "跟随系统" / "自定义"）
  String get summary => switch (mode) {
        ProxyMode.direct => '直连',
        ProxyMode.system => '跟随系统',
        ProxyMode.custom =>
          (url == null || url!.trim().isEmpty) ? '自定义（未填地址）' : url!,
      };

  /// 用户是否"配过"（折叠面板据此自动展开）
  bool get isConfigured => mode != ProxyMode.direct;

  /// 这份配置**是否真的会走代理** —— 与 Rust `uses_proxy()` 逐字对应
  ///
  /// ⚠️ 与 [isConfigured] **不是一回事**：
  /// ```text
  /// mode = custom 但 url 为空 → isConfigured = true（用户确实选了自定义）
  ///                            → isActive     = false（后端按直连处理）
  /// ```
  /// 这正是"UI 显示已配置、实际没生效"这种困惑的来源，
  /// 所以两个判定都留着，各有各的用途。
  bool get isActive => switch (mode) {
        ProxyMode.direct => false,
        ProxyMode.system => true,
        ProxyMode.custom => url != null && url!.trim().isNotEmpty,
      };

  factory ProxyConfig.fromJson(Map<String, dynamic> j) => ProxyConfig(
        mode: ProxyMode.parse(j['mode'] as String?),
        url: j['url'] as String?,
        bypass: (j['bypass'] as List? ?? const []).whereType<String>().toList(),
        scope: ProxyScope.parse(j['scope'] as String?),
        username: j['username'] as String?,
        /*
         * ⚠️ `has_password` **不在** Rust 的 ProxyConfig 里，
         *    但兼容读取它没有坏处：将来后端若把它一起下发，
         *    这里就已经能读了（不必再改一次模型）。
         *    正常路径仍然是调用 `SourinApi.hasProxyPassword()`。
         */
        hasPassword: j['has_password'] as bool? ?? false,
      );

  /// 发给后端的 payload —— **键名与 Rust 结构严格一致**
  ///
  /// ⚠️ 三条硬约定：
  /// ```text
  /// ① 绝不包含 password —— Rust 注释：
  ///    > ⚠️ 密码绝不在此结构里 —— 只存钥匙串，见 set_password / take_password
  ///    （原版也照这个做：密码不进配置对象，**也就不进备份**）
  /// ② url 为空时**不传**（后端是 Option<String>，传空串会存一个空 URL）
  /// ③ bypass 为空时**不传**（后端 skip_serializing_if = is_empty，语义相同）
  /// ```
  Map<String, dynamic> toJson() => {
        'mode': mode.wire,
        if (url != null && url!.trim().isNotEmpty) 'url': url!.trim(),
        if (bypass.isNotEmpty) 'bypass': bypass,
        'scope': scope.wire,
        if (username != null && username!.trim().isNotEmpty)
          'username': username!.trim(),
      };

  /// 复制一份（改少数字段）—— 避免调用方写一大串构造参数
  ProxyConfig copyWith({
    ProxyMode? mode,
    String? url,
    List<String>? bypass,
    ProxyScope? scope,
    String? username,
    bool? hasPassword,
  }) =>
      ProxyConfig(
        mode: mode ?? this.mode,
        url: url ?? this.url,
        bypass: bypass ?? this.bypass,
        scope: scope ?? this.scope,
        username: username ?? this.username,
        hasPassword: hasPassword ?? this.hasPassword,
      );
}

/// 代理测试结果
class ProxyTestResult {
  const ProxyTestResult({required this.ok, this.message = ''});

  final bool ok;
  final String message;

  factory ProxyTestResult.fromJson(Map<String, dynamic> j) => ProxyTestResult(
        ok: j['ok'] as bool? ?? false,
        message: j['message'] as String? ?? '',
      );
}

// ═══════════════════════════════════════════════════════════════════════
//  备份 / 同步
// ═══════════════════════════════════════════════════════════════════════

/// 备份内容概览（预览与检视共用）
class BackupPreview {
  const BackupPreview({
    this.version = 0,
    this.deviceId = '',
    this.appVersion = '',
    this.exportedAt,
    this.counts = const {},
    this.plugins = const [],
  });

  final int version;
  final String deviceId;
  final String appVersion;
  final int? exportedAt;

  /// 各类数据的条数（favorites / progress / plugins ...）
  final Map<String, int> counts;

  /// 插件清单：(文件名, 字节数)
  final List<(String, int)> plugins;

  factory BackupPreview.fromJson(Map<String, dynamic> j) {
    final c = <String, int>{};
    final raw = jmap(j['counts']);
    raw.forEach((k, v) {
      if (v is num) c[k] = v.toInt();
    });
    final p = <(String, int)>[];
    for (final e in (j['plugins'] as List? ?? const [])) {
      final m = jmap(e);
      p.add((
        m['name'] as String? ?? '',
        (m['bytes'] as num?)?.toInt() ?? 0,
      ));
    }
    return BackupPreview(
      version: (j['version'] as num?)?.toInt() ?? 0,
      deviceId: j['deviceId'] as String? ?? '',
      appVersion: j['appVersion'] as String? ?? '',
      exportedAt: (j['exportedAt'] as num?)?.toInt(),
      counts: c,
      plugins: p,
    );
  }
}

/// 备份导出结果
class BackupExportResult {
  const BackupExportResult({required this.path, required this.bytes});

  final String path;
  final int bytes;

  factory BackupExportResult.fromJson(Map<String, dynamic> j) =>
      BackupExportResult(
        path: j['path'] as String? ?? '',
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
      );
}

/// 备份导入汇总
///
/// # 注意 `skipped` —— 有内容就说明**部分数据没导入**
///
/// UI 应该把它显示给用户，而不是只报"导入成功"。
class ImportSummary {
  const ImportSummary({
    this.favoritesAdded = 0,
    this.favoritesUpdated = 0,
    this.followingAdded = 0,
    this.progressUpdated = 0,
    this.historyAdded = 0,
    this.skipUpdated = 0,
    this.pluginsWritten = const [],
    this.pluginsRenamed = const [],
    this.providersImported = 0,
    this.skipped = const [],
  });

  final int favoritesAdded;
  final int favoritesUpdated;
  final int followingAdded;
  final int progressUpdated;
  final int historyAdded;
  final int skipUpdated;
  final List<String> pluginsWritten;
  final List<String> pluginsRenamed;
  final int providersImported;

  /// 被跳过的条目及原因（**要显示给用户**）
  final List<String> skipped;

  factory ImportSummary.fromJson(Map<String, dynamic> j) => ImportSummary(
        favoritesAdded: (j['favorites_added'] as num?)?.toInt() ?? 0,
        favoritesUpdated: (j['favorites_updated'] as num?)?.toInt() ?? 0,
        followingAdded: (j['following_added'] as num?)?.toInt() ?? 0,
        progressUpdated: (j['progress_updated'] as num?)?.toInt() ?? 0,
        historyAdded: (j['history_added'] as num?)?.toInt() ?? 0,
        skipUpdated: (j['skip_updated'] as num?)?.toInt() ?? 0,
        pluginsWritten: jstrList(j['plugins_written']),
        pluginsRenamed: jstrList(j['plugins_renamed']),
        providersImported: (j['providers_imported'] as num?)?.toInt() ?? 0,
        skipped: jstrList(j['skipped']),
      );
}

/// 同步状态
class SyncStatus {
  const SyncStatus({this.connected = false, this.backend, this.deviceId = ''});

  final bool connected;
  final String? backend;
  final String deviceId;

  factory SyncStatus.fromJson(Map<String, dynamic> j) => SyncStatus(
        connected: j['connected'] as bool? ?? false,
        backend: j['backend'] as String?,
        deviceId: j['deviceId'] as String? ?? '',
      );
}

/// 同步的一步汇总
class SyncSummary {
  const SyncSummary({this.kind = '', this.count = 0, this.message = ''});

  final String kind;
  final int count;
  final String message;

  factory SyncSummary.fromJson(Map<String, dynamic> j) => SyncSummary(
        kind: j['kind'] as String? ?? '',
        count: (j['count'] as num?)?.toInt() ?? 0,
        message: j['message'] as String? ?? '',
      );
}

/// 云盘同步 + 自动备份的设置（`sync_settings_get` / `sync_settings_set`）
///
/// # ★ 这个类的 JSON 键是 camelCase，不是 snake_case
///
/// 本文件的通用约定是「JSON 字段 snake_case（Rust serde 默认）」，
/// 但云盘设置**故意反过来** —— 它存的是「本地偏好 + 少量连接信息」，
/// Rust 侧用 `#[serde(rename_all = "camelCase")]` 收发，Dart 侧就不必
/// 再多写一层键名映射。唯一权威定义见 `.probe/t91_sync_iface.md` §2。
///
/// # ★ 两个「间隔」是两回事（不要合并）
///
/// * [autoIntervalMinutes] = **多久看一眼云端**（增量同步，几个请求，几 KB）
/// * [autoBackupIntervalMinutes] = **多久整包备份一次**（zip 快照 + 清理旧份）
///
/// 阅读 App（Legado）就是这么拆的：进度 5 分钟 debounce、整包备份 24 小时。
/// 合并成一个间隔会导致「每 30 分钟传一个 zip」，与「耗很低的流量」相反。
class SyncSettings {
  const SyncSettings({
    this.connected = false,
    this.baseUrl = '',
    this.username = '',
    this.remoteDir = '',
    this.retainCount = 10,
    this.autoEnabled = false,
    this.autoIntervalMinutes = 30,
    this.autoOnChange = true,
    this.autoBackupIntervalMinutes = 1440,
    this.lastBackupAt = 0,
    this.lastSyncAt = 0,
  });

  /// 引擎是否已就绪（**只在 `sync_settings_get` 的返回里有**，设置文件里不存）
  final bool connected;

  /// WebDAV 地址（含或不含结尾斜杠都行）
  final String baseUrl;
  final String username;

  /// 远程目录；空 = 用 WebDAV 根目录
  final String remoteDir;

  /// 云端整体备份最多保留几份（下限 1，超出删最旧的）
  final int retainCount;

  /// 自动同步总开关
  final bool autoEnabled;

  /// 「多久看一眼云端」的间隔（分钟）；0 = 关
  final int autoIntervalMinutes;

  /// 数据有变动就同步（不用等间隔）
  final bool autoOnChange;

  /// 整体备份的间隔（分钟）；0 = 关
  final int autoBackupIntervalMinutes;

  /// 上次成功整体备份的时间（毫秒时间戳）；0 = 从未
  final int lastBackupAt;

  /// 上次成功同步的时间（毫秒时间戳）；0 = 从未
  final int lastSyncAt;

  factory SyncSettings.fromJson(Map<String, dynamic> j) => SyncSettings(
        connected: j['connected'] as bool? ?? false,
        baseUrl: j['baseUrl'] as String? ?? '',
        username: j['username'] as String? ?? '',
        remoteDir: j['remoteDir'] as String? ?? '',
        retainCount: (j['retainCount'] as num?)?.toInt() ?? 10,
        autoEnabled: j['autoEnabled'] as bool? ?? false,
        autoIntervalMinutes: (j['autoIntervalMinutes'] as num?)?.toInt() ?? 30,
        autoOnChange: j['autoOnChange'] as bool? ?? true,
        autoBackupIntervalMinutes:
            (j['autoBackupIntervalMinutes'] as num?)?.toInt() ?? 1440,
        lastBackupAt: (j['lastBackupAt'] as num?)?.toInt() ?? 0,
        lastSyncAt: (j['lastSyncAt'] as num?)?.toInt() ?? 0,
      );
}

/// 云端的一份整体备份（`sync_backup_list` 的元素）
///
/// 文件名由后端按「设备 + 日期时间」生成：
/// `dsh-backup-<设备>-20260929-143012.zip` ⇒ 字典序即时间序。
class SyncBackupEntry {
  const SyncBackupEntry({this.name = '', this.bytes = 0, this.modified = 0});

  final String name;
  final int bytes;

  /// 远端 `getlastmodified`（毫秒时间戳）；解析不出来时为 0
  final int modified;

  factory SyncBackupEntry.fromJson(Map<String, dynamic> j) => SyncBackupEntry(
        name: j['name'] as String? ?? '',
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
        modified: (j['modified'] as num?)?.toInt() ?? 0,
      );
}

/// 一次整体备份的结果（`sync_backup_now`）
class SyncBackupResult {
  const SyncBackupResult({
    this.name = '',
    this.bytes = 0,
    this.path = '',
    this.pruned = const [],
    this.total = 0,
  });

  /// 本次上传的备份文件名
  final String name;

  /// 本次上传的字节数
  final int bytes;

  /// 远端完整路径（给人看/排错用）
  final String path;

  /// 本次按保留份数删掉的旧备份文件名
  final List<String> pruned;

  /// **清理之后**云端仍留的 `dsh-backup-*.zip` 份数
  final int total;

  factory SyncBackupResult.fromJson(Map<String, dynamic> j) => SyncBackupResult(
        name: j['name'] as String? ?? '',
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
        path: j['path'] as String? ?? '',
        pruned: jstrList(j['pruned']),
        total: (j['total'] as num?)?.toInt() ?? 0,
      );
}

// ═══════════════════════════════════════════════════════════════════════
//  遥控
// ═══════════════════════════════════════════════════════════════════════

/// 遥控服务状态
class RemoteStatus {
  const RemoteStatus({
    this.running = false,
    this.url = '',
    this.port = 8642,
    this.pin = '',
    this.fixedPin,
    this.lanIp = '',
    this.reachable = false,
    this.qrSvg = '',
    this.stopped,
  });

  final bool running;
  final String url;
  final int port;

  /// 随机配对码（每次刷新都变）
  final String pin;

  /// 用户自设的固定配对码（与随机码**并存**，两个都能进）
  final String? fixedPin;

  final String lanIp;

  /// 局域网是否可达
  ///
  /// 判据是「局域网 IP 不是环回地址」—— 如果是 127.0.0.1，
  /// 说明**没连上局域网**，手机根本连不到这台机器。
  /// UI 应该提示这一点，而不是给用户一个抄了也没用的地址。
  final bool reachable;

  /// 配对二维码（SVG 字符串）
  final String qrSvg;

  /// `remote_stop` 专有：是否**真的**停了（超时可能没停干净）
  final bool? stopped;

  factory RemoteStatus.fromJson(Map<String, dynamic> j) => RemoteStatus(
        running: j['running'] as bool? ?? false,
        url: j['url'] as String? ?? '',
        port: (j['port'] as num?)?.toInt() ?? 8642,
        pin: j['pin'] as String? ?? '',
        fixedPin: j['fixedPin'] as String?,
        lanIp: j['lanIp'] as String? ?? '',
        reachable: j['reachable'] as bool? ?? false,
        qrSvg: j['qrSvg'] as String? ?? '',
        stopped: j['stopped'] as bool?,
      );
}


// ═══════════════════════════════════════════════════════════════════════
//  局域网遥控 —— 状态与命令（2026-09-24 补齐）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要这两个模型
//
// `remote_report_state` 要传一个 Map、`remote_take_commands` 返回一串 Map ——
// 没有类型的话调用方只能手搓字符串键，**拼错一个键名就静默失效**
// （Rust 侧反序列化失败 / 字段缺失，界面上表现为"手机上状态不对"，
// 而编译期毫无提示）。
//
// 对齐原版 `src/api/types.ts` 的 `RemoteState` / `RemoteCommand`。
//
// ⚠️ **字段名必须与 Rust 侧完全一致**（snake_case）——
//    Rust 是带 tag 的枚举 + serde 反序列化，
//    字段名对不上会被**直接拒绝**（这是有意的安全设计：
//    不能让手机端任意指挥前端）。

/// 播放器上报给手机端的状态
///
/// 对齐原版 `RemoteState`。
class RemoteState {
  const RemoteState({
    this.playing = false,
    this.title = '',
    this.episodeOrder = 0,
    this.episodeCount = 0,
    this.position = 0,
    this.duration = 0,
    this.volume = 0,
    this.muted = false,
    this.sources = const [],
    this.currentSource = '',
    this.episodes = const [],
    this.hasMedia = false,
    this.introStart,
    this.introSkip,
    this.outroSkip,
    this.outroEnd,
    this.autoSkip = true,
    this.skipEditing,
  });

  final bool playing;
  final String title;

  /// 第几集（1 基；非剧集为 0）
  final int episodeOrder;
  final int episodeCount;
  final int position;
  final int duration;
  final int volume;
  final bool muted;

  /// `(code, 名称)`
  final List<(String, String)> sources;
  final String currentSource;

  /// `(集号, 标题)`
  final List<(int, String)> episodes;

  /// **是否有媒体** —— 手机端据此提示「去客户端打开一个视频」
  final bool hasMedia;

  /// 片头区间**开始**（秒）；null = 未设置
  final int? introStart;

  /// 片头**结束**位置（秒）；null = 未设置
  final int? introSkip;

  /// 片尾**开始**位置（秒）；null = 未设置
  final int? outroSkip;

  /// 片尾**结束**位置（秒）；null = 跳到视频结尾
  final int? outroEnd;

  final bool autoSkip;

  /// 正在编辑哪个端点（手机端据此高亮）
  final String? skipEditing;

  /// 转成 `remote_report_state` 要的 Map
  ///
  /// ⚠️ **片头片尾字段必须全给**（哪怕是 null）——
  ///    原版注释记过这个坑：不给的话端上显示 `undefined`。
  Map<String, dynamic> toJson() => {
        'playing': playing,
        'title': title,
        'episode_order': episodeOrder,
        'episode_count': episodeCount,
        'position': position,
        'duration': duration,
        'volume': volume,
        'muted': muted,
        // Rust 侧是 `Vec<(String,String)>` —— 用 List 而不是 Map
        'sources': sources.map((e) => [e.$1, e.$2]).toList(),
        'current_source': currentSource,
        'episodes': episodes.map((e) => [e.$1, e.$2]).toList(),
        'has_media': hasMedia,
        'intro_start': introStart,
        'intro_skip': introSkip,
        'outro_skip': outroSkip,
        'outro_end': outroEnd,
        'auto_skip': autoSkip,
        'skip_editing': skipEditing,
      };

  /// 「没有播放器」时上报的状态
  ///
  /// 手机端据此提示「去客户端打开一个视频」。
  ///
  /// ⚠️ 原版注释强调：**没有播放页时也要上报** ——
  ///    不报的话手机会一直显示上次的标题与进度，
  ///    用户以为还在播（实际播放页早关了）。
  static RemoteState idle() => const RemoteState();
}

/// 手机端发来的命令
///
/// 对齐原版 `RemoteCommand`（Rust 侧是带 tag 的枚举，
/// **未知 kind 会被反序列化拒绝** —— 有意的安全设计）。
class RemoteCommand {
  const RemoteCommand(this.kind, [this.args = const {}]);

  /// 命令名，如 `toggle_play` / `next_episode` / `query_search`
  final String kind;

  /// 该命令的参数
  final Map<String, dynamic> args;

  factory RemoteCommand.fromJson(Map<String, dynamic> j) {
    final kind = j['kind']?.toString() ?? '';
    // 除 kind 之外的字段都是参数
    final args = <String, dynamic>{};
    for (final e in j.entries) {
      if (e.key == 'kind') continue;
      args[e.key] = e.value;
    }
    return RemoteCommand(kind, args);
  }

  String? get keyword => args['keyword']?.toString();
  String? get provider => args['provider']?.toString();
  String? get id => args['id']?.toString();
  String? get title => args['title']?.toString();
  String? get code => args['code']?.toString();
  String? get edge => args['edge']?.toString();

  /// ⚠️ 这两个**不能**写成 `get`（Dart 的 getter 不接受参数 —— 编译报
  ///    `Getters must be declared without a parameter list`，我第一版踩了）。
  num? number(String key) => args[key] as num?;
  bool? flag(String key) => args[key] as bool?;
}
