// ═══════════════════════════════════════════════════════════════════════
//  投屏总调度：发现 → 连接 → 下发 → 播放 —— task-27
// ═══════════════════════════════════════════════════════════════════════
//
// 前面四个文件各管一段（SSDP 找设备 / 解析描述 / SOAP 说话 / 代理防盗链），
// 本文件把它们串成 UI 能直接用的一条链：
//
// ```text
//   discover()    SSDP 扫 → 拉描述 → 得到"能投屏的设备"列表
//   connect(d)    选定设备，建 AvTransport（不播放）
//   cast(url)     起代理 → 拿到「手机在局域网里的地址」→ SetAVTransportURI → Play
//   stop/pause    转发给设备
// ```
//
// # 三个刻意的设计决定
//
// ```text
// 1. 发现阶段就把"不能投屏的设备"标出来而不是丢掉 —— 用户搜不到自己的电视时，
//    最需要知道的是"搜到了但它不支持投屏"，而不是"什么都没搜到"。
// 2. 描述文档拉取失败不打断整次扫描 —— 一台设备超时不代表别的也超时。
//    失败的设备带 error 进列表，UI 显示灰条 + 原因。
// 3. 投屏成功后才算 connected —— SetAVTransportURI 与 Play 任何一步失败，
//    状态必须回到失败态并带上设备说的原话（见 SoapResult.message）。
// ```

import 'dart:async';

import 'description.dart';
import 'dlna_http.dart';
import 'referer_proxy.dart';
import 'soap.dart';
import 'ssdp.dart';

// ═══════════════════════════════════════════════════════════════════════
//  模型
// ═══════════════════════════════════════════════════════════════════════

/// 扫描结果里的一台设备
class CastDevice {
  CastDevice({
    required this.location,
    required this.host,
    this.description,
    this.error,
    this.server = '',
    this.usn = '',
  });

  /// SSDP 给的描述文档地址
  final String location;

  /// 设备 IP（日志/去重用）
  final String host;

  /// 拉到并解析成功的描述；null 表示失败（见 [error]）
  final DeviceDescription? description;

  /// 拉描述失败的原因（中文人话）
  final String? error;

  /// SSDP 响应里的 SERVER 头（如 `Linux/3.x UPnP/1.0 Android/9`）
  final String server;

  /// SSDP 响应里的 USN
  final String usn;

  /// 列表上显示的名字
  String get name {
    final d = description;
    if (d != null && d.friendlyName.isNotEmpty) return d.friendlyName;
    // 没拿到描述时**不要**编一个名字 —— 显示 IP 更诚实
    return host;
  }

  /// 型号（没有则空）
  String get model => description?.modelName ?? '';

  /// 能不能投屏
  bool get canCast => description?.canCast ?? false;

  /// 不能投屏的原因（UI 直接显示）
  String get why {
    if (error != null) return error!;
    final d = description;
    if (d == null) return '没有拿到设备信息';
    if (d.avTransportControlUrl == null) {
      return d.serviceTypes.isEmpty
          ? '这台设备没有提供任何 UPnP 服务，不能投屏'
          : '这台设备不支持 AVTransport（它只提供 ${d.serviceTypes.length} 个其它服务），不能投屏';
    }
    return '';
  }

  @override
  String toString() => 'CastDevice($name @$host, canCast=$canCast)';
}

/// 一次扫描的完整结果
class CastScan {
  CastScan({
    required this.devices,
    required this.unsupported,
    required this.scan,
  });

  /// 能投屏的（canCast == true），按名字排序
  final List<CastDevice> devices;

  /// 扫到了但不能投屏的
  final List<CastDevice> unsupported;

  /// SSDP 层的统计（发出/收到/耗时/错误）
  final SsdpScanResult scan;

  List<CastDevice> get all => [...devices, ...unsupported];

  bool get isEmpty => devices.isEmpty && unsupported.isEmpty;
}

/// 投屏会话状态
enum CastPhase {
  /// 还没投
  idle,

  /// 正在连接设备 / 下发地址
  connecting,

  /// 设备已接受，正在播
  playing,

  /// 暂停
  paused,

  /// 出错了（[CastSession.error] 有原话）
  failed,
}

/// 当前投屏会话
class CastSession {
  CastSession({
    required this.device,
    required this.controlUrl,
    required this.phase,
    this.proxyUrl,
    this.originalUrl,
    this.error,
    this.transportState,
  });

  final CastDevice device;
  final String controlUrl;
  final CastPhase phase;

  /// 实际投给设备的地址（本地代理地址）
  final String? proxyUrl;

  /// 用户点的那个原始地址（换集/重投时用）
  final String? originalUrl;

  /// 失败原因（中文人话）
  final String? error;

  /// 设备自报的传输状态（`PLAYING` / `PAUSED_PLAYBACK` / `STOPPED`…）
  final String? transportState;

  bool get active => phase == CastPhase.playing || phase == CastPhase.paused;

