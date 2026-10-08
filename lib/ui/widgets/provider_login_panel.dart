// ═══════════════════════════════════════════════════════════════════════
//  Provider 登录 / 登出面板
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要有这个
//
// 审计发现 `ensureProviderSession` / `providerLogout` /
// `forgetProviderCredentials` / `getProviderEnabled` / `providerLogin`
// 这几个命令在 `lib/ui/**` 里**零调用** ——
// 后端能力齐了，界面没做。原版在 `SettingsView.vue` 里有完整入口。
//
// # 原版的关键设计（`SettingsView.vue` 的 `stateOf()`，照抄）
//
// ## 会话状态有四种，文案各不相同
//
// ```text
// active        → 「已登录」
// expiring      → 「已登录」+「令牌将在到期前自动续期，无需操作」
// not_required  → 「无需登录」**或**「游客可用」  ← 见下
// expired       → 「登录已失效」+「需重新登录（可能需要验证码）」
// ```
//
// ## ★ `not_required` 必须再分两种（原版注释专门讲了，这是真 bug 修复）
//
// > ★ 区分「压根不需要登录」与「游客可用、但登录是可选增强」
// >
// > 两者在后端都是 `not_required`（会话校验只管 `login_required`），
// > 但界面上该说的话完全不同：
// > ```text
// > · 央视        → 「无需登录」     （确实没有登录这回事）
// > · B站         → 「游客可用」     （能登录，只是不登也能用）
// > ```
// > ⚠️ 给 B站 显示「无需登录」是**错的** —— 它旁边就有个「登录」按钮，
// >    用户会以为是 bug。
//
// 判据是 `capabilities.login_supported`。
//
// ## ★ 登录入口的过滤条件
//
// ```text
// login_required || login_supported     ← 设置页显示登录入口
// login_required                        ← 会话校验（后端 ensure_session 用）
// ```
//
// 后端注释：
// > ⚠️ **绝不能**给 B站 设 `login_required = true`：
// >    `Registry::ensure_session` 会因此**挡住游客播放**
// >    （`if !login_required { return Some(true) }` 那条捷径失效），
// >    而「不登录就能看 1080P」正是 Owner 明确要的能力。
//
// ═══════════════════════════════════════════════════════════════════════
//  ✅ 曾经写在这里的「能力缺失 ①」**已修复**（任务 P2）
// ═══════════════════════════════════════════════════════════════════════
//
// 原注释说：
// > ## 缺失 ①：我们的 `Capabilities` 模型**少了 4 个登录字段**
// > `lib/core/models.dart` 的 `Capabilities` 只有**一个** `login` 布尔，
// > 而后端实际有 `login_required` / `login_supported` / `login_hint` /
// > `login_needs_username` / `login_qr_supported`。
// > **缓解措施**：从**原始 JSON** 里读这几个字段。
//
// 那个"缓解措施"（本文件原先的 `LoginCaps.fromRaw`）**已经撤除**：
// `models.dart::Capabilities` 现在按 `rust/sourin_core/src/model.rs:560-625`
// 补齐了全部 14 个字段，本面板直接用类型化字段，不再自己解析 JSON。
//
// # 为什么撤掉 `fromRaw` 是**必须的**（不是洁癖）
//
// ```text
// fromRaw  = 第二份契约。字段名（尤其 login_needs_username 的默认值
//            是 true 还是 false）写错一处，两处就会不一致 ——
//            而这里写错的表现是「账号框不显示 → 登录按钮永远禁用」，
//            正是后端注释专门警告过的那个坑。
// 类型化   = 唯一来源。默认值只在 Capabilities.fromJson 里写一次。
// ```
//
// 顺带：`Capabilities` 还多暴露了一个 [Capabilities.showLoginEntry]
// （= `loginRequired || loginSupported`），把"设置页显示登录入口"的
// 判据也收进模型，UI 侧不用各写一遍。
//
// # 扫码登录：**已可用**（2026-10-05 补齐 spike 命令层）
//
// 本文件早期版本写过「扫码登录**完全不可用**（而且原版也是坏的）」—— 那只是
// **spike 当时的事实**：spike 的 Rust 侧确实没有 provider_qr_login_start /
// provider_qr_login_poll 这两个命令（generate_handler! 只注册了 6 个登录命令）。
// 但「原版也是坏的」**是错的** —— 这两个命令在原版 src-tauri/src/lib.rs 里
// 注册着（lib.rs:4647-4648），原版设置页的扫码页签一直能用。
//
// 现在 spike 侧也补齐了。证据（全部实测，不是推断）：
//   1) 命令层：rust/sourin_core/src/commands_backup.rs:154 / :176
//      + rust/sourin_core/src/ffi.rs:1498 / :1507 两条 arm
//      + lib/core/sourin_api.dart:1110 / :1128 两个包装
//   2) 真请求：cargo test --test t525_qr_login => 4 passed / 0 failed
//      start 拿到 key + 145 字符 url + 22972 字符 svg；poll 立即返回 Pending
//   3) 插件层：部署版 bilibili.js（63,437 B）已实现 qrLoginStart / qrLoginPoll，
//      返回结构与本面板用到的字段（key / url / svg / hint / status / message /
//      session）逐字对齐 —— 插件一行都不用改
//
// 所以本面板**有**扫码页签，且**只在插件声明 login_qr_supported 时渲染**
// （对应 Capabilities.loginQrSupported）。不支持时只有一个页签，显示出来纯属
// 噪音 —— 这是原版 SettingsView.vue:3066 注释里的结论。
//
// 账号密码 + Cookie 导入两条路照旧（后者走同一条命令，把 Cookie 串当
// password 传 —— 与原版 login_needs_username=false 时的行为一致）。

import 'dart:async';

import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/sourin_api.dart';
import '../tokens.dart';
import 'overlay_motion.dart';
import 'qr_view.dart';

/// 会话状态（对应 Rust `SessionState`，`snake_case`）
enum SessionState {
  /// 该源不需要登录
  notRequired('not_required', '无需登录', Tone.ok),

  /// 已登录且可用
  active('active', '已登录', Tone.ok),

