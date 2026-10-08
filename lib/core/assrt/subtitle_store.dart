// =======================================================================
//  字幕落盘 / 绑定 / 偏好（task-29⑤）
// =======================================================================
//
// 三件事：
//   1. 把下载解出来的字幕写到 App 数据目录下的 subtitles/，按「视频键」分目录；
//   2. 记住「这个视频上次挂的是哪个字幕」—— 换集/重开时能自动挂回去；
//   3. 字幕相关的偏好键（全部 dsh.subtitle.* 前缀，集中在 SubtitleConfig）。
//
// # 为什么落盘而不是只留在内存
//
// 播放器换集后 mpv 会重新打开文件，外挂字幕是 file-local 的
// （见 lib/ui/player_page.dart:3119 的 _applySubtitleStyle 注释）——
// 所以字幕必须是**磁盘上真实存在的文件**，播放页才能在每次 sub-add 时引用它。
// 内存里存字节没有意义。
//
// # 目录布局
//
//   <dataDir>/subtitles/<videoKey>/<nn>-<原文件名>
//   <dataDir>/subtitles/<videoKey>/index.json      ← 绑定记录（无 BOM）
//
// videoKey 是把标题/剧集信息归一化后算出来的短哈希（自写 FNV-1a 64 位），
// 不含路径分隔符、不含任何用户可见文案 —— 只用于目录名。
//
// ⚠️ index.json **必须无 BOM**：本仓 load_persisted 一类读取器遇到 BOM 会
// 静默返回空（rust 侧已有此坑），Dart 侧同样按「无 BOM UTF-8」写。

import 'dart:convert';
import 'dart:io';

import '../app_log.dart';
import '../clip_download.dart';
import '../ui_prefs.dart';
import 'assrt_api.dart';
import 'archive.dart';

/// 字幕文件在磁盘上的落点
class SubtitleFileRef {
  const SubtitleFileRef({
    required this.path,
    required this.name,
    required this.bytes,
    this.episode,
  });

  final String path;
  final String name;
  final int bytes;

  /// 从文件名里抽出来的集号（抽不到就是 null）
  final int? episode;

  @override
  String toString() => 'SubtitleFileRef($name, $bytes B, ep=$episode)';
}

/// 一个视频的字幕绑定记录
class SubtitleBinding {
  const SubtitleBinding({
    required this.path,
    required this.name,
    required this.sourceTitle,
    required this.sourceId,
    required this.savedAt,
    this.episode,
  });

  final String path;
  final String name;
  final String sourceTitle;
  final String sourceId;
  final DateTime savedAt;
  final int? episode;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'name': name,
        'sourceTitle': sourceTitle,
        'sourceId': sourceId,
        'savedAt': savedAt.toIso8601String(),
        'episode': episode,
      };

  static SubtitleBinding? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    final name = raw['name'];
    if (path is! String || path.isEmpty) return null;
    return SubtitleBinding(
      path: path,
      name: name is String ? name : path.split(Platform.pathSeparator).last,
      sourceTitle: raw['sourceTitle'] is String ? raw['sourceTitle'] as String : '',
      sourceId: raw['sourceId'] is String ? raw['sourceId'] as String : '',
      savedAt: DateTime.tryParse(raw['savedAt'] is String ? raw['savedAt'] as String : '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      episode: raw['episode'] is int ? raw['episode'] as int : null,
    );
  }
}

/// 字幕落盘 + 绑定
///
/// 全静态，和 [UiPrefs] / [ClipDownloader] 一个风格；测试可用
/// [debugSetRoot] 指到临时目录，不碰真实数据目录。
class SubtitleStore {
  SubtitleStore._();

  static String? _rootOverride;

  /// 测试用：把根目录换掉（传 null 恢复）
  static void debugSetRoot(String? dir) => _rootOverride = dir;

  /// <dataDir>/subtitles
  static Future<String> root() async {
    final o = _rootOverride;
    if (o != null) return o;
    final d = await ClipDownloader.dataDir();
    return '$d${Platform.pathSeparator}subtitles';
  }

  /// 某个视频的目录（不存在则建）
  static Future<String> dirFor(String videoKey) async {
    final r = await root();
    final d = '$r${Platform.pathSeparator}$videoKey';
    await Directory(d).create(recursive: true);
    return d;
  }

