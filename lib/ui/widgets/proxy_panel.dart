// ═══════════════════════════════════════════════════════════════════════
//  站点代理配置面板（**每个内容源卡片内嵌一个**）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要做成"跟随插件"的独立组件（原版 Owner 的要求）
//
// 原版 `ProviderProxy.vue` 文件头原话：
// > Owner 原话：
// > > 设置代理那里我希望配置跟随插件，而不是在下面单独开一个
// >
// > 原来设置页有一个**独立的「站点代理」区块**，把所有源列在一个长列表里。
// > 问题很明显：
// > ```text
// > 用户想给「哔哩哔哩」配代理
// >   → 得先滚到「内容源」区块找到它（确认它存在、是启用的）
// >   → 再滚到下面的「站点代理」区块，在另一个列表里再找一次它
// >   → 两个列表的顺序还不一定一样
// > ```
// > 也就是「同一个东西的信息分散在两处」—— 用户要在脑子里做一次 join。
//
// 所以这个 widget 的用法是**嵌在源卡片里**：
// ```dart
// _ProviderTile(
//   provider: p,
//   ...,
//   // 卡片底部：
//   ProxyPanel(providerId: p.id, providerName: p.name),
// )
// ```
//
// # 设计取舍（照抄原版）
//
// · **默认折叠** —— 绝大多数源用直连，全展开会让列表变得很长。
//   折叠时只显示一行摘要（"直连" / "跟随系统" / "自定义"），
//   一眼能看出**哪些源配了代理**（那才是需要关注的信息）。
// · **已配置的自动展开** —— 用户配过的说明他在意。
// · **密码不回显** —— 只显示"已保存密码"，留空表示不修改。
//   凭据存系统钥匙串，不落库（原版注释：也就"不进备份"）。
//
// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 曾经在这里"绕开"的模型 bug ① —— **已修复，绕行方案已撤除**
// ═══════════════════════════════════════════════════════════════════════
//
// # 原来为什么绕（历史，留着是为了不再犯）
//
// `lib/core/models.dart` 的 `ProxyConfig` 与 Rust 后端**字段对不上**：
//
// ```text
// Dart(旧)  ProxyConfig{enabled, url, username, hasPassword}
//           toJson() → {"enabled": true, "url": "...", "username": "..."}
//
// Rust      ProxyConfig{mode, url, bypass, scope, username}
//           #[serde(default)] on every field, 无 deny_unknown_fields
// ```
//
// 后果（**静默失效，没有任何报错**）：
// ```text
// ① 发出去的 "enabled" 被 serde 忽略
// ② 后端 mode 取默认值 Direct
// ③ ProxyConfig::uses_proxy() 返回 false
// ④ → **代理永远不生效** —— 用户以为配好了，实际还是直连
// ```
// 读取方向同样是坏的：`fromJson` 读 `enabled`，而后端从不下发这个字段
// → 已配置的代理在 UI 上永远显示"未启用"。
//
// 当时这里定义了一个局部模型 `ProxyCfg` 并直接调 `SourinCore.callAsync`
// 绕开它（真机实测复现：绕行 `mode=custom` ✓ / 走 SourinApi `mode=direct` ✗）。
//
// # 现在
//
// `models.dart` 的 `ProxyConfig` 已按 `rust/sourin_core/src/proxy.rs:90-107`
// 修成 `{mode, url, bypass, scope, username}`，并带上 `ProxyMode` /
// `ProxyScope` 两个枚举与 `isActive`（= Rust `uses_proxy()`）。
// 所以本文件**回到正常路径**：
//
// ```text
// 读 → SourinApi.proxyConfigFor(id)         （全量 list 里取，命令没有单查版）
// 写 → SourinApi.setProxyConfig(id, cfg)    （payload 与 Rust 逐字对齐）
// 密码 → SourinApi.setProxyPassword / hasProxyPassword（**单独走钥匙串**）
// 测试 → SourinApi.testProxy（测试前先保存，否则测的是旧配置）
// 系统提示 → SourinApi.systemProxyHint
// ```
//
// ⚠️ 局部模型 `ProxyCfg` **已删除** —— 留着一个"正确但与 `models.dart`
//    并行的"模型，下次字段变更就会改一处漏一处（这正是当初那个 bug 的形态）。
//    唯一来源是 `models.dart::ProxyConfig`。