  /// 已登录但即将过期（宿主会尝试自动续期）
  expiring('expiring', '已登录', Tone.ok),

  /// 登录已失效，且无法自动恢复 —— 需要人工登录
  expired('expired', '登录已失效', Tone.err);

  const SessionState(this.wire, this.label, this.tone);

  final String wire;
  final String label;
  final Tone tone;

  static SessionState parse(String? v) => switch (v) {
    'active' => SessionState.active,
    'expiring' => SessionState.expiring,
    'expired' => SessionState.expired,
    _ => SessionState.notRequired,
  };
}

enum Tone { ok, warn, err }

/// `expired` 状态下该对用户说什么 —— **按能力位分两种**（task-38）
///
/// # 为什么抽成**顶层纯函数**（而不是留在 `_display` 的 switch 里）
///
/// ```text
/// ① 可**运行时**验证：给一个 Capabilities，直接断言返回的文案
///    —— 不用 pump 面板、不用真核心、不用真会话。
/// ② ★ 文本断言容易被"假绿"骗过（本项目刚踩过两个洞）：
///      · `src.contains('canAutoLogin')` 会被 import 行 / 注释匹配
///      · 断言字面量 `hint: '…'` 会被"包一层 helper"绕过
///    函数返回**值**就没有这些漏洞：参数变 → 返回值必须跟着变。
/// ③ 判据只有一处（以后加"第三种文案"不会漏改）。
/// ```
///
/// # 用户报的问题（原话）
///
/// > 次元城登录失效 明明不需要验证码就可以自动登录，还提示 验证码
///
/// # 实测诊断（用真实凭据跑过全链路）
///
/// 自动重登链路**一直是好的**：
/// ```text
/// can_auto_login() → true
/// auto_login()     → Ok(Some)    ← 真的成功（0.46 秒）
/// ensure_session() → Some(true)  ← 且磁盘写回了新 token
/// ```
/// ★ 用户看到「可能需要验证码」的时刻是：**token 已死、但还没点播**
///   （那时 `session_state()` 确实返回 `Expired`）。
///   他**只要点一下播放**，宿主就会自动重登 → 就能播了。
///   ⇒ 他什么都不用做，文案却叫他「请手动完成」—— **这是误导**。
///
/// # 两种文案
///
/// ```text
/// canAutoLogin = true  → 「正在自动重新登录，直接播放即可恢复」
///                        ★ 不带"验证码"，且告诉用户**不用动手**
///                        ⚠️ 措辞是"直接播放即可恢复"而**不是**
///                           "我们已经帮你重登了" —— 重登发生在
///                           **点播那一刻**，说"已经"就是第二种撒谎
/// canAutoLogin = false → 原版通用文案（`SettingsView.vue:175`）
///                        对真有验证码的源，那句是**对的**
/// ```
({String label, String hint, Tone tone}) expiredHintFor(Capabilities caps) {
  if (caps.canAutoLogin) {
    return (
      label: '登录已失效',
      hint: '正在自动重新登录，直接播放即可恢复（无需手动操作）',
      // ★ 这是**好消息**（不用你动手）→ 不能用错误色继续吓用户
      tone: Tone.ok,
    );
  }
  return (label: '登录已失效', hint: '需重新登录（可能需要验证码，请手动完成）', tone: Tone.err);
}

/// Provider 登录 / 登出面板（嵌在源卡片里）
class ProviderLoginPanel extends StatefulWidget {
  const ProviderLoginPanel({
    super.key,
    required this.providerId,
    required this.providerName,
    this.caps,
    this.defaultOpen = false,
    this.onLoggedIn,
    this.debugSessionStateOverride,
  });

  final String providerId;
  final String providerName;

  /// 登录能力位
  ///
  /// null 时本面板自己去 `SourinApi.listProviders()` 里找这个源再取
  /// `provider.capabilities`（见 [_ProviderLoginPanelState._load]）。
  final Capabilities? caps;

  final bool defaultOpen;

  /// ★ 登录成功后的回调（2026-09-24 新增）
  ///
  /// # 为什么需要
  ///
  /// 播放失败页的「登录」按钮要求「登录成功后能重试播放」。
  /// 光把面板弹出来、登录完就关掉，用户还得自己再点一次「重试」——
  /// 而他刚刚解决的就是那个导致失败的原因，让他再点一次很多余。
  ///
  /// 面板自己不 `Navigator.pop` 也不重试播放：它嵌在设置页里，
  /// **不知道**调用方是弹窗还是内嵌卡片。所以只发信号，由调用方决定。
  final VoidCallback? onLoggedIn;

  /// ★★★ **仅测试用**：强制指定会话状态（task-38 复核时加，task-41 的 Lead 批准）
  ///
  /// # 为什么必须有它（否则"不自动展开"这条**无法验证**）
  ///
  /// task-38 修的是"`expired` 时不再自动展开"。但那条行为在**单测里不可达**：
  /// ```dart
  /// // _load() 里
  /// final (s, st) = await (
  ///   SourinApi.providerSession(...).catchError((_) => null),
  ///   SourinApi.providerSessionStateWire(...).catchError((_) => null),
  /// ).wait;
  /// _state = st is String ? SessionState.parse(st)
  ///                       : ((s != null) ? active : notRequired);
  /// ```
  /// ```text
  /// 无核心环境 → providerSessionStateWire 抛 → catchError → st = null
  ///            → _state = (s != null) ? active : **notRequired**
  /// ⇒ ★★★ 永远到不了 `expired`
  /// ⇒ 就算把 `if (_state == expired) _open = true;` 塞回代码里（红度验证），
  ///   它也**永不触发** ⇒ 测试照样绿
  /// ⇒ 那条判据是**空断言**：不是靠"逻辑被删了"通过，
  ///   而是靠"**那个状态根本不可达**"通过。
  /// ```
  /// ★ 这是 2026-09-25 复核时实测发现的（注入回归后测试**仍然全绿**）。
  ///
  /// # 语义
  /// ```text
  /// null（默认，生产路径）→ 行为与以前**完全一致**（照常走 FFI）
  /// 非 null（仅测试）     → **短路掉 FFI 拉取**，直接用这个状态
  /// ```
  /// ⚠️ 非 null 时**不再调用** `providerSession*` ⇒ 测试不依赖核心存在。
  ///
  /// ⚠️ release 构建【永远】传 null（只有测试会传）⇒ **零行为影响**。
  @visibleForTesting
  final SessionState? debugSessionStateOverride;

