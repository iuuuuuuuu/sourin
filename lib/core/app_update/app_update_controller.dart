// ═══════════════════════════════════════════════════════════════════════
//  版本更新 —— 协调者（检查 / 下载 / 安装 / 节流 / 偏好）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么不做成一个全局单例到处直接调用
//
// 检查更新的时机有三处（启动、关于页手动、发现新版本后的提示），
// 但**彼此要共享同一份状态**（"已经查过了没有"、正在下载、不要重复提示）。
// 单例 + `ChangeNotifier` 是这里最省事且不引第三方状态管理的样子。
//
// # 两条硬约束
// ```text
// ① 任何网络失败都**不抛到调用方**，只在状态里记一句 —— 更新查不到
//    是日常（断网、镜像挂了、公司内网），不该弹错误。
// ② 启动时最多自动查一次/天，且可完全关闭。用户手动查**不受节流限制**。
// ```

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_log.dart';
import '../clip_download.dart';
import '../ui_prefs.dart';
import 'app_version.dart';
import 'client.dart';
import 'release.dart';
import 'route.dart';
import 'semver.dart';
import 'sha256.dart';

/// 一次检查的结果
class UpdateCheckResult {
  const UpdateCheckResult({
    required this.checked,
    this.release,
    this.message,
  });

  /// 是否成功联系到服务
  final bool checked;

  /// 比当前版本新的那个 Release（没有则 null）
  final ReleaseInfo? release;

  /// 给用户看的说明（成功/失败都用它，失败时不弹窗只写日志）
  final String? message;
}

/// 下载进度
class UpdateDownloadState {
  const UpdateDownloadState({
    required this.active,
    this.bytes = 0,
    this.total = -1,
    this.error,
  });

  final bool active;

  /// 已下载字节（-1 表示仍在解析）
  final int bytes;

  /// 总字节；服务器不给 Content-Length 时为 -1
  final int total;
  final String? error;

  static const idle = UpdateDownloadState(active: false);

  /// 0~1；总量未知时返回 0（UI 走不确定态动画）
  double get fraction => total <= 0 ? 0 : (bytes / total).clamp(0.0, 1.0);

  UpdateDownloadState copyWith({
    bool? active,
    int? bytes,
    int? total,
    String? error,
  }) =>
      UpdateDownloadState(
        active: active ?? this.active,
        bytes: bytes ?? this.bytes,
        total: total ?? this.total,
        error: error,
      );
}

class AppUpdateController extends ChangeNotifier {
  AppUpdateController._();

  static final AppUpdateController instance = AppUpdateController._();

  // ── 偏好键 ──
  static const _kRoute = 'appupdate.route';
  static const _kAutoCheck = 'appupdate.autoCheck';
  static const _kIncludePrerelease = 'appupdate.includePrerelease';
  static const _kLastCheck = 'appupdate.lastCheckAt';
  static const _kIgnored = 'appupdate.ignoredVersion';

  static const repoOwner = 'sourin-app';
  static const repoName = 'sourin';

  static const _apiBase = 'https://api.github.com';

  // ── 状态 ──
  UpdateRouteConfig _route = const UpdateRouteConfig();
  bool _autoCheck = true;
  bool _includePrerelease = false;
  DateTime? _lastCheckAt;
  String _ignoredVersion = '';
  bool _checking = false;
  ReleaseInfo? _available;
  UpdateDownloadState _download = UpdateDownloadState.idle;
  bool _cancelled = false;

  UpdateRouteConfig get route => _route;
  bool get autoCheck => _autoCheck;
  bool get includePrerelease => _includePrerelease;
  bool get checking => _checking;
  ReleaseInfo? get available => _available;
  UpdateDownloadState get download => _download;
  DateTime? get lastCheckAt => _lastCheckAt;

  /// 是否该在启动时自动查一次
  ///
  /// 规则：开着 + 从没查过（或距上次超过 [_autoInterval]）+ 没在下载中。
  bool get shouldAutoCheck {
    if (!_autoCheck || _checking || _download.active) return false;
    if (_lastCheckAt == null) return true;
    return DateTime.now().difference(_lastCheckAt!) >= _autoInterval;
  }

  /// 自动检查间隔：**每天最多一次**
  static const _autoInterval = Duration(hours: 24);

  UpdateHttp get _http => UpdateHttp(_route);

  // ── 偏好 ──