  CastSession copyWith({
    CastPhase? phase,
    String? proxyUrl,
    String? originalUrl,
    String? error,
    String? transportState,
    bool clearError = false,
  }) =>
      CastSession(
        device: device,
        controlUrl: controlUrl,
        phase: phase ?? this.phase,
        proxyUrl: proxyUrl ?? this.proxyUrl,
        originalUrl: originalUrl ?? this.originalUrl,
        error: clearError ? null : (error ?? this.error),
        transportState: transportState ?? this.transportState,
      );
}

// ═══════════════════════════════════════════════════════════════════════
//  调度器
// ═══════════════════════════════════════════════════════════════════════

/// 投屏总调度
///
/// 一个 App 只需要一个实例（代理端口要复用）。UI 层把它挂在页面 State 里。
class CastManager {
  CastManager({this.onLog, MediaProxy? proxy}) : _proxy = proxy ?? MediaProxy();

  /// 日志出口。**可写**：UI 层（CastButton）在 initState 里挂上自己的 logcat 出口，
  /// 因为投屏是长流程（发现 → 拉描述 → 下发 → 播放），出问题时用户只看得到「没反应」，
  /// 必须有一条能落到 logcat 的真实链路。
  void Function(String line)? onLog;

  /// 本地代理 —— 只有真正投屏时才启动（用户只是打开面板不该占端口）
  final MediaProxy _proxy;

  MediaProxy get proxy => _proxy;

  CastSession? _session;
  CastSession? get session => _session;

  /// 最近一次扫描（面板重绘用）
  CastScan? lastScan;

  void _log(String line) {
    onLog?.call(line);
    _proxy.onLog?.call(line);
  }

  // ── 发现 ──