  @override
  State<ProviderLoginPanel> createState() => _ProviderLoginPanelState();
}

class _ProviderLoginPanelState extends State<ProviderLoginPanel> {
  Capabilities _caps = const Capabilities();

  /// 当前会话（null = 未登录）
  Map<String, dynamic>? _session;

  SessionState? _state;
  bool _loading = true;
  bool _busy = false;
  String _err = '';
  String _ok = '';

  bool _open = false;

  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  // ── 扫码登录状态 ──
  /// 当前页签：'form'（账号密码 / Cookie）| 'qr'（扫码）
  String _tab = 'form';

  /// provider_qr_login_start 的原样返回（key / url / svg / hint）
  Map<String, dynamic>? _qr;
  String _qrMsg = '';
  bool _qrBusy = false;
  bool _qrDone = false;

  /// ★ 轮询定时器必须持有句柄并在 dispose / 切回表单时清掉。
  ///   原版注释（SettingsView.vue:230-232）：不定时清掉的话，弹窗关了
  ///   定时器还在跑，会一直打 B站 的轮询接口 —— 风控风险 + 无谓流量。
  Timer? _qrTimer;

  /// 防重叠：一次 poll 还没回来就不发第二次
  bool _qrPolling = false;

  @override
  void initState() {
    super.initState();
    _open = widget.defaultOpen;
    _caps = widget.caps ?? const Capabilities();
    _load();
  }