  /// 把解出来的字幕写盘
  ///
  /// [items] 通常来自 [extractSubtitles]；只写前 [maxFiles] 个，
  /// 因为真实样本里有 384 个字幕文件的包 —— 全写出来是几百 MB 的垃圾。
  /// 被截断时返回值里带 [SaveResult.truncatedFrom]。
  static Future<SaveResult> save({
    required String videoKey,
    required List<ExtractedSubtitle> items,
    required String sourceTitle,
    required String sourceId,
    int maxFiles = 8,
  }) async {
    final dir = await dirFor(videoKey);
    final saved = <SubtitleFileRef>[];
    var n = 0;
    for (final it in items) {
      if (saved.length >= maxFiles) break;
      n++;
      final safe = _safeFileName(it.baseName);
      final name = '${n.toString().padLeft(2, '0')}-$safe';
      final path = '$dir${Platform.pathSeparator}$name';
      try {
        // 直接写字节，不做任何文本转码 —— 原样落盘，播放器自己认编码
        await File(path).writeAsBytes(it.bytes, flush: true);
      } catch (e) {
        AppLog.write('subtitle', '写字幕失败 $path: $e');
        continue;
      }
      saved.add(SubtitleFileRef(
        path: path,
        name: it.baseName,
        bytes: it.bytes.length,
        episode: episodeNumberOf(it.baseName),
      ));
    }
    if (saved.isEmpty) {
      return const SaveResult(files: <SubtitleFileRef>[], truncatedFrom: null);
    }
    final first = saved.first;
    await bind(
      videoKey,
      SubtitleBinding(
        path: first.path,
        name: first.name,
        sourceTitle: sourceTitle,
        sourceId: sourceId,
        savedAt: DateTime.now(),
        episode: first.episode,
      ),
    );
    return SaveResult(
      files: saved,
      truncatedFrom: items.length > saved.length ? items.length : null,
    );
  }

  /// 记录「这个视频用哪个字幕」
  static Future<void> bind(String videoKey, SubtitleBinding b) async {
    final dir = await dirFor(videoKey);
    final f = File('$dir${Platform.pathSeparator}index.json');
    final list = await _readIndex(f);
    list.removeWhere((e) => e.path == b.path);
    list.insert(0, b);
    // 只留最近 20 条 —— 免得同一个剧集目录无限增长
    final keep = list.take(20).toList();
    try {
      await f.writeAsString(
        jsonEncode(keep.map((e) => e.toJson()).toList()),
        flush: true,
        encoding: const Utf8Codec(), // 无 BOM
      );
    } catch (e) {
      AppLog.write('subtitle', '写绑定失败: $e');
    }
  }

  /// 读回这个视频最近一次挂的字幕（文件已被删则跳过）
  static Future<SubtitleBinding?> boundFor(String videoKey) async {
    final r = await root();
    final f = File('$r${Platform.pathSeparator}$videoKey${Platform.pathSeparator}index.json');
    for (final b in await _readIndex(f)) {
      if (await File(b.path).exists()) return b;
    }
    return null;
  }

  /// 列出这个视频目录下现存的所有字幕文件（按集号/文件名排序）
  static Future<List<SubtitleFileRef>> listFor(String videoKey) async {
    final r = await root();
    final d = Directory('$r${Platform.pathSeparator}$videoKey');
    if (!await d.exists()) return const <SubtitleFileRef>[];
    final out = <SubtitleFileRef>[];
    await for (final e in d.list(followLinks: false)) {
      if (e is! File) continue;
      final base = e.uri.pathSegments.isEmpty ? e.path : e.uri.pathSegments.last;
      if (base == 'index.json') continue;
      if (!isTextSubtitleName(base)) continue;
      var size = 0;
      try {
        size = await e.length();
      } catch (_) {}
      // 去掉写入时加的 '01-' 前缀再抽集号，免得前缀被当成集号
      final logical = base.replaceFirst(RegExp(r'^\d{2}-'), '');
      out.add(SubtitleFileRef(
        path: e.path,
        name: logical,
        bytes: size,
        episode: episodeNumberOf(logical),
      ));
    }
    out.sort((a, b) {
      final ea = a.episode, eb = b.episode;
      if (ea != null && eb != null && ea != eb) return ea.compareTo(eb);
      if (ea != null && eb == null) return -1;
      if (ea == null && eb != null) return 1;
      return a.name.compareTo(b.name);
    });
    return out;
  }