  void loadPrefs() {
    _route = UpdateRouteConfig(
      route: UpdateRoute.parse(UiPrefs.get(_kRoute)),
      proxyHost: UiPrefs.get('appupdate.proxyHost') ?? '',
      proxyPort: int.tryParse(UiPrefs.get('appupdate.proxyPort') ?? '') ?? 0,
      followSystemProxy:
          UiPrefs.get('appupdate.followSystemProxy') == '1',
      mirrorName: UiPrefs.get('appupdate.mirrorName') ?? '',
      customMirror: UiPrefs.get('appupdate.customMirror') ?? '',
    );
    _autoCheck = UiPrefs.get(_kAutoCheck) != '0';
    _includePrerelease = UiPrefs.get(_kIncludePrerelease) == '1';
    _lastCheckAt = DateTime.tryParse(UiPrefs.get(_kLastCheck) ?? '');
    _ignoredVersion = UiPrefs.get(_kIgnored) ?? '';
  }

  void setRoute(UpdateRouteConfig c) {
    _route = c;
    c.toPrefs().forEach((k, v) => UiPrefs.set('appupdate.$k', v));
    notifyListeners();
  }

  void setAutoCheck(bool v) {
    _autoCheck = v;
    UiPrefs.set(_kAutoCheck, v ? '1' : '0');
    notifyListeners();
  }

  void setIncludePrerelease(bool v) {
    _includePrerelease = v;
    UiPrefs.set(_kIncludePrerelease, v ? '1' : '0');
    notifyListeners();
  }

  /// 忽略某个版本（之后不再提示它）
  void ignoreVersion(String tag) {
    _ignoredVersion = tag;
    UiPrefs.set(_kIgnored, tag);
    if (_available?.tag == tag) _available = null;
    notifyListeners();
  }

  String get ignoredVersion => _ignoredVersion;

  // ── 检查 ──

  /// 查一次更新。[manual] 为 true 时忽略节流并把结果给 UI
  Future<UpdateCheckResult> check({bool manual = false}) async {
    if (_checking) {
      return const UpdateCheckResult(checked: false, message: '正在检查…');
    }
    _checking = true;
    if (manual) notifyListeners();

    try {
      final current = (await AppVersion.load()).version;
      final rel = _includePrerelease
          ? await _fetchLatestOfAny()
          : await _fetchLatest();
      final newer = _pickNewer(releases: [rel], current: current);
      if (newer != null && newer.tag == _ignoredVersion) {
        return UpdateCheckResult(
          checked: true,
          release: newer,
          message: '已是最新版本',
        );
      }
      _lastCheckAt = DateTime.now();
      UiPrefs.set(_kLastCheck, _lastCheckAt!.toIso8601String());
      _available = newer;
      notifyListeners();
      return UpdateCheckResult(
        checked: true,
        release: newer,
        message: newer == null ? '当前已是最新版本 ${_short(current)}' : null,
      );
    } on ReleaseParseException catch (e) {
      AppLog.write('UPDATE', '发布信息解析失败: $e');
      return const UpdateCheckResult(checked: false, message: '更新信息读取异常');
    } catch (e) {
      // 网络失败不是错误 —— 断网时用户不该看到红框
      AppLog.write('UPDATE', '检查更新失败（静默）: $e');
      return const UpdateCheckResult(
        checked: false,
        message: '连不上更新服务，已改为稍后再试',
      );
    } finally {
      _checking = false;
      if (manual) notifyListeners();
    }
  }

  static String _short(String v) => v.length > 12 ? '${v.substring(0, 12)}…' : v;

  /// 从一批候选里挑出**比当前版本新**的（已是最新时返回 null）
  ///
  /// 单独抽出来是为了能离线测：候选是现成的 [ReleaseInfo]。
  ReleaseInfo? _pickNewer({
    required List<ReleaseInfo> releases,
    required String current,
  }) {
    final cur = SemVer.tryParse(current);
    if (cur == null) return null;
    ReleaseInfo? best;
    for (final r in releases) {
      final v = SemVer.tryParse(r.tag);
      if (v == null) continue;
      if (v.compareTo(cur) <= 0) continue;
      if (best == null) {
        best = r;
        continue;
      }
      final bv = SemVer.tryParse(best.tag)!;
      if (v.compareTo(bv) > 0) best = r;
    }
    return best;
  }

  Future<ReleaseInfo> _fetchLatest() async {
    final body = await _http.getText(Uri.parse('$_apiBase/repos/$repoOwner/$repoName/releases/latest'),
        headers: {'Accept': 'application/vnd.github+json'});
    return parseReleaseJson(jsonDecode(body) as Map<String, dynamic>);
  }