  @override
  void dispose() {
    _qrTimer?.cancel();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = '';
    });
    try {
      // ── 能力位：没传就自己去列表里找 ──
      if (widget.caps == null) {
        try {
          final list = await SourinApi.listProviders();
          for (final p in list) {
            if (p.id == widget.providerId) {
              _caps = p.capabilities;
              break;
            }
          }
        } catch (e) {
          debugPrint('[LOGIN] 拉 capabilities 失败: $e');
        }
      }

      if (!_caps.showLoginEntry) {
        // 这个源压根不需要登录 —— 面板自己不显示（见 build）
        if (!mounted) return;
        setState(() => _loading = false);
        return;
      }

      /*
       * ★★★ 测试注入点：非 null 时**短路掉 FFI**（task-38 复核时加）
       *
       * 为什么必须在这里短路（而不是在下面覆盖 `_state`）：
       * ```text
       * 若放在 `await` 之后覆盖 ⇒ 那两个 FFI 调用**仍然发生** ⇒
       *   ① 测试仍然依赖核心（或仍走 catchError 路径）
       *   ② 在**真机**上它会真的去查会话（有副作用）
       * ⇒ 放在 await **之前**，才能真正"不依赖核心、无副作用"
       * ```
       * ⚠️ 仍然保留"不自动展开"的语义 —— `_open` **不**因 expired 而变，
       *    这正是被测行为（见 `debugSessionStateOverride` 的长注释）。
       */
      /*
       * 两个查询并行（原版也是 `Promise.all`）：
       * ```text
       * provider_session        → 拿昵称/头像（Map? —— 未登录时是 null）
       * provider_session_state  → 判断该提示什么（String? —— 源不存在时是 null）
       * ```
       *
       * ⚠️ 两个返回类型**不一样**（`Map?` vs `String?`），所以不能用
       *    `Future.wait` 混在一个列表里 —— 那会被推断成 `List<Object?>`，
       *    取出来还得强转。用记录 `(a, b).wait` 解构，类型各自保留。
       *
       * ⚠️ `provider_session_state` 的真实返回类型是
       *    `Result<Option<SessionState>, String>` —— 一个**字符串**
       *    （`"active"` / `"not_required"` / …）或 null，**不是对象**。
       *    所以这里**必须**用 [SourinApi.providerSessionStateWire]：
       *    `SourinApi.providerSessionState` 的签名写成了 `Map?`，
       *    `jmapOrNull("active")` 会抛「期望对象，实际收到 String」，
       *    而那条路径被 `catchError` 吞掉 → `_state` 永远是 null →
       *    **UI 永远显示"无需登录"**，连 `expired` 都不提示。
       *    又是一个静默失效（细节见 `sourin_api.dart` 里
       *    `providerSessionStateWire` 的注释）。
       */
      /*
       * ★★★ 2026-09-25（task-38 复核）：`debugSessionStateOverride` 改成
       *     **不提前 return**，而是"跳过 FFI、继续走下面同一段 setState"
       *
       * # 为什么必须这样（实测抓到的**假绿**）
       *
       * 原来的写法是提前 return：
       * ```dart
       * if (override != null) {
       *   setState(() { _state = override; _loading = false; });
       *   return;                                   // ★ 到此为止
       * }
       * ```
       * 于是**下面那段 setState 永远不执行** —— 而
       * 「expired 时不自动展开」这个被测行为，恰恰就在那段里。
       *
       * ⇒ 用 override 测 `expired` 时，走的是**短路分支**，
       *   **不是**真实代码路径 ⇒ 把 `if (_state == expired) _open = true;`
       *   恢复回去，测试**照样绿**（实测确认：变异 s1 ⇒ GREEN）。
       *
       * ★ 这是"可达性"的**第三层**：
       * ```text
       * ① 对象存在（面板渲染出来了）      —— 另一个代理发现（_loading 永真）
       * ② 状态可达（expired 能构造出来）  —— 上一轮发现
       * ③ ★ 代码路径可达（被测那段真的执行）—— 本次发现
       * ```
       * 「状态对」≠「被测代码被执行」。
       *
       * # 修法：一个出口
       *
       * 让 override 只**替换数据来源**，后续解析/赋值/日志**全部共用**：
       * ⇒ 测的就是真代码；而且天然覆盖 `_session == null` 时的 label 分支。
       *
       * ⚠️ `override.wire` 必须与 `SessionState.parse()` 的输入格式一致
       *    （就是 `'active'` / `'expiring'` / `'expired'` / `'not_required'`
       *     那几个字符串 —— 见 `SessionState` 枚举的 `wire` 字段）。
       *    ★ 已核实：`SessionState.expired.wire == 'expired'`，
       *      而 `SessionState.parse('expired') == SessionState.expired`。
       */
      final override = widget.debugSessionStateOverride;
      final (s, st) = override != null
          // ★ 测试注入：不碰 FFI，但**继续走下面同一段** setState
          ? (null as Map<String, dynamic>?, override.wire as String?)
          : await (
              SourinApi.providerSession(widget.providerId)
                  .catchError((_) => null),
              SourinApi.providerSessionStateWire(widget.providerId)
                  .catchError((_) => null),
            ).wait;

      if (!mounted) return;
      setState(() {
        _session = s;
        _state = st is String
            ? SessionState.parse(st)
            // 拿不到状态时：有会话就当 active，否则 notRequired
            : ((s != null) ? SessionState.active : SessionState.notRequired);
        /*
         * ★★★ 2026-09-25（task-38）：**删掉**了「失效时自动展开」
         *
         * 原代码是：
         * ```dart
         * // 失效时自动展开（用户进来就是要处理它）
         * if (_state == SessionState.expired) _open = true;
         * ```
         * 那句注释里的假设（"用户进来就是要处理它"）**是错的** ——
         * 用户进设置页多半只是在**逛**，不是遇到了播不了的片。
         *
         * # 用户原话（本次反馈）
         *
         * > 像次元城支持自动登录的应该**无感登录**，哔哩哔哩如果遇到片源
         * > 需要会员或者登录，**这时候才提示出来**（账号过期也是同理）
         *
         * 即：**提示的触发点应该是「内容需要」，不是「会话状态」**。
         *
         * # 为什么两种状态都不该自动展开
         *
         * ```text
         * canAutoLogin = true（次元城）
         *   → 用户**永远不需要动手**：点播时 ensure_session() 会自动重登
         *     （实测 0.46 秒成功）
         *   → 自动展开纯属打扰。更糟的是：它配上旧文案
         *     「需重新登录（可能需要验证码，请手动完成）」——
         *     用户以为要人工介入，实际什么都不用做。**这正是 Owner 报的 bug。**
         *
         * canAutoLogin = false（B站这类）
         *   → 用户**此刻**也不用动手 —— 他只是在逛设置页。
         *     真要动手的时刻是**播放失败那一刻**（`player_page` 的失败页
         *     会给「登录」按钮，那条路径本来就有）。
         * ```
         *
         * # ⚠️ 但入口（「登录」按钮）**保留**
         *
         * 这是「**提供入口**」和「**主动打扰**」的区别：
         * ```text
         * 删掉自动展开  → 用户想登录时自己点「登录」（按钮一直画在状态行右侧）
         * 连入口都删掉  → 用户找不到地方登录（那才是 bug）
         * ```
         * 所以这里**只**不自动展开；`_open` 仍由用户点击切换（见 build 里那个
         * `TextButton`），`defaultOpen`（失败页弹窗传 true）也仍然生效。
         */
        /*
         * ★ 默认页签：插件声明了 `login_qr_supported` 就落扫码页签。
         *
         * ⚠️⚠️ 这句**必须**只跑一次（caps 刚解析出来的这一刻）。
         *
         * 它一度写在 `build()` 里，结果是：每次重建都把 `_tab` 掰回 `'qr'` ⇒
         * 用户点「其它方式」**根本切不过去**（切了立刻被下一次 build 掰回来）。
         * 这是 t526 设备端探针实测抓到的缺陷：点完「其它方式」后
         * `TextField` 数 = 0，Cookie 表单永远出不来 —— 而 B站 插件自己的
         * `login_hint` 恰恰写着「若扫码不可用，也可以切到「Cookie 导入」」。
         *
         * 原版（SettingsView.vue:202）也是**开弹窗时设一次**：
         * ```ts
         * loginTab.value = p.capabilities.login_qr_supported ? "qr" : "form";
         * ```
         * 不是每次渲染都设 ⇒ 挪到这里是**还原原版行为**，不是新设计。
         */
        if (_caps.loginQrSupported) _tab = 'qr';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '$e';
        _loading = false;
      });
    }
  }

  /// 状态 → 展示文案（把技术状态翻译成用户能懂的话）
  ///
  /// 照抄原版 `stateOf()`，**包含那个 `not_required` 的细分**。
  ({String label, String hint, Tone tone}) get _display {
    switch (_state ?? SessionState.notRequired) {
      case SessionState.active:
        return (label: '已登录', hint: '', tone: Tone.ok);

      case SessionState.expiring:
        /*
         * ★★★ 2026-09-24 修：这里原来无条件说「令牌将在到期前自动续期，无需操作」
         *
         * 用户报「次元城明明已登录了，也提示未登录」+「显示已登录但实际不能播」。
         * 根因是 Rust 侧把「**已经过期**」和「**即将过期**」都报成 `expiring`
         * （见 `provider.rs::session_needs_refresh` 的说明），
         * 而这里又把它渲染成「已登录 · 无需操作」——
         * 于是 token 已经死了 11 个小时，界面还笃定地说一切正常。
         *
         * Rust 侧已修（真过期且无法自动重登 → `expired`），
         * 但 `expiring` 这个状态**本身仍然涵盖两种情况**，文案必须同时成立：
         * ```text
         * ① 即将过期      → 宿主会提前续期，用户确实不用动手
         * ② 已过期但有凭据 → 宿主会在点播时自动重登，用户也不用动手
         * ```
         * 两者共同点是「**不用你动手**」，所以保留 `Tone.ok`；
         * 但措辞不能再是「无需操作」那种"什么都没发生"的口吻 ——
         * 万一自动恢复失败，用户至少知道该去哪、该期待什么。
         */
        return (
          label: '已登录',
          hint: '登录状态需要刷新，播放时会自动恢复；若仍提示登录失效，请点下方重新登录',
          tone: Tone.ok,
        );

      case SessionState.notRequired:
        /*
         * ★★★ 这两种**必须分开**（原版专门修过的 bug）
         *
         * > ⚠️ 给 B站 显示「无需登录」是**错的** ——
         * >    它旁边就有个「登录」按钮，用户会以为是 bug。
         */
        return _caps.loginSupported
            ? (label: '游客可用', hint: '不登录也能播放；登录后可同步关注与收藏', tone: Tone.ok)
            : (label: '无需登录', hint: '', tone: Tone.ok);

      case SessionState.expired:
        /*
         * ★ `expired` 有两种语义，**必须分开说**（照抄原版
         *   `SettingsView.vue:2280-2283`）：
         * ```text
         * login_required = true  → 「该源需要登录后才能播放」
         *                          （如 cycani：从来没登录过，或登录失效了）
         * login_required = false → 「登录已失效」
         *                          （如 B站：游客本来能用，只是登录态过期了）
         * ```
         * ⚠️ 对 B站 说「需要登录后才能播放」是错的 —— 它不登录也能看
         *    1080P（Owner 明确要的能力）。反过来对 cycani 说「登录已失效」
         *    会让从没登录过的用户以为"我什么时候登录过？"。
         *
         * ★★★ 2026-09-24 补：光看 `login_required` **还不够**
         *
         * 用户报「明明已登录了，也提示未登录」。cycani 的 `login_required`
         * 恒为 true，所以它**登录过、且刚失效**时也会说「该源需要登录后才能播放」——
         * 用户看到的是一句"从没登录过"的口吻，跟他记忆里的"我刚登录过"冲突，
         * 于是困惑（这正是用户原话里那个「也提示未登录」）。
         *
         * 判据补上**有没有会话**（`_session != null` = 确实登录过）：
         * ```text
         * 有会话但已失效 → 「登录已失效」   （说清发生了什么）
         * 从来没有会话   → 「需要登录」     （引导第一次登录）
         * ```
         * 两者都带 `Tone.err` 和登录入口，只是措辞不同。
         */
        if (_caps.loginRequired && _session == null) {
          return (label: '需要登录', hint: '该源需要登录后才能播放', tone: Tone.err);
        }
        /*
         * ★★★ 2026-09-25 修（task-38）：按**能力位**分两种文案
         *
         * # Owner 报的问题（原话）
         *
         * > 次元城登录失效 明明不需要验证码就可以自动登录，还提示 验证码
         *
         * # 实测诊断（探针 `.probe` + `tests/zz_t38_*`）
         *
         * 自动重登链路**一直是好的**（用真实凭据实测）：
         * ```text
         * can_auto_login() → true
         * auto_login()     → Ok(Some)    ← 真的成功，0.46 秒
         * ensure_session() → Some(true)  ← 且磁盘写回了新 token
         * ```
         * ★ 用户看到「可能需要验证码」的时刻是：**token 已死、但还没点播**
         *   （`session_state()` 那时确实返回 `Expired`）。
         *   他**只要点一下播放**，宿主就自动重登 → 就能播了。
         *   ⇒ 他什么都不用做，文案却叫他「请手动完成」—— **这是误导**。
         *
         * # 为什么按能力位而不是写死 provider id
         *
         * 「有账号密码就能自动重登」是**插件自身的能力**（它实现了
         * `autoLogin()`）。写死 `id == 'cycani'` 会让下一个类似插件
         * （用户自己写的、也实现了 `autoLogin`）继续看到"验证码"。
         *
         * # 两种文案的取舍依据
         *
         * ```text
         * canAutoLogin = true  → 「正在自动重新登录，直接播放即可恢复」
         *                        ★ 不带"验证码"，且**告诉用户不用动手**
         *                        ⚠️ 措辞是"直接播放即可恢复"而**不是**
         *                           "我们已经帮你重登了" —— 重登发生在
         *                           **点播那一刻**，说"已经"就是第二种撒谎
         * canAutoLogin = false → 保留原版通用文案
         *                        （对真有验证码的源，那句是**对的**）
         * ```
         */
        // ★ 判据抽在 `expiredHintFor()` 里（顶层纯函数，可运行时验证）
        return expiredHintFor(_caps);
    }
  }

  /// 登录
  Future<void> _login() async {
    // 需要账号时账号不能空（原版行为）
    if (_caps.loginNeedsUsername && _userCtrl.text.trim().isEmpty) {
      setState(() => _err = '请填账号');
      return;
    }
    if (_passCtrl.text.isEmpty) {
      setState(() => _err = '请填密码或粘贴 Cookie');
      return;
    }
    setState(() {
      _busy = true;
      _err = '';
      _ok = '';
    });
    try {
      final r = await SourinApi.providerLogin(
        widget.providerId,
        _userCtrl.text.trim(),
        _passCtrl.text,
      );
      if (!mounted) return;
      setState(() {
        _session = r.isEmpty ? null : r;
        _state = SessionState.active;
        _busy = false;
        _ok = '登录成功';
        // 登录成功后清掉密码框（凭据已进钥匙串，没必要留在内存里）
        _passCtrl.clear();
        _open = false;
      });
      // ★ 通知调用方（播放失败页据此自动重试）
      widget.onLoggedIn?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '登录失败：$e';
        _busy = false;
      });
    }
  }

  /// 登出
  Future<void> _logout({required bool forget}) async {
    setState(() {
      _busy = true;
      _err = '';
      _ok = '';
    });
    try {
      await SourinApi.providerLogout(widget.providerId);
      /*
       * ★ 「忘记凭据」是**额外**的一步（原版把它做成两个按钮）
       *
       * 后端注释：
       * > 优先走插件的 `forgetCredentials()` —— 插件把凭据存在自己的
       * > 私有存储里（`plugins/.data/<id>.json`），不是系统钥匙串。
       *
       * 区别：
       * ```text
       * 登出    服务端令牌失效，但本机还留着账号 → 下次能自动恢复
       * 忘记    连本机凭据一起删 → 下次必须重新输入
       * ```
       */
      if (forget) {
        await SourinApi.forgetProviderCredentials(widget.providerId);
      }
      if (!mounted) return;
      setState(() {
        _session = null;
        _state = SessionState.notRequired;
        _busy = false;
        _ok = forget ? '已登出并清除本机凭据' : '已登出';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '登出失败：$e';
        _busy = false;
      });
    }
  }

  // ═══ 扫码登录（支持 login_qr_supported 的源，例如 B站）═══

  /// 切到扫码页签。第一次切过去才申请二维码（原版 switchToQr 的等价物）
  void _switchToQr() {
    setState(() {
      _tab = 'qr';
      _err = '';
    });
    if (_qr == null && !_qrBusy) unawaited(_startQrLogin());
  }

  /// 切回表单页签。★ 必须停轮询 —— 用户已经不用二维码了，
  /// 还继续打 poll 接口是风控风险 + 无谓流量。
  void _switchToForm() {
    _stopQrPolling();
    setState(() {
      _tab = 'form';
      _err = '';
    });
  }

  /// 申请二维码。逐条对应原版 startQrLogin()：
  /// · 先停掉可能在跑的轮询（幂等）
  /// · 申请失败只报错，不自动重试（重试由用户点「重新获取二维码」）
  Future<void> _startQrLogin() async {
    _stopQrPolling();
    if (mounted) {
      setState(() {
        _qrBusy = true;
        _qrDone = false;
        _qrMsg = '';
        _err = '';
      });
    }
    try {
      final r = await SourinApi.providerQrLoginStart(widget.providerId);
      if (!mounted) return;
      final key = (r['key'] as String?) ?? '';
      setState(() {
        _qr = r;
        _qrMsg = key.isEmpty ? '二维码获取失败，请重试或切换到「其它方式」。' : '等待扫码…';
      });
      if (key.isNotEmpty) _startQrPolling(key);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _qr = null;
        _qrMsg = '二维码获取失败，请重试或切换到「其它方式」。';
      });
    } finally {
      if (mounted) setState(() => _qrBusy = false);
    }
  }

  /// 起 2 秒一次的轮询（幂等：先停旧的）。
  ///
  /// ★ 为什么是 2 秒（原版 SettingsView.vue:289-305 注释）：
  ///   B站 poll 接口返回 ttl: 1，二维码有效期约 180 秒，
  ///   2 秒一次约 90 次足够及时；1 秒太密有风控风险。
  void _startQrPolling(String key) {
    _stopQrPolling();
    _qrTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_pollQrOnce(key));
    });
  }

  void _stopQrPolling() {
    _qrTimer?.cancel();
    _qrTimer = null;
    _qrPolling = false;
  }

  /// 轮询一次。
  ///
  /// ★★★ try 只包住 providerQrLoginPoll 这**一个**网络调用 ——
  ///   原版在这里踩过 Owner 实测报的真 bug（SettingsView.vue:312-334）：
  ///   原来整个流程都在一个 try 里（含成功分支的副作用），于是登录其实
  ///   成功了、但后续任一步抛错就被 catch 抓住，界面把「登录成功」覆盖成
  ///   「网络异常，重试中…」，而轮询已经停了不再恢复 ⇒
  ///   用户看到「扫了 → 说网络异常 → 卡住」。用户原话：
  ///   > 我刚扫了 然后就提示网络异常
  ///   所以：网络失败 ⇒ 只改文案、**继续轮询**；成功分支的副作用一律
  ///   放在 try 外面，且不再让它们能把成功状态改回去。
  Future<void> _pollQrOnce(String key) async {
    if (!mounted || _qrPolling) return;
    _qrPolling = true;
    Map<String, dynamic> res;
    try {
      res = await SourinApi.providerQrLoginPoll(widget.providerId, key);
    } catch (_) {
      _qrPolling = false;
      if (mounted) setState(() => _qrMsg = '网络异常，重试中…');
      return;
    }
    _qrPolling = false;
    if (!mounted) return;

    final status = (res['status'] as String?) ?? '';
    final message = (res['message'] as String?) ?? '';

    if (status == 'confirmed') {
      // 先停轮询，再改状态：顺序反了会多打一次接口
      _stopQrPolling();
      setState(() {
        _session =
            (res['session'] as Map?)?.cast<String, dynamic>() ?? _session;
        _state = SessionState.active;
        _qrDone = true;
        _qrMsg = '登录成功';
        _ok = '登录成功';
        /*
         * 原版是「延迟 900ms 再关弹窗」（SettingsView.vue:372-375 注释：
         * 立刻关会让人怀疑到底成功了没）。这里没有独立弹窗可关，等价物是
         * 收起页签区 —— 而成功文案由状态行下方常驻的 _ok 承载（不会闪一下
         * 就消失），所以不需要额外的延时定时器。
         */
        _open = false;
        _tab = 'form';
      });
      widget.onLoggedIn?.call();
      return;
    }

    if (status == 'expired' || status == 'failed') {
      _stopQrPolling();
      setState(() {
        _qrMsg = message.isNotEmpty
            ? message
            : (status == 'expired' ? '二维码已失效' : '登录失败');
      });
      return;
    }

    // pending / scanned：继续轮询，只刷新文案
    setState(() => _qrMsg = message.isNotEmpty ? message : _qrMsg);
  }

  Widget _buildQrTab(FColors colors) {
    // 第一次切到扫码页签时自动申请一次（原版 switchToQr 里的
    // if (!qrData && !qrBusy) startQrLogin();）。
    // 放在 postFrame 里：build 期间不能 setState。
    if (_qr == null && !_qrBusy && _qrMsg.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _tab == 'qr' && _qr == null && !_qrBusy) {
          unawaited(_startQrLogin());
        }
      });
    }

    if (_qrBusy) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.x4),
        child: Column(
          children: [
            const SizedBox(
              width: 200,
              height: 200,
              child: CircularProgressIndicator(),
            ),
            const SizedBox(height: Sp.x3),
            Text(
              '正在获取二维码…',
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: colors.mutedForeground,
              ),
            ),
          ],
        ),
      );
    }

    final svg = (_qr?['svg'] as String?) ?? '';
    final url = (_qr?['url'] as String?) ?? '';
    final hint = (_qr?['hint'] as String?) ?? '';
    final expired = _qrMsg.contains('失效');
    final failed = _qrMsg.contains('获取失败');

    return Padding(
      padding: const EdgeInsets.only(top: Sp.x2),
      child: Column(
        children: [
          if (svg.isNotEmpty)
            /*
             * ★ 必须给**白底**（原版 SettingsView.vue:4053-4059 注释）：
             *   不给白底的话圆角外面会露出深色底，扫码识别率下降。
             */
            Container(
              width: 200,
              height: 200,
              padding: const EdgeInsets.all(Sp.x2),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              child: QrView(
                svg: svg,
                size: 184,
                fallback: const Text(
                  '二维码不可用',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: Colors.black54,
                  ),
                ),
              ),
            )
          else if (url.isNotEmpty) ...[
            Text(
              '二维码渲染失败，请手动访问：',
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: colors.mutedForeground,
              ),
            ),
            const SizedBox(height: Sp.x1),
            SelectableText(
              url,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: FontSizes.cap,
                height: 1.5,
                color: colors.foreground,
              ),
            ),
          ] else
            Text(
              '二维码获取失败，请重试或切换到「其它方式」。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: FontSizes.cap,
                height: 1.5,
                color: colors.error,
              ),
            ),
          if (_qrMsg.isNotEmpty) ...[
            const SizedBox(height: Sp.x2),
            Text(
              _qrMsg,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: FontSizes.cap,
                height: 1.5,
                color: _qrDone
                    ? colors.primary
                    : (expired ? colors.error : colors.mutedForeground),
              ),
            ),
          ],
          if (hint.isNotEmpty) ...[
            const SizedBox(height: Sp.x2),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: FontSizes.cap,
                height: 1.5,
                color: colors.mutedForeground,
              ),
            ),
          ],
          /*
           * 「重新获取二维码」只在**失效 / 获取失败**时给 ——
           * 等待中给按钮会让用户以为要手动刷新（原版 SettingsView.vue:3123 注释）。
           */
          if (expired || failed) ...[
            const SizedBox(height: Sp.x2),
            TextButton(
              onPressed: _qrBusy ? null : () => unawaited(_startQrLogin()),
              child: const Text('重新获取二维码'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _tabButton({
    required FColors colors,
    required String label,
    required bool on,
    required VoidCallback onTap,
  }) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        backgroundColor: on ? colors.primary : Colors.transparent,
        foregroundColor: on ? colors.primaryForeground : colors.foreground,
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: Sp.x1),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.full),
        ),
        textStyle: const TextStyle(fontSize: FontSizes.sm),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(label),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = FTheme.of(context).colors;

    // 这个源压根不需要登录 → 不渲染（不是显示一个用不了的按钮）
    if (!_loading && !_caps.showLoginEntry) return const SizedBox.shrink();

    if (_loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.x2),
        child: Text(
          '登录状态读取中…',
          style: TextStyle(
            fontSize: FontSizes.cap,
            color: colors.mutedForeground,
          ),
        ),
      );
    }

    final d = _display;
    final loggedIn =
        _session != null &&
        (_state == SessionState.active || _state == SessionState.expiring);

    /*
     * ★ 页签渲染由能力决定：插件声明了 login_qr_supported 才画页签行，
     * 否则只有表单页签（这时整行都不渲染，见下面那段）。
     *
     * ⚠️ `_tab` 的**默认值不在这里设** —— 它只在 `_load()` 尾巴设一次。
     *    写在 build() 里会在每次重建时把 `_tab` 掰回 `'qr'`，
     *    用户点「其它方式」根本切不过去（t526 设备探针实测抓到的缺陷：
     *    点完 TextField 数 = 0，Cookie 表单永远出不来）。
     */

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 状态行 ──
        Row(
          children: [
            Icon(
              loggedIn ? Icons.person_outline : Icons.person_off_outlined,
              size: 14,
              color: d.tone == Tone.err
                  ? colors.error
                  : (loggedIn ? colors.primary : colors.mutedForeground),
            ),
            const SizedBox(width: 6),
            Text(
              d.label,
              style: TextStyle(
                fontSize: FontSizes.cap,
                fontWeight: loggedIn ? FontWeight.w600 : FontWeight.w400,
                color: d.tone == Tone.err
                    ? colors.error
                    : (loggedIn ? colors.primary : colors.mutedForeground),
              ),
            ),
            // 昵称/头像（有会话时显示）
            if (_session?['display_name'] is String &&
                (_session!['display_name'] as String).isNotEmpty) ...[
              const SizedBox(width: 6),
              Text(
                _session!['display_name'] as String,
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: colors.foreground,
                ),
              ),
            ],
            const Spacer(),
            if (loggedIn)
              TextButton(
                onPressed: _busy ? null : () => _logout(forget: false),
                child: const Text('登出'),
              )
            else
              TextButton(
                onPressed: _busy ? null : () => setState(() => _open = !_open),
                child: Text(_open ? '收起' : '登录'),
              ),
          ],
        ),

        // 状态提示（`expiring` 与 `expired` 的说明）
        if (d.hint.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 20, top: 2),
            child: Text(
              d.hint,
              style: TextStyle(
                fontSize: FontSizes.cap,
                height: 1.5,
                color: d.tone == Tone.err
                    ? colors.error
                    : colors.mutedForeground,
              ),
            ),
          ),

        // ── 登录表单 / 扫码 ──
        if (_open && !loggedIn) ...[
          const SizedBox(height: Sp.x2),
          /*
         * 页签行**只在插件支持扫码时**渲染（原版 SettingsView.vue:3066 注释：
         * 不支持的话只有一个页签，显示出来纯属噪音）。
         * 文案用「扫码登录」/「其它方式」（原版逐字）—— 不能用「收起」，
         * 那两个字被 test/t38_login_autosopen_test.dart 的 _isExpanded() 当作判据。
         */
          if (_caps.loginQrSupported)
            Padding(
              padding: const EdgeInsets.only(top: Sp.x2),
              child: Row(
                children: [
                  Expanded(
                    child: _tabButton(
                      colors: colors,
                      label: '扫码登录',
                      on: _tab == 'qr',
                      onTap: _switchToQr,
                    ),
                  ),
                  const SizedBox(width: Sp.x1),
                  Expanded(
                    child: _tabButton(
                      colors: colors,
                      label: '其它方式',
                      on: _tab == 'form',
                      onTap: _switchToForm,
                    ),
                  ),
                ],
              ),
            ),

          if (_tab == 'qr')
            _buildQrTab(colors)
          else ...[
            /*
           * ★ 插件自带的登录说明（`login_hint`）**必须显示**
           *
           * 后端注释举例：
           * > 例：B站要「从浏览器复制 Cookie 粘进来」，不写清楚用户不知道做什么。
           */
            if ((_caps.loginHint ?? '').isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(Sp.x2),
                decoration: BoxDecoration(
                  color: colors.secondary,
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 13,
                      color: colors.mutedForeground,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _caps.loginHint!,
                        style: TextStyle(
                          fontSize: FontSizes.cap,
                          height: 1.5,
                          color: colors.foreground,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Sp.x2),
            ],

            /*
           * ⚠️ 账号框按 `loginNeedsUsername` 显示
           *
           * 后端注释：
           * > B站的 Cookie 导入**不需要账号**，只有密码框（用来粘 Cookie）。
           * > 设 false 时前端隐藏账号框，也**不再要求它非空**
           * > （否则登录按钮永远是禁用状态）。
           *
           * ⚠️ 这个字段的默认值是 **true**（Rust `#[serde(default = "default_true")]`）
           *    —— 判据写反会让所有老插件都不显示账号框。
           */
            if (_caps.loginNeedsUsername) ...[
              _input(controller: _userCtrl, colors: colors, hint: '账号'),
              const SizedBox(height: Sp.x2),
            ],
            _input(
              controller: _passCtrl,
              colors: colors,
              hint: _caps.loginNeedsUsername ? '密码' : '粘贴 Cookie',
              obscure: _caps.loginNeedsUsername,
              // 不要求账号时，密码框可以很大（Cookie 串很长）
              maxLines: _caps.loginNeedsUsername ? 1 : 4,
            ),

            const SizedBox(height: Sp.x2),
            Row(
              children: [
                FilledButton(
                  onPressed: _busy ? null : _login,
                  child: Text(_busy ? '登录中…' : '登录'),
                ),
                const SizedBox(width: Sp.x2),
                /*
               * 「忘记凭据」只在**曾经登录过**时才有意义 ——
               * 从没登录过的源上显示它，用户不知道会发生什么。
               * （`expired` 说明曾经登录过但现在失效了）
               */
                if (_state == SessionState.expired)
                  TextButton(
                    onPressed: _busy ? null : () => _logout(forget: true),
                    child: const Text('清除本机凭据'),
                  ),
              ],
            ),
          ],
        ],

        if (_err.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Sp.x2),
            child: Text(
              _err,
              style: TextStyle(
                fontSize: FontSizes.cap,
                height: 1.5,
                color: colors.error,
              ),
            ),
          ),
        if (_ok.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Sp.x2),
            child: Text(
              _ok,
              style: TextStyle(fontSize: FontSizes.cap, color: colors.primary),
            ),
          ),
      ],
    );
  }

  Widget _input({
    required TextEditingController controller,
    required FColors colors,
    required String hint,
    bool obscure = false,
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      maxLines: maxLines,
      style: const TextStyle(fontSize: FontSizes.sm),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(
          fontSize: FontSizes.sm,
          color: colors.mutedForeground,
        ),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Sp.x3,
          vertical: Sp.x3,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
      ),
    );
  }
}