import 'package:material_ui/material_ui.dart';

import '../../core/sourin_api.dart';
import '../tokens.dart';
import '../../ui/app_palette.dart';

// ═══════════════════════════════════════════════════════════════════════
//  组件
// ═══════════════════════════════════════════════════════════════════════

/// 站点代理面板（嵌在源卡片里）
class ProxyPanel extends StatefulWidget {
  const ProxyPanel({
    super.key,
    required this.providerId,
    required this.providerName,
    this.defaultOpen = false,
  });

  /// 源 / 插件的 id
  final String providerId;

  /// 显示名（仅用于无障碍标签与提示文案）
  final String providerName;

  /// 初始就展开
  ///
  /// 原版注释（`ProviderProxy.vue` L56-67）：
  /// > ★ 2026-09-21 补上 —— 这个 prop 在 `open` 的注释里被提到过，
  /// >   但**一直没实现**（注释先于代码）。弹窗版代理配置需要它：
  /// >   用户点「配置」按钮进来，就是要配代理，
  /// >   再让他点一次「代理 ▾」才看到控件是多余的一步。
  ///
  /// ⚠️ 与「已配置的自动展开」是**两件事**，取或的关系。
  final bool defaultOpen;

  @override
  State<ProxyPanel> createState() => _ProxyPanelState();
}

class _ProxyPanelState extends State<ProxyPanel> {
  ProxyConfig? _cfg;
  bool _loading = true;
  String _err = '';

  /// 折叠状态
  ///
  /// 展开条件（取或）：
  /// ```text
  /// defaultOpen          调用方要求（弹窗场景）
  /// cfg.isConfigured     用户已经配过 → 自动展开，省一次点击
  /// ```
  /// ⚠️ 因为要等 `_cfg` 拉回来才知道 `isConfigured`，
  ///    所以 `_open` 初始用 `defaultOpen`，拉到数据后再补判一次。
  bool _open = false;

  /// 密码输入（**不回显已有密码**；留空 = 不修改）
  final _passCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _bypassCtrl = TextEditingController();

  bool _testing = false;
  ProxyTestResult? _testResult;

  /// 系统代理提示（检测到环境变量代理时给用户一条提示）
  String? _sysHint;

  @override
  void initState() {
    super.initState();
    _open = widget.defaultOpen;
    _load();
    _loadSysHint();
  }

  @override
  void dispose() {
    _passCtrl.dispose();
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _bypassCtrl.dispose();
    super.dispose();
  }