  Future<ReleaseInfo> _fetchLatestOfAny() async {
    final body = await _http.getText(Uri.parse('$_apiBase/repos/$repoOwner/$repoName/releases?per_page=20'),
        headers: {'Accept': 'application/vnd.github+json'});
    final list = parseReleaseListJson(jsonDecode(body) as List<dynamic>);
    if (list.isEmpty) throw ReleaseParseException('没有可用的发布记录');
    return list.first;
  }

  /// 当前平台该下的那个资产（没有则 null）
  ReleaseAsset? assetFor(ReleaseInfo rel) {
    final (platform, abi) = UpdateHttp.currentTarget();
    return selectAsset(rel, platform, abi: abi);
  }

  // ── 下载 ──

  /// 下载某个 Release 的本平台安装包
  ///
  /// - [onDone] 返回可打开的文件路径；null 表示失败（已记进 [download].error）
  /// 校验：优先下载 Release 里的 `SHA256SUMS.txt`；**取不到就跳过校验并继续**
  ///（不因为一个校验文件缺失就把用户堵死在"无法更新"）。
  Future<File?> downloadRelease(
    ReleaseInfo rel, {
    void Function(UpdateDownloadState)? onProgress,
  }) async {
    final asset = assetFor(rel);
    if (asset == null) {
      _download = const UpdateDownloadState(
        active: false,
        error: '这个版本没有提供当前设备的安装包',
      );
      notifyListeners();
      return null;
    }

    final dir = Directory('${await ClipDownloader.dataDir()}/updates');
    await dir.create(recursive: true);
    final dest = File('${dir.path}${Platform.pathSeparator}${asset.name}');

    _cancelled = false;
    _download = const UpdateDownloadState(active: true, bytes: 0, total: -1);
    notifyListeners();

    try {
      final url = Uri.parse(RouteRewriter(_route).rewriteDownloadUrl(asset.url));
      await _http.download(
        url,
        dest,
        onProgress: (done, total) {
          _download = _download.copyWith(bytes: done, total: total);
          onProgress?.call(_download);
          notifyListeners();
        },
        cancelled: () async => _cancelled,
      );

      final ok = await verifySha256(dest, asset.name, tag: rel.tag);
      _download = UpdateDownloadState(
        active: false,
        bytes: await dest.length(),
        total: await dest.length(),
      );
      notifyListeners();
      if (!ok) {
        _download = _download.copyWith(error: '文件校验未通过，已删除，请重试');
        try {
          dest.deleteSync();
        } catch (_) {}
        notifyListeners();
        return null;
      }
      return dest;
    } on UpdateCancelled {
      _download = UpdateDownloadState.idle.copyWith(error: '已取消下载');
      notifyListeners();
      return null;
    } catch (e) {
      AppLog.write('UPDATE', '下载更新包失败: $e');
      _download = const UpdateDownloadState(
          active: false, error: '下载失败，请检查网络或下载方式设置');
      notifyListeners();
      return null;
    }
  }

  /// 取消正在进行的下载
  void cancelDownload() => _cancelled = true;

  /// 测试用：直接摆一个下载状态（截图与状态机断言用，不碰网络）
  @visibleForTesting
  void debugSetDownloadState(UpdateDownloadState s) {
    _download = s;
    notifyListeners();
  }

  /// 测试用：清掉已缓存的「有新版」状态
  @visibleForTesting
  void debugResetAvailable() {
    _available = null;
    _checking = false;
    notifyListeners();
  }

  /// 用 Release 里的 `SHA256SUMS.txt` 校验一个文件
  ///
  /// 读不到校验表 ⇒ 返回 true（不阻塞更新）。
  /// 校验不过 ⇒ 返回 false（调用方负责删掉）。
  Future<bool> verifySha256(File file, String assetName, {required String tag}) async {
    if (tag.isEmpty) return true;
    try {
      final sumsUrl =
          'https://github.com/$repoOwner/$repoName/releases/download/$tag/SHA256SUMS.txt';
      // ⚠️ 校验表本身也要能下载 ⇒ 同样按当前路线改写
      final text = await _http.getText(
        Uri.parse(RouteRewriter(_route).rewriteDownloadUrl(sumsUrl)),
      );
      final want = expectedSha256(parseSha256Sums(text), assetName);
      if (want == null) {
        AppLog.write('UPDATE', '校验表里没有 $assetName，跳过校验');
        return true;
      }
      final got = await sha256OfFile(file);
      if (got != want) {
        AppLog.write('UPDATE', '校验不符：期望 $want 实得 $got');
        return false;
      }
      return true;
    } catch (e) {
      AppLog.write('UPDATE', '取校验表失败（跳过校验）: $e');
      return true;
    }
  }
}