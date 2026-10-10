// ═══════════════════════════════════════════════════════════════════════
//  二级页：关于
// ═══════════════════════════════════════════════════════════════════════
//
// # 这一页现在有三件事
// ```text
// ① 显示自己的版本（CI 注入的 tag，本地构建回退到安装包版本）
// ② 手动「检查更新」
// ③ 设置「更新下载方式」（直连 / 代理 / 镜像）
// ```
//
// # 为什么第 ① 项和 ②③ 要放在一起
//
// 用户想更新时一定已经在这个页面里了 —— 把入口藏到别处等于没有。
//
// # 云盘状态与内容源数量的读法与旧版完全一致（各自 try/catch）：
//   设备 ID 来自 `SourinApi.syncStatus()`，没配云盘时该接口报错属正常；
//   绝不让它连带影响版本显示（用户来这一页十有八九是想看版本）。

import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../core/app_update/app_update_controller.dart';
import '../../core/app_update/app_version.dart';
import '../../core/app_update/client.dart';
import '../../core/app_update/install.dart';
import '../../core/app_update/release.dart';
import '../../core/app_update/route.dart';
import '../../core/sourin_api.dart';
import '../../core/ui_prefs.dart';
import '../tokens.dart';
import '../widgets/app_loading.dart';
import '../widgets/app_toast.dart';
import '../widgets/settings_kit.dart';
import '../widgets/settings_sub_page.dart';
import '../widgets/update_dialog.dart';

class AboutSettingsPage extends StatefulWidget {
  const AboutSettingsPage({super.key});

  @override
  AboutSettingsPageState createState() => AboutSettingsPageState();
}

class AboutSettingsPageState extends State<AboutSettingsPage> {
  @visibleForTesting
  AboutSettingsPageState();
  SyncStatus? _sync;
  List<ProviderManifest> _providers = const [];
  AppVersionInfo? _version;

  @override
  void initState() {
    super.initState();
    AppUpdateController.instance.loadPrefs();
    unawaited(_load());
  }

  Future<void> _load() async {
    final v = await AppVersion.load();
    if (mounted) setState(() => _version = v);

    // 两个请求**各自 try/catch** —— 一个失败不该让另一个也不显示。
    SyncStatus? sync;
    List<ProviderManifest> providers = const [];
    try {
      sync = await SourinApi.syncStatus();
    } catch (e) {
      debugPrint('[ABOUT] 云盘状态读取失败（未配置时属正常）: $e');
    }
    try {
      providers = await SourinApi.listProviders();
    } catch (e) {
      debugPrint('[ABOUT] 内容源列表读取失败: $e');
    }
    if (!mounted) return;
    setState(() {
      _sync = sync;
      _providers = providers;
    });
  }

  /// 手动检查更新
  Future<void> _checkNow() async {
    final c = AppUpdateController.instance;
    final res = await c.check(manual: true);
    if (!mounted) return;

    final rel = res.release;
    if (rel == null) {
      // 没连上 / 已是最新 —— 都只给一句话，不弹错误
      showAppToast(context, res.message ?? '当前已是最新版本');
      return;
    }
    final platform = UpdateHttp.currentTarget().$1;
    final wantDownload = await showUpdateDialog(context, rel, platform: platform);
    if (!wantDownload) return;
    await _downloadAndInstall(c, rel, platform);
  }

  Future<void> _downloadAndInstall(
    AppUpdateController c,
    ReleaseInfo rel,
    UpdatePlatform platform,
  ) async {
    final file = await c.downloadRelease(rel);
    if (!mounted) return;
    if (file == null) {
      showAppToast(context, c.download.error ?? '下载未完成',
          style: errToastStyle());
      return;
    }
    if (!InstallLaunch.canInstallDirectly) {
      final url = selectAsset(rel, platform)?.browserUrl ?? rel.htmlUrl;
      final msg = await InstallLaunch.openInBrowser(url);
      if (!mounted) return;
      showAppToast(context, msg ?? '请在浏览器里完成更新');
      return;
    }
    final msg = await InstallLaunch.open(file);
    if (!mounted) return;
    if (msg != null) {
      showAppToast(context, msg);
    } else if (Platform.isWindows) {
      // 安装向导已拉起 ⇒ 退出，让安装程序接管
      await AboutSettingsPageState.flushPrefsBeforeNonGracefulExit();
      exit(0);
    }
  }