/// ★ 就地弹出登录框，登录成功后回调（2026-09-24 新增）
///
/// # 为什么要有这个函数（用户原话）
///
/// > 我要求在这个页面也要显示出来 **登录** 按钮，点击可以进行**直接登录**
///
/// 用户是在**播放失败页**看到「登录已失效」的。让他「返回 → 进设置页 →
/// 找到那个源 → 展开 → 输入账号密码」是四步；就地弹窗是一步。
/// 失败页本来就已经把上下文（哪个源）拿在手上了，没有理由再让用户自己找回去。
///
/// # 为什么是弹窗而不是复用设置页
///
/// `ProviderLoginPanel` 本身是**嵌在设置页卡片里**的组件，
/// 直接塞进播放页会带上卡片的布局假设。包一层 `Dialog` 反而更简单，
/// 且面板内部逻辑（扫码页签 / Cookie 粘贴 / 自动展开）**一行都不用改**。
///
/// ⚠️ 用 `material_ui` 的 `Dialog` 而不是 forui 的 `FDialog`：
///    `FDialog` 的构造签名是 `builder(context, style)`（没有 `title`/`body`），
///    而本项目的既有弹窗（`source_switch_dialog` / `skip_marker_dialog`）
///    统一用 `Dialog` + `Theme.of(context).colorScheme`。**跟随既有惯例**，
///    免得同一屏里两种弹窗风格打架。
///
/// # 返回
/// `true` = 登录成功；`false` = 用户取消或没登录成功
/// （调用方据此决定要不要重试播放 —— 没登录成功就重试是白费一次请求）
Future<bool> showProviderLoginDialog(
  BuildContext context, {
  required String providerId,
  required String providerName,
}) async {
  var ok = false;
  await showAppDialog<void>(
    context: context,
    builder: (ctx) {
      final colors = Theme.of(ctx).colorScheme;
      return Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            clipBehavior: Clip.antiAlias,
            padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x5, Sp.x5, Sp.x4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '登录 $providerName',
                  style: TextStyle(
                    fontSize: FontSizes.lg,
                    fontWeight: FontWeights.semibold,
                    color: colors.onSurface,
                  ),
                ),
                const SizedBox(height: Sp.x2),
                Text(
                  '该源需要登录后才能播放。登录成功后会自动重试播放。',
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    height: 1.5,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: Sp.x4),
                ProviderLoginPanel(
                  providerId: providerId,
                  providerName: providerName,
                  // 失败页点进来就是要登录，直接展开表单，省掉一次点击
                  defaultOpen: true,
                  onLoggedIn: () => ok = true,
                ),
                const SizedBox(height: Sp.x3),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: Text(ok ? '完成' : '关闭'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
  return ok;
}