  /// 删除某个视频的全部字幕（用户点「清除」时用）
  static Future<int> clear(String videoKey) async {
    final r = await root();
    final d = Directory('$r${Platform.pathSeparator}$videoKey');
    if (!await d.exists()) return 0;
    var n = 0;
    await for (final e in d.list(followLinks: false)) {
      if (e is! File) continue;
      try {
        await e.delete();
        n++;
      } catch (_) {}
    }
    try {
      await d.delete();
    } catch (_) {}
    return n;
  }

  /// 已占用的总字节数（给设置页显示）
  static Future<int> totalBytes() async {
    final r = await root();
    final d = Directory(r);
    if (!await d.exists()) return 0;
    var sum = 0;
    await for (final e in d.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      try {
        sum += await e.length();
      } catch (_) {}
    }
    return sum;
  }

  static Future<List<SubtitleBinding>> _readIndex(File f) async {
    if (!await f.exists()) return <SubtitleBinding>[];
    try {
      var text = await f.readAsString();
      // 容忍 BOM（别人写的文件可能带）
      if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) {
        text = text.substring(1);
      }
      final raw = jsonDecode(text);
      if (raw is! List) return <SubtitleBinding>[];
      return raw
          .map(SubtitleBinding.fromJson)
          .whereType<SubtitleBinding>()
          .toList();
    } catch (e) {
      AppLog.write('subtitle', '读绑定失败: $e');
      return <SubtitleBinding>[];
    }
  }

  /// 文件名清洗：去掉路径分隔符与控制字符，保留中文/空格/点/括号
  static String _safeFileName(String name) {
    var s = name.replaceAll('\\', '/').split('/').last;
    s = s.replaceAll(RegExp(r'[<>:"|?*\x00-\x1F]'), '_');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.isEmpty) s = 'subtitle.srt';
    if (s.length > 120) {
      // 太长就保留扩展名截断 —— 有些条目的文件名是整段中文标题
      final dot = s.lastIndexOf('.');
      final ext = dot > 0 ? s.substring(dot) : '';
      s = s.substring(0, 120 - ext.length) + ext;
    }
    return s;
  }

  /// 「视频键」：把一个视频（剧名 + 集名 / 或一个直链）折成稳定的目录名
  ///
  /// 用自写 FNV-1a 64 位，**不用 package:crypto** —— pubspec 里没有它，
  /// 引未声明依赖会被 Lead 的审计打回（见 lib/core/danmaku.dart 文件头）。
  static String videoKey({
    String? title,
    String? episodeTitle,
    String? url,
  }) {
    final parts = <String>[
      (title ?? '').trim(),
      (episodeTitle ?? '').trim(),
      (url ?? '').trim(),
    ].where((e) => e.isNotEmpty).toList();
    final basis = parts.isEmpty ? 'unknown' : parts.join('|');
    final h = _fnv1a64(basis);
    final slug = _slugOf(parts.isEmpty ? 'v' : parts.first);
    return '$slug-${h.toRadixString(16).padLeft(16, '0')}';
  }

  static String _slugOf(String s) {
    final cleaned = s
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '')
        .replaceAll(RegExp(r'\s+'), '_');
    final short = cleaned.length > 24 ? cleaned.substring(0, 24) : cleaned;
    return short.isEmpty ? 'v' : short;
  }

  static int _fnv1a64(String s) {
    // FNV-1a 64 位。Dart 的 int 是 64 位，用掩码保持无符号语义。
    const int prime = 0x100000001B3;
    var h = 0xCBF29CE484222325;
    final bytes = utf8.encode(s);
    for (final b in bytes) {
      h = (h ^ b) & 0xFFFFFFFFFFFFFFFF;
      h = (h * prime) & 0xFFFFFFFFFFFFFFFF;
    }
    return h;
  }
}

/// [SubtitleStore.save] 的结果
class SaveResult {
  const SaveResult({required this.files, required this.truncatedFrom});

  final List<SubtitleFileRef> files;