  /// ★ 非优雅退出（`exit(0)`）之前把偏好落盘 —— **必须等它写完**再退。
  ///
  /// # 为什么（OPS-17 的超范围遗留项）
  /// `UiPrefs.set()` 只改内存，真正写盘的是
  /// `lib/core/ui_prefs.dart:107-113` 那个 300ms 去抖定时器。用户完全可能
  /// 「刚在设置页拨完开关 → 300ms 内点『立即更新』→ 安装器成功拉起」——
  /// `exit(0)` 立刻终止进程（它**不展开 finally**、也不等任何 Future），
  /// 这一次偏好就**永久丢失**（下次打开还是旧值）。
  ///
  /// # 为什么必须真的 await（不能 unawaited）
  /// 与 `lib/core/app_tray.dart:460-466 _flushPrefsBeforeExit()` 同一条纪律：
  /// 退出是一次性的，`exit(0)` 之后进程就没了，没有「稍后顺手写完」这回事。
  /// （对比 `lib/core/window_bounds.dart` 的拖窗口场景 —— 那里后面还有很长的
  ///   会话，`unawaited` 足够；这里不够。）
  ///
  /// # 为什么不会卡住退出
  /// `flush()` 自己吞异常只留日志（`lib/core/ui_prefs.dart:119-124`），
  /// 且没有脏数据时立即返回；外面再兜一层 try/catch ⇒ 落盘失败也照常退出。
  ///
  /// ⚠️ 抽成 `static`（而不是私有实例方法）是**为了可测**：`exit(0)` 会真的
  ///    杀掉进程，测试没法跑到它，只能直接调用「exit 之前的那一步」并断言
  ///    `ui-prefs.json` 里**盘上**已有值
  ///    （见 `test/zz_cr_prefs_about_exit_flush_test.dart`）。
  @visibleForTesting
  static Future<void> flushPrefsBeforeNonGracefulExit() async {
    try {
      await UiPrefs.flush();
    } catch (e) {
      debugPrint('[ABOUT] 退出前偏好落盘失败（不影响退出）: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: '关于',
      subtitle: '版本与运行信息',
      children: [
        SettingsBlock(
          title: '运行信息',
          children: [
            const SettingsInfoRow(
              label: '架构',
              value: 'Flutter + media_kit + Rust',
            ),
            SettingsInfoRow(
              label: '版本',
              value: _versionLabel(),
            ),
            SettingsInfoRow(
              label: '设备 ID',
              value: _sync?.deviceId ?? '(未知)',
            ),
            SettingsInfoRow(
              label: '内容源',
              value: '${_providers.length} 个'
                  '（${_providers.where((p) => p.enabled).length} 个已启用）',
            ),
          ],
        ),
        SettingsBlock(
          title: '更新',
          children: [
            ListenableBuilder(
              listenable: AppUpdateController.instance,
              builder: (context, _) {
                final c = AppUpdateController.instance;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SettingsInfoRow(
                      label: '自动检查',
                      value: c.autoCheck ? '每天一次' : '已关闭',
                    ),
                    const SizedBox(height: Sp.x2),
                    _SettingsSwitchRow(
                      label: '启动时自动检查更新',
                      value: c.autoCheck,
                      onChanged: c.setAutoCheck,
                    ),
                    _SettingsSwitchRow(
                      label: '同时接收预览版本',
                      value: c.includePrerelease,
                      onChanged: c.setIncludePrerelease,
                    ),
                    const SizedBox(height: Sp.x3),
                    _PrimaryButton(
                      busy: c.checking,
                      label: '检查更新',
                      onPressed: c.checking ? null : _checkNow,
                    ),
                  ],
                );
              },
            ),
          ],
        ),
        const SettingsBlock(
          title: '更新下载方式',
          children: [UpdateRouteEditor()],
        ),
      ],
    );
  }

  /// 「1.2.3（正式版）」/「1.2.0（本地构建）」
  String _versionLabel() {
    final v = _version;
    if (v == null) return '读取中…';
    return '${v.version}（${v.fromRelease ? '正式版' : '本地构建'}）';
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  下载方式编辑器
// ═══════════════════════════════════════════════════════════════════════

class UpdateRouteEditor extends StatefulWidget {
  const UpdateRouteEditor({super.key});

  @override
  UpdateRouteEditorState createState() => UpdateRouteEditorState();
}

class UpdateRouteEditorState extends State<UpdateRouteEditor> {
  late UpdateRouteConfig _cfg;
  late TextEditingController _host;
  late TextEditingController _port;
  late TextEditingController _mirror;

  @override
  void initState() {
    super.initState();
    final c = AppUpdateController.instance.route;
    _cfg = c;
    _host = TextEditingController(text: c.proxyHost);
    _port = TextEditingController(text: c.proxyPort > 0 ? '${c.proxyPort}' : '');
    _mirror = TextEditingController(text: c.customMirror);
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _mirror.dispose();
    super.dispose();
  }

  void _apply(UpdateRouteConfig c) {
    setState(() => _cfg = c);
    AppUpdateController.instance.setRoute(c);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final r in UpdateRoute.values)
          RadioListTile<UpdateRoute>(
            value: r,
            // ignore: deprecated_member_use
            groupValue: _cfg.route,
            // ignore: deprecated_member_use
            onChanged: (v) => _apply(_cfg.copyWith(route: v ?? UpdateRoute.direct)),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(_routeLabel(r), style: const TextStyle(fontSize: FontSizes.sm)),
          ),
        if (_cfg.route == UpdateRoute.proxy) ...[
          const SizedBox(height: Sp.x2),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: _Field(_host, '代理地址（如 127.0.0.1）', _onHost),
              ),
              const SizedBox(width: Sp.x2),
              Expanded(
                child: _Field(_port, '端口（如 7890）', _onPort,
                    keyboard: TextInputType.number),
              ),
            ],
          ),
          _SettingsSwitchRow(
            label: '跟随系统代理设置',
            value: _cfg.followSystemProxy,
            onChanged: (v) => _apply(_cfg.copyWith(followSystemProxy: v)),
          ),
        ],
        if (_cfg.route == UpdateRoute.mirror) ...[
          const SizedBox(height: Sp.x2),
          Wrap(
            spacing: Sp.x2,
            runSpacing: Sp.x2,
            children: [
              for (final m in UpdateMirror.list)
                ChoiceChip(
                  label: Text(m.name, style: const TextStyle(fontSize: FontSizes.cap)),
                  selected: _cfg.mirrorName == m.name,
                  onSelected: (sel) => _apply(_cfg.copyWith(
                    mirrorName: sel ? m.name : '',
                    customMirror: sel ? '' : _cfg.customMirror,
                  )),
                ),
            ],
          ),
          const SizedBox(height: Sp.x2),
          _Field(_mirror, '或填写自己的镜像地址（可留空）', _onMirror),
          const SizedBox(height: Sp.x1),
          Text('镜像只用于下载安装包；获取更新信息仍走直连或代理。',
              style:
                  TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant)),
        ],
      ],
    );
  }

  static String _routeLabel(UpdateRoute r) => switch (r) {
        UpdateRoute.direct => '直连下载',
        UpdateRoute.proxy => '通过代理下载',
        UpdateRoute.mirror => '镜像加速下载',
      };

  void _onHost(String v) => _apply(_cfg.copyWith(proxyHost: v.trim()));
  void _onPort(String v) =>
      _apply(_cfg.copyWith(proxyPort: int.tryParse(v.trim()) ?? 0));
  void _onMirror(String v) => _apply(_cfg.copyWith(customMirror: v.trim()));
}

class _Field extends StatelessWidget {
  const _Field(this.ctrl, this.hint, this.onChanged, {this.keyboard});
  final TextEditingController ctrl;
  final String hint;
  final ValueChanged<String> onChanged;
  final TextInputType? keyboard;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: ctrl,
      onChanged: onChanged,
      keyboardType: keyboard,
      style: const TextStyle(fontSize: FontSizes.sm),
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: const TextStyle(fontSize: FontSizes.cap),
        border: const OutlineInputBorder(),
      ),
    );
  }
}

class _SettingsSwitchRow extends StatelessWidget {
  const _SettingsSwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: const TextStyle(fontSize: FontSizes.sm)),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.onPressed,
    this.busy = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    if (busy) {
      // ★ OPS-14：共享组件 + **显式传 16**。
      //   按钮只有 40px 高，默认直径 30 会把按钮顶高 ⇒ 高度跳变。
      //   描边也从 2 提到 2.8（低于 2.5 就是 Owner 说的那根发丝）。
      return const SizedBox(
        height: 40,
        width: 40,
        child: Center(child: AppLoading(size: 16)),
      );
    }
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: Sp.x5),
      ),
      child: Text(label, style: const TextStyle(fontSize: FontSizes.sm)),
    );
  }
}