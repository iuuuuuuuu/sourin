// ═══════════════════════════════════════════════════════════════════════
//  更新下载的「网络路线」：直连 / 代理 / 镜像加速
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么把「怎么出去」单独抽成一个纯逻辑文件
//
// 网络失败是这个功能最高频的失败源，而**路线选择是可以离线验证的**：
// 镜像前缀拼接、代理地址解析、请求头改写全是纯字符串运算。
// 把它们放进网络请求代码里，就只能靠真连网来测 —— 那是 CI 上最红的一类。
//
// ⇒ 这里全是纯函数 + 一个极小的配置对象；网络执行在 `client.dart`。
//
// # 三种方式的语义（**���不重叠，别混**）
// ```text
// 直连   : 什么都不改
// 代理   : 给 HTTP 请求加 Proxy 头（HTTP 用 absolute-form 的 URL）
// 镜像   : 把 URL 的 host/path 换成镜像前缀后的整条原 URL
// ```
// ⚠️ 镜像只对**文件下载**有意义（`github.com/.../releases/download/...`）：
//   这些加速服务本质是一个公开的文件代理，只能代理 GET 一个具体文件。
//   `api.github.com` 的 JSON 接口它们一律不支持 ⇒
//   **镜像模式下 API 请求自动回退到直连/代理**（见 [resolveApi]）。

import 'dart:io';

/// 下载方式
enum UpdateRoute {
  direct,
  proxy,
  mirror;

  static UpdateRoute parse(String? raw) => switch (raw) {
        'proxy' => UpdateRoute.proxy,
        'mirror' => UpdateRoute.mirror,
        _ => UpdateRoute.direct,
      };

  String get key => name;

  static const label = '更新下载方式';
}

/// 预置的 GitHub 加速镜像（**用户可自选 / 可自定义**）
///
/// ⚠️ 这些是第三方公益服务，随时可能失效 —— 所以：
/// ① 列表只是「候选」，不代表我们保证它可用；
/// ② 失败必须**优雅回退**到直连/代理，而不是报错轰炸；
/// ③ 用户可以自己填别的前缀。
///
/// 拼接规则统一是 `<前缀>` + `<完整原始 URL>`（例如
/// `https://ghfast.top/` + `https://github.com/a/b/releases/download/v1/x.zip`）。
class UpdateMirror {
  const UpdateMirror(this.name, this.prefix);

  final String name;

  /// 前缀（**必须以 `/` 结尾**，否则拼接出来的 URL 是错的）
  final String prefix;

  static const list = <UpdateMirror>[
    UpdateMirror('ghfast', 'https://ghfast.top/'),
    UpdateMirror('gh-proxy', 'https://gh-proxy.com/'),
    UpdateMirror('ghproxy.net', 'https://ghproxy.net/'),
    UpdateMirror('gitproxy.click', 'https://gitproxy.click/'),
  ];

  static UpdateMirror? byName(String name) {
    for (final m in list) {
      if (m.name == name) return m;
    }
    return null;
  }

  /// 自定义前缀：补上结尾的 `/`（用户十有八九会漏）
  static String normalizePrefix(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'https://$s';
    }
    if (!s.endsWith('/')) s = '$s/';
    return s;
  }
}

/// 路线配置（从偏好读出来的一张快照）
class UpdateRouteConfig {
  const UpdateRouteConfig({
    this.route = UpdateRoute.direct,
    this.proxyHost = '',
    this.proxyPort = 0,
    this.followSystemProxy = false,
    this.mirrorName = '',
    this.customMirror = '',
  });

  final UpdateRoute route;

  /// 代理地址（不含 scheme，也不含端口）
  final String proxyHost;
  final int proxyPort;

  /// 「跟随系统」：用系统/环境变量里的代理（HTTP_PROXY 等）
  final bool followSystemProxy;

  /// 预置镜像名（空 = 用 [customMirror]）
  final String mirrorName;

  /// 自定义镜像前缀
  final String customMirror;