  /// 扫一遍局域网并补齐设备信息
  ///
  /// [timeout] 是 SSDP 监听窗口；拉描述每台最多 [DlnaHttp.defaultTimeout]。
  /// 描述文档**并发**拉取（串行的话 5 台设备 × 3 秒 = 15 秒，用户早走了）。
  Future<CastScan> discover({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final scan = await SsdpDiscovery.scan(timeout: timeout, onLog: _log);
    _log('[投屏] SSDP 得到 ${scan.responses.length} 条响应，开始拉设备描述…');

    final results = await Future.wait(scan.responses.map((r) async {
      final loc = r.location;
      final host = hostOf(loc ?? '');
      if (loc == null) {
        return CastDevice(
          location: '',
          host: r.source,
          error: '这台设备没有给出描述地址（LOCATION），无法连接',
          server: r.server,
          usn: r.usn,
        );
      }
      try {
        final d = await fetchDescription(loc);
        _log('[投屏] ✓ $host → ${d.friendlyName}'
            '${d.canCast ? '' : '（不支持 AVTransport，不能投屏）'}');
        return CastDevice(
          location: loc,
          host: host,
          description: d,
          server: r.server,
          usn: r.usn,
        );
      } on DlnaException catch (e) {
        _log('[投屏] ✗ $host 拉描述失败：${e.message}');
        return CastDevice(
          location: loc,
          host: host,
          error: e.message,
          server: r.server,
          usn: r.usn,
        );
      }
    }));

    final ok = results.where((d) => d.canCast).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final no = results.where((d) => !d.canCast).toList();
    final out = CastScan(devices: ok, unsupported: no, scan: scan);
    lastScan = out;
    _log('[投屏] 可投屏 ${ok.length} 台，扫到但不可投 ${no.length} 台');
    return out;
  }

  // ── 投屏 ──

  /// 把 [url] 投到 [device]
  ///
  /// [headers] 会由本地代理注入上游（B 站等防盗链源必须带 Referer）。
  /// 成功返回 session；失败**不抛异常**，返回 phase=failed 的 session ——
  /// UI 只需要看一个对象，不用同时处理返回值和异常两条路。
  Future<CastSession> cast(
    CastDevice device,
    String url, {
    Map<String, String> headers = const {},
    String title = '投屏',
  }) async {
    final control = device.description?.avTransportControlUrl;
    if (control == null) {
      final s = CastSession(
        device: device,
        controlUrl: '',
        phase: CastPhase.failed,
        originalUrl: url,
        error: device.why.isEmpty ? '这台设备不能投屏' : device.why,
      );
      _session = s;
      return s;
    }

    _session = CastSession(
      device: device,
      controlUrl: control,
      phase: CastPhase.connecting,
      originalUrl: url,
    );
    _log('[投屏] 目标：${device.name}（$control）');

    final at = AvTransport(controlUrl: control, onLog: _log);
    try {
      // ── 1. 起代理并登记（防盗链在这里解决）──
      final proxyUrl = await _proxy.register(url, headers: headers, label: title);
      _log('[投屏] 代理地址：$proxyUrl（附加头 ${headers.keys.join(',')}）');

      // ── 2. 告诉设备放哪个地址 ──
      final set = await at.setAvTransportUri(proxyUrl, title: title);
      if (!set.ok) {
        final s = _session!.copyWith(phase: CastPhase.failed, error: '设备拒绝了投屏地址：${set.message}');
        _session = s;
        _log('[投屏] ✗ SetAVTransportURI 失败：${set.message}');
        return s;
      }

      // ── 3. 让它播 ──
      final play = await at.play();
      if (!play.ok) {
        final s = _session!.copyWith(phase: CastPhase.failed, error: '设备接受地址但拒绝播放：${play.message}');
        _session = s;
        _log('[投屏] ✗ Play 失败：${play.message}');
        return s;
      }

      // ── 4. 问一下状态（拿不到也不影响投屏成功）──
      final st = await at.getTransportInfo();
      final state = _pick(st.body, 'CurrentTransportState');
      final s = _session!.copyWith(
        phase: CastPhase.playing,
        proxyUrl: proxyUrl,
        transportState: state,
        clearError: true,
      );
      _session = s;
      _log('[投屏] ✓ 已下发，设备状态：${state ?? '未知'}');
      return s;
    } on DlnaException catch (e) {
      final s = _session!.copyWith(phase: CastPhase.failed, error: e.message);
      _session = s;
      _log('[投屏] ✗ ${e.message}');
      return s;
    } catch (e) {
      final s = _session!.copyWith(phase: CastPhase.failed, error: '投屏失败：$e');
      _session = s;
      _log('[投屏] ✗ $e');
      return s;
    }
  }

  /// 暂停 / 继续
  Future<CastSession?> pause() => _transport('Pause', CastPhase.paused);

  Future<CastSession?> resume() => _transport('Play', CastPhase.playing);

  /// 停止投屏并撤掉代理登记
  Future<void> stop() async {
    final s = _session;
    if (s != null && s.controlUrl.isNotEmpty) {
      try {
        final at = AvTransport(controlUrl: s.controlUrl, onLog: _log);
        final r = await at.stop();
        _log('[投屏] Stop → ${r.ok ? 'ok' : r.message}');
      } on DlnaException catch (e) {
        // ★ 设备已经掉线时 Stop 必然失败 —— 这不影响"本地停止投屏"这件事，
        //   所以只记日志，不往 UI 抛错。
        _log('[投屏] Stop 失败（设备可能已离线）：${e.message}');
      }
    }
    _session = null;
    await _proxy.stop();
  }

  Future<CastSession?> _transport(String action, CastPhase phase) async {
    final s = _session;
    if (s == null || s.controlUrl.isEmpty) return null;
    final at = AvTransport(controlUrl: s.controlUrl, onLog: _log);
    try {
      final r = action == 'Play' ? await at.play() : await at.pause();
      final next = s.copyWith(
        phase: r.ok ? phase : CastPhase.failed,
        error: r.ok ? null : r.message,
        clearError: r.ok,
      );
      _session = next;
      return next;
    } on DlnaException catch (e) {
      final next = s.copyWith(phase: CastPhase.failed, error: e.message);
      _session = next;
      return next;
    }
  }

  /// 问设备当前状态（UI 定时刷新用）
  Future<String?> refreshState() async {
    final s = _session;
    if (s == null || s.controlUrl.isEmpty) return null;
    try {
      final at = AvTransport(controlUrl: s.controlUrl, onLog: _log);
      final r = await at.getTransportInfo();
      if (!r.ok) return null;
      final st = _pick(r.body, 'CurrentTransportState');
      if (st != null) {
        final phase = switch (st) {
          'PLAYING' => CastPhase.playing,
          'PAUSED_PLAYBACK' || 'PAUSED_RECORDING' => CastPhase.paused,
          'STOPPED' || 'NO_MEDIA_PRESENT' => CastPhase.idle,
          _ => s.phase,
        };
        _session = s.copyWith(transportState: st, phase: phase);
      }
      return st;
    } on DlnaException {
      return null;
    }
  }

  static String? _pick(String body, String tag) {
    final m = RegExp('<$tag(\\s[^>]*)?>(.*?)</$tag>', caseSensitive: false, dotAll: true)
        .firstMatch(body);
    final v = (m?.group(2) ?? '').trim();
    return v.isEmpty ? null : v;
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  全局单例
// ═══════════════════════════════════════════════════════════════════════

CastManager? _shared;

/// 全 App 共享的调度器
///
/// # 为什么必须是单例
///
/// 代理是**有状态**的：电视正在拉的流走的是 `<手机局域网地址>:<port>/m/<token>`。
/// 如果播放页每次重建都 new 一个 CastManager，代理会被重新绑定到另一个端口，
/// 而电视手里那个地址立刻 410 —— 表现就是"投上去播两秒就断"。
///
/// 所以：**谁都可以拿到它，但不要在 widget dispose 里 stop 它**（见 stop()）。
CastManager get sharedCastManager => _shared ??= CastManager();

/// 仅测试用：把单例换掉/清掉（不依赖 package:meta —— 本项目的 pubspec 里没有它）
set sharedCastManagerForTest(CastManager? m) => _shared = m;

