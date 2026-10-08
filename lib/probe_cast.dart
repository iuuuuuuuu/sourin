// task-27 投屏探针入口（**只用于真机取证**，不是交付界面）
//
// 为什么需要这个独立入口：宿主 GPU 建不起 mpv 的 GL 上下文，播放页底栏在模拟器上
// 永远不渲染（lib/ui/player_page.dart 的 _videoOutputDead 门控），所以「把按钮放进
// 播放页底栏再点它」这条路在模拟器上走不通。这个探针把 CastButton 直接挂在最外层，
// 绕开播放页，让「点按钮 → 发 SSDP → SetAVTransportURI → Play」全链路能被真实点击。
//
// 构建：flutter build apk --release --target-platform android-x64 -t lib/probe_cast.dart
// 装：  adb install -r -d <apk>      ← 同包名覆盖装，别 uninstall（会丢 Owner 的偏好数据）
//
// 正式接线（详情页/播放页底栏）由 Lead 统一做，说明见 .probe/cast/INTEGRATION.md。
import 'package:material_ui/material_ui.dart';

import 'core/dlna/cast_manager.dart';
import 'ui/cast/cast_button.dart';

void main() {
  runApp(const _ProbeApp());
}

class _ProbeApp extends StatelessWidget {
  const _ProbeApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '投屏探针',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF3B82F6), useMaterial3: true),
      home: const CastProbePage(),
    );
  }
}

class CastProbePage extends StatefulWidget {
  const CastProbePage({super.key});

  @override
  State<CastProbePage> createState() => _CastProbePageState();
}

class _CastProbePageState extends State<CastProbePage> {
  /// 默认拿一条**真的会做防盗链**的地址：B 站 CDN 只认 Referer
  /// （只带 UA → 403，只带 Referer → 206，两个都不带 → 403）。
  /// 探针页填的是宿主/假 renderer 能直接拉到的直链，方便对着假 renderer 取证。
  final _urlCtl = TextEditingController(
    text: 'http://10.0.2.2:8081/media/video.mp4',
  );
  final _refCtl = TextEditingController(text: 'https://www.bilibili.com/');
  final _titleCtl = TextEditingController(text: '第 3 集');

  final List<String> _lines = <String>[];
  final ScrollController _scroll = ScrollController();
  bool _scanning = false;
  bool _directBusy = false;
  String _scanSummary = '（还没扫过）';

  CastManager get _m => sharedCastManager;

  @override
  void initState() {
    super.initState();
    // ★ 探针页把 manager 的日志接到 debugPrint：adb logcat 里就有 [CAST] 前缀，
    //   用来和宿主假 renderer 落盘的请求体做时间戳对齐。
    _m.onLog = (line) {
      debugPrint('[CAST] $line');
      if (!mounted) return;
      setState(() => _lines.add(line));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    };
    _m.onLog!('[探针] 页面已就绪，日志从这里开始');
  }