  /// ── 走 `SourinApi`（模型已修好，见文件头）──
  ///
  /// ⚠️ 这里**不再**有 `_call(cmd, args)` 那种裸 FFI 包装 ——
  ///    它当初存在的唯一理由是绕开字段错位的 `ProxyConfig`。
  ///    现在字段对了，包装就变成"第二个契约"（命令名/参数名分散在两处），
  ///    所以撤掉，全部走 `SourinApi`。

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = '';
    });
    try {
      /*
       * ★ 读某一源的配置 + 密码标记 —— 一次往返拿全
       *
       * ⚠️ 没有 `get_proxy_config` 这个命令（只有全量的
       *    `list_proxy_configs`，Rust 签名是
       *    `HashMap<providerId, ProxyConfig>`）。
       *    `SourinApi.proxyConfigWithPassword` 内部按 id 取并并行查密码。
       *
       * ★★★ 任务 AE：它内部现在**走共享缓存**（`ProxyCache`）
       *
       * 原版 `SettingsView.vue:482-495` 的教训：
       * > 实测：一次 5 次切页的操作里 `has_proxy_password` 被调了 **15 次**
       * > （每次进设置页都要逐个源问一遍）。而这些数据**极少变化**。
       *
       * 我们这边更糟：面板是**每张源卡片一个**（照原版 `ProviderProxy`
       * 的设计），所以每个实例的 `initState` 都拉一次 ——
       * 本机 26 个源 = 26 次全量 `list_proxy_configs` + 26 次
       * `has_proxy_password` + 26 次 `system_proxy_hint` = **78 次 IPC**。
       * 走缓存后是 1 + N + 1（N = 真正配过密码的源数，通常 0）。
       */
      final cfg = await SourinApi.proxyConfigWithPassword(widget.providerId);

      if (!mounted) return;
      setState(() {
        _cfg = cfg;
        // 已配过的自动展开（原版行为）
        if (cfg.isConfigured) _open = true;
        _urlCtrl.text = cfg.url ?? '';
        _userCtrl.text = cfg.username ?? '';
        _bypassCtrl.text = cfg.bypass.join(', ');
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

  Future<void> _loadSysHint() async {
    try {
      // ★ 走共享缓存（全局唯一值，26 张卡片问一次就够）
      final h = await SourinApi.systemProxyHintCached();
      if (!mounted) return;
      setState(() => _sysHint = h);
    } catch (_) {
      // 检测不到就算了 —— 这只是个提示，不影响功能
    }
  }

  /// 保存配置（**不含密码**）
  ///
  /// # 为什么 url / username 要把"空"归一成 `null`
  ///
  /// Rust 是 `Option<String>` + `skip_serializing_if = "Option::is_none"`：
  /// ```text
  /// 传 null（不发该键）→ 后端存 None       ✓ 语义正确
  /// 传 ""             → 后端存 Some("")  ✗ 会落一个空 URL 进库
  /// ```
  /// 而用户清空输入框拿到的是空串，所以必须在这里归一化。
  Future<void> _save({bool notify = true}) async {
    final mode = _cfg?.mode ?? ProxyMode.direct;
    String? orNull(String s) => s.trim().isEmpty ? null : s.trim();

    final cfg = ProxyConfig(
      mode: mode,
      url: orNull(_urlCtrl.text),
      scope: _cfg?.scope ?? ProxyScope.apiOnly,
      username: orNull(_userCtrl.text),
      bypass: _bypassCtrl.text
          .split(',')
          .map((x) => x.trim())
          .where((x) => x.isNotEmpty)
          .toList(),
    );
    try {
      await SourinApi.setProxyConfig(widget.providerId, cfg);
      if (!mounted) return;
      setState(() {
        // 保留原来的 hasPassword 标记（密码不走这里，见 _savePassword）
        _cfg = cfg.copyWith(hasPassword: _cfg?.hasPassword ?? false);
        if (notify) _err = '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _err = '保存代理失败：$e');
    }
  }

  /// 保存密码（**单独命令，走系统钥匙串**）
  ///
  /// 原版注释（硬约定）：
  /// > 密码单独走钥匙串，不进配置对象，**也就不进备份**
  Future<void> _savePassword() async {
    final pwd = _passCtrl.text;
    if (pwd.isEmpty) return; // 留空 = 不修改
    try {
      await SourinApi.setProxyPassword(widget.providerId, pwd);
      if (!mounted) return;
      setState(() {
        _passCtrl.clear();
        _cfg = (_cfg ?? const ProxyConfig()).copyWith(hasPassword: true);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _err = '保存密码失败：$e');
    }
  }

  /// 清除代理（回到直连）
  Future<void> _clear() async {
    try {
      await SourinApi.clearProxyConfig(widget.providerId);
      if (!mounted) return;
      setState(() {
        _cfg = const ProxyConfig();
        _urlCtrl.clear();
        _userCtrl.clear();
        _bypassCtrl.clear();
        _testResult = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _err = '清除失败：$e');
    }
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
      _err = '';
    });
    try {
      // 测试前先保存（否则测的是旧配置 —— 用户刚填完地址就点测试会困惑）
      await _save(notify: false);
      final out = await SourinApi.testProxy(widget.providerId);
      if (!mounted) return;
      setState(() {
        _testResult = out;
        _testing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testResult = ProxyTestResult(ok: false, message: '$e');
        _testing = false;
      });
    }
  }

  void _setMode(ProxyMode m) {
    setState(() {
      _cfg = (_cfg ?? const ProxyConfig()).copyWith(mode: m);
      // 切到非直连时自动展开（原版行为：让用户接着填地址）
      if (m != ProxyMode.direct) _open = true;
      _testResult = null;
    });
    _save();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppPalette.of(context);

    if (_loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.x2),
        child: Text('代理配置读取中…',
            style: TextStyle(
                fontSize: FontSizes.cap, color: colors.mutedForeground)),
      );
    }

    final cfg = _cfg ?? const ProxyConfig();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 折叠头：一行摘要 + 展开箭头 ──
        InkWell(
          onTap: () => setState(() => _open = !_open),
          borderRadius: BorderRadius.circular(Radii.sm),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(
                  Icons.lan_outlined,
                  size: 14,
                  color: cfg.isConfigured
                      ? colors.primary
                      : colors.mutedForeground,
                ),
                const SizedBox(width: 6),
                /*
                 * 原版注释（折叠态的文案取舍）：
                 * > 折叠态**只显示摘要**，不显示「代理」二字与箭头 ——
                 * > 它们与标题同一行，多两个字就把标题挤窄了
                 *
                 * ⚠️ 但展开态**必须**把「代理」标签显示回来 ——
                 *    展开后是完整控件区，需要标题说明这是什么。
                 */
                Text(
                  _open ? '代理' : cfg.summary,
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    fontWeight:
                        cfg.isConfigured ? FontWeight.w600 : FontWeight.w400,
                    color: cfg.isConfigured
                        ? colors.primary
                        : colors.mutedForeground,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  _open ? Icons.expand_less : Icons.expand_more,
                  size: 14,
                  color: colors.mutedForeground,
                ),
                if (_open) ...[
                  const SizedBox(width: Sp.x2),
                  Text(cfg.summary,
                      style: TextStyle(
                          fontSize: FontSizes.cap,
                          color: colors.mutedForeground)),
                ],
              ],
            ),
          ),
        ),

        if (_open) ...[
          const SizedBox(height: Sp.x2),

          // ── 模式选择三个 pill ──
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final m in ProxyMode.values)
                _modePill(m, cfg.mode == m, colors),
            ],
          ),

          // ── 自定义才显示地址/凭据/范围 ──
          if (cfg.mode == ProxyMode.custom) ...[
            const SizedBox(height: Sp.x3),
            _label('代理地址', colors),
            const SizedBox(height: 4),
            _input(
              controller: _urlCtrl,
              colors: colors,
              // 原版 placeholder 就是这个格式
              hint: 'http://127.0.0.1:7890 或 socks5://127.0.0.1:1080',
              onDone: () => _save(),
            ),

            const SizedBox(height: Sp.x3),
            _label('认证（可选）', colors),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: _input(
                    controller: _userCtrl,
                    colors: colors,
                    hint: '用户名',
                    onDone: () => _save(),
                  ),
                ),
                const SizedBox(width: Sp.x2),
                Expanded(
                  child: _input(
                    controller: _passCtrl,
                    colors: colors,
                    /*
                     * 密码**永不回显** —— 原版硬约定：
                     * > 密码不回显 —— 只显示"已保存密码"，留空表示不修改。
                     * > 凭据存系统钥匙串，不落库。
                     */
                    hint: cfg.hasPassword ? '已保存（留空不修改）' : '密码',
                    obscure: true,
                    onDone: _savePassword,
                  ),
                ),
                const SizedBox(width: Sp.x2),
                IconButton(
                  onPressed: _savePassword,
                  icon: const Icon(Icons.lock_outline, size: 18),
                  tooltip: '保存密码到系统钥匙串',
                ),
              ],
            ),
            if (cfg.hasPassword)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '密码已存在系统钥匙串 —— 它**不进配置对象，也就不进备份**',
                  style: TextStyle(
                      fontSize: FontSizes.cap, color: colors.mutedForeground),
                ),
              ),

            const SizedBox(height: Sp.x3),
            _label('作用范围', colors),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              children: [
                for (final s in ProxyScope.values)
                  _modePill2(
                    s.label,
                    cfg.scope == s,
                    colors,
                    () {
                      setState(() {
                        _cfg = cfg.copyWith(scope: s);
                      });
                      _save();
                    },
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                cfg.scope == ProxyScope.apiOnly
                    ? '只让取数据走代理，视频直连更流畅（推荐）'
                    : '视频分片也走代理 —— 流量大，除非接口被墙否则不必',
                style: TextStyle(
                    fontSize: FontSizes.cap, color: colors.mutedForeground),
              ),
            ),

            const SizedBox(height: Sp.x3),
            _label('不走代理的主机（逗号分隔，可选）', colors),
            const SizedBox(height: 4),
            _input(
              controller: _bypassCtrl,
              colors: colors,
              hint: 'localhost, 127.0.0.1',
              onDone: () => _save(),
            ),
          ],

          // ── 跟随系统时给一条提示 ──
          if (cfg.mode == ProxyMode.system) ...[
            const SizedBox(height: Sp.x3),
            Text(
              _sysHint == null
                  ? '未检测到环境变量代理（HTTP_PROXY / HTTPS_PROXY / ALL_PROXY）'
                  : '检测到系统代理：$_sysHint',
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: _sysHint == null
                    ? colors.mutedForeground
                    : colors.foreground,
              ),
            ),
          ],

          const SizedBox(height: Sp.x3),

          // ── 动作行 ──
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: (_testing || cfg.mode == ProxyMode.direct)
                    ? null
                    : _test,
                icon: _testing
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.bolt_outlined, size: 15),
                label: Text(_testing ? '测试中…' : '测试连接'),
              ),
              const SizedBox(width: Sp.x2),
              if (cfg.mode != ProxyMode.direct)
                TextButton(onPressed: _clear, child: const Text('清除代理')),
            ],
          ),

          // ── 测试结果 ──
          if (_testResult != null)
            Padding(
              padding: const EdgeInsets.only(top: Sp.x2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _testResult!.ok
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    size: 14,
                    color: _testResult!.ok ? colors.primary : colors.error,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _testResult!.message.isEmpty
                          ? (_testResult!.ok ? '连接正常' : '连接失败')
                          : _testResult!.message,
                      style: TextStyle(
                        fontSize: FontSizes.cap,
                        height: 1.45,
                        color:
                            _testResult!.ok ? colors.primary : colors.error,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          if (_err.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Sp.x2),
              child: Text(_err,
                  style: TextStyle(
                      fontSize: FontSizes.cap, color: colors.error)),
            ),
        ],
      ],
    );
  }

  Widget _label(String t, AppPalette colors) => Text(
        t,
        style: TextStyle(fontSize: FontSizes.cap, color: colors.mutedForeground),
      );

  Widget _input({
    required TextEditingController controller,
    required AppPalette colors,
    required String hint,
    bool obscure = false,
    VoidCallback? onDone,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      style: const TextStyle(fontSize: FontSizes.sm),
      onSubmitted: onDone == null ? null : (_) => onDone(),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle:
            TextStyle(fontSize: FontSizes.sm, color: colors.mutedForeground),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: Sp.x3),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
      ),
    );
  }

  Widget _modePill(ProxyMode m, bool selected, AppPalette colors) =>
      _modePill2(m.label, selected, colors, () => _setMode(m));

  Widget _modePill2(
    String label,
    bool selected,
    AppPalette colors,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? colors.primary : colors.secondary,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? colors.primary : colors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: FontSizes.cap,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? colors.primaryForeground : colors.foreground,
          ),
        ),
      ),
    );
  }
}