  /// 非 null = 原始文件数比实际落盘的多，这是原始总数
  final int? truncatedFrom;

  bool get isEmpty => files.isEmpty;

  @override
  String toString() => 'SaveResult(${files.length} 个, 原始 $truncatedFrom)';
}

// -----------------------------------------------------------------------
// 偏好键（全部 dsh.subtitle.* —— 与 task-13 的 dsh.* 命名一致）
// -----------------------------------------------------------------------

/// 字幕偏好（纯数据，照 lib/ui/widgets/danmaku_settings_dialog.dart 的
/// DanmakuSettingsState 范式：fromPrefs() 工厂 + copyWith，可脱离 UI 单测）
class SubtitleConfig {
  const SubtitleConfig({
    this.enabled = true,
    this.autoLoadBound = true,
    this.preferredLanguages = const <String>['简', '繁', '英'],
    this.lastKeyword = '',
    this.showAttribution = true,
  });

  /// 总开关：关掉后播放页不显示「字幕」入口
  final bool enabled;

  /// 播放时自动挂上上次绑定过的字幕
  final bool autoLoadBound;

  /// 语言偏好（搜索结果排序用；assrt 的语言字段是「英 简 繁」这种空格串）
  final List<String> preferredLanguages;

  /// 上次搜的关键词（回填输入框，不算敏感信息）
  final String lastKeyword;

  /// 是否显示「字幕服务由 assrt.net 提供」署名
  ///
  /// assrt.net 的 API 文档要求署名；这个开关**默认 true**，
  /// 关掉只是把署名从面板移到关于页，不改变「必须可查」的事实。
  final bool showAttribution;

  static const String kEnabled = 'dsh.subtitle.enabled';
  static const String kAutoLoad = 'dsh.subtitle.autoLoad';
  static const String kLanguages = 'dsh.subtitle.languages';
  static const String kLastKeyword = 'dsh.subtitle.lastKeyword';
  static const String kAttribution = 'dsh.subtitle.attribution';

  static SubtitleConfig fromPrefs() {
    final langs = (UiPrefs.get(kLanguages) ?? '')
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return SubtitleConfig(
      enabled: (UiPrefs.get(kEnabled) ?? '1') != '0',
      autoLoadBound: (UiPrefs.get(kAutoLoad) ?? '1') != '0',
      preferredLanguages: langs.isEmpty
          ? const <String>['简', '繁', '英']
          : langs,
      lastKeyword: UiPrefs.get(kLastKeyword) ?? '',
      showAttribution: (UiPrefs.get(kAttribution) ?? '1') != '0',
    );
  }

  SubtitleConfig copyWith({
    bool? enabled,
    bool? autoLoadBound,
    List<String>? preferredLanguages,
    String? lastKeyword,
    bool? showAttribution,
  }) {
    return SubtitleConfig(
      enabled: enabled ?? this.enabled,
      autoLoadBound: autoLoadBound ?? this.autoLoadBound,
      preferredLanguages: preferredLanguages ?? this.preferredLanguages,
      lastKeyword: lastKeyword ?? this.lastKeyword,
      showAttribution: showAttribution ?? this.showAttribution,
    );
  }

  void save() {
    UiPrefs.set(kEnabled, enabled ? '1' : '0');
    UiPrefs.set(kAutoLoad, autoLoadBound ? '1' : '0');
    UiPrefs.set(kLanguages, preferredLanguages.join(','));
    UiPrefs.set(kLastKeyword, lastKeyword);
    UiPrefs.set(kAttribution, showAttribution ? '1' : '0');
  }

  /// 按语言偏好给搜索结果打分（分高的排前面；0 = 完全没命中偏好）
  ///
  /// assrt 的「语言」字段是「英 简 繁」这种以空格分隔的短串，可能整段缺失。
  int languageScore(AssrtSubtitle s) {
    if (s.languages.isEmpty) return 0;
    var score = 0;
    for (var i = 0; i < preferredLanguages.length; i++) {
      final want = preferredLanguages[i];
      if (want.isEmpty) continue;
      if (s.languages.any((l) => l.contains(want) || want.contains(l))) {
        // 排在前面的偏好权重更高
        score += preferredLanguages.length - i;
      }
    }
    return score;
  }
}