  @override
  void dispose() {
    _urlCtl.dispose();
    _refCtl.dispose();
    _titleCtl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Map<String, String> get _headers {
    final r = _refCtl.text.trim();
    if (r.isEmpty) return const {};
    return {'Referer': r};
  }

  /// 跳过设备弹窗直接投（探针专用取证捷径，见 build 里的注释）
  Future<void> _directCast() async {
    final url = _urlCtl.text.trim();
    if (!(url.startsWith('http://') || url.startsWith('https://'))) {
      setState(() => _scanSummary = '这个地址不能投屏（只支持 http/https）：$url');
      return;
    }
    setState(() => _directBusy = true);
    try {
      final scan = await _m.discover();
      if (scan.devices.isEmpty) {
        setState(() => _scanSummary = '没有可投的设备（可投 ${scan.devices.length} 台，发出 ${scan.scan.sent} 条搜索，收到 ${scan.scan.responses.length} 个回包）');
        return;
      }
      final d = scan.devices.first;
      final s = await _m.cast(d, url, headers: _headers, title: _titleCtl.text.trim());
      setState(() {
        _scanSummary = s.phase == CastPhase.failed
            ? '✗ 投屏失败：${s.error}'
            : '✓ 已投到 ${s.device.name}；代理地址 ${s.proxyUrl}；设备状态 ${s.transportState}';
      });
    } on Object catch (e) {
      setState(() => _scanSummary = '投屏异常：$e');
    } finally {
      if (mounted) setState(() => _directBusy = false);
    }
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _scanSummary = '扫描中…';
    });
    try {
      final scan = await _m.discover();
      final names = scan.devices.map((d) => '${d.name}（${d.host}）').join('、');
      final unsupported = scan.unsupported.map((d) => '${d.name}：${d.why}').join('、');
      setState(() {
        _scanSummary = [
          '发出 M-SEARCH ${scan.scan.sent} 次，收到 ${scan.scan.responses.length} 个回包',
          '可投屏 ${scan.devices.length} 台${names.isEmpty ? '' : '：$names'}',
          if (scan.unsupported.isNotEmpty) '搜到但不能投 ${scan.unsupported.length} 台：$unsupported',
          if (scan.scan.errors.isNotEmpty) '错误：${scan.scan.errors.join('；')}',
          if (!scan.scan.anySent) '★ 一条搜索都没发出去（Wi-Fi 没开？）',
          if (scan.scan.anySent && scan.scan.responses.isEmpty)
            '★ 发得出去、收不到回包（不是「网段里没有设备」——这两个结论不同）',
        ].join('\n');
      });
    } on Object catch (e) {
      setState(() => _scanSummary = '扫描失败：$e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('投屏探针（task-27）'),
        actions: [
          IconButton(
            tooltip: '扫描设备',
            onPressed: _scanning ? null : _scan,
            icon: _scanning
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.search),
          ),
        ],
      ),
      body: ListView(
        controller: _scroll,
        padding: const EdgeInsets.all(16),
        children: [
          const CastStatusBar(),
          const SizedBox(height: 12),
          _label('要投的媒体地址'),
          TextField(
            controller: _urlCtl,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              helperText: '探针默认指向宿主的假 renderer（模拟器里宿主 = 10.0.2.2）',
            ),
          ),
          const SizedBox(height: 12),
          _label('Referer（防盗链用；留空则不加）'),
          TextField(
            controller: _refCtl,
            decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          _label('标题（进 DIDL-Lite 元数据）'),
          TextField(
            controller: _titleCtl,
            decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              CastButton(
                url: _urlCtl.text.trim(),
                headers: _headers,
                title: _titleCtl.text.trim(),
                showLabel: true,
                onLog: (line) => debugPrint('[CAST] $line'),
              ),
              const SizedBox(width: 12),
              Text(
                '← 点这个按钮投屏（与正式界面同一个 CastButton）',
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // ★ 探针专用捷径：跳过设备选择弹窗，扫到第一台能投的设备就直接投。
          //   为什么要有它：在模拟器上这个弹窗的 InkWell 点不动（设备行 tap 之后
          //   弹窗关了但 onTap 没跑，日志里连 [投屏] 目标：… 都没有）—— 这是宿主
          //   渲染/输入的问题，不是投屏链路的问题。正式界面走 CastButton 的
          //   弹窗路径，探针需要一条不依赖弹窗的取证路径。
          Row(
            children: [
              FilledButton.tonal(
                onPressed: _directBusy ? null : _directCast,
                child: Text(_directBusy ? '投屏中…' : '直接投屏（跳过弹窗）'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _label('扫描结果'),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(_scanSummary, style: const TextStyle(fontSize: 13)),
          ),
          const SizedBox(height: 20),
          _label('日志（同时以 [CAST] 前缀进 logcat）'),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              _lines.isEmpty ? '（暂无）' : _lines.join('\n'),
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(t, style: const TextStyle(fontWeight: FontWeight.w600)),
      );
}