  UpdateRouteConfig copyWith({
    UpdateRoute? route,
    String? proxyHost,
    int? proxyPort,
    bool? followSystemProxy,
    String? mirrorName,
    String? customMirror,
  }) =>
      UpdateRouteConfig(
        route: route ?? this.route,
        proxyHost: proxyHost ?? this.proxyHost,
        proxyPort: proxyPort ?? this.proxyPort,
        followSystemProxy: followSystemProxy ?? this.followSystemProxy,
        mirrorName: mirrorName ?? this.mirrorName,
        customMirror: customMirror ?? this.customMirror,
      );

  /// 当前生效的镜像前缀（空 = 没有可用的镜像）
  String get mirrorPrefix {
    if (route != UpdateRoute.mirror) return '';
    if (mirrorName.isEmpty) return UpdateMirror.normalizePrefix(customMirror);
    return UpdateMirror.byName(mirrorName)?.prefix ?? '';
  }

  /// 当前可用的代理 URI（空 = 不带代理）
  ///
  /// 「跟随系统」时读环境变量 `HTTP_PROXY` / `HTTPS_PROXY`（小写也算）。
  String? proxyUri({Map<String, String>? env}) {
    if (route != UpdateRoute.proxy) return null;
    if (followSystemProxy) {
      final e = env ?? Platform.environment;
      final raw = (e['HTTPS_PROXY'] ?? e['https_proxy'] ?? '').trim().isNotEmpty
          ? (e['HTTPS_PROXY'] ?? e['https_proxy'])
          : (e['HTTP_PROXY'] ?? e['http_proxy'] ?? '');
      if (raw != null && raw.trim().isNotEmpty) return _normalizeUri(raw.trim());
      // 读不到系统代理 ⇒ 退回手工填的（用户可能显式填了）
      if (proxyHost.trim().isEmpty || proxyPort <= 0) return null;
    }
    if (proxyHost.trim().isEmpty || proxyPort <= 0) return null;
    return 'http://${proxyHost.trim()}:$proxyPort';
  }

  static String? _normalizeUri(String raw) {
    var s = raw;
    if (!s.contains('://')) s = 'http://$s';
    return s;
  }

  Map<String, String> toPrefs() => {
        'route': route.name,
        'proxyHost': proxyHost,
        'proxyPort': '$proxyPort',
        'followSystemProxy': followSystemProxy ? '1' : '0',
        'mirrorName': mirrorName,
        'customMirror': customMirror,
      };

  static UpdateRouteConfig fromPrefs(Map<String, String> p) =>
      UpdateRouteConfig(
        route: UpdateRoute.parse(p['route']),
        proxyHost: p['proxyHost'] ?? '',
        proxyPort: int.tryParse(p['proxyPort'] ?? '') ?? 0,
        followSystemProxy: p['followSystemProxy'] == '1',
        mirrorName: p['mirrorName'] ?? '',
        customMirror: p['customMirror'] ?? '',
      );
}

/// 把一个 URL 按当前路线改写
///
/// ⚠️ 只有 `https://github.com/…/releases/download/…` 这类**文件直链**
/// 会被镜像接管；其它地址原样返回（见 [isMirrorable]）。
class RouteRewriter {
  const RouteRewriter(this.config);

  final UpdateRouteConfig config;

  /// 这个地址能不能被镜像加速
  ///
  /// 镜像服务代理的是「一个具体文件」；API 与网页不是文件，
  /// 让它们走镜像只会拿到 404 或 HTML。
  static bool isMirrorable(Uri uri) {
    if (uri.scheme != 'https' && uri.scheme != 'http') return false;
    final h = uri.host.toLowerCase();
    if (h != 'github.com' && h != 'www.github.com') return false;
    return uri.path.contains('/releases/download/');
  }

  /// 按镜像前缀改写；不可镜像或没选镜像时原样返回
  String rewriteDownloadUrl(String rawUrl) {
    final prefix = config.mirrorPrefix;
    if (prefix.isEmpty) return rawUrl;
    final u = Uri.tryParse(rawUrl);
    if (u == null || !isMirrorable(u)) return rawUrl;
    return prefix + rawUrl;
  }

  /// API 请求最终该用哪个 URL
  ///
  /// 镜像不提供 API ⇒ 镜像模式下这里**回退到原地址**，
  /// 并由 [usesProxy] 决定是否改走代理。
  String resolveApi(Uri api) => api.toString();
}